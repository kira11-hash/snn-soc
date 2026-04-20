"""Multilayer FC SNN training (PyTorch).

Phase V2.A / A2:
    * ``MultiLayerANN`` — generic FC network driven by ``TopologyConfig``
    * ``train_multilayer`` — joint training loop with QAT (4-bit + device levels)

Important caveat: this file's ``forward`` uses ``ReLU`` as a training proxy.
The actual RTL semantics use binary spike masks for stages 1+ (see
``snn_engine_multilayer.snn_inference_multilayer`` for the RTL-like reference).
Keep this in mind when interpreting training accuracy vs RTL-like accuracy.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import torch.optim as optim
from torch.utils.data import DataLoader, TensorDataset

import config_multilayer as cfg
from _vendored_from_v1.quantization import (
    apply_qat_noise,
    fake_quantize_signed,
    ir_drop_scale,
)
from topologies import TopologyConfig

logger = logging.getLogger(__name__)


@dataclass
class TrainResult:
    """Training outcome for one topology."""
    topology_name: str
    float_test_accuracy: float        # Before QAT (or QAT disabled)
    quantized_test_accuracy: float    # After QAT
    final_loss: float
    num_epochs: int
    qat_enabled: bool


UINT8_MAX = 255  # matches RTL spike_count saturation

# RTL integer constants mirrored from _vendored_from_v1.integer_reference
_RTL_ADC_MAX = 255
_RTL_SUM_MAX = 960  # NUM_INPUTS=64 * LEVEL_MAX=15
_RTL_LEVEL_MAX = 15  # 4-bit quantized weight levels


def _ste_round(x: torch.Tensor) -> torch.Tensor:
    """Round with identity gradient (STE)."""
    return x + (x.round() - x).detach()


def _ste_clamp(x: torch.Tensor, lo: float, hi: float) -> torch.Tensor:
    """Clamp with identity gradient in the interior (STE)."""
    c = x.clamp(lo, hi)
    return x + (c - x).detach()


def _adc_scale_ste(raw: torch.Tensor) -> torch.Tensor:
    """Bit-exact V1 ADC for legacy count-bitplane path. Uses fixed SUM_MAX=960, 8-bit.

    Kept for V2.A bitplane path. V2.B streamed rate uses ``_adc_scale_v2_ste``.
    """
    biased = raw * _RTL_ADC_MAX + _RTL_SUM_MAX // 2
    scaled_int = torch.floor(biased / _RTL_SUM_MAX)
    scaled = biased / _RTL_SUM_MAX
    scaled_ste = scaled + (scaled_int - scaled).detach()
    return _ste_clamp(scaled_ste, 0.0, float(_RTL_ADC_MAX))


def _adc_scale_v2_ste(
    raw: torch.Tensor, sum_max: float, adc_bits: int = 8,
) -> torch.Tensor:
    """V2.B streamed-rate parameterized ADC (per-stage sum_max, configurable adc_bits).

    Bit-identical to ``adc_scale_v2.rtl_adc_scale_v2`` numpy golden:
      scaled_int = floor((raw * adc_max + sum_max // 2) / sum_max)
      clamp to [0, adc_max]
    """
    adc_max = float((1 << adc_bits) - 1)
    biased = raw * adc_max + sum_max // 2
    scaled_int = torch.floor(biased / sum_max)
    scaled = biased / sum_max
    scaled_ste = scaled + (scaled_int - scaled).detach()
    return _ste_clamp(scaled_ste, 0.0, adc_max)


def encode_pixel_to_stream_ste(
    pixel_uint8: torch.Tensor, T: int, method: str = "even_rate",
) -> torch.Tensor:
    """Differentiable pixel→spike stream encoder (even_rate accumulator, STE round).

    Matches ``snn_engine_multilayer.encode_pixel_to_spike_stream`` bit-for-bit
    on integer-valued pixel inputs. Returns ``[N, T, in_dim]`` float (0/1).

    Total spikes per pixel equals ``pixel * T // 256`` (G2 invariant).
    """
    if method != "even_rate":
        raise NotImplementedError(
            f"encode_pixel_to_stream_ste only supports 'even_rate' (got {method!r})"
        )
    # pixel_uint8: [N, in_dim], values in [0, 255] (float for STE)
    pix = _ste_clamp(_ste_round(pixel_uint8), 0.0, 255.0)  # STE integer
    N, in_dim = pix.shape
    device = pix.device

    # Accumulator loop. Non-differentiable spike generation with identity STE
    # on the spike values: backward flows as if spike = pix/256 (uniform proxy).
    acc = torch.zeros(N, in_dim, device=device, dtype=pix.dtype)
    stream = torch.zeros(T, N, in_dim, device=device, dtype=pix.dtype)
    # Hard forward path, no gradient through spikes themselves.
    with torch.no_grad():
        acc_hard = torch.zeros_like(pix)
        hard_stream = torch.zeros(T, N, in_dim, device=device, dtype=pix.dtype)
        for t in range(T):
            acc_hard = acc_hard + pix.detach()
            fired = (acc_hard >= 256.0).float()
            hard_stream[t] = fired
            acc_hard = acc_hard - fired * 256.0
    # Soft STE proxy: each timestep contributes pix/256 to expected spike.
    soft_stream = (pix / 256.0).unsqueeze(0).expand(T, -1, -1)
    # STE: forward=hard, backward gradient via soft.
    stream = soft_stream + (hard_stream - soft_stream).detach()
    return stream.permute(1, 0, 2).contiguous()  # [N, T, in_dim]


def _rtl_like_stage_forward_streamed(
    x_stream: torch.Tensor,          # [N, T, in_dim] float 0/1
    w_float: torch.Tensor,           # [out_dim, in_dim]
    threshold: torch.Tensor,
    sum_max: float,
    adc_bits: int,
    level_values: torch.Tensor | None = None,
) -> tuple[torch.Tensor, torch.Tensor]:
    """V2.B REV 2 streamed-rate stage forward with surrogate LIF.

    Matches ``snn_engine_multilayer._run_stage_streamed_rate``:
      - For each of T timesteps: 1 binary-WL MAC + per-stage ADC + LIF
      - Membrane accumulates across T (no reset within stage)
      - Spike generated per timestep

    Returns ``(spike_stream_out [N, T, out_dim], spike_counts [N, out_dim])``.
    """
    N, T, in_dim = x_stream.shape
    out_dim = w_float.shape[0]
    device = x_stream.device

    # Weight quantization (same as legacy): split pos/neg + 16-level snap.
    shared_max = w_float.abs().max().clamp(min=1e-6)
    w_pos_float = torch.clamp(w_float, min=0.0)
    w_neg_float = torch.clamp(-w_float, min=0.0)
    w_pos_norm = (w_pos_float / shared_max).clamp(0.0, 1.0)
    w_neg_norm = (w_neg_float / shared_max).clamp(0.0, 1.0)
    if level_values is None:
        w_pos = _ste_round(w_pos_norm * _RTL_LEVEL_MAX)
        w_neg = _ste_round(w_neg_norm * _RTL_LEVEL_MAX)
    else:
        lv = level_values.to(device=device, dtype=w_float.dtype).flatten()
        def _snap(normalized: torch.Tensor) -> torch.Tensor:
            d = (normalized.unsqueeze(-1) - lv.view(1, 1, -1)).abs()
            idx = d.argmin(dim=-1).to(dtype=w_float.dtype)
            soft = normalized * (lv.numel() - 1)
            return soft + (idx - soft).detach()
        w_pos = _snap(w_pos_norm)
        w_neg = _snap(w_neg_norm)

    membrane = torch.zeros(N, out_dim, device=device, dtype=w_float.dtype)
    spike_stream_out = torch.zeros(N, T, out_dim, device=device, dtype=w_float.dtype)
    for t in range(T):
        wl = x_stream[:, t, :]  # [N, in_dim]
        pos_sum = wl @ w_pos.t()  # [N, out_dim]
        neg_sum = wl @ w_neg.t()
        diff = _adc_scale_v2_ste(pos_sum, sum_max, adc_bits) - _adc_scale_v2_ste(neg_sum, sum_max, adc_bits)
        membrane = membrane + diff
        fired = _surrogate_spike(membrane, threshold)
        spike_stream_out[:, t, :] = fired
        membrane = membrane - fired * threshold

    spike_counts = spike_stream_out.sum(dim=1)  # [N, out_dim]
    return spike_stream_out, spike_counts


def _surrogate_spike(membrane: torch.Tensor, threshold: torch.Tensor) -> torch.Tensor:
    """Hard threshold in forward, fast-sigmoid surrogate gradient in backward."""
    margin = (membrane - threshold) / threshold.clamp(min=1.0)
    surr = torch.sigmoid(4.0 * margin)  # continuous proxy
    hard = (membrane.detach() >= threshold.detach()).float()
    return surr + (hard - surr).detach()


def _exporter_level_table(
    levels: torch.Tensor | None, num_levels: int
) -> torch.Tensor | None:
    """Return the normalized [0, 1] 16-level grid used by the exporter.

    Matches ``exporter_multilayer._as_level_tensor(add_zero_level=False)``: drop
    the QAT-specific leading-zero level (if present) and keep just the physical
    device levels. Returns ``None`` to fall back to linear 16-level grid.
    """
    if levels is None:
        return None
    vals = torch.sort(torch.unique(levels.flatten()))[0]
    # QAT tables prepend a zero-magnitude proxy (see _get_device_levels). The
    # exporter drops that by loading the raw MemristorArraySimulator values.
    # Emulate: if we have num_levels+1 entries and the first is ~0, drop it.
    if vals.numel() == num_levels + 1 and vals[0] < 1e-9:
        vals = vals[1:]
    if vals.numel() != num_levels:
        # Shape mismatch; fall back to linear grid.
        return None
    max_val = vals.max().clamp(min=1e-12)
    return vals / max_val


def _rtl_like_stage_forward(
    x_uint8: torch.Tensor,              # [N, in_dim] float ~integer in [0, 255]
    w_float: torch.Tensor,              # [out_dim, in_dim] continuous float weights
    threshold: torch.Tensor,            # scalar positive tensor
    timesteps: int,
    level_values: torch.Tensor | None = None,  # 16 physical normalized levels [0..1]
) -> torch.Tensor:
    """Differentiable Scheme-B bit-plane + ADC + LIF stage forward.

    Mimics ``snn_engine_multilayer._run_stage_bitplane`` with surrogate gradients
    so training sees the exact RTL datapath (not a float ReLU proxy).

    Weight quantization must match ``exporter_multilayer._quantize_half_to_level_indices``
    exactly: split signed w into pos/neg halves, share max across halves,
    snap each half to integer level index [0, 15] on a 16-level grid (not the
    8-level signed grid). STE through the snap so gradients flow to w_float.

    Returns ``[N, out_dim]`` uint8-saturated spike counts.
    """
    device = x_uint8.device
    shared_max = w_float.abs().max().clamp(min=1e-6)
    # Split into non-negative halves (V1 + exporter convention).
    w_pos_float = torch.clamp(w_float, min=0.0)
    w_neg_float = torch.clamp(-w_float, min=0.0)
    w_pos_norm = (w_pos_float / shared_max).clamp(0.0, 1.0)
    w_neg_norm = (w_neg_float / shared_max).clamp(0.0, 1.0)

    # Snap each half to integer level index [0, 15]. Default: uniform 16-level
    # grid. When ``level_values`` is provided (e.g., V1 log-spaced device
    # conductance), snap to the nearest level instead — this matches the
    # exporter's HEX output bit-exactly.
    if level_values is None:
        w_pos = _ste_round(w_pos_norm * _RTL_LEVEL_MAX)
        w_neg = _ste_round(w_neg_norm * _RTL_LEVEL_MAX)
    else:
        lv = level_values.to(device=device, dtype=w_float.dtype).flatten()
        # Nearest-level index via argmin |normalized - level|; STE backward.
        def _snap(normalized: torch.Tensor) -> torch.Tensor:
            d = (normalized.unsqueeze(-1) - lv.view(1, 1, -1)).abs()
            idx = d.argmin(dim=-1).to(dtype=w_float.dtype)
            # STE: forward = idx, backward = normalized * (num_levels-1) proxy.
            soft = normalized * (lv.numel() - 1)
            return soft + (idx - soft).detach()
        w_pos = _snap(w_pos_norm)
        w_neg = _snap(w_neg_norm)

    # Round inputs to nearest int (STE) then extract bits.
    x_int = _ste_clamp(_ste_round(x_uint8), 0.0, float(UINT8_MAX))

    n_batch = x_int.shape[0]
    out_dim = w_float.shape[0]
    membrane = torch.zeros(n_batch, out_dim, device=device)
    spike_count = torch.zeros_like(membrane)

    # Refractory: per-frame spike cap K (GPT 2026-04-19 P1 recommendation,
    # validated when stage0 count saturates to timesteps*8 max). K=None
    # disables. K=2 caps max_count at 2*timesteps; K=4 at 4*timesteps.
    refractory_k = getattr(cfg, "RTL_REFRACTORY_K", None)

    for _t in range(timesteps):
        # Per-frame spike counter (zeroed every frame). Refractory gate:
        # neuron may fire only if frame_fire < K in current frame.
        frame_fire = torch.zeros_like(membrane) if refractory_k is not None else None
        for bit in range(7, -1, -1):
            # Bit extraction: non-differentiable hard op + STE with x/256 weighting.
            x_long = x_int.detach().round().long()
            wl_hard = ((x_long >> bit) & 1).float()
            wl_soft = x_int / 256.0  # uniform soft proxy
            wl = wl_soft + (wl_hard - wl_soft).detach()

            pos_sum = wl @ w_pos.t()
            neg_sum = wl @ w_neg.t()
            diff = _adc_scale_ste(pos_sum) - _adc_scale_ste(neg_sum)

            membrane = membrane + diff * float(1 << bit)

            fired = _surrogate_spike(membrane, threshold)
            if refractory_k is not None:
                # Gate fired by frame_fire < K. STE: hard gate forward,
                # identity gradient on fired in backward (don't block surrogate).
                gate_hard = (frame_fire.detach() < float(refractory_k)).to(fired.dtype)
                # gate_soft = 1 so backward treats gate as identity.
                gate = 1.0 + (gate_hard - 1.0).detach()
                fired = fired * gate
                frame_fire = frame_fire + fired.detach()
            spike_count = spike_count + fired
            membrane = membrane - fired.detach() * threshold

    return _ste_clamp(spike_count, 0.0, float(UINT8_MAX))


def _uint8_quantize_ste(a: torch.Tensor, scale: torch.Tensor) -> torch.Tensor:
    """Uint8 activation quantization with straight-through estimator.

    Forward:  a_q = clamp(round(a / scale), 0, 255) * scale
    Backward: identity (STE) w.r.t. both a and scale

    2B-serial training proxy: stage N>0 consumes a uint8 spike_count. Training
    uses a learnable per-stage ``scale`` so the ReLU activation maps into a
    uint8 integer range, approximating the RTL bit-plane + LIF path without
    backprop through a non-differentiable step function.
    """
    a_q = torch.clamp(torch.round(a / scale), 0, UINT8_MAX) * scale
    return a + (a_q - a).detach()


class MultiLayerANN(nn.Module):
    """Multi-layer FC network parameterised by a ``TopologyConfig``.

    Each stage is a single ``nn.Linear(bias=False)`` (matching V1's
    ``SingleLayerANN`` convention of no bias, since CIM MAC has no bias).

    2B-serial training (2026-04-19): intermediate activations go through
    ``ReLU + uint8 quantization STE`` so the network learns weights compatible
    with the RTL spike_count feedback path. Final stage outputs logits.

    Per-stage ``act_log_scale`` is learnable (log-parametrized for positivity).
    At inference, this scale maps to the stage's RTL threshold.
    """

    def __init__(self, topology: TopologyConfig) -> None:
        super().__init__()
        self.topology = topology
        self.layers = nn.ModuleList(
            [nn.Linear(s.in_dim, s.out_dim, bias=False) for s in topology.stages]
        )
        # Log-parametrized per-intermediate-stage activation scale (used only by
        # the legacy ReLU+uint8 STE training path).
        num_intermediate = max(0, len(topology.stages) - 1)
        self.act_log_scale = nn.Parameter(torch.zeros(num_intermediate))
        # RTL-like learnable per-stage LIF threshold. Parametrized as
        # ``theta_min + softplus(raw)`` so training cannot collapse threshold
        # to 0/1 (which degenerates LIF to "sign(MAC)"). ``theta_min`` is a
        # per-stage buffer so Python forward + numpy golden see the same
        # effective threshold. See GPT 2026-04-19: stage0 theta_min ~100,
        # stage N>0 theta_min ~2-4 (prevents degeneration to binary mask).
        init_thresholds = torch.tensor(
            [float(s.threshold) for s in topology.stages], dtype=torch.float32
        ).clamp(min=1.0)
        default_theta_mins = [
            float(getattr(cfg, "RTL_STAGE0_THETA_MIN", 20)),
        ] + [
            float(getattr(cfg, "RTL_STAGEN_THETA_MIN", 1))
        ] * max(0, len(topology.stages) - 1)
        theta_min_tensor = torch.tensor(default_theta_mins, dtype=torch.float32)

        # Initialize raw parameter matching the selected parametrization.
        mode = getattr(cfg, "RTL_THRESHOLD_PARAM", "log_exp")
        if mode == "softplus_floor":
            residual = (init_thresholds - theta_min_tensor).clamp(min=1e-3)
            init_raw = torch.log(torch.expm1(residual.clamp(max=50.0)))
        elif mode == "ste_floor":
            init_raw = (init_thresholds - theta_min_tensor).clamp(min=0.0)
        else:  # "log_exp"
            init_raw = init_thresholds.clamp(min=1.0).log()
        self.raw_threshold = nn.Parameter(init_raw)
        self.register_buffer("theta_min", theta_min_tensor)

    def _scale_for(self, intermediate_index: int) -> torch.Tensor:
        # exp() keeps scale > 0; clamped at load/training so it never collapses to 0.
        return self.act_log_scale[intermediate_index].exp().clamp(min=1e-3)

    def effective_threshold(self, stage_idx: int) -> torch.Tensor:
        """Effective LIF threshold. Parametrization chosen via ``cfg.RTL_THRESHOLD_PARAM``:

        - "softplus_floor" (v8/v8b, BROKEN): ``theta_min + softplus(raw)``.
          Gradient vanishes at floor → training can't raise threshold. v8/v8b
          both got stuck at init and failed at 21% / 26%.
        - "log_exp" (v5/v7, WORKING): ``exp(raw)``. Log domain, no gradient
          saturation. v7 reached 82.09% this way.
        - "ste_floor" (route B, experimental): ``max(raw, theta_min)`` forward,
          identity gradient via STE to bypass hard-clamp gradient issue.

        Default: "log_exp" (proven). Override via cfg for experiments.
        """
        mode = getattr(cfg, "RTL_THRESHOLD_PARAM", "log_exp")
        raw = self.raw_threshold[stage_idx]
        if mode == "softplus_floor":
            return self.theta_min[stage_idx] + torch.nn.functional.softplus(raw)
        if mode == "ste_floor":
            theta_min = self.theta_min[stage_idx]
            soft = theta_min + raw                       # backward path
            hard = theta_min + torch.relu(raw)           # forward ≥ theta_min
            return soft + (hard - soft).detach()
        # "log_exp" — clamp raw to positive domain like log(threshold).
        return torch.exp(raw).clamp(min=1.0)

    @torch.no_grad()
    def calibrate_activation_scales(
        self,
        x: torch.Tensor,
        target_max_count: int = 80,
        percentile: float = 0.99,
    ) -> None:
        """Set per-stage ``act_log_scale`` from an unquantized forward pass.

        ``percentile`` (0-1) picks the activation statistic (default 99th).
        ``target_max_count`` maps that percentile to a uint8 level count.

        Fashion-MNIST calibration sensitivity (GPT 2026-04-19): Fashion
        activations distribute differently from MNIST; both percentile and
        target_max_count may need tuning per dataset to avoid STE destroying
        the pure-float accuracy.
        """
        act = x
        for i, layer in enumerate(self.layers):
            act = layer(act)
            if i < len(self.layers) - 1:
                relu_out = F.relu(act)
                pct_val = torch.quantile(relu_out.flatten(), percentile)
                new_scale = max(float(pct_val) / target_max_count, 1e-3)
                self.act_log_scale.data[i] = float(np.log(new_scale))
                act = relu_out

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        for i, layer in enumerate(self.layers):
            x = layer(x)
            if i < len(self.layers) - 1:
                a = F.relu(x)
                x = _uint8_quantize_ste(a, self._scale_for(i))
        return x

    def forward_pure_float(self, x: torch.Tensor) -> torch.Tensor:
        """Pure ReLU forward, no weight quant, no uint8 activation STE.

        Used to train a higher-accuracy float teacher (≥90%) for KD. The
        regular ``forward`` applies uint8 STE between layers to mimic the
        integer spike-count feedback, which caps float accuracy around 85%.
        Pure float can reach 92-94% on MNIST 8×8 with the same topology.
        """
        for i, layer in enumerate(self.layers):
            x = layer(x)
            if i < len(self.layers) - 1:
                x = F.relu(x)
        return x

    def forward_streamed_rate(
        self,
        pixel_uint8: torch.Tensor,     # [N, input_dim] float, values 0-255
        stream_timesteps: int,
        adc_bits: int,
        adc_full_scale: str,           # "active_wl" | "array"
        weight_bits: int = 4,
        levels: torch.Tensor | None = None,
        array_rows: int = 256,
    ) -> torch.Tensor:
        """V2.B REV 2 streamed-rate forward for training.

        Matches ``snn_engine_multilayer._snn_inference_streamed_rate_sample``
        semantics with surrogate gradient for LIF and STE for encoding.
        Returns ``[N, final_out_dim]`` spike_counts as logits (argmax → class).
        """
        level_values = _exporter_level_table(levels, 2 ** weight_bits)

        # Stage 0 input: encode pixel to [N, T, input_dim] stream
        stream = encode_pixel_to_stream_ste(pixel_uint8, stream_timesteps, method="even_rate")
        final_counts = None

        for i, (layer, stage) in enumerate(zip(self.layers, self.topology.stages)):
            # Resolve per-stage sum_max
            if stage.sum_max is not None:
                sum_max = float(stage.sum_max)
            elif adc_full_scale == "active_wl":
                sum_max = float(stage.in_dim * 15)
            else:
                sum_max = float(array_rows * 15)

            # Threshold from YAML (fixed during training; calibrated externally).
            threshold = torch.tensor(float(stage.threshold), device=pixel_uint8.device,
                                     dtype=pixel_uint8.dtype).clamp(min=1.0)
            stream, counts = _rtl_like_stage_forward_streamed(
                x_stream=stream,
                w_float=layer.weight,
                threshold=threshold,
                sum_max=sum_max,
                adc_bits=adc_bits,
                level_values=level_values,
            )
            final_counts = counts
        return final_counts  # [N, final_out_dim]

    def forward_qat(
        self,
        x: torch.Tensor,
        weight_bits: int,
        levels: torch.Tensor | None,
        noise_std: float,
        ir_drop_coeff: float,
    ) -> torch.Tensor:
        """QAT forward: weight quantize + activation uint8 quantize + STE."""
        for i, layer in enumerate(self.layers):
            w = layer.weight                                 # [out_dim, in_dim]
            w_q = fake_quantize_signed(w, weight_bits, levels)
            if noise_std and noise_std > 0:
                w_q = apply_qat_noise(w_q, noise_std)
            x_lin = x @ w_q.t()                              # [N, out_dim]
            scale = ir_drop_scale(x, ir_drop_coeff)
            if scale is not None:
                x_lin = x_lin * torch.clamp(scale, 0.8, 1.0)
            x = x_lin
            if i < len(self.layers) - 1:
                a = F.relu(x)
                x = _uint8_quantize_ste(a, self._scale_for(i))
        return x

    def forward_rtl_like(
        self,
        x_uint8: torch.Tensor,             # [N, input_dim] float ~integer in [0, 255]
        weight_bits: int,
        levels: torch.Tensor | None,
        collect_intermediate: bool = False,
    ) -> torch.Tensor | tuple[torch.Tensor, list[torch.Tensor]]:
        """Differentiable RTL-like forward: bit-plane + ADC + LIF per stage.

        Trains the model through the EXACT datapath the RTL will run at
        inference — bit-plane decomposition, integer ADC scaling, LIF with
        surrogate gradient. Intermediate stages pass uint8 spike_count
        (2B-serial). Final stage outputs raw spike_count [N, num_classes];
        CrossEntropyLoss operates on these counts as logits (works because
        argmax of counts = predicted class).

        If ``collect_intermediate=True``, returns ``(logits, intermediate_outs)``
        where intermediate_outs contains each non-final stage's spike_count
        tensor — used by the training loop to compute a saturation penalty.
        """
        level_values = _exporter_level_table(levels, 2 ** weight_bits)
        intermediate_outs: list[torch.Tensor] = []
        x = x_uint8
        num_stages = len(self.layers)
        for i, (layer, stage) in enumerate(zip(self.layers, self.topology.stages)):
            threshold = self.effective_threshold(i)
            x = _rtl_like_stage_forward(
                x_uint8=x,
                w_float=layer.weight,
                threshold=threshold,
                timesteps=stage.timesteps,
                level_values=level_values,
            )
            if collect_intermediate and i < num_stages - 1:
                intermediate_outs.append(x)
        if collect_intermediate:
            return x, intermediate_outs
        return x  # [N, final out_dim] as spike counts / logits

    def snapshot_thresholds(self) -> list[int]:
        """Return current learned thresholds as integers (for YAML writeback)."""
        with torch.no_grad():
            ths = [self.effective_threshold(i).item() for i in range(len(self.layers))]
            return [int(round(t)) for t in ths]


def _get_device_levels(num_levels: int) -> torch.Tensor | None:
    """Return V1 QAT device conductance levels, or ``None`` for V1 fallback.

    V1 imports from ``memristor_plugin.MemristorArraySimulator``. We try that
    first (via sys.path); if device levels are disabled or unavailable, return
    ``None`` so ``fake_quantize_signed`` uses V1's signed uniform STE path.
    """
    if not cfg.QAT_USE_DEVICE_LEVELS:
        return None

    try:
        cfg.setup_v1_import_paths()
        from memristor_plugin import MemristorArraySimulator  # type: ignore

        iv_path = cfg.V1_DEVICE_DIR / "I-V.xlsx"
        sim = MemristorArraySimulator(iv_data_path=str(iv_path), device="cpu")
        levels = torch.as_tensor(sim.conductance_levels, dtype=torch.float32)
        levels = torch.sort(torch.unique(levels))[0]
        max_val = levels.max()
        if max_val < 1e-12:
            return torch.linspace(0.0, 1.0, num_levels)
        levels_norm = levels / max_val
        # V1 QAT's snn_engine._load_plugin_levels prepends a zero conductance
        # proxy when the physical table starts above zero. Keep that convention
        # here; HEX export intentionally uses the 16 physical levels only.
        if levels_norm[0] > 0:
            levels_norm = torch.cat([torch.zeros(1, dtype=levels_norm.dtype), levels_norm])
        return levels_norm
    except Exception as exc:  # pragma: no cover — plugin is optional
        logger.warning(
            "Device model unavailable (%s); falling back to V1 signed uniform QAT.",
            exc,
        )
        return None


def _evaluate(
    model: MultiLayerANN,
    loader: DataLoader,
    qat: bool,
    weight_bits: int,
    levels: torch.Tensor | None,
) -> float:
    """Return classification accuracy on the loader."""
    model.eval()
    correct = 0
    total = 0
    with torch.no_grad():
        for inputs, labels in loader:
            if qat:
                logits = model.forward_qat(
                    inputs, weight_bits, levels, noise_std=0.0, ir_drop_coeff=0.0
                )
            else:
                logits = model(inputs)
            pred = logits.argmax(dim=1)
            correct += int((pred == labels).sum())
            total += labels.numel()
    return correct / max(1, total)


@torch.no_grad()
def _calibrate_rtl_thresholds(
    model: MultiLayerANN,
    x_uint8: torch.Tensor,
    levels: torch.Tensor | None,
    target_count: int = 20,
) -> None:
    """Set per-stage thresholds so the untrained RTL forward produces ~target_count spikes.

    Without this, default YAML thresholds (e.g., 10000) starve the surrogate
    gradient signal at step 0 — every neuron reports spike_count=0 and training
    cannot start.
    """
    level_values = _exporter_level_table(levels, 2 ** cfg.QAT_WEIGHT_BITS)
    act = x_uint8
    for stage_idx, (layer, stage) in enumerate(zip(model.layers, model.topology.stages)):
        probe = _rtl_like_stage_forward(
            act, layer.weight, torch.tensor(1.0), stage.timesteps,
            level_values=level_values,
        )
        pct = float(torch.quantile(probe.flatten(), 0.95))
        theta_min = float(model.theta_min[stage_idx])
        mode = getattr(cfg, "RTL_THRESHOLD_PARAM", "log_exp")
        if mode == "log_exp":
            # No floor: use probe-derived threshold directly (min 1).
            new_thresh = max(pct / max(1, target_count), 1.0)
            model.raw_threshold.data[stage_idx] = float(np.log(new_thresh))
        else:
            new_thresh = max(pct / max(1, target_count), theta_min)
            if mode == "softplus_floor":
                residual = max(new_thresh - theta_min, 1e-3)
                raw_val = float(np.log(np.expm1(min(residual, 50.0))))
            else:  # ste_floor
                raw_val = max(new_thresh - theta_min, 0.0)
            model.raw_threshold.data[stage_idx] = raw_val
        act = _rtl_like_stage_forward(
            act, layer.weight, torch.tensor(new_thresh), stage.timesteps,
            level_values=level_values,
        )


@torch.no_grad()
def _evaluate_rtl_like(
    model: MultiLayerANN,
    x_uint8: torch.Tensor,
    labels: torch.Tensor,
    levels: torch.Tensor | None,
    batch_size: int,
) -> float:
    """Accuracy under differentiable RTL-like forward (used as training eval only)."""
    model.eval()
    correct = 0
    total = 0
    for i in range(0, x_uint8.shape[0], batch_size):
        xb = x_uint8[i : i + batch_size]
        yb = labels[i : i + batch_size]
        logits = model.forward_rtl_like(xb, cfg.QAT_WEIGHT_BITS, levels)
        pred = logits.argmax(dim=1)
        correct += int((pred == yb).sum())
        total += yb.numel()
    return correct / max(1, total)


def train_multilayer(
    topology: TopologyConfig,
    train_images_uint8: torch.Tensor,
    train_labels: torch.Tensor,
    test_images_uint8: torch.Tensor,
    test_labels: torch.Tensor,
    epochs: int | None = None,
    lr: float | None = None,
    batch_size: int = 128,
    seed: int = 42,
    enable_qat: bool = True,
    log_every_epoch: bool = True,
) -> tuple[MultiLayerANN, TrainResult]:
    """Train one ``MultiLayerANN`` end-to-end (joint training).

    Args:
        topology:           Target topology (must have ``role="v2_demo"``).
        train_images_uint8: ``[N, input_dim]`` uint8 input (downsampled MNIST).
        train_labels:       ``[N]`` int labels.
        test_images_uint8:  ``[M, input_dim]`` uint8 test inputs.
        test_labels:        ``[M]`` int test labels.
        epochs:             Training epochs (default ``cfg.MULTILAYER_EPOCHS``).
        lr:                 Learning rate (default ``cfg.MULTILAYER_LR``).
        batch_size:         Minibatch size.
        seed:               RNG seed for reproducibility.
        enable_qat:         If True, apply QAT (fake quant + noise + IR-drop) in
                            the second half of training + fine-tune.
        log_every_epoch:    If True, log loss/acc each epoch.

    Returns:
        ``(model, TrainResult)``. ``TrainResult`` contains float and QAT accuracies.
    """
    if topology.role != "v2_demo":
        raise ValueError(
            f"train_multilayer expects role='v2_demo', got {topology.role} "
            f"for topology {topology.name}. Baselines should use run_baseline_64to10.py."
        )

    torch.manual_seed(seed)

    epochs = epochs if epochs is not None else cfg.MULTILAYER_EPOCHS
    lr = lr if lr is not None else cfg.MULTILAYER_LR

    # Normalize uint8 -> float [0, 1] for ReLU phases
    train_x = train_images_uint8.float() / 255.0
    test_x = test_images_uint8.float() / 255.0
    # Keep uint8-scale copies for the RTL-like fine-tune phase (stage 0 expects
    # [0, 255] integer-valued input).
    train_x_u8 = train_images_uint8.float()
    test_x_u8 = test_images_uint8.float()

    train_ds = TensorDataset(train_x, train_labels)
    train_loader = DataLoader(
        train_ds, batch_size=batch_size, shuffle=True,
        generator=torch.Generator().manual_seed(seed),
    )
    test_ds = TensorDataset(test_x, test_labels)
    test_loader = DataLoader(test_ds, batch_size=batch_size, shuffle=False)

    model = MultiLayerANN(topology)
    # Calibrate intermediate activation scales from a forward pass on a
    # calibration batch (PTQ-style). This aligns training's uint8 quantization
    # range with the RTL spike_count dynamic range, avoiding the "scale=1 traps
    # activation in [0, 7]" failure mode observed with the default init.
    calib_batch = train_x[: min(2048, train_x.shape[0])]
    model.calibrate_activation_scales(calib_batch, target_max_count=80)
    init_scales = model.act_log_scale.detach().exp().tolist()
    logger.info("[%s] calibrated act_scale = %s", topology.name, init_scales)

    optimizer = optim.SGD(model.parameters(), lr=lr, momentum=cfg.ANN_MOMENTUM)
    criterion = nn.CrossEntropyLoss()

    levels: torch.Tensor | None = None
    if enable_qat:
        levels = _get_device_levels(2 ** cfg.QAT_WEIGHT_BITS)

    # Stage 1: float training (first half of epochs)
    float_epochs = max(1, epochs // 2)
    qat_epochs = epochs - float_epochs + cfg.POST_QUANT_FINE_TUNE_EPOCHS if enable_qat else 0

    logger.info(
        "[%s] training: %d float epochs + %d QAT epochs (total %d)",
        topology.name, float_epochs, qat_epochs, float_epochs + qat_epochs,
    )

    final_loss = float("inf")
    model.train()
    for epoch in range(float_epochs):
        epoch_loss = 0.0
        num_batches = 0
        for inputs, labels in train_loader:
            logits = model(inputs)
            loss = criterion(logits, labels)
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            epoch_loss += float(loss.item())
            num_batches += 1
        avg = epoch_loss / max(1, num_batches)
        final_loss = avg
        if log_every_epoch:
            logger.info("[%s] epoch %d/%d (float) loss=%.4f",
                        topology.name, epoch + 1, float_epochs, avg)

    float_acc = _evaluate(model, test_loader, qat=False, weight_bits=0, levels=None)
    logger.info("[%s] float test accuracy = %.4f", topology.name, float_acc)

    # Stage 2: QAT fine-tune (only if enabled)
    quantized_acc = float_acc
    if enable_qat:
        for epoch in range(qat_epochs):
            epoch_loss = 0.0
            num_batches = 0
            for inputs, labels in train_loader:
                logits = model.forward_qat(
                    inputs,
                    weight_bits=cfg.QAT_WEIGHT_BITS,
                    levels=levels,
                    noise_std=cfg.QAT_NOISE_STD if cfg.QAT_NOISE_ENABLE else 0.0,
                    ir_drop_coeff=cfg.QAT_IR_DROP_COEFF,
                )
                loss = criterion(logits, labels)
                optimizer.zero_grad()
                loss.backward()
                optimizer.step()
                epoch_loss += float(loss.item())
                num_batches += 1
            avg = epoch_loss / max(1, num_batches)
            final_loss = avg
            if log_every_epoch:
                logger.info("[%s] epoch %d/%d (QAT) loss=%.4f",
                            topology.name, epoch + 1, qat_epochs, avg)

        quantized_acc = _evaluate(
            model, test_loader,
            qat=True, weight_bits=cfg.QAT_WEIGHT_BITS, levels=levels,
        )
        logger.info("[%s] QAT test accuracy = %.4f", topology.name, quantized_acc)

    # Stage 3: RTL-like fine-tune (2B-serial datapath with surrogate gradient).
    # This trains the EXACT datapath the RTL runs at inference — bit-plane
    # integer MAC + ADC clamp + LIF — so weights and thresholds co-adapt.
    rtl_fine_tune_epochs = getattr(cfg, "RTL_LIKE_FINE_TUNE_EPOCHS", 8)
    # Single-stage topologies: skip RTL-like fine-tune. It has no stage1
    # feedback to train through, and the v9b recipe destructively overrides
    # QAT weights (Fashion 64_10 went 75% QAT → 21% after RTL-like fine-tune).
    # Post-hoc threshold sweep on QAT weights is the right path for 1-stage.
    if rtl_fine_tune_epochs > 0 and topology.num_fc_stages == 1:
        logger.info(
            "[%s] num_fc_stages=1; skipping RTL-like fine-tune "
            "(use threshold sweep on QAT weights for 1-stage)",
            topology.name,
        )
        rtl_fine_tune_epochs = 0

    # Global skip switch (set RTL_SKIP_FINE_TUNE=True for datasets where the
    # v9b recipe calibration yields threshold floor → gradient death, e.g.,
    # Fashion-MNIST multi-layer crashed 72% QAT → 28% post RTL fine-tune).
    if getattr(cfg, "RTL_SKIP_FINE_TUNE", False):
        logger.info(
            "[%s] cfg.RTL_SKIP_FINE_TUNE=True; skipping RTL-like fine-tune",
            topology.name,
        )
        rtl_fine_tune_epochs = 0

    if rtl_fine_tune_epochs > 0:
        # Calibrate thresholds from an untrained-path forward pass so initial
        # spikes happen (~20 per neuron target), then let training refine them.
        _calibrate_rtl_thresholds(model, train_x_u8[:512], levels, target_count=20)
        logger.info(
            "[%s] RTL-like fine-tune: %d epochs, init thresholds = %s",
            topology.name, rtl_fine_tune_epochs,
            model.snapshot_thresholds(),
        )
        # SGD+momentum beat Adam empirically on this task (v5=78.9% vs v6=72.0%).
        # Surrogate gradient + integer STE gives noisy updates that Adam smooths
        # too aggressively. Keep LR at 0.1× main training LR.
        rtl_lr = lr * 0.1
        rtl_optimizer = optim.SGD(model.parameters(), lr=rtl_lr, momentum=cfg.ANN_MOMENTUM)
        train_ds_u8 = TensorDataset(train_x_u8, train_labels)
        train_loader_u8 = DataLoader(
            train_ds_u8, batch_size=batch_size, shuffle=True,
            generator=torch.Generator().manual_seed(seed + 1),
        )
        # GPT 2026-04-19 v8 loss: CE with temperature + rate homeostasis
        # (per-neuron target firing rate) + final count margin + saturation
        # + dead-neuron penalty. Addresses three degeneracies diagnosed:
        #   (1) stage N hidden count saturates to max_count (info compressed)
        #   (2) final stage threshold collapses to 1 (≈ sign(MAC))
        #   (3) final top1-top2 count margin too small (class 9 collapses)
        # Recipe presets per GPT 2026-04-19 ablation plan. Default hyper-parameter
        # values are selected by RTL_TRAINING_RECIPE in cfg; "custom" honors any
        # RTL_LAM_*/RTL_LOGIT_TEMP overrides the user sets directly.
        _recipe_presets = {
            # v7 baseline: saturation_penalty only — the proven 82.09% recipe.
            "v7":           dict(lam_sat=0.1,  lam_rate=0.0, lam_dead=0.0, lam_margin=0.0, logit_temp=1.0),
            # v7 + margin only (ablation: does margin alone push above v7?)
            "v7_margin":    dict(lam_sat=0.1,  lam_rate=0.0, lam_dead=0.0, lam_margin=0.1, logit_temp=1.0),
            # v7 + KD only (KD flag honored separately via RTL_LAM_KD)
            "v7_kd":        dict(lam_sat=0.1,  lam_rate=0.0, lam_dead=0.0, lam_margin=0.0, logit_temp=1.0),
            # v7 + margin + KD
            "v7_margin_kd": dict(lam_sat=0.1,  lam_rate=0.0, lam_dead=0.0, lam_margin=0.1, logit_temp=1.0),
            # v9b current run: everything but logit_temp
            "v9b":          dict(lam_sat=0.05, lam_rate=0.05, lam_dead=0.02, lam_margin=0.1, logit_temp=1.0),
        }
        recipe = getattr(cfg, "RTL_TRAINING_RECIPE", "v9b")
        preset = _recipe_presets.get(recipe, _recipe_presets["v9b"])
        logger.info("[%s] RTL fine-tune recipe = %s", topology.name, recipe)

        target_rate   = getattr(cfg, "RTL_RATE_HOMEOSTASIS_TARGET", 0.35)
        sat_cap       = getattr(cfg, "RTL_RATE_SAT_CAP", 0.75)
        dead_floor    = getattr(cfg, "RTL_RATE_DEAD_FLOOR", 0.02)
        lam_rate      = getattr(cfg, "RTL_LAM_RATE", preset["lam_rate"])
        lam_sat       = getattr(cfg, "RTL_LAM_SAT", preset["lam_sat"])
        lam_dead      = getattr(cfg, "RTL_LAM_DEAD", preset["lam_dead"])
        lam_margin    = getattr(cfg, "RTL_LAM_MARGIN", preset["lam_margin"])
        margin_target = getattr(cfg, "RTL_MARGIN_TARGET", 1.0)
        logit_temp    = getattr(cfg, "RTL_LOGIT_TEMP", preset["logit_temp"])

        # Optional KD teacher (pure-ReLU float model ≥90% acc). Load lazily.
        kd_alpha     = getattr(cfg, "RTL_LAM_KD", 0.0)
        kd_temp      = getattr(cfg, "RTL_KD_TEMP", 3.0)
        kd_ramp_eps  = getattr(cfg, "RTL_KD_RAMP_EPOCHS", 5)
        teacher = None
        teacher_path = cfg.get_topology_results_dir(topology.name) / "teacher.pt"
        if kd_alpha > 0 and teacher_path.exists():
            tdata = torch.load(teacher_path, map_location="cpu")
            teacher = MultiLayerANN(topology)
            teacher.load_state_dict(tdata["state_dict"], strict=False)
            teacher.eval()
            for p in teacher.parameters():
                p.requires_grad_(False)
            logger.info("[%s] KD teacher loaded (acc=%.4f) — T=%.1f, α=%.2f, ramp %d",
                        topology.name, tdata.get("test_accuracy", float("nan")),
                        kd_temp, kd_alpha, kd_ramp_eps)
        elif kd_alpha > 0:
            logger.warning("[%s] KD enabled (α=%.2f) but no teacher at %s",
                           topology.name, kd_alpha, teacher_path)

        for epoch in range(rtl_fine_tune_epochs):
            epoch_ce = 0.0
            epoch_rate = 0.0
            epoch_margin = 0.0
            num_batches = 0
            for inputs, labels in train_loader_u8:
                logits, intermediate = model.forward_rtl_like(
                    inputs, cfg.QAT_WEIGHT_BITS, levels, collect_intermediate=True
                )
                # (1) CE with logit temperature — counts are small ints (0-80),
                # CE gradient is weak without amplification.
                ce = criterion(logits * logit_temp, labels)

                # (2) Per-neuron rate homeostasis on intermediate stages.
                rate_loss = torch.tensor(0.0, device=logits.device)
                for stage_idx, interm in enumerate(intermediate):
                    max_count = 8.0 * float(topology.stages[stage_idx].timesteps)
                    rate = interm / max_count                    # [N, out_dim]
                    mean_per_neuron = rate.mean(dim=0)            # [out_dim]
                    # Deviation from target firing rate per hidden neuron.
                    homeostasis = ((mean_per_neuron - target_rate) ** 2).mean()
                    # Saturation and death penalties (per-sample).
                    over_sat  = torch.relu(rate - sat_cap).pow(2).mean()
                    under_dead = torch.relu(dead_floor - rate).pow(2).mean()
                    rate_loss = rate_loss + (
                        lam_rate * homeostasis + lam_sat * over_sat + lam_dead * under_dead
                    )

                # (3) Final count margin: true class count - max other count ≥ margin_target.
                N = logits.shape[0]
                true_count = logits[torch.arange(N), labels]
                mask = torch.ones_like(logits).scatter_(1, labels.unsqueeze(1), 0)
                other_max = (logits * mask - (1 - mask) * 1e6).max(dim=1).values
                margin = true_count - other_max
                margin_loss = torch.relu(margin_target - margin).mean()

                # KD loss (ramped from 0 over first kd_ramp_eps epochs).
                kd_loss = torch.tensor(0.0, device=logits.device)
                if teacher is not None:
                    ramp = min(1.0, (epoch + 1) / max(1, kd_ramp_eps))
                    with torch.no_grad():
                        teacher_logits = teacher.forward_pure_float(inputs / 255.0)
                    T = kd_temp
                    kd_loss = torch.nn.functional.kl_div(
                        torch.nn.functional.log_softmax(logits / T, dim=1),
                        torch.nn.functional.softmax(teacher_logits / T, dim=1),
                        reduction="batchmean",
                    ) * (T * T)
                    kd_term = kd_alpha * ramp * kd_loss
                else:
                    kd_term = torch.tensor(0.0, device=logits.device)

                loss = ce + rate_loss + lam_margin * margin_loss + kd_term

                rtl_optimizer.zero_grad()
                loss.backward()
                rtl_optimizer.step()
                epoch_ce += float(ce.item())
                epoch_rate += float(rate_loss.item())
                epoch_margin += float(margin_loss.item())
                num_batches += 1
            epoch_loss = (epoch_ce + epoch_rate + lam_margin * epoch_margin) / max(1, num_batches)
            avg = epoch_loss
            final_loss = avg
            ths = model.snapshot_thresholds()
            if log_every_epoch:
                logger.info(
                    "[%s] epoch %d/%d (RTL-like) ce=%.3f rate=%.3f margin=%.3f th=%s",
                    topology.name, epoch + 1, rtl_fine_tune_epochs,
                    epoch_ce / max(1, num_batches),
                    epoch_rate / max(1, num_batches),
                    epoch_margin / max(1, num_batches),
                    ths,
                )

        # Evaluate under RTL-like forward
        rtl_acc = _evaluate_rtl_like(model, test_x_u8, test_labels, levels, batch_size)
        logger.info("[%s] RTL-like fine-tune test accuracy = %.4f", topology.name, rtl_acc)
        quantized_acc = rtl_acc  # report this as the final quantized accuracy

    result = TrainResult(
        topology_name=topology.name,
        float_test_accuracy=float_acc,
        quantized_test_accuracy=quantized_acc,
        final_loss=final_loss,
        num_epochs=float_epochs + qat_epochs,
        qat_enabled=enable_qat,
    )
    return model, result


def save_model(model: MultiLayerANN, out_dir: Path) -> Path:
    """Save model weights + topology to ``<out_dir>/model.pt``."""
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "model.pt"
    torch.save(
        {"state_dict": model.state_dict(),
         "topology_name": model.topology.name,
         "num_fc_stages": model.topology.num_fc_stages},
        path,
    )
    return path


def load_model(path: Path, topology: TopologyConfig) -> MultiLayerANN:
    """Load model weights for a given topology."""
    data = torch.load(path, map_location="cpu")
    if data.get("topology_name") != topology.name:
        raise ValueError(
            f"Topology mismatch: checkpoint has {data.get('topology_name')!r}, "
            f"expected {topology.name!r}"
        )
    model = MultiLayerANN(topology)
    # strict=False: pre-2B-serial checkpoints (no act_log_scale) load cleanly;
    # missing act_log_scale stays at its zero init.
    missing, unexpected = model.load_state_dict(data["state_dict"], strict=False)
    if unexpected:
        raise ValueError(f"Checkpoint has unexpected keys: {unexpected}")
    # ``log_threshold`` is the pre-2026-04-19 parametrization (replaced by
     # ``raw_threshold + theta_min``). Both variants are allowed-missing so
    # checkpoints from either era reload cleanly.
    allowed_missing = {"act_log_scale", "log_threshold", "raw_threshold", "theta_min"}
    stray = [k for k in missing if k not in allowed_missing]
    if stray:
        raise ValueError(f"Checkpoint missing required keys: {stray}")
    model.eval()
    return model
