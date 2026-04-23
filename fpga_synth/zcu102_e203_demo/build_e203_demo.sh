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
#   HEX=/path/to/fw.hex          Override BRAM init hex (default: e203_smoke.hex)
#   OUT_DIR=/path/to/out         Override output directory
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CROSS="${CROSS:-riscv64-unknown-elf}"
VIVADO="${VIVADO:-vivado}"
SKIP_FW="${SKIP_FW:-0}"

HEX="${HEX:-$REPO_ROOT/fw/e203_smoke/out/e203_smoke.hex}"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/out}"

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# Get 8.3 short paths to work around Vivado's inability to handle spaces
# in file paths passed to read_verilog. On Windows (Git Bash / MSYS2) we
# use PowerShell's COM FileSystemObject; on Linux the path has no spaces.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Get 8.3 short path for repo root so Vivado can handle paths with spaces.
# Uses PowerShell FileSystemObject (Windows only); falls back gracefully.
# HEX and OUT paths are constructed from REPO_SHORT: subdirs have no spaces.
# ---------------------------------------------------------------------------
win_short_dir() {
  local posix_path="$1"
  local win_path result
  win_path="$(cygpath -w "$posix_path" 2>/dev/null || printf '%s' "$posix_path")"
  result="$(powershell.exe -NoProfile -Command \
    "\$fso=New-Object -ComObject Scripting.FileSystemObject; Write-Output \$fso.GetFolder('$win_path').ShortPath" \
    2>/dev/null | tr -d '\r\n' | sed 's|\\|/|g')"
  printf '%s' "${result:-$posix_path}"
}

win_short_file() {
  local posix_path="$1"
  local win_path result
  win_path="$(cygpath -w "$posix_path" 2>/dev/null || printf '%s' "$posix_path")"
  result="$(powershell.exe -NoProfile -Command \
    "\$fso=New-Object -ComObject Scripting.FileSystemObject; Write-Output \$fso.GetFile('$win_path').ShortPath" \
    2>/dev/null | tr -d '\r\n' | sed 's|\\|/|g')"
  printf '%s' "${result:-$posix_path}"
}

REPO_SHORT="$(win_short_dir "$REPO_ROOT" 2>/dev/null || printf '%s' "$REPO_ROOT")"
HEX_SHORT="$(win_short_file "$HEX" 2>/dev/null || printf '%s' "$HEX")"
OUT_SHORT="$(win_short_dir "$OUT_DIR" 2>/dev/null || printf '%s' "$OUT_DIR")"

echo "=== E203 FPGA Build Pipeline ==="
echo "Repo root  : $REPO_ROOT  →  $REPO_SHORT"
echo "Firmware   : $HEX  →  $HEX_SHORT"
echo "Output     : $OUT_DIR"

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
  -tclargs "$REPO_SHORT" "$HEX_SHORT" "$OUT_SHORT" \
  -log "$OUT_DIR/vivado_build.log" \
  -journal "$OUT_DIR/vivado_build.jou"

echo ""
echo "=== Build complete ==="
echo "Bitstream : $OUT_DIR/snn_soc_fpga_top.bit"
echo ""
echo "To program ZCU102:"
echo "  xsct $REPO_ROOT/scripts/program_zcu102_e203.tcl $OUT_DIR/snn_soc_fpga_top.bit"
