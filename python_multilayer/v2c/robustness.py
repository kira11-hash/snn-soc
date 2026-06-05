"""V2C Phase 3: non-ideal robustness of the digital binary CIM (the project's SOTA-able axis).

The V2C cells are BINARY and read by a 1-bit digital sense amp (NO ADC). Device non-idealities are
therefore digital bit errors on the packed cells — not the analog conductance variation / ADC
quantization / drift that costs analog CIM accuracy (and which a digital binary array is immune to by
construction). This module injects those digital faults and measures the deployed degradation, so we
can show V2C degrades gracefully under the *remaining* (digital) error model while the analog error
paths it structurally removes are anchored in the literature (RVComp / NeuRRAM / NatComm weight-
programming — see V2C_Codex审查_Phase-AB.md). We deliberately do NOT plot a head-to-head "digital
fault-rate r vs analog σ" curve (different physical quantities — Codex#3).

Fault physics (Codex#3 P1.3), on the packed binary cells ``[in, out*W]`` (``encoding.pack``):
  * ``stuck0`` / ``stuck1`` — cells permanently 0 / 1 (stuck-at / write-fail), a STATIC pattern.
  * ``invert``              — static sense-margin inversion (a fixed subset reads flipped).
  * ``read_ber``            — ASYMMETRIC read bit-error: a stored 1 (LRS) reads 0 w.p. ``p10``, a
                              stored 0 (HRS) reads 1 w.p. ``p01`` (map from device currents via
                              :func:`read_ber_from_device`). A fresh pattern per trial.

Two robustness views:
  * FULL-FRAME (argmax final membrane) — isolates fault impact on the decision surface.
  * DEPLOYED early-exit — the same cell faults also shift firing/threshold-crossing TIMES, so we also
    decode with the *frozen, clean-calibrated* per-class thresholds and report accuracy AND latency
    degradation (Codex#3 P1.2: full-frame != the deployed early-exit number). Pure numpy.
"""
from __future__ import annotations

import numpy as np

try:  # package import
    from . import convert as C
except ImportError:  # direct-module import (v2c on sys.path) — tests / venv
    import convert as C

FAULT_MODES = ("stuck0", "stuck1", "invert", "read_ber")


def read_ber_from_device(mu_lrs=1.0, sigma_lrs=0.15, mu_hrs=0.05, sigma_hrs=0.02, i_th=0.5):
    """Map device read currents to an ASYMMETRIC read-BER (Codex#3 pre-RTL#3). LRS(=1) and HRS(=0) cell
    currents ~ N(μ,σ); a 1-bit sense amp thresholds at ``i_th``. Returns ``(p10, p01)``:
    ``p10 = P(LRS reads < i_th)``, ``p01 = P(HRS reads > i_th)`` (normal CDF). Units arbitrary/relative."""
    from math import erf, sqrt
    phi = lambda z: 0.5 * (1.0 + erf(z / sqrt(2.0)))
    p10 = phi((i_th - mu_lrs) / max(sigma_lrs, 1e-9))         # LRS(stored 1) sensed below threshold -> 0
    p01 = 1.0 - phi((i_th - mu_hrs) / max(sigma_hrs, 1e-9))   # HRS(stored 0) sensed above threshold -> 1
    return float(p10), float(p01)


def inject_cell_faults(cells, mode, rng, rate=0.0, p10=0.0, p01=0.0):
    """Faulted COPY of packed binary ``cells``. ``stuck0``/``stuck1``/``invert`` use ``rate`` (each cell
    i.i.d. w.p. rate); ``read_ber`` is asymmetric (stored 1 -> 0 w.p. ``p10``, stored 0 -> 1 w.p. ``p01``)."""
    cells = np.asarray(cells)
    out = cells.copy()
    if mode not in FAULT_MODES:
        raise ValueError(f"unknown fault mode {mode!r}; use one of {FAULT_MODES}")
    if mode == "read_ber":
        ones, zeros = cells == 1, cells == 0
        out[ones & (rng.random(cells.shape) < p10)] = 0
        out[zeros & (rng.random(cells.shape) < p01)] = 1
        return out
    if rate <= 0:
        return out
    mask = rng.random(cells.shape) < rate
    if mode == "stuck0":
        out[mask] = 0
    elif mode == "stuck1":
        out[mask] = 1
    else:  # invert (static sense-margin inversion)
        out[mask] = 1 - out[mask]
    return out


