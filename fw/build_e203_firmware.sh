#!/usr/bin/env bash
# Legacy FPGA/e203_tb build flow:
#   - bootloader text @ 0x0000_0000 (INSTR_SRAM directly, no boot ROM)
#   - app text        @ 0x0001_0000 (DATA_SRAM)
#   - flash image built by fw/build_flash_image.py
#
# Tape-out / silicon Day-2 flow uses the newer chain instead:
#   - fw/boot_rom/build_boot_rom.sh        (ROM bootloader @ 0x0, 4KB mask ROM)
#   - fw/link_app.ld                       (app @ 0x0000_1000 in INSTR_SRAM)
#   - scripts/make_boot_image.py           (16-byte BOOT header + payload)
set -euo pipefail

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
