"""Activation-scale calibration grid search (GPT 2026-04-19 plan).

For a given topology + dataset, train a pure-float MultiLayerANN teacher (if
no checkpoint exists), then for each (percentile, target_max_count) config:
  1. Calibrate act_log_scale
  2. Evaluate ``forward()`` (uint8 STE) test accuracy — no retraining
  3. Report gap vs pure-float

Picks the config with smallest STE gap as the "keep depth headroom" setting.
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader, TensorDataset

import config_multilayer as cfg
from _vendored_from_v1.data_utils import (
    load_fashion_mnist_test,
    load_fashion_mnist_train,
    load_mnist_test,
    load_mnist_train,
)
from topologies import get_topology_by_name, load_topology_file
from trainer_multilayer import MultiLayerANN

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("calib_grid")


def _load_data(dataset: str):
    data_dir = str(cfg.ROOT_DIR / "data")
    if dataset == "fashion_mnist":
        tr_x, tr_y = load_fashion_mnist_train(data_dir, target_size=8, method="avgpool")
        te_x, te_y = load_fashion_mnist_test(data_dir, target_size=8, method="avgpool")
    else:
        tr_x, tr_y = load_mnist_train(data_dir, target_size=8, method="avgpool")
        te_x, te_y = load_mnist_test(data_dir, target_size=8, method="avgpool")
    return (tr_x.float() / 255.0, tr_y, te_x.float() / 255.0, te_y)


def _train_pure_float(topology, train_x, train_y, epochs: int, lr: float, seed: int = 42):
    torch.manual_seed(seed)
    model = MultiLayerANN(topology)
    loader = DataLoader(
        TensorDataset(train_x, train_y), batch_size=128, shuffle=True,
        generator=torch.Generator().manual_seed(seed),
    )
    opt = optim.SGD(model.parameters(), lr=lr, momentum=0.9)
    crit = nn.CrossEntropyLoss()
    for ep in range(epochs):
        model.train()
        for xb, yb in loader:
            loss = crit(model.forward_pure_float(xb), yb)
            opt.zero_grad(); loss.backward(); opt.step()
    return model


@torch.no_grad()
def _eval(model: MultiLayerANN, test_x: torch.Tensor, test_y: torch.Tensor, fn: str) -> float:
    model.eval()
    forward_fn = model.forward_pure_float if fn == "pure_float" else model.forward
    correct = 0
    for i in range(0, test_x.shape[0], 128):
        xb = test_x[i:i+128]; yb = test_y[i:i+128]
        pred = forward_fn(xb).argmax(dim=1)
        correct += int((pred == yb).sum())
    return correct / test_x.shape[0]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--topology", required=True)
    ap.add_argument("--dataset", default="mnist", choices=["mnist", "fashion_mnist"])
    ap.add_argument("--float-epochs", type=int, default=25)
    ap.add_argument("--lr", type=float, default=0.01)
    args = ap.parse_args()

    topo = get_topology_by_name(
        load_topology_file(cfg.ROOT_DIR / "topologies.yaml").topologies,
        args.topology,
    )
    tr_x, tr_y, te_x, te_y = _load_data(args.dataset)

    logger.info("[%s/%s] training pure-float teacher for %d epochs",
                args.topology, args.dataset, args.float_epochs)
    model = _train_pure_float(topo, tr_x, tr_y, args.float_epochs, args.lr)
    pf_acc = _eval(model, te_x, te_y, "pure_float")
    logger.info("[%s/%s] pure-float test accuracy: %.4f",
                args.topology, args.dataset, pf_acc)

    # Save as teacher
    save_dir = cfg.get_topology_results_dir(topo.name)
    torch.save(
        {"state_dict": model.state_dict(),
         "topology_name": topo.name,
         "test_accuracy": pf_acc,
         "dataset": args.dataset},
        save_dir / f"teacher_{args.dataset}.pt",
    )

    # Grid: percentile × target_max_count
    grid = [
        (0.99, 80),  # current baseline
        (0.99, 40),
        (0.99, 20),
        (0.97, 80),
        (0.97, 40),
        (0.95, 80),
        (0.95, 40),
        (0.90, 80),
        (0.90, 40),
    ]
    logger.info("[%s/%s] grid calibration + STE eval (pure float = %.4f)",
                args.topology, args.dataset, pf_acc)
    results = []
    for pct, tgt in grid:
        # Recalibrate act_log_scale from the pure-float checkpoint
        model_copy = MultiLayerANN(topo)
        model_copy.load_state_dict(model.state_dict(), strict=False)
        model_copy.calibrate_activation_scales(
            tr_x[:2048], target_max_count=tgt, percentile=pct
        )
        scales = model_copy.act_log_scale.detach().exp().tolist()
        ste_acc = _eval(model_copy, te_x, te_y, "uint8_ste")
        gap = pf_acc - ste_acc
        logger.info(
            "  pct=%.2f target=%2d  scales=%s  STE=%.4f  gap=%.4f",
            pct, tgt, [f"{s:.4f}" for s in scales], ste_acc, gap,
        )
        results.append((pct, tgt, ste_acc, gap, scales))

    results.sort(key=lambda r: -r[2])
    logger.info("[%s/%s] BEST: pct=%.2f target=%d STE=%.4f (gap %.4f from pure float %.4f)",
                args.topology, args.dataset,
                results[0][0], results[0][1], results[0][2], results[0][3], pf_acc)
    return 0


if __name__ == "__main__":
    sys.exit(main())
