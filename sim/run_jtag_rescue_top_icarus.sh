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
wsl.exe bash -lc "cd '$REPO_WSL' && bash fw/build_jtag_rescue_firmware.sh" > jtag_rescue_top_fw_build.log 2>&1

echo "[INFO] Compiling JTAG rescue top test (Icarus)..."
iverilog -g2012 -gno-assertions \
         -o jtag_rescue_top_test \
         -f sim_jtag_rescue_top.f \
         2>&1 | tee jtag_rescue_top_compile.log

if [ ! -f jtag_rescue_top_test ]; then
  echo "[ERROR] Compilation failed - check sim/jtag_rescue_top_compile.log"
  exit 1
fi

echo "[INFO] Running simulation..."
vvp jtag_rescue_top_test 2>&1 | tee jtag_rescue_top_sim.log

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
