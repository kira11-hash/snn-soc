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

mkdir -p waves

if [ ! -d "$VERDI_HOME" ]; then
  echo "[run_vcs.sh] VERDI_HOME 不存在：$VERDI_HOME"
  exit 1
fi

vcs -full64 -sverilog -timescale=1ns/1ps +define+VCS \
    -f sim.f -top top_tb -o simv \
    -debug_access+all -kdb \
    -P "$VERDI_HOME/share/PLI/VCS/LINUX64/novas.tab" \
       "$VERDI_HOME/share/PLI/VCS/LINUX64/pli.a" \
    -l vcs.log

./simv -l sim.log
