"""Bit-exact parity vectors for v2c_ttfs_layer from the Python golden forward.ttfs_layer_forward.

Usage: gen_ttfs_layer_vectors.py IN_DIM OUT_DIM W T EARLY SEED OUTDIR
Writes (for one frame): cells.hex (OUT_DIM*W cols), spike.hex (T steps), thr.hex (OUT_DIM, per-output
integer threshold), expected.txt (n_steps + per-output "spike_time membrane"; spike_time=-1 if none).
Each input fires at most once (valid TTFS stream). Thresholds ~ half the |full-frame membrane| so some
outputs fire and some never, exercising fire / no-fire / early-exit.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "python_multilayer", "v2c"))
import numpy as np  # noqa: E402
import encoding as enc  # noqa: E402
import forward as fwd  # noqa: E402


def bits_to_int(bits) -> int:
    b = np.asarray(bits)
    return int("".join("1" if x else "0" for x in b[::-1]), 2) if b.size else 0


def main():
    IN_DIM, OUT_DIM, W, T, EARLY, SEED, OUTDIR = (int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]),
                                                  int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]),
                                                  sys.argv[7])
    rng = np.random.default_rng(SEED)
    lo, hi = enc.value_range(W)
    w = rng.integers(lo, hi + 1, size=(IN_DIM, OUT_DIM)).astype(np.int64)
    if W == 1:
        w[w == 0] = 1
    cells = enc.pack(w, W)                                          # [IN_DIM, OUT_DIM*W]
    times = rng.integers(0, T + 1, size=IN_DIM)                     # T == no spike
    stream = np.zeros((T, IN_DIM), dtype=np.uint8)
    for i in range(IN_DIM):
        if times[i] < T:
            stream[times[i], i] = 1
    mem_full = np.zeros(OUT_DIM, dtype=np.int64)
    for t in range(T):
        mem_full += enc.mac(stream[t], cells, W, OUT_DIM)
    thr = np.maximum(1, (0.5 * np.abs(mem_full)).astype(np.int64))  # mixed fire / no-fire
    st, membrane, nsteps = fwd.ttfs_layer_forward(stream, cells, W, OUT_DIM, thr, early_exit=bool(EARLY))

    os.makedirs(OUTDIR, exist_ok=True)
    with open(os.path.join(OUTDIR, "cells.hex"), "w") as f:
        for c in range(OUT_DIM * W):
            f.write(f"{bits_to_int(cells[:, c]):x}\n")
    with open(os.path.join(OUTDIR, "spike.hex"), "w") as f:
        for t in range(T):
            f.write(f"{bits_to_int(stream[t]):x}\n")
    with open(os.path.join(OUTDIR, "thr.hex"), "w") as f:
        for o in range(OUT_DIM):
            f.write(f"{int(thr[o]):x}\n")
    with open(os.path.join(OUTDIR, "expected.txt"), "w") as f:
        f.write(f"{int(nsteps)}\n")
        for o in range(OUT_DIM):
            f.write(f"{int(st[o])} {int(membrane[o])}\n")
    print(f"frame seed={SEED}: nsteps={nsteps} fired={int((st>=0).sum())}/{OUT_DIM}")


if __name__ == "__main__":
    main()
