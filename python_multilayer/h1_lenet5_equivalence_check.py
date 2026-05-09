#!/usr/bin/env python3
"""LeNet-5 slow/fast H1 schedule equivalence gate for paper §5.7."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

import gen_convnet_golden as conv
import h1_schedule_ablation as ablation
import m2_real_inference as m2inf
import pack_fmap_words as pf
import snn_engine_conv as conv_eng


CONFIG_ID = ablation.CONFIG_LENET5_MNIST
DEFAULT_SAMPLE_COUNT = 100
DEFAULT_SCHEDULES = ("baseline", "reset_mixed_soft_early")
DEFAULT_OUT_JSON = ablation.DEFAULT_OUT_DIR / "h1_lenet5_equivalence_check.json"


def _sha256_array(arr: np.ndarray | torch.Tensor) -> str:
    if isinstance(arr, torch.Tensor):
        arr = arr.detach().cpu().numpy()
    arr_np = np.ascontiguousarray(np.asarray(arr))
    return hashlib.sha256(arr_np.tobytes()).hexdigest()


def _md5_json(obj: object) -> str:
    payload = json.dumps(obj, ensure_ascii=False, sort_keys=False).encode("utf-8")
    return hashlib.md5(payload).hexdigest()


def _resolve_threshold(default_threshold: int, multiplier: float) -> int:
    return max(1, int(np.floor(float(default_threshold) * float(multiplier))))


def _conv_stage_trace(
    input_words: np.ndarray,
    layer: conv.LayerSpec,
    weight_tiles: np.ndarray,
    *,
    t_count: int,
    threshold: int,
    reset_mode: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    cfg_layer = conv.cfg_for_layer(layer, t_count)
    output_words = np.zeros(
        pf.fmap_size_words(layer.out_h, layer.out_w, layer.c_out, t_count),
        dtype=np.uint32,
    )
    output_spikes = np.zeros((layer.out_h, layer.out_w, layer.c_out, t_count), dtype=np.int64)
    final_membrane = np.zeros((layer.out_h, layer.out_w, layer.c_out), dtype=np.int64)

    for oh in range(layer.out_h):
        for ow in range(layer.out_w):
            partial = np.zeros((t_count, layer.c_out), dtype=np.int64)
            membrane = np.zeros(layer.c_out, dtype=np.int64)
            pixel_spikes = np.zeros((t_count, layer.c_out), dtype=np.int64)
            for tile_idx in range(layer.tile_count):
                is_last = tile_idx == layer.tile_count - 1
                for t in range(t_count):
                    wl, valid_count = conv_eng.patch_gather_from_words(
                        input_words,
                        cfg_layer,
                        out_h=oh,
                        out_w=ow,
                        timestep=t,
                        tile_idx=tile_idx,
                    )
                    if valid_count < conv_eng.V2B_NUM_INPUTS:
                        wl[valid_count:] = 0
                    partial[t] += ablation._lenet5_mac_diff(wl, weight_tiles[tile_idx])
                    conv.check_partial_bound(partial[t], f"{layer.name} oh={oh} ow={ow} t={t}")
                    if is_last:
                        membrane += partial[t]
                        fired = membrane >= threshold
                        pixel_spikes[t, :] = fired.astype(np.int64)
                        if reset_mode:
                            membrane[fired] = 0
                        else:
                            membrane[fired] -= threshold
            final_membrane[oh, ow, :] = membrane
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
    return output_words, output_spikes, final_membrane


def _flatten_stage_trace(
    input_words: np.ndarray,
    layer: conv.LayerSpec,
    weight_tiles: np.ndarray,
    *,
    t_count: int,
    threshold: int,
    reset_mode: int,
) -> tuple[np.ndarray, np.ndarray]:
    cfg_layer = conv.cfg_for_layer(layer, t_count)
    partial = np.zeros((t_count, layer.c_out), dtype=np.int64)
    membrane = np.zeros(layer.c_out, dtype=np.int64)
    stream = np.zeros((t_count, layer.c_out), dtype=np.int64)
    for tile_idx in range(layer.tile_count):
        is_last = tile_idx == layer.tile_count - 1
        for t in range(t_count):
            wl, valid_count = conv_eng.flatten_gather_from_words(
                input_words,
                cfg_layer,
                timestep=t,
                tile_idx=tile_idx,
            )
            if valid_count < conv_eng.V2B_NUM_INPUTS:
                wl[valid_count:] = 0
            partial[t] += ablation._lenet5_mac_diff(wl, weight_tiles[tile_idx])
            conv.check_partial_bound(partial[t], f"{layer.name} t={t}")
            if is_last:
                membrane += partial[t]
                fired = membrane >= threshold
                stream[t, :] = fired.astype(np.int64)
                if reset_mode:
                    membrane[fired] = 0
                else:
                    membrane[fired] -= threshold
    return stream, membrane


def _fc_stage_trace(
    spike_stream: np.ndarray,
    layer: conv.LayerSpec,
    weight_tiles: np.ndarray,
    *,
    threshold: int,
    reset_mode: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
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
            partial[t] += ablation._lenet5_mac_diff(wl[t], weight_tiles[tile_idx])
        conv.check_partial_bound(partial, f"{layer.name}")
    membrane = np.zeros(layer.c_out, dtype=np.int64)
    out_stream = np.zeros((t_count, layer.c_out), dtype=np.int64)
    for t in range(t_count):
        membrane += partial[t]
        fired = membrane >= threshold
        out_stream[t, :] = fired.astype(np.int64)
        if reset_mode:
            membrane[fired] = 0
        else:
            membrane[fired] -= threshold
    return out_stream.sum(axis=0).astype(np.int64), out_stream, membrane


def _lif_trace_single(current: torch.Tensor, threshold: int, reset_mode: int) -> tuple[torch.Tensor, torch.Tensor]:
    t_count = current.shape[0]
    membrane = torch.zeros(current.shape[1:], dtype=current.dtype, device=current.device)
    theta = torch.tensor(float(threshold), dtype=current.dtype, device=current.device)
    out = []
    for t in range(t_count):
        membrane = membrane + current[t]
        fired = (membrane >= theta).to(dtype=current.dtype)
        out.append(fired)
        if reset_mode:
            membrane = membrane * (1.0 - fired)
        else:
            membrane = membrane - fired * theta
    return torch.stack(out, dim=0), membrane


def _trace_summary(spikes: np.ndarray | torch.Tensor, membrane: np.ndarray | torch.Tensor) -> dict[str, object]:
    spikes_np = spikes.detach().cpu().numpy() if isinstance(spikes, torch.Tensor) else np.asarray(spikes)
    membrane_np = membrane.detach().cpu().numpy() if isinstance(membrane, torch.Tensor) else np.asarray(membrane)
    return {
        "spike_sum": int(np.asarray(spikes_np, dtype=np.int64).sum()),
        "spike_sha256": _sha256_array(spikes_np),
        "membrane_sha256": _sha256_array(membrane_np),
    }


def _slow_trace(image_tensor: torch.Tensor, schedule: list[tuple[float, int]], assets: dict[str, object]) -> dict[str, object]:
    layers = list(assets["layers"])
    weights = assets["weights"]
    t_count = int(assets["t_count"])
    image = conv.image_to_uint8_hwc(image_tensor)
    spikes = conv.encode_image_to_spike_fmap(image, t_count)
    current_words = pf.pack_spike_fmap(spikes)

    conv1_thr = _resolve_threshold(layers[0].threshold, schedule[0][0])
    conv2_thr = _resolve_threshold(layers[1].threshold, schedule[1][0])
    fc1_thr = _resolve_threshold(layers[2].threshold, schedule[2][0])
    fc2_thr = _resolve_threshold(layers[3].threshold, schedule[3][0])
    fc3_thr = _resolve_threshold(layers[4].threshold, schedule[4][0])

    current_words, conv1_spikes, conv1_mem = _conv_stage_trace(
        current_words,
        layers[0],
        weights["conv1"],
        t_count=t_count,
        threshold=conv1_thr,
        reset_mode=schedule[0][1],
    )
    current_words, conv2_spikes, conv2_mem = _conv_stage_trace(
        current_words,
        layers[1],
        weights["conv2"],
        t_count=t_count,
        threshold=conv2_thr,
        reset_mode=schedule[1][1],
    )
    fc1_stream, fc1_mem = _flatten_stage_trace(
        current_words,
        layers[2],
        weights["fc1"],
        t_count=t_count,
        threshold=fc1_thr,
        reset_mode=schedule[2][1],
    )
    fc2_counts, fc2_stream, fc2_mem = _fc_stage_trace(
        fc1_stream,
        layers[3],
        weights["fc2"],
        threshold=fc2_thr,
        reset_mode=schedule[3][1],
    )
    fc3_counts, fc3_stream, fc3_mem = _fc_stage_trace(
        fc2_stream,
        layers[4],
        weights["fc3"],
        threshold=fc3_thr,
        reset_mode=schedule[4][1],
    )
    stage_traces = {
        "conv1": _trace_summary(conv1_spikes, conv1_mem),
        "conv2": _trace_summary(conv2_spikes, conv2_mem),
        "fc1": _trace_summary(fc1_stream, fc1_mem),
        "fc2": _trace_summary(fc2_stream, fc2_mem),
        "fc3": {
            **_trace_summary(fc3_stream, fc3_mem),
            "output_counts": [int(x) for x in fc3_counts.tolist()],
        },
    }
    return {
        "predicted_class": int(np.argmax(fc3_counts)),
        "stage_traces": stage_traces,
    }


def _fast_trace(image_tensor: torch.Tensor, schedule: list[tuple[float, int]], assets: dict[str, object]) -> dict[str, object]:
    front = assets["front"]
    fc1_w, fc2_w, fc3_w = assets["fc_weights_torch"]
    default_thresholds = assets["default_thresholds"]
    t_count = int(assets["t_count"])

    conv_thresholds = [
        _resolve_threshold(default_thresholds[0], schedule[0][0]),
        _resolve_threshold(default_thresholds[1], schedule[1][0]),
    ]
    fc_thresholds = [
        _resolve_threshold(default_thresholds[2], schedule[2][0]),
        _resolve_threshold(default_thresholds[3], schedule[3][0]),
        _resolve_threshold(default_thresholds[4], schedule[4][0]),
    ]
    conv_resets = [schedule[0][1], schedule[1][1]]
    fc_resets = [schedule[2][1], schedule[3][1], schedule[4][1]]

    stream = front.encode_stream(image_tensor.unsqueeze(0), t_count)[0]
    cur1 = F.conv2d(stream, front.conv1_w, bias=None, stride=1, padding=2)
    conv1_stream, conv1_mem = _lif_trace_single(cur1, conv_thresholds[0], conv_resets[0])
    cur2 = F.conv2d(conv1_stream, front.conv2_w, bias=None, stride=2, padding=0)
    conv2_stream, conv2_mem = _lif_trace_single(cur2, conv_thresholds[1], conv_resets[1])

    flat = conv2_stream.permute(0, 2, 3, 1).reshape(t_count, -1)
    fc1_cur = F.linear(flat, fc1_w)
    fc1_stream, fc1_mem = _lif_trace_single(fc1_cur, fc_thresholds[0], fc_resets[0])
    fc2_cur = F.linear(fc1_stream, fc2_w)
    fc2_stream, fc2_mem = _lif_trace_single(fc2_cur, fc_thresholds[1], fc_resets[1])
    fc3_cur = F.linear(fc2_stream, fc3_w)
    fc3_stream, fc3_mem = _lif_trace_single(fc3_cur, fc_thresholds[2], fc_resets[2])
    fc3_counts = fc3_stream.sum(dim=0).to(dtype=torch.int64)

    stage_traces = {
        "conv1": _trace_summary(conv1_stream, conv1_mem),
        "conv2": _trace_summary(conv2_stream, conv2_mem),
        "fc1": _trace_summary(fc1_stream, fc1_mem),
        "fc2": _trace_summary(fc2_stream, fc2_mem),
        "fc3": {
            **_trace_summary(fc3_stream, fc3_mem),
            "output_counts": [int(x) for x in fc3_counts.cpu().tolist()],
        },
    }
    return {
        "predicted_class": int(torch.argmax(fc3_counts).item()),
        "stage_traces": stage_traces,
    }


def _first_divergent_stage(slow_trace: dict[str, object], fast_trace: dict[str, object]) -> str | None:
    for stage_name in ("conv1", "conv2", "fc1", "fc2", "fc3"):
        slow_stage = slow_trace["stage_traces"][stage_name]
        fast_stage = fast_trace["stage_traces"][stage_name]
        if (
            slow_stage["spike_sha256"] != fast_stage["spike_sha256"]
            or slow_stage["membrane_sha256"] != fast_stage["membrane_sha256"]
        ):
            return stage_name
    return None


def _evaluate_schedule(
    *,
    config_id: str,
    schedule_name: str,
    sample_count: int,
    assets: dict[str, object],
) -> dict[str, object]:
    schedule, rationale = ablation._schedule_for(config_id, schedule_name)
    indices = list(m2inf._lenet5_assets()["indices"])[:sample_count]
    dataset = assets["dataset"]
    images = torch.stack([dataset[idx][0] for idx in indices], dim=0)
    labels = [int(dataset[idx][1]) for idx in indices]
    fast_counts = ablation._run_lenet5_batch_fast(
        images,
        front=assets["front"],
        fc_weights_torch=assets["fc_weights_torch"],
        default_thresholds=assets["default_thresholds"],
        schedule=schedule,
        t_count=int(assets["t_count"]),
    )
    fast_preds = fast_counts.argmax(dim=1).cpu().numpy().tolist()
    slow_preds: list[int] = []
    mismatches: list[dict[str, object]] = []

    for sample_rank, (dataset_idx, label) in enumerate(zip(indices, labels)):
        slow_trace = _slow_trace(dataset[dataset_idx][0], schedule, assets)
        slow_pred = int(slow_trace["predicted_class"])
        fast_pred = int(fast_preds[sample_rank])
        slow_preds.append(slow_pred)
        if slow_pred != fast_pred:
            fast_trace = _fast_trace(dataset[dataset_idx][0], schedule, assets)
            mismatches.append(
                {
                    "sample_rank": sample_rank,
                    "dataset_index": int(dataset_idx),
                    "ground_truth": int(label),
                    "slow_predicted_class": slow_pred,
                    "fast_predicted_class": fast_pred,
                    "first_divergent_stage": _first_divergent_stage(slow_trace, fast_trace),
                    "slow_trace": slow_trace["stage_traces"],
                    "fast_trace": fast_trace["stage_traces"],
                }
            )

    return {
        "schedule_name": schedule_name,
        "schedule_rationale": rationale,
        "sample_count": len(indices),
        "sample_indices_md5": _md5_json(indices),
        "ground_truth_md5": _md5_json(labels),
        "slow_predictions_md5": _md5_json(slow_preds),
        "fast_predictions_md5": _md5_json(fast_preds),
        "pred_mismatch_count": len(mismatches),
        "mismatches": mismatches,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config-id", default=CONFIG_ID, choices=[CONFIG_ID])
    parser.add_argument("--sample-count", type=int, default=DEFAULT_SAMPLE_COUNT)
    parser.add_argument(
        "--schedule",
        action="append",
        choices=list(ablation.lib.SCHEDULE_MAP.keys()),
        help="Schedule(s) to check; default = baseline + reset_mixed_soft_early",
    )
    parser.add_argument("--out-json", default=str(DEFAULT_OUT_JSON))
    args = parser.parse_args(argv)

    schedule_names = args.schedule or list(DEFAULT_SCHEDULES)
    out_json = Path(args.out_json).resolve()
    out_json.parent.mkdir(parents=True, exist_ok=True)
    assets = ablation._load_lenet5_assets(args.config_id)

    results = [
        _evaluate_schedule(
            config_id=args.config_id,
            schedule_name=schedule_name,
            sample_count=args.sample_count,
            assets=assets,
        )
        for schedule_name in schedule_names
    ]
    total_mismatches = sum(int(result["pred_mismatch_count"]) for result in results)
    report = {
        "config_id": args.config_id,
        "sample_count": args.sample_count,
        "subset_source": "m2_real_inference._lenet5_assets().indices[:N]",
        "schedule_results": results,
        "total_pred_mismatches": total_mismatches,
    }
    out_json.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"[ok] wrote {out_json}")
    if total_mismatches == 0:
        print("H1_LENET5_EQUIVALENCE_PASS")
        return 0
    for result in results:
        if int(result["pred_mismatch_count"]) == 0:
            continue
        for mismatch in result["mismatches"]:
            print(
                "[FAIL] schedule={schedule} dataset_index={dataset_index} slow={slow} fast={fast} first_divergent_stage={stage}".format(
                    schedule=result["schedule_name"],
                    dataset_index=mismatch["dataset_index"],
                    slow=mismatch["slow_predicted_class"],
                    fast=mismatch["fast_predicted_class"],
                    stage=mismatch["first_divergent_stage"],
                )
            )
    print("H1_LENET5_EQUIVALENCE_FAIL")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
