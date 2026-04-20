"""RTL-like multilayer SNN reference (Phase V2.A / A2.5 / 2B-serial).

Canonical reference for checking RTL bit-parity (A6.a). Does NOT use
floating-point ReLU activations.

2B-serial semantics (upgraded from 2026-04-19):

    stage 0:
        input  = uint8 pixel vector (length = input_dim)
        expand = 8 bit-planes (MSB→LSB), timesteps outer loop
        membrane accumulation: membrane += diff * (1 << bit)
        LIF threshold + soft reset per sub-step
        output = uint8 spike_count per neuron (saturated to [0, 255])

    stage N>0 (when ``use_bitplane=True``):
        input  = uint8 spike_count from previous stage
        expand = 8 bit-planes (MSB→LSB), same as stage 0
        MAC / LIF / accumulation symmetric with stage 0
        output = uint8 spike_count per neuron

    stage N>0 legacy binary mode (``use_bitplane=False``, retained for ablation):
        input  = binary spike mask (0/1)
        NO bit-plane expansion, typically timesteps=1
        kept to demonstrate the information bottleneck in the paper

RTL mapping (2B-serial, bit-serial replay):
    - spike_feedback latches uint8 spike_count[MAX_NEURONS][7:0] internally
    - Each bit-plane sub-step replays count_latched[i][bitplane_shift] as WL bitmap
    - External feedback_wl_data remains 128-bit, no wide bus needed

Integer ADC scale = ``(raw_sum * 255 + 960//2) // 960`` with clamp to [0, 255].
"""

from __future__ import annotations

import logging
from typing import Sequence

import numpy as np

from _vendored_from_v1.integer_reference import (
    ADC_MAX,
    SUM_MAX,
    rtl_adc_scale,
)
from adc_scale_v2 import rtl_adc_scale_v2
from topologies import StageConfig, TopologyConfig

logger = logging.getLogger(__name__)


def _cim_mac_scheme_b_integer(
    wl_spike: np.ndarray,       # int vector, shape [in_dim], values 0/1
    w_pos: np.ndarray,          # int matrix, shape [in_dim, out_dim]
    w_neg: np.ndarray,
) -> np.ndarray:
    """Scheme-B differential MAC + V1 integer ADC (SUM_MAX=960 frozen).

    Used only by legacy count-bitplane (V1 / 8×8) path. V2 streamed rate uses
    ``_cim_mac_scheme_b_v2`` with parameterized sum_max/adc_bits.
    """
    pos_sum = (wl_spike @ w_pos).astype(np.int64)
    neg_sum = (wl_spike @ w_neg).astype(np.int64)
    adc_pos = np.array([rtl_adc_scale(int(v)) for v in pos_sum], dtype=np.int64)
    adc_neg = np.array([rtl_adc_scale(int(v)) for v in neg_sum], dtype=np.int64)
    return adc_pos - adc_neg


def _cim_mac_scheme_b_v2(
    wl_spike: np.ndarray,       # int vector [in_dim] 0/1
    w_pos: np.ndarray,          # int matrix [in_dim, out_dim] level 0..15
    w_neg: np.ndarray,
    sum_max: int,
    adc_bits: int = 8,
) -> np.ndarray:
    """V2 Scheme-B differential MAC + parameterized ADC for streamed rate.

    Uses ``rtl_adc_scale_v2(sum_max=sum_max, adc_bits=adc_bits)`` so per-stage
    ``active_wl`` or ``array`` full-scale policy can be honored, and ADC can
    go 10/12-bit without changing V1 vendored code.
    """
    pos_sum = (wl_spike @ w_pos).astype(np.int64)
    neg_sum = (wl_spike @ w_neg).astype(np.int64)
    adc_pos = np.array(
        [rtl_adc_scale_v2(int(v), sum_max=sum_max, adc_bits=adc_bits) for v in pos_sum],
        dtype=np.int64,
    )
    adc_neg = np.array(
        [rtl_adc_scale_v2(int(v), sum_max=sum_max, adc_bits=adc_bits) for v in neg_sum],
        dtype=np.int64,
    )
    return adc_pos - adc_neg


