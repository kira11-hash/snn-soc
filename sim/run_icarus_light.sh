#!/usr/bin/env bash
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

mkdir -p waves

# Keep simulation weights aligned with fpga/cim_model source-of-truth.
cp ../fpga/cim_model/weight_pos.hex ./weight_pos.hex
cp ../fpga/cim_model/weight_neg.hex ./weight_neg.hex

# Disable SVA assertions for Icarus compatibility ($past is not fully supported).
iverilog -g2012 -gno-assertions -f sim_icarus_light.f -s top_tb_icarus_light -o icarus_light.out
vvp icarus_light.out | tee icarus_light.log
