#!/usr/bin/env python3
"""Real per-config M2 inference backends for Config #1 and #4.

This module bridges the scaffold scripts (`m2_anchor_check.py`,
`m2_envelope_sweep.py`) to the live repo's actual inference sources:

- Config #1 uses the V1 paper-source 8x8 `avgpool_8x8` pipeline, whose
  86.74% headline comes from the V1 validation split rather than the
  current `snn_engine_multilayer.py` baseline path.
- Config #4 uses the LeNet-5 integer reference flow built from
  `gen_convnet_golden.py` weights/checkpoints, evaluated on a
  deterministic 100-sample stratified subset.

Both paths share the same M2 single-axis surrogate knobs (drift / read /
D2D / ADC offset) and deterministic seed policy, so anchor/sweep CSVs
and provenance files can be derived from one source of truth.
"""

from __future__ import annotations

import hashlib
import json
import random
import sys
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Iterable

import numpy as np
import torch

import gen_convnet_golden as conv
import pack_fmap_words as pf
import snn_engine_conv as conv_eng
import snn_engine_multilayer as eng


ROOT = Path(__file__).resolve().parent
V1_DIR = (ROOT.parent / "项目相关文件" / "器件对齐" / "Python建模").resolve()
if str(V1_DIR) not in sys.path:
    sys.path.insert(0, str(V1_DIR))

import config as v1_cfg  # type: ignore  # noqa: E402
import data_utils as v1_data_utils  # type: ignore  # noqa: E402
import snn_engine as v1_snn_engine  # type: ignore  # noqa: E402
import train_ann as v1_train_ann  # type: ignore  # noqa: E402


CONFIG_V1 = "v1_fc_8x8_mnist"
CONFIG_LENET5 = "v2b_lenet5_mnist_28x28"
HEADLINE_ACC_PCT = {
    CONFIG_V1: 86.74,
    CONFIG_LENET5: 93.03,
}

V1_SPLIT = "val"
V1_STRATIFIED_SEED = 1
LENET5_STRATIFIED_SEED = 12
SAMPLES_PER_CLASS = 10
ADC_BITS_V1 = 8
ADC_BITS_LENET5 = 8


@dataclass(frozen=True)
class Provenance:
    config_id: str
    split_name: str
    subset_seed: int
    samples_per_class: int
    sample_indices: tuple[int, ...]
    labels: tuple[int, ...]
    baseline_output_md5: str


@dataclass(frozen=True)
class RunResult:
    config_id: str
    accuracy_pct: float
    sample_indices: tuple[int, ...]
    labels: tuple[int, ...]
    predictions: tuple[int, ...]
    output_counts: tuple[tuple[int, ...], ...]

    @property
    def sample_indices_md5(self) -> str:
        return _md5_json(list(self.sample_indices))

    @property
    def baseline_output_md5(self) -> str:
        return _md5_json([list(x) for x in self.output_counts])


def _stable_seed(*parts: object) -> int:
    payload = json.dumps(parts, ensure_ascii=False, sort_keys=False, default=str)
    digest = hashlib.sha256(payload.encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "little") % (2**31 - 1)


def _md5_json(obj: object) -> str:
    payload = json.dumps(obj, ensure_ascii=False, sort_keys=False).encode("utf-8")
    return hashlib.md5(payload).hexdigest()


def _stratified_indices(labels: Iterable[int], *, samples_per_class: int, seed: int) -> tuple[int, ...]:
    by_class: dict[int, list[int]] = {k: [] for k in range(10)}
    for idx, label in enumerate(labels):
        by_class[int(label)].append(idx)
    rng = random.Random(seed)
    picked: list[int] = []
    for cls in range(10):
        picked.extend(sorted(rng.sample(by_class[cls], samples_per_class)))
    return tuple(picked)


def _knob_kwargs(dim: str, sweep_value: float) -> dict[str, float]:
    return {
        "drift_alpha": sweep_value if dim == "drift" else 0.0,
        "sigma_read_lsb": sweep_value if dim == "read" else 0.0,
        "sigma_d2d_lognormal": sweep_value if dim == "d2d" else 0.0,
        "sigma_adc_offset_lsb": sweep_value if dim == "adc" else 0.0,
    }


