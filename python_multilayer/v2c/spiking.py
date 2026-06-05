"""
V2C surrogate-gradient TTFS-IF training (the real accuracy path).

The naive route — train a graded ReLU ANN, then fold/calibrate thresholds into the TTFS forward —
fails: the V2C TTFS-IF dynamic (integrate from 0, fire on the FIRST membrane>=threshold crossing,
single spike) is non-monotonic under signed weights, so "fires by time T" != "final membrane>=θ",
and mean-negative membranes fire instantly at θ<=0. Accuracy collapses to chance regardless of
threshold calibration (see V2C_RTL_bug记录 / handoff diagnostics).

So we train *inside* the real dynamic with surrogate gradients (Neftci 2019): the forward here is
bit-identical to ``forward.multilayer_ttfs_forward`` (same integrate / first-spike-latch / single
spike / hidden spike-train -> next-layer input), only the hard spike step gets a smooth surrogate
derivative on the backward pass. Weights (LSQ-QAT), per-output thresholds, and spike *timing* all
co-adapt — and the input TTFS stream carries pixel intensity as spike timing, so grayscale is used.

Train/inference consistency is exact up to integer-threshold rounding:
  membrane_train = scale ⊙ membrane_inf  (per-output LSQ scale factors out of the integer MAC),
  so fire(membrane_train >= θ_train)  <=>  fire(membrane_inf >= θ_train/scale),
  and we export the per-output integer threshold ``θ_inf = round(θ_train/scale)`` — a per-neuron
  threshold register, no inference-time BN / multiply (PPA-clean). ``convert.export_v2c_layers``
  reads these; ``convert.eval_ttfs`` then runs the golden ``forward.py`` to confirm the match.
"""
from __future__ import annotations

import math

import torch
import torch.nn as nn
import torch.nn.functional as F

try:  # package import
    from . import qat
    from . import model as M
except ImportError:  # direct-module import (v2c on sys.path) — venv / tests
    import qat
    import model as M


class SpikeFn(torch.autograd.Function):
    """Heaviside spike (forward) with a fast-sigmoid surrogate derivative (backward).

    forward:  s = 1[x >= 0]               (x = membrane - threshold)
    backward: ds/dx ~ 1/(1 + beta*|x|)^2  (SuperSpike / fast-sigmoid surrogate, Zenke 2018)
    """

    @staticmethod
    def forward(ctx, x, beta):
        ctx.save_for_backward(x)
        ctx.beta = beta
        return (x >= 0).to(x.dtype)

    @staticmethod
    def backward(ctx, grad_out):
        (x,) = ctx.saved_tensors
        sg = 1.0 / (1.0 + ctx.beta * x.abs()) ** 2
        return grad_out * sg, None


def encode_stream(images01: torch.Tensor, T: int) -> torch.Tensor:
    """Pixels in [0,1] ``[B,in]`` -> binary TTFS spike stream ``[B,T,in]`` (brighter = earlier).

    Matches ``ttfs.encode_pixel_to_ttfs`` exactly: ``t = round((1-x)*(T-1))``, intensity 0 -> no
    spike. One spike per (sample, input) at its time; float {0,1} for the matmul.
    """
    if T < 1:
        raise ValueError("T must be >= 1")
    b, n = images01.shape
    times = torch.round((1.0 - images01.clamp(0, 1)) * (T - 1)).long()       # [B,in], brightest->0
    fire = (images01 > 0).to(images01.dtype)                                  # 0-intensity never fires
    stream = torch.zeros(b, T, n, device=images01.device, dtype=images01.dtype)
    stream.scatter_(1, times.unsqueeze(1), fire.unsqueeze(1))                 # stream[b, t_bi, i] = fire
    return stream


def encode_ramp(images01: torch.Tensor, T: int, in_bits: int = 4) -> torch.Tensor:
    """Multi-bit (phase / bit-serial) input encoding -> ``[B,T,in]`` (the SAME quantized grayscale
    value every timestep, so the first layer's membrane RAMPS as ``(t+1)·(x_q @ W)``).

    Unlike the single-spike TTFS encoding (grayscale only in spike *timing* -> membrane sum is binary
    -> capped at ~binary-image accuracy), this puts the pixel grayscale into the membrane SUM. In the
    digital binary CIM this is bit-serial input (``in_bits`` binary phase-planes + 2^k shift-add); the
    repeated-value form here gives the identical ramp membrane and is what the first layer integrates.
    The first layer is thus a full multi-bit MAC; hidden/output stay single-spike TTFS (BNN evidence:
    a high-precision first layer + binary hidden recovers most accuracy). Returns float ``[B,T,in]``.
    """
    if T < 1:
        raise ValueError("T must be >= 1")
    if in_bits < 1:
        raise ValueError("in_bits must be >= 1")
    levels = (1 << in_bits) - 1
    xq = torch.round(images01.clamp(0, 1) * levels)                          # [B,in] integer 0..levels
    return xq.unsqueeze(1).expand(-1, T, -1).contiguous()                    # [B,T,in] (ramp via repeat)


