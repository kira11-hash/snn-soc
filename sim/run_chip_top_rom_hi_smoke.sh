#!/usr/bin/env bash
# chip_top ROM boot smoke with app linked into the high INSTR window (0x4800).
# Proves the boot-ROM-shifted INSTR window really reaches 0x4FFF.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools
resolve_repo_host_paths "$ROOT_DIR"
if command -v wslpath >/dev/null 2>&1; then
  run_in_wsl() { bash -lc "cd '$REPO_WSL' && $1"; }
else
  run_in_wsl() { wsl.exe bash -lc "cd '$REPO_WSL' && $1"; }
fi
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

run_in_wsl "UART_BAUD_DIV_OVERRIDE=2u bash fw/boot_rom/build_boot_rom.sh" \
  > chip_top_rom_hi_boot_fw_build.log 2>&1
run_in_wsl "UART_BAUD_DIV_OVERRIDE=2u APP_LINKER=fw/link_app_hi.ld APP_NAME=rom_hi_smoke_app ROM_SMOKE_ADDR=0x4800 bash fw/boot_rom/build_rom_smoke_app.sh" \
  > chip_top_rom_hi_app_fw_build.log 2>&1
run_in_wsl "python3 scripts/make_boot_image.py \
  --firmware fw/boot_rom/out/rom_hi_smoke_app.bin \
  --load-addr 0x4800 \
  --entry-addr 0x4800 \
  --out fw/boot_rom/out/rom_hi_smoke_flash.bin \
  --hex fw/boot_rom/out/rom_hi_smoke_flash.hex \
  --pad-to 65536" \
  > chip_top_rom_hi_flash_image.log 2>&1

run_iverilog -g2012 -gno-assertions \
  -f sim_chip_top_rom_smoke.f \
  -s chip_top_hi_tb \
  -o chip_top_rom_hi_smoke.out \
  > chip_top_rom_hi_smoke_compile.log 2>&1

run_vvp chip_top_rom_hi_smoke.out | tee chip_top_rom_hi_smoke_sim.log

if grep -q "CHIP_TOP_ROM_HI_SMOKE_PASS" chip_top_rom_hi_smoke_sim.log; then
  echo ""
  echo "============================================"
  echo "[RESULT] CHIP_TOP_ROM_HI_SMOKE_PASS"
  echo "============================================"
else
  echo ""
  echo "============================================"
  echo "[RESULT] CHIP_TOP_ROM_HI_SMOKE_FAIL"
  echo "============================================"
  exit 1
fi