def _int_weight_perturb(
    weights: np.ndarray,
    *,
    config_id: str,
    stage_tag: str,
    base_seed: int,
    drift_alpha: float,
    sigma_d2d_lognormal: float,
) -> np.ndarray:
    if drift_alpha == 0.0 and sigma_d2d_lognormal == 0.0:
        return weights
    rng = np.random.default_rng(_stable_seed(config_id, base_seed, stage_tag, "weight"))
    multiplier = np.ones(weights.shape, dtype=np.float64)
    if sigma_d2d_lognormal > 0.0:
        multiplier *= np.exp(rng.normal(0.0, sigma_d2d_lognormal, size=weights.shape))
    if drift_alpha != 0.0:
        multiplier *= (2.0 ** drift_alpha)
    max_level = int(np.max(weights)) if weights.size else 0
    perturbed = np.rint(weights.astype(np.float64) * multiplier)
    perturbed = np.clip(perturbed, 0, max_level)
    return perturbed.astype(np.int64)


def _float_weight_perturb(
    weights: torch.Tensor,
    *,
    config_id: str,
    stage_tag: str,
    base_seed: int,
    drift_alpha: float,
    sigma_d2d_lognormal: float,
    g_min: float,
    g_max: float,
) -> torch.Tensor:
    if drift_alpha == 0.0 and sigma_d2d_lognormal == 0.0:
        return weights
    rng = np.random.default_rng(_stable_seed(config_id, base_seed, stage_tag, "weight"))
    multiplier = np.ones(tuple(weights.shape), dtype=np.float64)
    if sigma_d2d_lognormal > 0.0:
        multiplier *= np.exp(rng.normal(0.0, sigma_d2d_lognormal, size=tuple(weights.shape)))
    if drift_alpha != 0.0:
        multiplier *= (2.0 ** drift_alpha)
    out = weights.detach().cpu().numpy().astype(np.float64) * multiplier
    out = np.clip(out, g_min, g_max)
    return torch.tensor(out, dtype=weights.dtype)


def _read_noise_int(
    pos_sum: np.ndarray,
    neg_sum: np.ndarray,
    *,
    sigma_read_lsb: float,
    sum_max: int,
    adc_bits: int,
    config_id: str,
    base_seed: int,
    stage_tag: str,
    sample_id: int,
    t_idx: int,
) -> tuple[np.ndarray, np.ndarray]:
    if sigma_read_lsb == 0.0:
        return pos_sum, neg_sum
    adc_max = (1 << adc_bits) - 1
    raw_sigma = sigma_read_lsb * float(sum_max) / float(max(adc_max, 1))
    rng_pos = np.random.default_rng(
        _stable_seed(config_id, base_seed, stage_tag, "read", "pos", sample_id, t_idx)
    )
    rng_neg = np.random.default_rng(
        _stable_seed(config_id, base_seed, stage_tag, "read", "neg", sample_id, t_idx)
    )
    pos_noise = np.rint(rng_pos.normal(0.0, raw_sigma, size=pos_sum.shape)).astype(np.int64)
    neg_noise = np.rint(rng_neg.normal(0.0, raw_sigma, size=neg_sum.shape)).astype(np.int64)
    return pos_sum + pos_noise, neg_sum + neg_noise


def _adc_offset_for_dim(
    *,
    out_dim: int,
    sigma_adc_offset_lsb: float,
    adc_bits: int,
    config_id: str,
    base_seed: int,
    stage_tag: str,
) -> np.ndarray:
    if sigma_adc_offset_lsb == 0.0:
        return np.zeros(out_dim, dtype=np.int64)
    rng = np.random.default_rng(
        _stable_seed(config_id, base_seed, stage_tag, "adc", out_dim, adc_bits)
    )
    return np.rint(rng.normal(0.0, sigma_adc_offset_lsb, size=out_dim)).astype(np.int64)


