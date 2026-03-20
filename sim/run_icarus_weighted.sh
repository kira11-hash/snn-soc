#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.icarus_weighted_run.XXXXXX")
cleanup() {
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

mkdir -p "$RUN_DIR/waves"

WEIGHT_SRC_DIR="${WEIGHT_SRC_DIR:-}"
if [ -z "$WEIGHT_SRC_DIR" ]; then
  WEIGHT_SRC_DIR=$(find_weight_dir "$ROOT_DIR" "$SCRIPT_DIR" || true)
fi

if [ -z "$WEIGHT_SRC_DIR" ]; then
  echo "[ERROR] weight_pos.hex / weight_neg.hex not found." >&2
  echo "[ERROR] Set WEIGHT_SRC_DIR or place hex files under any results/exports directory." >&2
  exit 1
fi

cp "$WEIGHT_SRC_DIR/weight_pos.hex" "$RUN_DIR/weight_pos.hex"
cp "$WEIGHT_SRC_DIR/weight_neg.hex" "$RUN_DIR/weight_neg.hex"

run_iverilog -g2012 -gno-assertions -f sim_icarus_weighted.f -s top_tb_icarus_weighted -o "$RUN_DIR/icarus_weighted.out"
(
  cd "$RUN_DIR"
  run_vvp ./icarus_weighted.out "$@"
) | tee "$SCRIPT_DIR/icarus_weighted.log"

mkdir -p "$SCRIPT_DIR/waves"
if [ -f "$RUN_DIR/waves/icarus_weighted.vcd" ]; then
  cp "$RUN_DIR/waves/icarus_weighted.vcd" "$SCRIPT_DIR/waves/icarus_weighted.vcd"
fi

if grep -q "WEIGHTED_SIM_PASS" "$SCRIPT_DIR/icarus_weighted.log"; then
  exit 0
fi

echo "[ERROR] WEIGHTED_SIM_PASS not found. See sim/icarus_weighted.log" >&2
exit 1
