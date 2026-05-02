#!/usr/bin/env bash
# fpga_synth/zcu102_v2_e203_demo/build_v2_e203_demo.sh
# Board-ready V2E203 build pipeline: firmware -> BRAM hex -> Vivado bitstream.
#
# Defaults are LeNet-5 board-evidence mode:
#   HEX=fw/v2_e203_smoke/out/v2_e203_lenet5.hex
#   OUT_DIR=fpga_synth/zcu102_v2_e203_demo/out
#   SKIP_FW=0
#
# Optional encoder-only bitstream:
#   SIM_FAST=0 bash fw/v2_e203_smoke/build_v2_e203_smoke.sh
#   HEX=fw/v2_e203_smoke/out/v2_e203_encoder.hex \
#   OUT_DIR=fpga_synth/zcu102_v2_e203_demo/out_encoder \
#   SKIP_FW=1 bash fpga_synth/zcu102_v2_e203_demo/build_v2_e203_demo.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CROSS="${CROSS:-riscv64-unknown-elf-}"
case "$CROSS" in
  *-) ;;
  *) CROSS="${CROSS}-" ;;
esac
VIVADO="${VIVADO:-vivado}"
SKIP_FW="${SKIP_FW:-0}"

HEX="${HEX:-$REPO_ROOT/fw/v2_e203_smoke/out/v2_e203_lenet5.hex}"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/out}"

abs_path() {
  local p="$1"
  if [ "${p#/}" != "$p" ] || [[ "$p" =~ ^[A-Za-z]:[\\/].* ]]; then
    printf '%s' "$p"
  else
    printf '%s/%s' "$REPO_ROOT" "$p"
  fi
}

HEX="$(abs_path "$HEX")"
OUT_DIR="$(abs_path "$OUT_DIR")"

if [ "$VIVADO" = "vivado" ] && ! command -v vivado >/dev/null 2>&1; then
  if [ -f /mnt/d/Xilinx/Vivado/2022.2/bin/vivado.bat ]; then
    VIVADO=/mnt/d/Xilinx/Vivado/2022.2/bin/vivado.bat
  elif [ -f /mnt/c/Xilinx/Vivado/2022.2/bin/vivado.bat ]; then
    VIVADO=/mnt/c/Xilinx/Vivado/2022.2/bin/vivado.bat
  fi
fi

to_win_path() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$p"
  elif [[ "$p" =~ ^/mnt/([A-Za-z])/(.*)$ ]]; then
    local drive="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]//\//\\}"
    printf '%s:\\%s' "$drive" "$rest"
  else
    printf '%s' "$p"
  fi
}

win_short_dir() {
  local posix_path="$1"
  local win_path result
  win_path="$(to_win_path "$posix_path")"
  result="$(powershell.exe -NoProfile -Command \
    "\$fso=New-Object -ComObject Scripting.FileSystemObject; Write-Output \$fso.GetFolder('$win_path').ShortPath" \
    2>/dev/null | tr -d '\r\n' | sed 's|\\|/|g')" || true
  printf '%s' "${result:-$posix_path}"
}

win_short_file() {
  local posix_path="$1"
  local win_path result
  win_path="$(to_win_path "$posix_path")"
  result="$(powershell.exe -NoProfile -Command \
    "\$fso=New-Object -ComObject Scripting.FileSystemObject; Write-Output \$fso.GetFile('$win_path').ShortPath" \
    2>/dev/null | tr -d '\r\n' | sed 's|\\|/|g')" || true
  printf '%s' "${result:-$posix_path}"
}

mkdir -p "$OUT_DIR"

echo "=== V2E203 ZCU102 FPGA Build Pipeline ==="
echo "Repo root : $REPO_ROOT"
echo "Firmware  : $HEX"
echo "Output    : $OUT_DIR"
echo "SKIP_FW   : $SKIP_FW"

if [ "$SKIP_FW" = "0" ]; then
  echo ""
  echo "--- Step 1: Build board-ready V2E203 firmware ---"
  CROSS="$CROSS" SIM_FAST=0 bash "$REPO_ROOT/fw/v2_e203_smoke/build_v2_e203_smoke.sh"
else
  echo ""
  echo "--- Step 1: Skipping firmware build (SKIP_FW=1) ---"
fi

if [ ! -f "$HEX" ]; then
  echo "ERROR: firmware hex not found: $HEX" >&2
  exit 1
fi

REPO_SHORT="$(win_short_dir "$REPO_ROOT")"
HEX_SHORT="$(win_short_file "$HEX")"
OUT_SHORT="$(win_short_dir "$OUT_DIR")"
TCL_SHORT="$(win_short_file "$SCRIPT_DIR/build_v2_e203_demo.tcl")"

echo ""
echo "--- Step 2: Vivado synthesis / implementation / bitstream ---"
echo "Repo root short : $REPO_SHORT"
echo "Firmware short  : $HEX_SHORT"
echo "Output short    : $OUT_SHORT"

run_vivado() {
  case "$VIVADO" in
    *.bat|*.BAT|*.cmd|*.CMD)
      local vivado_win
      vivado_win="$(to_win_path "$VIVADO")"
      cmd.exe /c "$vivado_win" -mode batch -source "$TCL_SHORT" -tclargs "$REPO_SHORT" "$HEX_SHORT" "$OUT_SHORT" -log "$OUT_SHORT/vivado_build.log" -journal "$OUT_SHORT/vivado_build.jou"
      ;;
    *)
      "$VIVADO" -mode batch \
        -source "$SCRIPT_DIR/build_v2_e203_demo.tcl" \
        -tclargs "$REPO_SHORT" "$HEX_SHORT" "$OUT_SHORT" \
        -log "$OUT_DIR/vivado_build.log" \
        -journal "$OUT_DIR/vivado_build.jou"
      ;;
  esac
}

run_vivado 2>&1 | tee "$OUT_DIR/build_console.log"

BIT="$OUT_DIR/snn_soc_v2b_e203_fpga_top.bit"
if [ ! -f "$BIT" ]; then
  echo "ERROR: bitstream not generated: $BIT" >&2
  exit 2
fi

echo ""
echo "=== V2E203 FPGA build complete ==="
echo "bitstream ready: $BIT"
echo "program: xsct $REPO_ROOT/scripts/program_zcu102_v2_e203.tcl $BIT"
