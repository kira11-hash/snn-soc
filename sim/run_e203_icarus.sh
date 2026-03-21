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

CREATED_VENDOR_JUNCTION=0
cleanup() {
  if [ "$CREATED_VENDOR_JUNCTION" -eq 1 ]; then
    MSYS2_ARG_CONV_EXCL='*' cmd.exe /c rmdir "$VENDOR_ASCII_WIN" > /dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ ! -e ../rtl/vendor_e203 ]; then
  powershell.exe -NoProfile -Command "if (-not (Test-Path '$VENDOR_ASCII_WIN')) { New-Item -ItemType Junction -Path '$VENDOR_ASCII_WIN' -Target '$VENDOR_SRC_WIN' | Out-Null }"
  CREATED_VENDOR_JUNCTION=1
fi

run_in_wsl "UART_BAUD_DIV_OVERRIDE=2u bash fw/build_e203_firmware.sh" > e203_fw_build.log 2>&1

run_iverilog -g2012 -gno-assertions -f sim_e203.f -s e203_tb -o e203_smoke.out > e203_compile.log 2>&1
run_vvp e203_smoke.out | tee e203_sim.log

grep -q "E203_SMOKETEST_PASS" e203_sim.log
