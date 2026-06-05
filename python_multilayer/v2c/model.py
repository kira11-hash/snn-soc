"""
V2C quantized MLP (reference) + the shared :class:`QuantLinear`.

:class:`QuantLinear` is an FC layer whose weights are fake-quantized to the V2C cell encoding
(``qat.lsq_quantize_weight`` with a per-output learned step size). It is the weight container reused
by the deployed spiking net (``spiking.V2CSpikingMLP``); :meth:`export_int` gives the integer weights
for ``encoding.pack``.

:class:`V2CMLP` stacks QuantLinears with float ReLU activations — the *reference quantized ANN*
(graded-activation upper bound). It is NOT the deployed V2C path: a graded ReLU ANN does not convert
to the non-monotonic TTFS-IF forward (see spiking.py / PROGRESS.md). The deployed path trains the
spiking net directly with surrogate gradients.

Networks (plan-v1.md §网络):
  * main      784 -> 246 -> 10   (W=4 fills 256/256 output columns, ~74% cell utilisation)
  * ablation  784 -> 160 -> 80 -> 10  (deeper FC; ~53% utilisation — the wide-shallow tradeoff)
torch-only.
"""
from __future__ import annotations

import math

import torch
import torch.nn as nn
import torch.nn.functional as F

try:  # package import (python_multilayer.v2c.model)
    from . import qat
except ImportError:  # direct-module import (v2c dir on sys.path) — tests / venv
    import qat

ARCHS = {
    "main": [784, 246, 10],
    "ablation": [784, 160, 80, 10],
}


class QuantLinear(nn.Module):
    """FC layer with V2C weight quantization (per-output LSQ step size) and an optional bias.

    Training forward uses the dequantized weights (differentiable STE); :meth:`export_int` returns
    the integer weights for ``encoding.pack``. The per-output step size ``scale`` is parameterised
    through softplus of a raw ``log_scale`` so it is always strictly positive — a plain clamped
    Parameter can be pushed <=0 by the optimiser and then sits in a zero-gradient dead zone.
    """

    def __init__(self, in_features: int, out_features: int, W: int, bias: bool = True,
                 weight_standardize: bool = False):
        super().__init__()
        self.in_features = in_features
        self.out_features = out_features
        self.W = W
        self.weight_standardize = weight_standardize
        self.weight = nn.Parameter(torch.empty(out_features, in_features))
        self.bias = nn.Parameter(torch.zeros(out_features)) if bias else None
        self.log_scale = nn.Parameter(torch.zeros(out_features, 1))
        self.reset_parameters()

    @property
    def scale(self) -> torch.Tensor:
        """Positive per-output LSQ step size = ``softplus(log_scale)`` (never <=0, no dead zone)."""
        return F.softplus(self.log_scale)

    def effective_weight(self) -> torch.Tensor:
        """The weight that is actually quantized/deployed. With ``weight_standardize`` each output's
        weights are centered + unit-scaled (Qiao 2019) — this controls the per-output membrane
        variance and stabilises TTFS-IF training. Deterministic from ``weight`` so export stays
        consistent (the standardised weights are what gets quantized and packed)."""
        w = self.weight
        if self.weight_standardize:
            w = w - w.mean(dim=1, keepdim=True)
            w = w * torch.rsqrt(w.var(dim=1, keepdim=True, unbiased=False) + 1e-5)
        return w

    def reset_parameters(self) -> None:
        nn.init.kaiming_normal_(self.weight, nonlinearity="relu")
        with torch.no_grad():
            s = qat.suggested_lsq_scale(self.effective_weight(), self.W, per_output=True).clamp(min=1e-6)
            self.log_scale.copy_(torch.log(torch.expm1(s)))                # softplus^{-1}(s)
        if self.bias is not None:
            nn.init.zeros_(self.bias)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        w_q, _ = qat.lsq_quantize_weight(self.effective_weight(), self.scale, self.W)
        return F.linear(x, w_q, self.bias)

    @torch.no_grad()
    def export_int(self) -> torch.Tensor:
        """Integer weights ``[out_features, in_features]`` in ``encoding.value_range(W)``."""
        _, w_int = qat.lsq_quantize_weight(self.effective_weight(), self.scale, self.W)
        return w_int


def _quant_unsigned(x: torch.Tensor, bits, hi: float = 1.0) -> torch.Tensor:
    """Uniform [0,hi] -> ``bits`` levels with a straight-through gradient. ``bits=None`` -> identity.
    Used to model the V2C multi-bit (bit-serial) INPUT and phase-coded hidden ACTIVATIONS in the
    reference ANN, so its accuracy maps the precision-vs-accuracy Pareto the spiking net trades on."""
    if bits is None:
        return x
    levels = (1 << bits) - 1
    xc = x.clamp(0.0, hi) * (levels / hi)
    xq = (torch.round(xc) - xc).detach() + xc                    # STE round
    return xq * (hi / levels)


class V2CMLP(nn.Module):
    """Stack of :class:`QuantLinear` with ReLU between hidden layers; returns logits.

    dims : layer sizes, e.g. ``[784, 246, 10]``. W : int (shared) or per-layer list.
    input_bits / act_bits : quantize the (in [0,1]) input and the ReLU hidden activations to N bits
    (``None`` = full precision) — this lets the reference ANN emulate the V2C multi-bit-input /
    multi-bit-hidden precision so its accuracy is the achievable ceiling for that precision.
    """

    def __init__(self, dims, W, bias: bool = True, input_bits=None, act_bits=None, act_hi: float = 4.0):
        super().__init__()
        if len(dims) < 2:
            raise ValueError("dims must have >= 2 entries (in, ..., out)")
        n_layers = len(dims) - 1
        widths = W if isinstance(W, (list, tuple)) else [W] * n_layers
        if len(widths) != n_layers:
            raise ValueError(f"W list length {len(widths)} != number of layers {n_layers}")
        self.dims = list(dims)
        self.widths = list(widths)
        self.input_bits = input_bits
        self.act_bits = act_bits
        self.act_hi = act_hi
        self.layers = nn.ModuleList(
            QuantLinear(dims[i], dims[i + 1], widths[i], bias=bias) for i in range(n_layers)
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = _quant_unsigned(x, self.input_bits, hi=1.0)             # multi-bit input
        last = len(self.layers) - 1
        for i, layer in enumerate(self.layers):
            x = layer(x)
            if i != last:
                x = _quant_unsigned(F.relu(x), self.act_bits, hi=self.act_hi)   # multi-bit hidden act
        return x


def make_mlp(arch: str = "main", W=4, bias: bool = True, **kwargs) -> V2CMLP:
    """Build a V2C MLP by name (``"main"`` / ``"ablation"``) at encoding width ``W``."""
    if arch not in ARCHS:
        raise ValueError(f"unknown arch {arch!r}; use one of {sorted(ARCHS)}")
    return V2CMLP(ARCHS[arch], W, bias=bias, **kwargs)
