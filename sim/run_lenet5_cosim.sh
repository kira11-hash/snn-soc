#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools
resolve_python_tool

MODE="${1:---smoke}"
case "$MODE" in
  --smoke) SAMPLES=1 ;;
  --full)  SAMPLES=10 ;;
  *) echo "usage: $0 [--smoke|--full] [lenet5|lenet5_fashion]" >&2; exit 2 ;;
esac

# Optional 2nd arg selects the golden bundle directory under results_conv/.
# Default "lenet5" matches the canonical M4 MNIST artifacts; "lenet5_fashion"
# points at the Fashion-MNIST 28x28 ablation produced by `gen_convnet_golden.py
# --network lenet5 --dataset-override fashion_mnist --tag _fashion`.
BUNDLE="${2:-lenet5}"
case "$BUNDLE" in
  lenet5)         GEN_OVERRIDE=() ;;
  lenet5_fashion) GEN_OVERRIDE=(--dataset-override fashion_mnist --tag _fashion) ;;
  *) echo "usage: $0 [--smoke|--full] [lenet5|lenet5_fashion]" >&2; exit 2 ;;
esac

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.lenet5_cosim_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

LOG="$SCRIPT_DIR/lenet5_cosim_sim.log"
: > "$LOG"

echo "[INFO] Generating/checking LeNet5 golden bundle (bundle=$BUNDLE)" | tee -a "$LOG"
run_python ../python_multilayer/gen_convnet_golden.py --network lenet5 --samples 10 "${GEN_OVERRIDE[@]}" | tee -a "$LOG"

GOLDEN_DIR="$SCRIPT_DIR/../python_multilayer/results_conv/$BUNDLE"
MANIFEST="$GOLDEN_DIR/lenet5_golden_manifest.json"
GOLDEN_DIR_HOST=$(to_windows_path "$GOLDEN_DIR")
MANIFEST_HOST=$(to_windows_path "$MANIFEST")
RTL_COUNTS="$RUN_DIR/lenet5_rtl_counts.txt"
RTL_COUNTS_HOST=$(to_windows_path "$RTL_COUNTS")

read -r TH_CONV1 TH_CONV2 TH_FC1 TH_FC2 TH_FC3 GOLDEN_SHA <<<"$(run_python - "$MANIFEST_HOST" "$SAMPLES" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="ascii"))
samples = int(sys.argv[2])
ths = {layer["name"]: layer["threshold"] for layer in manifest["layers"]}
h = hashlib.sha256()
for sample in manifest["samples"][:samples]:
    h.update((Path(sys.argv[1]).parent / sample["output_counts"]).read_bytes())
print(
    ths["conv1"], ths["conv2"], ths["fc1"], ths["fc2"], ths["fc3"],
    h.hexdigest(),
)
PY
)"

SUMMAX_CONV1=1023
SUMMAX_CONV2=1023
SUMMAX_FC1=1023
SUMMAX_FC2=1023
SUMMAX_FC3=1023

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_lenet5_cosim.f \
  -s lenet5_cosim_tb -o "$RUN_DIR/lenet5_cosim_tb.out"

run_vvp "$RUN_DIR/lenet5_cosim_tb.out" \
  "+GOLDEN_DIR=$GOLDEN_DIR_HOST" \
  "+RTL_COUNTS=$RTL_COUNTS_HOST" \
  "+SAMPLES=$SAMPLES" \
  "+TH_CONV1=$TH_CONV1" \
  "+TH_CONV2=$TH_CONV2" \
  "+TH_FC1=$TH_FC1" \
  "+TH_FC2=$TH_FC2" \
  "+TH_FC3=$TH_FC3" \
  "+SUMMAX_CONV1=$SUMMAX_CONV1" \
  "+SUMMAX_CONV2=$SUMMAX_CONV2" \
  "+SUMMAX_FC1=$SUMMAX_FC1" \
  "+SUMMAX_FC2=$SUMMAX_FC2" \
  "+SUMMAX_FC3=$SUMMAX_FC3" | tee -a "$LOG"

RTL_SHA=$(run_python - "$RTL_COUNTS_HOST" <<'PY'
import hashlib
import sys
from pathlib import Path

lines = []
for line in Path(sys.argv[1]).read_text(encoding="ascii").splitlines():
    if not line or line.startswith("sample "):
        continue
    lines.append(line + "\n")
print(hashlib.sha256("".join(lines).encode("ascii")).hexdigest())
PY
)
echo "[SHA] lenet5_golden_counts_concat=$GOLDEN_SHA" | tee -a "$LOG"
echo "[SHA] lenet5_rtl_counts_dump=$RTL_SHA" | tee -a "$LOG"

if grep -q "LENET5_COSIM_TB_PASS" "$LOG"; then
  echo "============================================" | tee -a "$LOG"
  echo "[RESULT] LENET5_COSIM_TB_PASS mode=$MODE bundle=$BUNDLE samples=$SAMPLES" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
else
  echo "============================================" | tee -a "$LOG"
  echo "[RESULT] LENET5_COSIM_TB_FAIL mode=$MODE bundle=$BUNDLE samples=$SAMPLES" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
  exit 1
fi
