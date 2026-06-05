"""Tests for v2c.cost (SOP accounting + projected-cycle formula)."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import numpy as np  # noqa: E402
import pytest  # noqa: E402

import cost  # noqa: E402


def test_input_sop_bitcount():
    imgs = np.full((1, 784), 255, dtype=np.uint8)              # 255 -> in4 value 15 -> popcount 4
    sop, bits = cost.input_sop(imgs, hid_dim=246, in_bits=4)
    assert bits == pytest.approx(784 * 4)
    assert sop == pytest.approx(784 * 4 * 246)
    sop0, bits0 = cost.input_sop(np.zeros((1, 784), np.uint8), hid_dim=246, in_bits=4)
    assert bits0 == 0 and sop0 == 0                            # all-zero image -> no input events


def test_output_sop_and_summary():
    assert cost.output_sop(100, 10) == 1000                    # single-spike: 100 fired × 10 outputs
    s = cost.sop_summary(np.zeros((1, 784), np.uint8), hidden_fire_count=123, hid_dim=246, out_dim=10, W=4)
    assert s["output_sop"] == 1230 and s["output_sop_cells"] == 1230 * 4
    assert s["input_sop"] == 0 and s["total_sop"] == 1230


def test_projected_cycles_structure():
    c = cost.projected_cycles(in_dim=784, hid_dim=246, out_dim=10, W=4, in_bits=4, T=16, t_exit=7,
                              macro_cols=256, row_stream_cyc=1)
    assert c["stripes"] == 4                                   # ceil(246*4 / 256) = ceil(3.84) = 4
    assert c["input_cycles"] == 4 * 4 * 784                    # in_bits * stripes * (in_dim * 1)
    assert c["output_cycles"] == 7 and c["algorithmic_t_exit"] == 7
    assert c["projected_total_cycles"] == c["input_cycles"] + c["output_cycles"]
