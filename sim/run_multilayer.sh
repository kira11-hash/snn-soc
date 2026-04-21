#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
. "$(pwd)/common_iverilog_env.sh"
resolve_iverilog_tools

echo "[run_multilayer.sh] Compiling with +define+SIM_MULTI_LAYER ..."
mkdir -p waves

run_iverilog -g2012 -gno-assertions \
  -DSIM_MULTI_LAYER \
  -DFPGA_BEHAVIORAL \
  -f sim_multilayer.f \
  -s multilayer_tb \
  -o sim_multilayer.out 2>&1

echo "[run_multilayer.sh] Running ..."
SIM_LOG=$(run_vvp sim_multilayer.out 2>&1)
echo "$SIM_LOG"

if echo "$SIM_LOG" | grep -q "MULTILAYER_SMOKE_PASS"; then
  echo "[run_multilayer.sh] >>> MULTILAYER_SMOKE_PASS <<<"
else
  echo "[run_multilayer.sh] >>> FAIL <<<"
  exit 1
fi
