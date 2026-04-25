#!/usr/bin/env bash
# sim/run_v2_e203_encoder_parity.sh
# Phase A-7 encoder-parity: CPU ↔ TB RPC handshake skeleton + marker flow.
# PASS tag: V2_E203_ENCODER_PARITY_PASS
#
# 前置：Icarus 快速模式 hex（真实 encoder 留给 board/Verilator）：
#   wsl bash -c "cd '/mnt/d/SoC Design/SoC Design/fw/v2_e203_smoke' && SIM_FAST=1 bash build_v2_e203_smoke.sh"
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

mkdir -p waves

HEX="../fw/v2_e203_smoke/out/v2_e203_encoder.hex"
if [ ! -f "$HEX" ]; then
  echo "[ERR] encoder firmware hex not found: $HEX"
  exit 1
fi

echo "[INFO] Compiling encoder-parity TB..."
run_iverilog -g2012 -gno-assertions \
         -o v2_e203_encoder_parity_test \
         -f sim_v2_e203_encoder_parity.f \
         2>&1 | tee v2_e203_encoder_parity_compile.log

echo "[INFO] Running..."
run_vvp v2_e203_encoder_parity_test 2>&1 | tee v2_e203_encoder_parity_sim.log

echo ""
if grep -q "V2_E203_ENCODER_PARITY_PASS" v2_e203_encoder_parity_sim.log; then
  echo "[RESULT] V2_E203_ENCODER_PARITY_PASS"
else
  echo "[RESULT] V2_E203_ENCODER_PARITY_FAIL"
  exit 1
fi
