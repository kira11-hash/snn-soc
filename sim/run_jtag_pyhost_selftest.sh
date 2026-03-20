#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_python_tool

run_python scripts/test_jtag_rescue.py
