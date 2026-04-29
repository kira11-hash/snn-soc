#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools
resolve_python_tool

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.conv_tile_e2e_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT
RUN_DIR_HOST=$(to_windows_path "$RUN_DIR")

LOG="$SCRIPT_DIR/conv_tile_e2e_sim.log"
: > "$LOG"

CASE_TABLE="$RUN_DIR/case_table.tsv"
SRC_ROOT_HOST=$(to_windows_path "$SCRIPT_DIR/../python_multilayer")

run_python - "$SRC_ROOT_HOST" "$RUN_DIR_HOST" > "$CASE_TABLE" <<'PY'
import json
import shutil
import sys
from pathlib import Path

import numpy as np

src_root = Path(sys.argv[1])
run_dir = Path(sys.argv[2])
sys.path.insert(0, str(src_root))

from exporter_conv import make_weight_tiles_from_kernel, write_weight_tiles_split_hex
from gen_synthetic_conv_golden import _make_input_spikes, _make_kernel
from pack_fmap_words import pack_spike_fmap, write_hex_words, sha256_file
from snn_engine_conv import run_conv_layer


def pad_hex(src_path: Path, dst_path: Path, total_lines: int) -> None:
    lines = [line.rstrip("\r\n") for line in src_path.read_text(encoding="ascii").splitlines() if line.strip()]
    if len(lines) > total_lines:
        lines = lines[:total_lines]
    lines.extend(["0"] * (total_lines - len(lines)))
    dst_path.write_text("\n".join(lines) + "\n", encoding="ascii")


def emit_case(case_name: str, cfg: dict, expected_err_code: int, expected_err_name: str,
              *, seed: int, weight_delay_max: int = 0, force_timeout: int = 0,
              random_seed: int = 1, reuse_synthetic: bool = False,
              reuse_case_name: str | None = None) -> None:
    case_dir = run_dir / case_name
    case_dir.mkdir(parents=True, exist_ok=True)
    stream_words = (int(cfg["T"]) + 31) >> 5
    input_word_count = min(65536, int(cfg["H"]) * int(cfg["W"]) * int(cfg["C_in"]) * stream_words)
    tile_count = int(cfg["tile_count"])
    c_out = int(cfg["C_out"])

    if reuse_synthetic:
        source_name = reuse_case_name or case_name
        pad_hex(src_root / f"synthetic_{source_name}_input_fmap_words.hex",
                case_dir / f"synthetic_{case_name}_input_fmap_words.hex", input_word_count)
        for tile_idx in range(tile_count):
          pad_hex(src_root / f"synthetic_{source_name}_weight_tile_{tile_idx}_pos.hex",
                  case_dir / f"synthetic_{case_name}_weight_tile_{tile_idx}_pos.hex", 256 * c_out)
          pad_hex(src_root / f"synthetic_{source_name}_weight_tile_{tile_idx}_neg.hex",
                  case_dir / f"synthetic_{case_name}_weight_tile_{tile_idx}_neg.hex", 256 * c_out)
        counts_path = src_root / f"synthetic_{source_name}_output_counts.txt"
        if counts_path.exists():
            shutil.copyfile(counts_path, case_dir / f"synthetic_{case_name}_output_counts.txt")
            golden_sha = sha256_file(counts_path)
        else:
            golden_sha = "-"
    else:
        input_spikes = _make_input_spikes(type("Obj", (), {"H": cfg["H"], "W": cfg["W"], "C_in": cfg["C_in"], "T": cfg["T"], "seed": seed})())
        input_words = pack_spike_fmap(input_spikes)
        write_hex_words(input_words, case_dir / f"synthetic_{case_name}_input_fmap_words.hex")
        kernel = _make_kernel(type("Obj", (), {
            "K": cfg["K"], "C_in": cfg["C_in"], "C_out": cfg["C_out"], "seed": seed
        })())
        weight_tiles = make_weight_tiles_from_kernel(kernel)
        write_weight_tiles_split_hex(weight_tiles, case_dir, case_id=case_name)
        if expected_err_code == 0 and not force_timeout:
            result = run_conv_layer(input_words, cfg, weight_tiles)
            counts_path = case_dir / f"synthetic_{case_name}_output_counts.txt"
            with counts_path.open("w", encoding="ascii", newline="\n") as f:
                for h in range(int(cfg["out_H"])):
                    for w in range(int(cfg["out_W"])):
                        for c in range(int(cfg["C_out"])):
                            f.write(f"{h} {w} {c} {int(result.output_counts[h, w, c])}\n")
            golden_sha = sha256_file(counts_path)
        else:
            golden_sha = "-"

    cfg_path = case_dir / f"synthetic_{case_name}_cfg_expected.json"
    cfg_data = dict(cfg)
    cfg_data["expected_err_code"] = expected_err_code
    cfg_data["expected_err_name"] = expected_err_name
    cfg_path.write_text(json.dumps(cfg_data, indent=2) + "\n", encoding="ascii")

    row = [
        case_name, str(cfg["K"]), str(cfg["stride"]), str(cfg["pad"]),
        str(cfg["C_in"]), str(cfg["C_out"]), str(cfg["H"]), str(cfg["W"]),
        str(cfg["out_H"]), str(cfg["out_W"]), str(cfg["T"]), str(cfg["threshold"]),
        str(cfg["tile_count"]), str(cfg["last_tile_valid_count"]),
        str(expected_err_code), expected_err_name, golden_sha,
        str(weight_delay_max), str(force_timeout), str(random_seed),
        str(case_dir),
    ]
    print("\t".join(row[:-1]))


