#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools
if command -v wslpath >/dev/null 2>&1; then
  REPO_WSL="$ROOT_DIR"
  run_in_wsl() {
    bash -lc "cd '$REPO_WSL' && $1"
  }
else
  REPO_WIN_RAW="$(cd .. && pwd -W)"
  REPO_WSL="$(wsl.exe wslpath -a "$REPO_WIN_RAW" 2>/dev/null | tr -d '\r')"
  run_in_wsl() {
    wsl.exe bash -lc "cd '$REPO_WSL' && $1"
  }
fi

mkdir -p waves
rm -f jtag_rescue_top_test jtag_rescue_top_compile.log jtag_rescue_top_sim.log

cleanup() {
  cleanup_vendor_e203_alias
}
trap cleanup EXIT

ensure_vendor_e203_alias "$ROOT_DIR"

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
