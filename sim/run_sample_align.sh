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
cd "$SCRIPT_DIR"

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.sample_align_run.XXXXXX")
cleanup() {
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

mkdir -p "$RUN_DIR/waves"

# ── 定位权重 hex ──
WEIGHT_SRC_DIR="${WEIGHT_SRC_DIR:-}"
if [ -z "$WEIGHT_SRC_DIR" ]; then
  AUTO_EXPORT_POS=$(find .. -path '*/results/exports/weight_pos.hex' -print -quit 2>/dev/null || true)
  if [ -n "$AUTO_EXPORT_POS" ] && [ -f "${AUTO_EXPORT_POS%/weight_pos.hex}/weight_neg.hex" ]; then
    WEIGHT_SRC_DIR="${AUTO_EXPORT_POS%/weight_pos.hex}"
  elif [ -f "../fpga/cim_model/weight_pos.hex" ] && [ -f "../fpga/cim_model/weight_neg.hex" ]; then
    WEIGHT_SRC_DIR="../fpga/cim_model"
  elif [ -f "./weight_pos.hex" ] && [ -f "./weight_neg.hex" ]; then
    WEIGHT_SRC_DIR="."
  fi
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
  # 优先从 Python 导出目录查找
  AUTO_STIMULUS=$(find .. -path '*/rtl_stimulus/all_samples.hex' -print -quit 2>/dev/null || true)
  if [ -n "$AUTO_STIMULUS" ]; then
    STIMULUS_DIR="${AUTO_STIMULUS%/all_samples.hex}"
  elif [ -f "./all_samples.hex" ] && [ -f "./expected_classes.hex" ]; then
    STIMULUS_DIR="."
  fi
fi

if [ -z "$STIMULUS_DIR" ] || [ ! -f "$STIMULUS_DIR/all_samples.hex" ] || [ ! -f "$STIMULUS_DIR/expected_classes.hex" ]; then
  echo "[ERROR] Stimulus files not found (all_samples.hex, expected_classes.hex)." >&2
  echo "[ERROR] Run export_expected_spike_ids.py first, then set STIMULUS_DIR or copy files to sim/." >&2
  exit 1
fi

cp "$STIMULUS_DIR/all_samples.hex" "$RUN_DIR/all_samples.hex"
cp "$STIMULUS_DIR/expected_classes.hex" "$RUN_DIR/expected_classes.hex"

echo "[run_sample_align.sh] Weight source: $WEIGHT_SRC_DIR"
echo "[run_sample_align.sh] Stimulus source: $STIMULUS_DIR"

# ── 编译 ──
iverilog -g2012 -gno-assertions -f sim_sample_align.f -s top_tb_sample_align -o "$RUN_DIR/sample_align.out"

# ── 运行 ──
(
  cd "$RUN_DIR"
  vvp ./sample_align.out "$@"
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