manifest = json.loads((src_root / "synthetic_golden_manifest.json").read_text(encoding="ascii"))
manifest_map = {c["case"]: c for c in manifest["cases"]}
for name in ("C4", "C5", "C6"):
    cfg = json.loads((src_root / manifest_map[name]["files"]["cfg_expected"]).read_text(encoding="ascii"))
    emit_case(name, cfg, 0, "OK", seed=cfg["seed"], reuse_synthetic=True)

emit_case("TC5K5", {
    "K": 5, "stride": 1, "pad": 2, "C_in": 16, "C_out": 16,
    "H": 14, "W": 14, "out_H": 14, "out_W": 14, "T": 10,
    "threshold": 40, "tile_count": 2, "last_tile_valid_count": 144,
}, 0, "OK", seed=501)
emit_case("TPAD2", {
    "K": 5, "stride": 1, "pad": 2, "C_in": 8, "C_out": 16,
    "H": 9, "W": 11, "out_H": 9, "out_W": 11, "T": 16,
    "threshold": 20, "tile_count": 1, "last_tile_valid_count": 200,
}, 0, "OK", seed=502)
emit_case("TNONDIV", {
    "K": 3, "stride": 2, "pad": 0, "C_in": 8, "C_out": 16,
    "H": 27, "W": 33, "out_H": 13, "out_W": 16, "T": 33,
    "threshold": 18, "tile_count": 1, "last_tile_valid_count": 72,
}, 0, "OK", seed=503)
emit_case("TNEGKKC", {
    "K": 5, "stride": 1, "pad": 0, "C_in": 128, "C_out": 16,
    "H": 8, "W": 8, "out_H": 4, "out_W": 4, "T": 10,
    "threshold": 16, "tile_count": 13, "last_tile_valid_count": 128,
}, 1, "ERR_ILLEGAL_KKC", seed=504)
emit_case("TNEGGEOM", {
    "K": 3, "stride": 1, "pad": 0, "C_in": 16, "C_out": 16,
    "H": 65, "W": 33, "out_H": 63, "out_W": 31, "T": 10,
    "threshold": 16, "tile_count": 1, "last_tile_valid_count": 144,
}, 3, "ERR_BAD_GEOMETRY", seed=505)
emit_case("TWEIGHTTIMEOUT", {
    "K": 3, "stride": 1, "pad": 1, "C_in": 32, "C_out": 32,
    "H": 8, "W": 8, "out_H": 8, "out_W": 8, "T": 64,
    "threshold": 48, "tile_count": 2, "last_tile_valid_count": 32,
}, 8, "ERR_WEIGHT_TIMEOUT", seed=506, force_timeout=1)
emit_case("TDELAY_A", {
    "K": 3, "stride": 1, "pad": 1, "C_in": 32, "C_out": 32,
    "H": 8, "W": 8, "out_H": 8, "out_W": 8, "T": 64,
    "threshold": 48, "tile_count": 2, "last_tile_valid_count": 32,
}, 0, "OK", seed=104, weight_delay_max=50, random_seed=111,
          reuse_synthetic=True, reuse_case_name="C4")
emit_case("TDELAY_B", {
    "K": 3, "stride": 1, "pad": 1, "C_in": 32, "C_out": 32,
    "H": 8, "W": 8, "out_H": 8, "out_W": 8, "T": 64,
    "threshold": 48, "tile_count": 2, "last_tile_valid_count": 32,
}, 0, "OK", seed=104, weight_delay_max=50, random_seed=222,
          reuse_synthetic=True, reuse_case_name="C4")
