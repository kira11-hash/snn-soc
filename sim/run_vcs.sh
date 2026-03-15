#!/usr/bin/env bash
set -euo pipefail

if [ -f /home/opt/demo/syn.env ]; then
  # shellcheck disable=SC1091
  source /home/opt/demo/syn.env
fi

: "${VCS_HOME:=/opt/Synopsys/vcs_green/vcs-2021.09-sp2}"
: "${VERDI_HOME:=/opt/Synopsys/verdi_green/verdi-2021.09-sp2}"
export PATH="$VCS_HOME/bin:$VERDI_HOME/bin:$PATH"

VCS_BIN="$VCS_HOME/bin/vcs"
VERDI_BIN="$VERDI_HOME/bin/verdi"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

mkdir -p waves

if [ ! -x "$VCS_BIN" ]; then
  echo "[run_vcs.sh] VCS binary not found: $VCS_BIN"
  echo "[run_vcs.sh] Current VCS_HOME=$VCS_HOME"
  if command -v vcs >/dev/null 2>&1; then
    echo "[run_vcs.sh] command -v vcs => $(command -v vcs)"
  fi
  exit 1
fi

if [ ! -x "$VERDI_BIN" ]; then
  echo "[run_vcs.sh] Verdi binary not found: $VERDI_BIN"
  echo "[run_vcs.sh] Current VERDI_HOME=$VERDI_HOME"
  if command -v verdi >/dev/null 2>&1; then
    echo "[run_vcs.sh] command -v verdi => $(command -v verdi)"
  fi
  exit 1
fi

"$VCS_BIN" -full64 -sverilog -timescale=1ns/1ps +define+VCS \
    -f sim.f -top top_tb -o simv \
    -debug_access+all -kdb \
    -P "$VERDI_HOME/share/PLI/VCS/LINUX64/novas.tab" \
       "$VERDI_HOME/share/PLI/VCS/LINUX64/pli.a" \
    -l vcs.log

./simv -l sim.log
