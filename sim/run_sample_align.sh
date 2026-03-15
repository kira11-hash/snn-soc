#!/usr/bin/env bash
# =============================================================================
# Step 3.4: Python↔RTL 数值对齐仿真运行脚本（Icarus）
#
# 前置步骤：
#   1. cd 项目相关文件/器件对齐/Python建模
#   2. python export_expected_spike_ids.py
#   3. 将 results/exports/rtl_stimulus/ 下生成的文件复制到 sim/ 目录
#      需要的文件：all_samples.hex, expected_classes.hex
#      权重文件：weight_pos.hex, weight_neg.hex（同 run_icarus_weighted.sh）
#
# 用法：
#   cd sim && bash run_sample_align.sh
#
# 通过标准：SAMPLE_ALIGN_PASS（10/10 样本 spike_id 完全一致）
# =============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$SCRIPT_DIR"

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.sample_align_run.XXXXXX")
cleanup() {
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

mkdir -p "$RUN_DIR/waves"

find_weight_dir() {
  local auto_export_pos
  local dir

  for dir in \
    "$ROOT_DIR/项目相关文件/器件对齐/Python建模/results/exports" \
    "$ROOT_DIR/fpga/cim_model" \
    "$SCRIPT_DIR"
  do
    if [ -f "$dir/weight_pos.hex" ] && [ -f "$dir/weight_neg.hex" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done

  auto_export_pos=$(find "$ROOT_DIR" -path '*/results/exports/weight_pos.hex' ! -path '*/backups/*' -print -quit 2>/dev/null || true)
  if [ -n "$auto_export_pos" ] && [ -f "${auto_export_pos%/weight_pos.hex}/weight_neg.hex" ]; then
    printf '%s\n' "${auto_export_pos%/weight_pos.hex}"
    return 0
  fi

  auto_export_pos=$(find "$ROOT_DIR" -path '*/results/exports/weight_pos.hex' -print -quit 2>/dev/null || true)
  if [ -n "$auto_export_pos" ] && [ -f "${auto_export_pos%/weight_pos.hex}/weight_neg.hex" ]; then
    printf '%s\n' "${auto_export_pos%/weight_pos.hex}"
    return 0
  fi

  return 1
}

find_stimulus_dir() {
  local auto_stimulus
  local dir

  for dir in \
    "$ROOT_DIR/项目相关文件/器件对齐/Python建模/results/exports/rtl_stimulus" \
    "$SCRIPT_DIR"
  do
    if [ -f "$dir/all_samples.hex" ] && [ -f "$dir/expected_classes.hex" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done

  auto_stimulus=$(find "$ROOT_DIR" -path '*/rtl_stimulus/all_samples.hex' ! -path '*/backups/*' -print -quit 2>/dev/null || true)
  if [ -n "$auto_stimulus" ] && [ -f "${auto_stimulus%/all_samples.hex}/expected_classes.hex" ]; then
    printf '%s\n' "${auto_stimulus%/all_samples.hex}"
    return 0
  fi

  auto_stimulus=$(find "$ROOT_DIR" -path '*/rtl_stimulus/all_samples.hex' -print -quit 2>/dev/null || true)
  if [ -n "$auto_stimulus" ] && [ -f "${auto_stimulus%/all_samples.hex}/expected_classes.hex" ]; then
    printf '%s\n' "${auto_stimulus%/all_samples.hex}"
    return 0
  fi

  return 1
}

count_nonempty_lines() {
  awk 'NF { count++ } END { print count + 0 }' "$1"
}

pad_hex_file() {
  local src="$1"
  local dst="$2"
  local target="$3"
  local filler="$4"

  awk -v target="$target" -v filler="$filler" '
    { print; count++ }
    END {
      while (count < target) {
        print filler
        count++
      }
    }
  ' "$src" > "$dst"
}

# ── 定位权重 hex ──
WEIGHT_SRC_DIR="${WEIGHT_SRC_DIR:-}"
if [ -z "$WEIGHT_SRC_DIR" ]; then
  WEIGHT_SRC_DIR=$(find_weight_dir || true)
fi

if [ -z "$WEIGHT_SRC_DIR" ]; then
  echo "[ERROR] weight_pos.hex / weight_neg.hex not found." >&2
  echo "[ERROR] Set WEIGHT_SRC_DIR or place hex files under any results/exports directory." >&2
  exit 1
fi

cp "$WEIGHT_SRC_DIR/weight_pos.hex" "$RUN_DIR/weight_pos.hex"
cp "$WEIGHT_SRC_DIR/weight_neg.hex" "$RUN_DIR/weight_neg.hex"

# ── 定位 stimulus 文件（all_samples.hex, expected_classes.hex） ──
STIMULUS_DIR="${STIMULUS_DIR:-}"
if [ -z "$STIMULUS_DIR" ]; then
  STIMULUS_DIR=$(find_stimulus_dir || true)
fi

if [ -z "$STIMULUS_DIR" ] || [ ! -f "$STIMULUS_DIR/all_samples.hex" ] || [ ! -f "$STIMULUS_DIR/expected_classes.hex" ]; then
  echo "[ERROR] Stimulus files not found (all_samples.hex, expected_classes.hex)." >&2
  echo "[ERROR] Run export_expected_spike_ids.py first, then set STIMULUS_DIR or copy files to sim/." >&2
  exit 1
fi

PLANES_PER_SAMPLE=80
MAX_SAMPLE_COUNT=256
TOTAL_PLANES_MAX=$((MAX_SAMPLE_COUNT * PLANES_PER_SAMPLE))
sample_count=$(count_nonempty_lines "$STIMULUS_DIR/expected_classes.hex")
plane_count=$(count_nonempty_lines "$STIMULUS_DIR/all_samples.hex")
required_plane_count=$((sample_count * PLANES_PER_SAMPLE))

if [ "$sample_count" -le 0 ]; then
  echo "[ERROR] expected_classes.hex is empty." >&2
  exit 1
fi

if [ "$sample_count" -gt "$MAX_SAMPLE_COUNT" ]; then
  echo "[ERROR] Stimulus sample count $sample_count exceeds TB MAX_SAMPLE_COUNT=$MAX_SAMPLE_COUNT." >&2
  exit 1
fi

if [ "$plane_count" -lt "$required_plane_count" ]; then
  echo "[ERROR] all_samples.hex has only $plane_count planes, expected at least $required_plane_count for $sample_count samples." >&2
  exit 1
fi

pad_hex_file "$STIMULUS_DIR/all_samples.hex" "$RUN_DIR/all_samples.hex" "$TOTAL_PLANES_MAX" "0000000000000000"
pad_hex_file "$STIMULUS_DIR/expected_classes.hex" "$RUN_DIR/expected_classes.hex" "$MAX_SAMPLE_COUNT" "0"

echo "[run_sample_align.sh] Weight source: $WEIGHT_SRC_DIR"
echo "[run_sample_align.sh] Stimulus source: $STIMULUS_DIR"
echo "[run_sample_align.sh] Auto-detected SAMPLE_COUNT=$sample_count"

# ── 编译 ──
iverilog -g2012 -gno-assertions -f sim_sample_align.f -s top_tb_sample_align -o "$RUN_DIR/sample_align.out"

# ── 运行 ──
VVP_ARGS=("$@")
for arg in "$@"; do
  if [[ "$arg" == +SAMPLE_COUNT=* ]]; then
    VVP_ARGS=("$@")
    sample_count=""
    break
  fi
done

if [ -n "$sample_count" ]; then
  VVP_ARGS=("+SAMPLE_COUNT=$sample_count" "${VVP_ARGS[@]}")
fi

(
  cd "$RUN_DIR"
  vvp ./sample_align.out "${VVP_ARGS[@]}"
) | tee "$SCRIPT_DIR/sample_align.log"

# ── 保存波形 ──
mkdir -p "$SCRIPT_DIR/waves"
if [ -f "$RUN_DIR/waves/sample_align.vcd" ]; then
  cp "$RUN_DIR/waves/sample_align.vcd" "$SCRIPT_DIR/waves/sample_align.vcd"
fi

# ── 判定结果 ──
if grep -q "SAMPLE_ALIGN_PASS" "$SCRIPT_DIR/sample_align.log"; then
  echo "[run_sample_align.sh] >>> SAMPLE_ALIGN_PASS <<<"
  exit 0
fi

echo "[ERROR] SAMPLE_ALIGN_PASS not found. See sim/sample_align.log" >&2
exit 1
