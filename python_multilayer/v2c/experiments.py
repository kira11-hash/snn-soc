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


def cmd_E8(args):
    """Threshold reproduction (Phase-2 SNN diagnostic). Init the SNN from the matched ANN (copy
    weights+scale), then SET the hidden integer threshold to the ANN's 1-bit-gate equivalent
        θ_int = round(T·(act_hi/2)·levels_in / scale),
    derived from: z1_ann = (scale/levels_in)·z1_int (in4 input dequant) and the ANN hidden fires iff
    z1_ann >= act_hi/2, while the ramp SNN hidden fires within-frame iff z1_int >= θ_int/T — equate.
    Setting softplus(log_thr)=T·(act_hi/2)·levels_in makes export round that per-output by /scale.

    Tests AT INIT (no spiking training) whether reproducing the gate reproduces the ANN:
      (1) SNN-hidden-fires vs ANN-hidden-active agreement (is the gate actually reproduced?);
      (2) golden full-frame acc (NB full-frame argmax drops the per-class OUTPUT scale, so it bounds
          what hidden-gate fidelity alone can buy — a low number here points at the output decode)."""
    import torch
    import spiking as S
    in_bits, act_hi = 4, 2.0
    levels_in = (1 << in_bits) - 1
    te_imgs, te_labels = D.load_dataset("fashion_mnist", train=False)
    dev = T.pick_device("auto")
    xte, yte = _test_xy("fashion_mnist", dev)
    ann, _ = T.train_model(dataset="fashion_mnist", arch="main", W=4, epochs=args.epochs,
                           input_bits=in_bits, act_bits=1, bias=False, act_hi=act_hi,
                           seed=0, verbose=args.verbose)
    ann_acc = T.evaluate_proxy(ann, xte, yte)
    ann = ann.cpu()
    snn = S.V2CSpikingMLP([784, 246, 10], 4, T=args.T)
    with torch.no_grad():
        for sl, al in zip(snn.layers, ann.layers):
            sl.weight.copy_(al.weight)
            sl.log_scale.copy_(al.log_scale)
        snn.log_thr[0].fill_(args.T * (act_hi / 2.0) * levels_in)   # hidden: ANN-gate equivalent
        snn.log_thr[1].fill_(1.0)                                    # output: low thr (full-frame ignores it)
    nb = 1000
    x01 = torch.from_numpy(te_imgs[:nb].astype("float32") / 255.0)
    snn_fired = (snn.per_layer_first_times(S.encode_ramp(x01, args.T, in_bits))[0] < args.T).float()
    ann_active = ann.hidden_acts(x01)[0]                             # [nb,246] 0/1
    agree = float((snn_fired == ann_active).float().mean())
    r = C.eval_ttfs_ramp_modes(snn, te_imgs, te_labels, args.T, in_bits=in_bits, deltas=(1, 2, 4),
                               n_eval=args.n_eval)
    print(f"[E8] ANN(EMA)={ann_acc:.4f} | hidden-gate agreement={agree:.4f} | SNN@init "
          f"strict={r['strict']['acc']:.4f} guardΔ2={r['guard'][2]['acc']:.4f} "
          f"full-frame={r['full_frame']['acc']:.4f}  (n_eval={r['n']})", flush=True)


def main():
    ap = argparse.ArgumentParser(description="V2C experiment campaign (ANN ceiling E0-E6 + SNN bridge E7)")
    ap.add_argument("exp", choices=["E0", "E2", "E3", "E4", "E5", "E6", "E7", "E8"])
    ap.add_argument("--seeds", type=int, default=5)
    ap.add_argument("--epochs", type=int, default=50)
    ap.add_argument("--T", type=int, default=16, help="TTFS timesteps (E7 only)")
    ap.add_argument("--n-eval", type=int, default=2000, help="golden eval sample count (E7 only)")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    {"E0": cmd_E0, "E2": cmd_E2, "E3": cmd_E3, "E4": cmd_E4,
     "E5": cmd_E5, "E6": cmd_E6, "E7": cmd_E7, "E8": cmd_E8}[args.exp](args)


if __name__ == "__main__":
    main()
