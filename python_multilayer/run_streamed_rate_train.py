"""V2.B REV 2 streamed-rate training entry point.

Trains `input_encoding=streamed_rate` topologies on Fashion-MNIST (or MNIST)
with:
  - Firing-rate band regularizer (GPT fix #10: light reg, no heavy penalty)
  - Periodic threshold EMA calibration (every 5 epochs)
  - Per-layer sum_max (active_wl or array)
  - CE loss on final spike_counts (logits)

Usage:
    python run_streamed_rate_train.py --topology 196_64_10 --epochs 30
    python run_streamed_rate_train.py --topology 196_10 --epochs 30
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

import numpy as np
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
from topologies import TopologyConfig, get_topology_by_name, load_topology_file
from trainer_multilayer import MultiLayerANN

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("streamed_train")


def _load_data(topology: TopologyConfig):
    data_dir = str(cfg.ROOT_DIR / "data")
    # Pick input size from topology input_dim.
    if topology.input_dim == 64:
        target_size = 8
    elif topology.input_dim == 196:
        target_size = 14
    else:
        raise ValueError(f"Unsupported input_dim {topology.input_dim}")

    if topology.dataset == "fashion_mnist":
        tx, ty = load_fashion_mnist_train(data_dir, target_size=target_size, method="avgpool")
        tx_t, ty_t = load_fashion_mnist_test(data_dir, target_size=target_size, method="avgpool")
    else:
        tx, ty = load_mnist_train(data_dir, target_size=target_size, method="avgpool")
        tx_t, ty_t = load_mnist_test(data_dir, target_size=target_size, method="avgpool")

    # Keep as uint8-valued float [0, 255] for streamed rate encoder.
    return tx.float(), ty, tx_t.float(), ty_t


@torch.no_grad()
def _compute_firing_rates(
    model: MultiLayerANN,
    x: torch.Tensor,
    topology: TopologyConfig,
    batch_size: int = 128,
) -> list[float]:
    """Per-stage mean firing rate (= counts / stream_timesteps).

    Returns list of length num_fc_stages; element i is the mean firing rate
    of stage i. Runs forward in chunks to limit memory.
    """
    model.eval()
    T = topology.stream_timesteps
    stage_counts = [torch.zeros(stage.out_dim) for stage in topology.stages]
    n_total = 0
    for start in range(0, x.shape[0], batch_size):
        xb = x[start:start + batch_size]
        # Run forward layer-by-layer to capture intermediate counts.
        from trainer_multilayer import (
            _rtl_like_stage_forward_streamed,
            _exporter_level_table,
            encode_pixel_to_stream_ste,
        )
        level_values = _exporter_level_table(None, 16)  # None = linear 16 levels
        stream = encode_pixel_to_stream_ste(xb, T)
        for i, (layer, stage) in enumerate(zip(model.layers, topology.stages)):
            sum_max = float(stage.sum_max) if stage.sum_max else float(stage.in_dim * 15)
            threshold = torch.tensor(float(stage.threshold)).clamp(min=1.0)
            stream, counts = _rtl_like_stage_forward_streamed(
                stream, layer.weight, threshold,
                sum_max=sum_max, adc_bits=topology.adc_bits, level_values=level_values,
            )
            stage_counts[i] += counts.sum(dim=0).detach()
        n_total += xb.shape[0]
    rates = [float((c / (n_total * T)).mean()) for c in stage_counts]
    return rates


def _calibrate_thresholds(
    model: MultiLayerANN,
    x: torch.Tensor,
    topology: TopologyConfig,
    target_band: tuple[float, float] = (0.05, 0.25),
    damping: float = 0.3,
) -> None:
    """EMA-damped threshold calibration to keep per-stage firing rate in band.

    For each stage:
      rate < target_band[0] → threshold *= (1 - 0.2 * damping) (lower)
      rate > target_band[1] → threshold *= (1 + 0.2 * damping) (higher)
      else: no change
    """
    rates = _compute_firing_rates(model, x[:1024], topology)
    new_thresholds = []
    for i, (rate, stage) in enumerate(zip(rates, topology.stages)):
        theta = stage.threshold
        if rate < target_band[0]:
            theta_new = max(int(theta * (1 - 0.2 * damping)), 1)
        elif rate > target_band[1]:
            theta_new = int(theta * (1 + 0.2 * damping))
        else:
            theta_new = theta
        new_thresholds.append(theta_new)
        logger.info(
            "  stage %d: rate=%.3f theta=%d → %d",
            i, rate, theta, theta_new,
        )
    # Mutate stages in-place (topology is pydantic, use model_copy)
    for stage, new_th in zip(topology.stages, new_thresholds):
        stage.__dict__["threshold"] = new_th  # bypass pydantic immutability


def _firing_rate_band_penalty(
    stage_counts_list: list[torch.Tensor],
    T: int,
    band: tuple[float, float] = (0.02, 0.25),
) -> torch.Tensor:
    """Light band penalty: only penalize rates outside [r_min, r_max].

    For each stage's count tensor [N, out_dim], compute per-neuron mean rate
    over the batch, then penalize (rate - band)^2 when rate is outside band.
    """
    total = torch.tensor(0.0, device=stage_counts_list[0].device)
    for counts in stage_counts_list:
        rate = counts.mean(dim=0) / T  # [out_dim]
        lo, hi = band
        under = torch.relu(lo - rate).pow(2).mean()
        over = torch.relu(rate - hi).pow(2).mean()
        total = total + under + over
    return total


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--topology", required=True)
    ap.add_argument("--epochs", type=int, default=30)
    ap.add_argument("--batch-size", type=int, default=128)
    ap.add_argument("--lr", type=float, default=0.01)
    ap.add_argument("--momentum", type=float, default=0.9)
    ap.add_argument("--rate-band-weight", type=float, default=0.05)
    ap.add_argument("--calib-interval", type=int, default=5, help="Epochs between threshold calibrations")
    ap.add_argument("--init-std", type=float, default=0.1)
    ap.add_argument("--subset", type=int, default=0, help="If >0, use this many training samples only")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--stream-timesteps", type=int, default=None,
                    help="Override topology.stream_timesteps (for T ablation)")
    ap.add_argument("--adc-bits", type=int, default=None,
                    help="Override topology.adc_bits")
    ap.add_argument("--dataset-override", default=None, choices=["mnist", "fashion_mnist"],
                    help="Override topology.dataset (for cross-dataset ablation)")
    ap.add_argument("--tag", default="",
                    help="Tag appended to output dir (e.g., _T128 or _mnist)")
    args = ap.parse_args()

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)

    topo = get_topology_by_name(
        load_topology_file(cfg.ROOT_DIR / "topologies.yaml").topologies,
        args.topology,
    )
    if topo.input_encoding != "streamed_rate":
        logger.error("Topology %s has input_encoding=%s; this script requires streamed_rate",
                     topo.name, topo.input_encoding)
        return 2

    # Apply CLI overrides (for ablation sweeps without editing YAML)
    if args.stream_timesteps is not None:
        topo.__dict__["stream_timesteps"] = args.stream_timesteps
        logger.info("[%s] stream_timesteps overridden to %d", topo.name, args.stream_timesteps)
    if args.adc_bits is not None:
        topo.__dict__["adc_bits"] = args.adc_bits
        logger.info("[%s] adc_bits overridden to %d", topo.name, args.adc_bits)
    if args.dataset_override is not None:
        topo.__dict__["dataset"] = args.dataset_override
        logger.info("[%s] dataset overridden to %s", topo.name, args.dataset_override)

    logger.info("[%s] dataset=%s input=%d T=%d adc=%d-bit full_scale=%s",
                topo.name, topo.dataset, topo.input_dim, topo.stream_timesteps,
                topo.adc_bits, topo.adc_full_scale)

    tx, ty, tx_t, ty_t = _load_data(topo)
    if args.subset > 0:
        tx, ty = tx[:args.subset], ty[:args.subset]
    logger.info("[%s] train %d / test %d", topo.name, tx.shape[0], tx_t.shape[0])

    # Build model
    model = MultiLayerANN(topo)
    for layer in model.layers:
        nn.init.normal_(layer.weight, std=args.init_std)

    # Initial threshold calibration (warmup-free first shot)
    logger.info("[%s] initial threshold calibration:", topo.name)
    _calibrate_thresholds(model, tx, topo)

    opt = optim.SGD(model.parameters(), lr=args.lr, momentum=args.momentum)
    ce = nn.CrossEntropyLoss()
    train_ds = TensorDataset(tx, ty)
    loader = DataLoader(train_ds, batch_size=args.batch_size, shuffle=True,
                        generator=torch.Generator().manual_seed(args.seed))

    T = topo.stream_timesteps
    best_acc = 0.0
    for ep in range(args.epochs):
        model.train()
        tot_loss, tot_ce, tot_reg, n = 0.0, 0.0, 0.0, 0
        for xb, yb in loader:
            logits_raw = model.forward_streamed_rate(
                xb, stream_timesteps=T, adc_bits=topo.adc_bits,
                adc_full_scale=topo.adc_full_scale,
            )
            # Normalize logits to rate domain [0, 1] before CE. Raw spike counts
            # in [0, T] make softmax too sharp and training collapses (loss
            # descends but argmax stays random). Dividing by T makes gradients
            # well-scaled while preserving argmax.
            logits = logits_raw / T
            loss_ce = ce(logits, yb)
            # Light rate band penalty on final-layer fire rate.
            rate = logits_raw.mean(dim=0) / T  # [num_classes]
            reg = torch.relu(0.02 - rate).pow(2).mean() + torch.relu(rate - 0.25).pow(2).mean()
            loss = loss_ce + args.rate_band_weight * reg

            opt.zero_grad()
            loss.backward()
            opt.step()
            tot_loss += loss.item()
            tot_ce += loss_ce.item()
            tot_reg += reg.item()
            n += 1

        # Eval
        model.eval()
        correct = 0
        with torch.no_grad():
            for start in range(0, tx_t.shape[0], args.batch_size):
                xb = tx_t[start:start + args.batch_size]
                yb = ty_t[start:start + args.batch_size]
                logits = model.forward_streamed_rate(
                    xb, stream_timesteps=T, adc_bits=topo.adc_bits,
                    adc_full_scale=topo.adc_full_scale,
                )
                correct += int((logits.argmax(dim=1) == yb).sum())
        acc = correct / tx_t.shape[0]
        best_acc = max(best_acc, acc)

        logger.info(
            "[%s] ep %d/%d: loss=%.4f ce=%.4f reg=%.4f acc=%.4f (best=%.4f)",
            topo.name, ep + 1, args.epochs,
            tot_loss / n, tot_ce / n, tot_reg / n, acc, best_acc,
        )

        # Periodic threshold calibration
        if (ep + 1) % args.calib_interval == 0 and ep < args.epochs - 1:
            logger.info("[%s] threshold calib at ep %d:", topo.name, ep + 1)
            _calibrate_thresholds(model, tx, topo)

    # Save final model (tag suffix so parallel runs don't clobber)
    base_name = topo.name + (f"_{args.tag}" if args.tag else "")
    out_dir = cfg.get_topology_results_dir(base_name)
    out_path = out_dir / "model.pt"
    torch.save(
        {
            "state_dict": model.state_dict(),
            "topology_name": topo.name,
            "best_test_accuracy": best_acc,
            "final_test_accuracy": acc,
            "final_thresholds": [s.threshold for s in topo.stages],
            "epochs": args.epochs,
            "stream_timesteps": T,
            "adc_bits": topo.adc_bits,
        },
        out_path,
    )
    logger.info("[%s] saved model.pt, best_acc=%.4f, final_thresholds=%s",
                topo.name, best_acc, [s.threshold for s in topo.stages])
    return 0


if __name__ == "__main__":
    sys.exit(main())
