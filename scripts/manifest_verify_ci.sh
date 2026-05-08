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
SOC_DESIGN="$(cd "$AUDIT_V2/.." && pwd)/SoC Design"
MANIFESTS_DIR="$SOC_DESIGN/essay/manifests"

if [ ! -d "$MANIFESTS_DIR" ]; then
    echo "[FATAL] $MANIFESTS_DIR does not exist; run --all first to populate"
    exit 2
fi

# Use a fixed --frozen-utc so the regen is byte-deterministic.
FROZEN_UTC="${FROZEN_UTC:-2026-05-08T00:00:00Z}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "[verify] regenerating manifests in $TMP_DIR (frozen-utc=$FROZEN_UTC)"
python3 "$HERE/make_manifest.py" \
    --all \
    --frozen-utc "$FROZEN_UTC" \
    --out-dir "$TMP_DIR" \
    --require-h1-artifacts

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

echo ""
echo "============================================"
echo "[RESULT] M4_MANIFEST_VERIFY_PASS"
echo "============================================"
exit 0
