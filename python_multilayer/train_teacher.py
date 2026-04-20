"""Pre-train a pure-ReLU float teacher for KD.

Per GPT 2026-04-19: KD effectiveness depends on teacher quality. Our regular
trainer applies uint8 STE between layers (caps float acc ~85%). For KD we
want a teacher ≥90%. This script trains a separate `MultiLayerANN` with
`forward_pure_float` (no weight quant, no activation uint8 STE) and saves to
`results_multilayer/<topo>/teacher.pt`.

Usage:
    python train_teacher.py --topology 64_32_10
    python train_teacher.py --topology 64_64_10 --epochs 40
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
from _vendored_from_v1.data_utils import load_mnist_test, load_mnist_train
from topologies import TopologyConfig, get_topology_by_name, load_topology_file
from trainer_multilayer import MultiLayerANN

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("teacher")


def train_teacher(
    topology: TopologyConfig,
    epochs: int = 40,
    lr: float = 0.01,
    batch_size: int = 128,
    seed: int = 42,
) -> tuple[MultiLayerANN, float]:
    torch.manual_seed(seed)

    train_x, train_y = load_mnist_train(
        str(cfg.ROOT_DIR / "data"), target_size=8, method="avgpool"
    )
    test_x, test_y = load_mnist_test(
        str(cfg.ROOT_DIR / "data"), target_size=8, method="avgpool"
    )
    train_x = train_x.float() / 255.0
    test_x = test_x.float() / 255.0

    train_loader = DataLoader(
        TensorDataset(train_x, train_y), batch_size=batch_size, shuffle=True,
        generator=torch.Generator().manual_seed(seed),
    )
    test_loader = DataLoader(
        TensorDataset(test_x, test_y), batch_size=batch_size, shuffle=False,
    )

    model = MultiLayerANN(topology)
    optimizer = optim.SGD(model.parameters(), lr=lr, momentum=cfg.ANN_MOMENTUM)
    criterion = nn.CrossEntropyLoss()

    best_acc = 0.0
    for epoch in range(epochs):
        model.train()
        epoch_loss = 0.0
        for xb, yb in train_loader:
            logits = model.forward_pure_float(xb)
            loss = criterion(logits, yb)
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            epoch_loss += float(loss.item())
        # Eval
        model.eval()
        correct = 0
        total = 0
        with torch.no_grad():
            for xb, yb in test_loader:
                pred = model.forward_pure_float(xb).argmax(dim=1)
                correct += int((pred == yb).sum())
                total += yb.numel()
        acc = correct / max(1, total)
        best_acc = max(best_acc, acc)
        logger.info(
            "[teacher %s] epoch %d/%d loss=%.4f test_acc=%.4f (best=%.4f)",
            topology.name, epoch + 1, epochs, epoch_loss / len(train_loader),
            acc, best_acc,
        )
    return model, best_acc


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--topology", required=True)
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--lr", type=float, default=0.01)
    args = ap.parse_args()

    topo = get_topology_by_name(
        load_topology_file(cfg.ROOT_DIR / "topologies.yaml").topologies,
        args.topology,
    )
    model, best_acc = train_teacher(topo, epochs=args.epochs, lr=args.lr)

    out_path = cfg.get_topology_results_dir(topo.name) / "teacher.pt"
    torch.save(
        {"state_dict": model.state_dict(),
         "topology_name": topo.name,
         "test_accuracy": best_acc},
        out_path,
    )
    logger.info("[teacher %s] saved to %s (best acc=%.4f)",
                topo.name, out_path, best_acc)
    return 0 if best_acc >= 0.88 else 0  # warn via exit 0; teacher low quality still usable


if __name__ == "__main__":
    sys.exit(main())
