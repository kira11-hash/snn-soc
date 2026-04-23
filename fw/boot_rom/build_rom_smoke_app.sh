#!/usr/bin/env bash
# Build a tiny app linked at 0x1000 for chip_top boot-ROM smoke tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FW_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
CROSS="${CROSS:-riscv64-unknown-elf}"

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

"$CROSS"-gcc "${CFLAGS[@]}" "${COMMON_CFLAGS[@]}" -c "$FW_DIR/crt0.S" -o "$OUT_DIR/rom_smoke_crt0.o"
"$CROSS"-gcc "${CFLAGS[@]}" "${COMMON_CFLAGS[@]}" -c "$FW_DIR/uart_printf.c" -o "$OUT_DIR/rom_smoke_uart.o"
"$CROSS"-gcc "${CFLAGS[@]}" "${COMMON_CFLAGS[@]}" -c "$SCRIPT_DIR/rom_smoke_app.c" -o "$OUT_DIR/rom_smoke_app.o"

"$CROSS"-gcc "${CFLAGS[@]}" \
  -T "$FW_DIR/link_app.ld" \
  -nostdlib \
  -Wl,--gc-sections \
  -Wl,--build-id=none \
  -Wl,-Map="$OUT_DIR/rom_smoke_app.map" \
  "$OUT_DIR/rom_smoke_crt0.o" \
  "$OUT_DIR/rom_smoke_app.o" \
  "$OUT_DIR/rom_smoke_uart.o" \
  -lgcc \
  -o "$OUT_DIR/rom_smoke_app.elf"

"$CROSS"-objcopy -O binary "$OUT_DIR/rom_smoke_app.elf" "$OUT_DIR/rom_smoke_app.bin"
"$CROSS"-objdump -d "$OUT_DIR/rom_smoke_app.elf" > "$OUT_DIR/rom_smoke_app.dump"

echo "[DONE] $OUT_DIR/rom_smoke_app.bin"
