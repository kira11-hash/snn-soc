#!/usr/bin/env python3
"""Generate Config #5 board-equivalent Python baseline artifacts.

This script defines the baseline contract for Config #5 board closure:

- stage 0 uses V2.B tiled FC semantics
- tile split follows the live hardware WL cap (`HW_NUM_INPUTS = 256`)
- each stage-0 tile uses the fixed full-stage `sum_max = 784 * 15`
- stage 1 remains the standard streamed-rate 64 -> 10 stage

Outputs are written to the declared archive path:

`audit-v2/h1_closeout_logs/config5_board_verify_2026_05_10/python_baseline/`

Artifacts:

- `trace_hash_python.log`
- `stage{0,1}_w_{pos,neg}.hex` (copied from sim-only bundle)
- `sample_XX_wl_stream.hex`     (copied from sim-only bundle)
- `sample_XX_counts.txt`        (board-equivalent counts)
- `sample_XX_predicted.txt`     (board-equivalent argmax)
- `sample_XX_label.txt`         (ground-truth label)
- `meta.txt`
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

import numpy as np

from snn_engine_multilayer import _run_stage_streamed_rate, _run_stage_streamed_rate_tiled
from topologies import HW_NUM_INPUTS, get_topology_by_name, load_topology_file


ROOT = Path(__file__).resolve().parent
BUNDLE_DIR = ROOT / "results_multilayer" / "fashion28_multilayer_golden"
ARCHIVE_DIR = ROOT.parent / "h1_closeout_logs" / "config5_board_verify_2026_05_10" / "python_baseline"
CONFIG_ID = "v2b_fc_fashion28_2L"
TOPO_NAME = "784_64_10"
STAGE0_FIXED_SUM_MAX = 784 * 15
CRC32_POLY_REFLECTED = 0xEDB88320
CRC32_INIT = 0xFFFFFFFF
CRC32_XOROUT = 0xFFFFFFFF
TRACE_SPIKE_WIDTH = 128


def load_weights_hex(path: Path, rows: int, cols: int) -> np.ndarray:
    vals = [int(line.strip(), 16) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    arr = np.asarray(vals, dtype=np.int64)
    if arr.size != rows * cols:
        raise ValueError(f"{path}: got {arr.size} values, expected {rows * cols}")
    return arr.reshape(rows, cols)


def load_wl_stream(path: Path, pad_width: int) -> np.ndarray:
    lines = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    out = np.zeros((len(lines), pad_width), dtype=np.int64)
    for t, line in enumerate(lines):
        value = int(line, 16)
        for i in range(pad_width):
            out[t, i] = (value >> i) & 1
    return out


def crc32_trace_hash(layer_id: int, t_idx: int, buf_sel: int, spike_bits_128: int) -> int:
    data = spike_bits_128
    data |= (int(t_idx) & 0xFF) << TRACE_SPIKE_WIDTH
    data |= (int(buf_sel) & 0x1) << (TRACE_SPIKE_WIDTH + 8)
    data |= (int(layer_id) & 0x7) << (TRACE_SPIKE_WIDTH + 8 + 1)
    width = TRACE_SPIKE_WIDTH + 8 + 1 + 3

    crc = CRC32_INIT
    for bit_idx in range(width):
        bit = (data >> bit_idx) & 1
        feedback = (crc & 1) ^ bit
        crc >>= 1
        if feedback:
            crc ^= CRC32_POLY_REFLECTED
    return crc ^ CRC32_XOROUT


def row_to_int(row: np.ndarray) -> int:
    value = 0
    for i, bit in enumerate(np.asarray(row, dtype=np.int64).reshape(-1)):
        if int(bit):
            value |= 1 << i
    return value


def emit_block(fp, sample_id: int, stage0_stream: np.ndarray, stage1_stream: np.ndarray) -> None:
    fp.write(f"TRACE_HASH_BEGIN config={CONFIG_ID} host=python sample={sample_id}\n")
    count = 0
    for t_idx in range(stage0_stream.shape[0]):
        hash_word = crc32_trace_hash(0, t_idx, 0, row_to_int(stage0_stream[t_idx]))
        fp.write(f"HASH layer=0 t={t_idx} buf=A 0x{hash_word:08X}\n")
        count += 1
    for t_idx in range(stage1_stream.shape[0]):
        hash_word = crc32_trace_hash(1, t_idx, 1, row_to_int(stage1_stream[t_idx]))
        fp.write(f"HASH layer=1 t={t_idx} buf=B 0x{hash_word:08X}\n")
        count += 1
    fp.write(f"TRACE_HASH_END count={count}\n")


def compute_config5_board_equivalent(sample_id: int) -> tuple[np.ndarray, np.ndarray, np.ndarray, int, int]:
    topo = get_topology_by_name(load_topology_file(ROOT / "topologies.yaml").topologies, TOPO_NAME)
    stage0 = topo.stages[0]
    stage1 = topo.stages[1]
    pad_width = ((stage0.in_dim + HW_NUM_INPUTS - 1) // HW_NUM_INPUTS) * HW_NUM_INPUTS

    w0_pos = load_weights_hex(BUNDLE_DIR / "stage0_w_pos.hex", stage0.in_dim, stage0.out_dim)
    w0_neg = load_weights_hex(BUNDLE_DIR / "stage0_w_neg.hex", stage0.in_dim, stage0.out_dim)
    w1_pos = load_weights_hex(BUNDLE_DIR / "stage1_w_pos.hex", stage1.in_dim, stage1.out_dim)
    w1_neg = load_weights_hex(BUNDLE_DIR / "stage1_w_neg.hex", stage1.in_dim, stage1.out_dim)

    wl_full = load_wl_stream(BUNDLE_DIR / f"sample_{sample_id:02d}_wl_stream.hex", pad_width)
    label = int((BUNDLE_DIR / f"sample_{sample_id:02d}_label.txt").read_text(encoding="utf-8").strip())

    wl_tiles: list[np.ndarray] = []
    w0_pos_tiles: list[np.ndarray] = []
    w0_neg_tiles: list[np.ndarray] = []
    sum_max_tiles: list[int] = []
    for tile_start in range(0, stage0.in_dim, HW_NUM_INPUTS):
        tile_stop = min(tile_start + HW_NUM_INPUTS, stage0.in_dim)
        wl_tiles.append(wl_full[:, tile_start:tile_stop].copy())
        w0_pos_tiles.append(w0_pos[tile_start:tile_stop, :].copy())
        w0_neg_tiles.append(w0_neg[tile_start:tile_stop, :].copy())
        # Tiled hardware applies ADC on each tile before cross-tile
        # accumulation. Using the historical full-stage sum_max on every tile
        # keeps the tiled path much closer to the original Config #5 decision
        # surface than per-tile active_wl scaling, while staying firmware-only.
        sum_max_tiles.append(STAGE0_FIXED_SUM_MAX)

    _, _, stage0_stream = _run_stage_streamed_rate_tiled(
        stage0,
        wl_tiles,
        w0_pos_tiles,
        w0_neg_tiles,
        sum_max_tiles,
        adc_bits=topo.adc_bits,
        stage_idx=0,
    )
    stage1_counts, _, stage1_stream = _run_stage_streamed_rate(
        stage1,
        stage0_stream,
        w1_pos,
        w1_neg,
        sum_max=960,
        adc_bits=topo.adc_bits,
        stage_idx=1,
    )
    pred = int(np.argmax(stage1_counts))
    return stage0_stream, stage1_stream, stage1_counts.astype(np.int64), pred, label


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default=str(ARCHIVE_DIR / "trace_hash_python.log"))
    args = ap.parse_args()

    out_path = Path(args.out)
    baseline_dir = out_path.parent
    baseline_dir.mkdir(parents=True, exist_ok=True)

    for name in ("stage0_w_pos.hex", "stage0_w_neg.hex", "stage1_w_pos.hex", "stage1_w_neg.hex"):
        shutil.copyfile(BUNDLE_DIR / name, baseline_dir / name)

    with out_path.open("w", encoding="utf-8", newline="\n") as fp:
        for sample_id in range(10):
            stage0_stream, stage1_stream, stage1_counts, pred, label = compute_config5_board_equivalent(sample_id)
            emit_block(fp, sample_id, stage0_stream, stage1_stream)

            shutil.copyfile(BUNDLE_DIR / f"sample_{sample_id:02d}_wl_stream.hex",
                            baseline_dir / f"sample_{sample_id:02d}_wl_stream.hex")
            (baseline_dir / f"sample_{sample_id:02d}_counts.txt").write_text(
                "\n".join(str(int(v)) for v in stage1_counts) + "\n",
                encoding="utf-8",
            )
            (baseline_dir / f"sample_{sample_id:02d}_predicted.txt").write_text(f"{pred}\n", encoding="utf-8")
            (baseline_dir / f"sample_{sample_id:02d}_label.txt").write_text(f"{label}\n", encoding="utf-8")

    (baseline_dir / "meta.txt").write_text(
        "\n".join(
            [
                f"config_id {CONFIG_ID}",
                "baseline_kind board_tiled_fixed_stage0_summax",
                f"tile_cap {HW_NUM_INPUTS}",
                f"stage0_tile_sum_max {STAGE0_FIXED_SUM_MAX}",
                "tile_sum_max_policy fixed_full_stage_sum_max",
                "stage1_sum_max 960",
                "trace_hash_host python",
            ]
        ) + "\n",
        encoding="utf-8",
    )
    print(f"[config5_trace_baseline] wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
