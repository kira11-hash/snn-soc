#!/usr/bin/env bash
set -e

# Setup environment variables
source /home/opt/demo/syn.env
export VCS_HOME=/opt/Synopsys/vcs_green/vcs-2021.09-sp2
export VERDI_HOME=/opt/Synopsys/verdi_green/verdi-2021.09-sp2
export PATH=$VCS_HOME/bin:$VERDI_HOME/bin:$PATH

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

mkdir -p waves

if [ -z "$VERDI_HOME" ]; then
  echo "[run_vcs.sh] 请先设置 VERDI_HOME（用于 FSDB PLI）"
  exit 1
fi

vcs -full64 -sverilog -timescale=1ns/1ps -f sim.f -o simv \
    -debug_access+all -kdb \
    -P "$VERDI_HOME/share/PLI/VCS/LINUX64/novas.tab" \
       "$VERDI_HOME/share/PLI/VCS/LINUX64/pli.a" \
    -l vcs.log

./simv -l sim.log
