"""V2 parameterized ADC scale helper.

V1 path (8×8 count-bitplane legacy) uses vendored ``rtl_adc_scale`` with
``SUM_MAX=960`` unchanged — see ``_vendored_from_v1/integer_reference.py``.

V2 streamed-rate path uses this module's ``rtl_adc_scale_v2`` with per-stage
``sum_max`` (= active_wl_count × LEVEL_MAX or fixed array_max) and
``adc_bits`` (8 / 10 / 12).

Per GPT 2026-04-20 REV 2 critical fix #1: V1 vendored code must stay frozen
so ``test_baseline_parity`` (V1 100/100 bit parity) never breaks.
"""

from __future__ import annotations

LEVEL_MAX_4BIT = 15  # 4-bit weight level cap [0, 15]


def sum_max_for_stage(in_dim: int, array_rows: int | None = None,
                       mode: str = "active_wl") -> int:
    """Compute ``sum_max`` for a stage according to ``adc_full_scale`` policy.

    Args:
        in_dim: Active WL count for this stage (= stage.in_dim).
        array_rows: Physical CIM array WL count (e.g., 256). Required for ``array`` mode.
        mode: ``'active_wl'`` → ``in_dim * 15`` (per-layer variable);
              ``'array'`` → ``array_rows * 15`` (fixed across layers).

    Returns:
        ``sum_max`` integer used as ADC full-scale reference.
    """
    if mode == "active_wl":
        return in_dim * LEVEL_MAX_4BIT
    if mode == "array":
        if array_rows is None:
            raise ValueError("array_rows required for adc_full_scale='array'")
        return array_rows * LEVEL_MAX_4BIT
    raise ValueError(f"Unknown adc_full_scale mode: {mode!r}")


def rtl_adc_scale_v2(raw_sum: int, sum_max: int, adc_bits: int = 8) -> int:
    """V2 parameterized ADC scale with configurable ``sum_max`` and ``adc_bits``.

    Formula (bit-identical to V1 but parametrized)::

        adc_max = (1 << adc_bits) - 1
        scaled  = (raw_sum * adc_max + sum_max // 2) // sum_max
        return  max(0, min(adc_max, scaled))

    Args:
        raw_sum: Integer MAC sum before ADC. Expected in ``[0, sum_max]``.
        sum_max: ADC full-scale reference (see ``sum_max_for_stage``).
        adc_bits: ADC resolution in bits (8 / 10 / 12). 8 matches V1.

    Returns:
        Integer ADC output in ``[0, adc_max]`` where ``adc_max = 2^adc_bits - 1``.
    """
    if adc_bits < 1 or adc_bits > 16:
        raise ValueError(f"adc_bits must be in [1, 16], got {adc_bits}")
    if sum_max <= 0:
        raise ValueError(f"sum_max must be > 0, got {sum_max}")
    adc_max = (1 << adc_bits) - 1
    scaled = (raw_sum * adc_max + sum_max // 2) // sum_max
    return max(0, min(adc_max, scaled))


def neuron_data_width_for(adc_bits: int) -> int:
    """Signed neuron membrane bit-width matching ``adc_bits`` diff range.

    For ADC diff in ``[-adc_max, +adc_max]`` we need ``adc_bits + 1`` signed
    bits (one sign bit). Downstream LIF membrane may need extra headroom for
    bit-plane-weighted accumulation — caller should add ``ceil(log2(T*8))``
    as needed, but for true streamed-rate only ``adc_bits + 1`` is required.
    """
    return adc_bits + 1
