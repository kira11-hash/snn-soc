"""
V2C surrogate-gradient spiking training (the DEPLOYED accuracy path).

Trains ``spiking.V2CSpikingMLP`` inside the real TTFS-IF dynamic (surrogate gradients), so weights
(LSQ-QAT), per-output integer thresholds (threshold-QAT), and spike timing co-adapt. After training,
the integer weights + integer thresholds export to the golden ``forward.multilayer_ttfs_forward``
(via ``convert.eval_ttfs``); the golden accuracy should match the training accuracy — that match is
the train/inference consistency the naive ANN->TTFS route could never achieve.

Same PPA-neutral trick stack as the reference ANN (AdamW / cosine / label smoothing / light
translation / EMA), reused from ``train.py``.

Run (in the v2c venv):
  ./.venv-v2c/bin/python python_multilayer/v2c/train_spiking.py --dataset fashion_mnist --W 4 --T 16
"""
from __future__ import annotations

import argparse

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

try:  # package import
    from . import spiking as S
    from . import data as data_mod
    from . import convert as C
    from .train import pick_device, EMA, random_translate, train_model
except ImportError:  # direct-module import (v2c on sys.path) — venv / tests
    import spiking as S
    import data as data_mod
    import convert as C
    from train import pick_device, EMA, random_translate, train_model

ARCHS = {"main": [784, 246, 10], "ablation": [784, 160, 80, 10]}


def _param_groups(model: nn.Module, weight_decay: float):
    """Weight decay on layer weights only — never on the LSQ scale or the (log) thresholds."""
    decay, no_decay = [], []
    for name, p in model.named_parameters():
        if not p.requires_grad:
            continue
        (decay if name.endswith(".weight") else no_decay).append(p)
    return [
        {"params": decay, "weight_decay": weight_decay},
        {"params": no_decay, "weight_decay": 0.0},
    ]


def _encode(x01, T, input_mode="ttfs", in_bits=4):
    """``ttfs`` -> single-spike TTFS stream; ``ramp`` -> multi-bit grayscale ramp (Option A)."""
    if input_mode == "ramp":
        return S.encode_ramp(x01, T, in_bits=in_bits)
    return S.encode_stream(x01, T)


@torch.no_grad()
def evaluate_spiking(model, x01: torch.Tensor, y: torch.Tensor, T: int, batch: int = 1000,
                     input_mode="ttfs", in_bits=4) -> float:
    """Training-time monitor: TTFS hard-classify accuracy of the spiking model on ``(x01,y)``.
    (Authoritative number comes from the golden ``convert.eval_ttfs`` for the TTFS input mode.)"""
    model.eval()
    correct = 0
    for i in range(0, x01.shape[0], batch):
        stream = _encode(x01[i:i + batch], T, input_mode, in_bits)
        _, mem_int, _, ft = model(stream)
        pred = S.hard_classify(ft, mem_int, T)               # integer membrane -> golden-consistent
        correct += int((pred == y[i:i + batch]).sum())
    return correct / x01.shape[0]


