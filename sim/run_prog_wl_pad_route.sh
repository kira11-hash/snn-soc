#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

run_iverilog -g2012 -gno-assertions \
  -f sim_prog_wl_pad_route.f \
  -s prog_wl_pad_route_tb \
  -o prog_wl_pad_route.out

run_vvp prog_wl_pad_route.out | tee prog_wl_pad_route.log

if grep -q "PROG_WL_PAD_ROUTE_TB_PASS" prog_wl_pad_route.log; then
  echo "============================================"
  echo "[RESULT] PROG_WL_PAD_ROUTE_TB_PASS"
  echo "============================================"
else
  echo "============================================"
  echo "[RESULT] PROG_WL_PAD_ROUTE_TB_FAIL"
  echo "============================================"
  exit 1
fi
