#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools
resolve_python_tool

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.conv_stage_smoke_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_conv_stage_smoke.f \
  -s conv_stage_smoke_tb -o "$RUN_DIR/conv_stage_smoke_tb.out"

RTL_COUNTS="$RUN_DIR/synthetic_C1_rtl_output_counts.txt"
RTL_COUNTS_HOST=$(to_windows_path "$RTL_COUNTS")
LOG="$SCRIPT_DIR/conv_stage_smoke_sim.log"
GOLDEN_DIR="../python_multilayer"
run_vvp "$RUN_DIR/conv_stage_smoke_tb.out" \
  "+GOLDEN_DIR=$GOLDEN_DIR" "+RTL_COUNTS=$RTL_COUNTS_HOST" | tee "$LOG"

PY_SHA=$(run_python - "$GOLDEN_DIR/synthetic_C1_output_counts.txt" <<'PY'
import hashlib
import sys
from pathlib import Path
print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)
RTL_SHA=$(run_python - "$RTL_COUNTS_HOST" <<'PY'
import hashlib
import sys
from pathlib import Path
print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)

echo "[SHA] python_synthetic_C1_output_counts=$PY_SHA" | tee -a "$LOG"
echo "[SHA] rtl_synthetic_C1_output_counts=$RTL_SHA" | tee -a "$LOG"

if [ "$PY_SHA" != "$RTL_SHA" ]; then
  echo "[RESULT] CONV_STAGE_SMOKE_TB_FAIL_SHA_MISMATCH" | tee -a "$LOG"
  exit 1
fi

if grep -q "CONV_STAGE_SMOKE_TB_PASS" "$LOG"; then
  echo "============================================" | tee -a "$LOG"
  echo "[RESULT] CONV_STAGE_SMOKE_TB_PASS" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
  exit 0
else
  echo "============================================" | tee -a "$LOG"
  echo "[RESULT] CONV_STAGE_SMOKE_TB_FAIL" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
  exit 1
fi
