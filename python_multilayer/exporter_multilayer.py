"""Export multilayer model weights to HEX + manifest.json.

Phase V2.A / A3:
    * ``export_topology`` — for each stage, quantize weights to 4-bit level
      indices, write HEX files, compute SHA-256, count nonzero cells, emit
      ``manifest.json``.
    * ``load_hex_weights_for_topology`` — load back from HEX for bit-parity
      check (A6.a's quantized-memory vs quantized-hex comparison).

HEX format (matches V1 ``load_weight_hex`` convention):
    One hex value per line, row-major ``[in_dim][out_dim]``. Each value in
    ``[0, 15]`` (4-bit level index).
"""

from __future__ import annotations

import hashlib
import json
import logging
import struct
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import torch

import config_multilayer as cfg
from _vendored_from_v1.integer_reference import load_weight_hex_variable_shape
from _vendored_from_v1.quantization import split_differential
from topologies import HW_MAX_LAYERS, StageConfig, TopologyConfig

logger = logging.getLogger(__name__)

TOPO_DESC_MAGIC: int = 0x544F504F  # "TOPO" little-endian
TOPO_DESC_VERSION: int = 0x0001
TOPO_DESC_HEADER_SIZE: int = 32
TOPO_DESC_STAGE_SIZE: int = 24
TOPO_DESC_MAX_STAGES: int = HW_MAX_LAYERS * 2  # chunk multiplex room

ADC_FULL_SCALE_ARRAY: int = 0
ADC_FULL_SCALE_ACTIVE_WL: int = 1


def _sha256_of_file(path: Path) -> str:
    """SHA-256 digest of a file's bytes (hex string)."""
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _write_hex_matrix(matrix_int: np.ndarray, path: Path) -> None:
    """Write an ``[in_dim, out_dim]`` int matrix to row-major HEX file.

    Each line is one value, lowercase hex, no prefix. Bit-identical to V1
    ``export_weight_map`` HEX writer.
    """
    if matrix_int.dtype.kind not in ("i", "u"):
        raise TypeError(f"Expected int matrix, got dtype {matrix_int.dtype}")
    in_dim, out_dim = matrix_int.shape
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="ascii") as f:
        for row in range(in_dim):
            for col in range(out_dim):
                f.write(f"{int(matrix_int[row, col]):x}\n")


def _as_level_tensor(
    levels: object | None,
    num_levels: int,
    *,
    device: torch.device,
    dtype: torch.dtype,
    add_zero_level: bool,
) -> torch.Tensor:
    """Return a normalized torch level table.

    V1 has two related but distinct level-table conventions:
    - QAT (`snn_engine._load_plugin_levels`) prepends a zero level if the
      device table starts above zero.
    - HEX export (`export_weight_map._get_level_table`) uses the physical
      device levels only, without prepending zero, so emitted indices remain
      in the 4-bit range [0, 15].

    This exporter follows the HEX convention, so callers pass
    ``add_zero_level=False``.
    """
    if levels is None:
        return torch.linspace(0.0, 1.0, num_levels, device=device, dtype=dtype)

    level_vals = torch.as_tensor(levels, device=device, dtype=dtype).flatten()
    level_vals = torch.sort(torch.unique(level_vals))[0]
    if level_vals.numel() < 2:
        return torch.linspace(0.0, 1.0, num_levels, device=device, dtype=dtype)

    max_val = level_vals.max()
    if max_val < 1e-12:
        return torch.linspace(0.0, 1.0, num_levels, device=device, dtype=dtype)

    level_vals = level_vals / max_val
    if add_zero_level and level_vals[0] > 0:
        level_vals = torch.cat([torch.zeros(1, device=device, dtype=dtype), level_vals])
    return level_vals


