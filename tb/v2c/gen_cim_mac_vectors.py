"""Generate bit-exact parity vectors for v2c_cim_mac from the Python golden encoding.mac.

Usage: gen_cim_mac_vectors.py IN_DIM W OUT_DIM N OUT_PATH
Each test draws random in-range weights -> encoding.pack -> cells, random spikes, and the golden
encoding.mac partial sum per output. Emits one line per (test, output):
    <spikes_hex> <cells_flat_hex> <expected_decimal>
where spikes_hex = sum_row spike[row]<<row, and cells_flat bit (k*IN_DIM+row) = cells[row, out*W+k]
(matches the RTL port ``cells_flat[k*IN_DIM +: IN_DIM] = column k``). First line: "IN_DIM W NLINES".
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "python_multilayer", "v2c"))
import numpy as np  # noqa: E402
import encoding as enc  # noqa: E402


def bits_to_int(bits) -> int:
    """bits[i] = bit i (LSB first) -> integer."""
    return int("".join("1" if b else "0" for b in np.asarray(bits)[::-1]), 2) if len(bits) else 0


def main():
    IN_DIM, W, OUT_DIM, N, out_path = (int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]),
                                       int(sys.argv[4]), sys.argv[5])
    rng = np.random.default_rng(0xC1A)
    lo, hi = enc.value_range(W)
    lines = []

    def add_case(w, spikes):
        cells = enc.pack(w, W)                                      # [IN_DIM, OUT_DIM*W]
        golden = enc.mac(spikes, cells, W, OUT_DIM)                 # [OUT_DIM] int64
        s_int = bits_to_int(spikes)
        for o in range(OUT_DIM):
            cf = 0
            for k in range(W):
                cf |= bits_to_int(cells[:, o * W + k]) << (k * IN_DIM)
            lines.append(f"{s_int:x} {cf:x} {int(golden[o])}")

    # deterministic edge cases: all-zero / all-one / alternating spikes × extreme (max+/min) weights —
    # stress the accumulator range + signedness (MSB-negated two's-comp / popcount-difference).
    wmax = np.full((IN_DIM, OUT_DIM), hi, np.int64)
    wmin = np.full((IN_DIM, OUT_DIM), -1 if W == 1 else lo, np.int64)
    z = np.zeros(IN_DIM, np.uint8); ones = np.ones(IN_DIM, np.uint8)
    alt = (np.arange(IN_DIM) % 2).astype(np.uint8)
    for w in (wmax, wmin):
        for sp in (z, ones, alt):
            add_case(w, sp)

    for _ in range(N):
        w = rng.integers(lo, hi + 1, size=(IN_DIM, OUT_DIM)).astype(np.int64)
        if W == 1:
            w[w == 0] = 1                                            # BNN has no 0
        spikes = rng.integers(0, 2, size=IN_DIM).astype(np.uint8)
        add_case(w, spikes)
    with open(out_path, "w") as f:
        f.write(f"{IN_DIM} {W} {len(lines)}\n")
        f.write("\n".join(lines) + "\n")
    print(f"wrote {len(lines)} vectors -> {out_path} (IN_DIM={IN_DIM} W={W} OUT_DIM={OUT_DIM} N={N})")


if __name__ == "__main__":
    main()
