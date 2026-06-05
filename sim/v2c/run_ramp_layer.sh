#!/usr/bin/env bash
# V2C ramp (multi-bit bit-serial) input-layer parity: v2c_ramp_layer.sv vs convert._ramp_hidden_times.
# Bit-exact z1 (bit-serial MAC) + hidden spike_times (ramp TTFS). FULL-FRAME (the hidden layer produces
# ALL spike times for the next layer — early-exit belongs to the output layer). W in {1,2,4}.
set -euo pipefail
cd "$(dirname "$0")/../.."
PY=./.venv-v2c/bin/python
RTL="rtl/v2c/v2c_cim_mac.sv rtl/v2c/v2c_ramp_layer.sv"
TB=tb/v2c/v2c_ramp_layer_tb.sv
GEN=tb/v2c/gen_ramp_layer_vectors.py
DIR=sim/v2c/build/ramp
mkdir -p "$DIR"
fail=0
run() {  # IN OUT W T IN_BITS NSEEDS
    iverilog -g2012 -D V2C_IN_DIM="$1" -D V2C_OUT_DIM="$2" -D V2C_W="$3" -D V2C_T="$4" \
             -D V2C_IN_BITS="$5" -o sim/v2c/build/ramp.vvp $RTL "$TB"
    local s
    for s in $(seq 1 "$6"); do
        "$PY" "$GEN" "$1" "$2" "$3" "$4" "$5" 0 "$s" "$DIR" >/dev/null   # arg6=EARLY (unused, full-frame)
        out=$(vvp -n sim/v2c/build/ramp.vvp)
        echo "$out" | grep -E "^(PASS|FAIL)"
        echo "$out" | grep -q "^PASS" || fail=1
    done
}
run 64  8  4 8  4 5
run 64  8  1 8  4 3
run 64  8  2 8  4 3
run 256 32 4 16 4 3            # bigger hidden-dim config
if [ "$fail" -eq 0 ]; then echo "== ALL v2c_ramp_layer parity PASS =="; else echo "== v2c_ramp_layer parity FAIL =="; exit 1; fi