SPIKE_COUNT_MAX = 255  # uint8 saturation for legacy count feedback


# ───── V2 streamed-rate helpers (GPT 2026-04-20 REV 2) ─────

def encode_pixel_to_spike_stream(
    pixel_vec: np.ndarray,             # uint8 [in_dim] values 0-255
    T: int,
    method: str = "even_rate",
) -> np.ndarray:
    """Encode uint8 pixel to a ``[T, in_dim]`` binary spike stream.

    Total spikes per pixel (REV 2 G2 definition — must match torch version)::

        total_spikes(pixel, T) == pixel * T // 256

    Default ``even_rate`` uses a Bresenham-style accumulator so spikes are
    uniformly distributed across the time axis (avoids prefix-rate bias that
    dumps all spikes into early timesteps and skews membrane accumulation).

    Args:
        pixel_vec: Length-``in_dim`` uint8/int array with values in ``[0, 255]``.
        T: Stream length.
        method: ``'even_rate'`` (default) / ``'prefix_rate'`` (ablation only).

    Returns:
        ``[T, in_dim]`` int64 array with 0/1 entries.
    """
    pix = np.asarray(pixel_vec, dtype=np.int64).reshape(-1)
    if pix.min() < 0 or pix.max() > 255:
        raise ValueError(
            f"pixel_vec must be in [0, 255]; got min={pix.min()} max={pix.max()}"
        )
    in_dim = pix.shape[0]
    out = np.zeros((T, in_dim), dtype=np.int64)

    if method == "even_rate":
        # Bresenham accumulator. For each neuron i, acc += pixel[i] each timestep;
        # when acc >= 256, emit a spike and subtract 256. This guarantees
        # total_spikes == pixel * T // 256 and spikes are evenly distributed.
        acc = np.zeros(in_dim, dtype=np.int64)
        for t in range(T):
            acc = acc + pix
            fired = acc >= 256
            out[t, fired] = 1
            acc[fired] -= 256
        return out

    if method == "prefix_rate":
        # Ablation only: first pixel*T//256 timesteps fire, rest silent.
        k = pix * T // 256
        for i in range(in_dim):
            out[: int(k[i]), i] = 1
        return out

    raise ValueError(f"Unknown encoding method: {method!r}")


