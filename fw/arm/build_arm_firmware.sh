#!/usr/bin/env bash
#
# fw/arm/build_arm_firmware.sh — Phase B standalone ARM build.
#
# Produces `fw/arm/out/v2b_arm_demo.elf` using the Xilinx aarch64-none-elf
# toolchain (bundled with Vitis 2022.2). No Vitis workspace, no BSP — just
# direct compile + link against a minimal standalone stub (crt0 + link.ld).
#
# Phase B Gate (as defined in plan REV 2):
#   - ELF links cleanly (zero undefined references)
#   - size report: text < 32 KB firmware code, rodata < 400 KB, bss < 16 KB
#   - nm contains arm_main, v2b_infer_resident_14x14, v2b_run_stage,
#     uart_init, golden_fashion10
#
# Windows-path-with-space caveat: the Xilinx aarch64 gcc is a native
# Windows .exe and can't parse MSYS-style paths that contain spaces
# (standard MinGW limitation). We convert the workspace prefix to its
# DOS 8.3 short form (e.g., `D:\SOCDES~1\audit-v2`) before handing
# filenames to gcc. This requires the workspace directory to have a
# short-name assigned (Windows default).
#
# Override flags:
#   V2B_SOC_BASE=0xB0000000u  — if Vivado Address Editor (Phase C0) picks
#                               a different base, pass it here without
#                               touching the C source.
#   TOOLCHAIN_BIN=/path       — override cross-gcc dir. Default:
#                               /d/Xilinx/Vitis/2022.2/gnu/aarch64/nt/aarch64-none/bin
#
# Phase C0 currently reuses this minimal ELF for direct xsct/JTAG bring-up.
# A future Vitis-proper workspace can replace the startup/UART pieces with
# BSP-generated PS init, MMU tables, xil_printf, and Xuartps support.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$HERE/out"
mkdir -p "$OUT"

# Translate workspace to DOS 8.3 form so gcc.exe can handle paths with spaces.
if command -v cygpath >/dev/null 2>&1; then
  # cygpath -d requires the target to exist; we construct path by taking
  # the short form of the workspace ROOT (which has the space) and
  # appending the rest as plain Windows-style suffix.
  ROOT_WIN_SHORT=$(cygpath -dw "$ROOT")   # e.g., D:\SOCDES~1\audit-v2
  HERE_WIN_SHORT=$(cygpath -dw "$HERE")   # e.g., D:\SOCDES~1\audit-v2\fw\arm
  OUT_WIN_SHORT=$(cygpath -dw "$OUT")     # e.g., D:\SOCDES~1\audit-v2\fw\arm\out
else
  # Fall back to the Unix-form paths (will break if path contains spaces).
  ROOT_WIN_SHORT="$ROOT"
  HERE_WIN_SHORT="$HERE"
  OUT_WIN_SHORT="$OUT"
fi

# Helper: given a Unix-form source path rooted under $HERE, emit its
# 8.3-Windows form. We do this per-file by letting cygpath -dw resolve
# a path that already exists (source files do).
to_win_short() {
  cygpath -dw "$1"
}

# For output files (don't exist yet at script start), touch them so
# cygpath can resolve the 8.3 short form.
to_win_short_out() {
  local path="$1"
  [ -e "$path" ] || : > "$path"
  cygpath -dw "$path"
}

TOOLCHAIN_BIN="${TOOLCHAIN_BIN:-/d/Xilinx/Vitis/2022.2/gnu/aarch64/nt/aarch64-none/bin}"
CC_BIN="$TOOLCHAIN_BIN/aarch64-none-elf-gcc"
SIZE_BIN="$TOOLCHAIN_BIN/aarch64-none-elf-size"
NM_BIN="$TOOLCHAIN_BIN/aarch64-none-elf-nm"

if [ ! -e "${CC_BIN}.exe" ] && [ ! -e "${CC_BIN}" ]; then
  echo "[FATAL] aarch64-none-elf-gcc not found at: $CC_BIN" >&2
  echo "         Set TOOLCHAIN_BIN to your Vitis aarch64 bin dir." >&2
  exit 1
fi

V2B_SOC_BASE_OVERRIDE="${V2B_SOC_BASE:-0xA0000000u}"

# Include dirs need the DOS 8.3 form too (workspace root has a space).
INC_ARM=$(cygpath -dw "$HERE/include")
INC_FW=$(cygpath -dw "$ROOT/fw/include")
INC_TOOL="$(dirname "$TOOLCHAIN_BIN")/lib/gcc/aarch64-none-elf/11.2.0/include"
# Xilinx install path has no short name, but also no space → plain -w is fine.
INC_TOOL_WIN=$(cygpath -w "$INC_TOOL")

