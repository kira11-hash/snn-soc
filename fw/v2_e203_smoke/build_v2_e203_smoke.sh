#!/usr/bin/env bash
# fw/v2_e203_smoke/build_v2_e203_smoke.sh
#
# Build 2 ELFs (smoke + encoder) for V2E203 FPGA branch. Runs under WSL
# (riscv64-unknown-elf-gcc 13.2+).
#
# Usage:
#   wsl bash -c "cd /mnt/d/'SoC Design'/'SoC Design'/fw/v2_e203_smoke && bash build_v2_e203_smoke.sh"
#   or from Windows git-bash if CROSS prefix resolves.
#
# Output:
#   SIM_FAST=0 -> out/v2_e203_smoke.elf   + .bin + .hex
#                  out/v2_e203_encoder.elf + .bin + .hex
#   SIM_FAST=1 -> out_simfast/v2_e203_smoke.elf   + .bin + .hex
#                  out_simfast/v2_e203_encoder.elf + .bin + .hex

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

CROSS="${CROSS:-riscv64-unknown-elf-}"
case "$CROSS" in
    *-) ;;
    *) CROSS="${CROSS}-" ;;
esac
CC="${CROSS}gcc"
OBJCOPY="${CROSS}objcopy"
SIZE="${CROSS}size"

# Default build is board-ready: full 10 samples and real encoder.
# Set SIM_FAST=1 for Icarus-only smoke runs; that mode bounds the sample
# loop and replaces the slow encoder body with an RPC marker path.
SIM_FAST="${SIM_FAST:-0}"
EXTRA_DEFS=""
if [ "$SIM_FAST" = "1" ]; then
    NUM_COSIM_SAMPLES="${NUM_COSIM_SAMPLES:-3}"
    EXTRA_DEFS="$EXTRA_DEFS -DNUM_COSIM_SAMPLES=${NUM_COSIM_SAMPLES} -DICARUS_SKIP_ENCODE"
    echo "[INFO] SIM_FAST=1: NUM_COSIM_SAMPLES=${NUM_COSIM_SAMPLES}, encoder skip path enabled"
    OUT_DIR="${OUT_DIR:-out_simfast}"
else
    echo "[INFO] board-ready firmware build: GOLDEN_NUM_SAMPLES=10, real encoder path enabled"
    OUT_DIR="${OUT_DIR:-out}"
fi

CFLAGS="-march=rv32i_zicsr_zifencei -mabi=ilp32 -O2 -ffreestanding -nostdlib \
        -fno-pic -mcmodel=medany -ffunction-sections -fdata-sections \
        -Wall -Wextra -Werror \
        ${EXTRA_DEFS} \
        -Iinclude -I../include"

LDFLAGS_COMMON="-nostdlib -Wl,--gc-sections -Wl,--print-memory-usage"

# gen_bram_init 路径 (仓库根 scripts/gen_bram_init.py)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
GEN_HEX_PY="$REPO_ROOT/scripts/gen_bram_init.py"
WORDS=16384  # 64 KB / 4 = 16384 words

mkdir -p "$OUT_DIR"

build_one() {
    local variant=$1      # smoke | encoder
    local main_src=$2
    local ldscript=$3

    local elf="$OUT_DIR/v2_e203_${variant}.elf"
    local binf="$OUT_DIR/v2_e203_${variant}.bin"
    local hex="$OUT_DIR/v2_e203_${variant}.hex"

    echo "=== Building $variant ==="
    $CC $CFLAGS \
        src/crt0_v2_e203.S \
        src/uart_printf_v2e203.c \
        src/v2b_scheduler_e203.c \
        src/golden_fashion10.c \
        "$main_src" \
        -T "$ldscript" \
        $LDFLAGS_COMMON \
        -Wl,-Map="$OUT_DIR/v2_e203_${variant}.map" \
        -o "$elf"

    $OBJCOPY -O binary "$elf" "$binf"
    $SIZE "$elf"

    # ELF → $readmemh hex, zero-pad to 16384 words
    python3 "$GEN_HEX_PY" "$elf" "$hex" "$WORDS"

    echo "=== $variant build OK: $elf ==="
}

build_one smoke   src/v2_e203_smoke_main.c   link_v2_e203_smoke.ld
build_one encoder src/v2_e203_encoder_main.c link_v2_e203_encoder.ld

echo ""
echo "V2_E203_FW_BUILD_PASS"
