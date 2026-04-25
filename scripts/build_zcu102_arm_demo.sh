#!/usr/bin/env bash
#
# scripts/build_zcu102_arm_demo.sh — one-shot driver for Phase C0.
#
# Runs `vivado -mode batch` on fpga_synth/zcu102_arm_demo.tcl which does
# BD + synth + impl + bitgen + xsa export. Takes ~30-40 min on a modern
# workstation.
#
# Override:
#   VIVADO_BIN=/path/to/vivado    (default: /d/Xilinx/Vivado/2022.2/bin/vivado.bat)
#
# Phase C0 gate criteria (local):
#   - vivado exits 0
#   - bitstream file exists: fpga_synth/zcu102_arm_demo/.../impl_1/*.bit
#   - XSA file exists:        fpga_synth/zcu102_arm_demo.xsa
#   - "ZCU102_ARM_DEMO_BITGEN_PASS" appears in log

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FPGA_DIR="$ROOT/fpga_synth"
TCL_FILE="$FPGA_DIR/zcu102_arm_demo.tcl"
LOG="$FPGA_DIR/zcu102_arm_demo.log"
JOU="$FPGA_DIR/zcu102_arm_demo.jou"

VIVADO_BIN="${VIVADO_BIN:-/d/Xilinx/Vivado/2022.2/bin/vivado.bat}"

if [ ! -f "$TCL_FILE" ]; then
  echo "[FATAL] missing $TCL_FILE" >&2
  exit 1
fi
if [ ! -e "$VIVADO_BIN" ] && [ ! -e "${VIVADO_BIN%.bat}" ]; then
  echo "[FATAL] vivado not found at $VIVADO_BIN — set VIVADO_BIN" >&2
  exit 1
fi

cd "$FPGA_DIR"
# Pass ROOT in DOS 8.3 form so Vivado's add_files can tolerate the
# space-in-path of this workspace.
ROOT_WIN_SHORT=$(cygpath -dw "$ROOT" | sed 's|\\|/|g')
echo "[build_zcu102_arm_demo] launching Vivado (this takes ~30 min)"
echo "  root (8.3): $ROOT_WIN_SHORT"
echo "  log:        $LOG"
echo "  tcl:        $TCL_FILE"
"$VIVADO_BIN" -mode batch -source "$(cygpath -w "$TCL_FILE")" \
  -log "$LOG" -journal "$JOU" -tclargs "$ROOT_WIN_SHORT"

# Check output artifacts
BIT=$(find "$FPGA_DIR/zcu102_arm_demo" -name "*.bit" 2>/dev/null | head -1 || true)
XSA="$FPGA_DIR/zcu102_arm_demo.xsa"

if [ -z "$BIT" ]; then
  echo "[FATAL] no .bit file produced" >&2
  exit 2
fi
if [ ! -f "$XSA" ]; then
  echo "[FATAL] no .xsa file produced at $XSA" >&2
  exit 3
fi
if ! grep -q "ZCU102_ARM_DEMO_BITGEN_PASS" "$LOG"; then
  echo "[FATAL] missing ZCU102_ARM_DEMO_BITGEN_PASS tag in $LOG" >&2
  exit 4
fi

MANIFEST_SCRIPT="$ROOT/scripts/gen_arm_demo_manifest.sh"
if [ -f "$MANIFEST_SCRIPT" ]; then
  ROOT_OVERRIDE="$ROOT" \
  VIVADO_BIN="$VIVADO_BIN" \
  BIT_PATH="$BIT" \
  XSA_PATH="$XSA" \
  bash "$MANIFEST_SCRIPT"
fi

echo ""
echo "============================================"
echo "[build_zcu102_arm_demo] PHASE_C0_BITGEN_PASS"
echo "============================================"
echo "bitstream: $BIT"
echo "xsa:       $XSA"
echo "manifest:  $ROOT/doc/arm-fpga-demo/build_manifest_v2.txt"
echo ""
echo "Next: load bitstream + ELF via xsct"
echo "  xsct scripts/program_zcu102_c0.tcl  # or c1"