def train_spiking(dataset="fashion_mnist", arch="main", W=4, T=16, epochs=30, batch=128, lr=1e-3,
                  weight_decay=5e-4, label_smoothing=0.1, max_shift=2, ema_decay=0.999, beta=5.0,
                  beta_mem=0.3, thr_init=1.0, weight_standardize=False, ettfs_init=False,
                  decode_gamma=None, fire_fraction=None, force_fire=False,
                  input_mode="ttfs", in_bits=4, teacher=None, kd_alpha=0.5, kd_temp=4.0,
                  init_from_ann=False, hidden_kd=0.0, ann_act_hi=2.0,
                  device="auto", seed=0, verbose=True):
    """Train the spiking V2C MLP; returns ``(model, history)`` (model carries EMA weights, on CPU)."""
    torch.manual_seed(seed)
    np.random.seed(seed)
    dev = pick_device(device)
    tr_imgs, tr_labels = data_mod.load_dataset(dataset, train=True)
    te_imgs, te_labels = data_mod.load_dataset(dataset, train=False)
    xtr = torch.from_numpy(tr_imgs.astype(np.float32) / 255.0).to(dev)
    ytr = torch.from_numpy(tr_labels).long().to(dev)
    xte = torch.from_numpy(te_imgs.astype(np.float32) / 255.0).to(dev)
    yte = torch.from_numpy(te_labels).long().to(dev)

    model = S.V2CSpikingMLP(ARCHS[arch], W, T=T, beta=beta, thr_init=thr_init,
                            decode_gamma=decode_gamma, ettfs_init=ettfs_init,
                            weight_standardize=weight_standardize, force_fire=force_fire).to(dev)
    if init_from_ann:
        # matched-teacher init (Codex/Nature-2024 route): a 1-bit-hidden quantized ANN of the SAME
        # arch/W reaches ~the architectural ceiling cheaply (its binary hidden == the ramp TTFS hidden's
        # z1>=θ gate). Copy its weights as the spiking init and distil from it, so the spiking net
        # fine-tunes spike timing from the ANN solution instead of training from scratch.
        ann, ann_hist = train_model(dataset=dataset, arch=arch, W=W, epochs=epochs,
                                    input_bits=in_bits, act_bits=1, bias=False, act_hi=ann_act_hi,
                                    device=device, seed=seed, verbose=False)
        ann = ann.to(dev)
        with torch.no_grad():
            for sl, al in zip(model.layers, ann.layers):
                sl.weight.copy_(al.weight)
                sl.log_scale.copy_(al.log_scale)
        if verbose:
            print(f"  [init-from-ann] matched 1-bit-hidden ANN acc={ann_hist[-1]['test_acc']:.4f} -> spiking init")
        if teacher is None:
            teacher = ann                                                  # also KD from the matched ANN
    if fire_fraction is not None:                                          # data-driven θ init (else fixed thr_init)
        model.init_thresholds_from_data(_encode(xtr[:1024], T, input_mode, in_bits),
                                        fire_fraction=fire_fraction)
    if teacher is not None:
        teacher = teacher.to(dev).eval()
    opt = torch.optim.AdamW(_param_groups(model, weight_decay), lr=lr, betas=(0.9, 0.99))
    n = xtr.shape[0]
    n_steps = epochs * ((n + batch - 1) // batch)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=n_steps)
    ema = EMA(model, decay=ema_decay)

    history = []
    for ep in range(epochs):
        model.train()
        perm = torch.randperm(n, device=dev)
        for i in range(0, n, batch):
            idx = perm[i:i + batch]
            xb = xtr[idx].view(-1, 1, 28, 28)
            xb = random_translate(xb, max_shift).view(idx.shape[0], -1).clamp(0, 1)
            stream = _encode(xb, T, input_mode, in_bits)
            do_hidden = hidden_kd > 0 and teacher is not None and hasattr(teacher, "hidden_acts")
            if do_hidden:
                earliness, _, mem_loss, _, hidden_fired = model(stream, return_hidden=True)
            else:
                earliness, _, mem_loss, _ = model(stream)
            loss = S.ttfs_loss(earliness, mem_loss, ytr[idx], beta_mem=beta_mem,
                               label_smoothing=label_smoothing)
            if teacher is not None:                                         # output KD (teacher logits)
                with torch.no_grad():
                    t_logits = teacher(xb)
                s_logits = (mem_loss - mem_loss.mean(1, keepdim=True).detach()) \
                    / (mem_loss.std(1, keepdim=True).detach() + 1e-5)
                kd = F.kl_div(F.log_softmax(s_logits / kd_temp, 1), F.softmax(t_logits / kd_temp, 1),
                              reduction="batchmean") * (kd_temp ** 2)
                loss = (1 - kd_alpha) * loss + kd_alpha * kd
            if do_hidden:                                                  # hidden-occurrence distillation
                with torch.no_grad():
                    t_hidden = teacher.hidden_acts(xb)                     # 0/1 teacher hidden bit
                # hidden_fired = firing margin (mem_q-thr_eff); normalise then BCE-with-logits so the
                # spiking hidden fires iff the matched ANN's hidden activates.
                hd = sum(F.binary_cross_entropy_with_logits(hf / (hf.detach().std() + 1e-5), th)
                         for hf, th in zip(hidden_fired, t_hidden))
                loss = loss + hidden_kd * hd
            opt.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=5.0)   # SNN BPTT stability
            opt.step()
            sched.step()
            ema.update(model)
        acc = evaluate_spiking(model, xte, yte, T, input_mode=input_mode, in_bits=in_bits)
        ep_loss = float(loss.detach())
        history.append({"epoch": ep, "test_acc": acc, "loss": ep_loss})
        if verbose:
            print(f"  ep{ep:02d} loss={ep_loss:.3f} spk_test_acc={acc:.4f} "
                  f"lr={sched.get_last_lr()[0]:.2e}", flush=True)

    ema.copy_to(model)
    model.eval()
    return model.to("cpu"), history


