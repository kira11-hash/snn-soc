"""Bit-exact parity vectors for v2c_ramp_layer from convert._ramp_hidden_times (eval_ttfs_ramp 1st layer).

Usage: gen_ramp_layer_vectors.py IN_DIM OUT_DIM W T IN_BITS EARLY SEED OUTDIR
Writes: cells.hex (OUT_DIM*W weight cols), bitplane.hex (IN_BITS lines = input bit-k of every pixel),
thr.hex (OUT_DIM), expected.txt (OUT_DIM lines "z1 hid_spike_time"; spike_time=-1 if none). z1 =
sum_k 2^k*mac(bitplane_k). Per-output threshold ~ random fraction of T*|z1| so outputs fire early/mid/
late/never (z1<=0 never fires).
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "python_multilayer", "v2c"))
import numpy as np  # noqa: E402
import encoding as enc  # noqa: E402
import convert as C  # noqa: E402


def bits_to_int(bits) -> int:
    b = np.asarray(bits)
    return int("".join("1" if x else "0" for x in b[::-1]), 2) if b.size else 0


def main():
    (IN_DIM, OUT_DIM, W, T, IN_BITS, EARLY, SEED, OUTDIR) = (
        int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]),
        int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]), sys.argv[8])
    rng = np.random.default_rng(SEED)
    lo, hi = enc.value_range(W)
    w = rng.integers(lo, hi + 1, size=(IN_DIM, OUT_DIM)).astype(np.int64)
    if W == 1:
        w[w == 0] = 1
    cells = enc.pack(w, W)
    levels = (1 << IN_BITS) - 1
    v = rng.integers(0, levels + 1, size=IN_DIM).astype(np.int64)       # multi-bit pixel values
    z1 = np.zeros(OUT_DIM, dtype=np.int64)
    for k in range(IN_BITS):
        z1 += (1 << k) * enc.mac(((v >> k) & 1).astype(np.uint8), cells, W, OUT_DIM)
    frac = rng.uniform(0.1, 1.3, size=OUT_DIM)
    thr = np.maximum(1, (frac * T * np.abs(z1)).astype(np.int64))       # mixed fire-time / never
    hid_times = C._ramp_hidden_times(v, cells, W, OUT_DIM, thr, T, IN_BITS)

    os.makedirs(OUTDIR, exist_ok=True)
    with open(os.path.join(OUTDIR, "cells.hex"), "w") as f:
        for c in range(OUT_DIM * W):
            f.write(f"{bits_to_int(cells[:, c]):x}\n")
    with open(os.path.join(OUTDIR, "bitplane.hex"), "w") as f:
        for k in range(IN_BITS):
            f.write(f"{bits_to_int(((v >> k) & 1)):x}\n")
    with open(os.path.join(OUTDIR, "thr.hex"), "w") as f:
        for o in range(OUT_DIM):
            f.write(f"{int(thr[o]):x}\n")
    with open(os.path.join(OUTDIR, "expected.txt"), "w") as f:
        for o in range(OUT_DIM):
            f.write(f"{int(z1[o])} {int(hid_times[o])}\n")
    print(f"seed={SEED}: fired={int((hid_times>=0).sum())}/{OUT_DIM} z1range=[{z1.min()},{z1.max()}]")


if __name__ == "__main__":
    main()
