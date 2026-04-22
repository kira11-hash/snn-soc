#!/usr/bin/env python3
"""Generate `golden_fashion10.h` + `.c` for Phase B ARM firmware.

Reads `python_multilayer/results_multilayer/fashion_multilayer_golden/` and
`python_multilayer/...` test data, re-computes per-sample raw pixels (uint8
[0..255]) + pre-encoded WL stream + expected counts, and emits a C header
the ARM standalone app can `#include`.

Emitted symbols (see `golden_fashion10.h`):
  - golden_s0_w_packed[196*64]  (4-bit packed: {neg[7:4], pos[3:0]} per byte)
  - golden_s1_w_packed[64 *10]
  - golden_fashion10[10]: array of {pixel_196[], encoded_stream[T*8_u32],
                                    expected_counts[10], expected_class}

Invocation:
    python fw/arm/scripts/gen_golden_header.py
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
PY_ML = ROOT / "python_multilayer"
GOLDEN_DIR = PY_ML / "results_multilayer" / "fashion_multilayer_golden"
OUT_INC = ROOT / "fw" / "arm" / "include" / "golden_fashion10.h"
OUT_SRC = ROOT / "fw" / "arm" / "src" / "golden_fashion10.c"

S0_IN = 196
S0_OUT = 64
S1_IN = 64
S1_OUT = 10
T = 64
WORDS_PER_ROW = 8   # 256 bits / 32
NUM_SAMPLES = 10


def load_weights_hex(path: Path, rows: int, cols: int) -> np.ndarray:
    """Each line is one 4-bit hex digit; shape [rows, cols] row-major."""
    with path.open() as f:
        vals = [int(line.strip(), 16) for line in f if line.strip()]
    arr = np.asarray(vals, dtype=np.uint8)
    assert arr.size == rows * cols, f"{path}: got {arr.size} expected {rows*cols}"
    return arr.reshape(rows, cols)


def pack_weights(w_pos: np.ndarray, w_neg: np.ndarray) -> np.ndarray:
    """Pack two 4-bit arrays into one byte: {neg[7:4], pos[3:0]}. Flat row-major."""
    assert w_pos.shape == w_neg.shape
    packed = ((w_neg & 0x0F) << 4) | (w_pos & 0x0F)
    return packed.flatten().astype(np.uint8)


def load_wl_stream_hex(path: Path) -> np.ndarray:
    """Load T lines of 64-hex-char strings (256 bits each).
    Returns shape [T, 8] uint32 (LSB=word0 covers bits 0..31)."""
    with path.open() as f:
        lines = [line.strip() for line in f if line.strip()]
    assert len(lines) == T, f"{path}: got {len(lines)} lines expected {T}"
    out = np.zeros((T, WORDS_PER_ROW), dtype=np.uint32)
    for t, line in enumerate(lines):
        # Each line is 64 hex chars = 256 bits, MSB-first in string.
        val = int(line, 16)
        for w in range(WORDS_PER_ROW):
            out[t, w] = (val >> (32 * w)) & 0xFFFFFFFF
    return out


def load_counts(path: Path) -> np.ndarray:
    with path.open() as f:
        vals = [int(line.strip()) for line in f if line.strip()]
    assert len(vals) == S1_OUT
    return np.asarray(vals, dtype=np.int32)


def load_pixels_for_sample(k: int) -> np.ndarray:
    """Re-run `gen_multilayer_fashion_golden.py` style pixel selection: load
    the Fashion-MNIST avgpool-14x14 test set via _vendored_from_v1.data_utils,
    pick the k-th class's first occurrence. Returns uint8 [196]."""
    if str(PY_ML) not in sys.path:
        sys.path.insert(0, str(PY_ML))
    import _vendored_from_v1.data_utils as v1_data  # type: ignore
    import config_multilayer as cfg  # type: ignore
    data_dir = str(cfg.ROOT_DIR / "data")
    x_test, y_test = v1_data.load_fashion_mnist_test(
        data_dir, target_size=14, method="avgpool"
    )
    x = x_test.numpy() if hasattr(x_test, "numpy") else np.asarray(x_test)
    y = y_test.numpy() if hasattr(y_test, "numpy") else np.asarray(y_test)
    if x.ndim == 3:
        x = x.reshape(-1, 14 * 14)
    x = x.astype(np.int64)
    hits = np.where(y == k)[0]
    if len(hits) == 0:
        raise RuntimeError(f"No Fashion-MNIST test sample for class {k}")
    pix = x[int(hits[0])]
    # Clamp to uint8 (pre-avgpool values are already 0..255 for standard data)
    pix = np.clip(pix, 0, 255).astype(np.uint8)
    assert pix.shape == (S0_IN,), f"pixel shape {pix.shape} != ({S0_IN},)"
    return pix


