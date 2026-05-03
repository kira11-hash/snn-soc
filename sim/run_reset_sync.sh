#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.reset_sync_run.XXXXXX")
cleanup() {
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -f sim_reset_sync.f -s reset_sync_tb -o "$RUN_DIR/reset_sync.out"
(
  cd "$RUN_DIR"
  run_vvp ./reset_sync.out
) | tee "$SCRIPT_DIR/reset_sync.log"

if grep -q "RESET_SYNC_TB_PASS" "$SCRIPT_DIR/reset_sync.log"; then
  exit 0
fi

echo "[ERROR] RESET_SYNC_TB_PASS not found. See sim/reset_sync.log" >&2
exit 1
