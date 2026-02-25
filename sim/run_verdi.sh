#!/usr/bin/env bash
set -e

# Setup environment variables
source /home/opt/demo/syn.env
export VCS_HOME=/opt/Synopsys/vcs_green/vcs-2021.09-sp2
export VERDI_HOME=/opt/Synopsys/verdi_green/verdi-2021.09-sp2
export PATH=$VCS_HOME/bin:$VERDI_HOME/bin:$PATH

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

verdi -sv -f sim.f -ssf waves/snn_soc.fsdb
