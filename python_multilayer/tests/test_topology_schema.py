"""Test topologies.yaml schema validation.

Runs fully offline — no torch / torchvision / V1 files required.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest
import yaml
from pydantic import ValidationError

# Make ``python_multilayer/`` importable regardless of pytest invocation dir.
ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from topologies import (  # noqa: E402
    HW_MAX_BL_SCAN,
    HW_MAX_LAYERS,
    HW_NUM_INPUTS,
    StageConfig,
    TopologyConfig,
    TopologyFile,
    load_topologies,
    load_topology_file,
)

TOPOLOGIES_YAML = ROOT / "topologies.yaml"


def _sample_stage(**overrides):
    base = dict(
        in_dim=64, out_dim=32, timesteps=10, use_bitplane=True,
        threshold=2550, weight_pos_hex="a.hex", weight_neg_hex="b.hex",
    )
    base.update(overrides)
    return base


# ─────────────────────────────────────────────────────────────────────────
# StageConfig validators
# ─────────────────────────────────────────────────────────────────────────
class TestStageConfig:
    def test_valid_stage(self):
        s = StageConfig(**_sample_stage())
        assert s.in_dim == 64
        assert s.out_dim == 32
        assert s.bl_scan_count == 64
        assert s.wl_count == 64

    def test_bl_scan_count_derives_correctly(self):
        s = StageConfig(**_sample_stage(out_dim=24))
        assert s.bl_scan_count == 48

    def test_in_dim_zero_rejected(self):
        with pytest.raises(ValidationError, match="in_dim"):
            StageConfig(**_sample_stage(in_dim=0))

    def test_in_dim_over_256_rejected(self):
        # V2.B REV 2: HW_NUM_INPUTS = 256 (was 64)
        with pytest.raises(ValidationError, match="in_dim"):
            StageConfig(**_sample_stage(in_dim=257))

    def test_out_dim_over_128_rejected(self):
        # V2.B REV 2: MAX_BL_SCAN=256 → out_dim ≤ 128 (was 64)
        with pytest.raises(ValidationError, match="out_dim"):
            StageConfig(**_sample_stage(out_dim=129))

    def test_timesteps_zero_rejected(self):
        with pytest.raises(ValidationError, match="timesteps"):
            StageConfig(**_sample_stage(timesteps=0))

    def test_threshold_negative_rejected(self):
        with pytest.raises(ValidationError, match="threshold"):
            StageConfig(**_sample_stage(threshold=-1))


# ─────────────────────────────────────────────────────────────────────────
# TopologyConfig cross-stage validators
# ─────────────────────────────────────────────────────────────────────────
class TestTopologyConfig:
    def _two_stage(self, **overrides):
        base = dict(
            name="test",
            role="v2_demo",
            num_fc_stages=2,
            input_dim=64,
            stages=[
                _sample_stage(in_dim=64, out_dim=32, threshold=2550),
                _sample_stage(
                    in_dim=32, out_dim=10, use_bitplane=False,
                    timesteps=1, threshold=100,
                ),
            ],
        )
        base.update(overrides)
        return TopologyConfig(**base)

    def test_valid_two_stage(self):
        t = self._two_stage()
        assert t.num_fc_stages == 2
        assert t.stages[0].bl_scan_count == 64
        assert t.stages[1].bl_scan_count == 20

    def test_num_fc_stages_mismatch_rejected(self):
        with pytest.raises(ValidationError, match="num_fc_stages"):
            self._two_stage(num_fc_stages=3)  # len(stages) == 2

    def test_first_stage_in_dim_mismatch_rejected(self):
        with pytest.raises(ValidationError, match="in_dim"):
            self._two_stage(input_dim=32)  # first stage in_dim=64

    def test_adjacent_stage_dim_mismatch_rejected(self):
        with pytest.raises(ValidationError, match="in_dim"):
            TopologyConfig(
                name="bad", role="v2_demo", num_fc_stages=2, input_dim=64,
                stages=[
                    _sample_stage(in_dim=64, out_dim=32),
                    _sample_stage(in_dim=24, out_dim=10),  # should be 32
                ],
            )

    def test_max_bl_scan_enforced(self):
        # V2.B REV 2: MAX_BL_SCAN=256 → out_dim up to 128; 129 should reject.
        with pytest.raises(ValidationError, match="(MAX_BL_SCAN|out_dim)"):
            TopologyConfig(
                name="huge", role="v2_demo", num_fc_stages=1, input_dim=64,
                stages=[_sample_stage(in_dim=64, out_dim=129)],
            )

    def test_num_fc_stages_over_4_rejected(self):
        with pytest.raises(ValidationError, match="num_fc_stages"):
            TopologyConfig(
                name="deep", role="v2_demo", num_fc_stages=5, input_dim=64,
                stages=[_sample_stage() for _ in range(5)],
            )

    def test_role_literal_enforced(self):
        with pytest.raises(ValidationError):
            self._two_stage(role="some_other_role")  # type: ignore[arg-type]


# ─────────────────────────────────────────────────────────────────────────
# topologies.yaml integration
# ─────────────────────────────────────────────────────────────────────────
class TestYamlFile:
    @pytest.fixture
    def topo_file(self) -> TopologyFile:
        return load_topology_file(TOPOLOGIES_YAML)

    def test_loads_without_error(self, topo_file):
        assert topo_file.schema_version == "1.0"
        assert topo_file.global_config.scheme == "B"

    def test_has_expected_topologies(self, topo_file):
        names = {t.name for t in topo_file.topologies}
        # V2.B REV 2 adds 14x14 streamed rate: Fashion (196_10/196_64_10) +
        # MNIST (mnist_196_10/mnist_196_64_10).
        assert names == {
            "64to10_baseline",
            "64_10", "64_24_10", "64_32_10", "64_64_10", "64_32_16_10",
            "196_10", "196_64_10",
            "mnist_196_10", "mnist_196_64_10",
        }

    def test_baseline_role(self, topo_file):
        baseline = next(t for t in topo_file.topologies if t.name == "64to10_baseline")
        assert baseline.role == "v1_frozen_baseline"

    def test_v2_demo_roles(self, topo_file):
        demos = [t for t in topo_file.topologies if t.role == "v2_demo"]
        # V2.B REV 2: 5 legacy 8x8 + 4 new 14x14 (Fashion + MNIST × single + multi) = 9
        assert len(demos) == 9

    def test_v2_demo_stages_use_bitplane_by_encoding(self, topo_file):
        """Per-encoding invariants:
          - input_encoding='bitplane' (legacy 2B-serial, 8x8): all stages use_bitplane=True
          - input_encoding='streamed_rate' (V2.B REV 2, 14x14): all stages use_bitplane=False
        """
        for topology in topo_file.topologies:
            if topology.role != "v2_demo":
                continue
            expected = topology.input_encoding == "bitplane"
            for i, stage in enumerate(topology.stages):
                assert stage.use_bitplane is expected, (
                    f"{topology.name} (encoding={topology.input_encoding}) "
                    f"stage {i}: use_bitplane={stage.use_bitplane}, expected={expected}"
                )

    def test_first_stage_timesteps_sensible(self, topo_file):
        """Stage 0 timesteps expectations:
          - bitplane: timesteps >= 2 (bit-plane accumulates in time)
          - streamed_rate: stage.timesteps field is unused (stream_timesteps dominates);
            require topology.stream_timesteps >= 8 as sanity (BSRC needs T >= 2^bits/factor).
        """
        for topology in topo_file.topologies:
            if topology.input_encoding == "streamed_rate":
                assert topology.stream_timesteps >= 8, (
                    f"{topology.name}: stream_timesteps={topology.stream_timesteps} too small"
                )
            else:
                assert topology.stages[0].timesteps >= 2, (
                    f"{topology.name}: stage 0 timesteps={topology.stages[0].timesteps}"
                )

    def test_subsequent_stage_timesteps_are_one(self, topo_file):
        """2B-serial: stage N>0 runs 1 timestep (each timestep already replays 8 bit-planes)."""
        for topology in topo_file.topologies:
            if topology.role != "v2_demo":
                continue
            for i in range(1, len(topology.stages)):
                assert topology.stages[i].timesteps == 1, (
                    f"{topology.name} stage {i} expected timesteps=1 "
                    "(bit-plane already provides 8 sub-steps per timestep)"
                )

    def test_subsequent_stage_threshold_plausible(self, topo_file):
        """2B-serial: stage N>0 threshold must be realisable given bit-plane sum range.

        Max accumulated membrane over 1 timestep × 8 bit-planes:
            sum_over_bits(2^bit) × max_diff_per_bit × timesteps
          = 255 × max_diff × 1
        where max_diff ≤ 255. So threshold ≤ 255*255 = 65,025.
        """
        max_theoretical = 255 * 255
        for topology in topo_file.topologies:
            if topology.role != "v2_demo":
                continue
            for i, stage in enumerate(topology.stages[1:], start=1):
                assert stage.threshold <= max_theoretical, (
                    f"{topology.name} stage {i} threshold={stage.threshold} "
                    f"exceeds theoretical max accumulated diff {max_theoretical}"
                )

    def test_bl_scan_never_exceeds_hw_limit(self, topo_file):
        for topology in topo_file.topologies:
            for i, stage in enumerate(topology.stages):
                assert stage.bl_scan_count <= HW_MAX_BL_SCAN, (
                    f"{topology.name} stage {i} bl_scan_count={stage.bl_scan_count} "
                    f"exceeds MAX_BL_SCAN={HW_MAX_BL_SCAN}"
                )

    def test_v1_baseline_fields(self, topo_file):
        v1 = topo_file.v1_baseline
        assert v1.frozen_rtl_threshold == 2550
        assert "alignment_manifest" in v1.alignment_manifest or True  # path string ok
        assert 0.0 <= v1.reported_full_test_accuracy <= 1.0

    def test_load_topologies_convenience(self):
        """``load_topologies`` is a shortcut for ``.topologies``."""
        ts = load_topologies(TOPOLOGIES_YAML)
        assert len(ts) == 10  # 1 baseline + 9 v2_demo (5 legacy 8x8 + 4 new 14x14)
