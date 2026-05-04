#!/usr/bin/env bash
#
# Generate a reproducibility manifest for the ARM-hosted V2.B FPGA demo.
# Called by fw/arm/build_arm_firmware.sh and scripts/build_zcu102_arm_demo.sh.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${ROOT_OVERRIDE:-$(cd "$HERE/.." && pwd)}"
MANIFEST="$ROOT/doc/arm-fpga-demo/build_manifest_v2.txt"

BIT_PATH="${BIT_PATH:-}"
XSA_PATH="${XSA_PATH:-}"
ELF_PATH="${ELF_PATH:-}"
PSU_INIT_PATH="${PSU_INIT_PATH:-}"
V2B_SOC_BASE_VALUE="${V2B_SOC_BASE_VALUE:-}"

find_first() {
  local pattern_root="$1"
  local name="$2"
  find "$pattern_root" -name "$name" -print 2>/dev/null | head -n 1 || true
}

path_relative_to_root() {
  local path="$1"
  if [ -z "$path" ]; then
    printf '<missing>\n'
    return 0
  fi

  case "$path" in
    "$ROOT"/*)
      printf '%s\n' "${path#"$ROOT"/}"
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

sha256_or_missing() {
  local path="$1"
  if [ -n "$path" ] && [ -f "$path" ]; then
    sha256sum "$path" | awk '{print $1}'
  else
    printf '<missing>\n'
  fi
}

tool_version_or_missing() {
  local tool_path="$1"
  local tool_arg="$2"
  local lines="$3"
  local invoke_path=""
  local output=""
  if [ -z "$tool_path" ]; then
    printf '<missing>\n'
    return 0
  fi
  if [ -e "$tool_path" ]; then
    invoke_path="$tool_path"
  elif [ -e "${tool_path}.exe" ]; then
    invoke_path="${tool_path}.exe"
  elif [ -e "${tool_path%.bat}" ]; then
    invoke_path="${tool_path%.bat}"
  else
    printf '<missing>\n'
    return 0
  fi

  if [ -n "${WSL_DISTRO_NAME:-}" ] && command -v wslpath >/dev/null 2>&1; then
    case "$invoke_path" in
      /mnt/*)
        output="$(cmd.exe /c "\"$(wslpath -w "$invoke_path")\" $tool_arg" 2>/dev/null | tr -d '\r' | head -n "$lines" | paste -sd ' | ' - || true)"
        ;;
      *)
        output="$("$invoke_path" "$tool_arg" 2>/dev/null | tr -d '\r' | head -n "$lines" | paste -sd ' | ' - || true)"
        ;;
    esac
  else
    output="$("$invoke_path" "$tool_arg" 2>/dev/null | tr -d '\r' | head -n "$lines" | paste -sd ' | ' - || true)"
  fi

  if [ -n "$output" ]; then
    printf '%s\n' "$output"
  else
    printf '<missing>\n'
  fi
}

if [ -z "$BIT_PATH" ]; then
  BIT_PATH="$(find_first "$ROOT/fpga_synth/zcu102_arm_demo" '*.bit')"
fi
if [ -z "$XSA_PATH" ] && [ -f "$ROOT/fpga_synth/zcu102_arm_demo.xsa" ]; then
  XSA_PATH="$ROOT/fpga_synth/zcu102_arm_demo.xsa"
fi
if [ -z "$ELF_PATH" ] && [ -f "$ROOT/fw/arm/out/v2b_arm_demo.elf" ]; then
  ELF_PATH="$ROOT/fw/arm/out/v2b_arm_demo.elf"
fi
if [ -z "$PSU_INIT_PATH" ]; then
  PSU_INIT_PATH="$(find_first "$ROOT/fpga_synth/zcu102_arm_demo" 'psu_init.tcl')"
fi

VIVADO_BIN="${VIVADO_BIN:-/d/Xilinx/Vivado/2022.2/bin/vivado.bat}"
TOOLCHAIN_BIN="${TOOLCHAIN_BIN:-/d/Xilinx/Vitis/2022.2/gnu/aarch64/nt/aarch64-none/bin}"
GCC_BIN="$TOOLCHAIN_BIN/aarch64-none-elf-gcc"

GIT_BRANCH="$(git -C "$ROOT" branch --show-current 2>/dev/null || printf '<missing>\n')"
VIVADO_VERSION="$(tool_version_or_missing "$VIVADO_BIN" -version 3)"
GCC_VERSION="$(tool_version_or_missing "$GCC_BIN" --version 1)"

mkdir -p "$(dirname "$MANIFEST")"
cat > "$MANIFEST" <<EOF
# v2-arm-fpga-demo build manifest v2
Git branch: $GIT_BRANCH

Vivado version: $VIVADO_VERSION
Resolved psu_init.tcl: $(path_relative_to_root "${PSU_INIT_PATH:-}")

AArch64 GCC version: $GCC_VERSION
V2B_SOC_BASE override: ${V2B_SOC_BASE_VALUE:-<unset>}

Bitstream path: $(path_relative_to_root "${BIT_PATH:-}")
Bitstream SHA256: $(sha256_or_missing "$BIT_PATH")
XSA path: $(path_relative_to_root "${XSA_PATH:-}")
XSA SHA256: $(sha256_or_missing "$XSA_PATH")
ELF path: $(path_relative_to_root "${ELF_PATH:-}")
ELF SHA256: $(sha256_or_missing "$ELF_PATH")
EOF

echo "[gen_arm_demo_manifest] wrote $MANIFEST"
