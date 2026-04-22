"""Test exporter round-trip bit-parity (A3 hard gate).

Build a tiny ``MultiLayerANN`` with random float weights, export via
``exporter_multilayer.export_topology``, then reload the HEX files and
assert the level indices are bit-identical to the memory-quantized form.

This test does NOT need V1 files or MNIST; it only tests the quant+export
round-trip, which is the A6.a-relevant invariant.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

import numpy as np
import pytest
import torch

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from exporter_multilayer import (  # noqa: E402
    export_topology,
    load_hex_weights_for_topology,
    weights_in_memory_int_form,
)
from topologies import StageConfig, TopologyConfig  # noqa: E402
from trainer_multilayer import MultiLayerANN  # noqa: E402


def _make_topology(name: str = "test_2stage") -> TopologyConfig:
    return TopologyConfig(
        name=name,
        role="v2_demo",
        num_fc_stages=2,
        input_dim=8,
        stages=[
            StageConfig(
                in_dim=8, out_dim=6, timesteps=10, use_bitplane=True,
                threshold=200,
                weight_pos_hex=f"results_multilayer/{name}/weights/L0_pos.hex",
                weight_neg_hex=f"results_multilayer/{name}/weights/L0_neg.hex",
            ),
            StageConfig(
                in_dim=6, out_dim=4, timesteps=1, use_bitplane=False,
                threshold=50,
                weight_pos_hex=f"results_multilayer/{name}/weights/L1_pos.hex",
                weight_neg_hex=f"results_multilayer/{name}/weights/L1_neg.hex",
            ),
        ],
    )


@pytest.fixture
def tiny_model_and_topology():
    torch.manual_seed(0)
    topology = _make_topology()
    model = MultiLayerANN(topology)
    # Replace weights with reproducible floats (mix of pos/neg/zeros)
    with torch.no_grad():
        model.layers[0].weight.copy_(torch.randn(6, 8) * 0.5)
        model.layers[1].weight.copy_(torch.randn(4, 6) * 0.3)
    return model, topology


def test_export_creates_expected_files(tiny_model_and_topology):
    model, topology = tiny_model_and_topology
    with tempfile.TemporaryDirectory() as tmpdir:
        out_dir = Path(tmpdir) / topology.name
        manifest = export_topology(topology, model.state_dict(), out_dir)

        # Files exist
        assert (out_dir / "manifest.json").exists()
        for i in range(topology.num_fc_stages):
            assert (out_dir / "weights" / f"L{i}_pos.hex").exists()
            assert (out_dir / "weights" / f"L{i}_neg.hex").exists()

        # Manifest structure
        assert manifest["topology_name"] == topology.name
        assert manifest["num_fc_stages"] == 2
        assert len(manifest["stages"]) == 2
        assert manifest["total_nonzero_cells"] >= 0
        assert manifest["quantization"]["weight_bits"] == 4
        for i, stage_meta in enumerate(manifest["stages"]):
            assert stage_meta["layer"] == i
            assert "weight_pos_sha256" in stage_meta
            assert "weight_neg_sha256" in stage_meta
            assert stage_meta["nonzero_cells"] >= 0
            assert stage_meta["physical_cells"] > 0


def test_memory_vs_hex_bit_parity(tiny_model_and_topology):
    """Core A3 hard gate: quantized-in-memory == quantized-from-hex, bit-identical."""
    model, topology = tiny_model_and_topology
    with tempfile.TemporaryDirectory() as tmpdir:
        out_dir = Path(tmpdir) / topology.name
        export_topology(topology, model.state_dict(), out_dir)

        mem_weights = weights_in_memory_int_form(topology, model.state_dict())
        hex_weights = load_hex_weights_for_topology(topology, out_dir)

        assert len(mem_weights) == len(hex_weights) == topology.num_fc_stages
        for i, ((mp, mn), (hp, hn)) in enumerate(zip(mem_weights, hex_weights)):
            assert mp.shape == hp.shape, (
                f"stage {i} w_pos shape differs: mem={mp.shape} hex={hp.shape}"
            )
            assert mn.shape == hn.shape
            assert np.array_equal(mp, hp), f"stage {i} w_pos memory != hex"
            assert np.array_equal(mn, hn), f"stage {i} w_neg memory != hex"


def test_hex_values_are_4bit_range(tiny_model_and_topology):
    """All exported hex values must be in [0, 15] (4-bit level indices)."""
    model, topology = tiny_model_and_topology
    with tempfile.TemporaryDirectory() as tmpdir:
        out_dir = Path(tmpdir) / topology.name
        export_topology(topology, model.state_dict(), out_dir)
        for i in range(topology.num_fc_stages):
            for suffix in ("pos", "neg"):
                hex_path = out_dir / "weights" / f"L{i}_{suffix}.hex"
                values = [int(line.strip(), 16) for line in hex_path.read_text().splitlines() if line.strip()]
                assert values, f"{hex_path} is empty"
                assert all(0 <= v <= 15 for v in values), (
                    f"{hex_path} contains values outside [0, 15]"
                )


def test_hex_file_line_count(tiny_model_and_topology):
    """Line count == in_dim * out_dim for each stage."""
    model, topology = tiny_model_and_topology
    with tempfile.TemporaryDirectory() as tmpdir:
        out_dir = Path(tmpdir) / topology.name
        export_topology(topology, model.state_dict(), out_dir)
        for i, stage in enumerate(topology.stages):
            expected_lines = stage.in_dim * stage.out_dim
            for suffix in ("pos", "neg"):
                hex_path = out_dir / "weights" / f"L{i}_{suffix}.hex"
                actual_lines = sum(1 for line in hex_path.read_text().splitlines() if line.strip())
                assert actual_lines == expected_lines, (
                    f"{hex_path} has {actual_lines} lines, expected {expected_lines}"
                )


def test_rtl_adc_scale_self_check():
    """Sanity: rtl_adc_scale produces expected values for reference inputs."""
    from snn_engine_multilayer import _self_check_adc_scale
    _self_check_adc_scale()  # raises AssertionError on failure


def test_v2_bitplane_matches_v1_rtl_inference():
    """Invariant: V2 ``_run_stage_bitplane`` must match V1 ``rtl_snn_inference``
    bit-for-bit on a single-layer (64→10) configuration.

    This is the foundation for A6.a (RTL bit parity): if V2's multilayer
    reference diverges from V1's integer path even for the Layer-0-only case,
    multilayer parity has no chance of holding. Runs on random small inputs
    so it doesn't need MNIST or V1 files.
    """
    import numpy as np
    import random

    from _vendored_from_v1.integer_reference import (
        NUM_INPUTS,
        NUM_OUTPUTS,
        LEVEL_MAX,
        rtl_snn_inference,
    )
    from snn_engine_multilayer import _run_stage_bitplane
    from topologies import StageConfig

    rng = random.Random(20260419)
    # Random 64×10 weights in [0, 15], random uint8 pixel vec, V1 threshold.
    w_pos_list = [
        [rng.randint(0, LEVEL_MAX) for _ in range(NUM_OUTPUTS)]
        for _ in range(NUM_INPUTS)
    ]
    w_neg_list = [
        [rng.randint(0, LEVEL_MAX) for _ in range(NUM_OUTPUTS)]
        for _ in range(NUM_INPUTS)
    ]
    pixel_vec_list = [rng.randint(0, 255) for _ in range(NUM_INPUTS)]

    timesteps = 10
    threshold = 2550

    # V1 path
    v1_counts, v1_pred, v1_membrane = rtl_snn_inference(
        pixel_vec=pixel_vec_list,
        w_pos=w_pos_list,
        w_neg=w_neg_list,
        timesteps=timesteps,
        threshold=threshold,
    )

    # V2 path: numpy arrays shape [in_dim, out_dim] for weights, [in_dim] for pixel
    w_pos_np = np.array(w_pos_list, dtype=np.int64)   # [64, 10]
    w_neg_np = np.array(w_neg_list, dtype=np.int64)
    pixel_np = np.array(pixel_vec_list, dtype=np.int64)

    stage = StageConfig(
        in_dim=NUM_INPUTS, out_dim=NUM_OUTPUTS,
        timesteps=timesteps, use_bitplane=True, threshold=threshold,
        weight_pos_hex="dummy.hex", weight_neg_hex="dummy.hex",
    )
    v2_counts, v2_membrane, _mask = _run_stage_bitplane(stage, pixel_np, w_pos_np, w_neg_np)

    assert v2_counts.tolist() == v1_counts, (
        f"spike_counts mismatch: V1={v1_counts}, V2={v2_counts.tolist()}"
    )
    assert v2_membrane.tolist() == v1_membrane, (
        f"membrane mismatch: V1={v1_membrane}, V2={v2_membrane.tolist()}"
    )
    assert int(np.argmax(v2_counts)) == v1_pred


def test_bitplane_feedback_mask_is_layer_or_accumulation():
    """RTL feedback is OR-accumulated across all sub-step spike_mask pulses
    within a single layer, NOT just the last event.

    【2026-04-22 audit note — corrected from previous last-event assumption】
    Verified in rtl/snn/spike_feedback.sv:62-63 (v2 HEAD):
        if (spike_mask_valid) spike_latched <= spike_latched | spike_mask;
    This OR accumulates across every `spike_mask_valid` pulse (one per
    bit-plane × timestep event). `spike_latched` clears on `feedback_en`
    at layer boundaries.

    lif_neuron_alu.sv does clear `spike_mask` on every `neuron_in_valid`
    (line 183), so its per-round spike_mask is "last-event only" — but the
    downstream accumulator `spike_feedback.spike_latched` merges them into
    a layer-level OR. Python `_run_stage_bitplane` returns the latter,
    matching what stage N+1 actually reads as WL input.

    Previous test expected `feedback_mask == [0]` based on the
    "last-event-only" misreading of the RTL; that contradicted both the
    current Python implementation AND the post-FP-009 RTL behavior. This
    test now locks in the OR-accumulation invariant so future Python/RTL
    changes cannot silently regress to last-event semantics.
    """
    import numpy as np

    from snn_engine_multilayer import _run_stage_bitplane
    from topologies import StageConfig

    stage = StageConfig(
        in_dim=1,
        out_dim=1,
        timesteps=1,
        use_bitplane=True,
        threshold=400,
        weight_pos_hex="dummy.hex",
        weight_neg_hex="dummy.hex",
    )
    pixel_vec = np.array([128], dtype=np.int64)  # bit7 only
    w_pos = np.array([[15]], dtype=np.int64)
    w_neg = np.array([[0]], dtype=np.int64)

    counts, _membrane, feedback_mask = _run_stage_bitplane(
        stage, pixel_vec, w_pos, w_neg
    )

    # bit7 event fires → spike_counts=1 AND feedback_mask=1 (OR of all events)
    # bit0 event does not fire → lif_neuron_alu.spike_mask for that round is 0,
    # but spike_feedback.spike_latched has already OR'd in the bit7 fire.
    assert counts.tolist() == [1]
    assert feedback_mask.tolist() == [1], (
        "feedback_mask must OR-accumulate across events within a layer; "
        f"got {feedback_mask.tolist()}"
    )