def main():
    ap = argparse.ArgumentParser(description="V2C surrogate-gradient spiking training + golden TTFS eval")
    ap.add_argument("--dataset", default="fashion_mnist", choices=list(data_mod.DATASETS))
    ap.add_argument("--arch", default="main", choices=list(ARCHS))
    ap.add_argument("--W", type=int, default=4)
    ap.add_argument("--T", type=int, default=16)
    ap.add_argument("--epochs", type=int, default=30)
    ap.add_argument("--batch", type=int, default=128)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--n-ttfs", type=int, default=2000, help="test samples for the golden TTFS eval")
    ap.add_argument("--ws", action="store_true", help="per-output weight standardization")
    ap.add_argument("--ettfs-init", action="store_true", help="ETTFS T-aware weight init")
    ap.add_argument("--decode-gamma", type=float, default=None, help="exp temporal decode γ (default linear)")
    ap.add_argument("--fire-frac", type=float, default=None, help="data-driven threshold init fire fraction")
    ap.add_argument("--beta-mem", type=float, default=0.3, help="membrane-CE weight (0 = temporal-only loss)")
    ap.add_argument("--force-fire", action="store_true", help="train-only: silent neurons fire at T-1")
    ap.add_argument("--input-mode", default="ttfs", choices=["ttfs", "ramp"],
                    help="ttfs = single-spike; ramp = multi-bit grayscale input (Option A)")
    ap.add_argument("--in-bits", type=int, default=4, help="input bit-depth for ramp mode")
    ap.add_argument("--kd", action="store_true", help="distill from a float-activation ANN teacher")
    ap.add_argument("--kd-alpha", type=float, default=0.5, help="KD weight (0..1); lower = gentler")
    ap.add_argument("--init-from-ann", action="store_true",
                    help="init spiking weights from a matched 1-bit-hidden ANN + distil from it")
    ap.add_argument("--hidden-kd", type=float, default=0.0,
                    help="hidden-occurrence distillation weight (match spiking firing to the ANN hidden bit)")
    ap.add_argument("--device", default="auto")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    print(f"[train_spiking] dataset={args.dataset} arch={args.arch} W={args.W} T={args.T} "
          f"epochs={args.epochs} input_mode={args.input_mode} in_bits={args.in_bits} ws={args.ws} "
          f"fire_frac={args.fire_frac} beta_mem={args.beta_mem} kd={args.kd} device={pick_device(args.device)}")
    teacher = None
    if args.kd:
        print("[train_spiking] training float-ANN teacher for KD ...")
        teacher, t_hist = train_model(dataset=args.dataset, arch=args.arch, W=args.W,
                                      epochs=args.epochs, device=args.device, seed=args.seed, verbose=False)
        print(f"[train_spiking] teacher (float-ANN) test acc = {t_hist[-1]['test_acc']:.4f}")
    model, hist = train_spiking(dataset=args.dataset, arch=args.arch, W=args.W, T=args.T,
                                epochs=args.epochs, batch=args.batch, lr=args.lr, beta_mem=args.beta_mem,
                                weight_standardize=args.ws, ettfs_init=args.ettfs_init,
                                decode_gamma=args.decode_gamma, fire_fraction=args.fire_frac,
                                force_fire=args.force_fire, input_mode=args.input_mode, in_bits=args.in_bits,
                                teacher=teacher, kd_alpha=args.kd_alpha, init_from_ann=args.init_from_ann,
                                hidden_kd=args.hidden_kd, device=args.device, seed=args.seed)
    spk_acc = hist[-1]["test_acc"]
    print("\n=== V2C Part 6b spiking result ===")
    print(f"  full-frame acc (no early-exit, ceiling) : {spk_acc:.4f}  ({args.input_mode} input, W={args.W} T={args.T})")
    if args.input_mode == "ttfs":
        # golden forward.py validates a binary spike stream (TTFS); multi-bit ramp golden is TBD.
        te_imgs, te_labels = data_mod.load_dataset(args.dataset, train=False)
        g = C.eval_ttfs(model, te_imgs, te_labels, args.T, n_eval=args.n_ttfs)
        print(f"  golden TTFS acc, EARLY-EXIT/DEPLOYED     : {g['ttfs_acc']:.4f}  (n={g['n']})")
        print(f"  early-exit latency-accuracy cost        : {spk_acc - g['ttfs_acc']:+.4f}  (decides at t~{g['algo_latency_mean']:.1f})")
        print(f"  fallback rate                           : {g['fallback_rate']:.4f}")
        print(f"  algo first-spike latency (mean)         : {g['algo_latency_mean']:.2f} / T={args.T}")
    else:
        # multi-bit ramp input: bit-serial first-layer golden (encoding.mac per bit-plane + shift-add).
        te_imgs, te_labels = data_mod.load_dataset(args.dataset, train=False)
        g = C.eval_ttfs_ramp(model, te_imgs, te_labels, args.T, in_bits=args.in_bits, n_eval=args.n_ttfs)
        print(f"  golden TTFS-ramp acc, EARLY-EXIT/DEPLOYED : {g['ttfs_acc']:.4f}  (n={g['n']})")
        print(f"  early-exit latency-accuracy cost          : {spk_acc - g['ttfs_acc']:+.4f}  (decides at t~{g['algo_latency_mean']:.1f})")
        print(f"  fallback rate                             : {g['fallback_rate']:.4f}")
        print(f"  algo first-spike latency (mean)           : {g['algo_latency_mean']:.2f} / T={args.T}")


if __name__ == "__main__":
    main()