def _quantize_half_to_level_indices(
    w_half: torch.Tensor,
    ref_max: torch.Tensor,
    weight_bits: int,
    levels: object | None,
) -> torch.Tensor:
    """Quantize a non-negative half-matrix to level indices using shared ref.

    This mirrors V1 `export_weight_map.py`: split the signed weight matrix,
    use one shared `abs().max()` for positive and negative halves, snap to the
    nearest normalized conductance level, and export the nearest level index.
    Using per-half maxima would still round-trip through HEX, but would not
    match V1/RTL weight maps.
    """
    if ref_max < 1e-12:
        return torch.zeros_like(w_half, dtype=torch.long)

    num_levels = 2 ** weight_bits
    level_vals = _as_level_tensor(
        levels,
        num_levels,
        device=w_half.device,
        dtype=w_half.dtype,
        add_zero_level=False,
    )
    if level_vals.numel() != num_levels:
        raise ValueError(
            f"HEX export expected {num_levels} physical levels for {weight_bits}-bit "
            f"weights, got {level_vals.numel()}"
        )

    normalized = (w_half / ref_max).clamp(0.0, 1.0)
    diff = (normalized.unsqueeze(-1) - level_vals.view(1, 1, -1)).abs()
    return diff.argmin(dim=-1).long()


def _quantize_stage_weights(
    w: torch.Tensor,                 # [out_dim, in_dim] float
    weight_bits: int,
    levels: object | None,
) -> tuple[np.ndarray, np.ndarray]:
    """Split + quantize a single stage's float weight matrix.

    Returns ``(g_pos, g_neg)`` as ``[in_dim, out_dim]`` int numpy matrices
    (row-major matches the HEX file layout).
    """
    # Transpose to [in_dim, out_dim] (matches HEX row-major: rows are inputs).
    w_t = w.detach().t().contiguous()   # [in_dim, out_dim]

    w_pos_float, w_neg_float = split_differential(w_t)
    shared_max = w_t.abs().max()

    g_pos = _quantize_half_to_level_indices(
        w_pos_float, shared_max, weight_bits, levels
    )
    g_neg = _quantize_half_to_level_indices(
        w_neg_float, shared_max, weight_bits, levels
    )

    return g_pos.cpu().numpy().astype(np.int64), g_neg.cpu().numpy().astype(np.int64)


def _get_device_levels_for_export(num_levels: int) -> torch.Tensor | None:
    """Same as trainer's device levels (uniform [0,1] or V1 device model)."""
    if not cfg.QAT_USE_DEVICE_LEVELS:
        return torch.linspace(0.0, 1.0, num_levels)
    try:
        cfg.setup_v1_import_paths()
        from memristor_plugin import MemristorArraySimulator  # type: ignore

        sim = MemristorArraySimulator(
            iv_data_path=str(cfg.V1_DEVICE_DIR / "I-V.xlsx"), device="cpu"
        )
        levels = torch.as_tensor(sim.conductance_levels, dtype=torch.float32)
        levels = torch.sort(torch.unique(levels))[0]
        if levels.numel() != num_levels:
            raise ValueError(
                f"device model returned {levels.numel()} levels, expected {num_levels}"
            )
        max_val = levels.max()
        if max_val < 1e-12:
            return torch.linspace(0.0, 1.0, num_levels)
        return levels / max_val
    except Exception as exc:
        logger.warning("Device model unavailable (%s); using uniform levels.", exc)
        return torch.linspace(0.0, 1.0, num_levels)