def _inject_layers(layers, mode, rng, rate=0.0, p10=0.0, p01=0.0):
    return [(inject_cell_faults(cells, mode, rng, rate, p10, p01), W, out_dim, thr)
            for (cells, W, out_dim, thr) in layers]


def _faulted_traj(layers, images, T, in_bits, mode, rng, rate, p10, p01, n_eval):
    faulted = _inject_layers(layers, mode, rng, rate, p10, p01)
    return C.ramp_output_trajectories(None, images, T, in_bits=in_bits, n_eval=n_eval, layers=faulted)


def robustness_sweep(model, images, labels, T, in_bits=4, mode="invert",
                     rates=(0.0, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2), n_eval=2000, trials=5, seed=0,
                     p10=0.0, p01=0.0):
    """FULL-FRAME (argmax final membrane) accuracy vs fault level for one ``mode``, averaged over
    ``trials`` fault patterns. For ``read_ber`` the x-axis is the (p10,p01) scale via ``rates`` (used as
    a multiplier on the base p10/p01). Returns ``{level: (mean_acc, std_acc)}``."""
    rng = np.random.default_rng(seed)
    layers, _ = C.export_v2c_layers(model)
    y = np.asarray(labels)
    out = {}
    for lv in rates:
        accs = []
        for _ in range(trials):
            traj, n = _faulted_traj(layers, images, T, in_bits, mode, rng,
                                    rate=lv, p10=p10 * lv if mode == "read_ber" else p10,
                                    p01=p01 * lv if mode == "read_ber" else p01, n_eval=n_eval)
            accs.append(float((traj[:, -1, :].argmax(axis=1) == y[:n]).mean()))
        out[float(lv)] = (float(np.mean(accs)), float(np.std(accs)))
    return out


def deployed_robustness_sweep(model, theta_out, images, labels, T, in_bits=4, mode="invert",
                              rates=(0.0, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2), n_eval=2000, trials=5,
                              seed=0, p10=0.0, p01=0.0):
    """DEPLOYED early-exit robustness (Codex#3 P1.2): decode the faulted trajectories with the FROZEN,
    clean-calibrated per-class integer thresholds ``theta_out`` (strict early-exit), so faults degrade
    BOTH accuracy and latency (cell faults shift firing/threshold-crossing times). Returns
    ``{level: (acc_mean, acc_std, lat_mean, lat_std)}``."""
    rng = np.random.default_rng(seed)
    layers, _ = C.export_v2c_layers(model)
    theta_out = np.asarray(theta_out, dtype=np.int64)
    y = np.asarray(labels)
    out = {}
    for lv in rates:
        accs, lats = [], []
        for _ in range(trials):
            traj, n = _faulted_traj(layers, images, T, in_bits, mode, rng,
                                    rate=lv, p10=p10 * lv if mode == "read_ber" else p10,
                                    p01=p01 * lv if mode == "read_ber" else p01, n_eval=n_eval)
            preds, lat = C.strict_decode_from_traj(traj, theta_out, T)
            accs.append(float((preds == y[:n]).mean()))
            lats.append(float(lat.mean()))
        out[float(lv)] = (float(np.mean(accs)), float(np.std(accs)), float(np.mean(lats)), float(np.std(lats)))
    return out


# --- ANALOG CIM baseline (illustrative/optimistic — NOT a calibrated device model) -------------------
# Same matched-ANN W4 integer weights, MAC with the analog non-idealities a digital binary array is
# immune to. Per Codex#3: fixed CALIBRATION-set ADC range (not a test-batch oracle max) + COLUMN
# gain/offset/read-noise (systematic terms that do NOT average out over the MAC fan-in, unlike the
# per-weight σ which largely does). Still optimistic (no drift / IR-drop / finite on-off / differential
# G+/G-); the strong "analog is fragile" claim is anchored in published σ/drift/SAF numbers, not here.

