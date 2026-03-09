#!/usr/bin/env bash
set -euo pipefail

if [ -f /home/opt/demo/syn.env ]; then
  # shellcheck disable=SC1091
  source /home/opt/demo/syn.env
fi

: "${VCS_HOME:=/opt/Synopsys/vcs_green/vcs-2021.09-sp2}"
: "${VERDI_HOME:=/opt/Synopsys/verdi_green/verdi-2021.09-sp2}"
export PATH="$VCS_HOME/bin:$VERDI_HOME/bin:$PATH"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.vcs_weighted_run.XXXXXX")
cleanup() {
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

mkdir -p "$RUN_DIR/waves"
mkdir -p "$SCRIPT_DIR/waves"

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

if [ ! -d "$VERDI_HOME" ]; then
  echo "[ERROR] VERDI_HOME not found: $VERDI_HOME" >&2
  exit 1
fi

cp "$WEIGHT_SRC_DIR/weight_pos.hex" "$RUN_DIR/weight_pos.hex"
cp "$WEIGHT_SRC_DIR/weight_neg.hex" "$RUN_DIR/weight_neg.hex"

vcs -full64 -sverilog -timescale=1ns/1ps +define+VCS \
    -f sim_icarus_weighted.f \
    -top top_tb_icarus_weighted \
    -o "$RUN_DIR/simv_weighted" \
    -debug_access+all -kdb \
    -P "$VERDI_HOME/share/PLI/VCS/LINUX64/novas.tab" \
       "$VERDI_HOME/share/PLI/VCS/LINUX64/pli.a" \
    -l "$SCRIPT_DIR/vcs_weighted_compile.log"

(
  cd "$RUN_DIR"
  ./simv_weighted "$@"
) | tee "$SCRIPT_DIR/vcs_weighted.log"

if [ -f "$RUN_DIR/waves/snn_soc_weighted.fsdb" ]; then
  cp "$RUN_DIR/waves/snn_soc_weighted.fsdb" "$SCRIPT_DIR/waves/snn_soc_weighted.fsdb"
fi

if grep -q "WEIGHTED_SIM_PASS" "$SCRIPT_DIR/vcs_weighted.log"; then
  exit 0
fi

echo "[ERROR] WEIGHTED_SIM_PASS not found. See sim/vcs_weighted.log" >&2
exit 1
