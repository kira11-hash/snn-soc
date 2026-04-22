#!/usr/bin/env bash
# feature/v2-arm-fpga-demo Phase A gate runner (2026-04-22).
# 验证 v2b_axi_wrapper（axi2simple_bridge + simple2v2btop_adapter + snn_soc_v2b_top）
# 与 Python golden（10 Fashion 14x14 samples）bit-exact。
# Expected pass tag: AXI_ARM_COSIM_RESIDENT_14X14_TB_PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.axi_arm_cosim_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top \
  -f sim_axi_arm_cosim_resident_14x14.f \
  -s axi_arm_cosim_resident_14x14_tb \
  -o "$RUN_DIR/axi_arm_cosim_resident_14x14_tb.out"

LOG="$RUN_DIR/axi_arm_cosim_resident_14x14_tb.log"
run_vvp "$RUN_DIR/axi_arm_cosim_resident_14x14_tb.out" | tee "$LOG"

if grep -q "AXI_ARM_COSIM_RESIDENT_14X14_TB_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] AXI_ARM_COSIM_RESIDENT_14X14_TB_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] AXI_ARM_COSIM_RESIDENT_14X14_TB_FAIL"
  echo "============================================"
  exit 1
fi
