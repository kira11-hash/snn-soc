"""V2C experiment campaign: ANN ceiling (E0-E6, Phase 1) + SNN bridge (E7, into Phase 2).

E0-E6 drive ``train.train_model`` across configs/seeds (mean±std). The matched-ANN config
(``bias=False, input_bits=4, act_bits=1, W=4``) is the deployable spiking net's accuracy *ceiling*;
these experiments push it with PPA-neutral training tricks only (no change to the binary cell, no
inference-time cost). FINDING: the cold E0 recipe (87.2%) is already at that ceiling — PACT/staged-
QAT/KD give no gain. E7 then inits the spiking net from the best ANN and reports the deployed golden
latency-accuracy Pareto (strict / guard-window / full-frame). See V2C_6b6c_接力文档.md / PROGRESS.md.

NB ``train.train_model`` records per-epoch accuracy on the RAW net but copies EMA weights into the
returned net only at the end, so ``history[-1]['test_acc']`` is the raw last-epoch number, NOT the
deployed EMA accuracy. We re-evaluate the returned (EMA) net here for the authoritative figure.

Run (in the v2c venv):
  ./.venv-v2c/bin/python python_multilayer/v2c/experiments.py E0 --seeds 5 --epochs 50
  ./.venv-v2c/bin/python python_multilayer/v2c/experiments.py E7 --seeds 1 --epochs 50 --T 16
"""
from __future__ import annotations

import argparse
import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import train as T          # noqa: E402  (after sys.path insert)
import data as D           # noqa: E402
import convert as C        # noqa: E402

# The matched 1-bit-hidden ANN that the deployed spiking net inherits from (init-from-ann).
MATCHED = dict(dataset="fashion_mnist", arch="main", W=4, bias=False,
               input_bits=4, act_bits=1, act_hi=2.0)


def _test_xy(dataset, dev):
    te_imgs, te_labels = D.load_dataset(dataset, train=False)
    return T._to_xy(te_imgs, te_labels, dev)


def _summarize(name, accs, tag=""):
    mean = statistics.mean(accs)
    std = statistics.pstdev(accs) if len(accs) > 1 else 0.0
    if tag:
        print(f"[{name}] {tag}", flush=True)
    print(f"[{name}] n={len(accs)}: mean={mean:.4f} std={std:.4f} "
          f"min={min(accs):.4f} max={max(accs):.4f} accs={[round(a, 4) for a in accs]}", flush=True)
    return accs


def run_seeds(name, train_fn, seeds, dataset, tag=""):
    """Run ``train_fn(seed) -> net`` over ``seeds``, eval EMA (deployed) net, report mean±std."""
    dev = T.pick_device("auto")
    xte, yte = _test_xy(dataset, dev)
    accs = []
    for s in seeds:
        net = train_fn(s)
        acc = T.evaluate_proxy(net, xte, yte)                      # EMA weights = deployed
        accs.append(acc)
        print(f"[{name}] seed={s} ema_acc={acc:.4f}", flush=True)
    return _summarize(name, accs, tag)


def run_config(name, cfg, seeds, epochs, verbose=False):
    """Train a single-phase ``cfg`` over ``seeds`` and report EMA test acc mean±std."""
    def train_fn(s):
        net, _ = T.train_model(seed=s, epochs=epochs, verbose=verbose, **cfg)
        return net
    return run_seeds(name, train_fn, seeds, cfg["dataset"], tag=f"cfg={cfg} epochs={epochs}")


def cmd_E0(args):
    """Baseline matched ANN."""
    run_config("E0", MATCHED, list(range(args.seeds)), args.epochs, args.verbose)


def cmd_E2(args):
    """act_hi grid for the 1-bit-hidden matched ANN (the 1-bit threshold is ~act_hi/2)."""
    grid = [1.0, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0]
    for hi in grid:
        run_config(f"E2_hi{hi}", {**MATCHED, "act_hi": hi},
                   list(range(args.seeds)), args.epochs, args.verbose)


def cmd_E3(args):
    """PACT: learnable activation clip (alpha init = MATCHED act_hi=2.0) co-adapting with weights."""
    run_config("E3_pact", {**MATCHED, "pact": True}, list(range(args.seeds)), args.epochs, args.verbose)


