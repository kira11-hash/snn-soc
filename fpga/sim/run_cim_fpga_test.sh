#!/usr/bin/env bash
# CIM FPGA model unit test — Icarus Verilog
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SIM_DIR="$SCRIPT_DIR"
CIM_MODEL_DIR="$PROJECT_ROOT/fpga/cim_model"
RUN_DIR="$SIM_DIR/.cim_unit_tmp"

rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR/waves"

# Copy weight hex into isolated run directory to avoid dirtying tracked files.
cp "$CIM_MODEL_DIR/weight_pos.hex" "$RUN_DIR/"
cp "$CIM_MODEL_DIR/weight_neg.hex" "$RUN_DIR/"

echo "=== Compiling CIM FPGA unit test ==="
iverilog -g2012 -gno-assertions \
  -I "$PROJECT_ROOT/rtl/top" \
  -o "$RUN_DIR/tb_cim_fpga.vvp" \
  "$PROJECT_ROOT/rtl/top/snn_soc_pkg.sv" \
  "$PROJECT_ROOT/fpga/cim_model/cim_fpga_model.sv" \
  "$SIM_DIR/tb_cim_fpga.sv"

echo "=== Running CIM FPGA unit test ==="
cd "$RUN_DIR"
vvp tb_cim_fpga.vvp 2>&1 | tee "$SIM_DIR/cim_fpga_test.log"

# Check pass/fail
if grep -q "CIM_FPGA_UNIT_PASS" "$SIM_DIR/cim_fpga_test.log"; then
  echo ""
  echo ">>> CIM_FPGA_UNIT_PASS <<<"
  rm -rf "$RUN_DIR"
  exit 0
else
  echo ""
  echo ">>> CIM_FPGA_UNIT_FAIL <<<"
  echo "Log: $SIM_DIR/cim_fpga_test.log"
  exit 1
fi