def calibrate_adc_range(s_cal: np.ndarray) -> np.ndarray:
    """Per-output ADC full-scale fixed from a CALIBRATION pass (max|sum| per column). Used at deploy as
    a FIXED range (not re-derived from the eval batch — that was the oracle-calibration flaw, Codex#3)."""
    return np.abs(np.asarray(s_cal)).max(axis=0) + 1e-12


def _analog_layer(x, W_int, scale, sigma, R_col, adc_bits, g_col, b_col, sigma_read, rng):
    """Analog MAC + column non-idealities + fixed-range ADC. ``R_col`` is the fixed per-output full-scale,
    ``g_col``/``b_col`` per-column gain/offset (systematic, non-averaging), ``sigma_read`` read noise."""
    W_pert = W_int * (1.0 + sigma * rng.standard_normal(W_int.shape))     # per-weight conductance variation
    s = x @ W_pert.T
    s = g_col * s + b_col + sigma_read * R_col * rng.standard_normal(s.shape)   # column gain/offset + read noise
    if adc_bits is not None:                                              # fixed-range ADC quantization
        step = 2.0 * R_col / ((1 << adc_bits) - 1)
        s = np.round(s / step) * step
    return s * scale.reshape(1, -1)


def analog_reference_sweep(ann, images, labels, in_bits=4, adc_bits=6, sigmas=(0.0, 0.05, 0.1, 0.2, 0.3),
                           sigma_gain=0.02, sigma_off=0.02, sigma_read=0.02, n_eval=2000, trials=5, seed=0):
    """Illustrative/optimistic analog-CIM accuracy vs per-weight conductance σ, with fixed-cal ADC +
    per-column gain/offset/read-noise. Averaged over ``trials`` device instances. Returns ``{σ: (mean,std)}``.
    NB this UNDERSTATES real analog fragility (no drift/IR-drop/on-off); see the literature anchors."""
    rng = np.random.default_rng(seed)
    n = len(images) if n_eval is None else min(int(n_eval), len(images))
    levels = (1 << in_bits) - 1
    x_in = np.round(np.asarray(images)[:n].astype(np.float64) / 255.0 * levels) / levels
    y = np.asarray(labels)[:n]
    act_hi = float(ann.act_hi)
    W0 = ann.layers[0].export_int().cpu().numpy().astype(np.float64)
    s0 = ann.layers[0].scale.detach().cpu().numpy().reshape(-1)
    W1 = ann.layers[1].export_int().cpu().numpy().astype(np.float64)
    s1 = ann.layers[1].scale.detach().cpu().numpy().reshape(-1)
    R0 = calibrate_adc_range(x_in @ W0.T)                                 # fixed ADC range from clean calib
    h_cal = act_hi * (np.maximum((x_in @ W0.T) * s0.reshape(1, -1), 0.0) >= act_hi / 2.0)
    R1 = calibrate_adc_range(h_cal @ W1.T)
    out = {}
    for sg in sigmas:
        accs = []
        for _ in range(trials):
            g0 = 1.0 + sigma_gain * rng.standard_normal(W0.shape[0]); b0 = sigma_off * R0 * rng.standard_normal(W0.shape[0])
            g1 = 1.0 + sigma_gain * rng.standard_normal(W1.shape[0]); b1 = sigma_off * R1 * rng.standard_normal(W1.shape[0])
            z0 = _analog_layer(x_in, W0, s0, sg, R0, adc_bits, g0, b0, sigma_read, rng)
            h = act_hi * (np.maximum(z0, 0.0) >= act_hi / 2.0)
            z1 = _analog_layer(h, W1, s1, sg, R1, adc_bits, g1, b1, sigma_read, rng)
            accs.append(float((z1.argmax(axis=1) == y).mean()))
        out[float(sg)] = (float(np.mean(accs)), float(np.std(accs)))
    return out
