#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools
resolve_python_tool

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.synthetic_conv_bitexact_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

LOG="$SCRIPT_DIR/synthetic_conv_bitexact_sim.log"
: > "$LOG"

GOLDEN_DIR_HOST=$(to_windows_path "$SCRIPT_DIR/../python_multilayer")
MANIFEST_HOST=$(to_windows_path "$SCRIPT_DIR/../python_multilayer/synthetic_golden_manifest.json")
CASE_TABLE="$RUN_DIR/synthetic_cases.tsv"

run_python - "$MANIFEST_HOST" > "$CASE_TABLE" <<'PY'
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1]).resolve()
manifest = json.loads(manifest_path.read_text(encoding="ascii"))
root = manifest_path.parent

for idx, entry in enumerate(manifest["cases"], start=1):
    cfg_path = root / entry["files"]["cfg_expected"]
    cfg = json.loads(cfg_path.read_text(encoding="ascii"))
    row = [
        str(idx),
        entry["case"],
        str(cfg["K"]),
        str(cfg["stride"]),
        str(cfg["pad"]),
        str(cfg["C_in"]),
        str(cfg["C_out"]),
        str(cfg["H"]),
        str(cfg["W"]),
        str(cfg["out_H"]),
        str(cfg["out_W"]),
        str(cfg["T"]),
        str(cfg["threshold"]),
        str(cfg["tile_count"]),
        str(cfg["last_tile_valid_count"]),
        str(cfg["expected_err_code"]),
        cfg["expected_err_name"],
        entry["sha256"]["output_counts"],
    ]
    print("\t".join(row))
PY

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_synthetic_conv_bitexact.f \
  -s synthetic_conv_bitexact_tb -o "$RUN_DIR/synthetic_conv_bitexact_tb.out"