class V2CSpikingMLP(nn.Module):
    """TTFS-IF spiking MLP: ``QuantLinear`` weights + learnable per-output thresholds.

    forward(in_stream ``[B,T,in]``) -> ``(earliness[B,out], out_membrane[B,out], out_first_time[B,out])``
      * earliness_c = Σ_t (T-t)*out_spike[:,t,c]  — soft "fires early" score (classification loss).
      * out_membrane — final output membrane (no-spike fallback signal + loss stabiliser).
      * out_first_time — hard first-spike timestep per output (T if never) — for faithful eval.
    """

    def __init__(self, dims, W, T: int, beta: float = 5.0, thr_init: float = 1.0,
                 decode_gamma=None, ettfs_init: bool = False, weight_standardize: bool = False,
                 force_fire: bool = False):
        super().__init__()
        if len(dims) < 2:
            raise ValueError("dims must have >= 2 entries")
        n_layers = len(dims) - 1
        widths = W if isinstance(W, (list, tuple)) else [W] * n_layers
        if len(widths) != n_layers:
            raise ValueError(f"W list length {len(widths)} != layers {n_layers}")
        self.dims = list(dims)
        self.widths = list(widths)
        self.T = T
        self.beta = beta
        self.decode_gamma = decode_gamma                  # None -> linear decode; >1 -> exp γ^-t
        self.force_fire = force_fire                      # train-only: silent neurons fire at T-1
        self.layers = nn.ModuleList(
            M.QuantLinear(dims[i], dims[i + 1], widths[i], bias=False,
                          weight_standardize=weight_standardize) for i in range(n_layers)
        )
        # threshold parameterised through softplus to stay positive (a TTFS neuron must integrate
        # UP to a positive threshold; θ<=0 would fire at t=0 before any evidence accumulates).
        # NB the *scale* of the threshold must match the membrane scale, which depends on the weight
        # init — prefer :meth:`init_thresholds_from_data` over a fixed ``thr_init``.
        inv = torch.log(torch.expm1(torch.tensor(float(thr_init))))           # softplus^{-1}(thr_init)
        self.log_thr = nn.ParameterList(
            nn.Parameter(torch.full((dims[i + 1],), float(inv))) for i in range(n_layers)
        )
        if ettfs_init:
            self._ettfs_init()

    @torch.no_grad()
    def _ettfs_init(self):
        """T-aware weight init (ETTFS, arXiv 2410.23619): ``W ~ U(-√(3T/N_in), √(3T/N_in))`` gives
        ``Var(W)=T/N_in``, keeping the membrane variance ~constant across layers and decoupled from T
        (plain Kaiming is T-agnostic and leaves TTFS membranes badly scaled — the mean-negative /
        instant-fire pathology). Re-derives the LSQ ``log_scale`` from the new weights."""
        for layer in self.layers:
            a = math.sqrt(3.0 * self.T / layer.in_features)
            layer.weight.uniform_(-a, a)
            s = qat.suggested_lsq_scale(layer.weight, layer.W, per_output=True).clamp(min=1e-6)
            layer.log_scale.copy_(torch.log(torch.expm1(s)))

    @torch.no_grad()
    def init_thresholds_from_data(self, in_stream, fire_fraction: float = 0.5):
        """Data-driven per-output threshold init from a calibration batch: set each neuron's integer
        threshold to the ``(1-fire_fraction)`` quantile of its final membrane, so ~``fire_fraction``
        of samples make it fire. This decouples the threshold from the (init- and layer-dependent)
        membrane scale — the thing a fixed ``thr_init`` gets wrong (instant-fire when too low,
        never-fire when too high). Sequential: each layer's spikes feed the next."""
        x = in_stream
        q = float(min(max(1.0 - fire_fraction, 0.0), 1.0))
        for li, layer in enumerate(self.layers):
            w_q, w_int = qat.lsq_quantize_weight(layer.effective_weight(), layer.scale, layer.W)
            w_int_f = w_int.to(x.dtype)
            mem = torch.zeros(x.shape[0], layer.out_features, device=x.device, dtype=x.dtype)
            for t in range(self.T):
                mem = mem + x[:, t, :] @ w_int_f.t()                      # threshold-independent final membrane
            theta = torch.quantile(mem.detach().float().cpu(), q, dim=0)  # [out] (CPU: MPS lacks quantile)
            theta_int = theta.round().clamp(min=1.0).to(x.device)        # integer, positive
            s = layer.scale.squeeze(-1).clamp(min=1e-8)
            thr_train = (s * theta_int).clamp(min=1e-4)                  # membrane_train units
            # numerically stable softplus^{-1}: log(expm1(y)) overflows for y>~88 (large ramp θ);
            # y + log(-expm1(-y)) == log(expm1(y)) but is finite for all y>0 (≈ y when y is large).
            self.log_thr[li].copy_(thr_train + torch.log(-torch.expm1(-thr_train)))
            spikes, _, _, _ = self._layer_spikes(x, w_q, w_int, s * theta_int, theta_int)
            x = spikes

    def thresholds(self):
        """Positive per-output thresholds (in w_q / membrane_train units), one tensor per layer."""
        return [F.softplus(t) for t in self.log_thr]

    def _effective_thresholds(self):
        """Threshold-QAT: the deployed *integer* threshold, mapped back to membrane_train units.

        membrane_train = scale ⊙ membrane_inf, so firing on ``membrane_train >= scale*round(θ/scale)``
        is bit-identical to the golden integer test ``membrane_inf >= round(θ/scale)``. STE round so
        the gradient still reaches ``log_thr`` — this removes the only systematic train/inference
        mismatch (threshold rounding), leaving just the output early-exit/tie ordering.
        """
        effs = []
        for layer, thr in zip(self.layers, self.thresholds()):
            s = layer.scale.detach().squeeze(-1).clamp(min=1e-8)               # [out], per-output step
            effs.append(s * qat._round_ste(thr / s))
        return effs

    @torch.no_grad()
    def export_int_thresholds(self):
        """Per-layer deployed integer thresholds ``round(softplus(log_thr)/scale)`` (int64)."""
        out = []
        for layer, thr in zip(self.layers, self.thresholds()):
            s = layer.scale.squeeze(-1).clamp(min=1e-8)
            out.append(torch.round(thr / s).long())
        return out

    def _layer_spikes(self, x, w_q, w_int, thr_eff, theta_int, force_fire: bool = False):
        """One TTFS-IF layer over T steps, *bit-exact* with the integer golden forward.

        The fire decision is the integer test ``mem_int >= theta_int`` (mem_int = exact integer
        membrane ``Σ spike·w_int``, representable in fp32 for our sizes) — identical to
        ``forward.py``, with NO float-accumulation boundary drift. The surrogate gradient flows
        through the smooth float path ``mem_q - thr_eff`` via an STE: ``s = s_hard + (sg-sg.detach())``
        (forward = the hard golden decision, backward = the surrogate derivative at ``mem_q-thr_eff``).

        x ``[B,T,in]`` -> spikes ``[B,T,out]``, float membrane ``mem_q`` (grad), integer membrane
        ``mem_int`` (exact, for classification), first-spike time ``[B,out]`` (T if never).
        """
        b = x.shape[0]
        out = w_q.shape[0]
        w_int_f = w_int.to(x.dtype)                                            # exact integer values
        mem_q = torch.zeros(b, out, device=x.device, dtype=x.dtype)           # differentiable (grad path)
        mem_i = torch.zeros(b, out, device=x.device, dtype=x.dtype)           # exact integer (golden path)
        fired = torch.zeros(b, out, device=x.device, dtype=x.dtype)
        first_time = torch.full((b, out), self.T, device=x.device, dtype=torch.long)
        spikes = []
        for t in range(self.T):
            mem_q = mem_q + x[:, t, :] @ w_q.t()                              # integrate (no reset)
            mem_i = mem_i + x[:, t, :].detach() @ w_int_f.t()                 # exact integer membrane
            s_hard = (mem_i >= theta_int).to(x.dtype)                         # golden decision (no grad)
            sg = SpikeFn.apply(mem_q - thr_eff, self.beta)                    # smooth surrogate path
            s = s_hard + (sg - sg.detach())                                   # fwd = s_hard; bwd = surrogate
            new = s * (1.0 - fired)                                           # single spike: first only
            if force_fire and t == self.T - 1:
                new = torch.maximum(new, 1.0 - fired)                         # silent neuron -> spike at T-1
            with torch.no_grad():
                latch = (new > 0) & (first_time == self.T)
                first_time = torch.where(latch, torch.full_like(first_time, t), first_time)
            fired = fired + new
            spikes.append(new)
        return torch.stack(spikes, dim=1), mem_q, mem_i, first_time

    def forward(self, in_stream: torch.Tensor):
        if in_stream.dim() != 3 or in_stream.shape[1] != self.T:
            raise ValueError(f"in_stream must be [B,T={self.T},in]; got {tuple(in_stream.shape)}")
        thr_effs = self._effective_thresholds()                                # float, grad to log_thr
        theta_ints = self.export_int_thresholds()                              # exact integer (no grad)
        x = in_stream
        spikes = mem_q = mem_i = first_time = None
        scale_last = None
        for li, layer in enumerate(self.layers):
            w_q, w_int = qat.lsq_quantize_weight(layer.effective_weight(), layer.scale, layer.W)
            theta_int = theta_ints[li].to(in_stream.dtype)                     # [out] integer-valued
            spikes, mem_q, mem_i, first_time = self._layer_spikes(
                x, w_q, w_int, thr_effs[li], theta_int, force_fire=(self.force_fire and self.training))
            x = spikes                                                         # hidden spike train -> next
            scale_last = layer.scale
        tvec = torch.arange(self.T, device=in_stream.device, dtype=in_stream.dtype)
        decode_w = (self.T - tvec) if self.decode_gamma is None else self.decode_gamma ** (-tvec)
        earliness = torch.einsum("bto,t->bo", spikes, decode_w)                 # earlier spike -> higher
        # mem_loss: differentiable membrane in INTEGER units (per-output scale divided out so the
        # cross-class argmax is order-identical to the golden integer membrane — P0 fix).
        mem_loss = mem_q / scale_last.detach().squeeze(-1).clamp(min=1e-8)
        return earliness, mem_i, mem_loss, first_time

    @torch.no_grad()
    def per_layer_first_times(self, in_stream: torch.Tensor):
        """List of per-layer first-spike times ``[B,out]`` (T if never) — exposes the integer-exact
        fire decisions for golden-consistency tests (hidden layers must match ``forward.py`` exactly)."""
        thr_effs = self._effective_thresholds()
        theta_ints = self.export_int_thresholds()
        x = in_stream
        times = []
        for li, layer in enumerate(self.layers):
            w_q, w_int = qat.lsq_quantize_weight(layer.effective_weight(), layer.scale, layer.W)
            spikes, _, _, ft = self._layer_spikes(
                x, w_q, w_int, thr_effs[li], theta_ints[li].to(in_stream.dtype))
            times.append(ft)
            x = spikes
        return times


