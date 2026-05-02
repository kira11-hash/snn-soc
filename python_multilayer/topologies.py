"""Topology configuration schema for V2 multilayer SNN.

Loads ``topologies.yaml`` and validates the configuration against hardware
constraints (MAX_BL_SCAN=128, NUM_INPUTS=64, MAX_LAYERS=4, Scheme B pairing).

The YAML file is the single source of truth consumed by:
    * Python trainer / exporter / RTL-like reference
    * RTL TB (``multilayer_sample_align_tb``, reads via ``$readmemh``)
    * E203 firmware (reads manifest header for layer count / bl_count)
    * Paper Table 1 (topology / accuracy / cell count)

Static configuration only; ``nonzero_cells`` and SHA-256 digests are exporter
artifacts that live in ``manifest.json``, not in this YAML.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Literal

import yaml
from pydantic import BaseModel, Field, computed_field, field_validator, model_validator

logger = logging.getLogger(__name__)

# Hardware constants mirrored from rtl/top/snn_soc_pkg.sv.
# V2.B REV 2 (2026-04-20) expands array to 256×256. Phase 1 Python can use
# these V2 bounds even before RTL is updated; legacy 64×128 topologies still
# pass because their dims are within the larger bounds.
HW_NUM_INPUTS: int = 256      # Max WL count per single-tile FC stage (V2.B: 256)
HW_MAX_BL_SCAN: int = 256     # Max BL scan count (V2.B: 256 = up to 128 out_dim)
HW_MAX_LAYERS: int = 4        # Max FC stages
# Multi-tile FC upper bound: tile_mode=1 splits the WL count into N tiles each
# ≤ HW_NUM_INPUTS and accumulates partial-sums. Used by 28×28 raw-input
# Fashion-MNIST / MNIST ablations (in_dim=784 = 4 tiles of 196). Not yet wired
# bit-exact through Python forward (treat as ideal-forward training accuracy).
HW_NUM_INPUTS_TILED_MAX: int = 1024


class StageConfig(BaseModel):
    """One FC stage (= one CIM inference pass).

    Scheme B pairs positive and negative columns, so the physical ADC scan
    count is ``2 * out_dim``. This is enforced by the ``bl_scan_count``
    computed field; attempts to set a different value are ignored.
    """

    in_dim: int
    out_dim: int
    timesteps: int
    use_bitplane: bool
    threshold: int
    weight_pos_hex: str
    weight_neg_hex: str
    # V2.B REV 2: per-stage ADC full-scale reference. If None, exporter/engine
    # derives from topology-level `adc_full_scale` policy (active_wl / array).
    sum_max: int | None = None

    @computed_field  # type: ignore[misc]
    @property
    def bl_scan_count(self) -> int:
        """Scheme B: positive + negative columns (= 2 × out_dim)."""
        return 2 * self.out_dim

    @computed_field  # type: ignore[misc]
    @property
    def wl_count(self) -> int:
        """Word-line count for this stage (= in_dim)."""
        return self.in_dim

    @field_validator("in_dim")
    @classmethod
    def _in_dim_range(cls, v: int) -> int:
        # Single-tile path: v ≤ HW_NUM_INPUTS (256). Multi-tile (tile_mode=1)
        # path: v ≤ HW_NUM_INPUTS_TILED_MAX (1024 = 4 tiles of 256). Python
        # forward currently uses ideal matmul for both — only single-tile is
        # bit-exact against RTL.
        if not 1 <= v <= HW_NUM_INPUTS_TILED_MAX:
            raise ValueError(
                f"in_dim must be in [1, {HW_NUM_INPUTS_TILED_MAX}] "
                f"(tiled upper bound), got {v}"
            )
        return v

    @field_validator("out_dim")
    @classmethod
    def _out_dim_range(cls, v: int) -> int:
        max_out = HW_MAX_BL_SCAN // 2
        if not 1 <= v <= max_out:
            raise ValueError(
                f"out_dim must be in [1, {max_out}] (MAX_BL_SCAN/2 = half of 128), got {v}"
            )
        return v

    @field_validator("timesteps")
    @classmethod
    def _timesteps_positive(cls, v: int) -> int:
        if v < 1:
            raise ValueError(f"timesteps must be >= 1, got {v}")
        return v

    @field_validator("threshold")
    @classmethod
    def _threshold_nonneg(cls, v: int) -> int:
        if v < 0:
            raise ValueError(f"threshold must be >= 0, got {v}")
        return v


class TopologyConfig(BaseModel):
    """Full topology (a sequence of FC stages).

    V2.B REV 2 (2026-04-20) adds streamed-rate fields at the top level.
    Defaults preserve backward-compat with V2.A count-bitplane topologies:
    ``input_encoding='bitplane'`` + ``stream_timesteps=1`` behaves like V2.A.
    """

    name: str
    role: Literal["v1_frozen_baseline", "v2_demo"]
    num_fc_stages: int
    input_dim: int
    stages: list[StageConfig]
    # V2.B REV 2 fields (defaults keep legacy count-bitplane behavior)
    dataset: Literal["mnist", "fashion_mnist"] = "mnist"
    input_encoding: Literal["bitplane", "streamed_rate"] = "bitplane"
    stream_timesteps: int = 1  # only used when input_encoding='streamed_rate'
    adc_bits: int = 8
    adc_full_scale: Literal["active_wl", "array"] = "active_wl"

    @field_validator("num_fc_stages")
    @classmethod
    def _num_fc_stages_range(cls, v: int) -> int:
        if not 1 <= v <= HW_MAX_LAYERS:
            raise ValueError(
                f"num_fc_stages must be in [1, {HW_MAX_LAYERS}] (MAX_LAYERS), got {v}"
            )
        return v

    @field_validator("input_dim")
    @classmethod
    def _input_dim_range(cls, v: int) -> int:
        if not 1 <= v <= HW_NUM_INPUTS_TILED_MAX:
            raise ValueError(
                f"input_dim must be in [1, {HW_NUM_INPUTS_TILED_MAX}] "
                f"(tiled upper bound), got {v}"
            )
        return v

    @model_validator(mode="after")
    def _validate_topology(self) -> "TopologyConfig":
        # (1) num_fc_stages matches stages length
        if len(self.stages) != self.num_fc_stages:
            raise ValueError(
                f"len(stages)={len(self.stages)} must equal "
                f"num_fc_stages={self.num_fc_stages}"
            )
        # (2) first stage in_dim == top-level input_dim
        if self.stages[0].in_dim != self.input_dim:
            raise ValueError(
                f"stages[0].in_dim={self.stages[0].in_dim} != "
                f"input_dim={self.input_dim}"
            )
        # (3) adjacent stages: stages[i+1].in_dim == stages[i].out_dim
        for i in range(len(self.stages) - 1):
            if self.stages[i + 1].in_dim != self.stages[i].out_dim:
                raise ValueError(
                    f"stage {i + 1} in_dim={self.stages[i + 1].in_dim} != "
                    f"stage {i} out_dim={self.stages[i].out_dim}"
                )
        # (4) bl_scan_count <= MAX_BL_SCAN
        for i, stage in enumerate(self.stages):
            if stage.bl_scan_count > HW_MAX_BL_SCAN:
                raise ValueError(
                    f"stage {i} bl_scan_count={stage.bl_scan_count} exceeds "
                    f"MAX_BL_SCAN={HW_MAX_BL_SCAN}"
                )
        # (5) RTL multilayer semantic (2B-serial as of 2026-04-19)
        # Stage 0 must use bit-plane (uint8 pixel input).
        # Stage N>0 can be either:
        #   - use_bitplane=True  → 2B-serial: uint8 spike_count input + bit-plane
        #   - use_bitplane=False → legacy binary spike mask (ablation only)
        if not self.stages[0].use_bitplane and self.input_encoding != "streamed_rate":
            # Only warn under legacy bitplane encoding. Under streamed_rate
            # use_bitplane=false is mandatory.
            logger.warning(
                "[topology %s] stage 0 use_bitplane=False with input_encoding="
                "'bitplane' is unusual. RTL convention: stage 0 expects uint8 "
                "pixel + bit-plane expansion.",
                self.name,
            )
        for i in range(1, len(self.stages)):
            if not self.stages[i].use_bitplane:
                logger.info(
                    "[topology %s] stage %d use_bitplane=False (legacy binary mask "
                    "mode, retained for ablation comparison vs 2B-serial).",
                    self.name, i,
                )
        # (6) V2.B REV 2: input_encoding='streamed_rate' requires all stages
        # to have use_bitplane=False (GPT fix #2). use_bitplane=True under
        # streamed_rate is a semantic conflict (would mix bit-plane event with
        # per-timestep stream).
        if self.input_encoding == "streamed_rate":
            if self.stream_timesteps < 2:
                raise ValueError(
                    f"[topology {self.name}] input_encoding='streamed_rate' "
                    f"requires stream_timesteps >= 2, got {self.stream_timesteps}"
                )
            for i, stage in enumerate(self.stages):
                if stage.use_bitplane:
                    raise ValueError(
                        f"[topology {self.name}] stage {i}: "
                        f"use_bitplane=True conflicts with input_encoding="
                        f"'streamed_rate'; set use_bitplane=False for all stages"
                    )
        return self


class GlobalConfig(BaseModel):
    """Global configuration (V1 frozen parameters)."""

    scheme: Literal["B"]
    adc_bits: int
    weight_bits: int
    reset_mode: Literal["soft", "hard"]
    preprocess: str


class V1BaselineConfig(BaseModel):
    """V1 frozen baseline reference (used only by A1.2 bit-parity check)."""

    python_dir: str
    weight_pos_hex: str
    weight_neg_hex: str
    alignment_manifest: str
    reported_full_test_accuracy: float
    alignment_subset_accuracy: float | None = None
    frozen_rtl_threshold: int


class TopologyFile(BaseModel):
    """Root schema for ``topologies.yaml``.

    The YAML uses ``global`` as a key, but ``global`` is a Python keyword,
    so we alias it to ``global_config`` via ``Field(alias="global")``.
    """

    schema_version: str
    global_config: GlobalConfig = Field(alias="global")
    v1_baseline: V1BaselineConfig
    topologies: list[TopologyConfig]

    model_config = {"populate_by_name": True}


def load_topology_file(path: Path | str = "topologies.yaml") -> TopologyFile:
    """Load the full ``topologies.yaml`` (all sections)."""
    path = Path(path)
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    return TopologyFile(**data)


def load_topologies(path: Path | str = "topologies.yaml") -> list[TopologyConfig]:
    """Convenience: load only the topology list (for legacy callers)."""
    return load_topology_file(path).topologies


def get_topology_by_name(
    topologies: list[TopologyConfig], name: str
) -> TopologyConfig:
    """Find a topology by name; raises KeyError if not found."""
    for topology in topologies:
        if topology.name == name:
            return topology
    raise KeyError(f"Topology {name!r} not found in list of {len(topologies)}")
