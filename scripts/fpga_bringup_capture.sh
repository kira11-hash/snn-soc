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
PYTHON="${PYTHON:-}"
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
    --python)      PYTHON="$2"; shift 2 ;;
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

if [ -z "$PYTHON" ]; then
  if command -v python3 >/dev/null 2>&1; then
    PYTHON="$(command -v python3)"
  elif command -v python >/dev/null 2>&1; then
    PYTHON="$(command -v python)"
  else
    echo "[ERR] neither python3 nor python found; pass --python /path/to/python" >&2
    exit 64
  fi
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
echo "Python     : $PYTHON"
echo "Expected tags:"
for t in "${TAGS[@]}"; do echo "  - $t"; done
if [ ${#FAIL_TAGS[@]} -gt 0 ]; then
  echo "Fail tags:"
  for t in "${FAIL_TAGS[@]}"; do echo "  - $t"; done
fi

# ---------------------------------------------------------------------------
# Python capture via pyserial (portable Windows/Linux/WSL)
#
# Important ordering: open the serial port BEFORE programming the PL.  The E203
# starts from BRAM immediately after fpga programming; opening COM3 after xsct
# returns can miss the first UART tags.
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 1/2: open serial first, then program PL via xsct ---"

if [ "$SKIP_PROGRAM" = "0" ]; then
  if [ -z "$BITSTREAM" ]; then
    echo "[ERR] --bitstream required (or use --skip-program to reuse the running design)" >&2
    exit 64
  fi
  if [ ! -f "$BITSTREAM" ]; then
    echo "[ERR] bitstream not found: $BITSTREAM" >&2
    exit 64
  fi
fi

export FPGA_ROOT_DIR="$ROOT_DIR"
export FPGA_BITSTREAM="$BITSTREAM"
export FPGA_SERIAL_PORT="$SERIAL_PORT"
export FPGA_BAUD="$BAUD"
export FPGA_TIMEOUT="$TIMEOUT"
export FPGA_OUT_LOG="$OUT_LOG"
export FPGA_TAGS="$(printf "%s\n" "${TAGS[@]}")"
export FPGA_FAIL_TAGS="$(printf "%s\n" "${FAIL_TAGS[@]:-}")"
export FPGA_XSCT="$XSCT"
export FPGA_SKIP_PROGRAM="$SKIP_PROGRAM"

"$PYTHON" - <<'PYEOF'
import os
import subprocess
import sys
import threading
import time

try:
    import serial
except Exception as e:
    print(f"[ERR] pyserial import failed: {e}", flush=True)
    sys.exit(4)

root_dir = os.environ["FPGA_ROOT_DIR"]
bitstream = os.environ.get("FPGA_BITSTREAM", "")
port = os.environ["FPGA_SERIAL_PORT"]
baud = int(os.environ["FPGA_BAUD"])
timeout_s = float(os.environ["FPGA_TIMEOUT"])
out_path = os.environ["FPGA_OUT_LOG"]
expect = [t for t in os.environ.get("FPGA_TAGS", "").splitlines() if t]
fail_tags = [t for t in os.environ.get("FPGA_FAIL_TAGS", "").splitlines() if t]
xsct = os.environ.get("FPGA_XSCT", "xsct")
skip_program = os.environ.get("FPGA_SKIP_PROGRAM", "0") == "1"

print(f"[INFO] opening {port} @ {baud} before programming", flush=True)
try:
    ser = serial.Serial(port, baud, timeout=0.1)
    try:
        ser.reset_input_buffer()
    except Exception:
        pass
except Exception as e:
    print(f"[ERR] could not open {port}: {e}", flush=True)
    sys.exit(4)

state = {
    "buf": "",
    "seen": set(),
    "fail_seen": None,
    "stop": False,
}
lock = threading.Lock()

def reader():
    with open(out_path, "w", encoding="utf-8", errors="replace") as fh:
        fh.write(f"# capture from {port} @ {baud} starting {time.ctime()}\n")
        fh.flush()
        while True:
            with lock:
                if state["stop"]:
                    break
            chunk = ser.read(256)
            if not chunk:
                continue
            text = chunk.decode("utf-8", errors="replace")
            sys.stdout.write(text)
            sys.stdout.flush()
            fh.write(text)
            fh.flush()
            with lock:
                state["buf"] += text
                if len(state["buf"]) > 8192:
                    state["buf"] = state["buf"][-4096:]
                for ft in fail_tags:
                    if ft and ft in state["buf"]:
                        state["fail_seen"] = ft
                        state["stop"] = True
                        break
                for t in expect:
                    if t not in state["seen"] and t in state["buf"]:
                        state["seen"].add(t)
                if len(state["seen"]) == len(expect):
                    state["stop"] = True

reader_thread = threading.Thread(target=reader, daemon=True)
reader_thread.start()

xsct_rc = 0
if not skip_program:
    print("", flush=True)
    print("--- programming PL via xsct while serial capture is active ---", flush=True)
    tcl = os.path.join(root_dir, "scripts", "program_zcu102_e203.tcl")
    xsct_log = out_path + ".xsct.log"
    with open(xsct_log, "w", encoding="utf-8", errors="replace") as xfh:
        proc = subprocess.Popen(
            [xsct, tcl, bitstream],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            xfh.write(line)
            xfh.flush()
        xsct_rc = proc.wait()
        if xsct_rc != 0:
            print(f"[ERR] xsct programming failed rc={xsct_rc} — see {xsct_log}", flush=True)
else:
    print("--- SKIP_PROGRAM (reuse already-running FPGA) ---", flush=True)

deadline = time.time() + timeout_s
while time.time() < deadline:
    with lock:
        done = state["stop"]
    if done:
        break
    time.sleep(0.05)

with lock:
    state["stop"] = True
reader_thread.join(timeout=1.0)
ser.close()

print("", flush=True)
print("=" * 60, flush=True)
if xsct_rc != 0:
    sys.exit(3)
if state["fail_seen"]:
    print(f"[RESULT] FAIL — fail tag observed: {state['fail_seen']}", flush=True)
    sys.exit(2)
if len(state["seen"]) == len(expect):
    print(f"[RESULT] PASS — all {len(expect)} tag(s) observed", flush=True)
    for t in expect:
        print(f"  [OK] {t}", flush=True)
    sys.exit(0)

missing = [t for t in expect if t not in state["seen"]]
print("[RESULT] FAIL — timeout, missing tags:", flush=True)
for t in missing:
    print(f"  [MISS] {t}", flush=True)
sys.exit(1)
PYEOF

exit $?
