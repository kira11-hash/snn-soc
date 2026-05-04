#!/usr/bin/env bash
#
# Generate a reproducibility manifest for the V2 E203 FPGA demo.
# Called by fpga_synth/zcu102_v2_e203_demo/build_v2_e203_demo.sh.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${ROOT_OVERRIDE:-$(cd "$HERE/.." && pwd)}"
MANIFEST="$ROOT/doc/v2-fpga-e203/build_manifest_lenet5.txt"

BIT_PATH="${BIT_PATH:-}"
TIMING_PATH="${TIMING_PATH:-}"
UTIL_PATH="${UTIL_PATH:-}"
DRC_PATH="${DRC_PATH:-}"

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
        output="$(cmd.exe /c "\"$(wslpath -w "$invoke_path")\" $tool_arg" 2>/dev/null | tr -d '\r' | head -n "$lines" | paste -sd '|' - || true)"
        ;;
      *)
        output="$("$invoke_path" "$tool_arg" 2>/dev/null | tr -d '\r' | head -n "$lines" | paste -sd '|' - || true)"
        ;;
    esac
  else
    output="$("$invoke_path" "$tool_arg" 2>/dev/null | tr -d '\r' | head -n "$lines" | paste -sd '|' - || true)"
  fi

  if [ -n "$output" ]; then
    printf '%s\n' "$output"
  else
    printf '<missing>\n'
  fi
}

if [ -z "$BIT_PATH" ]; then
  BIT_PATH="$(find_first "$ROOT/fpga_synth/zcu102_v2_e203_demo/out" '*.bit')"
fi
if [ -z "$TIMING_PATH" ] && [ -f "$ROOT/fpga_synth/zcu102_v2_e203_demo/out/timing_summary.rpt" ]; then
  TIMING_PATH="$ROOT/fpga_synth/zcu102_v2_e203_demo/out/timing_summary.rpt"
fi
if [ -z "$UTIL_PATH" ] && [ -f "$ROOT/fpga_synth/zcu102_v2_e203_demo/out/utilization.rpt" ]; then
  UTIL_PATH="$ROOT/fpga_synth/zcu102_v2_e203_demo/out/utilization.rpt"
fi
if [ -z "$DRC_PATH" ] && [ -f "$ROOT/fpga_synth/zcu102_v2_e203_demo/out/drc.rpt" ]; then
  DRC_PATH="$ROOT/fpga_synth/zcu102_v2_e203_demo/out/drc.rpt"
fi

VIVADO_BIN="${VIVADO_BIN:-/d/Xilinx/Vivado/2022.2/bin/vivado.bat}"
GIT_BRANCH="$(git -C "$ROOT" branch --show-current 2>/dev/null || printf '<missing>\n')"
VIVADO_VERSION="$(tool_version_or_missing "$VIVADO_BIN" -version 3)"

mkdir -p "$(dirname "$MANIFEST")"
cat > "$MANIFEST" <<EOF
# feature/v2-fpga-e203-conv LeNet-5 build manifest
Git branch: $GIT_BRANCH

Vivado version: $VIVADO_VERSION

Bitstream path: $(path_relative_to_root "${BIT_PATH:-}")
Bitstream SHA256: $(sha256_or_missing "$BIT_PATH")
Timing report path: $(path_relative_to_root "${TIMING_PATH:-}")
Timing report SHA256: $(sha256_or_missing "$TIMING_PATH")
Utilization report path: $(path_relative_to_root "${UTIL_PATH:-}")
Utilization report SHA256: $(sha256_or_missing "$UTIL_PATH")
DRC report path: $(path_relative_to_root "${DRC_PATH:-}")
DRC report SHA256: $(sha256_or_missing "$DRC_PATH")

LeNet-5 ELF path: fw/v2_e203_smoke/out/v2_e203_lenet5.elf
LeNet-5 ELF SHA256: $(sha256_or_missing "$ROOT/fw/v2_e203_smoke/out/v2_e203_lenet5.elf")
LeNet-5 hex path: fw/v2_e203_smoke/out/v2_e203_lenet5.hex
LeNet-5 hex SHA256: $(sha256_or_missing "$ROOT/fw/v2_e203_smoke/out/v2_e203_lenet5.hex")
LeNet-5 map path: fw/v2_e203_smoke/out/v2_e203_lenet5.map
LeNet-5 map SHA256: $(sha256_or_missing "$ROOT/fw/v2_e203_smoke/out/v2_e203_lenet5.map")

Smoke ELF path: fw/v2_e203_smoke/out/v2_e203_smoke.elf
Smoke ELF SHA256: $(sha256_or_missing "$ROOT/fw/v2_e203_smoke/out/v2_e203_smoke.elf")
Smoke hex path: fw/v2_e203_smoke/out/v2_e203_smoke.hex
Smoke hex SHA256: $(sha256_or_missing "$ROOT/fw/v2_e203_smoke/out/v2_e203_smoke.hex")

Encoder ELF path: fw/v2_e203_smoke/out/v2_e203_encoder.elf
Encoder ELF SHA256: $(sha256_or_missing "$ROOT/fw/v2_e203_smoke/out/v2_e203_encoder.elf")
Encoder hex path: fw/v2_e203_smoke/out/v2_e203_encoder.hex
Encoder hex SHA256: $(sha256_or_missing "$ROOT/fw/v2_e203_smoke/out/v2_e203_encoder.hex")
EOF

echo "[gen_v2_e203_manifest] wrote $MANIFEST"