def staged_train(seed, base, phase_epochs=(20, 10, 15, 10), lr_finetune=2e-4, verbose=False):
    """Staged QAT: warm-start through progressively harder quantization (LSQ/DoReFa practice — cold
    low-bit training underperforms a warmed-up net). Each phase loads the previous phase's EMA weights.
      A: float input + float act (W4 weights only)  -> B: +4-bit input  -> C: +1-bit act
      D: low-lr fine-tune at the final (in4/act1) precision.
    Later phases warm-start so they need far fewer epochs; ``phase_epochs`` defaults to a 55-epoch
    total (~ E0's 50ep cold budget) so a win reflects the schedule, not extra compute. ``base`` =
    dataset/arch/W/bias/act_hi (target config minus the quant bits). Returns the phase-D net."""
    ea, eb, ec, ed = phase_epochs
    netA, _ = T.train_model(seed=seed, epochs=ea, input_bits=None, act_bits=None,
                            verbose=verbose, **base)
    netB, _ = T.train_model(seed=seed, epochs=eb, input_bits=4, act_bits=None,
                            warm_start_state=netA.state_dict(), verbose=verbose, **base)
    netC, _ = T.train_model(seed=seed, epochs=ec, input_bits=4, act_bits=1,
                            warm_start_state=netB.state_dict(), verbose=verbose, **base)
    netD, _ = T.train_model(seed=seed, epochs=ed, lr=lr_finetune, input_bits=4, act_bits=1,
                            warm_start_state=netC.state_dict(), verbose=verbose, **base)
    return netD


