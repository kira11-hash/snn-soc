#!/usr/bin/env bash
# Permanent regression gate for the WSTRB byte-mask invariant in
# rtl/top/snn_soc_v2b_top.sv. Drives cmd_* directly (no AXI stack
# dependency) so it runs on any branch carrying snn_soc_v2b_top.

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

iverilog -g2012 -gno-assertions \
  -o v2b_partial_write_invariant_test \
  -f sim_v2b_partial_write_invariant.f

echo "[RESULT_BEGIN]"
vvp v2b_partial_write_invariant_test
echo "[RESULT_END]"

if grep -q "V2B_PARTIAL_WRITE_INVARIANT_TB_PASS" <(vvp v2b_partial_write_invariant_test 2>&1); then
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
