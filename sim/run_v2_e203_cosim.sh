#!/usr/bin/env bash
# sim/run_v2_e203_cosim.sh
# Phase A-7 cosim: full-top + DMEM marker + PC check.
# PASS tag: V2_E203_COSIM_PASS
#
# 默认使用 SIM_FAST=1 专用产物目录 `fw/v2_e203_smoke/out_simfast/`。
# 若 fast hex 缺失，脚本会自动调用：
#   wsl bash -c "cd '/mnt/d/SoC Design/SoC Design/fw/v2_e203_smoke' && SIM_FAST=1 NUM_COSIM_SAMPLES=3 bash build_v2_e203_smoke.sh"

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

cleanup() {
  cleanup_vendor_e203_alias
}
trap cleanup EXIT

ensure_vendor_e203_alias "$ROOT_DIR"

mkdir -p waves

HEX="../fw/v2_e203_smoke/out_simfast/v2_e203_smoke.hex"
if [ ! -f "$HEX" ]; then
  echo "[INFO] fast cosim hex not found, building SIM_FAST=1 firmware..."
  run_in_repo_wsl "$ROOT_DIR" \
    "cd fw/v2_e203_smoke && SIM_FAST=1 NUM_COSIM_SAMPLES=3 bash build_v2_e203_smoke.sh"
fi
if [ ! -f "$HEX" ]; then
  echo "[ERR] fast firmware hex not found after build: $HEX"
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