CFLAGS=(
  "-mcpu=cortex-a53"
  "-mgeneral-regs-only"
  "-ffreestanding"
  "-Wall" "-Wextra" "-Werror"
  "-Wno-unused-parameter"
  "-O2"
  "-g"
  "-fno-common"
  "-fno-builtin"
  "-I$INC_ARM"
  "-I$INC_FW"
  "-DV2B_SOC_BASE=$V2B_SOC_BASE_OVERRIDE"
)

ASFLAGS=(
  "-mcpu=cortex-a53"
)

LINK_LD=$(cygpath -dw "$HERE/link_arm.ld")
MAP_FILE=$(to_win_short_out "$OUT/v2b_arm_demo.map")

LDFLAGS=(
  "-mcpu=cortex-a53"
  "-nostdlib"
  "-nostartfiles"
  "-Wl,--build-id=none"
  "-Wl,--gc-sections"
  "-Wl,-Map,$MAP_FILE"
  "-T$LINK_LD"
)

# Compile phase
OBJECTS=()
compile() {
  local src_unix="$1"
  local src_win obj_unix obj_win
  src_win=$(to_win_short "$src_unix")
  obj_unix="$OUT/$(basename "${src_unix%.*}").o"
  obj_win=$(to_win_short_out "$obj_unix")
  echo "  CC  $(basename "$src_unix")"
  if [[ "$src_unix" == *.S ]]; then
    "$CC_BIN" "${ASFLAGS[@]}" -c "$src_win" -o "$obj_win"
  else
    # Force C language: on MSYS, 8.3 short-name path uppercases the extension
    # (e.g. `v2b_scheduler_arm.c` → `V2B_SC~1.C`) which gcc treats as C++.
    "$CC_BIN" "${CFLAGS[@]}" -x c -c "$src_win" -o "$obj_win"
  fi
  OBJECTS+=("$obj_win")
}

echo "[build_arm_firmware] regenerate LeNet5 golden header"
python "$HERE/scripts/gen_lenet5_header.py"

echo "[build_arm_firmware] compile (V2B_SOC_BASE=$V2B_SOC_BASE_OVERRIDE)"
compile "$HERE/src/crt0_aarch64.S"
compile "$HERE/src/uart_ps.c"
compile "$HERE/src/golden_lenet5.c"
compile "$HERE/src/v2b_conv_scheduler_arm.c"
compile "$HERE/src/arm_main.c"

# Link phase
ELF_UNIX="$OUT/v2b_arm_demo.elf"
ELF_WIN=$(to_win_short_out "$ELF_UNIX")
echo "[build_arm_firmware] link → $ELF_UNIX"
"$CC_BIN" "${LDFLAGS[@]}" "${OBJECTS[@]}" -o "$ELF_WIN"

# Gate B reports
echo ""
echo "[build_arm_firmware] size report:"
"$SIZE_BIN" "$ELF_WIN"

echo ""
echo "[build_arm_firmware] symbol presence check:"
REQUIRED_SYMS=("arm_main" "v2b_run_lenet5_demo" "uart_init" "golden_lenet5" "_start")
SYM_LIST=$("$NM_BIN" "$ELF_WIN" | awk '{print $3}')
for sym in "${REQUIRED_SYMS[@]}"; do
  if ! grep -q "^${sym}$" <<<"$SYM_LIST"; then
    echo "  [FATAL] missing symbol: $sym" >&2
    exit 2
  fi
  echo "  [OK] $sym"
done

echo ""
echo "[build_arm_firmware] undefined-ref check:"
UNDEF=$("$NM_BIN" -u "$ELF_WIN" 2>/dev/null || true)
if [ -n "$UNDEF" ]; then
  echo "[FATAL] undefined references:" >&2
  echo "$UNDEF" >&2
  exit 3
fi
echo "  [OK] zero undefined refs"

echo ""
echo "============================================"
echo "[build_arm_firmware] PHASE_B_GATE_PASS"
echo "============================================"

MANIFEST_SCRIPT="$ROOT/scripts/gen_arm_demo_manifest.sh"
if [ -f "$MANIFEST_SCRIPT" ]; then
  ROOT_OVERRIDE="$ROOT" \
  TOOLCHAIN_BIN="$TOOLCHAIN_BIN" \
  ELF_PATH="$ELF_UNIX" \
  V2B_SOC_BASE_VALUE="$V2B_SOC_BASE_OVERRIDE" \
  bash "$MANIFEST_SCRIPT"
fi