@lru_cache(maxsize=1)
def _v1_assets() -> dict[str, object]:
    ds = v1_data_utils.prepare_all_datasets(quick_mode=False)["avgpool_8x8"]
    model = v1_train_ann.load_weights("avgpool_8x8", input_dim=64)
    weights = v1_train_ann.get_weights(model)
    device_sim = v1_snn_engine._get_plugin_sim(rows=10, cols=64)
    if device_sim is None:
        raise RuntimeError("V1 device simulator is unavailable")
    g_pos, g_neg = v1_snn_engine.prepare_conductance_pair_device(weights, weight_bits=4, device_sim=device_sim)
    fs_cfg = v1_snn_engine.estimate_adc_full_scale(g_pos, g_neg, "B")
    threshold = float(v1_snn_engine._estimate_spike_threshold(fs_cfg, 10, 1.0 / 255.0))
    labels = ds[f"{V1_SPLIT}_labels"]
    indices = _stratified_indices(labels.tolist(), samples_per_class=SAMPLES_PER_CLASS, seed=V1_STRATIFIED_SEED)
    return {
        "images": ds[f"{V1_SPLIT}_images_uint8"],
        "labels": labels,
        "indices": indices,
        "device_sim": device_sim,
        "g_pos": g_pos.detach().cpu(),
        "g_neg": g_neg.detach().cpu(),
        "fs_cfg": fs_cfg,
        "threshold": threshold,
    }


def _v1_run_single(
    pixel_vec: np.ndarray,
    *,
    device_sim,
    g_pos: torch.Tensor,
    g_neg: torch.Tensor,
    fs_cfg: dict,
    threshold: float,
    sigma_read_lsb: float,
    sigma_adc_offset_lsb: float,
    config_id: str,
    base_seed: int,
    sample_id: int,
) -> tuple[int, tuple[int, ...]]:
    membrane = torch.zeros(10, dtype=torch.float64)
    spike_counts = torch.zeros(10, dtype=torch.int64)

    pos_scale = float(fs_cfg["pos"]) / float((1 << ADC_BITS_V1) - 1)
    neg_scale = float(fs_cfg["neg"]) / float((1 << ADC_BITS_V1) - 1)
    adc_offset = _adc_offset_for_dim(
        out_dim=10,
        sigma_adc_offset_lsb=sigma_adc_offset_lsb,
        adc_bits=ADC_BITS_V1,
        config_id=config_id,
        base_seed=base_seed,
        stage_tag="v1",
    )
    adc_offset_pos = torch.tensor(adc_offset * pos_scale, dtype=torch.float64).unsqueeze(0)
    adc_offset_neg = torch.tensor(adc_offset * neg_scale, dtype=torch.float64).unsqueeze(0)

    pixels = np.asarray(pixel_vec, dtype=np.int64)
    for _frame in range(10):
        for bit in range(v1_cfg.PIXEL_BITS - 1, -1, -1):
            spike_input = torch.tensor(((pixels >> bit) & 1), dtype=torch.float64).unsqueeze(0)
            mac_pos = v1_snn_engine._cim_mac(spike_input, g_pos.to(dtype=torch.float64), device_sim)
            mac_neg = v1_snn_engine._cim_mac(spike_input, g_neg.to(dtype=torch.float64), device_sim)
            if sigma_read_lsb > 0.0:
                raw_sigma_pos = sigma_read_lsb * float(fs_cfg["pos"]) / float((1 << ADC_BITS_V1) - 1)
                raw_sigma_neg = sigma_read_lsb * float(fs_cfg["neg"]) / float((1 << ADC_BITS_V1) - 1)
                rng_pos = np.random.default_rng(
                    _stable_seed(config_id, base_seed, "v1", "read", "pos", sample_id, _frame, bit)
                )
                rng_neg = np.random.default_rng(
                    _stable_seed(config_id, base_seed, "v1", "read", "neg", sample_id, _frame, bit)
                )
                mac_pos = mac_pos + torch.tensor(
                    rng_pos.normal(0.0, raw_sigma_pos, size=tuple(mac_pos.shape)),
                    dtype=mac_pos.dtype,
                )
                mac_neg = mac_neg + torch.tensor(
                    rng_neg.normal(0.0, raw_sigma_neg, size=tuple(mac_neg.shape)),
                    dtype=mac_neg.dtype,
                )
            adc_pos = v1_snn_engine.quantize_adc(
                mac_pos, ADC_BITS_V1, signed=False, full_scale=fs_cfg["pos"], full_scale_mode="fixed"
            )
            adc_neg = v1_snn_engine.quantize_adc(
                mac_neg, ADC_BITS_V1, signed=False, full_scale=fs_cfg["neg"], full_scale_mode="fixed"
            )
            if sigma_adc_offset_lsb > 0.0:
                adc_pos = torch.clamp(adc_pos + adc_offset_pos, 0.0, float(fs_cfg["pos"]))
                adc_neg = torch.clamp(adc_neg + adc_offset_neg, 0.0, float(fs_cfg["neg"]))
            membrane += (adc_pos - adc_neg).squeeze(0) * float(1 << bit)
            fired = membrane >= threshold
            spike_counts += fired.to(dtype=torch.int64)
            membrane[fired] -= threshold

    pred = int(torch.argmax(spike_counts).item())
    return pred, tuple(int(x) for x in spike_counts.tolist())


