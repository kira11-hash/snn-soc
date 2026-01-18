#!/usr/bin/env bash
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

verdi -sv -f sim.f -ssf waves/snn_soc.fsdb -do verdi.tcl