PY

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_conv_tile_e2e.f \
  -s conv_tile_e2e_tb -o "$RUN_DIR/conv_tile_e2e_tb.out"

all_ok=1
DELAY_SHA_A=""
DELAY_SHA_B=""
while IFS= read -r line
do
  line=${line//$'\r'/}
  IFS=$'\t' read -r CASE_NAME K STRIDE PAD C_IN C_OUT H W OUT_H OUT_W T THRESHOLD TILE_COUNT LAST_TILE EXPECT_ERR EXPECT_ERR_NAME GOLDEN_COUNTS_SHA WEIGHT_DELAY_MAX FORCE_TIMEOUT RANDOM_SEED <<< "$line"
  GOLDEN_COUNTS_SHA=$(printf '%s' "$GOLDEN_COUNTS_SHA" | tr -cd '0-9a-fA-F')
  CASE_DIR="$RUN_DIR/$CASE_NAME"
  CASE_DIR_HOST=$(to_windows_path "$CASE_DIR")
  RTL_COUNTS="$CASE_DIR/synthetic_${CASE_NAME}_rtl_output_counts.txt"
  RTL_COUNTS_HOST=$(to_windows_path "$RTL_COUNTS")
  CASE_LOG="$CASE_DIR/sim.log"
  echo "[RUN] case=$CASE_NAME" | tee -a "$LOG"
  run_vvp "$RUN_DIR/conv_tile_e2e_tb.out" \
    "+CASE_NAME=$CASE_NAME" "+CASE_TAG=1" "+GOLDEN_DIR=$CASE_DIR_HOST" "+OUT_DIR=$CASE_DIR_HOST" \
    "+K=$K" "+STRIDE=$STRIDE" "+PAD=$PAD" "+C_IN=$C_IN" "+C_OUT=$C_OUT" \
    "+H=$H" "+W=$W" "+OUT_H=$OUT_H" "+OUT_W=$OUT_W" "+T=$T" \
    "+THRESHOLD=$THRESHOLD" "+TILE_COUNT=$TILE_COUNT" "+LAST_TILE_VALID=$LAST_TILE" \
    "+EXPECTED_ERR_CODE=$EXPECT_ERR" "+EXPECTED_ERR_NAME=$EXPECT_ERR_NAME" \
    "+WEIGHT_READY_DELAY_MAX=$WEIGHT_DELAY_MAX" "+FORCE_TIMEOUT=$FORCE_TIMEOUT" \
    "+RANDOM_SEED=$RANDOM_SEED" </dev/null | tee "$CASE_LOG"
  cat "$CASE_LOG" >> "$LOG"

  if ! grep -q "CONV_TILE_E2E_CASE_PASS case=$CASE_NAME" "$CASE_LOG"; then
    all_ok=0
    break
  fi

  if [ "$EXPECT_ERR" = "0" ]; then
    RTL_SHA=$(run_python - "$RTL_COUNTS_HOST" <<'PY'
import hashlib, sys
from pathlib import Path
print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)
    RTL_SHA=${RTL_SHA//$'\r'/}
    RTL_SHA=$(printf '%s' "$RTL_SHA" | tr -cd '0-9a-fA-F')
    echo "[SHA] case=$CASE_NAME golden=$GOLDEN_COUNTS_SHA rtl=$RTL_SHA" | tee -a "$LOG"
    if [ "$RTL_SHA" != "$GOLDEN_COUNTS_SHA" ]; then
      all_ok=0
      break
    fi
    if [ "$CASE_NAME" = "TDELAY_A" ]; then DELAY_SHA_A="$RTL_SHA"; fi
    if [ "$CASE_NAME" = "TDELAY_B" ]; then DELAY_SHA_B="$RTL_SHA"; fi
  fi
done < "$CASE_TABLE"

if [ "$all_ok" -eq 1 ] && [ -n "$DELAY_SHA_A" ] && [ "$DELAY_SHA_A" = "$DELAY_SHA_B" ]; then
  echo "[SHA] delay_seed_consistency=$DELAY_SHA_A" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
  echo "[RESULT] CONV_TILE_E2E_TB_PASS" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
  exit 0
else
  echo "============================================" | tee -a "$LOG"
  echo "[RESULT] CONV_TILE_E2E_TB_FAIL" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
  exit 1
fi
