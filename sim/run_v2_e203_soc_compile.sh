#!/usr/bin/env bash
# sim/run_v2_e203_soc_compile.sh
# Phase A-5: snn_soc_v2b_e203_top elaborate + rst-release smoke
# PASS tag: V2_E203_SOC_COMPILE_PASS
#
# 这是 SoC 顶层的 compile-only sanity，不加载固件、不发推理。
# 完整 cosim 在 Phase A-7 `run_v2_e203_cosim.sh` 里做。

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

mkdir -p waves

echo "[INFO] Compiling snn_soc_v2b_e203_top elaborate-smoke (Icarus)..."
run_iverilog -g2012 -gno-assertions \
         -o v2_e203_soc_compile_test \
         -f sim_v2_e203.f \
         2>&1 | tee v2_e203_soc_compile.log

if [ ! -f v2_e203_soc_compile_test ]; then
  echo "[ERROR] Compilation failed"
  exit 1
fi

echo "[INFO] Running..."
run_vvp v2_e203_soc_compile_test 2>&1 | tee v2_e203_soc_compile_sim.log

echo ""
if grep -q "V2_E203_SOC_COMPILE_PASS" v2_e203_soc_compile_sim.log; then
  echo "[RESULT] V2_E203_SOC_COMPILE_PASS"
else
  echo "[RESULT] V2_E203_SOC_COMPILE_FAIL"
  exit 1
fi
