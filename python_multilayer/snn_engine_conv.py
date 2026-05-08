"""Integer RTL-like reference for the V2.B CONV extension.

This module is the M1 bit-exact contract for M3 RTL/TB work.  It models the
frozen V2.B CONV datapath order:

* 32-bit padded fmap layout
* dynamic WL patch/flatten gather, one timestep at a time
* 256-lane signed 4-bit weight tiles
* T-major partial-sum accumulation across tiles
* LIF + soft reset only on the last tile
* per-pixel membrane reset and packed fmap writeback
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from pack_fmap_words import (
    fmap_size_words,
    get_fmap_bit,
    pack_spike_fmap,
    set_fmap_bit,
    stream_words_for_t,
)
from snn_engine_multilayer import encode_pixel_to_spike_stream


V2B_NUM_INPUTS = 256
V2B_MAX_OUT_NEURONS = 128
V2B_MAX_TIMESTEPS = 256
V2B_CONV_MAX_H = 64
V2B_CONV_MAX_W = 64
V2B_CONV_MAX_KKC = 1152
V2B_FMAP_BANK_WORDS = 65536
V2B_PARTIAL_ABS_LIMIT = 8191
V2B_WEIGHT_TIMEOUT_CYCLES = 1_000_000


ERR_CODES: dict[str, int] = {
    "OK": 0,
    "ERR_ILLEGAL_KKC": 1,
    "ERR_TILE_CFG_MISMATCH": 2,
    "ERR_BAD_GEOMETRY": 3,
    "ERR_FMAP_OOB": 4,
    "ERR_BAD_T": 5,
    "ERR_BAD_COUT": 6,
    "ERR_FMAP_WRITE_WHILE_BUSY": 7,
    "ERR_WEIGHT_TIMEOUT": 8,
    "ERR_FMAP_WR_OOB": 9,
}
ERR_NAMES_BY_CODE = {v: k for k, v in ERR_CODES.items()}


class ConvConfigError(ValueError):
    """Raised when a CONV run is attempted with an invalid configuration."""


class PartialSumOverflowError(OverflowError):
    """Raised when the 14-bit signed partial-sum bound would be exceeded."""


@dataclass
class ConvRunResult:
    output_words: np.ndarray
    output_spikes: np.ndarray      # [out_H, out_W, C_out, T]
    output_counts: np.ndarray      # [out_H, out_W, C_out]
    trace: dict[str, Any]


def _get_int(cfg: dict, *names: str, default: int | None = None) -> int:
    for name in names:
        if name in cfg and cfg[name] is not None:
            return int(cfg[name])
    if default is None:
        raise KeyError(f"configuration is missing one of {names}")
    return int(default)


def _ceil_div(a: int, b: int) -> int:
    return (int(a) + int(b) - 1) // int(b)


def _out_dim(size: int, k: int, stride: int, pad: int) -> int:
    return ((int(size) + 2 * int(pad) - int(k)) // int(stride)) + 1


def _valid_count(input_dim: int, tile_idx: int) -> int:
    remaining = int(input_dim) - int(tile_idx) * V2B_NUM_INPUTS
    return max(0, min(V2B_NUM_INPUTS, remaining))


def err_code_num(name: str) -> int:
    return ERR_CODES[name]


def err_code_name(code: int) -> str:
    return ERR_NAMES_BY_CODE[int(code)]


def derive_conv_cfg(cfg: dict) -> dict:
    """Return a normalized config with derived out shape and tile fields."""
    out = dict(cfg)
    flatten_mode = bool(out.get("flatten_mode", False))
    k = _get_int(out, "K", "cfg_K", default=0)
    stride = _get_int(out, "stride", "S", "cfg_stride", default=1)
    pad = _get_int(out, "pad", "P", "cfg_pad", default=0)
    h = _get_int(out, "H", "cfg_H", default=0)
    w = _get_int(out, "W", "cfg_W", default=0)
    c_in = _get_int(out, "C_in", "Cin", "cfg_C_in", default=0)
    c_out = _get_int(out, "C_out", "Cout", "cfg_C_out", default=0)
    t_count = _get_int(out, "T", "T_count", "cfg_T_count", default=0)

    if flatten_mode:
        input_dim = h * w * c_in
        out_h = _get_int(out, "out_H", "cfg_out_H", default=1)
        out_w = _get_int(out, "out_W", "cfg_out_W", default=1)
    else:
        input_dim = k * k * c_in
        out_h = _get_int(out, "out_H", "cfg_out_H",
                         default=_out_dim(h, k, stride, pad) if stride else 0)
        out_w = _get_int(out, "out_W", "cfg_out_W",
                         default=_out_dim(w, k, stride, pad) if stride else 0)

    tile_count = _get_int(out, "tile_count", "cfg_tile_count",
                          default=_ceil_div(input_dim, V2B_NUM_INPUTS) if input_dim > 0 else 0)
    last_count = _get_int(
        out,
        "last_tile_valid_count",
        "last_count",
        "cfg_last_tile_valid_count",
        default=(
            input_dim - V2B_NUM_INPUTS * (tile_count - 1)
            if tile_count > 0 else 0
        ),
    )

    out.update({
        "K": k,
        "stride": stride,
        "pad": pad,
        "H": h,
        "W": w,
        "C_in": c_in,
        "C_out": c_out,
        "T": t_count,
        "out_H": out_h,
        "out_W": out_w,
        "input_dim": input_dim,
        "tile_count": tile_count,
        "last_tile_valid_count": last_count,
        "stream_words": stream_words_for_t(t_count) if t_count > 0 else 0,
        "base_word": _get_int(out, "base_word", "fmap_base_word", default=0),
        "out_base_word": _get_int(out, "out_base_word", "cfg_out_base_word", default=0),
        "bank_words": _get_int(out, "bank_words", default=V2B_FMAP_BANK_WORDS),
        "threshold": _get_int(out, "threshold", "cfg_threshold", default=1),
        "flatten_mode": flatten_mode,
    })
    return out


def validate_conv_cfg(cfg: dict) -> tuple[bool, str]:
    """Validate a CONV/FLATTEN config and return ``(ok, err_name)``."""
    c = derive_conv_cfg(cfg)
    flatten = bool(c["flatten_mode"])
    k = c["K"]
    stride = c["stride"]
    pad = c["pad"]
    h = c["H"]
    w = c["W"]
    c_in = c["C_in"]
    c_out = c["C_out"]
    t_count = c["T"]
    input_dim = c["input_dim"]

    if not flatten:
        kkc = k * k * c_in
        if kkc == 0 or kkc > V2B_CONV_MAX_KKC:
            return False, "ERR_ILLEGAL_KKC"
    elif input_dim == 0:
        return False, "ERR_ILLEGAL_KKC"

    expected_tiles = _ceil_div(input_dim, V2B_NUM_INPUTS) if input_dim > 0 else 0
    expected_last = (
        input_dim - V2B_NUM_INPUTS * (expected_tiles - 1)
        if expected_tiles > 0 else 0
    )
    if c["tile_count"] != expected_tiles or c["last_tile_valid_count"] != expected_last:
        return False, "ERR_TILE_CFG_MISMATCH"

    if not flatten:
        expected_out_h = _out_dim(h, k, stride, pad) if stride else 0
        expected_out_w = _out_dim(w, k, stride, pad) if stride else 0
        bad_geometry = (
            k not in (3, 5)
            or stride not in (1, 2)
            or pad < 0
            or pad > 2
            or h <= 0
            or w <= 0
            or h > V2B_CONV_MAX_H
            or w > V2B_CONV_MAX_W
            or c_in <= 0
            or c["out_H"] <= 0
            or c["out_W"] <= 0
            or c["out_H"] > V2B_CONV_MAX_H
            or c["out_W"] > V2B_CONV_MAX_W
            or h + 2 * pad < k
            or w + 2 * pad < k
            or c["out_H"] != expected_out_h
            or c["out_W"] != expected_out_w
        )
    else:
        bad_geometry = (
            h <= 0
            or w <= 0
            or h > V2B_CONV_MAX_H
            or w > V2B_CONV_MAX_W
            or c_in <= 0
        )
    if bad_geometry:
        return False, "ERR_BAD_GEOMETRY"

    if t_count <= 0 or t_count > V2B_MAX_TIMESTEPS:
        return False, "ERR_BAD_T"

    if c_out <= 0 or c_out > V2B_MAX_OUT_NEURONS:
        return False, "ERR_BAD_COUT"

    input_words = fmap_size_words(h, w, c_in, t_count)
    if c["base_word"] + input_words > c["bank_words"]:
        return False, "ERR_FMAP_OOB"
    if not flatten:
        output_words = fmap_size_words(c["out_H"], c["out_W"], c_out, t_count)
        if c["out_base_word"] + output_words > c["bank_words"]:
            return False, "ERR_FMAP_OOB"

    if bool(c.get("busy", False)) and bool(c.get("fmap_wr_commit", False)):
        return False, "ERR_FMAP_WRITE_WHILE_BUSY"

    if bool(c.get("weight_timeout_en", False)):
        cycles = _get_int(c, "weight_wait_cycles", default=0)
        limit = _get_int(c, "weight_timeout_cycles", default=V2B_WEIGHT_TIMEOUT_CYCLES)
        if cycles > limit:
            return False, "ERR_WEIGHT_TIMEOUT"

    if bool(c.get("fmap_wr_commit", False)):
        wr_addr = _get_int(c, "fmap_wr_addr", default=0)
        if wr_addr < 0 or wr_addr >= c["bank_words"]:
            return False, "ERR_FMAP_WR_OOB"

    return True, "OK"


def validate_conv_cfg_num(cfg: dict) -> tuple[bool, int]:
    ok, err = validate_conv_cfg(cfg)
    return ok, ERR_CODES[err]


def encode_image_to_spike_fmap(
    image: np.ndarray,
    t_count: int,
    *,
    method: str = "even_rate",
) -> np.ndarray:
    """Encode ``[H, W]`` or ``[H, W, C]`` uint8 pixels into ``[H, W, C, T]``."""
    img = np.asarray(image, dtype=np.int64)
    if img.ndim == 2:
        img = img[:, :, None]
    if img.ndim != 3:
        raise ValueError(f"image must be [H, W] or [H, W, C], got {img.shape}")
    h, w, c = img.shape
    stream_t_in = encode_pixel_to_spike_stream(img.reshape(-1), int(t_count), method=method)
    return stream_t_in.reshape(int(t_count), h, w, c).transpose(1, 2, 3, 0).astype(np.int64)


def wordline_to_u32_words(wl: np.ndarray) -> list[str]:
    """Return the 256-bit WL as eight little-lane-order 32-bit hex words."""
    arr = np.asarray(wl, dtype=np.int64).reshape(V2B_NUM_INPUTS)
    words: list[str] = []
    for word_idx in range(8):
        value = 0
        for bit in range(32):
            lane = word_idx * 32 + bit
            if int(arr[lane]):
                value |= 1 << bit
        words.append(f"{value:08x}")
    return words


def load_unsigned_weight_hex(path: str | Path) -> np.ndarray:
    """Load one unsigned split-weight HEX file with values in ``[0, 7]``."""
    values: list[int] = []
    with Path(path).open("r", encoding="ascii") as f:
        for line in f:
            text = line.strip()
            if not text or text.startswith("#"):
                continue
            value = int(text, 16)
            if not 0 <= value <= 7:
                raise ValueError(f"{path}: value {text!r} is outside [0, 7]")
            values.append(value)
    return np.asarray(values, dtype=np.int32)


def load_weight_tile(
    case_id: str,
    layer_id: str,
    tile_idx: int,
    *,
    c_out: int,
    out_dir: str | Path = ".",
) -> np.ndarray:
    """Load one signed tile from FC-style ``*_pos.hex``/``*_neg.hex`` files."""
    del layer_id
    base = Path(out_dir)
    pos_path = base / f"synthetic_{case_id}_weight_tile_{int(tile_idx)}_pos.hex"
    neg_path = base / f"synthetic_{case_id}_weight_tile_{int(tile_idx)}_neg.hex"
    pos = load_unsigned_weight_hex(pos_path)
    neg = load_unsigned_weight_hex(neg_path)
    expected = V2B_NUM_INPUTS * int(c_out)
    if pos.shape[0] != expected:
        raise ValueError(f"{pos_path} has {pos.shape[0]} entries, expected {expected}")
    if neg.shape[0] != expected:
        raise ValueError(f"{neg_path} has {neg.shape[0]} entries, expected {expected}")
    signed = pos.astype(np.int32) - neg.astype(np.int32)
    if np.any(signed < -7) or np.any(signed > 7):
        raise ValueError("pos-neg reconstructed weights outside [-7, 7]")
    return signed.reshape(V2B_NUM_INPUTS, int(c_out)).astype(np.int64)


def load_weight_tiles(
    case_id: str,
    layer_id: str,
    tile_count: int,
    *,
    c_out: int,
    out_dir: str | Path = ".",
) -> np.ndarray:
    """Load all split HEX tiles for one synthetic case."""
    tiles = [
        load_weight_tile(case_id, layer_id, tile_idx, c_out=c_out, out_dir=out_dir)
        for tile_idx in range(int(tile_count))
    ]
    return np.stack(tiles, axis=0).astype(np.int64)


def patch_gather_from_words(
    fmap_words: np.ndarray,
    cfg: dict,
    *,
    out_h: int,
    out_w: int,
    timestep: int,
    tile_idx: int,
) -> tuple[np.ndarray, int]:
    """Gather one 256-lane dynamic WL for a CONV patch."""
    c = derive_conv_cfg(cfg)
    k = c["K"]
    c_in = c["C_in"]
    valid_count = _valid_count(k * k * c_in, tile_idx)
    wl = np.zeros(V2B_NUM_INPUTS, dtype=np.int64)
    for lane in range(valid_count):
        conv_idx = int(tile_idx) * V2B_NUM_INPUTS + lane
        channel = conv_idx % c_in
        k_idx = conv_idx // c_in
        ky = k_idx // k
        kx = k_idx % k
        in_h = int(out_h) * c["stride"] + ky - c["pad"]
        in_w = int(out_w) * c["stride"] + kx - c["pad"]
        if 0 <= in_h < c["H"] and 0 <= in_w < c["W"]:
            wl[lane] = get_fmap_bit(
                fmap_words,
                h=in_h,
                w=in_w,
                c=channel,
                t=timestep,
                width=c["W"],
                channels=c_in,
                t_count=c["T"],
                base_word=c["base_word"],
            )
    return wl, valid_count


def flatten_gather_from_words(
    fmap_words: np.ndarray,
    cfg: dict,
    *,
    timestep: int,
    tile_idx: int,
) -> tuple[np.ndarray, int]:
    """Gather one 256-lane dynamic WL for a row-major flatten reader."""
    c = derive_conv_cfg({**cfg, "flatten_mode": True})
    input_dim = c["H"] * c["W"] * c["C_in"]
    valid_count = _valid_count(input_dim, tile_idx)
    wl = np.zeros(V2B_NUM_INPUTS, dtype=np.int64)
    for lane in range(valid_count):
        flat_idx = int(tile_idx) * V2B_NUM_INPUTS + lane
        channel = flat_idx % c["C_in"]
        pixel = flat_idx // c["C_in"]
        h = pixel // c["W"]
        w = pixel % c["W"]
        wl[lane] = get_fmap_bit(
            fmap_words,
            h=h,
            w=w,
            c=channel,
            t=timestep,
            width=c["W"],
            channels=c["C_in"],
            t_count=c["T"],
            base_word=c["base_word"],
        )
    return wl, valid_count


def _check_weight_tiles(weight_tiles: np.ndarray, tile_count: int, c_out: int) -> np.ndarray:
    tiles = np.asarray(weight_tiles, dtype=np.int64)
    if tiles.shape != (tile_count, V2B_NUM_INPUTS, c_out):
        raise ValueError(
            f"weight_tiles shape {tiles.shape} != ({tile_count}, {V2B_NUM_INPUTS}, {c_out})"
        )
    if np.any(tiles < -7) or np.any(tiles > 7):
        raise ValueError("weight_tiles must be signed 4-bit values in [-7, 7]")
    return tiles


def _mac_signed(wl: np.ndarray, weights: np.ndarray) -> np.ndarray:
    return (np.asarray(wl, dtype=np.int64) @ np.asarray(weights, dtype=np.int64)).astype(np.int64)


def _check_partial_bound(partial: np.ndarray, *, context: str) -> None:
    max_abs = int(np.max(np.abs(partial))) if partial.size else 0
    if max_abs > V2B_PARTIAL_ABS_LIMIT:
        raise PartialSumOverflowError(
            f"{context}: abs(partial_sum)={max_abs} exceeds 14-bit signed limit "
            f"{V2B_PARTIAL_ABS_LIMIT}"
        )


def run_conv_layer(
    input_words: np.ndarray,
    cfg: dict,
    weight_tiles: np.ndarray,
    *,
    collect_trace: bool = False,
) -> ConvRunResult:
    """Run one CONV layer using the activation-stationary RTL order."""
    ok, err = validate_conv_cfg(cfg)
    if not ok:
        raise ConvConfigError(err)
    c = derive_conv_cfg(cfg)
    tiles = _check_weight_tiles(weight_tiles, c["tile_count"], c["C_out"])

    output_word_count = c["out_base_word"] + fmap_size_words(
        c["out_H"], c["out_W"], c["C_out"], c["T"]
    )
    output_words = np.zeros(output_word_count, dtype=np.uint32)
    output_spikes = np.zeros((c["out_H"], c["out_W"], c["C_out"], c["T"]), dtype=np.int64)
    trace: dict[str, Any] = {}

    for oh in range(c["out_H"]):
        for ow in range(c["out_W"]):
            partial = np.zeros((c["T"], c["C_out"]), dtype=np.int64)
            membrane = np.zeros(c["C_out"], dtype=np.int64)
            pixel_spikes_tc = np.zeros((c["T"], c["C_out"]), dtype=np.int64)

            for tile_idx in range(c["tile_count"]):
                tile_weights = tiles[tile_idx]
                is_last_tile = tile_idx == c["tile_count"] - 1
                for t in range(c["T"]):
                    wl, valid_count = patch_gather_from_words(
                        input_words, c,
                        out_h=oh,
                        out_w=ow,
                        timestep=t,
                        tile_idx=tile_idx,
                    )
                    # Lanes outside valid_count must be zero, and weights for
                    # those lanes are ignored by multiplying with the zero WL.
                    if valid_count < V2B_NUM_INPUTS:
                        wl[valid_count:] = 0
                    diff = _mac_signed(wl, tile_weights)
                    partial[t] += diff
                    _check_partial_bound(partial[t], context=f"oh={oh} ow={ow} t={t}")

                    if collect_trace and oh == 0 and ow == 0 and tile_idx == 0 and t == 0:
                        trace["patch0_words_hex"] = wordline_to_u32_words(wl)
                        trace["weight_tile0_lane0_15"] = (
                            tile_weights[:16, : min(8, c["C_out"])].astype(int).tolist()
                        )
                        trace["partial_t0_after_tile0"] = (
                            partial[0, : min(8, c["C_out"])].astype(int).tolist()
                        )

                    if is_last_tile:
                        membrane += partial[t]
                        fired = membrane >= c["threshold"]
                        pixel_spikes_tc[t, :] = fired.astype(np.int64)
                        membrane[fired] -= c["threshold"]

                        if collect_trace and oh == 0 and ow == 0 and t == 0:
                            trace["partial_t0_final"] = (
                                partial[0, : min(8, c["C_out"])].astype(int).tolist()
                            )
                            trace["spike_t0"] = (
                                pixel_spikes_tc[0, : min(8, c["C_out"])].astype(int).tolist()
                            )

            # Membrane resets implicitly here at the next spatial pixel.
            for t in range(c["T"]):
                for out_c in range(c["C_out"]):
                    bit = int(pixel_spikes_tc[t, out_c])
                    output_spikes[oh, ow, out_c, t] = bit
                    set_fmap_bit(
                        output_words,
                        h=oh,
                        w=ow,
                        c=out_c,
                        t=t,
                        value=bit,
                        width=c["out_W"],
                        channels=c["C_out"],
                        t_count=c["T"],
                        base_word=c["out_base_word"],
                    )

            if collect_trace and oh == 0 and ow == 0:
                trace["count_h0_w0"] = (
                    pixel_spikes_tc.sum(axis=0)[: min(8, c["C_out"])].astype(int).tolist()
                )

    output_counts = output_spikes.sum(axis=3).astype(np.int64)
    return ConvRunResult(output_words, output_spikes, output_counts, trace)


def run_flatten_fc_stage(
    input_words: np.ndarray,
    cfg: dict,
    weight_tiles: np.ndarray,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Run the CONV->FC flatten path with the same tile/LIF ordering."""
    flatten_cfg = derive_conv_cfg({**cfg, "flatten_mode": True})
    ok, err = validate_conv_cfg(flatten_cfg)
    if not ok:
        raise ConvConfigError(err)
    tiles = _check_weight_tiles(weight_tiles, flatten_cfg["tile_count"], flatten_cfg["C_out"])

    partial = np.zeros((flatten_cfg["T"], flatten_cfg["C_out"]), dtype=np.int64)
    membrane = np.zeros(flatten_cfg["C_out"], dtype=np.int64)
    spike_stream = np.zeros((flatten_cfg["T"], flatten_cfg["C_out"]), dtype=np.int64)

    for tile_idx in range(flatten_cfg["tile_count"]):
        is_last_tile = tile_idx == flatten_cfg["tile_count"] - 1
        for t in range(flatten_cfg["T"]):
            wl, valid_count = flatten_gather_from_words(
                input_words, flatten_cfg, timestep=t, tile_idx=tile_idx
            )
            if valid_count < V2B_NUM_INPUTS:
                wl[valid_count:] = 0
            partial[t] += _mac_signed(wl, tiles[tile_idx])
            _check_partial_bound(partial[t], context=f"flatten t={t}")
            if is_last_tile:
                membrane += partial[t]
                fired = membrane >= flatten_cfg["threshold"]
                spike_stream[t, :] = fired.astype(np.int64)
                membrane[fired] -= flatten_cfg["threshold"]

    return spike_stream.sum(axis=0).astype(np.int64), membrane, spike_stream


