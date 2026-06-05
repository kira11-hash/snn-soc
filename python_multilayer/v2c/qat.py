"""
V2C QAT weight quantization (straight-through estimator) — bridges float training weights to the
V2C cell encoding. Produces integer weights in ``encoding.value_range(W)`` (so they feed straight
into ``encoding.pack``) plus a per-tensor positive ``scale`` (folded into the layer threshold at
inference, since the V2C digital-CIM MAC is integer-only).

    W=1  BNN              w_int in {-1,+1}                       sign + hard-tanh STE  (Courbariaux 2016)
    W=2  ternary (TWN)    w_int in {-1,0,+1}                     |w|>Δ (Δ=0.7·E|w|) + identity STE (Li 2016)
    W>=4 two's-complement w_int in [-(2^(W-1)-1), 2^(W-1)-1]     SYMMETRIC uniform round/clamp + STE
                          (symmetric signed quantization: scale=max|w|/qmax maps the largest weight
                           to ±qmax, so the most-negative code -2^(W-1) — legal in the cell encoding —
                           is reserved and never emitted; avoids zero-point asymmetry.)

Training forward uses ``w_q = w_int * scale`` (differentiable via STE); export uses ``w_int``
(integer, for ``encoding.pack``) and ``scale`` (to fold into the threshold). torch-only.

Two quantizers live here:
  * :func:`quantize_weight`      — stateless per-tensor max baseline (scale derived from |w|).
  * :func:`lsq_quantize_weight`  — per-output **learned** step size (LSQ, Esser 2020), the
                                   accuracy path used by ``model.QuantLinear``. The owning layer
                                   holds ``scale`` as a trainable ``[out,1]`` parameter; the
                                   per-output scale folds into a per-output integer **threshold**
                                   at inference (no inference-time BN / multiply — PPA-clean).
Both keep the SYMMETRIC two's-complement range ``[-(2^(W-1)-1), 2^(W-1)-1]`` for W>=4 (the
most-negative code -2^(W-1) stays reserved/unemitted), matching ``encoding`` + the RTL.
"""
import math

import torch


def _round_ste(x: torch.Tensor) -> torch.Tensor:
    """``round(x)`` with a straight-through (identity) gradient."""
    return (torch.round(x) - x).detach() + x


def _grad_scale(x: torch.Tensor, g: float) -> torch.Tensor:
    """Identity in the forward pass; scales the gradient by ``g`` in the backward pass.

    The LSQ step-size trick (Esser 2020 §3.3): the step size ``s`` sees a gradient scaled by
    ``g = 1/sqrt(n_weights * qmax)`` so it co-trains stably with the (much more numerous) weights.
    """
    return (x - x * g).detach() + x * g


def lsq_quantize_weight(w: torch.Tensor, scale: torch.Tensor, W: int):
    """LSQ fake-quantize ``w`` with an externally-held (learnable) ``scale``.

    ``w``     : float weights ``[out_features, in_features]`` (torch ``nn.Linear`` layout).
    ``scale`` : positive step size — scalar (per-tensor) or ``[out_features, 1]`` (per-output).
    Returns ``(w_q, w_int)``:
      w_q   : float (== ``w_int*scale``), differentiable — training forward.
      w_int : int64 in ``encoding.value_range(W)`` — for ``encoding.pack`` / export.

    W>=4 is a true uniform LSQ step (symmetric, STE round/clamp + step-size grad scaling).
    W=1 (BNN sign) and W=2 (ternary TWN) keep their non-uniform STE but take the per-output
    ``scale`` as a learnable magnitude (so the fold-to-threshold path is per-output for all W).
    """
    eps = 1e-8
    per_output = scale.numel() > 1
    if W >= 4:
        qmax = 2 ** (W - 1) - 1          # symmetric: reserve -2^(W-1)
        qmin = -qmax
        n = w.shape[1] if per_output else w.numel()   # weights sharing one step size
        s = _grad_scale(scale.clamp(min=eps), 1.0 / math.sqrt(n * qmax))
        v = _round_ste((w / s).clamp(qmin, qmax))      # integer-valued float, grad clipped at rails
        return v * s, v.detach().round().long()
    if W == 2:                          # ternary (TWN), per-output Δ + learnable per-output scale
        s = scale.clamp(min=eps)
        dim = 1 if per_output else None
        delta = (0.7 * w.detach().abs().mean(dim=dim, keepdim=per_output)).clamp(min=1e-12)
        w_int = (torch.sign(w) * (w.detach().abs() > delta).float())     # {-1,0,+1}
        w_q = w_int * s + (w - w.detach())             # forward w_int*s; grad: identity STE + d/ds
        return w_q, w_int.detach().long()
    if W == 1:                          # BNN, sign + hard-tanh STE, learnable per-output scale
        s = scale.clamp(min=eps)
        w_sign = torch.where(w >= 0, torch.ones_like(w), -torch.ones_like(w))   # {-1,+1}
        w_clip = (w / s).clamp(-1, 1) * s              # hard-tanh: grad only where |w/s|<=1
        w_q = w_sign * s + (w_clip - w_clip.detach())
        return w_q, w_sign.detach().long()
    raise ValueError(f"unsupported encoding width W={W} (use 1, 2, or >=4)")


