"""Post-hoc threshold sweep (Route C) per GPT 2026-04-19 recommendation.

Loads a trained model, keeps weights frozen, sweeps per-stage thresholds on
a validation subset, and writes the best-combination back as integer values
to the model's raw_threshold (for export / numpy golden eval) and optionally
to topologies.yaml.

Usage:
    python run_threshold_sweep.py --topology 64_32_10 [--write-yaml]

Sweep ranges (from GPT):
    stage0 ∈ {40, 50, 60, 70, 80, 100, 120}
    stageN ∈ {1, 2, 3, 4, 6, 8}

For 3-stage topologies, coordinate descent to avoid 6^3 blowup.
"""

from __future__ import annotations

import argparse
import itertools
import logging
import sys
from pathlib import Path

import numpy as np
import torch
import yaml

import config_multilayer as cfg
from _vendored_from_v1.data_utils import load_mnist_test
from exporter_multilayer import weights_in_memory_int_form
from snn_engine_multilayer import snn_inference_multilayer_sample
from topologies import TopologyConfig, get_topology_by_name, load_topology_file
from trainer_multilayer import load_model

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("sweep")


STAGE0_CANDIDATES = [40, 50, 60, 70, 80, 100, 120, 150]
STAGEN_CANDIDATES = [1, 2, 3, 4, 6, 8, 12]


def _eval_acc(images_u8, labels, topology, weights, thresholds) -> float:
    new_stages = [
        s.model_copy(update={"threshold": int(t)})
        for s, t in zip(topology.stages, thresholds)
    ]
    topo_alt = topology.model_copy(update={"stages": new_stages})
    correct = 0
    for i in range(images_u8.shape[0]):
        pred, _, _ = snn_inference_multilayer_sample(
            images_u8[i].astype(np.int64), topo_alt, weights
        )
        if pred == int(labels[i]):
            correct += 1
    return correct / max(1, images_u8.shape[0])


def sweep_two_stage(topo: TopologyConfig, images_u8, labels, weights) -> tuple[list[int], float]:
    best_acc = 0.0
    best_th = list(topo.stages[s].threshold for s in range(len(topo.stages)))
    for th0, th1 in itertools.product(STAGE0_CANDIDATES, STAGEN_CANDIDATES):
        acc = _eval_acc(images_u8, labels, topo, weights, [th0, th1])
        if acc > best_acc:
            best_acc = acc
            best_th = [th0, th1]
            logger.info("  new best th=[%d, %d] acc=%.4f", th0, th1, acc)
    return best_th, best_acc


def sweep_three_stage(topo: TopologyConfig, images_u8, labels, weights) -> tuple[list[int], float]:
    # Coordinate descent: init from current, round-robin refine each axis
    current = [int(s.threshold) for s in topo.stages]
    best_acc = _eval_acc(images_u8, labels, topo, weights, current)
    for _round in range(2):
        for axis, cands in enumerate([STAGE0_CANDIDATES, STAGEN_CANDIDATES, STAGEN_CANDIDATES]):
            for th in cands:
                trial = list(current)
                trial[axis] = th
                acc = _eval_acc(images_u8, labels, topo, weights, trial)
                if acc > best_acc:
                    best_acc = acc
                    current = trial
                    logger.info("  round %d axis %d th=%s acc=%.4f", _round, axis, current, best_acc)
    return current, best_acc


def update_yaml(name: str, new_th: list[int]) -> None:
    p = cfg.ROOT_DIR / "topologies.yaml"
    data = yaml.safe_load(p.read_text(encoding="utf-8"))
    for t in data["topologies"]:
        if t["name"] == name:
            for stage, th in zip(t["stages"], new_th):
                stage["threshold"] = int(th)
            break
    p.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False,
                                default_flow_style=False), encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--topology", required=True)
    ap.add_argument("--samples", type=int, default=2000,
                    help="validation subset size for sweep (default 2000)")
    ap.add_argument("--full-eval", action="store_true",
                    help="also evaluate final thresholds on full 10k test set")
    ap.add_argument("--write-yaml", action="store_true")
    args = ap.parse_args()

    topo_file = load_topology_file(cfg.ROOT_DIR / "topologies.yaml")
    topo = get_topology_by_name(topo_file.topologies, args.topology)
    model = load_model(cfg.get_topology_results_dir(topo.name) / "model.pt", topo)
    weights = weights_in_memory_int_form(topo, model.state_dict())
    tx, ty = load_mnist_test(str(cfg.ROOT_DIR / "data"), target_size=8, method="avgpool")

    val_u8 = tx[: args.samples].numpy()
    val_y = ty[: args.samples].numpy()

    logger.info("[%s] pre-sweep thresholds: %s", topo.name, model.snapshot_thresholds())
    pre_acc = _eval_acc(val_u8, val_y, topo, weights,
                        [int(s.threshold) for s in topo.stages])
    logger.info("[%s] pre-sweep accuracy (%d samples, YAML thresholds): %.4f",
                topo.name, args.samples, pre_acc)

    if topo.num_fc_stages == 2:
        best_th, best_acc = sweep_two_stage(topo, val_u8, val_y, weights)
    elif topo.num_fc_stages == 3:
        best_th, best_acc = sweep_three_stage(topo, val_u8, val_y, weights)
    else:
        logger.error("Unsupported stage count %d", topo.num_fc_stages)
        return 2

    logger.info("[%s] BEST thresholds: %s  val_acc=%.4f", topo.name, best_th, best_acc)

    if args.full_eval:
        logger.info("[%s] running full 10k eval with best thresholds...", topo.name)
        full_u8 = tx.numpy()
        full_y = ty.numpy()
        full_acc = _eval_acc(full_u8, full_y, topo, weights, best_th)
        logger.info("[%s] FULL 10K accuracy: %.4f", topo.name, full_acc)

    if args.write_yaml:
        update_yaml(topo.name, best_th)
        logger.info("[%s] wrote thresholds to topologies.yaml: %s", topo.name, best_th)

    return 0


if __name__ == "__main__":
    sys.exit(main())
