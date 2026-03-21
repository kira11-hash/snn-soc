#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

LDFLAGS=(
  -T "$SCRIPT_DIR/link.ld"
  -nostdlib
  -Wl,--gc-sections
  -Wl,--build-id=none
  -Wl,-Map="$OUT_DIR/jtag_rescue.map"
)

COMMON_CFLAGS=(-I"$SCRIPT_DIR")
if [ -n "${UART_BAUD_DIV_OVERRIDE:-}" ]; then
  COMMON_CFLAGS+=("-DUART_BAUD_DIV=${UART_BAUD_DIV_OVERRIDE}")
fi

"$CROSS"-gcc "${CFLAGS[@]}" "${COMMON_CFLAGS[@]}" -c "$SCRIPT_DIR/crt0.S" -o "$OUT_DIR/jtag_rescue_crt0.o"
"$CROSS"-gcc "${CFLAGS[@]}" "${COMMON_CFLAGS[@]}" -c "$SCRIPT_DIR/uart_printf.c" -o "$OUT_DIR/jtag_rescue_uart_printf.o"
"$CROSS"-gcc "${CFLAGS[@]}" "${COMMON_CFLAGS[@]}" -c "$SCRIPT_DIR/jtag_rescue_main.c" -o "$OUT_DIR/jtag_rescue_main.o"

"$CROSS"-gcc "${CFLAGS[@]}" "${LDFLAGS[@]}" \
  "$OUT_DIR/jtag_rescue_crt0.o" "$OUT_DIR/jtag_rescue_main.o" "$OUT_DIR/jtag_rescue_uart_printf.o" \
  -lgcc \
  -o "$OUT_DIR/jtag_rescue.elf"

"$CROSS"-objcopy -O binary "$OUT_DIR/jtag_rescue.elf" "$OUT_DIR/jtag_rescue.bin"
"$CROSS"-objdump -d "$OUT_DIR/jtag_rescue.elf" > "$OUT_DIR/jtag_rescue.dump"

JTAG_RESCUE_WORDS=$(( ($(wc -c < "$OUT_DIR/jtag_rescue.bin") + 3) / 4 ))
python3 "$SCRIPT_DIR/bin_to_readmemh.py" \
  "$OUT_DIR/jtag_rescue.bin" \
  "$OUT_DIR/jtag_rescue_imem.hex" \
  "$JTAG_RESCUE_WORDS"

printf '%s\n' "$JTAG_RESCUE_WORDS" > "$OUT_DIR/jtag_rescue_words.txt"
echo "$OUT_DIR/jtag_rescue_imem.hex"
