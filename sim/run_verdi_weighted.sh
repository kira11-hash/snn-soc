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

FSDB_PATH="${1:-waves/snn_soc_weighted.fsdb}"

verdi -sv -f sim_icarus_weighted.f -ssf "$FSDB_PATH" -play verdi_weighted.tcl