def _run_v1_backend(
    *,
    drift_alpha: float = 0.0,
    sigma_read_lsb: float = 0.0,
    sigma_d2d_lognormal: float = 0.0,
    sigma_adc_offset_lsb: float = 0.0,
    base_seed: int = 0,
) -> RunResult:
    assets = _v1_assets()
    images = assets["images"]
    labels = assets["labels"]
    indices = assets["indices"]
    device_sim = assets["device_sim"]
    g_min = float(device_sim.conductance_model.g_min)
    g_max = float(device_sim.conductance_model.g_max)
    g_pos = _float_weight_perturb(
        assets["g_pos"],
        config_id=CONFIG_V1,
        stage_tag="v1_pos",
        base_seed=base_seed,
        drift_alpha=drift_alpha,
        sigma_d2d_lognormal=sigma_d2d_lognormal,
        g_min=g_min,
        g_max=g_max,
    )
    g_neg = _float_weight_perturb(
        assets["g_neg"],
        config_id=CONFIG_V1,
        stage_tag="v1_neg",
        base_seed=base_seed,
        drift_alpha=drift_alpha,
        sigma_d2d_lognormal=sigma_d2d_lognormal,
        g_min=g_min,
        g_max=g_max,
    )

    predictions: list[int] = []
    outputs: list[tuple[int, ...]] = []
    subset_labels = [int(labels[i]) for i in indices]
    for sample_id, index in enumerate(indices):
        pred, counts = _v1_run_single(
            images[index].numpy(),
            device_sim=device_sim,
            g_pos=g_pos,
            g_neg=g_neg,
            fs_cfg=assets["fs_cfg"],
            threshold=assets["threshold"],
            sigma_read_lsb=sigma_read_lsb,
            sigma_adc_offset_lsb=sigma_adc_offset_lsb,
            config_id=CONFIG_V1,
            base_seed=base_seed,
            sample_id=sample_id,
        )
        predictions.append(pred)
        outputs.append(counts)

    accuracy_pct = 100.0 * sum(int(p == y) for p, y in zip(predictions, subset_labels)) / len(indices)
    return RunResult(
        config_id=CONFIG_V1,
        accuracy_pct=accuracy_pct,
        sample_indices=tuple(int(i) for i in indices),
        labels=tuple(subset_labels),
        predictions=tuple(predictions),
        output_counts=tuple(outputs),
    )


