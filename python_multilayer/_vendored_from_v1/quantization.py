"""Vendored from V1 ``train_ann.py`` at 2026-04-19.

QAT (quantization-aware training) operators:
    * ``_fake_quantize_signed`` — STE fake quant (uses device levels if given)
    * ``_apply_qat_noise``      — Gaussian noise injection scaled by max_abs
    * ``_ir_drop_scale``        — IR-drop proxy scaling for input-dependent droop

Plus the V2-specific helper ``split_differential`` that mirrors V1 ``snn_engine``.

DO NOT EDIT. Must stay bit-identical to V1 so that QAT-trained weights match
V1's training pipeline exactly.

Source: d:/SoC Design/SoC Design/项目相关文件/器件对齐/Python建模/train_ann.py
"""

from __future__ import annotations

import torch


def fake_quantize_signed(
    weights: torch.Tensor,
    weight_bits: int,
    levels: torch.Tensor | None = None,
) -> torch.Tensor:
    """Signed fake quantization with straight-through estimator (STE).

    If ``levels`` is provided, use device conductance levels for magnitude;
    otherwise use linear uniform quantization to ``[-qmax, +qmax]``.

    Vendored verbatim from V1 ``train_ann._fake_quantize_signed``.
    """
    max_abs = weights.abs().max()
    if max_abs < 1e-12:
        return weights
    if levels is None:
        qmax = (2 ** (weight_bits - 1)) - 1
        if qmax <= 0:
            return weights
        step = max_abs / qmax
        w_q = torch.round(weights / step) * step
    else:
        sign = torch.sign(weights)
        mag = weights.abs() / max_abs
        # diff shape: [*weights.shape, len(levels)]
        diff = (mag.unsqueeze(-1) - levels.view(1, 1, -1)).abs()
        idx = diff.argmin(dim=-1)
        q_mag = levels[idx]
        w_q = sign * q_mag * max_abs
    # STE: pass through gradient as-if w_q == weights.
    return weights + (w_q - weights).detach()


def apply_qat_noise(w_q: torch.Tensor, noise_std: float) -> torch.Tensor:
    """Additive Gaussian noise during QAT (scaled by max_abs).

    Vendored verbatim from V1 ``train_ann._apply_qat_noise``.
    """
    if noise_std is None or noise_std <= 0:
        return w_q
    max_abs = w_q.abs().max()
    if max_abs < 1e-12:
        return w_q
    noise = torch.randn_like(w_q) * noise_std * max_abs
    return w_q + noise


def ir_drop_scale(inputs: torch.Tensor, coeff: float) -> torch.Tensor | None:
    """IR-drop proxy: scale per-sample based on mean input magnitude.

    Mimics V1 ``train_ann._ir_drop_scale``. Returns ``None`` when proxy is
    disabled (coeff <= 0).
    """
    if coeff is None or coeff <= 0:
        return None
    # Mean over features -> per-sample scalar in [~0, 1]; larger mean -> more droop.
    mean_mag = inputs.abs().mean(dim=1, keepdim=True)
    # Larger coeff -> stronger droop.
    return 1.0 - coeff * mean_mag


# ─────────────────────────────────────────────────────────────────────────
# Convenience helpers (not vendored verbatim; re-implementing the
# V1 differential split since V1 ``snn_engine.split_differential`` is shorter
# and cleaner to inline here than to sys.path-import the whole snn_engine).
# ─────────────────────────────────────────────────────────────────────────
def split_differential(W: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
    """Split a signed weight matrix into positive and negative halves.

    ``W_pos = max(W, 0)``, ``W_neg = max(-W, 0)``. Both non-negative.

    Mirrors V1 ``snn_engine.split_differential``. Copied here (not imported)
    because V1 ``snn_engine`` has heavy imports we don't need.
    """
    W_pos = W.clamp(min=0)
    W_neg = (-W).clamp(min=0)
    return W_pos, W_neg


def quantize_to_levels(
    W_half: torch.Tensor,
    weight_bits: int,
    levels: torch.Tensor | None = None,
) -> torch.Tensor:
    """Quantize a non-negative weight half-matrix to integer level indices.

    Args:
        W_half:      Non-negative weights (after ``split_differential``).
        weight_bits: Target bit-width (e.g., 4 => 16 levels).
        levels:      Optional device conductance levels, shape ``[2^weight_bits]``.
                     If given, snap to nearest. Otherwise uniform [0, 1].

    Returns:
        Integer level indices ``[0, 2^weight_bits - 1]``, same shape as input.

    The output is the level *index* (for exporting to HEX files), not the
    physical conductance. Export format: ``int(level_idx) in [0, 15]``.
    """
    max_abs = W_half.abs().max()
    if max_abs < 1e-12:
        return torch.zeros_like(W_half, dtype=torch.long)

    num_levels = 2 ** weight_bits
    if levels is None:
        # Uniform levels in [0, 1]
        level_vals = torch.linspace(0.0, 1.0, num_levels)
    else:
        level_vals = levels

    # Normalize to [0, 1], find nearest level index
    normalized = (W_half / max_abs).clamp(0.0, 1.0)
    # diff shape: [*W_half.shape, num_levels]
    diff = (normalized.unsqueeze(-1) - level_vals.view(1, 1, -1)).abs()
    idx = diff.argmin(dim=-1)  # [*W_half.shape] int indices
    return idx.long()
