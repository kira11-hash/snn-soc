#!/usr/bin/env bash
# Build the 4KB mask-ROM bootloader image.
#
# Outputs:
#   fw/boot_rom/out/boot_rom.elf
#   fw/boot_rom/out/boot_rom.bin
#   fw/boot_rom/out/boot_rom.hex   (1024 x 32-bit words = 4KB ROM)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FW_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
CROSS="${CROSS:-riscv64-unknown-elf}"
BOOT_ROM_WORDS=1024

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

COMMON_CFLAGS=(-I"$FW_DIR")
if [ -n "${UART_BAUD_DIV_OVERRIDE:-}" ]; then
  COMMON_CFLAGS+=("-DUART_BAUD_DIV=${UART_BAUD_DIV_OVERRIDE}")
fi

LDFLAGS=(
  -T "$SCRIPT_DIR/link_boot_rom.ld"
  -nostdlib
  -Wl,--gc-sections
  -Wl,--build-id=none
  -Wl,-Map="$OUT_DIR/boot_rom.map"
)

"$CROSS"-gcc "${CFLAGS[@]}" "${COMMON_CFLAGS[@]}" -c "$FW_DIR/crt0.S" -o "$OUT_DIR/boot_rom_crt0.o"
"$CROSS"-gcc "${CFLAGS[@]}" "${COMMON_CFLAGS[@]}" -c "$FW_DIR/uart_printf.c" -o "$OUT_DIR/boot_rom_uart.o"
"$CROSS"-gcc "${CFLAGS[@]}" "${COMMON_CFLAGS[@]}" -c "$SCRIPT_DIR/boot_rom_main.c" -o "$OUT_DIR/boot_rom_main.o"

"$CROSS"-gcc "${CFLAGS[@]}" "${LDFLAGS[@]}" \
  "$OUT_DIR/boot_rom_crt0.o" \
  "$OUT_DIR/boot_rom_main.o" \
  "$OUT_DIR/boot_rom_uart.o" \
  -lgcc \
  -o "$OUT_DIR/boot_rom.elf"

"$CROSS"-objcopy -O binary "$OUT_DIR/boot_rom.elf" "$OUT_DIR/boot_rom.bin"
"$CROSS"-objdump -d "$OUT_DIR/boot_rom.elf" > "$OUT_DIR/boot_rom.dump"

SIZE=$("$CROSS"-size "$OUT_DIR/boot_rom.elf" | awk 'NR==2{print $1+$2}')
MAX_BYTES=$((BOOT_ROM_WORDS * 4))
if [ "$SIZE" -gt "$MAX_BYTES" ]; then
  echo "[ERROR] boot ROM image too large: ${SIZE} > ${MAX_BYTES}" >&2
  exit 1
fi

python3 "$FW_DIR/bin_to_readmemh.py" \
  "$OUT_DIR/boot_rom.bin" \
  "$OUT_DIR/boot_rom.hex" \
  "$BOOT_ROM_WORDS"

echo "[INFO] boot_rom size: ${SIZE} bytes / ${MAX_BYTES} bytes"
echo "[DONE] $OUT_DIR/boot_rom.hex (${BOOT_ROM_WORDS} words)"