def export_topology(
    topology: TopologyConfig,
    model_state_dict: dict[str, torch.Tensor],
    out_dir: Path,
) -> dict:
    """Export all stages of a topology to HEX + manifest.json.

    Args:
        topology:         TopologyConfig for this model.
        model_state_dict: torch state_dict from ``MultiLayerANN`` (keys are
                          ``layers.<i>.weight``).
        out_dir:          Output directory (``results_multilayer/<name>/``).

    Returns:
        The manifest dict (also written to ``out_dir/manifest.json``).
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    weights_dir = out_dir / "weights"
    weights_dir.mkdir(parents=True, exist_ok=True)

    levels = _get_device_levels_for_export(2 ** cfg.QAT_WEIGHT_BITS)

    stage_meta: list[dict] = []
    total_nonzero = 0

    for i, stage in enumerate(topology.stages):
        key = f"layers.{i}.weight"
        if key not in model_state_dict:
            raise KeyError(
                f"Model state_dict is missing key {key!r} for stage {i} of "
                f"topology {topology.name}. Available keys: {list(model_state_dict)}"
            )
        w = model_state_dict[key]                 # [out_dim, in_dim]
        if w.shape != (stage.out_dim, stage.in_dim):
            raise ValueError(
                f"Stage {i} weight shape {tuple(w.shape)} != expected "
                f"({stage.out_dim}, {stage.in_dim})"
            )

        g_pos, g_neg = _quantize_stage_weights(
            w, cfg.QAT_WEIGHT_BITS, levels
        )  # both [in_dim, out_dim] int

        pos_path = weights_dir / f"L{i}_pos.hex"
        neg_path = weights_dir / f"L{i}_neg.hex"
        _write_hex_matrix(g_pos, pos_path)
        _write_hex_matrix(g_neg, neg_path)

        # Metrics
        nonzero = int(np.count_nonzero(g_pos)) + int(np.count_nonzero(g_neg))
        physical = g_pos.size + g_neg.size

        stage_meta.append({
            "layer": i,
            "in_dim": stage.in_dim,
            "out_dim": stage.out_dim,
            "bl_scan_count": stage.bl_scan_count,
            "wl_count": stage.wl_count,
            "timesteps": stage.timesteps,
            "use_bitplane": stage.use_bitplane,
            "threshold": stage.threshold,
            "weight_pos_hex": f"weights/L{i}_pos.hex",
            "weight_neg_hex": f"weights/L{i}_neg.hex",
            "weight_pos_sha256": _sha256_of_file(pos_path),
            "weight_neg_sha256": _sha256_of_file(neg_path),
            "nonzero_cells": nonzero,
            "physical_cells": physical,
        })
        total_nonzero += nonzero

    manifest = {
        "topology_name": topology.name,
        "schema_version": "1.0",
        "role": topology.role,
        "num_fc_stages": topology.num_fc_stages,
        "input_dim": topology.input_dim,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "quantization": {
            "weight_bits": cfg.QAT_WEIGHT_BITS,
            "use_device_levels": cfg.QAT_USE_DEVICE_LEVELS,
        },
        "stages": stage_meta,
        "total_nonzero_cells": total_nonzero,
    }
    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    logger.info(
        "[%s] exported %d stages to %s (total_nonzero=%d)",
        topology.name, len(stage_meta), out_dir, total_nonzero,
    )
    return manifest


def load_hex_weights_for_topology(
    topology: TopologyConfig, out_dir: Path
) -> list[tuple[np.ndarray, np.ndarray]]:
    """Load back the exported HEX weights as ``[(w_pos, w_neg), ...]`` int matrices.

    Returns numpy int matrices of shape ``[in_dim, out_dim]`` for each stage.
    Matches the format expected by ``snn_inference_multilayer_sample``.
    """
    weights_dir = out_dir / "weights"
    stage_weights: list[tuple[np.ndarray, np.ndarray]] = []
    for i, stage in enumerate(topology.stages):
        pos_path = weights_dir / f"L{i}_pos.hex"
        neg_path = weights_dir / f"L{i}_neg.hex"
        w_pos_list = load_weight_hex_variable_shape(str(pos_path), stage.in_dim, stage.out_dim)
        w_neg_list = load_weight_hex_variable_shape(str(neg_path), stage.in_dim, stage.out_dim)
        w_pos = np.array(w_pos_list, dtype=np.int64)
        w_neg = np.array(w_neg_list, dtype=np.int64)
        stage_weights.append((w_pos, w_neg))
    return stage_weights


def weights_in_memory_int_form(
    topology: TopologyConfig,
    model_state_dict: dict[str, torch.Tensor],
) -> list[tuple[np.ndarray, np.ndarray]]:
    """Produce the same int matrices the exporter would write, without file I/O.

    Used by ``test_exported_hex_parity`` to compare memory-quantized vs
    hex-loaded weights, proving the export round-trip is lossless.
    """
    levels = _get_device_levels_for_export(2 ** cfg.QAT_WEIGHT_BITS)
    stage_weights: list[tuple[np.ndarray, np.ndarray]] = []
    for i, stage in enumerate(topology.stages):
        key = f"layers.{i}.weight"
        w = model_state_dict[key]
        g_pos, g_neg = _quantize_stage_weights(w, cfg.QAT_WEIGHT_BITS, levels)
        stage_weights.append((g_pos, g_neg))
    return stage_weights


# ──────────────────────────────────────────────────────────────────────
# REV 3.1 D3 — binary topology descriptor (topology_desc.bin + .h)
# ──────────────────────────────────────────────────────────────────────

def _pack_topology_desc_header(
    *,
    stream_timesteps: int,
    adc_bits: int,
    adc_full_scale_code: int,
    num_stages_total: int,
    num_chunks: int,
    pixel_stream_addr: int,
) -> bytes:
    """32-byte little-endian header for topology_desc.bin.

    Layout (offsets in bytes):
      0  uint32 magic             = TOPO_DESC_MAGIC
      4  uint16 version           = TOPO_DESC_VERSION
      6  uint16 stream_timesteps
      8  uint8  adc_bits
      9  uint8  adc_full_scale    (0=array, 1=active_wl)
      10 uint8  num_stages_total
      11 uint8  num_chunks
      12 uint32 pixel_stream_addr (firmware-encoded pixel stream SRAM base)
      16 uint32 reserved[4]       (zero, future use)
    """
    return struct.pack(
        "<IHHBBBBI16s",
        TOPO_DESC_MAGIC,
        TOPO_DESC_VERSION,
        stream_timesteps,
        adc_bits,
        adc_full_scale_code,
        num_stages_total,
        num_chunks,
        pixel_stream_addr,
        b"\x00" * 16,
    )


def _pack_stage_desc(
    *,
    in_dim: int,
    out_dim: int,
    threshold: int,
    sum_max: int,
    weight_pos_addr: int,
    weight_neg_addr: int,
    is_resident: int,
    is_tile_final: int,
    tile_mode: int,
    chunk_id: int,
) -> bytes:
    """24-byte little-endian stage descriptor.

    Layout:
      0  uint16 in_dim
      2  uint16 out_dim
      4  uint32 threshold
      8  uint32 sum_max
      12 uint32 weight_pos_addr
      16 uint32 weight_neg_addr
      20 uint8  is_resident      (1 = boot-loaded, skip reprogram)
      21 uint8  is_tile_final    (1 = last tile of a multi-tile stage)
      22 uint8  tile_mode        (0 = single stage, 1 = tile partial-sum)
      23 uint8  chunk_id         (0 for non-chunked demos)
    """
    return struct.pack(
        "<HHIIIIBBBB",
        in_dim, out_dim,
        threshold, sum_max,
        weight_pos_addr, weight_neg_addr,
        is_resident, is_tile_final, tile_mode, chunk_id,
    )


def _adc_full_scale_code(topology: TopologyConfig) -> int:
    scale = getattr(topology, "adc_full_scale", "active_wl")
    if scale == "array":
        return ADC_FULL_SCALE_ARRAY
    if scale == "active_wl":
        return ADC_FULL_SCALE_ACTIVE_WL
    raise ValueError(f"Unknown adc_full_scale={scale!r}")


def _effective_sum_max(stage: StageConfig, topology: TopologyConfig) -> int:
    """Resolve stage.sum_max using topology-level adc_full_scale policy."""
    if stage.sum_max is not None:
        return int(stage.sum_max)
    scale = getattr(topology, "adc_full_scale", "active_wl")
    if scale == "array":
        from topologies import HW_NUM_INPUTS  # local import to avoid cycles
        return HW_NUM_INPUTS * 15
    return int(stage.in_dim) * 15


def export_topology_descriptor(
    topology: TopologyConfig,
    out_dir: Path,
    *,
    weight_pos_base_addr: int = 0x1000_0000,
    weight_neg_base_addr: int = 0x1000_8000,
    pixel_stream_addr: int = 0x2000_0000,
) -> dict:
    """Emit ``topology_desc.bin`` + ``topology_desc.h`` for Phase C firmware.

    REV 3.1 D3: E203 firmware does NOT parse JSON. It reads a pre-compiled
    binary descriptor into SRAM and walks it via the matching C struct.

    REV 3.2 D11: Every stage carries an ``is_resident`` bit. The 14×14 main
    demo marks all stages resident; tile / chunk multiplex demos leave it 0
    so firmware reprograms per tile/chunk.

    Only streamed-rate topologies emit a descriptor; legacy bit-plane V1
    paths are skipped (their firmware path differs).

    Args:
      topology:              TopologyConfig (post-validation).
      out_dir:               Destination folder (descriptor beside manifest).
      weight_pos_base_addr:  Per-stage positive weight base address (advances
                             by 32 KB placeholder stride; B0 mini-spec
                             will replace with real SRAM map).
      weight_neg_base_addr:  Per-stage negative weight base address.
      pixel_stream_addr:     SRAM base where firmware drops encoded pixel.

    Returns:
      dict summarising the emitted layout (bytes, sha256, path list).
    """
    if getattr(topology, "input_encoding", "bitplane") != "streamed_rate":
        logger.info(
            "[%s] skip descriptor (input_encoding=%s, not streamed_rate)",
            topology.name, getattr(topology, "input_encoding", None),
        )
        return {"skipped": True, "reason": "not streamed_rate"}

    # Resident policy per REV 3.2 D11: 14×14 single/multi fits 256×256 array.
    # Any stage whose 2*out_dim > 256 WL (tile needed) or layer count > MAX
    # flips is_resident=0. Main 14×14 always stays 1.
    #
    # V0 of the descriptor only supports single-tile + single-chunk layouts.
    # Tile/chunk multiplex is reserved for A4/A3 follow-up.
    num_stages = topology.num_fc_stages
    if num_stages > TOPO_DESC_MAX_STAGES:
        raise ValueError(
            f"Topology {topology.name} has {num_stages} stages, exceeds "
            f"TOPO_DESC_MAX_STAGES={TOPO_DESC_MAX_STAGES}"
        )

    adc_bits = int(getattr(topology, "adc_bits", 10))
    stream_timesteps = int(getattr(topology, "stream_timesteps", 64))
    adc_full_scale_code = _adc_full_scale_code(topology)

    header = _pack_topology_desc_header(
        stream_timesteps=stream_timesteps,
        adc_bits=adc_bits,
        adc_full_scale_code=adc_full_scale_code,
        num_stages_total=num_stages,
        num_chunks=1,  # V0: no chunk multiplex
        pixel_stream_addr=pixel_stream_addr,
    )
    assert len(header) == TOPO_DESC_HEADER_SIZE, (
        f"header size {len(header)} != {TOPO_DESC_HEADER_SIZE}"
    )

    # 14×14 resident policy: treat 196_* stages as resident.
    # Future tile/chunk demos override via args.
    fits_array = all(s.in_dim <= 256 and 2 * s.out_dim <= 256 for s in topology.stages)
    fits_layers = num_stages <= HW_MAX_LAYERS

    stage_bytes: list[bytes] = []
    stage_meta: list[dict] = []
    pos_stride = 0x8000  # 32 KB placeholder per-stage region
    neg_stride = 0x8000
    for i, stage in enumerate(topology.stages):
        is_resident = 1 if (fits_array and fits_layers) else 0
        sum_max = _effective_sum_max(stage, topology)
        w_pos_addr = weight_pos_base_addr + i * pos_stride
        w_neg_addr = weight_neg_base_addr + i * neg_stride
        packed = _pack_stage_desc(
            in_dim=stage.in_dim,
            out_dim=stage.out_dim,
            threshold=int(stage.threshold),
            sum_max=sum_max,
            weight_pos_addr=w_pos_addr,
            weight_neg_addr=w_neg_addr,
            is_resident=is_resident,
            is_tile_final=1,  # V0: always single-tile
            tile_mode=0,      # V0: no accumulate
            chunk_id=0,
        )
        assert len(packed) == TOPO_DESC_STAGE_SIZE
        stage_bytes.append(packed)
        stage_meta.append({
            "layer": i,
            "in_dim": stage.in_dim,
            "out_dim": stage.out_dim,
            "threshold": stage.threshold,
            "sum_max": sum_max,
            "weight_pos_addr": f"0x{w_pos_addr:08x}",
            "weight_neg_addr": f"0x{w_neg_addr:08x}",
            "is_resident": is_resident,
        })

    blob = header + b"".join(stage_bytes)
    expected_size = TOPO_DESC_HEADER_SIZE + num_stages * TOPO_DESC_STAGE_SIZE
    assert len(blob) == expected_size, (
        f"descriptor size mismatch: got {len(blob)}, expected {expected_size}"
    )

    out_dir.mkdir(parents=True, exist_ok=True)
    bin_path = out_dir / "topology_desc.bin"
    bin_path.write_bytes(blob)
    blob_sha = hashlib.sha256(blob).hexdigest()

    # Matching C header
    header_path = out_dir / "topology_desc.h"
    header_path.write_text(_render_topology_desc_h(topology), encoding="utf-8")

    logger.info(
        "[%s] descriptor: %d bytes (%d stages), sha256=%s, bin=%s",
        topology.name, len(blob), num_stages, blob_sha[:16], bin_path,
    )

    return {
        "topology_name": topology.name,
        "bytes": len(blob),
        "num_stages": num_stages,
        "sha256": blob_sha,
        "bin_path": str(bin_path),
        "header_path": str(header_path),
        "stream_timesteps": stream_timesteps,
        "adc_bits": adc_bits,
        "adc_full_scale_code": adc_full_scale_code,
        "all_resident": all(s["is_resident"] == 1 for s in stage_meta),
        "stages": stage_meta,
    }


def _render_topology_desc_h(topology: TopologyConfig) -> str:
    """Emit the C header mirroring topology_desc.bin layout.

    Firmware includes this and casts the loaded blob pointer to
    ``const topology_desc_t *``.
    """
    return f"""/* auto-generated by exporter_multilayer.py for topology={topology.name}
 * DO NOT EDIT BY HAND. Mirrors topology_desc.bin struct layout.
 * REV 3.1 D3 + REV 3.2 D11.
 */
