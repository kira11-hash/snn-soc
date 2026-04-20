"""Test V1 baseline bit-parity (A1.2 hard gate).

Runs ``run_baseline_64to10.main`` with the real V1 data. Skipped if V1
files are missing (e.g., on CI without V1 vendored tree) to keep pure
schema tests fast.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import config_multilayer as cfg  # noqa: E402


def _v1_files_available() -> bool:
    """Check whether the V1 HEX + alignment manifest exist."""
    v1 = cfg.V1_PYTHON_DIR
    candidates = [
        v1 / "results/exports/weight_pos.hex",
        v1 / "results/exports/weight_neg.hex",
        v1 / "results/exports/rtl_stimulus_batch100/alignment_manifest.json",
        v1 / "weights_full/avgpool_8x8.pt",
    ]
    return all(p.exists() for p in candidates)


@pytest.mark.skipif(
    not _v1_files_available(),
    reason="V1 HEX weights / alignment manifest not available (run V1 first)",
)
def test_baseline_bit_parity():
    """Invoke run_baseline_64to10.main and expect return code 0 (PASS)."""
    # Import here to keep torchvision dependency out of pure-schema tests.
    from run_baseline_64to10 import main as run_baseline_main

    args = argparse.Namespace(topologies=str(ROOT / "topologies.yaml"))
    rc = run_baseline_main(args)
    assert rc == 0, f"Baseline parity failed with return code {rc}"


@pytest.mark.skipif(
    not _v1_files_available(),
    reason="V1 float weights / HEX weights not available (run V1 first)",
)
def test_v2_export_quantization_matches_v1_hex():
    """V2 exporter quantization must reproduce V1 staged HEX exactly.

    Memory-vs-HEX round-trip tests are necessary but not sufficient: they can
    pass even if V2 uses a different quantizer. This test compares V2's
    stage quantization on V1 `avgpool_8x8.pt` against V1's frozen
    `weight_pos.hex` / `weight_neg.hex`.
    """
    import numpy as np
    import torch

    from _vendored_from_v1.integer_reference import load_weight_hex
    from exporter_multilayer import _get_device_levels_for_export, _quantize_stage_weights

    state = torch.load(cfg.V1_PYTHON_DIR / "weights_full/avgpool_8x8.pt", map_location="cpu")
    if "fc.weight" in state:
        weight = state["fc.weight"]
    else:
        weight = next(v for v in state.values() if isinstance(v, torch.Tensor) and v.ndim == 2)

    levels = _get_device_levels_for_export(2 ** cfg.QAT_WEIGHT_BITS)
    v2_pos, v2_neg = _quantize_stage_weights(weight.float(), cfg.QAT_WEIGHT_BITS, levels)

    v1_pos = np.array(
        load_weight_hex(str(cfg.V1_PYTHON_DIR / "results/exports/weight_pos.hex")),
        dtype=np.int64,
    )
    v1_neg = np.array(
        load_weight_hex(str(cfg.V1_PYTHON_DIR / "results/exports/weight_neg.hex")),
        dtype=np.int64,
    )

    assert np.array_equal(v2_pos, v1_pos)
    assert np.array_equal(v2_neg, v1_neg)
