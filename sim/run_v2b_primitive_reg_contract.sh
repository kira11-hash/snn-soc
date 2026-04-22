#!/usr/bin/env bash
# BLOCK-V2-02 regression runner (2026-04-22 GPT audit fixup).
# Verifies that v2b_primitives.h CFG5 contract (t_count) matches snn_soc_v2b_top RTL.
# Expected pass tag: V2B_PRIMITIVE_REG_CONTRACT_TB_PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.v2b_primitive_reg_contract_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_v2b_primitive_reg_contract.f \
  -s v2b_primitive_reg_contract_tb -o "$RUN_DIR/v2b_primitive_reg_contract_tb.out"

LOG="$RUN_DIR/v2b_primitive_reg_contract_tb.log"
run_vvp "$RUN_DIR/v2b_primitive_reg_contract_tb.out" | tee "$LOG"

if grep -q "V2B_PRIMITIVE_REG_CONTRACT_TB_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] V2B_PRIMITIVE_REG_CONTRACT_TB_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] V2B_PRIMITIVE_REG_CONTRACT_TB_FAIL"
  echo "============================================"
  exit 1
fi
