#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run_multilayer_scan_ext.sh — 运行 multilayer_scan_ext_tb
# 目的：覆盖 V2 ADC 扩展扫描（bl_cnt=64 / 128），证明 MAX_BL_SCAN=128 真的可用
# 对应 Codex D2-003 finding
# -----------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
. "$(pwd)/common_iverilog_env.sh"
resolve_iverilog_tools

echo "[run_multilayer_scan_ext.sh] Compiling with +define+SIM_MULTI_LAYER ..."
mkdir -p waves

run_iverilog -g2012 -gno-assertions \
  -DSIM_MULTI_LAYER \
  -DFPGA_BEHAVIORAL \
  -f sim_multilayer_scan_ext.f \
  -s multilayer_scan_ext_tb \
  -o sim_multilayer_scan_ext.out 2>&1

echo "[run_multilayer_scan_ext.sh] Running ..."
SIM_LOG=$(run_vvp sim_multilayer_scan_ext.out 2>&1)
echo "$SIM_LOG"

if echo "$SIM_LOG" | grep -q "MULTILAYER_SCAN_EXT_PASS"; then
  echo "[run_multilayer_scan_ext.sh] >>> MULTILAYER_SCAN_EXT_PASS <<<"
else
  echo "[run_multilayer_scan_ext.sh] >>> FAIL <<<"
  exit 1
fi
