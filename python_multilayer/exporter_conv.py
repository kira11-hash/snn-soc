"""CONV weight tiling helpers for the V2.B integer reference.

The frozen layout is tile-major:

``weight_tile[tile_idx][lane][out_c]``

where ``lane = ((ky * K + kx) * C_in + c) % 256`` and the stored value is a
signed 4-bit integer in ``[-7, +7]``.  HEX export follows the existing FC
convention: each tile is split into unsigned ``*_pos.hex`` and ``*_neg.hex``
files, one unsigned nibble per line.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

try:  # Torch is already a dependency of the existing multilayer flow.
    import torch
except Exception:  # pragma: no cover - lets non-export smoke tests import this.
    torch = None  # type: ignore[assignment]

try:
    import config_multilayer as cfg
    from exporter_multilayer import _get_device_levels_for_export, _quantize_stage_weights
except Exception:  # pragma: no cover
    cfg = None  # type: ignore[assignment]
    _get_device_levels_for_export = None  # type: ignore[assignment]
    _quantize_stage_weights = None  # type: ignore[assignment]


SIGNED_MIN = -7
SIGNED_MAX = 7
LANES_PER_TILE = 256


def split_signed_to_pos_neg(signed_value: int) -> tuple[int, int]:
    """Split signed ``[-7, +7]`` into unsigned ``pos``/``neg`` in ``[0, 7]``."""
    v = int(signed_value)
    if v < SIGNED_MIN or v > SIGNED_MAX:
        raise ValueError(f"value must be in [-7, 7], got {v}")
    return max(0, v), max(0, -v)


def merge_pos_neg_to_signed(pos_value: int, neg_value: int) -> int:
    """Merge unsigned ``pos``/``neg`` nibbles back into signed ``[-7, +7]``."""
    pos = int(pos_value)
    neg = int(neg_value)
    if not 0 <= pos <= SIGNED_MAX:
        raise ValueError(f"pos must be in [0, 7], got {pos}")
    if not 0 <= neg <= SIGNED_MAX:
        raise ValueError(f"neg must be in [0, 7], got {neg}")
    signed = pos - neg
    if signed < SIGNED_MIN or signed > SIGNED_MAX:
        raise ValueError(f"pos-neg must be in [-7, 7], got {signed}")
    return signed


def _hex_unsigned_0_to_7(value: int) -> str:
    """Encode one unsigned [0, 7] value as lowercase hex."""
    v = int(value)
    if not 0 <= v <= SIGNED_MAX:
        raise ValueError(f"unsigned split weight must be in [0, 7], got {v}")
    return f"{v:x}"


def _read_unsigned_hex_0_to_7(path: str | Path) -> list[int]:
    values: list[int] = []
    with Path(path).open("r", encoding="ascii") as f:
        for line in f:
            text = line.strip()
            if not text or text.startswith("#"):
                continue
            value = int(text, 16)
            if not 0 <= value <= SIGNED_MAX:
                raise ValueError(f"{path}: value {text!r} is outside [0, 7]")
            values.append(value)
    return values


def conv_kernel_to_matrix(kernel_signed: np.ndarray) -> np.ndarray:
    """Flatten ``[K, K, C_in, C_out]`` into ``[K*K*C_in, C_out]``."""
    arr = np.asarray(kernel_signed, dtype=np.int64)
    if arr.ndim != 4:
        raise ValueError(f"kernel_signed must be [K, K, C_in, C_out], got {arr.shape}")
    if np.any(arr < SIGNED_MIN) or np.any(arr > SIGNED_MAX):
        raise ValueError("kernel_signed contains values outside [-7, 7]")
    k_y, k_x, c_in, c_out = arr.shape
    if k_y != k_x:
        raise ValueError(f"CONV kernels must be square, got {k_y}x{k_x}")

    matrix = np.zeros((k_y * k_x * c_in, c_out), dtype=np.int64)
    for ky in range(k_y):
        for kx in range(k_x):
            for c in range(c_in):
                idx = (ky * k_y + kx) * c_in + c
                matrix[idx, :] = arr[ky, kx, c, :]
    return matrix


def make_weight_tiles_from_matrix(matrix_signed: np.ndarray) -> np.ndarray:
    """Pad and tile ``[input_dim, C_out]`` into ``[tiles, 256, C_out]``."""
    matrix = np.asarray(matrix_signed, dtype=np.int64)
    if matrix.ndim != 2:
        raise ValueError(f"matrix_signed must be [input_dim, C_out], got {matrix.shape}")
    if np.any(matrix < SIGNED_MIN) or np.any(matrix > SIGNED_MAX):
        raise ValueError("matrix_signed contains values outside [-7, 7]")
    input_dim, c_out = matrix.shape
    if input_dim <= 0:
        raise ValueError("input_dim must be positive")
    tile_count = (input_dim + LANES_PER_TILE - 1) // LANES_PER_TILE
    tiles = np.zeros((tile_count, LANES_PER_TILE, c_out), dtype=np.int64)
    for idx in range(input_dim):
        tiles[idx // LANES_PER_TILE, idx % LANES_PER_TILE, :] = matrix[idx, :]
    return tiles


def make_weight_tiles_from_kernel(kernel_signed: np.ndarray) -> np.ndarray:
    """Convert ``[K, K, C_in, C_out]`` signed weights to tile-major layout."""
    return make_weight_tiles_from_matrix(conv_kernel_to_matrix(kernel_signed))


def quantize_conv2d_weight_to_signed(
    weight_4d: "torch.Tensor",
    *,
    weight_bits: int = 4,
    levels: object | None = None,
) -> np.ndarray:
    """Quantize a PyTorch ``nn.Conv2d`` weight tensor to signed 4-bit levels.

    Input shape is ``[C_out, C_in, K, K]``.  The existing multilayer quantizer
    is reused by reshaping the kernel into an FC-style matrix and subtracting
    the exported positive/negative halves.  The resulting signed values are
    clamped to the V2.B CONV architectural range ``[-7, +7]``.
    """
    if torch is None:
        raise RuntimeError("torch is required for quantize_conv2d_weight_to_signed")
    if _quantize_stage_weights is None:
        raise RuntimeError("exporter_multilayer quantization helpers are unavailable")

    w = weight_4d.detach()
    if w.ndim != 4:
        raise ValueError(f"expected [C_out, C_in, K, K], got {tuple(w.shape)}")
    c_out, c_in, k_y, k_x = (int(x) for x in w.shape)
    if k_y != k_x:
        raise ValueError(f"CONV kernels must be square, got {k_y}x{k_x}")

    # FC quantizer expects [out_dim, in_dim].  Its in_dim order must match
    # conv_idx = (ky*K + kx)*C_in + c.
    fc_weight = torch.zeros((c_out, k_y * k_x * c_in), dtype=w.dtype, device=w.device)
    for ky in range(k_y):
        for kx in range(k_x):
            for c in range(c_in):
                idx = (ky * k_y + kx) * c_in + c
                fc_weight[:, idx] = w[:, c, ky, kx]

    if levels is None and _get_device_levels_for_export is not None and cfg is not None:
        levels = _get_device_levels_for_export(2 ** weight_bits)
    g_pos, g_neg = _quantize_stage_weights(fc_weight, weight_bits, levels)
    signed_matrix = np.clip(g_pos.astype(np.int64) - g_neg.astype(np.int64),
                            SIGNED_MIN, SIGNED_MAX)

    kernel = np.zeros((k_y, k_x, c_in, c_out), dtype=np.int64)
    for ky in range(k_y):
        for kx in range(k_x):
            for c in range(c_in):
                idx = (ky * k_y + kx) * c_in + c
                kernel[ky, kx, c, :] = signed_matrix[idx, :]
    return kernel


def export_weight_tile_split(
    tile_signed: np.ndarray,
    out_dir: str | Path,
    case_id: str,
    layer_id: str,
    tile_idx: int,
) -> tuple[Path, Path]:
    """Write one tile as ``*_pos.hex`` and ``*_neg.hex``.

    ``layer_id`` is accepted to keep the call site aligned with the future
    multi-layer exporter; M1 synthetic filenames intentionally omit it to match
    the frozen review contract.
    """
    del layer_id
    tile = np.asarray(tile_signed, dtype=np.int64)
    if tile.ndim != 2 or tile.shape[0] != LANES_PER_TILE:
        raise ValueError(f"tile_signed must be [256, C_out], got {tile.shape}")
    if np.any(tile < SIGNED_MIN) or np.any(tile > SIGNED_MAX):
        raise ValueError("tile_signed contains values outside [-7, 7]")

    path = Path(out_dir)
    path.mkdir(parents=True, exist_ok=True)
    pos_path = path / f"synthetic_{case_id}_weight_tile_{int(tile_idx)}_pos.hex"
    neg_path = path / f"synthetic_{case_id}_weight_tile_{int(tile_idx)}_neg.hex"
    with pos_path.open("w", encoding="ascii", newline="\n") as fp_pos, \
            neg_path.open("w", encoding="ascii", newline="\n") as fp_neg:
        for lane_idx in range(tile.shape[0]):
            for out_c in range(tile.shape[1]):
                pos, neg = split_signed_to_pos_neg(int(tile[lane_idx, out_c]))
                fp_pos.write(f"{_hex_unsigned_0_to_7(pos)}\n")
                fp_neg.write(f"{_hex_unsigned_0_to_7(neg)}\n")
    return pos_path, neg_path


def write_weight_tiles_split_hex(
    weight_tiles: np.ndarray,
    out_dir: str | Path,
    *,
    case_id: str,
    layer_id: str = "L0",
) -> list[dict[str, Path | int]]:
    """Write ``[tiles, 256, C_out]`` signed tiles as pos/neg HEX pairs."""
    tiles = np.asarray(weight_tiles, dtype=np.int64)
    if tiles.ndim != 3 or tiles.shape[1] != LANES_PER_TILE:
        raise ValueError(f"weight_tiles must be [tiles, 256, C_out], got {tiles.shape}")
    if np.any(tiles < SIGNED_MIN) or np.any(tiles > SIGNED_MAX):
        raise ValueError("weight_tiles contains values outside [-7, 7]")

    written: list[dict[str, Path | int]] = []
    for tile_idx in range(tiles.shape[0]):
        pos_path, neg_path = export_weight_tile_split(
            tiles[tile_idx],
            out_dir,
            case_id=case_id,
            layer_id=layer_id,
            tile_idx=tile_idx,
        )
        written.append({"tile_idx": tile_idx, "pos": pos_path, "neg": neg_path})
    return written


def read_weight_tile_split_hex(
    pos_path: str | Path,
    neg_path: str | Path,
    *,
    c_out: int,
) -> np.ndarray:
    """Read one pos/neg tile pair into signed ``[256, C_out]`` integers."""
    pos_values = _read_unsigned_hex_0_to_7(pos_path)
    neg_values = _read_unsigned_hex_0_to_7(neg_path)
    expected = LANES_PER_TILE * int(c_out)
    if len(pos_values) != expected:
        raise ValueError(f"{pos_path} has {len(pos_values)} entries, expected {expected}")
    if len(neg_values) != expected:
        raise ValueError(f"{neg_path} has {len(neg_values)} entries, expected {expected}")
    signed = [
        merge_pos_neg_to_signed(pos, neg)
        for pos, neg in zip(pos_values, neg_values)
    ]
    return np.asarray(signed, dtype=np.int64).reshape(LANES_PER_TILE, int(c_out))


def load_weight_tiles_split_hex(
    tile_files: list[dict[str, str | Path | int]],
    *,
    c_out: int,
) -> np.ndarray:
    """Read manifest-style tile file dicts into ``[tiles, 256, C_out]``."""
    if not tile_files:
        raise ValueError("at least one weight tile pair is required")
    ordered = sorted(tile_files, key=lambda entry: int(entry["tile_idx"]))
    tiles = [
        read_weight_tile_split_hex(entry["pos"], entry["neg"], c_out=c_out)
        for entry in ordered
    ]
    return np.stack(tiles, axis=0).astype(np.int64)