while IFS=$'\t' read -r CASE_TAG CASE_NAME K STRIDE PAD C_IN C_OUT H W OUT_H OUT_W T THRESHOLD TILE_COUNT LAST_TILE EXPECTED_ERR_CODE EXPECTED_ERR_NAME GOLDEN_COUNTS_SHA
do
  CASE_TAG=${CASE_TAG//$'\r'/}
  CASE_NAME=${CASE_NAME//$'\r'/}
  EXPECTED_ERR_NAME=${EXPECTED_ERR_NAME//$'\r'/}
  GOLDEN_COUNTS_SHA=${GOLDEN_COUNTS_SHA//$'\r'/}
  GOLDEN_COUNTS_SHA=$(printf '%s' "$GOLDEN_COUNTS_SHA" | tr -cd '0-9a-fA-F')
  CASE_DIR="$RUN_DIR/$CASE_NAME"
  mkdir -p "$CASE_DIR"
  CASE_DIR_HOST=$(to_windows_path "$CASE_DIR")
  CASE_LOG="$CASE_DIR/sim.log"

  run_python - "$GOLDEN_DIR_HOST" "$CASE_NAME" "$CASE_DIR_HOST" "$C_OUT" "$TILE_COUNT" <<'PY'
import shutil
import sys
from pathlib import Path

src_root = Path(sys.argv[1]).resolve()
case_name = sys.argv[2]
case_dir = Path(sys.argv[3]).resolve()
c_out = int(sys.argv[4])
tile_count = int(sys.argv[5])

def pad_hex(src_path: Path, dst_path: Path, total_lines: int) -> None:
    lines = [line.rstrip("\r\n") for line in src_path.read_text(encoding="ascii").splitlines() if line.strip()]
    if len(lines) > total_lines:
        lines = lines[:total_lines]
    lines.extend(["0"] * (total_lines - len(lines)))
    dst_path.write_text("\n".join(lines) + "\n", encoding="ascii")

pad_hex(src_root / f"synthetic_{case_name}_input_fmap_words.hex",
        case_dir / f"synthetic_{case_name}_input_fmap_words.hex", 65536)
for tile_idx in range(tile_count):
    pad_hex(src_root / f"synthetic_{case_name}_weight_tile_{tile_idx}_pos.hex",
            case_dir / f"synthetic_{case_name}_weight_tile_{tile_idx}_pos.hex",
            256 * c_out)
    pad_hex(src_root / f"synthetic_{case_name}_weight_tile_{tile_idx}_neg.hex",
            case_dir / f"synthetic_{case_name}_weight_tile_{tile_idx}_neg.hex",
            256 * c_out)

cfg = src_root / f"synthetic_{case_name}_cfg_expected.json"
if cfg.exists():
    shutil.copyfile(cfg, case_dir / cfg.name)
counts = src_root / f"synthetic_{case_name}_output_counts.txt"
if counts.exists():
    shutil.copyfile(counts, case_dir / counts.name)
PY

  echo "[RUN] case=$CASE_NAME" | tee -a "$LOG"
  run_vvp "$RUN_DIR/synthetic_conv_bitexact_tb.out" \
    "+CASE_NAME=$CASE_NAME" \
    "+CASE_TAG=$CASE_TAG" \
    "+GOLDEN_DIR=$CASE_DIR_HOST" \
    "+OUT_DIR=$CASE_DIR_HOST" \
    "+K=$K" \
    "+STRIDE=$STRIDE" \
    "+PAD=$PAD" \
    "+C_IN=$C_IN" \
    "+C_OUT=$C_OUT" \
    "+H=$H" \
    "+W=$W" \
    "+OUT_H=$OUT_H" \
    "+OUT_W=$OUT_W" \
    "+T=$T" \
    "+THRESHOLD=$THRESHOLD" \
    "+TILE_COUNT=$TILE_COUNT" \
    "+LAST_TILE_VALID=$LAST_TILE" \
    "+EXPECTED_ERR_CODE=$EXPECTED_ERR_CODE" \
    "+EXPECTED_ERR_NAME=$EXPECTED_ERR_NAME" </dev/null | tee "$CASE_LOG"

  cat "$CASE_LOG" >> "$LOG"

  if ! grep -q "SYNTHETIC_CONV_BITEXACT_PASS case=$CASE_NAME" "$CASE_LOG"; then
    echo "[RESULT] FAIL case=$CASE_NAME tb-did-not-pass" | tee -a "$LOG"
    exit 1
  fi

  STATUS_FILE_HOST=$(to_windows_path "$CASE_DIR/synthetic_${CASE_NAME}_STATUS.ERR")
  if [ "$EXPECTED_ERR_CODE" = "0" ]; then
    RTL_COUNTS_HOST=$(to_windows_path "$CASE_DIR/synthetic_${CASE_NAME}_rtl_output_counts.txt")
    RTL_SHA=$(run_python - "$RTL_COUNTS_HOST" <<'PY'
import hashlib
import sys
from pathlib import Path

print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)
    RTL_SHA=${RTL_SHA//$'\r'/}
    RTL_SHA=$(printf '%s' "$RTL_SHA" | tr -cd '0-9a-fA-F')
    echo "[SHA] case=$CASE_NAME golden=$GOLDEN_COUNTS_SHA rtl=$RTL_SHA" | tee -a "$LOG"
    if [ "$RTL_SHA" != "$GOLDEN_COUNTS_SHA" ]; then
      echo "[RESULT] FAIL case=$CASE_NAME sha-mismatch" | tee -a "$LOG"
      exit 1
    fi

    run_python - "$STATUS_FILE_HOST" <<'PY'
import sys
from pathlib import Path

data = {}
for line in Path(sys.argv[1]).read_text(encoding="ascii").splitlines():
    if not line:
        continue
    key, value = line.split("=", 1)
    data[key] = value

assert data["ERR_CODE"] == "0", data
assert data["ERR_NAME"] == "OK", data
assert data["DONE_STICKY"] == "1", data
assert data["BUSY_FINAL"] == "0", data
PY
  else
    run_python - "$STATUS_FILE_HOST" "$CASE_NAME" "$EXPECTED_ERR_CODE" "$EXPECTED_ERR_NAME" <<'PY'
import sys
from pathlib import Path

status_path = Path(sys.argv[1])
case_name = sys.argv[2]
expected_err_code = sys.argv[3]
expected_err_name = sys.argv[4]

expected = "\n".join([
    f"CASE={case_name}",
    f"ERR_CODE={expected_err_code}",
    f"ERR_NAME={expected_err_name}",
    "WEIGHT_REQ_SEEN=0",
    "STAGE_START_COUNT=0",
    "MAC_START_COUNT=0",
    "MAC_DONE_COUNT=0",
    "FMAP_WRITE_COUNT=0",
    "OUTPUT_BANK_CHANGED=0",
    "DONE_STICKY=1",
    "BUSY_FINAL=0",
]) + "\n"

actual = status_path.read_text(encoding="ascii")
if actual != expected:
    print("STATUS.ERR mismatch", file=sys.stderr)
    print("--- expected ---", file=sys.stderr)
    print(expected, file=sys.stderr, end="")
    print("--- actual ---", file=sys.stderr)
    print(actual, file=sys.stderr, end="")
    raise SystemExit(1)
PY
  fi

  echo "[RESULT] PASS case=$CASE_NAME" | tee -a "$LOG"
done < "$CASE_TABLE"

echo "============================================" | tee -a "$LOG"
echo "[RESULT] SYNTHETIC_CONV_BITEXACT_PASS" | tee -a "$LOG"
echo "============================================" | tee -a "$LOG"