def cmd_E4(args):
    """Staged QAT vs the cold-trained E0 baseline (same final in4/act1/W4/act_hi=2.0 config, ~equal
    epoch budget). ``--epochs`` overrides phase-A length; B/C/D scale with it."""
    base = dict(dataset="fashion_mnist", arch="main", W=4, bias=False, act_hi=2.0)
    ea = args.epochs
    pe = (ea, max(1, ea // 2), max(1, int(ea * 0.75)), max(1, ea // 2))   # default (20,10,15,10)
    run_seeds("E4_staged", lambda s: staged_train(s, base, pe, verbose=args.verbose),
              list(range(args.seeds)), base["dataset"],
              tag=f"phase_epochs(A,B,C,D)={pe} lr_ft=2e-4 vs E0 cold")


def cmd_E5(args):
    """Teacher-assistant KD: a SAME-ARCH same-W4 but full-precision-activation teacher (float in/act,
    ~88.2% per the Pareto — the precision ceiling for these weights) distills the matched in4/act1
    student. Same-arch teacher = closest output distribution, so KD lifts the student without the
    mismatch a big CNN teacher would impose. Teacher trained once (seed 0), reused across student seeds."""
    common = dict(dataset="fashion_mnist", arch="main", W=4, bias=False, act_hi=2.0)
    assistant, _ = T.train_model(seed=0, epochs=args.epochs, input_bits=None, act_bits=None,
                                 verbose=args.verbose, **common)

    def train_fn(s):
        net, _ = T.train_model(seed=s, epochs=args.epochs, input_bits=4, act_bits=1,
                               teacher=assistant, kd_alpha=0.5, kd_temp=4.0,
                               verbose=args.verbose, **common)
        return net
    run_seeds("E5_ta_kd", train_fn, list(range(args.seeds)), common["dataset"],
              tag=f"assistant=main/W4/float-act -> student=in4/act1; kd_alpha=0.5 epochs={args.epochs}")


def cmd_E6(args):
    """Constant bias row (ANN): the affine bias realized as one extra always-active W-cell row. On the
    reference ANN this is exactly ``bias=True``; ~+0.3pp expected (the SNN-side benefit, where the
    threshold can't fully absorb an affine bias, is the Phase-2 test). vs E0's bias=False."""
    run_config("E6_bias", {**MATCHED, "bias": True}, list(range(args.seeds)), args.epochs, args.verbose)


def cmd_E7(args):
    """Bridge into Phase 2: init the deployed spiking net from the best (cold matched) ANN — which is
    exactly what ``train_spiking --init-from-ann`` trains internally — in the ramp TTFS dynamic, then
    report the golden latency-accuracy Pareto: strict early-exit (the deployed number) / guard-window
    Δ (wait Δ cycles after the first spike — recovers a wrong class that spiked one cycle early, NO
    retraining) / full-frame (timing-free ceiling). Current best strict = 81.25% (handoff)."""
    import train_spiking as TS                                   # local import (pulls torch + spiking)
    te_imgs, te_labels = D.load_dataset("fashion_mnist", train=False)
    for s in range(args.seeds):
        model, hist = TS.train_spiking(
            dataset="fashion_mnist", arch="main", W=4, T=args.T, epochs=args.epochs,
            input_mode="ramp", in_bits=4, fire_fraction=0.5, init_from_ann=True,
            kd_alpha=0.2, ann_act_hi=2.0, seed=s, verbose=args.verbose)
        r = C.eval_ttfs_ramp_modes(model, te_imgs, te_labels, args.T, in_bits=4,
                                   deltas=(1, 2, 4), n_eval=args.n_eval)
        full_frame_monitor = hist[-1]["test_acc"]                # training hard-classify (full-frame)
        print(f"[E7] seed={s} T={args.T} n_eval={r['n']} | "
              f"strict={r['strict']['acc']:.4f}@t≈{r['strict']['latency']:.1f}  "
              f"guardΔ1={r['guard'][1]['acc']:.4f}@{r['guard'][1]['latency']:.1f}  "
              f"guardΔ2={r['guard'][2]['acc']:.4f}@{r['guard'][2]['latency']:.1f}  "
              f"guardΔ4={r['guard'][4]['acc']:.4f}@{r['guard'][4]['latency']:.1f}  "
              f"full={r['full_frame']['acc']:.4f}@{args.T}  (train-monitor={full_frame_monitor:.4f})",
              flush=True)


def _gate_init_snn(snn, ann, T_steps, act_hi=2.0, in_bits=4):
    """Copy ANN weights+scale into the spiking net and set its HIDDEN integer threshold to the ANN
    1-bit-gate equivalent: softplus(log_thr_hidden) = T·(act_hi/2)·levels_in, so export rounds it by
    /scale per output (boundary exact up to torch.round's half-to-even tie — see model._quant_unsigned)."""
    import torch
    levels_in = (1 << in_bits) - 1
    with torch.no_grad():
        for sl, al in zip(snn.layers, ann.layers):
            sl.weight.copy_(al.weight)
            sl.log_scale.copy_(al.log_scale)
        snn.log_thr[0].fill_(T_steps * (act_hi / 2.0) * levels_in)
    return snn


def cmd_E8(args):
    """Gate-init diagnostics (P1.2) + output-threshold calibration Pareto (F3). Trains the matched ANN
    once, inits the SNN from it with the ANN-gate hidden threshold (θ=round(T·(act_hi/2)·levels_in/
    scale)), then — NO spiking training:
      (A) verifies full-frame≈ANN is REAL, not a subset/discriminator artifact: same-subset ANN acc,
          ANN-vs-SNN-full pred agreement, hidden-gate agreement (on n_eval), output-scale CV, and
          integer-argmax vs scaled-argmax agreement (does dropping the per-class output scale flip the
          decision?);
      (B) sweeps the output threshold θ_out[k]=round(c/scale_out[k]) over c -> the strict early-exit
          latency-accuracy Pareto (full-frame is the c->∞, timing-free ceiling)."""
    import torch
    import spiking as S
    in_bits, act_hi = 4, 2.0
    te_imgs, te_labels = D.load_dataset(args.dataset, train=False)
    dev = T.pick_device("auto")
    xte, yte = _test_xy(args.dataset, dev)
    n = args.n_eval
    ann, _ = T.train_model(dataset=args.dataset, arch="main", W=4, epochs=args.epochs,
                           input_bits=in_bits, act_bits=1, bias=False, act_hi=act_hi,
                           seed=0, verbose=args.verbose)
    ann_acc_10k = T.evaluate_proxy(ann, xte, yte)
    ann_acc_sub = T.evaluate_proxy(ann, xte[:n], yte[:n])
    ann = ann.cpu()
    # ---- (A) P1.2 diagnostics: is full-frame≈ANN real? ----
    x01 = torch.from_numpy(te_imgs[:n].astype("float32") / 255.0)
    y_sub = torch.from_numpy(te_labels[:n].astype("int64"))
    with torch.no_grad():
        ann_pred = ann(x01).argmax(1)                                  # scaled logits = ANN's real decision
        occ = ann.hidden_acts(x01)[0]                                  # [n,246] 1-bit hidden occurrence
        w_out_int = ann.layers[-1].export_int().float()               # [10,246]
        int_pred = (occ @ w_out_int.t()).argmax(1)                     # scale-free integer-MAC argmax
        sc_out = ann.layers[-1].scale.detach().squeeze(-1)            # [10] per-class output scale
    int_vs_scaled = float((int_pred == ann_pred).float().mean())      # dropping output scale flips decision?
    cv = float((sc_out.std() / sc_out.mean()).abs())
    snn = S.V2CSpikingMLP([784, 246, 10], 4, T=args.T)
    _gate_init_snn(snn, ann, args.T, act_hi, in_bits)
    with torch.no_grad():
        snn_fired = (snn.per_layer_first_times(S.encode_ramp(x01, args.T, in_bits))[0] < args.T).float()
        gate_agree = float((snn_fired == occ).float().mean())         # SNN hidden fires vs ANN 1-bit active
        _, mem_int, _, _ = snn(S.encode_ramp(x01, args.T, in_bits))
        snn_full_pred = mem_int.argmax(1)                              # SNN full-frame decision
    snn_full_acc = float((snn_full_pred == y_sub).float().mean())
    snn_vs_ann = float((snn_full_pred == ann_pred).float().mean())
    print(f"[E8-diag] ANN acc 10k={ann_acc_10k:.4f} sub(n={n})={ann_acc_sub:.4f} | "
          f"SNN full-frame={snn_full_acc:.4f} | SNN-vs-ANN pred-agree={snn_vs_ann:.4f} | "
          f"hidden-gate agree={gate_agree:.4f} | out-scale CV={cv:.3f} | "
          f"int-vs-scaled argmax agree={int_vs_scaled:.4f}", flush=True)
    # ---- (B) F3 output-threshold sweep -> strict latency-accuracy Pareto ----
    for c in [0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0, 8.0, 16.0, 32.0]:
        with torch.no_grad():
            snn.log_thr[1].fill_(float(c))                            # softplus(c)~c -> θ_out=round(c/scale_out)
        r = C.eval_ttfs_ramp_modes(snn, te_imgs, te_labels, args.T, in_bits=in_bits, deltas=(2,), n_eval=n)
        print(f"[E8-sweep] c={c:6.1f} strict={r['strict']['acc']:.4f}@t≈{r['strict']['latency']:.1f} "
              f"guardΔ2={r['guard'][2]['acc']:.4f}@{r['guard'][2]['latency']:.1f} "
              f"full={r['full_frame']['acc']:.4f}", flush=True)


def cmd_E9(args):
    """Causal ablation (P1.1): hold the HIDDEN threshold init at the ANN-gate value and run FULL
    spiking training, vs E8's gate-init + no-train (full-frame ~87.85%). Isolates the confound in
    断言 C (E7 = fire_fraction-init + train; E8 = gate-init + no-train):
      full-frame stays high -> training is fine; E7's drop was the fire_fraction hidden-threshold init;
      full-frame drops      -> surrogate training itself drags full-frame down."""
    import train_spiking as TS
    te_imgs, te_labels = D.load_dataset("fashion_mnist", train=False)
    for s in range(args.seeds):
        model, _ = TS.train_spiking(dataset="fashion_mnist", arch="main", W=4, T=args.T,
                                    epochs=args.epochs, input_mode="ramp", in_bits=4,
                                    init_from_ann=True, gate_threshold_init=True, fire_fraction=0.5,
                                    kd_alpha=0.2, ann_act_hi=2.0, seed=s, verbose=args.verbose)
        r = C.eval_ttfs_ramp_modes(model, te_imgs, te_labels, args.T, in_bits=4, deltas=(1, 2, 4),
                                   n_eval=args.n_eval)
        print(f"[E9-gate+train] seed={s} strict={r['strict']['acc']:.4f}@{r['strict']['latency']:.1f} "
              f"guardΔ2={r['guard'][2]['acc']:.4f} guardΔ4={r['guard'][4]['acc']:.4f} "
              f"full-frame={r['full_frame']['acc']:.4f}", flush=True)


def cmd_E10(args):
    """Per-class output-threshold coordinate search (F5): push the latency knee left of the global-c
    Pareto. Gate-init SNN (NO spiking training); precompute output membrane trajectories once on a
    TRAIN calibration set and the TEST set; coordinate-descend per-class c_k (θ_out[k]=round(c_k/
    scale_out[k])) to maximize acc - λ·latency/T on CALIB, then report on TEST. Calibrating on train
    and reporting on test avoids tuning thresholds to the test set.

    ⚠ This is an OBSERVED calibrated frontier, not the global optimum: greedy coordinate descent over a
    discrete c-grid from a fixed init (c=2) can sit in a local optimum. Single seed, n=n_eval subset —
    a preliminary frontier; the final paper number needs multi-seed + full test + a held-out calib
    split (see PROGRESS F7). Latency is the algorithmic timestep, not an RTL cycle (see convert.py)."""
    import statistics
    import numpy as np
    import spiking as S
    in_bits, act_hi = 4, 2.0
    tr_imgs, tr_labels = D.load_dataset(args.dataset, train=True)
    te_imgs, te_labels = D.load_dataset(args.dataset, train=False)
    n = args.n_eval
    c_grid = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0, 6.0]
    lams = [0.0, 0.5, 1.0]
    agg = {lam: {"acc": [], "lat": []} for lam in lams}                # F7: aggregate across seeds
    print(f"[E10] dataset={args.dataset} seeds={args.seeds} n_eval={n} epochs={args.epochs}", flush=True)
    for s in range(args.seeds):
        ann, _ = T.train_model(dataset=args.dataset, arch="main", W=4, epochs=args.epochs,
                               input_bits=in_bits, act_bits=1, bias=False, act_hi=act_hi,
                               seed=s, verbose=args.verbose)
        ann = ann.cpu()
        sc_out = ann.layers[-1].scale.detach().squeeze(-1).numpy()    # [10] per-class output scale
        snn = S.V2CSpikingMLP([784, 246, 10], 4, T=args.T)
        _gate_init_snn(snn, ann, args.T, act_hi, in_bits)
        # calibrate on TRAIN (distinct from the reported TEST; the ANN saw train, so this is a mild
        # optimism — quantified by the calib->test gap below), report on TEST.
        traj_cal, _ = C.ramp_output_trajectories(snn, tr_imgs, args.T, in_bits=in_bits, n_eval=n)
        traj_te, _ = C.ramp_output_trajectories(snn, te_imgs, args.T, in_bits=in_bits, n_eval=n)
        y_cal, y_te = tr_labels[:n], te_labels[:n]

        def theta_of(c_vec):
            return np.maximum(1, np.rint(np.asarray(c_vec) / sc_out)).astype(np.int64)

        def acc_lat(traj, y, c_vec):
            preds, lat = C.strict_decode_from_traj(traj, theta_of(c_vec), args.T)
            return float((preds == y).mean()), float(lat.mean()), float((lat == args.T).mean())

        if s == 0:                                                    # global-c baseline once
            for c in [1.0, 1.5, 2.0, 3.0]:
                a, l, _ = acc_lat(traj_te, y_te, np.full(10, c))
                print(f"[E10-global seed0] c={c:.2f} TEST acc={a:.4f}@t≈{l:.1f}", flush=True)
        for lam in lams:
            c_vec = np.full(10, 2.0)                                  # init at the global-c knee
            for _ in range(3):                                        # greedy coordinate descent (observed frontier)
                for k in range(10):
                    best_c, best_o = c_vec[k], None
                    for cand in c_grid:
                        cv = c_vec.copy(); cv[k] = cand
                        a, l, _ = acc_lat(traj_cal, y_cal, cv)
                        o = a - lam * l / args.T
                        if best_o is None or o > best_o:
                            best_o, best_c = o, cand
                    c_vec[k] = best_c
            ca, cl, _ = acc_lat(traj_cal, y_cal, c_vec)
            ta, tl, fb = acc_lat(traj_te, y_te, c_vec)
            agg[lam]["acc"].append(ta); agg[lam]["lat"].append(tl)
            print(f"[E10 seed={s} λ={lam:.1f}] TEST acc={ta:.4f}@t≈{tl:.1f} fallback={fb:.3f} "
                  f"(calib {ca:.4f}@{cl:.1f}) c_vec={np.round(c_vec, 2).tolist()}", flush=True)
    if args.seeds > 1:                                                # F7 aggregate
        for lam in lams:
            a, l = agg[lam]["acc"], agg[lam]["lat"]
            print(f"[E10-AGG λ={lam:.1f}] acc={statistics.mean(a):.4f}±{statistics.pstdev(a):.4f} "
                  f"lat={statistics.mean(l):.1f}±{statistics.pstdev(l):.1f}  ({len(a)} seeds, n={n})", flush=True)


def cmd_E11(args):
    """Phase 3 — non-ideal robustness (the SOTA-able axis). Gate-init SNN (deployed, no training), then
    sweep digital cell-fault rate for each mode (stuck0 / stuck1 / flip) -> full-frame accuracy-vs-fault
    -rate. Digital binary cells + 1-bit sense are immune-by-construction to the analog variation/ADC
    noise that costs analog CIM 10-50%+; this draws the curve. Analog-CIM baseline comparison TBD."""
    import robustness as R
    import spiking as S
    in_bits, act_hi = 4, 2.0
    te_imgs, te_labels = D.load_dataset(args.dataset, train=False)
    ann, _ = T.train_model(dataset=args.dataset, arch="main", W=4, epochs=args.epochs,
                           input_bits=in_bits, act_bits=1, bias=False, act_hi=act_hi,
                           seed=0, verbose=args.verbose)
    ann = ann.cpu()
    snn = S.V2CSpikingMLP([784, 246, 10], 4, T=args.T)
    _gate_init_snn(snn, ann, args.T, act_hi, in_bits)
    print(f"[E11] dataset={args.dataset} T={args.T} n_eval={args.n_eval}", flush=True)
    rates = (0.0, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2)
    for mode in R.FAULT_MODES:
        sw = R.robustness_sweep(snn, te_imgs, te_labels, args.T, in_bits=in_bits, mode=mode,
                                rates=rates, n_eval=args.n_eval, trials=5, seed=0)
        pts = "  ".join(f"r={r:.3f}:{m:.4f}±{s:.4f}" for r, (m, s) in sw.items())
        print(f"[E11-robust {mode:6s}] {pts}", flush=True)


def main():
    ap = argparse.ArgumentParser(description="V2C experiment campaign (ANN ceiling E0-E6 + SNN E7-E10 + robustness E11)")
    ap.add_argument("exp", choices=["E0", "E2", "E3", "E4", "E5", "E6", "E7", "E8", "E9", "E10", "E11"])
    ap.add_argument("--dataset", default="fashion_mnist", choices=list(D.DATASETS),
                    help="dataset for the gate-init pipeline (E8/E10/E11)")
    ap.add_argument("--seeds", type=int, default=5)
    ap.add_argument("--epochs", type=int, default=50)
    ap.add_argument("--T", type=int, default=16, help="TTFS timesteps (E7 only)")
    ap.add_argument("--n-eval", type=int, default=2000, help="golden eval sample count (E7 only)")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    {"E0": cmd_E0, "E2": cmd_E2, "E3": cmd_E3, "E4": cmd_E4, "E5": cmd_E5, "E6": cmd_E6,
     "E7": cmd_E7, "E8": cmd_E8, "E9": cmd_E9, "E10": cmd_E10, "E11": cmd_E11}[args.exp](args)


if __name__ == "__main__":
    main()
