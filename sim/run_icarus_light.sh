#!/usr/bin/env bash
set -e

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
else
  echo "[ERR] weight hex files not found in ../fpga/cim_model or ./sim" >&2
  exit 1
fi

# Copy to isolated runtime directory to avoid dirtying tracked sim/*.hex.
cp "$WEIGHT_SRC_DIR/weight_pos.hex" "$RUN_DIR/weight_pos.hex"
cp "$WEIGHT_SRC_DIR/weight_neg.hex" "$RUN_DIR/weight_neg.hex"

# Disable SVA assertions for Icarus compatibility ($past is not fully supported).
iverilog -g2012 -gno-assertions -f sim_icarus_light.f -s top_tb_icarus_light -o "$RUN_DIR/icarus_light.out"
(
  cd "$RUN_DIR"
  vvp ./icarus_light.out
) | tee "$SCRIPT_DIR/icarus_light.log"
