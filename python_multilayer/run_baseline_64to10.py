"""A1.2 — V1 baseline bit-parity validator.

Reproduces the exact predicted_class sequence that V1 wrote into
``expected_classes.hex`` (via ``rtl_snn_inference`` with absolute threshold
2550). Failing this means V2's RTL-like path is not bit-identical to V1 —
a blocker for everything downstream.

Usage:
    python run_baseline_64to10.py [--topologies path/to/topologies.yaml]

Exit codes:
    0  — 100/100 match, bit-identical to V1
    1  — One or more samples differ (parity violated)
    2  — Setup error (missing V1 files, schema mismatch, etc.)
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path
from typing import Any

import config_multilayer as cfg
from _vendored_from_v1.integer_reference import (
    NUM_INPUTS,
    load_weight_hex,
    rtl_snn_inference,
)
from topologies import load_topology_file

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("run_baseline")


def _resolve_v1_path(root: Path, relative: str) -> Path:
    """V1 paths in topologies.yaml are relative to the V1 ``python_dir``."""
    return (root / relative).resolve()


def _load_v1_alignment_manifest(v1_root: Path, manifest_rel: str) -> dict[str, Any]:
    manifest_path = _resolve_v1_path(v1_root, manifest_rel)
    if not manifest_path.exists():
        raise FileNotFoundError(
            f"V1 alignment manifest not found: {manifest_path}. "
            "Has V1 ``export_expected_spike_ids.py`` ever been run?"
        )
    return json.loads(manifest_path.read_text(encoding="utf-8"))


def _load_v1_hex_weights(v1_root: Path, pos_rel: str, neg_rel: str):
    """Load V1's pre-quantized 64×10 HEX weights."""
    pos_path = _resolve_v1_path(v1_root, pos_rel)
    neg_path = _resolve_v1_path(v1_root, neg_rel)
    if not pos_path.exists() or not neg_path.exists():
        raise FileNotFoundError(
            f"V1 HEX weights not found:\n  {pos_path}\n  {neg_path}\n"
            "Has V1 ``export_weight_map.py`` ever been run?"
        )
    w_pos = load_weight_hex(str(pos_path))
    w_neg = load_weight_hex(str(neg_path))
    return w_pos, w_neg


def _decode_sample_hex_to_pixel_vec(sample_hex: Path) -> list[int]:
    """Decode one frozen V1 sample hex file back to its 64 uint8 pixels.

    V1 `export_expected_spike_ids.py` wrote each sample as repeated frames of
    bit-plane WL vectors: first 8 non-empty lines are bit7..bit0 for frame 0,
    and bit position `row` maps to input row `row`. Reconstructing from this
    file avoids torchvision/preprocess drift and makes A1.2 check the exact
    frozen RTL stimulus used to create `expected_classes.hex`.
    """
    lines = [line.strip() for line in sample_hex.read_text().splitlines() if line.strip()]
    if len(lines) < 8:
        raise ValueError(f"{sample_hex} has {len(lines)} non-empty lines, expected >= 8")

    pixel_vec = [0] * NUM_INPUTS
    for bit_idx, line in enumerate(lines[:8]):
        bit = 7 - bit_idx
        wl_bits = int(line, 16)
        for row in range(NUM_INPUTS):
            if (wl_bits >> row) & 1:
                pixel_vec[row] |= 1 << bit
    return pixel_vec


