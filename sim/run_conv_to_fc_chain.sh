#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools
resolve_python_tool

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.conv_to_fc_chain_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

GOLDEN_DIR="$RUN_DIR/golden"
mkdir -p "$GOLDEN_DIR"

run_python - "$GOLDEN_DIR" <<'PY'
import json
import sys
from pathlib import Path

import numpy as np

root = Path.cwd().parent / "python_multilayer"
sys.path.insert(0, str(root))

from exporter_conv import make_weight_tiles_from_kernel, make_weight_tiles_from_matrix, write_weight_tiles_split_hex
from gen_synthetic_conv_golden import _make_input_spikes, _make_kernel
from pack_fmap_words import pack_spike_fmap, write_hex_words
from snn_engine_conv import run_conv_layer, run_flatten_fc_stage
from synthetic_conv_cases import get_case

out_dir = Path(sys.argv[1])
out_dir.mkdir(parents=True, exist_ok=True)

H = 8
W = 8
C_IN = 4
C_MID = 8
C_OUT = 10
T = 10
FC_THRESHOLD = 32

rng_fc = np.random.default_rng(0xC0A3)

conv_case = get_case("C1")
input_spikes = _make_input_spikes(conv_case)
input_words = pack_spike_fmap(input_spikes)
write_hex_words(input_words, out_dir / "chain_input_fmap_words.hex")

conv_kernel = _make_kernel(conv_case)
conv_tiles = make_weight_tiles_from_kernel(conv_kernel)
write_weight_tiles_split_hex(conv_tiles, out_dir, case_id="CHAIN_CONV")

conv_cfg = conv_case.cfg_dict(include_tile_cfg=True)
conv_result = run_conv_layer(input_words, conv_cfg, conv_tiles)
write_hex_words(conv_result.output_words, out_dir / "chain_conv_output_words.hex")

fc_matrix = rng_fc.integers(-7, 8, size=(H * W * C_MID, C_OUT), dtype=np.int64)
fc_tiles = make_weight_tiles_from_matrix(fc_matrix)
if fc_tiles.shape[0] != 2:
    raise SystemExit(f"expected 2 FC tiles, got {fc_tiles.shape[0]}")
write_weight_tiles_split_hex(fc_tiles, out_dir, case_id="CHAIN_FC")

fc_cfg = {
    "H": H,
    "W": W,
    "C_in": C_MID,
    "C_out": C_OUT,
    "T": T,
    "tile_count": 2,
    "last_tile_valid_count": 256,
    "threshold": FC_THRESHOLD,
    "base_word": 0,
    "out_base_word": 0,
    "flatten_mode": True,
}
fc_counts, fc_membrane, fc_spike_stream = run_flatten_fc_stage(conv_result.output_words, fc_cfg, fc_tiles)

final_stream_path = out_dir / "chain_final_stream_words.hex"
with final_stream_path.open("w", encoding="ascii", newline="\n") as f:
    for t in range(T):
        word = 0
        for cls in range(C_OUT):
            if int(fc_spike_stream[t, cls]):
                word |= 1 << cls
        f.write(f"{word:08x}\n")

meta = {
    "config": {
        "H": H,
        "W": W,
        "C_in": C_IN,
        "C_mid": C_MID,
        "C_out": C_OUT,
        "K": 3,
        "stride": 1,
        "pad": 1,
        "T": T,
        "conv_threshold": 4,
        "fc_threshold": FC_THRESHOLD,
    },
    "fc_counts": [int(x) for x in fc_counts.tolist()],
    "fc_membrane": [int(x) for x in fc_membrane.tolist()],
}
(out_dir / "chain_meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="ascii")
print(f"[PY] generated golden bundle in {out_dir}")
PY

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_conv_to_fc_chain.f \
  -s conv_to_fc_chain_tb -o "$RUN_DIR/conv_to_fc_chain_tb.out"

RTL_STREAM="$RUN_DIR/chain_rtl_stream_words.hex"
RTL_STREAM_HOST=$(to_windows_path "$RTL_STREAM")
LOG="$SCRIPT_DIR/conv_to_fc_chain_sim.log"
run_vvp "$RUN_DIR/conv_to_fc_chain_tb.out" \
  "+GOLDEN_DIR=$GOLDEN_DIR" "+RTL_STREAM=$RTL_STREAM_HOST" | tee "$LOG"

PY_SHA=$(run_python - "$GOLDEN_DIR/chain_final_stream_words.hex" <<'PY'
import hashlib
import sys
from pathlib import Path
print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)
RTL_SHA=$(run_python - "$RTL_STREAM_HOST" <<'PY'
import hashlib
import sys
from pathlib import Path
print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)

echo "[SHA] python_chain_final_stream=$PY_SHA" | tee -a "$LOG"
echo "[SHA] rtl_chain_final_stream=$RTL_SHA" | tee -a "$LOG"

if [ "$PY_SHA" != "$RTL_SHA" ]; then
  echo "[RESULT] CONV_TO_FC_CHAIN_TB_FAIL_SHA_MISMATCH" | tee -a "$LOG"
  exit 1
fi

if grep -q "CONV_TO_FC_CHAIN_TB_PASS" "$LOG"; then
  echo "============================================" | tee -a "$LOG"
  echo "[RESULT] CONV_TO_FC_CHAIN_TB_PASS" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
  exit 0
else
  echo "============================================" | tee -a "$LOG"
  echo "[RESULT] CONV_TO_FC_CHAIN_TB_FAIL" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
  exit 1
fi
