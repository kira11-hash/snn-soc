#!/usr/bin/env bash
# CIM FPGA model unit test — Icarus Verilog
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SIM_DIR="$SCRIPT_DIR"
CIM_MODEL_DIR="$PROJECT_ROOT/fpga/cim_model"

mkdir -p "$SIM_DIR/waves"

# Copy hex files to sim directory (where $readmemh can find them)
cp "$CIM_MODEL_DIR/weight_pos.hex" "$SIM_DIR/"
cp "$CIM_MODEL_DIR/weight_neg.hex" "$SIM_DIR/"

echo "=== Compiling CIM FPGA unit test ==="
iverilog -g2012 -gno-assertions \
  -I "$PROJECT_ROOT/rtl/top" \
  -o "$SIM_DIR/tb_cim_fpga.vvp" \
  "$PROJECT_ROOT/rtl/top/snn_soc_pkg.sv" \
  "$PROJECT_ROOT/fpga/cim_model/cim_fpga_model.sv" \
  "$SIM_DIR/tb_cim_fpga.sv"

echo "=== Running CIM FPGA unit test ==="
cd "$SIM_DIR"
vvp tb_cim_fpga.vvp 2>&1 | tee cim_fpga_test.log

# Check pass/fail
if grep -q "CIM_FPGA_UNIT_PASS" cim_fpga_test.log; then
  echo ""
  echo ">>> CIM_FPGA_UNIT_PASS <<<"
  exit 0
else
  echo ""
  echo ">>> CIM_FPGA_UNIT_FAIL <<<"
  exit 1
fi
