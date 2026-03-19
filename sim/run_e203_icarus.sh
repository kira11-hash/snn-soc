#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
REPO_WIN="$(cd .. && pwd -W)"
REPO_WIN="${REPO_WIN//\//\\}"
REPO_WSL="$(wsl.exe wslpath -a "$REPO_WIN" 2>/dev/null | tr -d '\r')"
VENDOR_ASCII_WIN="${REPO_WIN}\\rtl\\vendor_e203"
VENDOR_SRC_WIN="${REPO_WIN}\\项目相关文件\\未添加的IP的源代码\\e203_hbirdv2-master\\rtl"

mkdir -p waves

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

wsl.exe bash -lc "cd '$REPO_WSL' && bash fw/build_e203_firmware.sh" > e203_fw_build.log 2>&1

iverilog -g2012 -gno-assertions -f sim_e203.f -s e203_tb -o e203_smoke.out > e203_compile.log 2>&1
vvp e203_smoke.out | tee e203_sim.log

grep -q "E203_SMOKETEST_PASS" e203_sim.log
