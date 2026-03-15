#!/usr/bin/env bash
set -euo pipefail

if [ -f /home/opt/demo/syn.env ]; then
  # shellcheck disable=SC1091
  source /home/opt/demo/syn.env
fi

: "${VCS_HOME:=/opt/Synopsys/vcs_green/vcs-2021.09-sp2}"
: "${VERDI_HOME:=/opt/Synopsys/verdi_green/verdi-2021.09-sp2}"
export PATH="$VCS_HOME/bin:$VERDI_HOME/bin:$PATH"

VERDI_BIN="$VERDI_HOME/bin/verdi"
if [ ! -x "$VERDI_BIN" ]; then
  echo "[ERROR] Verdi binary not found: $VERDI_BIN" >&2
  echo "[ERROR] Current VERDI_HOME=$VERDI_HOME" >&2
  if command -v verdi >/dev/null 2>&1; then
    echo "[INFO] command -v verdi => $(command -v verdi)" >&2
  fi
  echo "[ERROR] Please source the correct Synopsys environment or export VERDI_HOME explicitly." >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

FSDB_PATH="${1:-waves/snn_soc_weighted.fsdb}"

"$VERDI_BIN" -sv -f sim_icarus_weighted.f -ssf "$FSDB_PATH" -play verdi_weighted.tcl
