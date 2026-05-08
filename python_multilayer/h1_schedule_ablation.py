#!/usr/bin/env python3
"""H1 full-test-set schedule ablation driver for paper §5.7."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import sys
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

import _vendored_from_v1.data_utils as v1_data
import config_multilayer as cfg
import gen_convnet_golden as conv
import h1_schedule_library as lib
import m2_real_inference as m2inf
import pack_fmap_words as pf
import snn_engine_conv as conv_eng
import snn_engine_multilayer as eng
from exporter_multilayer import _quantize_stage_weights
from topologies import TopologyConfig, get_topology_by_name, load_topology_file


ROOT = Path(__file__).resolve().parent
PAPER_ROOT = ROOT.parent.parent / "SoC Design"
DEFAULT_OUT_DIR = PAPER_ROOT / "essay" / "exp_h1_schedule_ablation"
MAX_LAYER_SLOTS = 8

CONFIG_V1 = "v1_fc_8x8_mnist"
CONFIG_FASHION14 = "v2b_fc_fashion14_2L"
CONFIG_MNIST14 = "v2b_fc_mnist14_2L"
CONFIG_LENET5_MNIST = "v2b_lenet5_mnist_28x28"
CONFIG_FASHION28 = "v2b_fc_fashion28_2L"
CONFIG_LENET5_FASHION = "v2b_lenet5_fashion_28x28"


@dataclass(frozen=True)
class ConfigSpec:
    config_id: str
    config_number: int
    short_label: str
    paper_label: str
    kind: str
    headline_accuracy_pct: float
    num_layers: int
    dataset: str
    target_size: int
    topology_name: str | None = None
    model_path: Path | None = None
    lenet_ckpt_suffix: str = ""


CONFIGS = {
    CONFIG_V1: ConfigSpec(
        config_id=CONFIG_V1,
        config_number=1,
        short_label="V1 8x8 MNIST",
        paper_label="#1 V1 8x8 MNIST",
        kind="v1",
        headline_accuracy_pct=86.74,
        num_layers=1,
        dataset="mnist",
        target_size=8,
    ),
    CONFIG_FASHION14: ConfigSpec(
        config_id=CONFIG_FASHION14,
        config_number=2,
        short_label="V2.B FC Fashion 14x14",
        paper_label="#2 V2.B FC F14",
        kind="fc",
        headline_accuracy_pct=82.38,
        num_layers=2,
        dataset="fashion_mnist",
        target_size=14,
        topology_name="196_64_10",
        model_path=ROOT / "results_multilayer" / "196_64_10" / "model.pt",
    ),
    CONFIG_MNIST14: ConfigSpec(
        config_id=CONFIG_MNIST14,
        config_number=3,
        short_label="V2.B FC MNIST 14x14",
        paper_label="#3 V2.B FC M14",
        kind="fc",
        headline_accuracy_pct=96.48,
        num_layers=2,
        dataset="mnist",
        target_size=14,
        topology_name="mnist_196_64_10",
        model_path=ROOT / "results_multilayer" / "196_64_10__mnist14" / "model.pt",
    ),
    CONFIG_LENET5_MNIST: ConfigSpec(
        config_id=CONFIG_LENET5_MNIST,
        config_number=4,
        short_label="V2.B LeNet5 MNIST",
        paper_label="#4 V2.B LeNet5 M",
        kind="lenet5",
        headline_accuracy_pct=93.03,
        num_layers=5,
        dataset="mnist",
        target_size=28,
    ),
    CONFIG_FASHION28: ConfigSpec(
        config_id=CONFIG_FASHION28,
        config_number=5,
        short_label="V2.B FC Fashion 28x28",
        paper_label="#5 V2.B FC F28",
        kind="fc",
        headline_accuracy_pct=84.05,
        num_layers=2,
        dataset="fashion_mnist",
        target_size=28,
        topology_name="784_64_10",
        model_path=ROOT / "results_multilayer" / "784_64_10" / "model.pt",
    ),
    CONFIG_LENET5_FASHION: ConfigSpec(
        config_id=CONFIG_LENET5_FASHION,
        config_number=6,
        short_label="V2.B LeNet5 Fashion",
        paper_label="#6 V2.B LeNet5 F",
        kind="lenet5",
        headline_accuracy_pct=81.99,
        num_layers=5,
        dataset="fashion_mnist",
        target_size=28,
        lenet_ckpt_suffix="_fashion",
    ),
}

CONFIG_ORDER = [
    CONFIG_V1,
    CONFIG_FASHION14,
    CONFIG_MNIST14,
    CONFIG_LENET5_MNIST,
    CONFIG_FASHION28,
    CONFIG_LENET5_FASHION,
]


def _expected_full_count(config_id: str) -> int:
    spec = CONFIGS[config_id]
    if spec.kind == "v1":
        return int(len(_load_v1_assets_full()["labels"]))
    if spec.kind == "fc":
        _topo, _weights, _images, labels = _load_fc_assets(config_id)
        return int(len(labels))
    if spec.kind == "lenet5":
        return int(len(_load_lenet5_assets(config_id)["dataset"]))
    raise ValueError(f"unsupported kind={spec.kind!r}")


def _md5_json(obj: object) -> str:
    return hashlib.md5(
        json.dumps(obj, ensure_ascii=False, sort_keys=False).encode("utf-8")
    ).hexdigest()


def _load_state_dict(model_path: Path) -> dict[str, torch.Tensor]:
    state = torch.load(model_path, map_location="cpu", weights_only=False)
    if isinstance(state, dict) and "state_dict" in state:
        return state["state_dict"]
    return state


def _resolve_model_path(model_path: Path) -> Path:
    best_path = model_path.with_name("model_best.pt")
    if best_path.exists():
        return best_path
    return model_path


def _load_fc_dataset(dataset: str, target_size: int) -> tuple[np.ndarray, np.ndarray]:
    data_dir = str(cfg.ROOT_DIR / "data")
    if dataset == "mnist":
        images, labels = v1_data.load_mnist_test(data_dir, target_size=target_size, method="avgpool")
    elif dataset == "fashion_mnist":
        images, labels = v1_data.load_fashion_mnist_test(
            data_dir, target_size=target_size, method="avgpool"
        )
    else:
        raise ValueError(f"unsupported dataset={dataset!r}")
    images_np = images.numpy().astype(np.int64) if hasattr(images, "numpy") else np.asarray(images).astype(np.int64)
    if images_np.ndim == 3:
        images_np = images_np.reshape(-1, target_size * target_size)
    labels_np = labels.numpy() if hasattr(labels, "numpy") else np.asarray(labels)
    return images_np, labels_np


@lru_cache(maxsize=3)
def _load_fc_assets(config_id: str) -> tuple[TopologyConfig, list[tuple[np.ndarray, np.ndarray]], np.ndarray, np.ndarray]:
    spec = CONFIGS[config_id]
    assert spec.topology_name is not None
    assert spec.model_path is not None
    topo = get_topology_by_name(
        load_topology_file(ROOT / "topologies.yaml").topologies,
        spec.topology_name,
    )
    state_dict = _load_state_dict(_resolve_model_path(spec.model_path))
    # Paper Table-3 FC headline accuracies come from the training-time
    # `forward_streamed_rate` evaluation path, which uses the default uniform
    # 16-level grid (`levels=None`) rather than the exporter's device-level
    # table. Use the same quantization surface here so baseline rows line up
    # with the published numbers.
    levels = None
    stage_weights: list[tuple[np.ndarray, np.ndarray]] = []
    for i, _stage in enumerate(topo.stages):
        key = f"layers.{i}.weight"
        if key not in state_dict:
            raise KeyError(f"missing key {key!r} in {spec.model_path}")
        w_pos, w_neg = _quantize_stage_weights(state_dict[key], cfg.QAT_WEIGHT_BITS, levels)
        stage_weights.append((w_pos, w_neg))
    images, labels = _load_fc_dataset(spec.dataset, spec.target_size)
    return topo, stage_weights, images, labels


@lru_cache(maxsize=1)
def _load_v1_assets_full() -> dict[str, object]:
    assets = dict(m2inf._v1_assets())
    assets["g_pos"] = assets["g_pos"].to(dtype=torch.float64)
    assets["g_neg"] = assets["g_neg"].to(dtype=torch.float64)
    return assets


def _resolve_threshold_float(default_threshold: float, multiplier: float) -> float:
    if abs(multiplier - 1.0) < 1e-12:
        return float(default_threshold)
    return float(max(1, int(np.floor(float(default_threshold) * multiplier))))


def _resolve_threshold_int(default_threshold: int, multiplier: float) -> int:
    if abs(multiplier - 1.0) < 1e-12:
        return int(default_threshold)
    return int(max(1, int(np.floor(float(default_threshold) * multiplier))))


def _run_v1_single(
    pixel_vec: np.ndarray,
    *,
    g_pos: torch.Tensor,
    g_neg: torch.Tensor,
    device_sim,
    fs_cfg: dict[str, float],
    threshold: float,
    reset_mode: int,
) -> tuple[int, tuple[int, ...]]:
    membrane = torch.zeros(10, dtype=torch.float64)
    spike_counts = torch.zeros(10, dtype=torch.int64)
    pixels = np.asarray(pixel_vec, dtype=np.int64)
    for _frame in range(10):
        for bit in range(m2inf.v1_cfg.PIXEL_BITS - 1, -1, -1):
            spike_input = torch.tensor(((pixels >> bit) & 1), dtype=torch.float64).unsqueeze(0)
            mac_pos = m2inf.v1_snn_engine._cim_mac(spike_input, g_pos, device_sim)
            mac_neg = m2inf.v1_snn_engine._cim_mac(spike_input, g_neg, device_sim)
            adc_pos = m2inf.v1_snn_engine.quantize_adc(
                mac_pos,
                m2inf.ADC_BITS_V1,
                signed=False,
                full_scale=fs_cfg["pos"],
                full_scale_mode="fixed",
            )
            adc_neg = m2inf.v1_snn_engine.quantize_adc(
                mac_neg,
                m2inf.ADC_BITS_V1,
                signed=False,
                full_scale=fs_cfg["neg"],
                full_scale_mode="fixed",
            )
            membrane += (adc_pos - adc_neg).squeeze(0) * float(1 << bit)
            fired = membrane >= threshold
            spike_counts += fired.to(dtype=torch.int64)
            if reset_mode:
                membrane[fired] = 0.0
            else:
                membrane[fired] -= threshold
    pred = int(torch.argmax(spike_counts).item())
    return pred, tuple(int(x) for x in spike_counts.tolist())


def _lenet5_mac_diff(wl: np.ndarray, weights: np.ndarray) -> np.ndarray:
    """LeNet-5 anchor path: raw signed MAC, matching m2_real_inference."""
    wl_i = np.asarray(wl, dtype=np.int64)
    weights_i = np.asarray(weights, dtype=np.int64)
    return (wl_i @ weights_i).astype(np.int64)


@lru_cache(maxsize=2)
def _load_lenet5_assets(config_id: str) -> dict[str, object]:
    spec = CONFIGS[config_id]
    conv.NETWORKS["lenet5"]["dataset"] = spec.dataset
    ckpt = conv.train_lenet5_head_checkpoint(
        force=False,
        download=False,
        ckpt_suffix=spec.lenet_ckpt_suffix,
    )
    proxy_ckpt = conv.train_proxy_checkpoint(
        "lenet5",
        force=False,
        download=False,
        ckpt_suffix=spec.lenet_ckpt_suffix,
    )
    proxy = conv.ConvNet("lenet5")
    proxy.load_state_dict(proxy_ckpt["state_dict"])
    proxy.eval()
    head = conv.LenetSNNHead.from_proxy(proxy)
    head.load_state_dict(ckpt["head_state_dict"])
    head.eval()
    layers = list(conv.NETWORKS["lenet5"]["layers"])
    th_fc1, th_fc2, th_fc3 = ckpt["export_fc_thresholds"]
    layers = [
        layers[0],
        layers[1],
        conv.LayerSpec(**{**layers[2].__dict__, "threshold": int(th_fc1)}),
        conv.LayerSpec(**{**layers[3].__dict__, "threshold": int(th_fc2)}),
        conv.LayerSpec(**{**layers[4].__dict__, "threshold": int(th_fc3)}),
    ]
    front = conv.FrozenLenetFrontEnd.from_proxy(proxy, layers[:2])
    front.eval()
    weights = {
        "conv1": conv.layer_weight_tiles(proxy, layers[0]),
        "conv2": conv.layer_weight_tiles(proxy, layers[1]),
        "fc1": conv.make_weight_tiles_from_matrix(head.export()[0].T),
        "fc2": conv.make_weight_tiles_from_matrix(head.export()[1].T),
        "fc3": conv.make_weight_tiles_from_matrix(head.export()[2].T),
    }
    fc1_q, fc2_q, fc3_q, fc_thresholds = head.export()
    test_ds = conv.load_dataset(spec.dataset, train=False, download=False)
    return {
        "dataset": test_ds,
        "layers": tuple(layers),
        "weights": weights,
        "t_count": int(conv.NETWORKS["lenet5"]["t"]),
        "front": front,
        "fc_weights_torch": (
            torch.tensor(fc1_q, dtype=torch.float32),
            torch.tensor(fc2_q, dtype=torch.float32),
            torch.tensor(fc3_q, dtype=torch.float32),
        ),
        "default_thresholds": (
            int(layers[0].threshold),
            int(layers[1].threshold),
            int(fc_thresholds[0]),
            int(fc_thresholds[1]),
            int(fc_thresholds[2]),
        ),
    }


def _run_conv_layer_h1(
    input_words: np.ndarray,
    layer: conv.LayerSpec,
    weight_tiles: np.ndarray,
    *,
    t_count: int,
    stage_idx: int,
) -> tuple[np.ndarray, np.ndarray]:
    cfg_layer = conv.cfg_for_layer(layer, t_count)
    output_words = np.zeros(
        pf.fmap_size_words(layer.out_h, layer.out_w, layer.c_out, t_count),
        dtype=np.uint32,
    )
    output_spikes = np.zeros((layer.out_h, layer.out_w, layer.c_out, t_count), dtype=np.int64)
    threshold, reset_mode = eng.h1_resolve_stage_lif(layer.threshold, stage_idx)

    for oh in range(layer.out_h):
        for ow in range(layer.out_w):
            partial = np.zeros((t_count, layer.c_out), dtype=np.int64)
            membrane = np.zeros(layer.c_out, dtype=np.int64)
            pixel_spikes = np.zeros((t_count, layer.c_out), dtype=np.int64)
            for tile_idx in range(layer.tile_count):
                is_last = tile_idx == layer.tile_count - 1
                for t in range(t_count):
                    wl, valid_count = conv_eng.patch_gather_from_words(
                        input_words, cfg_layer, out_h=oh, out_w=ow, timestep=t, tile_idx=tile_idx
                    )
                    if valid_count < conv_eng.V2B_NUM_INPUTS:
                        wl[valid_count:] = 0
                    partial[t] += _lenet5_mac_diff(wl, weight_tiles[tile_idx])
                    conv.check_partial_bound(partial[t], f"{layer.name} oh={oh} ow={ow} t={t}")
                    if is_last:
                        membrane += partial[t]
                        fired = membrane >= threshold
                        pixel_spikes[t, :] = fired.astype(np.int64)
                        if reset_mode:
                            membrane[fired] = 0
                        else:
                            membrane[fired] -= threshold
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


def _run_flatten_layer_h1(
    input_words: np.ndarray,
    layer: conv.LayerSpec,
    weight_tiles: np.ndarray,
    *,
    t_count: int,
    stage_idx: int,
) -> np.ndarray:
    cfg_layer = conv.cfg_for_layer(layer, t_count)
    partial = np.zeros((t_count, layer.c_out), dtype=np.int64)
    membrane = np.zeros(layer.c_out, dtype=np.int64)
    stream = np.zeros((t_count, layer.c_out), dtype=np.int64)
    threshold, reset_mode = eng.h1_resolve_stage_lif(layer.threshold, stage_idx)
    for tile_idx in range(layer.tile_count):
        is_last = tile_idx == layer.tile_count - 1
        for t in range(t_count):
            wl, valid_count = conv_eng.flatten_gather_from_words(
                input_words, cfg_layer, timestep=t, tile_idx=tile_idx
            )
            if valid_count < conv_eng.V2B_NUM_INPUTS:
                wl[valid_count:] = 0
            partial[t] += _lenet5_mac_diff(wl, weight_tiles[tile_idx])
            conv.check_partial_bound(partial[t], f"{layer.name} t={t}")
            if is_last:
                membrane += partial[t]
                fired = membrane >= threshold
                stream[t, :] = fired.astype(np.int64)
                if reset_mode:
                    membrane[fired] = 0
                else:
                    membrane[fired] -= threshold
    return stream


def _run_fc_stream_h1(
    spike_stream: np.ndarray,
    layer: conv.LayerSpec,
    weight_tiles: np.ndarray,
    *,
    stage_idx: int,
) -> tuple[np.ndarray, np.ndarray]:
    t_count, in_dim = spike_stream.shape
    if in_dim != layer.c_in:
        raise ValueError(f"{layer.name}: stream in_dim {in_dim} != {layer.c_in}")
    partial = np.zeros((t_count, layer.c_out), dtype=np.int64)
    for tile_idx in range(layer.tile_count):
        start = tile_idx * conv_eng.V2B_NUM_INPUTS
        stop = min(start + conv_eng.V2B_NUM_INPUTS, layer.c_in)
        wl = np.zeros((t_count, conv_eng.V2B_NUM_INPUTS), dtype=np.int64)
        wl[:, : stop - start] = spike_stream[:, start:stop]
        for t in range(t_count):
            partial[t] += _lenet5_mac_diff(wl[t], weight_tiles[tile_idx])
        conv.check_partial_bound(partial, f"{layer.name}")
    membrane = np.zeros(layer.c_out, dtype=np.int64)
    out_stream = np.zeros((t_count, layer.c_out), dtype=np.int64)
    threshold, reset_mode = eng.h1_resolve_stage_lif(layer.threshold, stage_idx)
    for t in range(t_count):
        membrane += partial[t]
        fired = membrane >= threshold
        out_stream[t, :] = fired.astype(np.int64)
        if reset_mode:
            membrane[fired] = 0
        else:
            membrane[fired] -= threshold
    return out_stream.sum(axis=0).astype(np.int64), out_stream


def _lif_torch(current: torch.Tensor, threshold: int, reset_mode: int) -> torch.Tensor:
    n = current.shape[0]
    t_count = current.shape[1]
    mem = torch.zeros((n, *current.shape[2:]), dtype=current.dtype, device=current.device)
    theta = torch.tensor(float(threshold), dtype=current.dtype, device=current.device)
    out = []
    for t in range(t_count):
        mem = mem + current[:, t]
        fired = (mem >= theta).to(dtype=current.dtype)
        out.append(fired)
        if reset_mode:
            mem = mem * (1.0 - fired)
        else:
            mem = mem - fired * theta
    return torch.stack(out, dim=1)


@torch.no_grad()
def _run_lenet5_batch_fast(
    images: torch.Tensor,
    *,
    front: conv.FrozenLenetFrontEnd,
    fc_weights_torch: tuple[torch.Tensor, torch.Tensor, torch.Tensor],
    default_thresholds: tuple[int, int, int, int, int],
    schedule: list[tuple[float, int]],
    t_count: int,
) -> torch.Tensor:
    conv_thresholds = [
        _resolve_threshold_int(default_thresholds[0], schedule[0][0]),
        _resolve_threshold_int(default_thresholds[1], schedule[1][0]),
    ]
    fc_thresholds = [
        _resolve_threshold_int(default_thresholds[2], schedule[2][0]),
        _resolve_threshold_int(default_thresholds[3], schedule[3][0]),
        _resolve_threshold_int(default_thresholds[4], schedule[4][0]),
    ]
    conv_resets = [schedule[0][1], schedule[1][1]]
    fc_resets = [schedule[2][1], schedule[3][1], schedule[4][1]]

    stream = front.encode_stream(images, t_count)
    n, tt, c, h, w = stream.shape
    cur1 = F.conv2d(stream.reshape(n * tt, c, h, w), front.conv1_w, bias=None, stride=1, padding=2)
    stream = _lif_torch(cur1.reshape(n, tt, 6, 28, 28), conv_thresholds[0], conv_resets[0])
    n, tt, c, h, w = stream.shape
    cur2 = F.conv2d(stream.reshape(n * tt, c, h, w), front.conv2_w, bias=None, stride=2, padding=0)
    stream = _lif_torch(cur2.reshape(n, tt, 16, 12, 12), conv_thresholds[1], conv_resets[1])

    flat = stream.permute(0, 1, 3, 4, 2).reshape(n, tt, -1)
    fc1_w, fc2_w, fc3_w = fc_weights_torch
    x = F.linear(flat.reshape(n * tt, -1), fc1_w).reshape(n, tt, 120)
    x = _lif_torch(x, fc_thresholds[0], fc_resets[0])
    x = F.linear(x.reshape(n * tt, 120), fc2_w).reshape(n, tt, 84)
    x = _lif_torch(x, fc_thresholds[1], fc_resets[1])
    x = F.linear(x.reshape(n * tt, 84), fc3_w).reshape(n, tt, 10)
    x = _lif_torch(x, fc_thresholds[2], fc_resets[2])
    return x.sum(dim=1)


def _schedule_for(config_id: str, schedule_name: str) -> tuple[list[tuple[float, int]], str]:
    spec = CONFIGS[config_id]
    factory, rationale = lib.SCHEDULE_MAP[schedule_name]
    schedule = factory(spec.num_layers)
    if len(schedule) != spec.num_layers:
        raise ValueError(
            f"{schedule_name} produced {len(schedule)} layers for {config_id}, "
            f"expected {spec.num_layers}"
        )
    return schedule, rationale


def _target_indices(count: int, n_samples: int | None) -> list[int]:
    if n_samples is None or n_samples <= 0:
        return list(range(count))
    return list(range(min(count, n_samples)))


def _raw_csv_path(config_id: str, schedule_name: str) -> Path:
    return ROOT / f"h1_schedule_ablation_{config_id}_{schedule_name}.csv"


def _raw_fieldnames() -> list[str]:
    fields = [
        "config_id",
        "schedule_name",
        "schedule_rationale",
        "num_layers",
        "sample_id",
        "ground_truth",
        "predicted",
        "correct",
    ]
    for layer_idx in range(MAX_LAYER_SLOTS):
        fields.append(f"layer{layer_idx}_thr_mult")
        fields.append(f"layer{layer_idx}_reset")
    return fields


def _raw_row_base(
    *,
    config_id: str,
    schedule_name: str,
    rationale: str,
    schedule: list[tuple[float, int]],
    sample_id: int,
    ground_truth: int,
    predicted: int,
) -> dict[str, object]:
    row: dict[str, object] = {
        "config_id": config_id,
        "schedule_name": schedule_name,
        "schedule_rationale": rationale,
        "num_layers": len(schedule),
        "sample_id": sample_id,
        "ground_truth": ground_truth,
        "predicted": predicted,
        "correct": int(predicted == ground_truth),
    }
    for layer_idx in range(MAX_LAYER_SLOTS):
        if layer_idx < len(schedule):
            row[f"layer{layer_idx}_thr_mult"] = f"{schedule[layer_idx][0]:.6f}"
            row[f"layer{layer_idx}_reset"] = schedule[layer_idx][1]
        else:
            row[f"layer{layer_idx}_thr_mult"] = ""
            row[f"layer{layer_idx}_reset"] = ""
    return row


def _completed_sample_ids(raw_csv: Path) -> set[int]:
    if not raw_csv.exists():
        return set()
    with raw_csv.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        return {int(row["sample_id"]) for row in reader}


def _ensure_writer(raw_csv: Path) -> csv.DictWriter:
    need_header = not raw_csv.exists()
    handle = raw_csv.open("a", encoding="utf-8", newline="")
    writer = csv.DictWriter(handle, fieldnames=_raw_fieldnames())
    if need_header:
        writer.writeheader()
    writer._backing_handle = handle  # type: ignore[attr-defined]
    return writer


def _close_writer(writer: csv.DictWriter) -> None:
    writer._backing_handle.close()  # type: ignore[attr-defined]


def _run_v1_schedule(config_id: str, schedule_name: str, n_samples: int | None) -> Path:
    spec = CONFIGS[config_id]
    schedule, rationale = _schedule_for(config_id, schedule_name)
    multiplier, reset_mode = schedule[0]
    assets = _load_v1_assets_full()
    images = assets["images"]
    labels = assets["labels"]
    indices = _target_indices(len(labels), n_samples)
    raw_csv = _raw_csv_path(config_id, schedule_name)
    done = _completed_sample_ids(raw_csv)
    writer = _ensure_writer(raw_csv)
    threshold = _resolve_threshold_float(float(assets["threshold"]), multiplier)
    try:
        for pos, dataset_idx in enumerate(indices):
            if dataset_idx in done:
                continue
            pred, counts = _run_v1_single(
                np.asarray(images[dataset_idx]),
                g_pos=assets["g_pos"],
                g_neg=assets["g_neg"],
                device_sim=assets["device_sim"],
                fs_cfg=assets["fs_cfg"],
                threshold=threshold,
                reset_mode=reset_mode,
            )
            writer.writerow(
                _raw_row_base(
                    config_id=config_id,
                    schedule_name=schedule_name,
                    rationale=rationale,
                    schedule=schedule,
                    sample_id=dataset_idx,
                    ground_truth=int(labels[dataset_idx]),
                    predicted=pred,
                )
            )
            if (pos + 1) % 250 == 0:
                print(
                    f"[{config_id}/{schedule_name}] {pos + 1}/{len(indices)} samples",
                    flush=True,
                )
    finally:
        _close_writer(writer)
    return raw_csv


def _run_fc_schedule(config_id: str, schedule_name: str, n_samples: int | None) -> Path:
    schedule, rationale = _schedule_for(config_id, schedule_name)
    eng.h1_set_schedule(
        threshold_multipliers=[item[0] for item in schedule],
        reset_modes=[item[1] for item in schedule],
    )
    try:
        topo, stage_weights, images, labels = _load_fc_assets(config_id)
        indices = _target_indices(len(labels), n_samples)
        raw_csv = _raw_csv_path(config_id, schedule_name)
        done = _completed_sample_ids(raw_csv)
        writer = _ensure_writer(raw_csv)
        try:
            for pos, dataset_idx in enumerate(indices):
                if dataset_idx in done:
                    continue
                pred, per_stage_counts, _ = eng.snn_inference_multilayer_sample(
                    images[dataset_idx], topo, stage_weights
                )
                _ = per_stage_counts[-1]
                writer.writerow(
                    _raw_row_base(
                        config_id=config_id,
                        schedule_name=schedule_name,
                        rationale=rationale,
                        schedule=schedule,
                        sample_id=dataset_idx,
                        ground_truth=int(labels[dataset_idx]),
                        predicted=int(pred),
                    )
                )
                if (pos + 1) % 250 == 0:
                    print(
                        f"[{config_id}/{schedule_name}] {pos + 1}/{len(indices)} samples",
                        flush=True,
                    )
        finally:
            _close_writer(writer)
        return raw_csv
    finally:
        eng.h1_reset()


def _run_lenet5_schedule(config_id: str, schedule_name: str, n_samples: int | None) -> Path:
    schedule, rationale = _schedule_for(config_id, schedule_name)
    assets = _load_lenet5_assets(config_id)
    test_ds = assets["dataset"]
    t_count = int(assets["t_count"])
    front = assets["front"]
    fc_weights_torch = assets["fc_weights_torch"]
    default_thresholds = assets["default_thresholds"]
    indices = _target_indices(len(test_ds), n_samples)
    raw_csv = _raw_csv_path(config_id, schedule_name)
    done = _completed_sample_ids(raw_csv)
    remaining = [dataset_idx for dataset_idx in indices if dataset_idx not in done]
    if not remaining:
        return raw_csv
    writer = _ensure_writer(raw_csv)
    batch_size = 64
    processed = 0
    try:
        for start in range(0, len(remaining), batch_size):
            batch_indices = remaining[start:start + batch_size]
            batch_images = torch.stack([test_ds[idx][0] for idx in batch_indices], dim=0)
            batch_labels = [int(test_ds[idx][1]) for idx in batch_indices]
            counts = _run_lenet5_batch_fast(
                batch_images,
                front=front,
                fc_weights_torch=fc_weights_torch,
                default_thresholds=default_thresholds,
                schedule=schedule,
                t_count=t_count,
            )
            preds = counts.argmax(dim=1).cpu().numpy().tolist()
            for dataset_idx, label, pred in zip(batch_indices, batch_labels, preds):
                writer.writerow(
                    _raw_row_base(
                        config_id=config_id,
                        schedule_name=schedule_name,
                        rationale=rationale,
                        schedule=schedule,
                        sample_id=dataset_idx,
                        ground_truth=label,
                        predicted=int(pred),
                    )
                )
            processed += len(batch_indices)
            if processed % 256 == 0 or processed == len(remaining):
                print(
                    f"[{config_id}/{schedule_name}] {processed}/{len(remaining)} samples",
                    flush=True,
                )
    finally:
        _close_writer(writer)
    return raw_csv


def run_schedule(
    *,
    config_id: str,
    schedule_name: str,
    n_samples: int | None = None,
    out_dir: Path = DEFAULT_OUT_DIR,
) -> Path:
    spec = CONFIGS[config_id]
    out_dir.mkdir(parents=True, exist_ok=True)
    if spec.kind == "v1":
        raw_csv = _run_v1_schedule(config_id, schedule_name, n_samples)
    elif spec.kind == "fc":
        raw_csv = _run_fc_schedule(config_id, schedule_name, n_samples)
    elif spec.kind == "lenet5":
        raw_csv = _run_lenet5_schedule(config_id, schedule_name, n_samples)
    else:
        raise ValueError(f"unsupported kind={spec.kind!r}")
    rebuild_summary_csv(config_id=config_id, out_dir=out_dir)
    return raw_csv


def rebuild_summary_csv(*, config_id: str, out_dir: Path = DEFAULT_OUT_DIR) -> list[dict[str, object]]:
    spec = CONFIGS[config_id]
    out_dir.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, object]] = []
    baseline_accuracy: float | None = None
    baseline_total_count: int | None = None
    for schedule_name, _factory, rationale in lib.SCHEDULES:
        raw_csv = _raw_csv_path(config_id, schedule_name)
        if not raw_csv.exists():
            continue
        with raw_csv.open("r", encoding="utf-8", newline="") as f:
            reader = list(csv.DictReader(f))
        if not reader:
            continue
        correct_count = sum(int(row["correct"]) for row in reader)
        total_count = len(reader)
        accuracy_pct = 100.0 * correct_count / total_count
        if schedule_name == "baseline":
            baseline_accuracy = accuracy_pct
            baseline_total_count = total_count
        summary_row = {
            "config_id": config_id,
            "schedule_name": schedule_name,
            "schedule_rationale": rationale,
            "correct_count": correct_count,
            "total_count": total_count,
            "accuracy_pct": f"{accuracy_pct:.4f}",
            "delta_vs_baseline_pct": "",
            "sample_indices_md5": _md5_json([int(row["sample_id"]) for row in reader]),
        }
        rows.append(summary_row)
    if baseline_accuracy is not None:
        expected_full_count = _expected_full_count(config_id)
        if baseline_total_count == expected_full_count:
            delta = abs(baseline_accuracy - spec.headline_accuracy_pct)
            if delta > 0.5:
                raise RuntimeError(
                    f"{config_id} baseline drifted to {baseline_accuracy:.4f}% "
                    f"(headline {spec.headline_accuracy_pct:.2f}%, delta {delta:.4f}%)"
                )
        for row in rows:
            row["delta_vs_baseline_pct"] = f"{float(row['accuracy_pct']) - baseline_accuracy:+.4f}"
    summary_csv = out_dir / f"summary_{config_id}.csv"
    with summary_csv.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "config_id",
                "schedule_name",
                "schedule_rationale",
                "correct_count",
                "total_count",
                "accuracy_pct",
                "delta_vs_baseline_pct",
                "sample_indices_md5",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)
    return rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config-id", required=True, choices=CONFIG_ORDER)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--schedule", choices=list(lib.SCHEDULE_MAP.keys()))
    group.add_argument("--all", action="store_true")
    parser.add_argument(
        "--n-samples",
        type=int,
        default=0,
        help="0 or omitted = full test split; positive value = first N samples for debug",
    )
    parser.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR))
    parser.add_argument("--frozen-utc", default="")
    args = parser.parse_args(argv)

    out_dir = Path(args.out_dir).resolve()
    schedule_names = [name for name, _factory, _rationale in lib.SCHEDULES] if args.all else [args.schedule]
    if args.frozen_utc:
        print(f"[meta] frozen_utc={args.frozen_utc}", flush=True)
    for schedule_name in schedule_names:
        print(f"[run] config={args.config_id} schedule={schedule_name}", flush=True)
        raw_csv = run_schedule(
            config_id=args.config_id,
            schedule_name=schedule_name,
            n_samples=args.n_samples if args.n_samples > 0 else None,
            out_dir=out_dir,
        )
        print(f"[ok] wrote {raw_csv}", flush=True)
    if args.all:
        print(f"H1_SCHEDULE_ABLATION_FULL_SWEEP_DONE config={args.config_id}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
