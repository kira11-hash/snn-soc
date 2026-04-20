"""Chunk-multiplex stream-boundary vs count-boundary ablation tests (A3 / D1).

REV 3.1 D1 principle: chunk boundary must preserve timestep-level
information (stream) to stay semantically identical to the unchunked
run. Count-boundary is the wrong design that destroys temporal
structure and degrades accuracy at depth.

These tests document the semantic with small synthetic topologies so
the contract is locked in for the paper's ablation table.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from snn_engine_multilayer import (  # noqa: E402
    _encode_counts_as_spike_stream,
    encode_pixel_to_spike_stream,
    run_streamed_rate_chunked,
    snn_inference_multilayer_sample,
)
from topologies import get_topology_by_name, load_topology_file

TOPO_YAML = ROOT / "topologies.yaml"


def _random_stage_weights(topology, seed: int = 0):
    rng = np.random.default_rng(seed)
    weights = []
    for stage in topology.stages:
        w_pos = rng.integers(0, 16, (stage.in_dim, stage.out_dim), dtype=np.int64)
        w_neg = rng.integers(0, 16, (stage.in_dim, stage.out_dim), dtype=np.int64)
        weights.append((w_pos, w_neg))
    return weights


def _random_pixel(topology, seed: int = 0):
    rng = np.random.default_rng(seed + 1000)
    return rng.integers(0, 256, topology.input_dim, dtype=np.int64)


# ──────────────────────────────────────────────────────────────
# Stream-boundary chunking is semantically transparent
# ──────────────────────────────────────────────────────────────

def test_stream_boundary_chunk_matches_unchunked():
    """Stream-boundary chunking must produce identical counts + stream per
    stage as the unchunked streamed_rate inference. REV 3.1 D1: chunk is
    just a firmware scheduling unit, not a semantic change."""
    topo_file = load_topology_file(TOPO_YAML)
    topo = get_topology_by_name(topo_file.topologies, "196_64_10")
    weights = _random_stage_weights(topo, seed=42)
    pixel = _random_pixel(topo, seed=42)

    # Unchunked (uses the same pipeline via _snn_inference_streamed_rate_sample)
    pred_ref, counts_ref, _memb_ref = snn_inference_multilayer_sample(
        pixel, topo, weights,
    )

    # Chunked with boundary=[1] → chunks are [stage 0] and [stage 1]
    pred_chunk, counts_chunk, _memb_chunk, _stream_chunk = run_streamed_rate_chunked(
        pixel, topo, weights,
        chunk_boundaries=[1], boundary_mode="stream",
    )

    assert pred_ref == pred_chunk
    for i, (c_ref, c_chunk) in enumerate(zip(counts_ref, counts_chunk)):
        assert np.array_equal(c_ref, c_chunk), (
            f"stage {i} counts differ (stream-boundary ≠ unchunked): "
            f"ref={c_ref.tolist()} chunk={c_chunk.tolist()}"
        )


def test_empty_chunks_equivalent_to_unchunked():
    """chunk_boundaries=None must behave identically to unchunked run."""
    topo_file = load_topology_file(TOPO_YAML)
    topo = get_topology_by_name(topo_file.topologies, "mnist_196_64_10")
    weights = _random_stage_weights(topo, seed=1)
    pixel = _random_pixel(topo, seed=1)

    pred_ref, counts_ref, _ = snn_inference_multilayer_sample(pixel, topo, weights)
    pred_chunk, counts_chunk, _, _ = run_streamed_rate_chunked(
        pixel, topo, weights, chunk_boundaries=None, boundary_mode="stream",
    )

    assert pred_ref == pred_chunk
    for c_ref, c_chunk in zip(counts_ref, counts_chunk):
        assert np.array_equal(c_ref, c_chunk)


# ──────────────────────────────────────────────────────────────
# Count-boundary is lossy — the whole ablation point
# ──────────────────────────────────────────────────────────────

def test_count_boundary_can_diverge_from_stream_boundary():
    """Count-boundary discards per-timestep firing order, so for at least
    one (pixel, weights) it must produce different per-stage counts than
    the stream-boundary baseline.

    This is the D1 ablation target: if count-boundary never differed,
    there'd be no motivation for the hardware stream buffer.
    """
    topo_file = load_topology_file(TOPO_YAML)
    topo = get_topology_by_name(topo_file.topologies, "196_64_10")

    diverged = False
    for seed in range(5):  # try a few seeds to surface divergence
        weights = _random_stage_weights(topo, seed=seed)
        pixel = _random_pixel(topo, seed=seed)

        _, counts_stream, _, _ = run_streamed_rate_chunked(
            pixel, topo, weights,
            chunk_boundaries=[1], boundary_mode="stream",
        )
        _, counts_count, _, _ = run_streamed_rate_chunked(
            pixel, topo, weights,
            chunk_boundaries=[1], boundary_mode="count",
        )
        if not np.array_equal(counts_stream[-1], counts_count[-1]):
            diverged = True
            break

    assert diverged, (
        "count-boundary must differ from stream-boundary on at least one "
        "random input; if they always match, the ablation shows no signal."
    )


def test_count_boundary_preserves_total_firings_per_neuron():
    """Sanity: _encode_counts_as_spike_stream round-trip — count stays
    preserved going stream→count→stream (up to T clamp)."""
    T = 64
    counts = np.array([0, 1, 5, 16, 32, 63, 64, 100], dtype=np.int64)
    stream = _encode_counts_as_spike_stream(counts, T)
    # Stream column sums == min(counts, T)
    expected = np.minimum(counts, T)
    got = stream.sum(axis=0)
    assert np.array_equal(got, expected), (
        f"Encoded stream counts mismatch: got={got.tolist()} "
        f"expected={expected.tolist()}"
    )


# ──────────────────────────────────────────────────────────────
# Invariant checks
# ──────────────────────────────────────────────────────────────

def test_invalid_boundary_mode_rejected():
    topo_file = load_topology_file(TOPO_YAML)
    topo = get_topology_by_name(topo_file.topologies, "196_64_10")
    weights = _random_stage_weights(topo, seed=0)
    pixel = _random_pixel(topo, seed=0)
    with pytest.raises(ValueError, match="boundary_mode"):
        run_streamed_rate_chunked(
            pixel, topo, weights,
            chunk_boundaries=[1], boundary_mode="count_bitplane",  # type: ignore[arg-type]
        )


def test_invalid_chunk_boundary_index_rejected():
    topo_file = load_topology_file(TOPO_YAML)
    topo = get_topology_by_name(topo_file.topologies, "196_64_10")  # 2 stages
    weights = _random_stage_weights(topo, seed=0)
    pixel = _random_pixel(topo, seed=0)
    # n_stages=2, so boundary must be 1; 0 and 2 are invalid
    for bad_b in [0, 2, 3]:
        with pytest.raises(ValueError, match="chunk_boundary"):
            run_streamed_rate_chunked(
                pixel, topo, weights,
                chunk_boundaries=[bad_b], boundary_mode="stream",
            )


def test_bitplane_topology_rejected():
    topo_file = load_topology_file(TOPO_YAML)
    topo = get_topology_by_name(topo_file.topologies, "64_32_10")  # legacy bitplane
    weights = _random_stage_weights(topo, seed=0)
    pixel = _random_pixel(topo, seed=0)
    with pytest.raises(ValueError, match="streamed_rate"):
        run_streamed_rate_chunked(
            pixel, topo, weights,
            chunk_boundaries=[1], boundary_mode="stream",
        )


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
