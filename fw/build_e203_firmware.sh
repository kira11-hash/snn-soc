#!/usr/bin/env bash
# ⚠⚠⚠  FW-C2 audit warning（2026-05-02 pre-tape-out audit）⚠⚠⚠
#
# 本脚本是 V1 legacy FPGA / e203_tb build flow，**不是 tape-out 路径**：
#   - bootloader text @ 0x0000_0000 (INSTR_SRAM directly, no boot ROM)
#   - app text        @ 0x0001_0000 (DATA_SRAM)
#   - flash image built by fw/build_flash_image.py（旧 magic header 格式）
#
# 与流片 mask ROM (0x0) + INSTR_SRAM @ 0x1000 的硅片真实路径**不兼容**：
#   - app @ 0x10000 不在 boot_rom 的 ROM_APP_BASE/END (0x1000..0x4FFF) 内
#     → boot_rom_main.c app_range_ok() 直接 reject → 卡 JTAG rescue
#   - 旧 magic header 格式（fw/build_flash_image.py:11-12 写 0x10000 load addr）
#     与 scripts/make_boot_image.py 的 0x1000 流片格式不一致
#
# **Tape-out / silicon Day-2 必须用以下新链**：
#   - fw/boot_rom/build_boot_rom.sh        (ROM bootloader @ 0x0, 4KB mask ROM)
#   - fw/link_app.ld                       (app @ 0x0000_1000 in INSTR_SRAM)
#   - scripts/make_boot_image.py           (16-byte BOOT header + payload @ 0x1000)
#
# 本脚本仅用于 V1 legacy FPGA 端到端 sim regression（top_tb_icarus_*）。
# 流片 / 真硅片 / chip_top 端到端 sim 都不要走这一路。
set -euo pipefail

if [ "${ALLOW_LEGACY_V1_FW:-}" != "1" ]; then
  echo "============================================" >&2
  echo "[FW-C2 WARN] fw/build_e203_firmware.sh is V1 legacy (links to 0x10000)" >&2
  echo "[FW-C2 WARN] do NOT use this for tape-out / silicon flow." >&2
  echo "[FW-C2 WARN] Tape-out path: fw/boot_rom/build_boot_rom.sh +" >&2
  echo "[FW-C2 WARN]               fw/silicon_bringup/build_silicon_bringup.sh +" >&2
  echo "[FW-C2 WARN]               scripts/make_boot_image.py" >&2
  echo "[FW-C2 WARN] To proceed anyway (V1 legacy FPGA sim), set ALLOW_LEGACY_V1_FW=1" >&2
  echo "============================================" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
CROSS="${CROSS:-riscv64-unknown-elf}"
BOOT_IMEM_WORDS=4096

mkdir -p "$OUT_DIR"

CFLAGS=(
  -march=rv32i_zicsr_zifencei
  -mabi=ilp32
  -ffreestanding
  -fno-builtin
  -ffunction-sections
  -fdata-sections
  -O2
  -Wall
  -Wextra
  -Werror
  -nostdlib
)

LDFLAGS=(
  -T "$SCRIPT_DIR/link.ld"
  -nostdlib
  -Wl,--gc-sections
  -Wl,--build-id=none
  -Wl,-Map="$OUT_DIR/bootloader.map"
)

COMMON_CFLAGS=(-I"$SCRIPT_DIR")
if [ -n "${UART_BAUD_DIV_OVERRIDE:-}" ]; then
  COMMON_CFLAGS+=("-DUART_BAUD_DIV=${UART_BAUD_DIV_OVERRIDE}")
fi

"$CROSS"-gcc "${CFLAGS[@]}" "${COMMON_CFLAGS[@]}" -c "$SCRIPT_DIR/crt0.S" -o "$OUT_DIR/crt0.o"
"$CROSS"-gcc "${CFLAGS[@]}" "${COMMON_CFLAGS[@]}" -c "$SCRIPT_DIR/uart_printf.c" -o "$OUT_DIR/uart_printf.o"

"$CROSS"-gcc "${CFLAGS[@]}" "${COMMON_CFLAGS[@]}" -c "$SCRIPT_DIR/main.c" -o "$OUT_DIR/app_main.o"
"$CROSS"-gcc "${CFLAGS[@]}" \
  -T "$SCRIPT_DIR/app_link.ld" \
  -nostdlib \
  -Wl,--gc-sections \
  -Wl,--build-id=none \
  -Wl,-Map="$OUT_DIR/app.map" \
  "$OUT_DIR/crt0.o" "$OUT_DIR/app_main.o" "$OUT_DIR/uart_printf.o" \
  -lgcc \
  -o "$OUT_DIR/app.elf"
"$CROSS"-objcopy -O binary "$OUT_DIR/app.elf" "$OUT_DIR/app.bin"
"$CROSS"-objdump -d "$OUT_DIR/app.elf" > "$OUT_DIR/app.dump"
python3 "$SCRIPT_DIR/build_flash_image.py" \
  "$OUT_DIR/app.bin" \
  "$OUT_DIR/flash_image.bin" \
  "$OUT_DIR/flash_image.hex"

"$CROSS"-gcc "${CFLAGS[@]}" "${COMMON_CFLAGS[@]}" -c "$SCRIPT_DIR/boot_main.c" -o "$OUT_DIR/boot_main.o"
"$CROSS"-gcc "${CFLAGS[@]}" "${LDFLAGS[@]}" \
  "$OUT_DIR/crt0.o" "$OUT_DIR/boot_main.o" "$OUT_DIR/uart_printf.o" \
  -lgcc \
  -o "$OUT_DIR/bootloader.elf"
"$CROSS"-objcopy -O binary "$OUT_DIR/bootloader.elf" "$OUT_DIR/bootloader.bin"
"$CROSS"-objdump -d "$OUT_DIR/bootloader.elf" > "$OUT_DIR/bootloader.dump"
python3 "$SCRIPT_DIR/bin_to_readmemh.py" \
  "$OUT_DIR/bootloader.bin" \
  "$OUT_DIR/bootloader.hex" \
  "$BOOT_IMEM_WORDS"

echo "$OUT_DIR/bootloader.hex"
