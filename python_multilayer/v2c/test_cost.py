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


def test_input_skip_cycles_conventions():
    # img0: 100 nonzero pixels at 255 (->level 15, popcount 4); img1: all zero
    imgs = np.zeros((2, 784), np.uint8)
    imgs[0, :100] = 255
    r = cost.input_skip_cycles(imgs, in_dim=784, hid_dim=246, W=4, in_bits=4, read_bits=128)
    assert r["in_stripes"] == 8                              # ceil(246*4/128)
    assert r["dense"] == 4 * 8 * 784                         # baseline
    assert r["row_event_count"]["worst"] == 100 and r["row_event_count"]["best"] == 0  # nonzero pixels
    assert r["bit_event_count"]["worst"] == 400             # 100 px × popcount(15)=4
    assert r["value_event_cycles"]["worst"] == 8 * 100      # in_stripes × nnz
    assert r["bit_event_cycles"]["worst"] == 8 * 400        # in_stripes × Σpopcount
    # value-event strictly cheaper than bit-event (nnz < Σpopcount) when any pixel has >1 set bit
    assert r["value_event_cycles"]["worst"] < r["bit_event_cycles"]["worst"]


def test_projected_cycles_structure():
    # read_bits=128 (plan-v1.md P_READ_BITS): hidden 246*W4 -> 8 input stripes, output 10*W4 -> 1 stripe
    c = cost.projected_cycles(in_dim=784, hid_dim=246, out_dim=10, W=4, in_bits=4, T=16, t_exit=7,
                              read_bits=128, fired_hidden_by_exit=100, row_stream_cyc=1)
    assert c["in_stripes"] == 8                                # ceil(246*4 / 128) = ceil(7.69) = 8
    assert c["out_stripes"] == 1                               # ceil(10*4 / 128) = 1
    assert c["input_cycles"] == 4 * 8 * 784                    # in_bits * stripes * (in_dim * 1)
    # output layer is EVENT-DRIVEN: cycles scale with ACTIVE hidden rows, NOT the algorithmic t_exit
    assert c["output_cycles"] == 100 * 1 and c["active_hidden_rows"] == 100
    assert c["algorithmic_t_exit"] == 7                        # algorithmic latency kept separate from cycles
    assert c["projected_total_cycles"] == c["input_cycles"] + c["output_cycles"]
    # conservative fallback: no fired-hidden count -> worst case all hidden rows
    c2 = cost.projected_cycles(hid_dim=246, out_dim=10, W=4, read_bits=128)
    assert c2["active_hidden_rows"] == 246 and c2["output_cycles"] == 246
