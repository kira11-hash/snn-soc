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

# Keep simulation weights aligned with fpga/cim_model source-of-truth
# without overwriting tracked files under sim/.
cp ../fpga/cim_model/weight_pos.hex "$RUN_DIR/weight_pos.hex"
cp ../fpga/cim_model/weight_neg.hex "$RUN_DIR/weight_neg.hex"

# Disable SVA assertions for Icarus compatibility ($past is not fully supported).
iverilog -g2012 -gno-assertions -f sim_icarus_light.f -s top_tb_icarus_light -o "$RUN_DIR/icarus_light.out"
(
  cd "$RUN_DIR"
  vvp ./icarus_light.out
) | tee "$SCRIPT_DIR/icarus_light.log"