def ttfs_loss(earliness, out_membrane, target, beta_mem: float = 0.3, label_smoothing: float = 0.1):
    """TTFS classification loss: CE on the earliness score (correct class should fire earliest)
    + ``beta_mem``*CE on the final membrane (gradient for no-spike samples + stabiliser).

    ``out_membrane`` must be the model's ``mem_loss`` (membrane in integer units, per-output scale
    divided out) so the CE optimises the same cross-class ordering the golden integer argmax uses.
    The membrane is per-sample standardised (detached stats) before its CE — integer membranes can be
    huge (esp. multi-bit ramp input), and raw softmax would overflow; standardising is argmax-
    preserving and keeps the gradient well-scaled.
    """
    l_time = F.cross_entropy(earliness, target, label_smoothing=label_smoothing)
    mem = out_membrane
    mem = (mem - mem.mean(dim=1, keepdim=True).detach()) / (mem.std(dim=1, keepdim=True).detach() + 1e-5)
    l_mem = F.cross_entropy(mem, target, label_smoothing=label_smoothing)
    return l_time + beta_mem * l_mem


@torch.no_grad()
def hard_classify(out_first_time, out_membrane, T: int):
    """Faithful TTFS decode (matches ``forward.ttfs_classify``): earliest spike wins; ties ->
    highest membrane -> lowest index; no spike (all == T) -> argmax membrane. Returns ``preds[B]``.

    ``out_membrane`` must be the model's ``mem_int`` (exact INTEGER membrane); the golden tie-break
    and no-spike fallback compare integer membranes, and the per-output LSQ scale would otherwise
    reorder a scaled membrane's argmax. For training-time monitoring; the authoritative number comes
    from the golden ``forward.py`` (this monitors the full-frame point, golden the early-exit point)."""
    b = out_first_time.shape[0]
    fired = out_first_time < T
    # earliest time per sample (T if none fired); push non-fired to +inf for the min
    t_for_min = torch.where(fired, out_first_time, torch.full_like(out_first_time, T + 1))
    earliest = t_for_min.min(dim=1, keepdim=True).values                      # [B,1]
    is_earliest = fired & (out_first_time == earliest)                        # tie set
    # among ties pick highest membrane; non-ties masked to -inf
    masked_mem = torch.where(is_earliest, out_membrane, torch.full_like(out_membrane, float("-inf")))
    any_fired = fired.any(dim=1)
    pred_spike = masked_mem.argmax(dim=1)                                     # ties -> lowest idx (argmax stable)
    pred_fallback = out_membrane.argmax(dim=1)
    return torch.where(any_fired, pred_spike, pred_fallback)
