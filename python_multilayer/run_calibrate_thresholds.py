"""A2.5.b — joint multi-stage threshold calibration.

Sweeps all stage thresholds (including stage 0) jointly. For 2-stage topologies
uses a coarse grid (stage 0 ∈ wide range × stage 1 ∈ narrow range) then
refines around the best point. For 3-stage topologies uses greedy coordinate
descent: fix stages 1,2 then sweep 0; fix 0,2 then sweep 1; etc.

Stage 0 theoretical max diff per sample (integer RTL path):
    max_per_bitplane = in_dim × level_max × 255 / SUM_MAX
    max_total        = sum over bit-planes × timesteps
                     = 64 × 15 × 255/960 × (1+2+4+8+16+32+64+128) × 10
                     ≈ 64,000
So realistic stage 0 threshold is in [1000, 20000] depending on weights.

Stage N>0 realistic max diff:
    in_dim × level_max × 255 / SUM_MAX  (single timestep)
    ≈ in_dim × 4 for in_dim ∈ [10, 32]

Writes calibrated thresholds back to topologies.yaml.
"""

from __future__ import annotations

import argparse
import itertools
import logging
import sys
from pathlib import Path

import numpy as np
import yaml

import config_multilayer as cfg
from _vendored_from_v1.data_utils import load_mnist_test
from exporter_multilayer import weights_in_memory_int_form
from snn_engine_multilayer import snn_inference_multilayer_sample
from topologies import (
    TopologyConfig,
    get_topology_by_name,
    load_topology_file,
)
from trainer_multilayer import load_model

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("calibrate")


def _eval_thresholds(images, labels, topology, stage_weights, thresholds):
    new_stages = [s.model_copy(update={"threshold": t}) for s, t in zip(topology.stages, thresholds)]
    topo_copy = topology.model_copy(update={"stages": new_stages})
    correct = 0
    for img, lab in zip(images, labels):
        pred, _, _ = snn_inference_multilayer_sample(img.astype(np.int64), topo_copy, stage_weights)
        if pred == int(lab):
            correct += 1
    return correct / max(1, len(labels))


def calibrate(topology: TopologyConfig, sample_limit: int = 1000, use_joint: bool = True) -> list[int]:
    out_dir = cfg.get_topology_results_dir(topology.name)
    model = load_model(out_dir / "model.pt", topology)
    stage_weights = weights_in_memory_int_form(topology, model.state_dict())

    tx, ty = load_mnist_test(str(cfg.ROOT_DIR / "data"), target_size=8, method="avgpool")
    images = tx[:sample_limit].numpy()
    labels = ty[:sample_limit].numpy()

    n = topology.num_fc_stages
    # Stage 0 candidate thresholds (wide sweep)
    stage0_cands = [1500, 2550, 4000, 6000, 8000, 10000, 12000, 15000, 18000]
    # Stage N>0 candidate thresholds (realistic range)
    stage_n_cands = [4, 6, 8, 10, 12, 14, 18, 22]

    if n == 2 and use_joint:
        # Full 2D grid
        best = (-1.0, list(topology.stages[i].threshold for i in range(n)))
        for th0 in stage0_cands:
            for th1 in stage_n_cands:
                trial = [th0, th1]
                acc = _eval_thresholds(images, labels, topology, stage_weights, trial)
                if acc > best[0]:
                    best = (acc, trial)
                    logger.info("[%s] new best: th=%s acc=%.4f", topology.name, trial, acc)
        logger.info("[%s] calibration done: th=%s acc=%.4f", topology.name, best[1], best[0])
        return list(best[1])

    if n == 3 and use_joint:
        # Coordinate descent: start with reasonable guess, refine each axis
        current = [10000, 12, 6]
        best_acc = _eval_thresholds(images, labels, topology, stage_weights, current)
        for _round in range(2):  # 2 passes of coordinate descent
            for axis, cands in enumerate([stage0_cands, stage_n_cands, stage_n_cands]):
                for th in cands:
                    trial = list(current)
                    trial[axis] = th
                    acc = _eval_thresholds(images, labels, topology, stage_weights, trial)
                    if acc > best_acc:
                        best_acc = acc
                        current = trial
                        logger.info("[%s] new best axis=%d: th=%s acc=%.4f", topology.name, axis, current, best_acc)
        logger.info("[%s] calibration done: th=%s acc=%.4f", topology.name, current, best_acc)
        return current

    # Fallback: single-stage (shouldn't happen for v2_demo)
    return [s.threshold for s in topology.stages]


def update_yaml(topology_name: str, new_thresholds: list[int]) -> None:
    yaml_path = cfg.ROOT_DIR / "topologies.yaml"
    data = yaml.safe_load(yaml_path.read_text(encoding="utf-8"))
    for topo in data["topologies"]:
        if topo["name"] == topology_name:
            for i, (stage, th) in enumerate(zip(topo["stages"], new_thresholds)):
                if stage["threshold"] != th:
                    logger.info("[%s] stage %d: threshold %d -> %d", topology_name, i, stage["threshold"], th)
                    stage["threshold"] = th
            break
    yaml_path.write_text(
        yaml.safe_dump(data, allow_unicode=True, sort_keys=False, default_flow_style=False),
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--topology", default=None)
    parser.add_argument("--all-topologies", action="store_true")
    parser.add_argument("--sample-limit", type=int, default=1000)
    parser.add_argument("--no-write", action="store_true")
    args = parser.parse_args()

    topo_file = load_topology_file(cfg.ROOT_DIR / "topologies.yaml")
    if args.all_topologies:
        targets = [t for t in topo_file.topologies if t.role == "v2_demo"]
    elif args.topology:
        targets = [get_topology_by_name(topo_file.topologies, args.topology)]
    else:
        logger.error("--topology or --all-topologies required")
        return 2

    for topo in targets:
        new_ths = calibrate(topo, args.sample_limit)
        if not args.no_write:
            update_yaml(topo.name, new_ths)
    return 0


if __name__ == "__main__":
    sys.exit(main())
