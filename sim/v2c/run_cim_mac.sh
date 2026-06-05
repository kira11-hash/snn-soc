#!/usr/bin/env bash
# V2C CIM-MAC parity: v2c_cim_mac.sv vs Python golden encoding.mac, across W in {1,2,4,8} + the
# production IN_DIM=784/W=4 config. Bit-exact in ideal mode (plan-v1.md). Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")/../.."                       # repo root
PY=./.venv-v2c/bin/python
RTL=rtl/v2c/v2c_cim_mac.sv
TB=tb/v2c/v2c_cim_mac_tb.sv
GEN=tb/v2c/gen_cim_mac_vectors.py
mkdir -p sim/v2c/build
fail=0
run() {  # IN_DIM W OUT_DIM N
    "$PY" "$GEN" "$1" "$2" "$3" "$4" sim/v2c/build/cim_mac.vec >/dev/null
    iverilog -g2012 -D V2C_IN_DIM="$1" -D V2C_W="$2" -o sim/v2c/build/cim_mac.vvp "$RTL" "$TB"
    out=$(vvp -n sim/v2c/build/cim_mac.vvp)
    echo "$out"
    echo "$out" | grep -q "^PASS" || fail=1
}
run 64  1 6 20
run 64  2 6 20
run 64  4 6 20
run 64  8 6 20
run 784 4 4 12                                   # production single-macro config
if [ "$fail" -eq 0 ]; then echo "== ALL v2c_cim_mac parity PASS =="; else echo "== v2c_cim_mac parity FAIL =="; exit 1; fi
