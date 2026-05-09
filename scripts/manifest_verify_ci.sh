#!/usr/bin/env bash
# audit-v2/scripts/manifest_verify_ci.sh — M4 close-out CI step
#
# Mandatory close-out CI step (per essay/m4_design_2026_05_07.md
# round-2 §7 risk M4-2 + Codex round-1 ruling M4-Q5: --verify is the
# gate, hooks are optional).
#
# Generates all 6 manifests deterministically and compares against
# committed copies under essay/manifests/. Exit 0 = manifests in tree
# match the regenerated state. Exit non-zero = drift; reviewer must
# either regenerate + commit or investigate which artifact moved.
#
# Usage:
#   bash audit-v2/scripts/manifest_verify_ci.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AUDIT_V2="$(cd "$HERE/.." && pwd)"
SOC_DESIGN_DEFAULT="$(cd "$AUDIT_V2/.." && pwd)/SoC Design"
SOC_DESIGN="${SOC_DESIGN:-$SOC_DESIGN_DEFAULT}"
MANIFESTS_DIR="$SOC_DESIGN/essay/manifests"
WIN_PYTHON="/mnt/c/Users/24201/AppData/Local/Python/bin/python.exe"
if [ -x "$WIN_PYTHON" ]; then
    PYTHON_BIN="$WIN_PYTHON"
    USE_WIN_PYTHON=1
else
    PYTHON_BIN="${PYTHON_BIN:-python3}"
    USE_WIN_PYTHON=0
fi

if [ ! -d "$MANIFESTS_DIR" ]; then
    echo "[FATAL] $MANIFESTS_DIR does not exist."
    echo "[FATAL] If audit-v2 is not checked out beside 'SoC Design', export SOC_DESIGN=/abs/path/to/SoC Design and retry."
    exit 2
fi

# Use a fixed --frozen-utc so the regen is byte-deterministic.
FROZEN_UTC="${FROZEN_UTC:-2026-05-08T00:00:00Z}"

if [ "$USE_WIN_PYTHON" -eq 1 ]; then
    TMP_DIR="$AUDIT_V2/.manifest_verify_tmp.$$"
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
else
    TMP_DIR="$(mktemp -d)"
fi
trap 'rm -rf "$TMP_DIR"' EXIT

MAKE_MANIFEST_PY="$HERE/make_manifest.py"
H1_EQ_PY="$AUDIT_V2/python_multilayer/h1_lenet5_equivalence_check.py"
TMP_DIR_PY="$TMP_DIR"
if [ "$USE_WIN_PYTHON" -eq 1 ] && command -v wslpath >/dev/null 2>&1; then
    MAKE_MANIFEST_PY="$(wslpath -w "$MAKE_MANIFEST_PY")"
    H1_EQ_PY="$(wslpath -w "$H1_EQ_PY")"
    TMP_DIR_PY="$(wslpath -w "$TMP_DIR")"
fi

M2_ARGS=()
if [ -f "$SOC_DESIGN/essay/exp_m2_envelope/sample_provenance.yaml" ]; then
    echo "[verify] detected post-M2 artifacts; enabling --include-m2-refs"
    M2_ARGS+=(--include-m2-refs)
fi

H1_ARGS=()
if [ -f "$SOC_DESIGN/essay/exp_h1_schedule_ablation/summary_per_config.csv" ]; then
    echo "[verify] detected post-H1 full-set artifacts; enabling --include-h1-refs"
    H1_ARGS+=(--include-h1-refs)
fi

echo "[verify] regenerating manifests in $TMP_DIR (frozen-utc=$FROZEN_UTC)"
"$PYTHON_BIN" "$MAKE_MANIFEST_PY" \
    --all \
    --frozen-utc "$FROZEN_UTC" \
    --out-dir "$TMP_DIR_PY" \
    --require-h1-artifacts \
    "${H1_ARGS[@]}" \
    "${M2_ARGS[@]}"

DRIFT=0
for committed in "$MANIFESTS_DIR"/*.yaml; do
    name="$(basename "$committed")"
    regen="$TMP_DIR/$name"
    if [ ! -f "$regen" ]; then
        echo "[FAIL] $name: missing in regen output"
        DRIFT=$((DRIFT + 1))
        continue
    fi
    if ! diff -q "$committed" "$regen" >/dev/null 2>&1; then
        echo "[FAIL] $name: drifted vs regenerated"
        diff -u "$committed" "$regen" | head -40
        DRIFT=$((DRIFT + 1))
    else
        echo "[ok]   $name"
    fi
done

if [ "$DRIFT" -gt 0 ]; then
    echo ""
    echo "============================================"
    echo "[RESULT] M4_MANIFEST_VERIFY_FAIL drift_count=$DRIFT"
    echo "============================================"
    exit 1
fi

echo "[verify] running LeNet-5 slow/fast equivalence gate"
"$PYTHON_BIN" "$H1_EQ_PY"

echo ""
echo "============================================"
echo "[RESULT] M4_MANIFEST_VERIFY_PASS"
echo "============================================"
exit 0
