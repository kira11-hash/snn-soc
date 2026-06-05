"""
V2C weight encoding / codebook + digital-CIM accumulator (per encoding width W).

V2C is a *digital binary* RRAM-CIM: every bit-cell stores 1 bit; a logical weight
is bit-sliced across ``W`` binary cells (W = cells/weight). The MAC is done in the
digital domain by popcount/shift-add over the cells of the *active* (spiking) rows
— there is no analog current summation and no multi-bit ADC.

Three encodings (see plan-v1.md「编码↔累积」表 / V2C_设计决策与权衡记录.md §3):

    W = 1  BNN              weights {-1, +1}           1 cell : cell=1 -> +1, cell=0 -> -1
    W = 2  ternary          weights {-1, 0, +1}        2 cells (pos, neg)
    W >= 4 two's-complement weights int[-2^(W-1), 2^(W-1)-1]   W cells = W bit-planes

Per-output MAC partial sum over active rows (this is exactly what the RTL macro does):

    W = 1  : 2*popcount(cell==1) - N_active
    W = 2  : popcount(pos==1) - popcount(neg==1)
    W >= 4 : sum_k 2^k * popcount(bitplane_k==1),  with k = W-1 (MSB) negated

Physical column layout (one layer): ``col = out_idx * W + bit_idx``. The per-layer
``layer_base`` offset for single-macro multi-layer residency is applied by the
caller (placement), not here. Logical output budget = ARRAY_COLS // W.

ternary codebook:  +1=(pos,neg)=(1,0)  -1=(0,1)  0=(0,0)  (1,1)=ILLEGAL.
Ideal :func:`pack` never produces (1,1) (asserted). A non-ideal (1,1) (e.g. from an
injected bit-flip / stuck-at) decodes to 0 — the popcount-difference accumulator
naturally yields 0 — and is *counted* by :func:`count_ternary_illegal` so it is
never silently absorbed (see round-3 review, decisions §10).

Pure numpy. No torch, no analog physics, no ADC. This is the bit-exact golden the
RTL CIM macro must match in ideal mode.
"""
from __future__ import annotations

import numpy as np

ARRAY_COLS = 1024  # physical bit-cell columns per macro


def value_range(W: int) -> tuple[int, int]:
    """Inclusive (min, max) representable weight value for encoding width ``W``."""
    if W == 1:
        return (-1, 1)  # BNN {-1,+1}; 0 not representable
    if W == 2:
        return (-1, 1)  # ternary {-1,0,+1}
    if W >= 4:
        half = 1 << (W - 1)
        return (-half, half - 1)  # two's-complement
    raise ValueError(f"unsupported encoding width W={W} (use 1, 2, or >=4)")


def outputs_per_macro(W: int) -> int:
    """Logical outputs that fit in one 1024-col macro at width ``W``."""
    return ARRAY_COLS // W


def _check_range(w: np.ndarray, W: int) -> None:
    lo, hi = value_range(W)
    if w.size and (int(w.min()) < lo or int(w.max()) > hi):
        raise ValueError(f"weights out of range [{lo},{hi}] for W={W}")
    if W == 1 and np.any(w == 0):
        raise ValueError("BNN (W=1) cannot represent weight 0")


def _bin_ok(a) -> bool:
    """True iff every element is 0 or 1."""
    a = np.asarray(a)
    return bool(np.all((a == 0) | (a == 1)))


def pack(w: np.ndarray, W: int) -> np.ndarray:
    """Encode integer weights ``w[in_dim, out_dim]`` -> binary cells ``[in_dim, out_dim*W]``.

    Column ``out*W + bit``. uint8 in {0,1}.
    """
    w0 = np.asarray(w)
    if not np.issubdtype(w0.dtype, np.integer) and not np.all(w0 == np.rint(w0)):
        raise ValueError("weights must be integer-valued (quantize before pack)")
    w = w0.astype(np.int64)
    if w.ndim != 2:
        raise ValueError("w must be 2-D [in_dim, out_dim]")
    _check_range(w, W)
    in_dim, out_dim = w.shape
    cells = np.zeros((in_dim, out_dim * W), dtype=np.uint8)
    if W == 1:  # BNN: cell = (w == +1)
        cells[:] = (w == 1).astype(np.uint8)
    elif W == 2:  # ternary: col0=pos(w==+1), col1=neg(w==-1)
        cells[:, 0::2] = (w == 1).astype(np.uint8)
        cells[:, 1::2] = (w == -1).astype(np.uint8)
        assert not np.any((cells[:, 0::2] == 1) & (cells[:, 1::2] == 1)), \
            "ideal pack produced ternary (1,1) — bug"
    else:  # two's-complement, W bit-planes
        wu = (w & ((1 << W) - 1)).astype(np.int64)  # two's-complement bit pattern
        for k in range(W):
            cells[:, k::W] = ((wu >> k) & 1).astype(np.uint8)
    return cells


