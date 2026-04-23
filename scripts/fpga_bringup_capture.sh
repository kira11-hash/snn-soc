#!/usr/bin/env bash
# scripts/fpga_bringup_capture.sh
#
# One-shot FPGA bring-up harness:
#   1. program ZCU102 PL via xsct (J18 USB-JTAG)
#   2. open the COM port (CP2108 Interface 2 on J83 = COM3 by default),
#      stream its bytes to a timestamped log file
#   3. wait for a configurable PASS / FAIL tag list
#   4. compare against expected tags; emit overall PASS or FAIL
#
# Designed to be re-usable for ANY firmware variant: silicon_bringup,
# e203_fpga_smoke (Phase C production), or future variants.  Tag list is
# a command-line argument.
#
# Usage:
#   bash scripts/fpga_bringup_capture.sh \
#        --bitstream fpga_synth/zcu102_e203_demo/out/snn_soc_fpga_top.bit \
#        --serial COM3 \
#        --baud 115200 \
#        --timeout 60 \
#        --tag SILICON_BRINGUP_DIGITAL_PASS
#
#   Multiple --tag args supported (all must appear for overall PASS).
#   --fail-tag adds strings that immediately abort as FAIL if observed.
#
# Exit codes:
#   0  — all expected tags seen, no fail tags
#   1  — timeout without all tags
#   2  — a fail tag observed
#   3  — xsct programming failed
#   4  — serial port could not be opened
#
# Requires:
#   xsct   (Vitis / Vivado)
#   python (PySerial via `pip install pyserial`)
#
# Host OS:
#   Windows (Git Bash / MSYS2): COM3 via pyserial
#   Linux   (/dev/ttyUSB*):     pyserial handles either

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
BITSTREAM=""
SERIAL_PORT="COM3"
BAUD="115200"
TIMEOUT="60"
OUT_LOG=""
TAGS=()
FAIL_TAGS=()
XSCT="${XSCT:-xsct}"
SKIP_PROGRAM="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bitstream)   BITSTREAM="$2"; shift 2 ;;
    --serial)      SERIAL_PORT="$2"; shift 2 ;;
    --baud)        BAUD="$2"; shift 2 ;;
    --timeout)     TIMEOUT="$2"; shift 2 ;;
    --out)         OUT_LOG="$2"; shift 2 ;;
    --tag)         TAGS+=("$2"); shift 2 ;;
    --fail-tag)    FAIL_TAGS+=("$2"); shift 2 ;;
    --skip-program) SKIP_PROGRAM="1"; shift ;;
    --xsct)        XSCT="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,30p' "$0"
      exit 0 ;;
    *)
      echo "[ERR] unknown arg: $1" >&2
      exit 64 ;;
  esac
done

if [ ${#TAGS[@]} -eq 0 ]; then
  echo "[ERR] at least one --tag required" >&2
  exit 64
fi

if [ -z "$OUT_LOG" ]; then
  STAMP="$(date +%Y%m%d_%H%M%S)"
  OUT_LOG="$ROOT_DIR/doc/main-fpga-e203/uart_capture_${STAMP}.log"
fi
mkdir -p "$(dirname "$OUT_LOG")"

echo "=== FPGA bring-up capture ==="
echo "Bitstream  : ${BITSTREAM:-<skipped>}"
echo "Serial     : $SERIAL_PORT @ $BAUD"
echo "Timeout    : ${TIMEOUT}s"
echo "Log        : $OUT_LOG"
echo "Expected tags:"
for t in "${TAGS[@]}"; do echo "  - $t"; done
if [ ${#FAIL_TAGS[@]} -gt 0 ]; then
  echo "Fail tags:"
  for t in "${FAIL_TAGS[@]}"; do echo "  - $t"; done
fi

# ---------------------------------------------------------------------------
# Step 1: xsct programs PL (unless --skip-program)
# ---------------------------------------------------------------------------
if [ "$SKIP_PROGRAM" = "0" ]; then
  if [ -z "$BITSTREAM" ]; then
    echo "[ERR] --bitstream required (or use --skip-program to reuse the running design)" >&2
    exit 64
  fi
  if [ ! -f "$BITSTREAM" ]; then
    echo "[ERR] bitstream not found: $BITSTREAM" >&2
    exit 64
  fi
  echo ""
  echo "--- Step 1: programming PL via xsct ---"
  if ! "$XSCT" "$ROOT_DIR/scripts/program_zcu102_e203.tcl" "$BITSTREAM" 2>&1 | tee "${OUT_LOG}.xsct.log"; then
    echo "[ERR] xsct programming failed — see ${OUT_LOG}.xsct.log" >&2
    exit 3
  fi
  # Let the PL power-stabilise + E203 reset before opening serial
  sleep 1
else
  echo "--- Step 1: SKIP_PROGRAM (reuse already-running FPGA) ---"
fi

# ---------------------------------------------------------------------------
# Step 2: Python capture via pyserial (portable Windows/Linux/WSL)
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 2: serial capture on $SERIAL_PORT ---"

TAGS_JOIN="$(printf "%s\n" "${TAGS[@]}" | tr '\n' '|' | sed 's/|$//')"
FAIL_TAGS_JOIN="$(printf "%s\n" "${FAIL_TAGS[@]:-}" | tr '\n' '|' | sed 's/|$//')"

python - <<PYEOF
import sys, time, serial

port = r"$SERIAL_PORT"
baud = int("$BAUD")
timeout_s = float("$TIMEOUT")
expect = [t for t in r"""${TAGS_JOIN}""".split("|") if t]
fail_tags = [t for t in r"""${FAIL_TAGS_JOIN}""".split("|") if t]
out_path = r"$OUT_LOG"

print(f"[INFO] opening {port} @ {baud}", flush=True)
try:
    ser = serial.Serial(port, baud, timeout=0.5)
except Exception as e:
    print(f"[ERR] could not open {port}: {e}", flush=True)
    sys.exit(4)

start = time.time()
buf = ""
seen = set()
fail_seen = None
with open(out_path, "w", encoding="utf-8", errors="replace") as fh:
    fh.write(f"# capture from {port} @ {baud} starting {time.ctime(start)}\n")
    fh.flush()
    while time.time() - start < timeout_s:
        chunk = ser.read(256)
        if chunk:
            try:
                text = chunk.decode("utf-8", errors="replace")
            except Exception:
                text = ""
            sys.stdout.write(text)
            sys.stdout.flush()
            fh.write(text)
            fh.flush()
            buf += text
            # Keep buffer bounded
            if len(buf) > 8192:
                buf = buf[-4096:]
            # Check fail tags first
            for ft in fail_tags:
                if ft and ft in buf:
                    fail_seen = ft
                    break
            if fail_seen:
                break
            # Check expected tags
            for t in expect:
                if t not in seen and t in buf:
                    seen.add(t)
            if len(seen) == len(expect):
                break
ser.close()

print("", flush=True)
print("=" * 60, flush=True)
if fail_seen:
    print(f"[RESULT] FAIL — fail tag observed: {fail_seen}", flush=True)
    sys.exit(2)
if len(seen) == len(expect):
    print(f"[RESULT] PASS — all {len(expect)} tag(s) observed", flush=True)
    for t in expect:
        print(f"  [OK] {t}", flush=True)
    sys.exit(0)
else:
    missing = [t for t in expect if t not in seen]
    print("[RESULT] FAIL — timeout, missing tags:", flush=True)
    for t in missing:
        print(f"  [MISS] {t}", flush=True)
    sys.exit(1)
PYEOF

# Propagate Python's exit code
exit $?
