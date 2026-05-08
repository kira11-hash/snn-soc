#!/usr/bin/env python3
"""
audit-v2/python_multilayer/m2_anchor_check.py — M2 anchor regression gate.

Per essay/m2_design_2026_05_07.md round-2-NIT-inline §6 acceptance:
  * 4 new keyword knobs default to 0.0 and engine is byte-identical
    to current behavior when M2_NONIDEALITY_OFF=True (the default).
  * Anchor accuracy reproduces §3 Table-3 headline within ±0.5%.

This script checks BOTH conditions on Config #1 (V1 8x8 MNIST,
86.74% headline) and Config #4 (V2.B LeNet-5 MNIST, 93.03% headline).

Usage:
  python3 m2_anchor_check.py                # run both configs
  python3 m2_anchor_check.py --config 1     # Config #1 only
  python3 m2_anchor_check.py --config 4     # Config #4 only

Sentinels:
  M2_ANCHOR_CHECK_PASS    — all anchor accuracies within ±0.5%
  M2_ANCHOR_CHECK_FAIL    — at least one anchor accuracy drifted
"""

from __future__ import annotations

import argparse
import sys

import snn_engine_multilayer as eng
import m2_real_inference as real_inf


HEADLINE_ACC = {
    1: 86.74,                # Config #1 V1 FC 64->10 MNIST 8x8
    4: 93.03,                # Config #4 V2.B LeNet-5 MNIST 28x28
}
TOLERANCE_PCT = 0.5


def check_byte_parity_flag() -> bool:
    """Verify M2_NONIDEALITY_OFF default + state struct."""
    ok = True
    if not eng.M2_NONIDEALITY_OFF:
        print("[FAIL] M2_NONIDEALITY_OFF default is False (should be True)")
        ok = False
    expected_zeros = (
        "drift_alpha", "sigma_read_lsb",
        "sigma_d2d_lognormal", "sigma_adc_offset_lsb",
    )
    for k in expected_zeros:
        v = eng._M2_STATE.get(k, None)
        if v != 0.0:
            print(f"[FAIL] _M2_STATE[{k!r}] default = {v!r} (should be 0.0)")
            ok = False
    if ok:
        print("[ok]   M2 default state preserves byte-parity (flag=True, knobs=0.0)")
    return ok


def run_config_anchor(config_number: int) -> bool:
    """Run the real anchor inference path for one config."""
    headline = HEADLINE_ACC.get(config_number)
    if headline is None:
        print(f"[FAIL] unsupported config #{config_number}")
        return False

    config_id = {
        1: real_inf.CONFIG_V1,
        4: real_inf.CONFIG_LENET5,
    }[config_number]
    result = real_inf.run_anchor(config_id)
    delta = abs(result.accuracy_pct - headline)

    print(f"[info] Config #{config_number} headline accuracy: {headline:.2f}%")
    print(f"[info] Real anchor accuracy: {result.accuracy_pct:.2f}%")
    print(f"[info] Sample count: {len(result.sample_indices)}")
    print(f"[info] sample_indices_md5: {result.sample_indices_md5}")
    print(f"[info] baseline_output_md5: {result.baseline_output_md5}")
    print(f"[info] Tolerance: ±{TOLERANCE_PCT}% around headline")

    if delta > TOLERANCE_PCT:
        print(
            f"[FAIL] Config #{config_number}: anchor delta {delta:.2f}% "
            f"exceeds tolerance ±{TOLERANCE_PCT}%"
        )
        return False
    print(f"[ok]   Config #{config_number}: |Δ|={delta:.2f}% within tolerance")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=int, choices=[1, 4],
                        help="Run only one config (default: both)")
    args = parser.parse_args()

    print("=== M2 anchor check ===")
    parity_ok = check_byte_parity_flag()

    targets = [args.config] if args.config else [1, 4]
    config_results = []
    for n in targets:
        print(f"\n--- Config #{n} ---")
        config_results.append(run_config_anchor(n))

    print()
    if parity_ok and all(config_results):
        print("M2_ANCHOR_CHECK_PASS")
        return 0
    print("M2_ANCHOR_CHECK_FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
