#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.sync_2ff_run.XXXXXX")
cleanup() {
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -f sim_sync_2ff.f -s sync_2ff_tb -o "$RUN_DIR/sync_2ff.out"
(
  cd "$RUN_DIR"
  run_vvp ./sync_2ff.out
) | tee "$SCRIPT_DIR/sync_2ff.log"

if grep -q "SYNC_2FF_TB_PASS" "$SCRIPT_DIR/sync_2ff.log"; then
  exit 0
fi

echo "[ERROR] SYNC_2FF_TB_PASS not found. See sim/sync_2ff.log" >&2
exit 1
