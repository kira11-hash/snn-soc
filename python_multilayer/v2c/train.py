"""
V2C reference quantized-ANN training (the graded-activation upper bound).

Trains ``model.V2CMLP`` (quantized weights via per-output LSQ, float ReLU activations) with a
strong-but-simple trick stack. This is NOT the deployed V2C path — the V2C accelerator runs the
non-differentiable TTFS-IF spiking forward, and a graded ReLU ANN does not convert to it (the
TTFS-IF dynamic is non-monotonic; naive threshold calibration collapses to chance). The deployed
path is the surrogate-gradient spiking net in ``spiking.py`` / ``train_spiking.py``. This file is
kept as the quantized-ANN accuracy reference (an upper bound on what the integer weights can do
with full-precision activations).

Tricks (PPA-neutral — none change the binary cell or add inference-time cost):
  AdamW (no weight-decay on scale/bias) + cosine LR + label smoothing + light random translation
  + weight EMA + good init (model.QuantLinear uses Kaiming + LSQ-scale init). Optional float-teacher
  KD is wired (``teacher=...``) but off by default.

Run (in the v2c venv):
  ./.venv-v2c/bin/python python_multilayer/v2c/train.py --dataset fashion_mnist --W 4 --epochs 20
"""
from __future__ import annotations

import argparse

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

try:  # package import
    from . import model as M
    from . import data as data_mod
except ImportError:  # direct-module import (v2c on sys.path) — venv / tests
    import model as M
    import data as data_mod


def pick_device(prefer: str = "auto") -> torch.device:
    if prefer != "auto":
        return torch.device(prefer)
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def random_translate(x4: torch.Tensor, max_shift: int = 2) -> torch.Tensor:
    """Per-sample random integer translation of ``[B,1,28,28]`` images (light augmentation)."""
    if max_shift <= 0:
        return x4
    b = x4.shape[0]
    dx = torch.randint(-max_shift, max_shift + 1, (b,), device=x4.device).float() * (2.0 / 28)
    dy = torch.randint(-max_shift, max_shift + 1, (b,), device=x4.device).float() * (2.0 / 28)
    theta = torch.zeros(b, 2, 3, device=x4.device)
    theta[:, 0, 0] = 1.0
    theta[:, 1, 1] = 1.0
    theta[:, 0, 2] = dx
    theta[:, 1, 2] = dy
    grid = F.affine_grid(theta, x4.shape, align_corners=False)
    return F.grid_sample(x4, grid, align_corners=False, padding_mode="zeros")


class EMA:
    """Exponential moving average of model parameters (eval with the smoothed weights)."""

    def __init__(self, model: nn.Module, decay: float = 0.999):
        self.decay = decay
        self.shadow = {k: v.detach().clone() for k, v in model.state_dict().items()}

    @torch.no_grad()
    def update(self, model: nn.Module) -> None:
        for k, v in model.state_dict().items():
            s = self.shadow[k]
            if v.dtype.is_floating_point:
                s.mul_(self.decay).add_(v.detach(), alpha=1.0 - self.decay)
            else:
                s.copy_(v)

    def copy_to(self, model: nn.Module) -> None:
        model.load_state_dict(self.shadow, strict=True)


def _param_groups(model: nn.Module, weight_decay: float):
    """Weight decay on layer weights only — never on the LSQ scale or the bias/threshold."""
    decay, no_decay = [], []
    for name, p in model.named_parameters():
        if not p.requires_grad:
            continue
        (no_decay if (name.endswith("scale") or name.endswith("bias")) else decay).append(p)
    return [
        {"params": decay, "weight_decay": weight_decay},
        {"params": no_decay, "weight_decay": 0.0},
    ]


def _to_xy(images, labels, device):
    x = torch.from_numpy(np.asarray(images)).float().div_(255.0).to(device)   # [N,784] in [0,1]
    y = torch.from_numpy(np.asarray(labels)).long().to(device)
    return x, y


@torch.no_grad()
def evaluate_proxy(model: nn.Module, x: torch.Tensor, y: torch.Tensor, batch: int = 1000) -> float:
    """Quantized-ANN (proxy) accuracy on ``(x,y)`` tensors."""
    model.eval()
    correct = 0
    for i in range(0, x.shape[0], batch):
        logits = model(x[i:i + batch])
        correct += int((logits.argmax(1) == y[i:i + batch]).sum())
    return correct / x.shape[0]


