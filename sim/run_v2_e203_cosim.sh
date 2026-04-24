#!/usr/bin/env bash
# sim/run_v2_e203_cosim.sh
# Phase A-7 cosim: full-top + DMEM marker + PC check.
# PASS tag: V2_E203_COSIM_PASS
#
# 前置：必须先构建固件 hex：
#   wsl bash -c "cd '/mnt/d/SoC Design/SoC Design/fw/v2_e203_smoke' && bash build_v2_e203_smoke.sh"

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

mkdir -p waves

HEX="../fw/v2_e203_smoke/out/v2_e203_smoke.hex"
if [ ! -f "$HEX" ]; then
  echo "[ERR] firmware hex not found: $HEX"
  echo "      run: wsl bash -c \"cd '/mnt/d/SoC Design/SoC Design/fw/v2_e203_smoke' && bash build_v2_e203_smoke.sh\""
  exit 1
fi

echo "[INFO] Compiling v2_e203 cosim TB (Icarus)..."
run_iverilog -g2012 -gno-assertions \
         -o v2_e203_cosim_test \
         -f sim_v2_e203_cosim.f \
         2>&1 | tee v2_e203_cosim_compile.log

echo "[INFO] Running cosim..."
run_vvp v2_e203_cosim_test 2>&1 | tee v2_e203_cosim_sim.log

echo ""
if grep -q "V2_E203_COSIM_PASS" v2_e203_cosim_sim.log; then
  echo "[RESULT] V2_E203_COSIM_PASS"
else
  echo "[RESULT] V2_E203_COSIM_FAIL"
  exit 1
fi
