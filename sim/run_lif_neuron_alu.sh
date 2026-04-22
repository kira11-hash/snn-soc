#!/usr/bin/env bash
# Auto-generated V2.B regression runner (2026-04-22 post-audit).
# Expected pass tag: LIF_NEURON_ALU_PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.lif_neuron_alu_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_lif_neuron_alu.f   -s lif_neuron_alu_tb -o "$RUN_DIR/lif_neuron_alu_tb.out"

LOG="$RUN_DIR/lif_neuron_alu_tb.log"
run_vvp "$RUN_DIR/lif_neuron_alu_tb.out" | tee "$LOG"

if grep -q "LIF_NEURON_ALU_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] LIF_NEURON_ALU_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] LIF_NEURON_ALU_FAIL"
  echo "============================================"
  exit 1
fi