@lru_cache(maxsize=1)
def _lenet5_assets() -> dict[str, object]:
    ckpt = conv.train_lenet5_head_checkpoint(force=False, download=False)
    proxy_ckpt = conv.train_proxy_checkpoint("lenet5", force=False, download=False)
    proxy = conv.ConvNet("lenet5")
    proxy.load_state_dict(proxy_ckpt["state_dict"])
    proxy.eval()
    head = conv.LenetSNNHead.from_proxy(proxy)
    head.load_state_dict(ckpt["head_state_dict"])
    layers = list(conv.NETWORKS["lenet5"]["layers"])
    th_fc1, th_fc2, th_fc3 = ckpt["export_fc_thresholds"]
    layers = [
        layers[0],
        layers[1],
        conv.LayerSpec(**{**layers[2].__dict__, "threshold": int(th_fc1)}),
        conv.LayerSpec(**{**layers[3].__dict__, "threshold": int(th_fc2)}),
        conv.LayerSpec(**{**layers[4].__dict__, "threshold": int(th_fc3)}),
    ]
    weights = {
        "conv1": conv.layer_weight_tiles(proxy, layers[0]),
        "conv2": conv.layer_weight_tiles(proxy, layers[1]),
        "fc1": conv.make_weight_tiles_from_matrix(head.export()[0].T),
        "fc2": conv.make_weight_tiles_from_matrix(head.export()[1].T),
        "fc3": conv.make_weight_tiles_from_matrix(head.export()[2].T),
    }
    test_ds = conv.load_dataset("mnist", train=False, download=False)
    labels = [int(test_ds[i][1]) for i in range(len(test_ds))]
    indices = _stratified_indices(labels, samples_per_class=SAMPLES_PER_CLASS, seed=LENET5_STRATIFIED_SEED)
    return {
        "dataset": test_ds,
        "layers": tuple(layers),
        "weights": weights,
        "indices": indices,
    }