#ifndef TOPOLOGY_DESC_H
#define TOPOLOGY_DESC_H
#include <stdint.h>

#define TOPO_DESC_MAGIC         0x{TOPO_DESC_MAGIC:08X}u
#define TOPO_DESC_VERSION       0x{TOPO_DESC_VERSION:04X}u
#define TOPO_DESC_MAX_STAGES    {TOPO_DESC_MAX_STAGES}

#define ADC_FULL_SCALE_ARRAY      {ADC_FULL_SCALE_ARRAY}u
#define ADC_FULL_SCALE_ACTIVE_WL  {ADC_FULL_SCALE_ACTIVE_WL}u

typedef struct __attribute__((packed)) {{
    uint16_t in_dim;             /* 1..256 */
    uint16_t out_dim;            /* 1..128 */
    uint32_t threshold;          /* LIF threshold, unsigned */
    uint32_t sum_max;            /* per-tile ADC full-scale (= in_dim * 15 active_wl) */
    uint32_t weight_pos_addr;    /* SRAM address, positive CIM half */
    uint32_t weight_neg_addr;    /* SRAM address, negative CIM half */
    uint8_t  is_resident;        /* 1=boot-loaded, 0=firmware reprograms per tile */
    uint8_t  is_tile_final;      /* 1=last tile (trigger LIF + write stream buf) */
    uint8_t  tile_mode;          /* 0=single, 1=tile partial-sum accumulate */
    uint8_t  chunk_id;           /* for future chunk multiplex */
}} stage_desc_t;

typedef struct __attribute__((packed)) {{
    uint32_t magic;              /* TOPO_DESC_MAGIC, check on boot */
    uint16_t version;            /* TOPO_DESC_VERSION */
    uint16_t stream_timesteps;   /* T (e.g. 64, 256) */
    uint8_t  adc_bits;           /* 8 / 10 / 12 */
    uint8_t  adc_full_scale;     /* ADC_FULL_SCALE_* */
    uint8_t  num_stages_total;   /* flexible array length */
    uint8_t  num_chunks;         /* 1 for V0; future multi-chunk */
    uint32_t pixel_stream_addr;  /* SRAM base for firmware-encoded pixel stream */
    uint32_t reserved[4];        /* zero, future */
    stage_desc_t stages[];       /* num_stages_total entries */
}} topology_desc_t;

#endif /* TOPOLOGY_DESC_H */
"""
