#!/usr/bin/env bash
# Permanent regression gate for the WSTRB byte-mask invariant in
# rtl/top/snn_soc_v2b_top.sv. Drives cmd_* directly (no AXI stack
# dependency) so it runs on any branch carrying snn_soc_v2b_top.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.v2b_partial_write_invariant_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions \
  -o "$RUN_DIR/v2b_partial_write_invariant_test" \
  -f sim_v2b_partial_write_invariant.f

echo "[RESULT_BEGIN]"
LOG="$RUN_DIR/v2b_partial_write_invariant.log"
run_vvp "$RUN_DIR/v2b_partial_write_invariant_test" | tee "$LOG"
echo "[RESULT_END]"

if grep -q "V2B_PARTIAL_WRITE_INVARIANT_TB_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] V2B_PARTIAL_WRITE_INVARIANT_TB_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] V2B_PARTIAL_WRITE_INVARIANT_TB_FAIL"
  echo "============================================"
  exit 1
fi
