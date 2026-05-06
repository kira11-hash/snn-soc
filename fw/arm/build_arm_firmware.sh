#!/usr/bin/env bash
#
# fw/arm/build_arm_firmware.sh — Phase B 独立 ARM 构建脚本。
#
# 输出 `fw/arm/out/v2b_arm_demo.elf`，使用 Xilinx aarch64-none-elf 工具链
# （Vitis 2022.2 自带）。不依赖 Vitis workspace、不依赖 BSP，直接对最小化
# standalone stub（crt0 + link.ld）做 compile + link。
#
# Phase B Gate（plan REV 2 定义）：
#   - ELF 链接干净（0 个 undefined refs）
#   - size 报告满足预算（v2-conv 已扩到 LeNet-5 后 .text + .rodata ≈ 150 KB）
#   - nm 包含 arm_main / v2b_run_lenet5_demo / uart_init / golden_lenet5 / _start
#
# Windows 路径含空格的处理（关键）：Xilinx aarch64 gcc 是原生 Windows .exe，
# 无法直接处理 MSYS 风格的含空格路径（MinGW 通用限制）。脚本把 workspace
# 前缀转成 DOS 8.3 短名（如 `D:\SOCDES~1\audit-v2`）再传给 gcc。这要求
# Windows 目录已分配短名（默认行为）。
#
# 可覆盖的环境变量：
#   V2B_SOC_BASE=0xB0000000u   — Vivado Address Editor（Phase C0）若改了 base，
#                                直接在编译时传入即可，无需改 C 源码。
#   TOOLCHAIN_BIN=/path         — 覆盖交叉 gcc 路径。默认：
#                                 /d/Xilinx/Vitis/2022.2/gnu/aarch64/nt/aarch64-none/bin
#   ARM_FW_VARIANT=lenet5|fashion14
#                               — 选择当前要生成的 ARM firmware 入口。
#   ARM_FW_EXTRA_DEFS="-DMACRO=VALUE ..."
#                               — 追加给 C 编译阶段的额外宏定义。
#
# Phase C0 当前直接复用本脚本输出的 ELF 走 xsct/JTAG bring-up。
# 后续可改造成 Vitis BSP workspace（含 PS init、MMU tables、xil_printf、Xuartps），
# 但本评估周期保持 standalone 路径，控制变量。

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$HERE/out"
mkdir -p "$OUT"

is_wsl_shell() {
  [ -n "${WSL_DISTRO_NAME:-}" ]
}

default_toolchain_bin() {
  local candidates=(
    "/d/Xilinx/Vitis/2022.2/gnu/aarch64/nt/aarch64-none/bin"
  )
  if is_wsl_shell; then
    candidates+=("/mnt/d/Xilinx/Vitis/2022.2/gnu/aarch64/nt/aarch64-none/bin")
  fi
  candidates+=("/c/Xilinx/Vitis/2022.2/gnu/aarch64/nt/aarch64-none/bin")
  if is_wsl_shell; then
    candidates+=("/mnt/c/Xilinx/Vitis/2022.2/gnu/aarch64/nt/aarch64-none/bin")
  fi

  local candidate
  for candidate in "${candidates[@]}"; do
    if [ -e "$candidate/aarch64-none-elf-gcc.exe" ] || [ -e "$candidate/aarch64-none-elf-gcc" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '%s\n' "${candidates[0]}"
}

# 把 workspace 路径翻译成 DOS 8.3 短名，让 gcc.exe 能处理带空格的路径。
if command -v cygpath >/dev/null 2>&1; then
  # cygpath -d 要求目标已存在；先把 workspace ROOT（含空格）转成短名，
  # 再把剩下的相对部分按 Windows 风格拼上。
  ROOT_WIN_SHORT=$(cygpath -dw "$ROOT")   # 例：D:\SOCDES~1\audit-v2
  HERE_WIN_SHORT=$(cygpath -dw "$HERE")   # 例：D:\SOCDES~1\audit-v2\fw\arm
  OUT_WIN_SHORT=$(cygpath -dw "$OUT")     # 例：D:\SOCDES~1\audit-v2\fw\arm\out
else
  # 没 cygpath 时退回 Unix 风格路径（路径含空格会失败）。
  ROOT_WIN_SHORT="$ROOT"
  HERE_WIN_SHORT="$HERE"
  OUT_WIN_SHORT="$OUT"
fi

# 工具函数：把 $HERE 下的 Unix 风格路径转成 8.3 Windows 短名。
# 因为 cygpath -dw 要求文件已存在，这一支只用于已有的 source 文件。
to_win_short() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -dw "$1"
    return 0
  fi
  if is_wsl_shell && command -v wslpath >/dev/null 2>&1; then
    wslpath -w "$1" | tr -d '\r'
    return 0
  fi
  printf '%s\n' "$1"
}

# 输出文件在脚本开始时还不存在；先 touch 一下让 cygpath 能解析短名。
to_win_short_out() {
  local path="$1"
  [ -e "$path" ] || : > "$path"
  to_win_short "$path"
}

TOOLCHAIN_BIN="${TOOLCHAIN_BIN:-$(default_toolchain_bin)}"
CC_BIN="$TOOLCHAIN_BIN/aarch64-none-elf-gcc"
SIZE_BIN="$TOOLCHAIN_BIN/aarch64-none-elf-size"
NM_BIN="$TOOLCHAIN_BIN/aarch64-none-elf-nm"

