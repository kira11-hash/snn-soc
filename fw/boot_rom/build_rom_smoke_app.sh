#!/usr/bin/env bash
# Build a tiny app linked into INSTR_SRAM for chip_top boot-ROM smoke tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FW_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
CROSS="${CROSS:-riscv64-unknown-elf}"
APP_LINKER="${APP_LINKER:-$FW_DIR/link_app.ld}"
APP_SRC="${APP_SRC:-$SCRIPT_DIR/rom_smoke_app.c}"
APP_NAME="${APP_NAME:-rom_smoke_app}"
ROM_SMOKE_ADDR="${ROM_SMOKE_ADDR:-}"

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
if [ -n "$ROM_SMOKE_ADDR" ]; then
  COMMON_CFLAGS+=("-DROM_SMOKE_ADDR=${ROM_SMOKE_ADDR}")
fi

"$CROSS"-gcc "${CFLAGS[@]}" "${COMMON_CFLAGS[@]}" -c "$FW_DIR/crt0.S" -o "$OUT_DIR/${APP_NAME}_crt0.o"
"$CROSS"-gcc "${CFLAGS[@]}" "${COMMON_CFLAGS[@]}" -c "$FW_DIR/uart_printf.c" -o "$OUT_DIR/${APP_NAME}_uart.o"
"$CROSS"-gcc "${CFLAGS[@]}" "${COMMON_CFLAGS[@]}" -c "$APP_SRC" -o "$OUT_DIR/${APP_NAME}.o"

"$CROSS"-gcc "${CFLAGS[@]}" \
  -T "$APP_LINKER" \
  -nostdlib \
  -Wl,--gc-sections \
  -Wl,--build-id=none \
  -Wl,-Map="$OUT_DIR/${APP_NAME}.map" \
  "$OUT_DIR/${APP_NAME}_crt0.o" \
  "$OUT_DIR/${APP_NAME}.o" \
  "$OUT_DIR/${APP_NAME}_uart.o" \
  -lgcc \
  -o "$OUT_DIR/${APP_NAME}.elf"

"$CROSS"-objcopy -O binary "$OUT_DIR/${APP_NAME}.elf" "$OUT_DIR/${APP_NAME}.bin"
"$CROSS"-objdump -d "$OUT_DIR/${APP_NAME}.elf" > "$OUT_DIR/${APP_NAME}.dump"

SIZE=$("$CROSS"-size "$OUT_DIR/${APP_NAME}.elf" | awk 'NR==2{print $1+$2}')
if [ "$SIZE" -gt 2048 ]; then
  echo "[ERROR] ${APP_NAME}.elf too large for high-window smoke assumptions: ${SIZE} bytes" >&2
  exit 1
fi

echo "[DONE] $OUT_DIR/${APP_NAME}.bin"
