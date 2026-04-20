"""Vendored from V1 ``export_expected_spike_ids.py`` at 2026-04-19.

Integer RTL-like inference path. Used by:
    * A1.2 — V1 baseline bit parity (``run_baseline_64to10.py``)
    * A2.5 — RTL-like multilayer reference (single-stage inner call)
    * A3 — exporter bit-parity check (quantized-from-memory vs from-hex)

DO NOT EDIT. Must stay bit-identical to V1 so that the generated
``expected_classes.hex`` is reproducible.

Source: d:/SoC Design/SoC Design/项目相关文件/器件对齐/Python建模/export_expected_spike_ids.py
"""

from __future__ import annotations

from typing import Sequence

import torch

# ─────────────────────────────────────────────────────────────────────────
# RTL integer constants (V1 frozen as of 2026-04, see doc/03)
# ─────────────────────────────────────────────────────────────────────────
NUM_INPUTS: int = 64
NUM_OUTPUTS: int = 10
PIXEL_BITS: int = 8
LEVEL_MAX: int = 15                               # 4-bit => 16 levels [0, 15]
SUM_MAX: int = NUM_INPUTS * LEVEL_MAX             # 960
ADC_MAX: int = 255                                # 8-bit ADC full-scale


def rtl_adc_scale(raw_sum: int) -> int:
    """Reproduce RTL ADC scaling formula (integer, with half-step rounding).

    Mirrors V1 and the behavioral model in
    ``sim/models/cim_macro_blackbox_weighted_icarus.sv``.

    Must be bit-identical to V1: any deviation here causes A1.2 parity to fail.
    """
    scaled = (raw_sum * ADC_MAX + SUM_MAX // 2) // SUM_MAX
    return max(0, min(ADC_MAX, scaled))


def rtl_snn_inference(
    pixel_vec: Sequence[int],
    w_pos: Sequence[Sequence[int]],
    w_neg: Sequence[Sequence[int]],
    timesteps: int,
    threshold: int,
) -> tuple[list[int], int, list[int]]:
    """Integer-only SNN inference matching RTL semantics exactly.

    Args:
        pixel_vec: Length-``NUM_INPUTS`` pixel vector, ``uint8`` values 0-255.
        w_pos:     ``[NUM_INPUTS][NUM_OUTPUTS]`` int 0-``LEVEL_MAX`` positive weights.
        w_neg:     Same shape, negative weights.
        timesteps: Frame count (each frame = 8 bit-planes MSB→LSB).
        threshold: Absolute RTL threshold (e.g., 2550 for V1 baseline).

    Returns:
        ``(spike_counts, predicted_class, membrane_final)``.
    """
    membrane = [0] * NUM_OUTPUTS
    spike_counts = [0] * NUM_OUTPUTS

    for _frame in range(timesteps):
        for bit in range(PIXEL_BITS - 1, -1, -1):
            spike_input = [(pixel_vec[row] >> bit) & 1 for row in range(NUM_INPUTS)]

            for col in range(NUM_OUTPUTS):
                pos_sum = 0
                neg_sum = 0
                for row in range(NUM_INPUTS):
                    if spike_input[row]:
                        pos_sum += w_pos[row][col]
                        neg_sum += w_neg[row][col]

                adc_pos = rtl_adc_scale(pos_sum)
                adc_neg = rtl_adc_scale(neg_sum)
                diff = adc_pos - adc_neg

                membrane[col] += diff * (1 << bit)
                if membrane[col] >= threshold:
                    spike_counts[col] += 1
                    membrane[col] -= threshold

    predicted_class = spike_counts.index(max(spike_counts))
    return spike_counts, predicted_class, membrane


def pick_n_per_class(
    labels: torch.Tensor, samples_per_class: int, num_classes: int = NUM_OUTPUTS
) -> list[int]:
    """Return dataset indices for class-major ordering, N per class.

    Preserves V1 convention: for each class 0..N-1, take the first ``samples_per_class``
    occurrences in the dataset (in original order).

    Args:
        labels:            Tensor of shape ``[N]`` with integer class labels.
        samples_per_class: Samples to pick per class.
        num_classes:       Number of classes (default 10 for MNIST).

    Returns:
        List of length ``samples_per_class * num_classes`` with dataset indices.
    """
    if samples_per_class <= 0:
        raise ValueError("samples_per_class must be positive")

    picked: list[int] = []
    for cls in range(num_classes):
        hits = torch.nonzero(labels == cls, as_tuple=False).flatten()
        if hits.numel() < samples_per_class:
            raise RuntimeError(
                f"Class {cls} has only {hits.numel()} samples, need {samples_per_class}"
            )
        picked.extend(int(hit.item()) for hit in hits[:samples_per_class])
    return picked


def load_weight_hex(hex_path: str) -> list[list[int]]:
    """Load row-major HEX weights into ``[NUM_INPUTS][NUM_OUTPUTS]`` int matrix.

    File format:
        One hex value per line, row-major order. Total lines = ``NUM_INPUTS *
        NUM_OUTPUTS = 640``. Each value in ``[0, LEVEL_MAX=15]`` (4-bit).

    Bit-identical to V1 ``load_weight_hex`` in ``export_expected_spike_ids.py``.
    """
    with open(hex_path, "r", encoding="ascii") as f:
        values = [int(line.strip(), 16) for line in f if line.strip()]

    expected = NUM_INPUTS * NUM_OUTPUTS
    if len(values) != expected:
        raise ValueError(f"Expected {expected} entries in {hex_path}, got {len(values)}")

    weights: list[list[int]] = [[0] * NUM_OUTPUTS for _ in range(NUM_INPUTS)]
    for row in range(NUM_INPUTS):
        for col in range(NUM_OUTPUTS):
            weights[row][col] = values[row * NUM_OUTPUTS + col]
    return weights


def load_weight_hex_variable_shape(
    hex_path: str, in_dim: int, out_dim: int
) -> list[list[int]]:
    """Variant of ``load_weight_hex`` for V2 multi-layer topologies.

    V1 only has 64×10 weights, but V2 stages can be e.g. 64×32, 32×16, etc.
    The file layout is still row-major: ``[in_dim][out_dim]``.
    """
    with open(hex_path, "r", encoding="ascii") as f:
        values = [int(line.strip(), 16) for line in f if line.strip()]

    expected = in_dim * out_dim
    if len(values) != expected:
        raise ValueError(
            f"Expected {expected} entries in {hex_path} (shape {in_dim}x{out_dim}), "
            f"got {len(values)}"
        )

    weights: list[list[int]] = [[0] * out_dim for _ in range(in_dim)]
    for row in range(in_dim):
        for col in range(out_dim):
            weights[row][col] = values[row * out_dim + col]
    return weights
