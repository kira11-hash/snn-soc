#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.icarus_light_run.XXXXXX")
cleanup() {
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

mkdir -p "$RUN_DIR/waves"

# Current light flow always uses rtl/snn/cim_macro_blackbox.sv.
# It is intentionally weight-independent; use run_icarus_weighted.sh for
# exported weight hex validation.
EXPECTED_OUT_COUNT="${SMOKE_EXPECTED_OUT_COUNT:-100}"
CHECK_OUT_COUNT="${SMOKE_CHECK_OUT_COUNT:-1}"

# Disable SVA assertions for Icarus compatibility ($past is not fully supported).
iverilog -g2012 -gno-assertions -f sim_icarus_light.f -s top_tb_icarus_light -o "$RUN_DIR/icarus_light.out"
(
  cd "$RUN_DIR"
  vvp ./icarus_light.out \
    +EXPECTED_OUT_COUNT="$EXPECTED_OUT_COUNT" \
    +CHECK_OUT_COUNT="$CHECK_OUT_COUNT"
) | tee "$SCRIPT_DIR/icarus_light.log"

if grep -q "LIGHT_SMOKETEST_PASS" "$SCRIPT_DIR/icarus_light.log"; then
  exit 0
fi

echo "[ERROR] LIGHT_SMOKETEST_PASS not found. See sim/icarus_light.log" >&2
exit 1
