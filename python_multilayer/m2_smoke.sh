#!/usr/bin/env bash
# audit-v2/python_multilayer/m2_smoke.sh — < 5min smoke test for M2.
#
# Per essay/m2_design_2026_05_07.md round-2-NIT-inline §5.2:
#   - Verifies most-aggressive sweep point on each dim does not collapse
#     accuracy below 50% on more than 2 of 4 dims (early-warning for
#     unrealistic ranges).
#   - Confirms anchor-row produces M2_NONIDEALITY_OFF=True log.
#   - Confirms non-anchor rows produce M2_NONIDEALITY_OFF=False log per
#     Codex round-2-NIT-inline M2-R2-N1.
#
# Sentinel:
#   M2_SMOKE_PASS  — smoke completed without collapse-failure
#   M2_SMOKE_FAIL  — too many dims collapsed below 50% accuracy

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

CONFIG="${1:-v1_fc_8x8_mnist}"
DIMS=("drift" "read" "d2d" "adc")

TMP_OUT="$(mktemp -d)"
trap 'rm -rf "$TMP_OUT"' EXIT

echo "=== M2 smoke (config=$CONFIG, n_seed=1, smoke ranges) ==="

# 1. Anchor + flag-state regression
python3 m2_anchor_check.py --config 1 || {
    echo "M2_SMOKE_FAIL: anchor check failed"
    exit 1
}

# 2. Run each dim with N=1 and 3 sweep points (anchor + 2 perturbed) — quick
COLLAPSE_COUNT=0
for dim in "${DIMS[@]}"; do
    echo ""
    echo "--- smoke dim: $dim ---"
    python3 m2_envelope_sweep.py \
        --config-id "$CONFIG" \
        --dim "$dim" \
        --n-seed 1 \
        --out-dir "$TMP_OUT" \
        > "$TMP_OUT/${dim}.log" 2>&1
    # Check the most-aggressive (last) sweep point's accuracy
    last_acc=$(tail -n +2 "$TMP_OUT/m2_envelope_${CONFIG}_${dim}.csv" \
               | awk -F, 'END {print $4}')
    echo "  most-aggressive accuracy: $last_acc"
    if awk -v a="$last_acc" 'BEGIN { exit !(a < 50.0) }'; then
        COLLAPSE_COUNT=$((COLLAPSE_COUNT + 1))
        echo "  [warn] dim=$dim collapsed below 50% (acc=$last_acc)"
    fi
    # Check log produced both M2_NONIDEALITY_OFF lines (anchor + non-anchor)
    if ! grep -q "M2_NONIDEALITY_OFF=True (anchor)" "$TMP_OUT/${dim}.log"; then
        echo "[warn] dim=$dim: missing anchor flag log"
    fi
    if ! grep -q "M2_NONIDEALITY_OFF=False" "$TMP_OUT/${dim}.log"; then
        echo "[warn] dim=$dim: missing perturbed flag log"
    fi
done

echo ""
echo "=== smoke summary ==="
echo "collapsed dims: $COLLAPSE_COUNT / 4"
if [ "$COLLAPSE_COUNT" -gt 2 ]; then
    echo ""
    echo "============================================"
    echo "[RESULT] M2_SMOKE_FAIL collapsed_dims=$COLLAPSE_COUNT"
    echo "============================================"
    exit 1
fi

echo ""
echo "============================================"
echo "[RESULT] M2_SMOKE_PASS collapsed_dims=$COLLAPSE_COUNT"
echo "============================================"
