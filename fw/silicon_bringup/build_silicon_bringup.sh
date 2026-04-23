#!/usr/bin/env bash
# fw/silicon_bringup/build_silicon_bringup.sh
# Compile silicon_bringup.c → ELF → $readmemh hex.
#
# Usage:
#   bash build_silicon_bringup.sh                    # default 115200@50MHz
#   CROSS=riscv32-unknown-elf bash build_silicon_bringup.sh
#   UART_BAUD_DIV_OVERRIDE=4 bash build_silicon_bringup.sh    # sim-speed
#
# Outputs (fw/silicon_bringup/out/):
#   silicon_bringup.elf   — linked ELF (stripped of debug info)
#   silicon_bringup.hex   — 4096-word $readmemh image (NOP-padded)
#   silicon_bringup.dump  — disassembly
#   silicon_bringup.map   — linker map
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FW_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
CROSS="${CROSS:-riscv64-unknown-elf}"
BOOT_IMEM_WORDS=4096  # 16KB INSTR_SRAM / 4 bytes per word

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

CFLAGS_EXTRA=(-I"$FW_DIR")
if [ -n "${UART_BAUD_DIV_OVERRIDE:-}" ]; then
  CFLAGS_EXTRA+=("-DUART_BAUD_DIV=${UART_BAUD_DIV_OVERRIDE}")
fi

LDFLAGS=(
  -T "$FW_DIR/link.ld"
  -nostdlib
  -Wl,--gc-sections
  -Wl,--build-id=none
  -Wl,-Map="$OUT_DIR/silicon_bringup.map"
)

# Compile
"$CROSS"-gcc "${CFLAGS[@]}" "${CFLAGS_EXTRA[@]}" -c "$FW_DIR/crt0.S"        -o "$OUT_DIR/silicon_bringup_crt0.o"
"$CROSS"-gcc "${CFLAGS[@]}" "${CFLAGS_EXTRA[@]}" -c "$FW_DIR/uart_printf.c" -o "$OUT_DIR/silicon_bringup_uart.o"
"$CROSS"-gcc "${CFLAGS[@]}" "${CFLAGS_EXTRA[@]}" -c "$SCRIPT_DIR/silicon_bringup.c" -o "$OUT_DIR/silicon_bringup_main.o"

# Link
"$CROSS"-gcc "${CFLAGS[@]}" "${LDFLAGS[@]}" \
  "$OUT_DIR/silicon_bringup_crt0.o" \
  "$OUT_DIR/silicon_bringup_main.o" \
  "$OUT_DIR/silicon_bringup_uart.o" \
  -lgcc \
  -o "$OUT_DIR/silicon_bringup.elf"

# Disassembly + size check
"$CROSS"-objdump -d "$OUT_DIR/silicon_bringup.elf" > "$OUT_DIR/silicon_bringup.dump"

SIZE=$("$CROSS"-size "$OUT_DIR/silicon_bringup.elf" | awk 'NR==2{print $1+$2}')
MAX_BYTES=$((BOOT_IMEM_WORDS * 4))
if [ "$SIZE" -gt "$MAX_BYTES" ]; then
  echo "[ERROR] firmware too large: ${SIZE} bytes > ${MAX_BYTES} bytes (INSTR_SRAM 16KB)" >&2
  exit 1
fi
echo "[INFO] silicon_bringup firmware size: ${SIZE} bytes / ${MAX_BYTES} bytes"

# ELF → flat bin → $readmemh hex
"$CROSS"-objcopy -O binary "$OUT_DIR/silicon_bringup.elf" "$OUT_DIR/silicon_bringup.bin"
python3 "$FW_DIR/bin_to_readmemh.py" \
  "$OUT_DIR/silicon_bringup.bin" \
  "$OUT_DIR/silicon_bringup.hex" \
  "$BOOT_IMEM_WORDS"

echo "[DONE] silicon_bringup.hex -> $OUT_DIR/silicon_bringup.hex (${BOOT_IMEM_WORDS} words)"