def run_conv_chain(
    input_words: np.ndarray,
    layers: list[tuple[dict, np.ndarray]],
) -> ConvRunResult:
    """Run a simple ping-pong chain of CONV layers."""
    bank_a = np.asarray(input_words, dtype=np.uint32).copy()
    bank_b = np.zeros_like(bank_a)
    last_result: ConvRunResult | None = None
    read_a = True
    for layer_idx, (cfg, weights) in enumerate(layers):
        source = bank_a if read_a else bank_b
        result = run_conv_layer(source, cfg, weights)
        if read_a:
            bank_b = result.output_words
        else:
            bank_a = result.output_words
        read_a = not read_a
        last_result = result
    if last_result is None:
        raise ValueError("layers must not be empty")
    return last_result


def run_synthetic_smoke() -> bool:
    """Small no-file smoke test used by the M1 gate."""
    rng = np.random.default_rng(0xC01D)
    h, w, c_in, t_count = 4, 4, 3, 10
    image = rng.integers(0, 256, size=(h, w, c_in), dtype=np.int64)
    spikes = encode_image_to_spike_fmap(image, t_count)
    input_words = pack_spike_fmap(spikes)
    cfg = {
        "K": 3,
        "stride": 1,
        "pad": 1,
        "C_in": c_in,
        "C_out": 5,
        "H": h,
        "W": w,
        "out_H": h,
        "out_W": w,
        "T": t_count,
        "tile_count": 1,
        "last_tile_valid_count": 27,
        "threshold": 4,
    }
    weights = rng.integers(-3, 4, size=(1, V2B_NUM_INPUTS, 5), dtype=np.int64)
    weights[:, 27:, :] = 0
    result = run_conv_layer(input_words, cfg, weights, collect_trace=True)
    if result.output_counts.shape != (h, w, 5):
        return False
    if result.output_spikes.shape != (h, w, 5, t_count):
        return False
    return validate_conv_cfg({"K": 5, "C_in": 128, "C_out": 16, "H": 8, "W": 8, "T": 10}) == (
        False,
        "ERR_ILLEGAL_KKC",
    )


__all__ = [
    "ConvConfigError",
    "ConvRunResult",
    "ERR_CODES",
    "ERR_NAMES_BY_CODE",
    "PartialSumOverflowError",
    "derive_conv_cfg",
    "encode_image_to_spike_fmap",
    "err_code_name",
    "err_code_num",
    "flatten_gather_from_words",
    "load_unsigned_weight_hex",
    "load_weight_tile",
    "load_weight_tiles",
    "patch_gather_from_words",
    "run_conv_chain",
    "run_conv_layer",
    "run_flatten_fc_stage",
    "run_synthetic_smoke",
    "validate_conv_cfg",
    "validate_conv_cfg_num",
    "wordline_to_u32_words",
]
