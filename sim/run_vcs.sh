#!/usr/bin/env bash
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

mkdir -p waves

if [ -z "$VERDI_HOME" ]; then
  echo "[run_vcs.sh] 请先设置 VERDI_HOME（用于 FSDB PLI）"
  exit 1
fi

vcs -full64 -sverilog -f sim.f -o simv \
    -debug_access+all -kdb \
    -P "$VERDI_HOME/share/PLI/VCS/LINUX64/novas.tab" \
       "$VERDI_HOME/share/PLI/VCS/LINUX64/novas.so" \
    -l vcs.log

./simv -l sim.log
