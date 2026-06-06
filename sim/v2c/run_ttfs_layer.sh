#!/usr/bin/env bash
# V2C TTFS-IF layer parity: v2c_ttfs_layer.sv vs Python forward.ttfs_layer_forward. Bit-exact
# spike_times + membrane + n_steps, across W in {1,2,4}, early-exit on/off, + output-layer config.
set -euo pipefail
cd "$(dirname "$0")/../.."
PY=./.venv-v2c/bin/python
RTL="rtl/v2c/v2c_cim_mac.sv rtl/v2c/v2c_ttfs_layer.sv"
TB=tb/v2c/v2c_ttfs_layer_tb.sv
GEN=tb/v2c/gen_ttfs_layer_vectors.py
DIR=sim/v2c/build/ttfs
mkdir -p "$DIR"
fail=0
run() {  # IN OUT W T EARLY NSEEDS
    iverilog -g2012 -D V2C_IN_DIM="$1" -D V2C_OUT_DIM="$2" -D V2C_W="$3" -D V2C_T="$4" \
             -D V2C_EARLY="$5" -o sim/v2c/build/ttfs.vvp $RTL "$TB"
    local s
    for s in $(seq 1 "$6"); do
        "$PY" "$GEN" "$1" "$2" "$3" "$4" "$5" "$s" "$DIR" >/dev/null
        out=$(vvp -n sim/v2c/build/ttfs.vvp)
        echo "$out" | grep -E "^(PASS|FAIL)"
        echo "$out" | grep -q "^PASS" || fail=1
    done
}
run 64  8  4 8  0 4
run 64  8  4 8  1 4
run 64  8  1 8  0 3
run 64  8  2 8  0 3
run 784 10 4 16 0 2          # large-IN smoke (full-frame) — stresses IN_DIM, not the real output layer
run 784 10 4 16 1 2          # large-IN smoke (early-exit)
run 246 10 4 16 0 2          # PRODUCTION output layer (246->10, full-frame) — exact main-net dims
run 246 10 4 16 1 2          # PRODUCTION output layer (246->10, early-exit)
if [ "$fail" -eq 0 ]; then echo "== ALL v2c_ttfs_layer parity PASS =="; else echo "== v2c_ttfs_layer parity FAIL =="; exit 1; fi