if [ ! -e "${CC_BIN}.exe" ] && [ ! -e "${CC_BIN}" ]; then
  echo "[FATAL] 找不到 aarch64-none-elf-gcc：$CC_BIN" >&2
  echo "         请把 TOOLCHAIN_BIN 设到 Vitis aarch64 bin 目录。" >&2
  if is_wsl_shell; then
    echo "         当前是 WSL shell；优先尝试 /mnt/d/Xilinx/...，不要用默认的 /d/...。" >&2
  fi
  exit 1
fi

V2B_SOC_BASE_OVERRIDE="${V2B_SOC_BASE:-0xA0000000u}"
ARM_FW_VARIANT="${ARM_FW_VARIANT:-lenet5}"
ARM_FW_EXTRA_DEFS="${ARM_FW_EXTRA_DEFS:-}"

# Include 路径同样需要转 8.3 短名（仓库根目录含空格）
INC_ARM=$(to_win_short "$HERE/include")
INC_FW=$(to_win_short "$ROOT/fw/include")
INC_TOOL="$(dirname "$TOOLCHAIN_BIN")/lib/gcc/aarch64-none-elf/11.2.0/include"

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

if [ -n "$ARM_FW_EXTRA_DEFS" ]; then
  # Intentionally split on shell words so callers can pass multiple -D flags.
  # Example:
  #   ARM_FW_EXTRA_DEFS="-DFOO=1 -DBAR=2"
  # shellcheck disable=SC2206
  EXTRA_DEF_WORDS=($ARM_FW_EXTRA_DEFS)
  CFLAGS+=("${EXTRA_DEF_WORDS[@]}")
fi

ASFLAGS=(
  "-mcpu=cortex-a53"
)

LINK_LD=$(to_win_short "$HERE/link_arm.ld")
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

# 编译阶段
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
    # 强制 C 语言：在 MSYS 下 8.3 短名会把扩展名改成大写
    # （例如 v2b_scheduler_arm.c → V2B_SC~1.C），gcc 默认把 .C 当 C++ 编。
    "$CC_BIN" "${CFLAGS[@]}" -x c -c "$src_win" -o "$obj_win"
  fi
  OBJECTS+=("$obj_win")
}

echo "[build_arm_firmware] 目标 variant: $ARM_FW_VARIANT"
echo "[build_arm_firmware] 编译（V2B_SOC_BASE=$V2B_SOC_BASE_OVERRIDE）"
compile "$HERE/src/crt0_aarch64.S"
compile "$HERE/src/uart_ps.c"
compile "$ROOT/fw/src/v2b_trace_hash.c"

REQUIRED_SYMS=()
case "$ARM_FW_VARIANT" in
  lenet5)
    echo "[build_arm_firmware] 重新生成 LeNet-5 黄金参考 header"
    python "$HERE/scripts/gen_lenet5_header.py"
    compile "$HERE/src/golden_lenet5.c"
    compile "$HERE/src/v2b_conv_scheduler_arm.c"
    compile "$HERE/src/arm_main.c"
    REQUIRED_SYMS=("arm_main" "v2b_run_lenet5_demo_trace" "uart_init" "golden_lenet5" "_start")
    ;;
  fashion14)
    echo "[build_arm_firmware] 重新生成 Fashion14 黄金参考 header"
    python "$HERE/scripts/gen_golden_header.py"
    compile "$HERE/src/golden_fashion10.c"
    compile "$HERE/src/v2b_scheduler_arm.c"
    compile "$HERE/src/arm_main_fashion14.c"
    REQUIRED_SYMS=("arm_main" "v2b_infer_resident_14x14_trace" "uart_init" "golden_fashion10" "_start")
    ;;
  *)
    echo "[FATAL] unsupported ARM_FW_VARIANT=$ARM_FW_VARIANT" >&2
    exit 4
    ;;
esac

# 链接阶段
ELF_UNIX="$OUT/v2b_arm_demo.elf"
ELF_WIN=$(to_win_short_out "$ELF_UNIX")
echo "[build_arm_firmware] 链接 → $ELF_UNIX"
"$CC_BIN" "${LDFLAGS[@]}" "${OBJECTS[@]}" -o "$ELF_WIN"

# Gate B 报告
echo ""
echo "[build_arm_firmware] size 报告："
"$SIZE_BIN" "$ELF_WIN"

echo ""
echo "[build_arm_firmware] 关键符号存在性检查："
SYM_LIST=$("$NM_BIN" "$ELF_WIN" | awk '{print $3}')
for sym in "${REQUIRED_SYMS[@]}"; do
  if ! grep -q "^${sym}$" <<<"$SYM_LIST"; then
    echo "  [FATAL] 缺少符号: $sym" >&2
    exit 2
  fi
  echo "  [OK] $sym"
done

echo ""
echo "[build_arm_firmware] 未解析引用检查："
UNDEF=$("$NM_BIN" -u "$ELF_WIN" 2>/dev/null || true)
if [ -n "$UNDEF" ]; then
  echo "[FATAL] 存在未解析引用：" >&2
  echo "$UNDEF" >&2
  exit 3
fi
echo "  [OK] 无未解析引用"

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