def unpack(cells: np.ndarray, W: int, out_dim: int) -> np.ndarray:
    """Ideal decode ``cells[in_dim, out_dim*W]`` -> ``w[in_dim, out_dim]``.

    A ternary (1,1) illegal cell decodes to 0 (use :func:`count_ternary_illegal`
    to detect/count it).
    """
    cells = np.asarray(cells)
    if cells.ndim != 2 or cells.shape[1] != out_dim * W:
        raise ValueError(f"cells shape {cells.shape} != (in_dim, out_dim*W={out_dim * W})")
    cells = cells.astype(np.int64)
    in_dim = cells.shape[0]
    if W == 1:
        return np.where(cells == 1, 1, -1).astype(np.int64)
    if W == 2:
        pos = cells[:, 0::2]
        neg = cells[:, 1::2]
        return (pos - neg).astype(np.int64)  # (1,1) -> 0
    wu = np.zeros((in_dim, out_dim), dtype=np.int64)
    for k in range(W):
        wu |= (cells[:, k::W] & 1) << k
    sign = 1 << (W - 1)
    return (wu - ((wu & sign) << 1)).astype(np.int64)  # two's-complement -> signed


def count_ternary_illegal(cells: np.ndarray) -> int:
    """Number of (pos=1 AND neg=1) illegal ternary cells (W=2 only)."""
    cells = np.asarray(cells)
    pos = cells[:, 0::2]
    neg = cells[:, 1::2]
    return int(np.count_nonzero((pos == 1) & (neg == 1)))


def mac(spikes: np.ndarray, cells: np.ndarray, W: int, out_dim: int) -> np.ndarray:
    """Digital-CIM MAC partial sum over active (spiking) rows, per output.

    Implements the per-W popcount accumulator (what the RTL macro computes). Equals
    ``spikes @ unpack(cells, W, out_dim)`` for legal codewords.

    spikes : 0/1 array ``[in_dim]`` (rows active this step).
    cells  : uint8 ``[in_dim, out_dim*W]``.
    return : int64 array ``[out_dim]``.
    """
    s_arr = np.asarray(spikes)
    cells_a = np.asarray(cells)
    if s_arr.ndim != 1:
        raise ValueError("spikes must be 1-D [in_dim]")
    if cells_a.ndim != 2 or cells_a.shape != (s_arr.shape[0], out_dim * W):
        raise ValueError(
            f"cells shape {cells_a.shape} != (in_dim={s_arr.shape[0]}, out_dim*W={out_dim * W})")
    if not _bin_ok(s_arr) or not _bin_ok(cells_a):
        raise ValueError("spikes and cells must be binary {0,1}")
    s = s_arr.astype(np.int64).reshape(-1, 1)  # [in_dim,1]
    cells = cells_a.astype(np.int64)
    n_active = int(s.sum())
    if W == 1:  # 2*popcount(1) - N_active
        pc = (s * cells).sum(axis=0)
        return (2 * pc - n_active).astype(np.int64)
    if W == 2:  # popcount(pos) - popcount(neg)
        pos = (s * cells[:, 0::2]).sum(axis=0)
        neg = (s * cells[:, 1::2]).sum(axis=0)
        return (pos - neg).astype(np.int64)
    out = np.zeros(out_dim, dtype=np.int64)  # sum_k sign_k 2^k popcount_k, MSB negated
    for k in range(W):
        pc = (s * cells[:, k::W]).sum(axis=0)
        wk = 1 << k
        out = out - wk * pc if k == W - 1 else out + wk * pc
    return out
