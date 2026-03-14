#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.icarus_light_run.XXXXXX")
cleanup() {
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

mkdir -p "$RUN_DIR/waves"

# Resolve weight source directory:
# 1) Prefer fpga/cim_model when present.
# 2) Fallback to sim/ local tracked weights on branches without fpga/.
WEIGHT_SRC_DIR=""
if [ -f ../fpga/cim_model/weight_pos.hex ] && [ -f ../fpga/cim_model/weight_neg.hex ]; then
  WEIGHT_SRC_DIR="../fpga/cim_model"
elif [ -f ./weight_pos.hex ] && [ -f ./weight_neg.hex ]; then
  WEIGHT_SRC_DIR="."
fi

# OUT_FIFO expected count defaults:
# - with staged weights: 14
# - without weights (main blackbox path, T=10 default): 100
EXPECTED_OUT_COUNT="${SMOKE_EXPECTED_OUT_COUNT:-}"
CHECK_OUT_COUNT="${SMOKE_CHECK_OUT_COUNT:-1}"
if [ -z "$EXPECTED_OUT_COUNT" ]; then
  if [ -n "$WEIGHT_SRC_DIR" ]; then
    EXPECTED_OUT_COUNT=14
  else
    EXPECTED_OUT_COUNT=100
  fi
fi

# Copy to isolated runtime directory to avoid dirtying tracked sim/*.hex.
# For main/tapeout-oriented branches, light smoke may not require weight files.
if [ -n "$WEIGHT_SRC_DIR" ]; then
  cp "$WEIGHT_SRC_DIR/weight_pos.hex" "$RUN_DIR/weight_pos.hex"
  cp "$WEIGHT_SRC_DIR/weight_neg.hex" "$RUN_DIR/weight_neg.hex"
else
  echo "[INFO] No weight hex source found; run light smoke without staged weights."
fi

# Disable SVA assertions for Icarus compatibility ($past is not fully supported).
iverilog -g2012 -gno-assertions -f sim_icarus_light.f -s top_tb_icarus_light -o "$RUN_DIR/icarus_light.out"
(
  cd "$RUN_DIR"
  vvp ./icarus_light.out \
    +EXPECTED_OUT_COUNT="$EXPECTED_OUT_COUNT" \
    +CHECK_OUT_COUNT="$CHECK_OUT_COUNT"
) | tee "$SCRIPT_DIR/icarus_light.log"

if grep -q "LIGHT_SMOKETEST_PASS" "$SCRIPT_DIR/icarus_light.log"; then
  exit 0
fi

echo "[ERROR] LIGHT_SMOKETEST_PASS not found. See sim/icarus_light.log" >&2
exit 1
