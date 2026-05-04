#!/usr/bin/env bash
# fw/e203_smoke/build_e203_smoke.sh
# Compile e203_fpga_smoke.c → ELF → hex for Vivado BRAM pre-init.
#
# Usage:
#   bash build_e203_smoke.sh               # default: UART_BAUD_DIV=434 (50 MHz / 115200)
#   CROSS=riscv32-unknown-elf bash build_e203_smoke.sh
#   UART_BAUD_DIV_OVERRIDE=4 bash build_e203_smoke.sh  # sim-speed override
#
# Outputs:
#   out/e203_smoke.elf   — stripped ELF
#   out/e203_smoke.hex   — $readmemh-compatible word-wide hex (4096 words, NOP-padded)
#   out/e203_smoke.dump  — disassembly for debug
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FW_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$FW_DIR/.." && pwd)"
OUT_DIR="out"
CROSS="${CROSS:-riscv64-unknown-elf}"
BOOT_IMEM_WORDS=4096  # 16KB INSTR_SRAM / 4 bytes per word

cd "$SCRIPT_DIR"
mkdir -p "$OUT_DIR"

if ! command -v "$CROSS"-gcc >/dev/null 2>&1; then
  if command -v wsl.exe >/dev/null 2>&1 && [ -z "${E203_SMOKE_WSL_REEXEC:-}" ]; then
    ROOT_WIN="$(cd "$ROOT_DIR" && pwd -W 2>/dev/null || true)"
    if [ -n "$ROOT_WIN" ]; then
      ROOT_WSL="$(wsl.exe wslpath -a "$ROOT_WIN" 2>/dev/null | tr -d '\r')"
      if [ -n "$ROOT_WSL" ] && \
         wsl.exe bash -lc "command -v '$CROSS-gcc' >/dev/null 2>&1 && command -v '$CROSS-objcopy' >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1"; then
        echo "[INFO] local $CROSS toolchain not found; retrying build inside WSL"
        wsl.exe bash -lc "cd '$ROOT_WSL' && E203_SMOKE_WSL_REEXEC=1 CROSS='$CROSS' UART_BAUD_DIV_OVERRIDE='${UART_BAUD_DIV_OVERRIDE:-}' bash 'fw/e203_smoke/build_e203_smoke.sh'"
        exit $?
      fi
    fi
  fi
  echo "[ERROR] missing $CROSS-gcc. Install the toolchain locally or make it available inside WSL." >&2
  exit 127
fi

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

CFLAGS_EXTRA=(-I..)
if [ -n "${UART_BAUD_DIV_OVERRIDE:-}" ]; then
  CFLAGS_EXTRA+=("-DUART_BAUD_DIV=${UART_BAUD_DIV_OVERRIDE}")
fi

LDFLAGS=(
  -T "../link.ld"
  -nostdlib
  -Wl,--gc-sections
  -Wl,--build-id=none
  -Wl,-Map="$OUT_DIR/e203_smoke.map"
)

# Compile
"$CROSS"-gcc "${CFLAGS[@]}" "${CFLAGS_EXTRA[@]}" -c "../crt0.S"       -o "$OUT_DIR/e203_smoke_crt0.o"
"$CROSS"-gcc "${CFLAGS[@]}" "${CFLAGS_EXTRA[@]}" -c "../uart_printf.c" -o "$OUT_DIR/e203_smoke_uart.o"
"$CROSS"-gcc "${CFLAGS[@]}" "${CFLAGS_EXTRA[@]}" -c "$SCRIPT_DIR/e203_fpga_smoke.c" -o "$OUT_DIR/e203_smoke_main.o"

# Link
"$CROSS"-gcc "${CFLAGS[@]}" "${LDFLAGS[@]}" \
  "$OUT_DIR/e203_smoke_crt0.o" \
  "$OUT_DIR/e203_smoke_main.o" \
  "$OUT_DIR/e203_smoke_uart.o" \
  -lgcc \
  -o "$OUT_DIR/e203_smoke.elf"

# Disassembly for debug
"$CROSS"-objdump -d "$OUT_DIR/e203_smoke.elf" > "$OUT_DIR/e203_smoke.dump"

# ELF size check
SIZE=$("$CROSS"-size "$OUT_DIR/e203_smoke.elf" | awk 'NR==2{print $1+$2}')
MAX_BYTES=$((BOOT_IMEM_WORDS * 4))
if [ "$SIZE" -gt "$MAX_BYTES" ]; then
  echo "[ERROR] firmware too large: ${SIZE} bytes > ${MAX_BYTES} bytes (INSTR_SRAM 16KB)" >&2
  exit 1
fi
echo "[INFO] firmware size: ${SIZE} bytes / ${MAX_BYTES} bytes"

# Convert ELF → flat binary → $readmemh hex
"$CROSS"-objcopy -O binary "$OUT_DIR/e203_smoke.elf" "$OUT_DIR/e203_smoke.bin"
python3 "../bin_to_readmemh.py" \
  "$OUT_DIR/e203_smoke.bin" \
  "$OUT_DIR/e203_smoke.hex" \
  "$BOOT_IMEM_WORDS"

echo "[DONE] $OUT_DIR/e203_smoke.hex"
