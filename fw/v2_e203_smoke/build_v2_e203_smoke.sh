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
#   out/v2_e203_smoke.elf   + .bin + .hex
#   out/v2_e203_encoder.elf + .bin + .hex

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

CROSS="${CROSS:-riscv64-unknown-elf-}"
CC="${CROSS}gcc"
OBJCOPY="${CROSS}objcopy"
SIZE="${CROSS}size"

# NUM_COSIM_SAMPLES can be overridden from env to bound Icarus wall-clock;
# default 3 is enough to prove firmware→RTL bit-exact (FPGA G3 ups this to 10).
NUM_COSIM_SAMPLES="${NUM_COSIM_SAMPLES:-3}"

CFLAGS="-march=rv32i_zicsr_zifencei -mabi=ilp32 -O2 -ffreestanding -nostdlib \
        -fno-pic -mcmodel=medany -ffunction-sections -fdata-sections \
        -Wall -Wextra -Werror \
        -DNUM_COSIM_SAMPLES=${NUM_COSIM_SAMPLES} \
        -DICARUS_SKIP_ENCODE \
        -Iinclude -I../include"

LDFLAGS_COMMON="-nostdlib -Wl,--gc-sections -Wl,--print-memory-usage"

# gen_bram_init 路径 (仓库根 scripts/gen_bram_init.py)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
GEN_HEX_PY="$REPO_ROOT/scripts/gen_bram_init.py"
WORDS=16384  # 64 KB / 4 = 16384 words

mkdir -p out

build_one() {
    local variant=$1      # smoke | encoder
    local main_src=$2
    local ldscript=$3

    local elf="out/v2_e203_${variant}.elf"
    local binf="out/v2_e203_${variant}.bin"
    local hex="out/v2_e203_${variant}.hex"

    echo "=== Building $variant ==="
    $CC $CFLAGS \
        src/crt0_v2_e203.S \
        src/uart_printf_v2e203.c \
        src/v2b_scheduler_e203.c \
        src/golden_fashion10.c \
        "$main_src" \
        -T "$ldscript" \
        $LDFLAGS_COMMON \
        -Wl,-Map="out/v2_e203_${variant}.map" \
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
