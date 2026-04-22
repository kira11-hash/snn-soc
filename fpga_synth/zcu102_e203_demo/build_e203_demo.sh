#!/usr/bin/env bash
# fpga_synth/zcu102_e203_demo/build_e203_demo.sh
# Full build pipeline: firmware → hex → Vivado synthesis → bitstream.
#
# Usage:
#   bash fpga_synth/zcu102_e203_demo/build_e203_demo.sh
#
# Environment overrides:
#   CROSS=riscv64-unknown-elf   RISC-V toolchain prefix (default: riscv64-unknown-elf)
#   VIVADO=vivado                Vivado executable (default: vivado)
#   SKIP_FW=1                    Skip firmware build (use existing hex)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$SCRIPT_DIR/out"

CROSS="${CROSS:-riscv64-unknown-elf}"
VIVADO="${VIVADO:-vivado}"
SKIP_FW="${SKIP_FW:-0}"

HEX="$REPO_ROOT/fw/e203_smoke/out/e203_smoke.hex"

mkdir -p "$OUT_DIR"

echo "=== E203 FPGA Build Pipeline ==="
echo "Repo root : $REPO_ROOT"
echo "Output    : $OUT_DIR"

# ---------------------------------------------------------------------------
# Step 1: Build firmware
# ---------------------------------------------------------------------------
if [ "$SKIP_FW" = "0" ]; then
    echo ""
    echo "--- Step 1: Build e203_smoke firmware ---"
    CROSS="$CROSS" bash "$REPO_ROOT/fw/e203_smoke/build_e203_smoke.sh"
    echo "[DONE] Firmware: $HEX"
else
    echo "--- Step 1: Skipping firmware build (SKIP_FW=1) ---"
    if [ ! -f "$HEX" ]; then
        echo "ERROR: hex not found: $HEX" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Step 2: Vivado synthesis + implementation + bitstream
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 2: Vivado synthesis + bitstream ---"
"$VIVADO" -mode batch \
  -source "$SCRIPT_DIR/build_e203_demo.tcl" \
  -tclargs "$HEX" "$OUT_DIR" \
  -log "$OUT_DIR/vivado_build.log" \
  -journal "$OUT_DIR/vivado_build.jou"

echo ""
echo "=== Build complete ==="
echo "Bitstream : $OUT_DIR/snn_soc_fpga_top.bit"
echo ""
echo "To program ZCU102:"
echo "  xsct $REPO_ROOT/scripts/program_zcu102_e203.tcl $OUT_DIR/snn_soc_fpga_top.bit"
