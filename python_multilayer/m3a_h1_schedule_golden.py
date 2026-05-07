#!/usr/bin/env python3
"""Generate H1 Schedule A/B golden counts for Fashion-14x14 Config #2.

Reuses the P4 196_64_10 Fashion model and the same 10 class-major samples as
gen_multilayer_fashion_golden.py, but swaps in per-layer threshold/reset-mode
settings for the H1 board-only ablations.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import _vendored_from_v1.data_utils as v1_data  # noqa: E402
from adc_scale_v2 import rtl_adc_scale_v2  # noqa: E402
from exporter_multilayer import _get_device_levels_for_export, _quantize_stage_weights  # noqa: E402
from snn_engine_multilayer import encode_pixel_to_spike_stream  # noqa: E402
from topologies import get_topology_by_name, load_topology_file  # noqa: E402
import config_multilayer as cfg  # noqa: E402

SCHED_A = ((13, 0), (8, 0))
SCHED_B = ((16, 0), (8, 1))


class FakeStage:
    def __init__(self, in_dim: int, out_dim: int):
        self.in_dim = in_dim
        self.out_dim = out_dim


def run_stage_schedule(
    stage: FakeStage,
    wl_stream: np.ndarray,
    w_pos: np.ndarray,
    w_neg: np.ndarray,
    threshold: int,
    reset_mode: int,
    adc_bits: int,
) -> tuple[np.ndarray, np.ndarray]:
    t_count, in_dim = wl_stream.shape
    if in_dim != stage.in_dim:
        raise ValueError(f"wl_stream in_dim={in_dim} != stage.in_dim={stage.in_dim}")

    out_dim = stage.out_dim
    sum_max = stage.in_dim * 15
    membrane = np.zeros(out_dim, dtype=np.int64)
    spike_counts = np.zeros(out_dim, dtype=np.int64)
    spike_stream_out = np.zeros((t_count, out_dim), dtype=np.int64)

    for t in range(t_count):
        wl = wl_stream[t].astype(np.int64)
        raw_pos = wl @ w_pos
        raw_neg = wl @ w_neg
        adc_pos = np.asarray(
            [rtl_adc_scale_v2(int(v), sum_max=sum_max, adc_bits=adc_bits) for v in raw_pos],
            dtype=np.int64,
        )
        adc_neg = np.asarray(
            [rtl_adc_scale_v2(int(v), sum_max=sum_max, adc_bits=adc_bits) for v in raw_neg],
            dtype=np.int64,
        )
        diff = adc_pos - adc_neg
        membrane += diff
        fired = membrane >= threshold
        spike_stream_out[t, fired] = 1
        spike_counts += fired.astype(np.int64)
        if reset_mode:
            membrane[fired] = 0
        else:
            membrane[fired] -= threshold

    return spike_counts, spike_stream_out


def run_schedule_golden(
    pixel: np.ndarray,
    stage_weights: list[tuple[np.ndarray, np.ndarray]],
    stages: list[FakeStage],
    schedule: tuple[tuple[int, int], tuple[int, int]],
    t_count: int,
    adc_bits: int,
) -> tuple[np.ndarray, int]:
    wl_stream_0 = encode_pixel_to_spike_stream(pixel, t_count, method="even_rate")
    counts0, spike_stream_0 = run_stage_schedule(
        stages[0],
        wl_stream_0,
        stage_weights[0][0],
        stage_weights[0][1],
        threshold=schedule[0][0],
        reset_mode=schedule[0][1],
        adc_bits=adc_bits,
    )
    counts1, _ = run_stage_schedule(
        stages[1],
        spike_stream_0,
        stage_weights[1][0],
        stage_weights[1][1],
        threshold=schedule[1][0],
        reset_mode=schedule[1][1],
        adc_bits=adc_bits,
    )
    predicted = int(counts1.argmax())
    return counts1, predicted


def write_counts_dir(out_dir: Path, samples: list[dict]) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    with (out_dir / "meta.txt").open("w", encoding="ascii", newline="\n") as f:
        f.write("config 196_64_10\n")
        f.write(f"num_samples {len(samples)}\n")
    for sample in samples:
        tag = f"sample_{sample['sample_idx']:02d}"
        with (out_dir / f"{tag}_counts.txt").open("w", encoding="ascii", newline="\n") as f:
            for value in sample["counts"]:
                f.write(f"{int(value)}\n")
        with (out_dir / f"{tag}_predicted.txt").open("w", encoding="ascii", newline="\n") as f:
            f.write(f"{sample['predicted']}\n")
        with (out_dir / f"{tag}_label.txt").open("w", encoding="ascii", newline="\n") as f:
            f.write(f"{sample['label']}\n")


def load_stage_weights(topo) -> list[tuple[np.ndarray, np.ndarray]]:
    model_path = ROOT / "results_multilayer" / "196_64_10" / "model.pt"
    state = torch.load(model_path, map_location="cpu", weights_only=False)
    sd = state["state_dict"] if isinstance(state, dict) and "state_dict" in state else state
    levels = _get_device_levels_for_export(2 ** cfg.QAT_WEIGHT_BITS)
    stage_weights = []
    for i, _stage in enumerate(topo.stages):
        key = f"layers.{i}.weight"
        w = sd[key]
        g_pos, g_neg = _quantize_stage_weights(w, cfg.QAT_WEIGHT_BITS, levels)
        stage_weights.append((g_pos, g_neg))
    return stage_weights


def load_samples(num_samples: int) -> list[dict]:
    data_dir = str(cfg.ROOT_DIR / "data")
    x_test, y_test = v1_data.load_fashion_mnist_test(
        data_dir, target_size=14, method="avgpool"
    )
    x_pool_flat = x_test.numpy().astype(np.int64) if hasattr(x_test, "numpy") else np.asarray(x_test).astype(np.int64)
    if x_pool_flat.ndim == 3:
        x_pool_flat = x_pool_flat.reshape(-1, 14 * 14)
    y_test = y_test.numpy() if hasattr(y_test, "numpy") else np.asarray(y_test)

    chosen_idx = []
    for cls in range(10):
        hits = np.where(y_test == cls)[0]
        if len(hits) == 0:
            raise RuntimeError(f"no Fashion test sample for class {cls}")
        chosen_idx.append(int(hits[0]))
    chosen_idx = chosen_idx[:num_samples]

    samples = []
    for sample_idx, raw_idx in enumerate(chosen_idx):
        samples.append(
            {
                "sample_idx": sample_idx,
                "pixel": x_pool_flat[raw_idx],
                "label": int(y_test[raw_idx]),
            }
        )
    return samples


def main() -> int:
    topo_file = load_topology_file(ROOT / "topologies.yaml")
    topo = get_topology_by_name(topo_file.topologies, "196_64_10")
    t_count = int(topo.stream_timesteps)
    adc_bits = int(topo.adc_bits)
    stages = [FakeStage(topo.stages[0].in_dim, topo.stages[0].out_dim),
              FakeStage(topo.stages[1].in_dim, topo.stages[1].out_dim)]
    stage_weights = load_stage_weights(topo)
    samples = load_samples(num_samples=10)

    sched_a_results = []
    sched_b_results = []
    for sample in samples:
        counts_a, pred_a = run_schedule_golden(
            sample["pixel"], stage_weights, stages, SCHED_A, t_count, adc_bits
        )
        counts_b, pred_b = run_schedule_golden(
            sample["pixel"], stage_weights, stages, SCHED_B, t_count, adc_bits
        )
        sched_a_results.append(
            {
                "sample_idx": sample["sample_idx"],
                "counts": counts_a,
                "predicted": pred_a,
                "label": sample["label"],
            }
        )
        sched_b_results.append(
            {
                "sample_idx": sample["sample_idx"],
                "counts": counts_b,
                "predicted": pred_b,
                "label": sample["label"],
            }
        )

    out_a = ROOT / "results_multilayer" / "h1_schedA_golden"
    out_b = ROOT / "results_multilayer" / "h1_schedB_golden"
    write_counts_dir(out_a, sched_a_results)
    write_counts_dir(out_b, sched_b_results)
    print(f"[done] wrote {out_a}")
    print("H1_SCHED_A_GOLDEN_PASS")
    print(f"[done] wrote {out_b}")
    print("H1_SCHED_B_GOLDEN_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
