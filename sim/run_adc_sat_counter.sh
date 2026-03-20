#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.adc_sat_counter_run.XXXXXX")
cleanup() {
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

mkdir -p "$RUN_DIR/waves"

run_iverilog -g2012 -gno-assertions -f sim_adc_sat_counter.f -s top_tb_adc_sat_counter -o "$RUN_DIR/adc_sat_counter.out"
(
  cd "$RUN_DIR"
  run_vvp ./adc_sat_counter.out
) | tee "$SCRIPT_DIR/adc_sat_counter.log"

if grep -q "ADC_SAT_COUNTER_PASS" "$SCRIPT_DIR/adc_sat_counter.log"; then
  exit 0
fi

echo "[ERROR] ADC_SAT_COUNTER_PASS not found. See sim/adc_sat_counter.log" >&2
exit 1
