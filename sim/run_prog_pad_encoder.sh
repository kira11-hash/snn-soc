#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

run_iverilog -g2012 -gno-assertions \
  -f sim_prog_pad_encoder.f \
  -s prog_pad_encoder_tb \
  -o prog_pad_encoder.out

run_vvp prog_pad_encoder.out | tee prog_pad_encoder.log

if grep -q "PROG_PAD_ENCODER_TB_PASS" prog_pad_encoder.log; then
  echo "============================================"
  echo "[RESULT] PROG_PAD_ENCODER_TB_PASS"
  echo "============================================"
else
  echo "============================================"
  echo "[RESULT] PROG_PAD_ENCODER_TB_FAIL"
  echo "============================================"
  exit 1
fi
