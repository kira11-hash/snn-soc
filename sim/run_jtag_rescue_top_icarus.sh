#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools
if command -v wslpath >/dev/null 2>&1; then
  REPO_WSL="$ROOT_DIR"
  REPO_WIN="$(wslpath -w "$REPO_WSL" | tr -d '\r')"
  run_in_wsl() {
    bash -lc "cd '$REPO_WSL' && $1"
  }
else
  REPO_WIN="$(cd .. && pwd -W)"
  REPO_WIN="${REPO_WIN//\//\\}"
  REPO_WSL="$(wsl.exe wslpath -a "$REPO_WIN" 2>/dev/null | tr -d '\r')"
  run_in_wsl() {
    wsl.exe bash -lc "cd '$REPO_WSL' && $1"
  }
fi
REPO_WIN="${REPO_WIN//\//\\}"
VENDOR_ASCII_WIN="${REPO_WIN}\\rtl\\vendor_e203"
VENDOR_SRC_POSIX="$(find_vendor_e203_rtl_dir "$ROOT_DIR")"

if [ -z "$VENDOR_SRC_POSIX" ]; then
  echo "[ERROR] Unable to locate e203_hbirdv2-master/rtl under repo root: $ROOT_DIR" >&2
  exit 1
fi

VENDOR_SRC_WIN="$(to_windows_path "$VENDOR_SRC_POSIX")"
VENDOR_SRC_WIN="${VENDOR_SRC_WIN//\//\\}"

mkdir -p waves
rm -f jtag_rescue_top_test jtag_rescue_top_compile.log jtag_rescue_top_sim.log

CREATED_VENDOR_JUNCTION=0
cleanup() {
  if [ "$CREATED_VENDOR_JUNCTION" -eq 1 ] && [ -e ../rtl/vendor_e203 ]; then
    cmd.exe /c "rmdir \"$VENDOR_ASCII_WIN\"" > /dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ ! -e ../rtl/vendor_e203 ]; then
  powershell.exe -NoProfile -Command "if (-not (Test-Path '$VENDOR_ASCII_WIN')) { New-Item -ItemType Junction -Path '$VENDOR_ASCII_WIN' -Target '$VENDOR_SRC_WIN' | Out-Null }"
  CREATED_VENDOR_JUNCTION=1
fi

echo "[INFO] Building rescue firmware..."
run_in_wsl "UART_BAUD_DIV_OVERRIDE=2u bash fw/build_jtag_rescue_firmware.sh" > jtag_rescue_top_fw_build.log 2>&1

echo "[INFO] Compiling JTAG rescue top test (Icarus)..."
run_iverilog -g2012 -gno-assertions \
         -o jtag_rescue_top_test \
         -f sim_jtag_rescue_top.f \
         2>&1 | tee jtag_rescue_top_compile.log

if [ ! -f jtag_rescue_top_test ]; then
  echo "[ERROR] Compilation failed - check sim/jtag_rescue_top_compile.log"
  exit 1
fi

echo "[INFO] Running simulation..."
run_vvp jtag_rescue_top_test 2>&1 | tee jtag_rescue_top_sim.log

if grep -q "JTAG_RESCUE_TOP_PASS" jtag_rescue_top_sim.log; then
  echo "============================================"
  echo "[RESULT] JTAG_RESCUE_TOP_PASS"
  echo "============================================"
  exit 0
fi

echo "============================================"
echo "[RESULT] JTAG_RESCUE_TOP_FAIL"
echo "  -> check sim/jtag_rescue_top_sim.log"
echo "============================================"
exit 1