def main(args: argparse.Namespace) -> int:
    # 1. Load topology file
    topo_file_path = Path(args.topologies).resolve()
    try:
        topo_file = load_topology_file(topo_file_path)
    except Exception as exc:
        logger.error("Failed to load topologies.yaml: %s", exc)
        return 2

    # 2. Find baseline topology
    try:
        baseline = next(
            t for t in topo_file.topologies if t.name == "64to10_baseline"
        )
    except StopIteration:
        logger.error("Topology 'baseline' (name=64to10_baseline) not found")
        return 2
    if baseline.role != "v1_frozen_baseline":
        logger.error(
            "Expected baseline role='v1_frozen_baseline', got %s", baseline.role
        )
        return 2

    v1_ref = topo_file.v1_baseline
    v1_root = (topo_file_path.parent / v1_ref.python_dir).resolve()
    logger.info("V1 root: %s", v1_root)

    # 3. Load V1 alignment manifest (threshold + 100 samples)
    try:
        manifest = _load_v1_alignment_manifest(v1_root, v1_ref.alignment_manifest)
    except FileNotFoundError as exc:
        logger.error("%s", exc)
        return 2

    rtl_threshold = int(manifest["threshold"])
    timesteps = int(manifest["timesteps"])
    v1_alignment_accuracy = float(manifest.get("accuracy", 0.0))

    logger.info(
        "V1 manifest: threshold=%d timesteps=%d sample_count=%d accuracy=%.4f",
        rtl_threshold, timesteps, manifest.get("sample_count"), v1_alignment_accuracy,
    )
    if rtl_threshold != v1_ref.frozen_rtl_threshold:
        logger.warning(
            "Manifest threshold=%d differs from topologies.yaml frozen_rtl_threshold=%d; "
            "using manifest value.",
            rtl_threshold, v1_ref.frozen_rtl_threshold,
        )

    # 4. Load V1 HEX weights (64×10 row-major int)
    try:
        w_pos, w_neg = _load_v1_hex_weights(
            v1_root, v1_ref.weight_pos_hex, v1_ref.weight_neg_hex
        )
    except FileNotFoundError as exc:
        logger.error("%s", exc)
        return 2
    logger.info("Loaded V1 HEX weights: %dx%d", len(w_pos), len(w_pos[0]))

    # 5. Run per-sample RTL-like inference against the frozen V1 stimulus.
    # Do not re-download/re-downsample MNIST here: torchvision/Pillow version
    # differences can alter a few avgpool pixels. The sample hex files are the
    # exact bit-plane stimulus that V1 used to generate the manifest.
    results: list[dict[str, Any]] = manifest["results"]
    if len(results) == 0:
        logger.error("V1 manifest has zero results")
        return 2
    stimulus_dir = _resolve_v1_path(v1_root, v1_ref.alignment_manifest).parent

    mismatches: list[dict[str, Any]] = []
    for entry in results:
        v1_predicted = int(entry["predicted_class"])
        sample_hex = stimulus_dir / str(entry["hex_file"])
        if not sample_hex.exists():
            logger.error("Frozen V1 sample hex not found: %s", sample_hex)
            return 2
        pixel_vec = _decode_sample_hex_to_pixel_vec(sample_hex)
        if len(pixel_vec) != NUM_INPUTS:
            logger.error(
                "Sample %s has %d pixels, expected %d",
                sample_hex, len(pixel_vec), NUM_INPUTS,
            )
            return 2

        _counts, v2_predicted, _membrane = rtl_snn_inference(
            pixel_vec=pixel_vec,
            w_pos=w_pos,
            w_neg=w_neg,
            timesteps=timesteps,
            threshold=rtl_threshold,
        )

        if v2_predicted != v1_predicted:
            mismatches.append({
                "slot": int(entry.get("slot", -1)),
                "dataset_index": int(entry.get("dataset_index", -1)),
                "true_label": int(entry.get("true_label", -1)),
                "v1_predicted": v1_predicted,
                "v2_predicted": v2_predicted,
            })

    total = len(results)
    matched = total - len(mismatches)

    if mismatches:
        logger.error(
            "[FAIL] %d/%d samples mismatched V1 expected_classes.hex",
            len(mismatches), total,
        )
        for m in mismatches[:5]:
            logger.error("  mismatch: %s", m)
        if len(mismatches) > 5:
            logger.error("  ... and %d more", len(mismatches) - 5)
        return 1

    logger.info("[PASS] %d/%d bit-identical to V1 frozen baseline", matched, total)
    logger.info(
        "V1 alignment subset accuracy: %.4f (100 samples, reported-only)",
        v1_alignment_accuracy,
    )
    logger.info(
        "V1 full-test historical accuracy: %.4f (see topologies.yaml v1_baseline)",
        v1_ref.reported_full_test_accuracy,
    )
    logger.info("Note: accuracy fields are for reporting, NOT the gate (gate = bit parity).")
    return 0


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="V1 baseline bit-parity validator")
    parser.add_argument(
        "--topologies",
        default=str(cfg.ROOT_DIR / "topologies.yaml"),
        help="Path to topologies.yaml (default: python_multilayer/topologies.yaml)",
    )
    return parser.parse_args()


if __name__ == "__main__":
    sys.exit(main(_parse_args()))