def train_model(dataset="fashion_mnist", arch="main", W=4, epochs=20, batch=128, lr=2e-3,
                weight_decay=5e-4, label_smoothing=0.1, max_shift=2, ema_decay=0.999,
                input_bits=None, act_bits=None,
                teacher=None, kd_alpha=0.5, kd_temp=4.0, device="auto", seed=0, verbose=True):
    """Train the quantized proxy MLP; returns ``(model, history)``. ``model`` carries EMA weights."""
    torch.manual_seed(seed)
    np.random.seed(seed)
    dev = pick_device(device)
    tr_imgs, tr_labels = data_mod.load_dataset(dataset, train=True)
    te_imgs, te_labels = data_mod.load_dataset(dataset, train=False)
    xtr, ytr = _to_xy(tr_imgs, tr_labels, dev)
    xte, yte = _to_xy(te_imgs, te_labels, dev)

    net = M.make_mlp(arch, W, input_bits=input_bits, act_bits=act_bits).to(dev)
    opt = torch.optim.AdamW(_param_groups(net, weight_decay), lr=lr, betas=(0.9, 0.99))
    n_steps = epochs * ((xtr.shape[0] + batch - 1) // batch)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=n_steps)
    ema = EMA(net, decay=ema_decay)
    if teacher is not None:
        teacher = teacher.to(dev).eval()

    history = []
    n = xtr.shape[0]
    for ep in range(epochs):
        net.train()
        perm = torch.randperm(n, device=dev)
        for i in range(0, n, batch):
            idx = perm[i:i + batch]
            xb = xtr[idx].view(-1, 1, 28, 28)
            xb = random_translate(xb, max_shift).view(xb.shape[0], -1)
            yb = ytr[idx]
            logits = net(xb)
            loss = F.cross_entropy(logits, yb, label_smoothing=label_smoothing)
            if teacher is not None:
                with torch.no_grad():
                    t_logits = teacher(xb)
                kd = F.kl_div(F.log_softmax(logits / kd_temp, 1),
                              F.softmax(t_logits / kd_temp, 1),
                              reduction="batchmean") * (kd_temp ** 2)
                loss = (1 - kd_alpha) * loss + kd_alpha * kd
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step()
            sched.step()
            ema.update(net)
        acc = evaluate_proxy(net, xte, yte)
        ep_loss = float(loss.detach())
        history.append({"epoch": ep, "test_acc": acc, "loss": ep_loss})
        if verbose:
            print(f"  ep{ep:02d} loss={ep_loss:.3f} proxy_test_acc={acc:.4f} lr={sched.get_last_lr()[0]:.2e}", flush=True)

    ema.copy_to(net)                                   # eval/export with smoothed weights
    net.eval()
    return net, history


def main():
    ap = argparse.ArgumentParser(description="V2C reference quantized-ANN training (graded proxy)")
    ap.add_argument("--dataset", default="fashion_mnist", choices=list(data_mod.DATASETS))
    ap.add_argument("--arch", default="main", choices=list(M.ARCHS))
    ap.add_argument("--W", type=int, default=4)
    ap.add_argument("--epochs", type=int, default=20)
    ap.add_argument("--batch", type=int, default=128)
    ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--device", default="auto")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    print(f"[train] dataset={args.dataset} arch={args.arch} W={args.W} epochs={args.epochs} "
          f"device={pick_device(args.device)}")
    _, hist = train_model(dataset=args.dataset, arch=args.arch, W=args.W, epochs=args.epochs,
                          batch=args.batch, lr=args.lr, device=args.device, seed=args.seed)
    print("\n=== V2C reference quantized-ANN ===")
    print(f"  arch={args.arch} W={args.W}  quantized-ANN test acc : {hist[-1]['test_acc']:.4f}")
    print("  (this is the graded-activation upper-bound reference; the deployed V2C path is the")
    print("   surrogate-gradient spiking net — see train_spiking.py / spiking.py / convert.py.)")


if __name__ == "__main__":
    main()
