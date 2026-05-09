"""Generate Fashion 14x14 multilayer bit-parity golden for RTL TB.

Loads P4 model (196_64_10 Fashion T=64) from results_multilayer/196_64_10/
model.pt, quantises weights, encodes 10 Fashion test images to spike
streams, runs the RTL-like _run_stage_streamed_rate pipeline and dumps
everything the TB needs in hex form.

Layout produced under results_multilayer/fashion_multilayer_golden/:
  meta.txt                — topology params (T, adc_bits, in/out dims, thresholds)
  stage0_w_pos.hex        — 196 x 64 4-bit level, row-major
  stage0_w_neg.hex        — 196 x 64 4-bit level, row-major
  stage1_w_pos.hex        — 64 x 10
  stage1_w_neg.hex        — 64 x 10
  sample_XX_wl_stream.hex — one file per sample: T lines of 256-bit hex (zero-pad)
  sample_XX_counts.txt    — final per-class counts from Python golden (10 ints)
  sample_XX_predicted.txt — argmax class
  sample_XX_label.txt     — Fashion ground-truth label
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
from exporter_multilayer import _quantize_stage_weights, _get_device_levels_for_export  # noqa: E402
from gen_multilayer_bundle import resolve_best_or_final_model_path  # noqa: E402
from snn_engine_multilayer import _run_stage_streamed_rate, encode_pixel_to_spike_stream  # noqa: E402
from topologies import get_topology_by_name, load_topology_file  # noqa: E402
import config_multilayer as cfg  # noqa: E402


class FakeStage:
    def __init__(self, in_dim: int, out_dim: int, threshold: int):
        self.in_dim = in_dim
        self.out_dim = out_dim
        self.threshold = threshold


def dump_weight_hex(path: Path, w: np.ndarray) -> None:
    """w: [in_dim, out_dim] int values 0..15, row-major."""
    in_dim, out_dim = w.shape
    with path.open("w") as f:
        for i in range(in_dim):
            for j in range(out_dim):
                f.write(f"{int(w[i, j]):01x}\n")


def dump_wl_stream_hex(path: Path, wl_stream: np.ndarray, pad_width: int) -> None:
    """wl_stream: [T, in_dim] binary. Each line: pad_width-bit hex value
    where bit i = wl_stream[t, i] for i < in_dim, else 0."""
    T, in_dim = wl_stream.shape
    assert pad_width >= in_dim
    hex_chars = (pad_width + 3) // 4
    with path.open("w") as f:
        for t in range(T):
            val = 0
            for i in range(in_dim):
                if wl_stream[t, i]:
                    val |= (1 << i)
            f.write(f"{val:0{hex_chars}x}\n")


def run_2stage_golden(
    pixel: np.ndarray, stage_weights, stages, T: int, adc_bits: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, int]:
    """Run the full 2-stage streamed-rate pipeline and return:
    (wl_stream_stage0 [T, 196], wl_stream_stage1 [T, 64], counts [10], predicted)."""
    # Stage 0 input encoding
    wl_stream_0 = encode_pixel_to_spike_stream(pixel, T, method="even_rate")
    # Stage 0 forward
    w_pos0, w_neg0 = stage_weights[0]
    counts0, _, spike_stream_0 = _run_stage_streamed_rate(
        stages[0], wl_stream_0, w_pos0, w_neg0,
        sum_max=stages[0].in_dim * 15, adc_bits=adc_bits,
    )
    # Stage 1 forward — wl_stream = stage 0 spike stream
    w_pos1, w_neg1 = stage_weights[1]
    counts1, _, _ = _run_stage_streamed_rate(
        stages[1], spike_stream_0, w_pos1, w_neg1,
        sum_max=stages[1].in_dim * 15, adc_bits=adc_bits,
    )
    predicted = int(counts1.argmax())
    return wl_stream_0, spike_stream_0, counts1, predicted


def main(num_samples: int = 10) -> int:
    topo_file = load_topology_file(ROOT / "topologies.yaml")
    topo = get_topology_by_name(topo_file.topologies, "196_64_10")
    assert topo.dataset == "fashion_mnist"
    assert topo.input_encoding == "streamed_rate"
    T = int(topo.stream_timesteps)          # 64
    adc_bits = int(topo.adc_bits)           # 10

    # Load P4 trained model (overnight run)
    model_path = resolve_best_or_final_model_path(
        ROOT / "results_multilayer" / "196_64_10" / "model.pt"
    )
    if not model_path.exists():
        print(f"[FATAL] model not found: {model_path}")
        return 1
    state = torch.load(model_path, map_location="cpu", weights_only=False)
    if isinstance(state, dict) and "state_dict" in state:
        sd = state["state_dict"]
    else:
        sd = state

    # Quantise weights per stage (re-use exporter helpers to stay bit-consistent)
    levels = _get_device_levels_for_export(2 ** cfg.QAT_WEIGHT_BITS)
    stage_weights = []
    for i, stage in enumerate(topo.stages):
        key = f"layers.{i}.weight"
        if key not in sd:
            print(f"[FATAL] missing key {key} in model state_dict")
            return 1
        w = sd[key]
        g_pos, g_neg = _quantize_stage_weights(w, cfg.QAT_WEIGHT_BITS, levels)
        stage_weights.append((g_pos, g_neg))
        print(f"[info] stage {i}: {stage.in_dim}->{stage.out_dim}, "
              f"w_pos shape {g_pos.shape}, nonzero pos={np.count_nonzero(g_pos)}, "
              f"nonzero neg={np.count_nonzero(g_neg)}")

    # Load Fashion test set, pick num_samples images (class-major, one per class)
    data_dir = str(cfg.ROOT_DIR / "data")
    x_test, y_test = v1_data.load_fashion_mnist_test(
        data_dir, target_size=14, method="avgpool"
    )
    # Already downsampled to 14x14 -> flattened 196 per image
    x_pool_flat = x_test.numpy().astype(np.int64) if hasattr(x_test, "numpy") else np.asarray(x_test).astype(np.int64)
    if x_pool_flat.ndim == 3:
        x_pool_flat = x_pool_flat.reshape(-1, 14 * 14)
    y_test = y_test.numpy() if hasattr(y_test, "numpy") else np.asarray(y_test)

    # Pick one sample per class (class 0..9); first occurrence
    chosen_idx = []
    for cls in range(10):
        hits = np.where(y_test == cls)[0]
        if len(hits) == 0:
            print(f"[FATAL] no Fashion test sample for class {cls}")
            return 1
        chosen_idx.append(int(hits[0]))
    chosen_idx = chosen_idx[:num_samples]

    out_dir = ROOT / "results_multilayer" / "fashion_multilayer_golden"
    out_dir.mkdir(parents=True, exist_ok=True)

    # Dump stage weight hex
    dump_weight_hex(out_dir / "stage0_w_pos.hex", stage_weights[0][0])
    dump_weight_hex(out_dir / "stage0_w_neg.hex", stage_weights[0][1])
    dump_weight_hex(out_dir / "stage1_w_pos.hex", stage_weights[1][0])
    dump_weight_hex(out_dir / "stage1_w_neg.hex", stage_weights[1][1])

    # Run each sample + dump
    for k, idx in enumerate(chosen_idx):
        pixel = x_pool_flat[idx]
        label = int(y_test[idx])
        # Create FakeStage objects for engine (pydantic StageConfig has extra metadata)
        s0 = FakeStage(topo.stages[0].in_dim, topo.stages[0].out_dim, topo.stages[0].threshold)
        s1 = FakeStage(topo.stages[1].in_dim, topo.stages[1].out_dim, topo.stages[1].threshold)
        wl0, wl1, counts, predicted = run_2stage_golden(
            pixel, stage_weights, [s0, s1], T=T, adc_bits=adc_bits,
        )
        tag = f"sample_{k:02d}"
        # Stage-0 WL stream (196 bits wide, zero-padded to 256 for RTL input_stream_sram)
        dump_wl_stream_hex(out_dir / f"{tag}_wl_stream.hex", wl0, pad_width=256)
        # Counts (10 ints)
        with (out_dir / f"{tag}_counts.txt").open("w") as f:
            for c in counts:
                f.write(f"{int(c)}\n")
        with (out_dir / f"{tag}_predicted.txt").open("w") as f:
            f.write(f"{predicted}\n")
        with (out_dir / f"{tag}_label.txt").open("w") as f:
            f.write(f"{label}\n")
        print(f"[sample {k}] idx={idx} label={label} predicted={predicted} counts={counts.tolist()}")

    # Meta
    with (out_dir / "meta.txt").open("w") as f:
        f.write(f"topology 196_64_10\n")
        f.write(f"T {T}\n")
        f.write(f"adc_bits {adc_bits}\n")
        f.write(f"num_samples {len(chosen_idx)}\n")
        f.write(f"stage0_in_dim {topo.stages[0].in_dim}\n")
        f.write(f"stage0_out_dim {topo.stages[0].out_dim}\n")
        f.write(f"stage0_threshold {topo.stages[0].threshold}\n")
        f.write(f"stage0_sum_max {topo.stages[0].in_dim * 15}\n")
        f.write(f"stage1_in_dim {topo.stages[1].in_dim}\n")
        f.write(f"stage1_out_dim {topo.stages[1].out_dim}\n")
        f.write(f"stage1_threshold {topo.stages[1].threshold}\n")
        f.write(f"stage1_sum_max {topo.stages[1].in_dim * 15}\n")

    print(f"[done] wrote {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main(num_samples=10))