def _run_stage_streamed_rate(
    stage: StageConfig,
    wl_stream: np.ndarray,             # [T, in_dim] int {0, 1}
    w_pos: np.ndarray,                 # [in_dim, out_dim] level 0..15
    w_neg: np.ndarray,
    sum_max: int,
    adc_bits: int = 8,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """V2 streamed-rate stage forward (true BSRC semantics).

    For each of T timesteps:
      - 1 MAC with binary WL mask (no bit-plane decomposition)
      - Scheme-B diff through per-stage parameterized ADC
      - Membrane accumulation (no reset between timesteps within the stage)
      - LIF fire (soft reset subtracts ``stage.threshold``)
      - Record spike to stream[t]

    Returns:
        ``(spike_counts [out_dim], membrane [out_dim], spike_stream [T, out_dim])``
        ``spike_counts[i]`` = total fires for neuron i. Stage N>0 feeds
        ``spike_stream`` (not ``spike_counts``) to the next stage.
    """
    T, in_dim = wl_stream.shape
    out_dim = stage.out_dim
    if in_dim != stage.in_dim:
        raise ValueError(
            f"wl_stream in_dim={in_dim} != stage.in_dim={stage.in_dim}"
        )
    membrane = np.zeros(out_dim, dtype=np.int64)
    spike_counts = np.zeros(out_dim, dtype=np.int64)
    spike_stream_out = np.zeros((T, out_dim), dtype=np.int64)

    for t in range(T):
        wl = wl_stream[t].astype(np.int64)
        diff = _cim_mac_scheme_b_v2(wl, w_pos, w_neg, sum_max=sum_max, adc_bits=adc_bits)
        membrane += diff
        fired = membrane >= stage.threshold
        spike_stream_out[t, fired] = 1
        spike_counts += fired.astype(np.int64)
        membrane[fired] -= stage.threshold

    return spike_counts, membrane, spike_stream_out


def _run_stage_streamed_rate_tiled(
    stage: StageConfig,
    wl_stream_tiles: list[np.ndarray],   # N_tiles × [T, tile_in_dim] int {0,1}
    w_pos_tiles: list[np.ndarray],       # N_tiles × [tile_in_dim, out_dim]
    w_neg_tiles: list[np.ndarray],
    sum_max_per_tile: list[int],         # len == N_tiles
    adc_bits: int = 8,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """REV 3.1 D1 + D7: tile-correct partial-sum streamed stage forward.

    Implements the **correct** spatial tile multiplex semantics for >256-WL
    stages (e.g. 28×28 pixel input needing 4 tiles of 196). For each timestep
    ``t`` we accumulate **per-tile ADC-quantised** partial diffs into
    ``partial_diff_buffer[t][j]`` across all tiles, THEN run a single LIF per
    timestep in timestep order.

    Critical correctness points:
      * D1: accumulator is ``[T × out_dim]`` (**not** ``[out_dim]``). Otherwise
        the tile loop mixes different timesteps' partials, destroying the
        rate-coded temporal information.
      * D7: per-tile ADC precedes cross-tile accumulation. The naive golden
        ``adc(sum(raw_over_tiles))`` is NOT bit-identical to RTL which does
        ``sum(adc(raw_per_tile))``. Paper's bit-exact claim depends on this.
      * Each tile's ``sum_max`` may differ (last tile often has fewer active
        WL rows). Use per-tile ``sum_max_per_tile[tile]``.

    Equivalent to :func:`_run_stage_streamed_rate` when ``N_tiles == 1``.

    Args:
      stage:             StageConfig. Uses ``stage.stream_timesteps`` is absent;
                         falls back to ``wl_stream_tiles[0].shape[0]`` for T.
      wl_stream_tiles:   list of N_tiles arrays, each ``[T, tile_in_dim]`` 0/1.
                         ``sum(tile_in_dim) == stage.in_dim``; tiles may be
                         unequal (last smaller).
      w_pos_tiles:       list of N_tiles ``[tile_in_dim, stage.out_dim]`` level
                         matrices (uint 0..15 typically).
      w_neg_tiles:       same shape as ``w_pos_tiles``.
      sum_max_per_tile:  per-tile ADC full-scale (= tile_in_dim × 15 for
                         active_wl, or HW_NUM_INPUTS × 15 for array mode).
      adc_bits:          ADC bit width (8 / 10 / 12).

    Returns:
      ``(spike_counts [out_dim], membrane [out_dim], spike_stream [T, out_dim])``
    """
    n_tiles = len(wl_stream_tiles)
    if not (len(w_pos_tiles) == len(w_neg_tiles) == len(sum_max_per_tile) == n_tiles):
        raise ValueError(
            f"Tile count mismatch: wl_stream_tiles={n_tiles}, "
            f"w_pos_tiles={len(w_pos_tiles)}, w_neg_tiles={len(w_neg_tiles)}, "
            f"sum_max_per_tile={len(sum_max_per_tile)}"
        )
    if n_tiles == 0:
        raise ValueError("wl_stream_tiles must have at least one tile")

    T = int(wl_stream_tiles[0].shape[0])
    out_dim = stage.out_dim
    total_in_dim = 0
    for i, wl_tile in enumerate(wl_stream_tiles):
        if wl_tile.shape[0] != T:
            raise ValueError(
                f"Tile {i} T={wl_tile.shape[0]} inconsistent with tile 0 T={T}"
            )
        tile_in_dim = wl_tile.shape[1]
        if w_pos_tiles[i].shape != (tile_in_dim, out_dim):
            raise ValueError(
                f"Tile {i} w_pos shape {w_pos_tiles[i].shape} != "
                f"({tile_in_dim}, {out_dim})"
            )
        if w_neg_tiles[i].shape != (tile_in_dim, out_dim):
            raise ValueError(
                f"Tile {i} w_neg shape {w_neg_tiles[i].shape} != "
                f"({tile_in_dim}, {out_dim})"
            )
        total_in_dim += tile_in_dim
    if total_in_dim != stage.in_dim:
        raise ValueError(
            f"Sum of tile in_dim = {total_in_dim} != stage.in_dim = {stage.in_dim}"
        )

    # D1: [T, out_dim] accumulator. Must span timesteps, NOT be per-tile.
    partial_diff_buffer = np.zeros((T, out_dim), dtype=np.int64)

    for tile in range(n_tiles):
        wl_stream_tile = wl_stream_tiles[tile].astype(np.int64)
        wp_tile = w_pos_tiles[tile]
        wn_tile = w_neg_tiles[tile]
        s_max = int(sum_max_per_tile[tile])
        for t in range(T):
            wl = wl_stream_tile[t]
            # D7: per-tile ADC, THEN accumulate into shared buffer.
            diff = _cim_mac_scheme_b_v2(
                wl, wp_tile, wn_tile,
                sum_max=s_max, adc_bits=adc_bits,
            )
            partial_diff_buffer[t] += diff

    # After all tiles done: single LIF sweep over timesteps, preserving
    # the true BSRC temporal semantics.
    membrane = np.zeros(out_dim, dtype=np.int64)
    spike_counts = np.zeros(out_dim, dtype=np.int64)
    spike_stream_out = np.zeros((T, out_dim), dtype=np.int64)
    for t in range(T):
        membrane += partial_diff_buffer[t]
        fired = membrane >= stage.threshold
        spike_stream_out[t, fired] = 1
        spike_counts += fired.astype(np.int64)
        membrane[fired] -= stage.threshold

    return spike_counts, membrane, spike_stream_out


def _run_stage_bitplane(
    stage: StageConfig,
    pixel_vec: np.ndarray,             # uint8 shape [in_dim], values 0-255
    w_pos: np.ndarray,
    w_neg: np.ndarray,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Run a bit-plane stage (stage 0, or stage N>0 in 2B-serial mode).

    The input is interpreted as uint8 per WL (0-255). Each sub-step extracts
    one bit of the input and MACs it. Used for stage 0 (pixel input) and
    stage N>0 when use_bitplane=True (uint8 spike_count input from previous
    stage).

    Returns ``(spike_counts, membrane, spike_mask)``.

    spike_mask is the OR of all sub-step fires within the layer, matching the
    RTL `spike_feedback.sv` semantic after the 2026-04-19 fix (bug FP-009):
    `spike_feedback` OR-accumulates `spike_mask` across every
    `spike_mask_valid` pulse within a layer, then clears on `feedback_en`.
    Previously it latched only the last, which for MNIST-like sparse inputs
    with bit 0 contribution ×1 was almost always all-zero.

    Numerically equivalent to ``(spike_counts > 0)`` because every individual
    `fired` mask is OR'd into `spike_mask` and `spike_counts` increments only
    when fired=1.
    """
    out_dim = stage.out_dim
    membrane = np.zeros(out_dim, dtype=np.int64)
    spike_counts = np.zeros(out_dim, dtype=np.int64)
    spike_mask = np.zeros(out_dim, dtype=np.int64)

    wl_in = np.clip(pixel_vec, 0, SPIKE_COUNT_MAX).astype(np.int64)

    # Refractory spike cap per frame (matches trainer's RTL_REFRACTORY_K).
    # RTL must implement an equivalent per-neuron per-frame counter when
    # this is non-None. None = classic LIF with no refractory.
    import config_multilayer as _cfg
    refractory_k = getattr(_cfg, "RTL_REFRACTORY_K", None)

    for _frame in range(stage.timesteps):
        frame_fire = np.zeros(out_dim, dtype=np.int64) if refractory_k is not None else None
        for bit in range(7, -1, -1):
            wl_spike = ((wl_in >> bit) & 1).astype(np.int64)
            diff = _cim_mac_scheme_b_integer(wl_spike, w_pos, w_neg)
            membrane += diff * (1 << bit)
            fired = (membrane >= stage.threshold)
            if refractory_k is not None:
                fired = fired & (frame_fire < int(refractory_k))
                frame_fire += fired.astype(np.int64)
            fired_i = fired.astype(np.int64)
            spike_mask = spike_mask | fired_i
            spike_counts += fired_i
            membrane[fired] -= stage.threshold

    return spike_counts, membrane, spike_mask


def _run_stage_binary(
    stage: StageConfig,
    spike_mask_in: np.ndarray,         # binary int shape [in_dim]
    w_pos: np.ndarray,
    w_neg: np.ndarray,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Run a subsequent stage (no bit-plane expansion).

    ``timesteps`` defaults to 1 for binary stages; if > 1 the same spike_mask
    is replayed each timestep (RTL would likely skip this but we model it
    faithfully via the yaml-supplied value).
    """
    out_dim = stage.out_dim
    membrane = np.zeros(out_dim, dtype=np.int64)
    spike_counts = np.zeros(out_dim, dtype=np.int64)
    spike_mask = np.zeros(out_dim, dtype=np.int64)

    for _frame in range(stage.timesteps):
        diff = _cim_mac_scheme_b_integer(spike_mask_in, w_pos, w_neg)
        membrane += diff
        fired = membrane >= stage.threshold
        spike_mask = spike_mask | fired.astype(np.int64)  # OR accumulate, matching RTL post-fix
        spike_counts += fired.astype(np.int64)
        membrane[fired] -= stage.threshold

    return spike_counts, membrane, spike_mask


def snn_inference_multilayer_sample(
    pixel_vec: np.ndarray,                    # uint8 shape [input_dim]
    topology: TopologyConfig,
    stage_weights: Sequence[tuple[np.ndarray, np.ndarray]],  # [(w_pos, w_neg), ...]
) -> tuple[int, list[np.ndarray], list[np.ndarray]]:
    """Run RTL-like multilayer inference on one sample.

    Args:
        pixel_vec:     ``[input_dim]`` uint8 pixel vector.
        topology:      Topology configuration.
        stage_weights: Per-stage tuple ``(w_pos, w_neg)`` of int matrices.

    Returns:
        ``(predicted_class, per_stage_spike_counts, per_stage_membrane)``.
    """
    if len(stage_weights) != topology.num_fc_stages:
        raise ValueError(
            f"Expected {topology.num_fc_stages} weight pairs, got {len(stage_weights)}"
        )

    # V2.B REV 2: dispatch by top-level input_encoding.
    if topology.input_encoding == "streamed_rate":
        return _snn_inference_streamed_rate_sample(pixel_vec, topology, stage_weights)

    # Legacy 'bitplane' path (V2.A count-bitplane + V1 8×8 baseline).
    per_stage_counts: list[np.ndarray] = []
    per_stage_membrane: list[np.ndarray] = []
    prev_counts: np.ndarray | None = None
    prev_mask: np.ndarray | None = None

    for i, (stage, (w_pos, w_neg)) in enumerate(zip(topology.stages, stage_weights)):
        if w_pos.shape != (stage.in_dim, stage.out_dim):
            raise ValueError(
                f"Stage {i} w_pos shape {w_pos.shape} != expected "
                f"({stage.in_dim}, {stage.out_dim})"
            )
        if w_neg.shape != (stage.in_dim, stage.out_dim):
            raise ValueError(
                f"Stage {i} w_neg shape {w_neg.shape} != expected "
                f"({stage.in_dim}, {stage.out_dim})"
            )

        if i == 0:
            if not stage.use_bitplane:
                raise ValueError(
                    f"Stage 0 of topology {topology.name!r} has use_bitplane=False "
                    "under input_encoding='bitplane'. For streamed rate use "
                    "input_encoding='streamed_rate'."
                )
            counts, membrane, mask = _run_stage_bitplane(stage, pixel_vec, w_pos, w_neg)
        else:
            if stage.use_bitplane:
                assert prev_counts is not None, "unreachable"
                counts, membrane, mask = _run_stage_bitplane(
                    stage, prev_counts, w_pos, w_neg
                )
            else:
                assert prev_mask is not None, "unreachable"
                counts, membrane, mask = _run_stage_binary(
                    stage, prev_mask, w_pos, w_neg
                )

        per_stage_counts.append(counts)
        per_stage_membrane.append(membrane)
        prev_counts = np.clip(counts, 0, SPIKE_COUNT_MAX).astype(np.int64)
        prev_mask = mask

    final_counts = per_stage_counts[-1]
    predicted_class = int(np.argmax(final_counts))
    return predicted_class, per_stage_counts, per_stage_membrane


def _snn_inference_streamed_rate_sample(
    pixel_vec: np.ndarray,
    topology: TopologyConfig,
    stage_weights: Sequence[tuple[np.ndarray, np.ndarray]],
) -> tuple[int, list[np.ndarray], list[np.ndarray]]:
    """V2.B REV 2 streamed rate dispatch for one sample.

    Pipeline:
      1. Encode pixel → T × in_dim binary stream (even_rate accumulator)
      2. Stage 0: streamed forward → T × out_dim spike stream
      3. Stage N>0: consume prev spike stream, streamed forward
      4. Argmax over final stage spike_counts

    All stages share the topology's ``stream_timesteps`` T, ``adc_bits``, and
    ``adc_full_scale`` policy for per-layer ``sum_max``.
    """
    T = topology.stream_timesteps
    adc_bits = topology.adc_bits
    full_scale = topology.adc_full_scale
    array_rows = 256  # V2.B fixed; read from cfg if needed

    per_stage_counts: list[np.ndarray] = []
    per_stage_membrane: list[np.ndarray] = []

    # Stage 0 input: encode pixel to spike stream.
    wl_stream = encode_pixel_to_spike_stream(pixel_vec, T, method="even_rate")

    for i, (stage, (w_pos, w_neg)) in enumerate(zip(topology.stages, stage_weights)):
        if w_pos.shape != (stage.in_dim, stage.out_dim):
            raise ValueError(
                f"Stage {i} w_pos shape {w_pos.shape} != expected "
                f"({stage.in_dim}, {stage.out_dim})"
            )
        # Resolve sum_max for this stage
        if stage.sum_max is not None:
            sum_max = stage.sum_max
        elif full_scale == "active_wl":
            sum_max = stage.in_dim * 15
        else:
            sum_max = array_rows * 15

        counts, membrane, stream = _run_stage_streamed_rate(
            stage, wl_stream, w_pos, w_neg, sum_max=sum_max, adc_bits=adc_bits,
        )
        per_stage_counts.append(counts)
        per_stage_membrane.append(membrane)
        wl_stream = stream  # feed next stage

    final_counts = per_stage_counts[-1]
    predicted_class = int(np.argmax(final_counts))
    return predicted_class, per_stage_counts, per_stage_membrane


# ──────────────────────────────────────────────────────────────────────
# REV 3.1 D1 / A3 — chunk multiplex with stream-boundary vs count-boundary
# ──────────────────────────────────────────────────────────────────────

def _encode_counts_as_spike_stream(
    counts: np.ndarray, T: int,
) -> np.ndarray:
    """Map per-neuron counts back to a [T, N] spike stream via even_rate
    Bresenham.

    Used ONLY by count-boundary ablation (REV 3.1 D1 "what-if"): compresses
    a full [T, N] stream down to [N] count and re-generates a stream shape
    from it. The re-generated stream has the correct total count per
    neuron but loses the original firing *order* across timesteps, which
    is what stream-boundary preserves.

    Args:
      counts: non-negative int array of shape ``[N]``. Values must be in
              ``[0, T]`` (clamped to ``T`` automatically; extra fire events
              past ``T`` cannot be re-expressed as binary mask per step).
      T:      target stream length.

    Returns:
      ``[T, N]`` int64 binary spike stream. Each column has
      ``min(counts[i], T)`` spikes spread evenly across time.
    """
    counts_int = np.asarray(counts, dtype=np.int64).reshape(-1)
    counts_clipped = np.clip(counts_int, 0, T)
    N = counts_clipped.shape[0]
    out = np.zeros((T, N), dtype=np.int64)
    # Accumulator: acc += counts each step; fire when acc >= T.
    # Produces counts[i] spikes in T steps, evenly distributed.
    acc = np.zeros(N, dtype=np.int64)
    for t in range(T):
        acc = acc + counts_clipped
        fired = acc >= T
        out[t, fired] = 1
        acc[fired] -= T
    return out


def run_streamed_rate_chunked(
    pixel_vec: np.ndarray,
    topology: TopologyConfig,
    stage_weights: Sequence[tuple[np.ndarray, np.ndarray]],
    *,
    chunk_boundaries: Sequence[int] | None = None,
    boundary_mode: str = "stream",
) -> tuple[int, list[np.ndarray], list[np.ndarray], list[np.ndarray]]:
    """Run streamed_rate inference with explicit chunk splits.

    REV 3.1 D1 motivates this: when a topology has more layers than the
    hardware ``MAX_LAYERS`` supports, firmware splits stages into chunks.
    The boundary between chunks must preserve enough state for the next
    chunk to continue inference.

    Two modes are exposed so the paper can include a **stream vs count**
    ablation:

      * ``stream`` (default, correct): the last stage of chunk N emits
        ``[T, out_dim]`` binary stream, which is passed verbatim as the
        input ``wl_stream`` to the first stage of chunk N+1. This is
        IDENTICAL to running the full topology without chunking, because
        the inter-stage interface IS already a stream. Chunks here are
        just a firmware scheduling unit, not a semantic change.

      * ``count`` (ablation, lossy): the last stage of chunk N emits
        ``[out_dim]`` counts. The next chunk re-encodes counts into a
        fresh ``[T, out_dim]`` stream via ``_encode_counts_as_spike_stream``.
        The total fire count per neuron is preserved, but the temporal
        ordering is lost. This is the **wrong** design that REV 3.1 D1
        warns against (V2.A count-bitplane had this property).

    ``chunk_boundaries`` lists the stage index where a new chunk starts;
    e.g. ``[2]`` for a 4-stage topology splits into chunks ``[0, 1]`` and
    ``[2, 3]``. ``None`` or empty means no chunking (equivalent to
    ``_snn_inference_streamed_rate_sample``).

    Returns:
      ``(predicted_class, per_stage_counts, per_stage_membrane,
         per_stage_stream)``.
    """
    if boundary_mode not in ("stream", "count"):
        raise ValueError(
            f"boundary_mode must be 'stream' or 'count', got {boundary_mode!r}"
        )
    if topology.input_encoding != "streamed_rate":
        raise ValueError(
            f"Chunked run requires input_encoding='streamed_rate', "
            f"got {topology.input_encoding!r}"
        )
    if len(stage_weights) != topology.num_fc_stages:
        raise ValueError(
            f"Expected {topology.num_fc_stages} weight pairs, got {len(stage_weights)}"
        )

    boundaries = sorted(set(chunk_boundaries)) if chunk_boundaries else []
    n_stages = topology.num_fc_stages
    for b in boundaries:
        if not 1 <= b < n_stages:
            raise ValueError(
                f"chunk_boundary {b} must be in [1, {n_stages - 1}]"
            )

    T = topology.stream_timesteps
    adc_bits = topology.adc_bits
    full_scale = topology.adc_full_scale
    array_rows = 256

    per_stage_counts: list[np.ndarray] = []
    per_stage_membrane: list[np.ndarray] = []
    per_stage_stream: list[np.ndarray] = []

    # Stage 0 input: encode pixel → spike stream (same for both modes).
    wl_stream = encode_pixel_to_spike_stream(pixel_vec, T, method="even_rate")

    for i, (stage, (w_pos, w_neg)) in enumerate(zip(topology.stages, stage_weights)):
        # Resolve per-stage sum_max
        if stage.sum_max is not None:
            sum_max = stage.sum_max
        elif full_scale == "active_wl":
            sum_max = stage.in_dim * 15
        else:
            sum_max = array_rows * 15

        counts, membrane, stream = _run_stage_streamed_rate(
            stage, wl_stream, w_pos, w_neg, sum_max=sum_max, adc_bits=adc_bits,
        )
        per_stage_counts.append(counts)
        per_stage_membrane.append(membrane)
        per_stage_stream.append(stream)

        # At chunk boundary, optionally downgrade stream → counts → re-encode.
        next_stage_idx = i + 1
        if next_stage_idx < n_stages and next_stage_idx in boundaries:
            if boundary_mode == "count":
                wl_stream = _encode_counts_as_spike_stream(counts, T)
            else:
                wl_stream = stream
        else:
            wl_stream = stream

    final_counts = per_stage_counts[-1]
    predicted_class = int(np.argmax(final_counts))
    return predicted_class, per_stage_counts, per_stage_membrane, per_stage_stream


def snn_inference_multilayer(
    images_uint8: np.ndarray,                                # [N, input_dim] uint8
    labels: np.ndarray,                                       # [N] int
    topology: TopologyConfig,
    stage_weights: Sequence[tuple[np.ndarray, np.ndarray]],
) -> tuple[float, np.ndarray]:
    """Run RTL-like inference over a batch, return ``(accuracy, predictions)``.

    Uses ``snn_inference_multilayer_sample`` per sample. Not vectorized to
    guarantee bit-identical results with the RTL integer path (any numpy
    matmul batching could introduce different rounding).
    """
    if images_uint8.shape[1] != topology.input_dim:
        raise ValueError(
            f"Input dim mismatch: images {images_uint8.shape[1]} vs "
            f"topology.input_dim {topology.input_dim}"
        )

    n = images_uint8.shape[0]
    predictions = np.empty(n, dtype=np.int64)
    for i in range(n):
        pred, _, _ = snn_inference_multilayer_sample(
            images_uint8[i].astype(np.int64),  # safely widen uint8 → int64
            topology,
            stage_weights,
        )
        predictions[i] = pred

    # ML-002 fix: extract labels to numpy explicitly (supports torch.Tensor
    # via .numpy(); everything else via np.asarray), and assert shape match
    # so length mismatches raise ValueError instead of silent broadcasting.
    labels_np = labels.numpy() if hasattr(labels, "numpy") else np.asarray(labels)
    if predictions.shape != labels_np.shape:
        raise ValueError(
            f"predictions shape {predictions.shape} != labels shape {labels_np.shape}"
        )
    accuracy = float(np.mean(predictions == labels_np))
    return accuracy, predictions


# ─────────────────────────────────────────────────────────────────────────
# Module self-check: assert our rtl_adc_scale copy matches the vendored one
# ─────────────────────────────────────────────────────────────────────────
def _self_check_adc_scale() -> None:
    """Verify rtl_adc_scale reproduces V1 behavior on a few known inputs.

    Called from ``if __name__ == "__main__"`` for quick sanity; also part of
    the schema test suite.
    """
    # Smoke cases: (raw_sum, expected_scaled)
    cases: list[tuple[int, int]] = [
        (0, 0),
        (SUM_MAX, ADC_MAX),                         # full-scale
        (SUM_MAX // 2, (SUM_MAX // 2 * ADC_MAX + SUM_MAX // 2) // SUM_MAX),
        (-1, 0),                                    # clamp to 0
        (SUM_MAX + 10, ADC_MAX),                    # clamp to ADC_MAX
    ]
    for raw, expected in cases:
        actual = rtl_adc_scale(raw)
        assert actual == expected, f"rtl_adc_scale({raw}) = {actual}, expected {expected}"


if __name__ == "__main__":
    _self_check_adc_scale()
    print("rtl_adc_scale self-check passed")
