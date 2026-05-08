"""
audit-v2/scripts/manifest_schema.py — M4 Golden Bundle Manifest schema (m4-3.1)

Canonical schema definition for the per-config YAML manifests under
`essay/manifests/`. Imported by `make_manifest.py` for both generation
and `--verify`.

Schema versioned `m4-3.1`:
  - m4-1.0  Round-1 (flat per-config block)
  - m4-2.0  Round-2 (per-artifact provenance + 3-tier schema)
  - m4-3.0  Round-3 (heterogeneous weight_hex.format enum)
  - m4-3.1  Round-4 (real export-manifest filenames + role-based H1
                     skip + correct LeNet-5 tile count)

Design source-of-truth: essay/m4_design_2026_05_07.md round 4.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Tuple

SCHEMA_VERSION = "m4-3.1"

# Evidence tiers (paper §3 Table-2)
TIER_BOARD = "board"
TIER_PATH_EQ = "path-equivalent"
TIER_SIM_ONLY = "sim-only"
ALLOWED_TIERS = (TIER_BOARD, TIER_PATH_EQ, TIER_SIM_ONLY)

# weight_hex.format enum (M4 round-3 §3 + round-4 R3-F1/F2 fixes)
WEIGHT_FORMAT_V1 = "v1-single-layer"
WEIGHT_FORMAT_FC = "fc-multi-layer"
WEIGHT_FORMAT_CONV = "conv-multi-tile"
ALLOWED_WEIGHT_FORMATS = (
    WEIGHT_FORMAT_V1,
    WEIGHT_FORMAT_FC,
    WEIGHT_FORMAT_CONV,
)

# Real export-manifest filename per format (round-4 R3-F1 fix; verified on disk).
# v1-single-layer has no manifest file; the HEX is its own ground truth.
EXPORT_MANIFEST_FILENAME = {
    WEIGHT_FORMAT_FC: "manifest.json",                # exporter_multilayer.py:279
    WEIGHT_FORMAT_CONV: "lenet5_golden_manifest.json",  # gen_convnet_golden.py
    WEIGHT_FORMAT_V1: None,
}

# H1 anchor commits per worktree (round-3 R2-F4 + round-4 R3-F5 split).
H1_ANCHORS = {
    "main": "31d2240f",
    "audit-v2": "5258a90f",
    "audit-v2-e203": "8f83b53b",
}

# M3 anchor commits — used when an artifact's role: starts with
# "backward-compat reference" (round-4 R3-F5 fix).
M3_ANCHORS = {
    "audit-v2": "5ef37855",
    "audit-v2-e203": "8747037e",
}

# Producer block: every hash-bearing artifact carries one of these.
PRODUCER_REQUIRED_KEYS = ("worktree", "head_sha")
PRODUCER_OPTIONAL_KEYS = (
    "branch",
    "build_log",
    "build_log_sha256",
    "build_script",
    "build_script_sha256",
    "build_variant",
    "training_script",
    "training_script_sha256",
    "training_run_log",
    "training_run_log_sha256",
    "head_sha_at_train",
    "head_sha_at_export",
    "head_sha_at_capture",
    "head_sha_at_run",
    "script",
    "script_sha256",
    "source_checkpoint",
    "source_checkpoint_sha256",
    "export_manifest",
    "h1_anchor_check",
    "m3_anchor_check",
    "skip_reason",
    "copied_to_main_at_closeout",
    "dataset_source",
    "split_seed",
    "firmware_function",
    "firmware_source",
    "firmware_source_sha256",
    "sim_script",
    "sim_script_sha256",
    "capture_script",
    "capture_script_sha256",
    "reason_diff_vs_reference",
)


@dataclass
class ConfigEntry:
    """One row of paper §3 Table-3 + tier label.

    The 6 canonical entries are listed in `CANONICAL_CONFIGS` below.
    """

    config_id: str
    number: int
    topology: str
    dataset: str
    input_shape: Tuple[int, int]
    layers: int
    layer_kind: str
    out_neurons: int
    adc_bits: int
    reported_accuracy: float
    reported_accuracy_source: str
    tier: str
    weight_format: str
    # path-eq tier: which board config is the reference
    inherits_from_id: str = ""
    inherits_from_number: int = 0


CANONICAL_CONFIGS: Tuple[ConfigEntry, ...] = (
    ConfigEntry(
        config_id="v1_fc_8x8_mnist",
        number=1,
        topology="FC SNN 64->10",
        dataset="MNIST",
        input_shape=(8, 8),
        layers=1,
        layer_kind="FC",
        out_neurons=10,
        adc_bits=8,
        reported_accuracy=86.74,
        reported_accuracy_source="paper §3 Table-3 row #1",
        tier=TIER_BOARD,
        weight_format=WEIGHT_FORMAT_V1,
    ),
    ConfigEntry(
        config_id="v2b_fc_fashion14_2L",
        number=2,
        topology="FC SNN 196->64->10",
        dataset="Fashion-MNIST",
        input_shape=(14, 14),
        layers=2,
        layer_kind="FC",
        out_neurons=64,
        adc_bits=10,
        reported_accuracy=82.38,
        reported_accuracy_source="paper §3 Table-3 row #2",
        tier=TIER_BOARD,
        weight_format=WEIGHT_FORMAT_FC,
    ),
    ConfigEntry(
        config_id="v2b_fc_mnist14_2L",
        number=3,
        topology="FC SNN 196->64->10",
        dataset="MNIST",
        input_shape=(14, 14),
        layers=2,
        layer_kind="FC",
        out_neurons=64,
        adc_bits=10,
        reported_accuracy=96.48,
        reported_accuracy_source="paper §3 Table-3 row #3",
        tier=TIER_PATH_EQ,
        weight_format=WEIGHT_FORMAT_FC,
        inherits_from_id="v2b_fc_fashion14_2L",
        inherits_from_number=2,
    ),
    ConfigEntry(
        config_id="v2b_lenet5_mnist_28x28",
        number=4,
        topology="LeNet-5 (2C+3F)",
        dataset="MNIST",
        input_shape=(28, 28),
        layers=5,
        layer_kind="FC+CONV",
        out_neurons=10,
        adc_bits=8,
        reported_accuracy=93.03,
        reported_accuracy_source="paper §3 Table-3 row #4",
        tier=TIER_BOARD,
        weight_format=WEIGHT_FORMAT_CONV,
    ),
    ConfigEntry(
        config_id="v2b_fc_fashion28_2L",
        number=5,
        topology="FC SNN 784->64->10",
        dataset="Fashion-MNIST",
        input_shape=(28, 28),
        layers=2,
        layer_kind="FC",
        out_neurons=64,
        adc_bits=10,
        reported_accuracy=84.05,
        reported_accuracy_source="paper §3 Table-3 row #5",
        tier=TIER_SIM_ONLY,
        weight_format=WEIGHT_FORMAT_FC,
    ),
    ConfigEntry(
        config_id="v2b_lenet5_fashion_28x28",
        number=6,
        topology="LeNet-5 (2C+3F)",
        dataset="Fashion-MNIST",
        input_shape=(28, 28),
        layers=5,
        layer_kind="FC+CONV",
        out_neurons=10,
        adc_bits=8,
        reported_accuracy=81.99,
        reported_accuracy_source="paper §3 Table-3 row #6",
        tier=TIER_PATH_EQ,
        weight_format=WEIGHT_FORMAT_CONV,
        inherits_from_id="v2b_lenet5_mnist_28x28",
        inherits_from_number=4,
    ),
)

CANONICAL_CONFIG_BY_ID = {c.config_id: c for c in CANONICAL_CONFIGS}
CANONICAL_CONFIG_BY_NUMBER = {c.number: c for c in CANONICAL_CONFIGS}


# Required top-level fields per tier (round-3 §3.1-§3.4 + round-4 fixes).
COMMON_REQUIRED_FIELDS = (
    "schema_version",
    "config",
    "evidence_tier",
    "generator",
    "artifacts",
)

BOARD_REQUIRED_ARTIFACTS = (
    "bitstream_arm",
    "bitstream_e203",
    "firmware_arm_elf",
    "firmware_e203_elf",
    "weight_hex",
    "model_checkpoint",
    "topologies_yaml",
    "input_fmap_dataset",
    "python_integer_reference_golden",
    "runtime_csr_dump",
    "trace_hash_logs",
)

PATH_EQ_REQUIRED_FIELDS = (
    "inherits_from",
    "inherited_fields",
    "config_specific_artifacts",
)

PATH_EQ_REQUIRED_CONFIG_SPECIFIC = (
    "weight_hex",
    "input_fmap_dataset",
    "python_integer_reference_golden",
    "model_checkpoint",        # round-3 R2-F2 fix
    "topologies_yaml",         # round-3 R2-F2 fix
    "cosim_byte_match_certificate",
)

SIM_ONLY_REQUIRED_FIELDS = (
    "topologies_yaml",
    "model_checkpoint",
    "python_engine",
    "weight_hex",
    "input_fmap_dataset",
    "python_integer_reference_golden",
    "rng_seeds",
    "paper_disclosure",
)


@dataclass
class ValidationResult:
    """Outcome of `validate_manifest(...)`. Empty `errors` list = PASS."""

    config_id: str = ""
    errors: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)

    def ok(self) -> bool:
        return not self.errors


def validate_manifest(manifest: dict) -> ValidationResult:
    """Validate one parsed manifest dict against schema m4-3.1.

    Returns ValidationResult; caller checks `.ok()` and reads
    `.errors` / `.warnings` for reporting.
    """

    result = ValidationResult()

    # 1) schema_version
    sv = manifest.get("schema_version")
    if sv != SCHEMA_VERSION:
        result.errors.append(
            f"schema_version expected '{SCHEMA_VERSION}', got '{sv}'"
        )

    # 2) config block
    cfg = manifest.get("config", {})
    if not isinstance(cfg, dict):
        result.errors.append("config: expected dict")
        return result

    cfg_id = cfg.get("id", "")
    result.config_id = cfg_id
    if cfg_id not in CANONICAL_CONFIG_BY_ID:
        result.errors.append(
            f"config.id '{cfg_id}' not in canonical 6-config list"
        )
        return result

    canonical = CANONICAL_CONFIG_BY_ID[cfg_id]
    for field_name, expected in (
        ("number", canonical.number),
        ("topology", canonical.topology),
        ("dataset", canonical.dataset),
        ("input_shape", list(canonical.input_shape)),
        ("layers", canonical.layers),
        ("layer_kind", canonical.layer_kind),
        ("out_neurons", canonical.out_neurons),
        ("adc_bits", canonical.adc_bits),
        ("reported_accuracy", canonical.reported_accuracy),
    ):
        actual = cfg.get(field_name)
        if actual != expected:
            result.errors.append(
                f"config.{field_name}: expected {expected!r}, got {actual!r}"
            )

    # 3) evidence_tier
    tier = manifest.get("evidence_tier")
    if tier != canonical.tier:
        result.errors.append(
            f"evidence_tier '{tier}' != canonical '{canonical.tier}' for {cfg_id}"
        )

    # 4) generator block
    gen = manifest.get("generator", {})
    for k in ("utc_frozen", "by", "schema"):
        if k not in gen:
            result.errors.append(f"generator.{k} missing")
    if gen.get("schema") != SCHEMA_VERSION:
        result.errors.append(
            f"generator.schema mismatch (manifest claims '{gen.get('schema')}',"
            f" want '{SCHEMA_VERSION}')"
        )

    # 5) per-tier required fields
    if tier == TIER_BOARD:
        artifacts = manifest.get("artifacts", {})
        if not isinstance(artifacts, dict):
            result.errors.append("artifacts: expected dict for board tier")
        else:
            for art in BOARD_REQUIRED_ARTIFACTS:
                if art not in artifacts:
                    result.errors.append(f"artifacts.{art}: missing (board tier)")
    elif tier == TIER_PATH_EQ:
        for f in PATH_EQ_REQUIRED_FIELDS:
            if f not in manifest:
                result.errors.append(f"{f}: missing (path-eq tier)")
        cs = manifest.get("config_specific_artifacts", {})
        if isinstance(cs, dict):
            for art in PATH_EQ_REQUIRED_CONFIG_SPECIFIC:
                if art not in cs:
                    result.errors.append(
                        f"config_specific_artifacts.{art}: missing (path-eq tier)"
                    )
    elif tier == TIER_SIM_ONLY:
        sim = manifest.get("sim_only", {})
        if not isinstance(sim, dict):
            result.errors.append("sim_only: expected dict for sim-only tier")
        else:
            for f in SIM_ONLY_REQUIRED_FIELDS:
                if f not in sim:
                    result.errors.append(f"sim_only.{f}: missing (sim-only tier)")

    # 6) weight_hex.format enum check (where weight_hex is present)
    def check_weight_format(node: dict, path_prefix: str) -> None:
        wh = node.get("weight_hex")
        if not isinstance(wh, dict):
            return
        fmt = wh.get("format")
        if fmt not in ALLOWED_WEIGHT_FORMATS:
            result.errors.append(
                f"{path_prefix}.weight_hex.format '{fmt}' not in "
                f"{ALLOWED_WEIGHT_FORMATS}"
            )
        if fmt != canonical.weight_format:
            result.errors.append(
                f"{path_prefix}.weight_hex.format '{fmt}' != canonical "
                f"'{canonical.weight_format}' for {cfg_id}"
            )

    if tier == TIER_BOARD:
        check_weight_format(manifest.get("artifacts", {}), "artifacts")
    elif tier == TIER_PATH_EQ:
        check_weight_format(
            manifest.get("config_specific_artifacts", {}),
            "config_specific_artifacts",
        )
    elif tier == TIER_SIM_ONLY:
        check_weight_format(manifest.get("sim_only", {}), "sim_only")

    # 7) m2_envelope_refs (round-3 R2-F5 + round-4): optional from day one;
    #    if present, must be boolean `applicable: true|false` (no <unknown>).
    m2refs = manifest.get("m2_envelope_refs")
    if m2refs is not None:
        if not isinstance(m2refs, dict):
            result.errors.append("m2_envelope_refs: expected dict if present")
        else:
            applicable = m2refs.get("applicable")
            if applicable not in (True, False):
                result.errors.append(
                    f"m2_envelope_refs.applicable: expected boolean, "
                    f"got {applicable!r} (no <unknown> third state)"
                )

    return result


def list_required_artifacts_for_tier(tier: str) -> Tuple[str, ...]:
    """Return the artifact-key tuple required for a given tier."""
    if tier == TIER_BOARD:
        return BOARD_REQUIRED_ARTIFACTS
    if tier == TIER_PATH_EQ:
        return PATH_EQ_REQUIRED_CONFIG_SPECIFIC
    if tier == TIER_SIM_ONLY:
        return SIM_ONLY_REQUIRED_FIELDS
    raise ValueError(f"unknown tier: {tier!r}")
