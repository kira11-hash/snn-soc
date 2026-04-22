#!/usr/bin/env bash
# Auto-generated V2.B regression runner (2026-04-22 post-audit).
# Expected pass tag: CIM_MAC_BEHAVIORAL_V2_DIM_EDGE_TB_PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.cim_mac_v2_dim_edge_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_cim_mac_v2_dim_edge.f   -s cim_mac_behavioral_v2_dim_edge_tb -o "$RUN_DIR/cim_mac_behavioral_v2_dim_edge_tb.out"

LOG="$RUN_DIR/cim_mac_behavioral_v2_dim_edge_tb.log"
run_vvp "$RUN_DIR/cim_mac_behavioral_v2_dim_edge_tb.out" | tee "$LOG"

if grep -q "CIM_MAC_BEHAVIORAL_V2_DIM_EDGE_TB_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] CIM_MAC_BEHAVIORAL_V2_DIM_EDGE_TB_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] CIM_MAC_BEHAVIORAL_V2_DIM_EDGE_TB_FAIL"
  echo "============================================"
  exit 1
fi