def suggested_lsq_scale(w: torch.Tensor, W: int, per_output: bool = True) -> torch.Tensor:
    """LSQ step-size init (Esser 2020): ``2*mean(|w|)/sqrt(qmax)`` (W>=4); mean(|w|) for W<4.

    Returns ``[out_features,1]`` (per-output) or scalar — the initial value for the layer's
    learnable ``scale`` parameter.
    """
    if per_output:
        a = w.detach().abs().mean(dim=1, keepdim=True)
    else:
        a = w.detach().abs().mean()
    if W >= 4:
        return (2.0 * a / math.sqrt(2 ** (W - 1) - 1)).clamp(min=1e-8)
    return a.clamp(min=1e-8)


def quantize_weight(w: torch.Tensor, W: int):
    """Fake-quantize float weights ``w`` to the W-encoding.

    Returns ``(w_q, w_int, scale)``:
      w_q   : float tensor (== ``w_int*scale``), differentiable (STE) — use in the training forward.
      w_int : int64 tensor in ``encoding.value_range(W)`` — use for ``encoding.pack`` / export.
      scale : positive scalar tensor — fold into the layer threshold at inference.
    """
    if W >= 4:                                                  # SYMMETRIC uniform two's-complement (-qmax..qmax)
        qmax = 2 ** (W - 1) - 1
        qmin = -(2 ** (W - 1))
        scale = (w.detach().abs().max() / qmax).clamp(min=1e-8)
        w_int_f = _round_ste((w / scale).clamp(qmin, qmax))     # integer-valued float, grad clipped
        return w_int_f * scale, w_int_f.detach().round().long(), scale
    if W == 2:                                                  # ternary (TWN)
        delta = (0.7 * w.detach().abs().mean()).clamp(min=1e-12)
        mask = (w.abs() > delta).float()                        # kept (nonzero) weights
        nz = mask.sum().clamp(min=1.0)
        scale = ((w.detach().abs() * mask).sum() / nz).clamp(min=1e-8)
        w_int_hard = torch.sign(w) * mask                       # {-1,0,+1}
        w_q = (w_int_hard * scale - w).detach() + w             # identity STE
        return w_q, w_int_hard.detach().long(), scale
    if W == 1:                                                  # BNN, hard-tanh STE
        scale = w.detach().abs().mean().clamp(min=1e-8)
        w_sign = torch.where(w >= 0, torch.ones_like(w), -torch.ones_like(w))  # {-1,+1} (no 0)
        w_clip = (w / scale).clamp(-1, 1)
        w_q = (w_sign * scale - w_clip * scale).detach() + w_clip * scale      # grad where |w/scale|<=1
        return w_q, w_sign.detach().long(), scale
    raise ValueError(f"unsupported encoding width W={W} (use 1, 2, or >=4)")
