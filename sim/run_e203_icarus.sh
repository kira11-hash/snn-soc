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

cleanup() {
  cleanup_vendor_e203_alias
}
trap cleanup EXIT

ensure_vendor_e203_alias "$ROOT_DIR"

run_in_wsl "UART_BAUD_DIV_OVERRIDE=2u bash fw/build_e203_firmware.sh" > e203_fw_build.log 2>&1

run_iverilog -g2012 -gno-assertions -f sim_e203.f -s e203_tb -o e203_smoke.out > e203_compile.log 2>&1
run_vvp e203_smoke.out | tee e203_sim.log

grep -q "E203_SMOKETEST_PASS" e203_sim.log
