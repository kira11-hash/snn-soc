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
if [ "${SILICON_BRINGUP_SIM_FAST:-0}" = "1" ]; then
  CFLAGS_EXTRA+=("-DSILICON_BRINGUP_SIM_FAST=1")
fi

# audit-pass4 M-1: SOURCE_DATE_EPOCH-aware build id.
#   - default: "frozen" → identical .hex on every machine; tracked golden
#     stays clean across rebuilds, no daily churn from __DATE__.
#   - opt-in:  set SOURCE_DATE_EPOCH (e.g. `git log -1 --format=%ct` of the
#     commit that's about to ship) to embed a real YYYY-MM-DD instead.
# The C side falls back to "frozen" via #ifndef when this is absent, so the
# binary still links if you compile by hand without the wrapper script.
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
  if SBR_BUILD_ID=$(date -u -d "@${SOURCE_DATE_EPOCH}" "+%Y-%m-%d" 2>/dev/null); then
    :
  else
    SBR_BUILD_ID="frozen"
  fi
else
  SBR_BUILD_ID="frozen"
fi
CFLAGS_EXTRA+=("-DSILICON_BRINGUP_BUILD_ID=\"${SBR_BUILD_ID}\"")
echo "[INFO] silicon_bringup build_id='${SBR_BUILD_ID}' (set SOURCE_DATE_EPOCH to override)"

LINK_SCRIPT="$FW_DIR/link_app.ld"
if [ "${SILICON_BRINGUP_LEGACY_SIM:-0}" = "1" ]; then
  # Fast Icarus regression path: boot-ROM / 0x1000 handoff is already covered
  # by chip_top_rom_smoke TBs, so this wrapper is allowed to run silicon_bringup
  # on the legacy instr_sram@0x0 path for practical wall-clock.
  LINK_SCRIPT="$FW_DIR/link.ld"
fi

# Production / board / silicon default remains 0x1000 via link_app.ld.
LDFLAGS=(
  -T "$LINK_SCRIPT"
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