def fmt_uint8_array(arr: np.ndarray, per_line: int = 16) -> str:
    lines = []
    for i in range(0, arr.size, per_line):
        chunk = arr[i : i + per_line]
        lines.append("  " + ", ".join(f"0x{v:02x}" for v in chunk) + ",")
    return "\n".join(lines)


def fmt_uint32_array(arr: np.ndarray, per_line: int = 8) -> str:
    lines = []
    for i in range(0, arr.size, per_line):
        chunk = arr[i : i + per_line]
        lines.append("  " + ", ".join(f"0x{v:08x}" for v in chunk) + ",")
    return "\n".join(lines)


def fmt_int32_array(arr: np.ndarray) -> str:
    return "  " + ", ".join(str(int(v)) for v in arr)


def main() -> int:
    if not GOLDEN_DIR.exists():
        print(f"[FATAL] golden dir missing: {GOLDEN_DIR}", file=sys.stderr)
        return 1

    s0_pos = load_weights_hex(GOLDEN_DIR / "stage0_w_pos.hex", S0_IN, S0_OUT)
    s0_neg = load_weights_hex(GOLDEN_DIR / "stage0_w_neg.hex", S0_IN, S0_OUT)
    s1_pos = load_weights_hex(GOLDEN_DIR / "stage1_w_pos.hex", S1_IN, S1_OUT)
    s1_neg = load_weights_hex(GOLDEN_DIR / "stage1_w_neg.hex", S1_IN, S1_OUT)

    s0_packed = pack_weights(s0_pos, s0_neg)
    s1_packed = pack_weights(s1_pos, s1_neg)

    # Also dump the raw 4-bit arrays for firmware paths that want pos/neg
    # separate (v2b_load_mac_weights takes pos+neg separately).
    s0_pos_flat = s0_pos.flatten().astype(np.uint8)
    s0_neg_flat = s0_neg.flatten().astype(np.uint8)
    s1_pos_flat = s1_pos.flatten().astype(np.uint8)
    s1_neg_flat = s1_neg.flatten().astype(np.uint8)

    samples = []
    for k in range(NUM_SAMPLES):
        stream = load_wl_stream_hex(GOLDEN_DIR / f"sample_{k:02d}_wl_stream.hex")
        counts = load_counts(GOLDEN_DIR / f"sample_{k:02d}_counts.txt")
        pred_path = GOLDEN_DIR / f"sample_{k:02d}_predicted.txt"
        pred = int(pred_path.read_text().strip())
        pixels = load_pixels_for_sample(k)
        samples.append({
            "k": k,
            "pixels": pixels,
            "stream": stream,
            "counts": counts,
            "predicted": pred,
        })

    # ── Emit header ──
    OUT_INC.parent.mkdir(parents=True, exist_ok=True)
    OUT_SRC.parent.mkdir(parents=True, exist_ok=True)

    with OUT_INC.open("w", encoding="utf-8", newline="\n") as f:
        f.write(f"""\
/* AUTOGENERATED by fw/arm/scripts/gen_golden_header.py — do not hand-edit. */
/* Source: python_multilayer/results_multilayer/fashion_multilayer_golden/ */
#ifndef GOLDEN_FASHION10_H
#define GOLDEN_FASHION10_H

#include <stdint.h>

#define GOLDEN_S0_IN_DIM   {S0_IN}u
#define GOLDEN_S0_OUT_DIM  {S0_OUT}u
#define GOLDEN_S1_IN_DIM   {S1_IN}u
#define GOLDEN_S1_OUT_DIM  {S1_OUT}u
#define GOLDEN_T           {T}u
#define GOLDEN_WORDS_PER_ROW {WORDS_PER_ROW}u
#define GOLDEN_NUM_SAMPLES {NUM_SAMPLES}u

/* Packed layout: {{neg[7:4], pos[3:0]}} per 4-bit pair per byte. */
extern const uint8_t golden_s0_w_packed[{S0_IN} * {S0_OUT}];
extern const uint8_t golden_s1_w_packed[{S1_IN} * {S1_OUT}];

/* Raw pos/neg 4-bit arrays (flat row-major, one 4-bit level per byte) —
 * consumed by v2b_load_mac_weights() which takes pos/neg pointers separately. */
extern const uint8_t golden_s0_w_pos[{S0_IN} * {S0_OUT}];
extern const uint8_t golden_s0_w_neg[{S0_IN} * {S0_OUT}];
extern const uint8_t golden_s1_w_pos[{S1_IN} * {S1_OUT}];
extern const uint8_t golden_s1_w_neg[{S1_IN} * {S1_OUT}];

typedef struct {{
    uint8_t  pixel_196[{S0_IN}];                       /* raw uint8 pixels → C1 path */
    uint32_t encoded_stream[{T} * {WORDS_PER_ROW}];    /* pre-encoded WL stream → C0 path */
    int32_t  expected_counts[{S1_OUT}];                /* per-class spike counts */
    uint8_t  expected_class;                           /* argmax */
}} v2b_fashion_sample_t;

extern const v2b_fashion_sample_t golden_fashion10[{NUM_SAMPLES}];

#endif /* GOLDEN_FASHION10_H */
""")

    # ── Emit .c ──
    with OUT_SRC.open("w", encoding="utf-8", newline="\n") as f:
        f.write("/* AUTOGENERATED by fw/arm/scripts/gen_golden_header.py — do not hand-edit. */\n")
        f.write('#include "golden_fashion10.h"\n\n')

        f.write(f"const uint8_t golden_s0_w_packed[{S0_IN} * {S0_OUT}] = {{\n")
        f.write(fmt_uint8_array(s0_packed))
        f.write("\n};\n\n")

        f.write(f"const uint8_t golden_s1_w_packed[{S1_IN} * {S1_OUT}] = {{\n")
        f.write(fmt_uint8_array(s1_packed))
        f.write("\n};\n\n")

        f.write(f"const uint8_t golden_s0_w_pos[{S0_IN} * {S0_OUT}] = {{\n")
        f.write(fmt_uint8_array(s0_pos_flat))
        f.write("\n};\n\n")

        f.write(f"const uint8_t golden_s0_w_neg[{S0_IN} * {S0_OUT}] = {{\n")
        f.write(fmt_uint8_array(s0_neg_flat))
        f.write("\n};\n\n")

        f.write(f"const uint8_t golden_s1_w_pos[{S1_IN} * {S1_OUT}] = {{\n")
        f.write(fmt_uint8_array(s1_pos_flat))
        f.write("\n};\n\n")

        f.write(f"const uint8_t golden_s1_w_neg[{S1_IN} * {S1_OUT}] = {{\n")
        f.write(fmt_uint8_array(s1_neg_flat))
        f.write("\n};\n\n")

        f.write(f"const v2b_fashion_sample_t golden_fashion10[{NUM_SAMPLES}] = {{\n")
        for s in samples:
            f.write("  {\n")
            f.write("    .pixel_196 = {\n")
            f.write(fmt_uint8_array(s["pixels"]))
            f.write("\n    },\n")
            f.write("    .encoded_stream = {\n")
            f.write(fmt_uint32_array(s["stream"].flatten()))
            f.write("\n    },\n")
            f.write("    .expected_counts = {\n")
            f.write(fmt_int32_array(s["counts"]))
            f.write("\n    },\n")
            f.write(f"    .expected_class = {s['predicted']}u,\n")
            f.write("  },\n")
        f.write("};\n")

    print(f"[gen_golden_header] wrote {OUT_INC}")
    print(f"[gen_golden_header] wrote {OUT_SRC}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