def _adc_scale_int_bits(raw: np.ndarray, *, sum_max: int, adc_bits: int) -> np.ndarray:
    adc_max = (1 << adc_bits) - 1
    raw_i = np.asarray(raw, dtype=np.int64)
    scaled = (raw_i * adc_max + (sum_max // 2)) // sum_max
    return np.clip(scaled, 0, adc_max).astype(np.int64)


def _lenet5_mac_diff(
    wl: np.ndarray,
    weights: np.ndarray,
    *,
    sum_max: int,
    adc_bits: int,
    config_id: str,
    base_seed: int,
    stage_tag: str,
    sample_id: int,
    t_idx: int,
    drift_alpha: float,
    sigma_read_lsb: float,
    sigma_d2d_lognormal: float,
    sigma_adc_offset_lsb: float,
) -> np.ndarray:
    pos = np.clip(weights, 0, None).astype(np.int64)
    neg = np.clip(-weights, 0, None).astype(np.int64)
    pos = _int_weight_perturb(
        pos,
        config_id=config_id,
        stage_tag=f"{stage_tag}_pos",
        base_seed=base_seed,
        drift_alpha=drift_alpha,
        sigma_d2d_lognormal=sigma_d2d_lognormal,
    )
    neg = _int_weight_perturb(
        neg,
        config_id=config_id,
        stage_tag=f"{stage_tag}_neg",
        base_seed=base_seed,
        drift_alpha=drift_alpha,
        sigma_d2d_lognormal=sigma_d2d_lognormal,
    )
    wl_i = np.asarray(wl, dtype=np.int64)
    pos_sum = (wl_i @ pos).astype(np.int64)
    neg_sum = (wl_i @ neg).astype(np.int64)
    diff = pos_sum - neg_sum
    if sigma_read_lsb > 0.0:
        rng = np.random.default_rng(
            _stable_seed(config_id, base_seed, stage_tag, "read", sample_id, t_idx)
        )
        diff = diff + np.rint(rng.normal(0.0, sigma_read_lsb, size=diff.shape)).astype(np.int64)
    if sigma_adc_offset_lsb > 0.0:
        offset = _adc_offset_for_dim(
            out_dim=diff.shape[0],
            sigma_adc_offset_lsb=sigma_adc_offset_lsb,
            adc_bits=adc_bits,
            config_id=config_id,
            base_seed=base_seed,
            stage_tag=stage_tag,
        )
        diff = diff + offset
    return diff.astype(np.int64)


def _run_conv_layer_hw_m2(
    input_words: np.ndarray,
    layer: conv.LayerSpec,
    weight_tiles: np.ndarray,
    *,
    t_count: int,
    sample_id: int,
    base_seed: int,
    drift_alpha: float,
    sigma_read_lsb: float,
    sigma_d2d_lognormal: float,
    sigma_adc_offset_lsb: float,
) -> tuple[np.ndarray, np.ndarray]:
    cfg = conv.cfg_for_layer(layer, t_count)
    output_words = np.zeros(
        pf.fmap_size_words(layer.out_h, layer.out_w, layer.c_out, t_count),
        dtype=np.uint32,
    )
    output_spikes = np.zeros((layer.out_h, layer.out_w, layer.c_out, t_count), dtype=np.int64)
    sum_max = min(layer.input_dim, conv_eng.V2B_NUM_INPUTS) * layer.max_level

    for oh in range(layer.out_h):
        for ow in range(layer.out_w):
            partial = np.zeros((t_count, layer.c_out), dtype=np.int64)
            membrane = np.zeros(layer.c_out, dtype=np.int64)
            pixel_spikes = np.zeros((t_count, layer.c_out), dtype=np.int64)
            for tile_idx in range(layer.tile_count):
                is_last = tile_idx == layer.tile_count - 1
                for t in range(t_count):
                    wl, valid_count = conv_eng.patch_gather_from_words(
                        input_words, cfg, out_h=oh, out_w=ow, timestep=t, tile_idx=tile_idx
                    )
                    if valid_count < conv_eng.V2B_NUM_INPUTS:
                        wl[valid_count:] = 0
                    partial[t] += _lenet5_mac_diff(
                        wl,
                        weight_tiles[tile_idx],
                        sum_max=sum_max,
                        adc_bits=ADC_BITS_LENET5,
                        config_id=CONFIG_LENET5,
                        base_seed=base_seed,
                        stage_tag=f"{layer.name}_tile{tile_idx}",
                        sample_id=sample_id,
                        t_idx=t,
                        drift_alpha=drift_alpha,
                        sigma_read_lsb=sigma_read_lsb,
                        sigma_d2d_lognormal=sigma_d2d_lognormal,
                        sigma_adc_offset_lsb=sigma_adc_offset_lsb,
                    )
                    conv.check_partial_bound(partial[t], f"{layer.name} oh={oh} ow={ow} t={t}")
                    if is_last:
                        membrane += partial[t]
                        fired = membrane >= layer.threshold
                        pixel_spikes[t, :] = fired.astype(np.int64)
                        membrane[fired] -= layer.threshold
            for t in range(t_count):
                for c_idx in range(layer.c_out):
                    bit = int(pixel_spikes[t, c_idx])
                    output_spikes[oh, ow, c_idx, t] = bit
                    pf.set_fmap_bit(
                        output_words,
                        h=oh,
                        w=ow,
                        c=c_idx,
                        t=t,
                        value=bit,
                        width=layer.out_w,
                        channels=layer.c_out,
                        t_count=t_count,
                        base_word=0,
                    )
    return output_words, output_spikes


def _run_flatten_layer_hw_m2(
    input_words: np.ndarray,
    layer: conv.LayerSpec,
    weight_tiles: np.ndarray,
    *,
    t_count: int,
    sample_id: int,
    base_seed: int,
    drift_alpha: float,
    sigma_read_lsb: float,
    sigma_d2d_lognormal: float,
    sigma_adc_offset_lsb: float,
) -> np.ndarray:
    cfg = conv.cfg_for_layer(layer, t_count)
    sum_max = min(layer.input_dim, conv_eng.V2B_NUM_INPUTS) * layer.max_level
    partial = np.zeros((t_count, layer.c_out), dtype=np.int64)
    membrane = np.zeros(layer.c_out, dtype=np.int64)
    stream = np.zeros((t_count, layer.c_out), dtype=np.int64)
    for tile_idx in range(layer.tile_count):
        is_last = tile_idx == layer.tile_count - 1
        for t in range(t_count):
            wl, valid_count = conv_eng.flatten_gather_from_words(input_words, cfg, timestep=t, tile_idx=tile_idx)
            if valid_count < conv_eng.V2B_NUM_INPUTS:
                wl[valid_count:] = 0
            partial[t] += _lenet5_mac_diff(
                wl,
                weight_tiles[tile_idx],
                sum_max=sum_max,
                adc_bits=ADC_BITS_LENET5,
                config_id=CONFIG_LENET5,
                base_seed=base_seed,
                stage_tag=f"{layer.name}_tile{tile_idx}",
                sample_id=sample_id,
                t_idx=t,
                drift_alpha=drift_alpha,
                sigma_read_lsb=sigma_read_lsb,
                sigma_d2d_lognormal=sigma_d2d_lognormal,
                sigma_adc_offset_lsb=sigma_adc_offset_lsb,
            )
            conv.check_partial_bound(partial[t], f"{layer.name} t={t}")
            if is_last:
                membrane += partial[t]
                fired = membrane >= layer.threshold
                stream[t, :] = fired.astype(np.int64)
                membrane[fired] -= layer.threshold
    return stream


def _run_fc_stream_hw_m2(
    spike_stream: np.ndarray,
    layer: conv.LayerSpec,
    weight_tiles: np.ndarray,
    *,
    sample_id: int,
    base_seed: int,
    drift_alpha: float,
    sigma_read_lsb: float,
    sigma_d2d_lognormal: float,
    sigma_adc_offset_lsb: float,
) -> tuple[np.ndarray, np.ndarray]:
    t_count, in_dim = spike_stream.shape
    if in_dim != layer.c_in:
        raise ValueError(f"{layer.name}: stream in_dim {in_dim} != {layer.c_in}")
    sum_max = min(layer.c_in, conv_eng.V2B_NUM_INPUTS) * layer.max_level
    partial = np.zeros((t_count, layer.c_out), dtype=np.int64)
    for tile_idx in range(layer.tile_count):
        start = tile_idx * conv_eng.V2B_NUM_INPUTS
        stop = min(start + conv_eng.V2B_NUM_INPUTS, layer.c_in)
        wl = np.zeros((t_count, conv_eng.V2B_NUM_INPUTS), dtype=np.int64)
        wl[:, : stop - start] = spike_stream[:, start:stop]
        for t in range(t_count):
            partial[t] += _lenet5_mac_diff(
                wl[t],
                weight_tiles[tile_idx],
                sum_max=sum_max,
                adc_bits=ADC_BITS_LENET5,
                config_id=CONFIG_LENET5,
                base_seed=base_seed,
                stage_tag=f"{layer.name}_tile{tile_idx}",
                sample_id=sample_id,
                t_idx=t,
                drift_alpha=drift_alpha,
                sigma_read_lsb=sigma_read_lsb,
                sigma_d2d_lognormal=sigma_d2d_lognormal,
                sigma_adc_offset_lsb=sigma_adc_offset_lsb,
            )
        conv.check_partial_bound(partial, f"{layer.name}")
    membrane = np.zeros(layer.c_out, dtype=np.int64)
    out_stream = np.zeros((t_count, layer.c_out), dtype=np.int64)
    for t in range(t_count):
        membrane += partial[t]
        fired = membrane >= layer.threshold
        out_stream[t, :] = fired.astype(np.int64)
        membrane[fired] -= layer.threshold
    return out_stream.sum(axis=0).astype(np.int64), out_stream


def _run_lenet5_backend(
    *,
    drift_alpha: float = 0.0,
    sigma_read_lsb: float = 0.0,
    sigma_d2d_lognormal: float = 0.0,
    sigma_adc_offset_lsb: float = 0.0,
    base_seed: int = 0,
) -> RunResult:
    assets = _lenet5_assets()
    test_ds = assets["dataset"]
    layers = list(assets["layers"])
    weights = assets["weights"]
    indices = assets["indices"]
    t_count = int(conv.NETWORKS["lenet5"]["t"])

    predictions: list[int] = []
    outputs: list[tuple[int, ...]] = []
    labels: list[int] = []

    for sample_id, index in enumerate(indices):
        image_tensor, label = test_ds[index]
        labels.append(int(label))
        image = conv.image_to_uint8_hwc(image_tensor)
        spikes = conv.encode_image_to_spike_fmap(image, t_count)
        current_words = pf.pack_spike_fmap(spikes)

        current_words, _ = _run_conv_layer_hw_m2(
            current_words,
            layers[0],
            weights["conv1"],
            t_count=t_count,
            sample_id=sample_id,
            base_seed=base_seed,
            drift_alpha=drift_alpha,
            sigma_read_lsb=sigma_read_lsb,
            sigma_d2d_lognormal=sigma_d2d_lognormal,
            sigma_adc_offset_lsb=sigma_adc_offset_lsb,
        )
        current_words, _ = _run_conv_layer_hw_m2(
            current_words,
            layers[1],
            weights["conv2"],
            t_count=t_count,
            sample_id=sample_id,
            base_seed=base_seed,
            drift_alpha=drift_alpha,
            sigma_read_lsb=sigma_read_lsb,
            sigma_d2d_lognormal=sigma_d2d_lognormal,
            sigma_adc_offset_lsb=sigma_adc_offset_lsb,
        )
        stream = _run_flatten_layer_hw_m2(
            current_words,
            layers[2],
            weights["fc1"],
            t_count=t_count,
            sample_id=sample_id,
            base_seed=base_seed,
            drift_alpha=drift_alpha,
            sigma_read_lsb=sigma_read_lsb,
            sigma_d2d_lognormal=sigma_d2d_lognormal,
            sigma_adc_offset_lsb=sigma_adc_offset_lsb,
        )
        _, stream = _run_fc_stream_hw_m2(
            stream,
            layers[3],
            weights["fc2"],
            sample_id=sample_id,
            base_seed=base_seed,
            drift_alpha=drift_alpha,
            sigma_read_lsb=sigma_read_lsb,
            sigma_d2d_lognormal=sigma_d2d_lognormal,
            sigma_adc_offset_lsb=sigma_adc_offset_lsb,
        )
        counts, _ = _run_fc_stream_hw_m2(
            stream,
            layers[4],
            weights["fc3"],
            sample_id=sample_id,
            base_seed=base_seed,
            drift_alpha=drift_alpha,
            sigma_read_lsb=sigma_read_lsb,
            sigma_d2d_lognormal=sigma_d2d_lognormal,
            sigma_adc_offset_lsb=sigma_adc_offset_lsb,
        )
        pred = int(np.argmax(counts))
        predictions.append(pred)
        outputs.append(tuple(int(x) for x in counts.tolist()))

    accuracy_pct = 100.0 * sum(int(p == y) for p, y in zip(predictions, labels)) / len(indices)
    return RunResult(
        config_id=CONFIG_LENET5,
        accuracy_pct=accuracy_pct,
        sample_indices=tuple(int(i) for i in indices),
        labels=tuple(labels),
        predictions=tuple(predictions),
        output_counts=tuple(outputs),
    )


@lru_cache(maxsize=8)
def run_anchor(config_id: str) -> RunResult:
    if config_id == CONFIG_V1:
        eng.m2_reset()
        return _run_v1_backend()
    if config_id == CONFIG_LENET5:
        eng.m2_reset()
        return _run_lenet5_backend()
    raise ValueError(f"unsupported config_id={config_id!r}")


def run_perturbed(config_id: str, dim: str, sweep_value: float, seed: int) -> RunResult:
    kwargs = _knob_kwargs(dim, sweep_value)
    base_seed = _stable_seed(config_id, dim, sweep_value, seed)
    if config_id == CONFIG_V1:
        return _run_v1_backend(base_seed=base_seed, **kwargs)
    if config_id == CONFIG_LENET5:
        return _run_lenet5_backend(base_seed=base_seed, **kwargs)
    raise ValueError(f"unsupported config_id={config_id!r}")


def sample_provenance(config_id: str) -> Provenance:
    anchor = run_anchor(config_id)
    if config_id == CONFIG_V1:
        return Provenance(
            config_id=config_id,
            split_name=V1_SPLIT,
            subset_seed=V1_STRATIFIED_SEED,
            samples_per_class=SAMPLES_PER_CLASS,
            sample_indices=anchor.sample_indices,
            labels=anchor.labels,
            baseline_output_md5=anchor.baseline_output_md5,
        )
    if config_id == CONFIG_LENET5:
        return Provenance(
            config_id=config_id,
            split_name="test",
            subset_seed=LENET5_STRATIFIED_SEED,
            samples_per_class=SAMPLES_PER_CLASS,
            sample_indices=anchor.sample_indices,
            labels=anchor.labels,
            baseline_output_md5=anchor.baseline_output_md5,
        )
    raise ValueError(f"unsupported config_id={config_id!r}")
