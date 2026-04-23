#!/usr/bin/env bash
# sim/run_silicon_bringup.sh
# Build fw/silicon_bringup + run Icarus simulation against silicon_bringup_tb.
#
# Pass tag: SILICON_BRINGUP_TB_PASS
# Fail tag: SILICON_BRINGUP_TB_FAIL
#
# Uses the same vendor_e203 junction + WSL toolchain invocation pattern as
# run_e203_icarus.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

if command -v wslpath >/dev/null 2>&1; then
  REPO_WSL="$ROOT_DIR"
  REPO_WIN="$(wslpath -w "$REPO_WSL" | tr -d '\r')"
  run_in_wsl() { bash -lc "cd '$REPO_WSL' && $1"; }
else
  REPO_WIN="$(cd .. && pwd -W)"
  REPO_WIN="${REPO_WIN//\//\\}"
  REPO_WSL="$(wsl.exe wslpath -a "$REPO_WIN" 2>/dev/null | tr -d '\r')"
  run_in_wsl() { wsl.exe bash -lc "cd '$REPO_WSL' && $1"; }
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
RESTORE_DEFAULT_FW=1
cleanup() {
  if [ "$RESTORE_DEFAULT_FW" -eq 1 ]; then
    # The sim build below overrides UART_BAUD_DIV to 2 for speed and writes the
    # tracked fw/silicon_bringup/out/silicon_bringup.hex.  Always restore the
    # default 50MHz/115200 image before returning so Gate A does not leave the
    # tape-out firmware artifact dirty or board-hostile.
    run_in_wsl "bash fw/silicon_bringup/build_silicon_bringup.sh" \
      > silicon_bringup_fw_restore.log 2>&1 || \
      echo "[WARN] failed to restore default silicon_bringup.hex; see silicon_bringup_fw_restore.log" >&2
  fi
  if [ "$CREATED_VENDOR_JUNCTION" -eq 1 ]; then
    MSYS2_ARG_CONV_EXCL='*' cmd.exe /c rmdir "$VENDOR_ASCII_WIN" > /dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ ! -e ../rtl/vendor_e203 ]; then
  powershell.exe -NoProfile -Command "if (-not (Test-Path '$VENDOR_ASCII_WIN')) { New-Item -ItemType Junction -Path '$VENDOR_ASCII_WIN' -Target '$VENDOR_SRC_WIN' | Out-Null }"
  CREATED_VENDOR_JUNCTION=1
fi

# Build silicon_bringup firmware with UART_BAUD_DIV_OVERRIDE=2 for sim speed
run_in_wsl "UART_BAUD_DIV_OVERRIDE=2u bash fw/silicon_bringup/build_silicon_bringup.sh" \
    > silicon_bringup_fw_build.log 2>&1

run_iverilog -g2012 -gno-assertions \
  -f sim_silicon_bringup.f \
  -s silicon_bringup_tb \
  -o silicon_bringup.out \
  > silicon_bringup_compile.log 2>&1

run_vvp silicon_bringup.out | tee silicon_bringup_sim.log

if grep -q "SILICON_BRINGUP_TB_PASS" silicon_bringup_sim.log; then
    echo ""
    echo "============================================"
    echo "[RESULT] SILICON_BRINGUP_TB_PASS"
    echo "============================================"
    exit 0
else
    echo ""
    echo "============================================"
    echo "[RESULT] SILICON_BRINGUP_TB_FAIL"
    echo "============================================"
    exit 1
fi
