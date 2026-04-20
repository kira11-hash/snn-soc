"""V2 multilayer modeling configuration.

V1 frozen parameters are hard-coded here (not imported from V1's ``config.py``)
so V2 has a single canonical value table and is resilient to V1 edits.

The V1 ``memristor_plugin.py`` (device model + I-V data) is still imported via
sys.path because it represents physical ground truth that V1 and V2 share.
"""

from __future__ import annotations

import sys
from pathlib import Path

# ─────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────
ROOT_DIR: Path = Path(__file__).resolve().parent
RESULTS_DIR: Path = ROOT_DIR / "results_multilayer"

# V1 Python directory (absolute path to "项目相关文件/器件对齐/Python建模").
# A1.2 baseline parity reads V1 HEX weights + alignment_manifest.json from here.
V1_PYTHON_DIR: Path = (
    ROOT_DIR.parent / "项目相关文件" / "器件对齐" / "Python建模"
).resolve()

# V1 device model directory. We import ``memristor_plugin.py`` from here because
# it depends on ``I-V.xlsx`` (physical measurements); copying would drift if the
# device team updates the I-V data.
V1_DEVICE_DIR: Path = (
    ROOT_DIR.parent / "项目相关文件" / "器件对齐" / "器件相关参数与数据"
).resolve()


def setup_v1_import_paths() -> None:
    """Add V1 directories to ``sys.path`` so ``memristor_plugin`` is importable.

    Called lazily (not at module import time) so tests that don't need V1 can
    skip this without hitting a missing-file error.
    """
    for candidate in (V1_DEVICE_DIR, V1_PYTHON_DIR):
        candidate_str = str(candidate)
        if candidate.exists() and candidate_str not in sys.path:
            sys.path.insert(0, candidate_str)


# ─────────────────────────────────────────────────────────────────────────
# V1 frozen parameters (copied from V1 config.py as of 2026-04-18)
#
# DO NOT import from V1 config.py. V2 owns these values so it is robust to
# V1 edits. If V1 changes these (which would violate the V1 freeze), update
# the values here manually after verifying the intent.
# ─────────────────────────────────────────────────────────────────────────

# QAT (quantization-aware training) parameters
QAT_WEIGHT_BITS: int = 4
QAT_USE_DEVICE_LEVELS: bool = True
QAT_NOISE_ENABLE: bool = True
QAT_NOISE_STD: float = 0.02
QAT_IR_DROP_COEFF: float = 0.05
POST_QUANT_FINE_TUNE_EPOCHS: int = 5

# ANN training hyperparameters (reused for MultiLayerANN base)
ANN_EPOCHS: int = 30
ANN_LR: float = 0.01
ANN_MOMENTUM: float = 0.9
ANN_BATCH_SIZE: int = 128

# SNN fixed parameters
PIXEL_BITS: int = 8       # 8-bit pixel => 8 bit-planes
NUM_OUTPUTS: int = 10     # MNIST classes
SPIKE_RESET_MODE: str = "soft"

# V1 frozen SNN inference config (locked via sweep)
THRESHOLD_RATIO_DEFAULT: float = 1.0 / 255.0
TIMESTEPS_DEFAULT: int = 10
ADC_BITS: int = 8
WEIGHT_BITS: int = 4
SCHEME: str = "B"
PREPROCESS_METHOD: str = "avgpool"
PREPROCESS_SIZE: int = 8

# RTL integer ADC scaling constants (see rtl_adc_scale)
# Values must match V1 export_expected_spike_ids.py header (NUM_INPUTS=64,
# LEVEL_MAX=15, ADC_MAX=255) and doc/03 behavioral model.
RTL_NUM_INPUTS: int = 64
RTL_LEVEL_MAX: int = 15            # 4-bit => 16 levels [0, 15]
RTL_SUM_MAX: int = RTL_NUM_INPUTS * RTL_LEVEL_MAX  # = 960
RTL_ADC_MAX: int = 255             # 8-bit ADC
RTL_ABSOLUTE_THRESHOLD: int = 2550  # = (1/255) × 255 × 10

# ─────────────────────────────────────────────────────────────────────────
# V2 multilayer-specific parameters
# ─────────────────────────────────────────────────────────────────────────
MULTILAYER_LR: float = 0.01
MULTILAYER_EPOCHS: int = 40                  # Multilayer may need more epochs
MULTILAYER_JOINT_TRAIN: bool = True          # End-to-end joint training
# Subsequent binary layers use per-stage YAML thresholds scaled to WL count.
SUBSEQUENT_LAYER_THRESHOLD_DEFAULT: int = 64

# RTL-like fine-tune phase (2B-serial bit-plane + ADC + LIF with surrogate
# gradient). Training's forward matches the RTL inference datapath exactly;
# this closes the gap between ReLU+STE proxy (~55%) and the 88%+ target.
RTL_LIKE_FINE_TUNE_EPOCHS: int = 50

# Training recipe preset. Controls which loss components are active for the
# RTL-like fine-tune phase. Allows clean single-variable ablation per GPT
# 2026-04-19 guidance (v9 multi-补丁 combination punch was unstable).
#
#   "v7"            — saturation_penalty only (reproduces v7 82.09% baseline)
#   "v7_margin"     — v7 + margin loss
#   "v7_kd"         — v7 + KD teacher distillation
#   "v7_margin_kd"  — v7 + margin + KD
#   "v9b"           — v9 full recipe minus logit_temp (current run)
#   "custom"        — honor individual RTL_LAM_* / RTL_LOGIT_TEMP overrides
RTL_TRAINING_RECIPE: str = "v9b"

# Refractory spike cap per frame (GPT 2026-04-19 P1). None = classic LIF;
# K=2 caps max_count at 2*timesteps (for timesteps=10 → max=20);
# K=4 caps at 4*timesteps → max=40. Diagnoses v9b 64_64_10 showed stage 0
# p50=79 p90=80 saturated; refractory prevents that by enforcing per-frame
# max fire count. Requires RTL counterpart (per-neuron per-frame counter)
# before RTL ↔ Python bit parity can pass with this enabled.
RTL_REFRACTORY_K: int | None = None  # v10 K=2 regressed -6.5pp; disabled

# KD (knowledge distillation) from pure-float teacher. Set RTL_LAM_KD > 0 to
# enable. Teacher must exist at results_multilayer/<topo>/teacher.pt
# (train via train_teacher.py). Per GPT: T=3, α=0.3, ramp first 5 epochs.
RTL_LAM_KD: float = 0.0  # KD on MNIST didn't help (v11 -0.85pp); disabled
RTL_KD_TEMP: float = 3.0
RTL_KD_RAMP_EPOCHS: int = 5

# Skip RTL-like fine-tune entirely. Use when calibration pathology occurs
# (e.g., Fashion 64_32_10 crashed 72% QAT → 28% in RTL fine-tune due to
# threshold=[2,1] saturation floor). Fallback: QAT weights + post-hoc
# threshold sweep gives the best achievable RTL-like accuracy.
RTL_SKIP_FINE_TUNE: bool = False


# ─────────────────────────────────────────────────────────────────────────
# Convenience accessors
# ─────────────────────────────────────────────────────────────────────────
def get_topology_results_dir(topology_name: str) -> Path:
    """Per-topology output directory (created on demand)."""
    path = RESULTS_DIR / topology_name
    path.mkdir(parents=True, exist_ok=True)
    return path


def get_weights_dir(topology_name: str) -> Path:
    """Per-topology weights subdirectory."""
    path = get_topology_results_dir(topology_name) / "weights"
    path.mkdir(parents=True, exist_ok=True)
    return path
