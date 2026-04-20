"""Fashion-MNIST: joint timestep + threshold sweep on QAT checkpoint.

GPT 2026-04-19 final shot: Fashion 64_32_10 stage 0 under-fires (mean=3.85 at
th=2550 with T=10). Test hypothesis: longer timesteps + lower threshold frees
up count range, recovers some of the 44 pp gap between forward_qat (80%) and
bit-plane RTL (36%).

No retraining — pure inference sweep using trained QAT weights.
"""

from __future__ import annotations

import argparse
import itertools
import logging
import sys

import numpy as np

import config_multilayer as cfg
from _vendored_from_v1.data_utils import load_fashion_mnist_test
from exporter_multilayer import weights_in_memory_int_form
from snn_engine_multilayer import snn_inference_multilayer_sample, _run_stage_bitplane
from topologies import get_topology_by_name, load_topology_file
from trainer_multilayer import load_model

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("fsweep")


def _eval(images, labels, topo, weights):
    correct = 0
    for i in range(images.shape[0]):
        pred, _, _ = snn_inference_multilayer_sample(
            images[i].astype(np.int64), topo, weights
        )
        if pred == int(labels[i]):
            correct += 1
    return correct / images.shape[0]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--topology", default="64_32_10")
    ap.add_argument("--samples", type=int, default=2000)
    ap.add_argument("--full-eval", action="store_true")
    args = ap.parse_args()

    topo = get_topology_by_name(
        load_topology_file(cfg.ROOT_DIR / "topologies.yaml").topologies,
        args.topology,
    )
    model = load_model(cfg.get_topology_results_dir(topo.name) / "model.pt", topo)
    weights = weights_in_memory_int_form(topo, model.state_dict())
    tx, ty = load_fashion_mnist_test(
        str(cfg.ROOT_DIR / "data"), target_size=8, method="avgpool"
    )
    img = tx[:args.samples].numpy()
    lab = ty[:args.samples].numpy()

    # Diagnostic: stage 0 count distribution at (T0=10, 20) × (theta0 in [800, 1600, 2550])
    print("\n=== Stage 0 count distribution per T0 × theta0 ===")
    wp, wn = weights[0]
    for T0 in [10, 20]:
        for th0 in [800, 1600, 2550]:
            s0 = topo.stages[0].model_copy(update={"threshold": th0, "timesteps": T0})
            counts = np.stack([
                _run_stage_bitplane(s0, img[i].astype(np.int64), wp, wn)[0]
                for i in range(50)
            ])
            print(
                f"  T0={T0:2d} theta0={th0:4d}: mean={counts.mean():5.2f} "
                f"p50={int(np.percentile(counts,50)):3d} p90={int(np.percentile(counts,90)):3d} "
                f"max={counts.max():3d} zero_rate={(counts==0).mean()*100:.1f}% "
                f"near_max_rate={(counts >= 8*T0*0.8).mean()*100:.1f}%"
            )

    # Coarse grid: T0 × theta0 × theta1
    print("\n=== Coarse sweep ===")
    t0_cands = [10, 20]
    th0_cands = [400, 800, 1200, 1600, 2000, 2550, 4000]
    th1_cands = [1, 2, 4, 8, 16, 32, 64, 128, 256]

    best = (0.0, (10, 1, 2550, 1))
    for T0, th0, th1 in itertools.product(t0_cands, th0_cands, th1_cands):
        stages = [
            topo.stages[0].model_copy(update={"threshold": th0, "timesteps": T0}),
            topo.stages[1].model_copy(update={"threshold": th1}),
        ]
        t = topo.model_copy(update={"stages": stages})
        acc = _eval(img, lab, t, weights)
        if acc > best[0]:
            best = (acc, (T0, 1, th0, th1))
            logger.info("  new best: T0=%d T1=%d theta0=%d theta1=%d acc=%.4f",
                        T0, 1, th0, th1, acc)
    logger.info("BEST coarse: T0=%d T1=%d theta=[%d, %d] acc=%.4f",
                *best[1], best[0])

    if args.full_eval:
        T0, T1, th0, th1 = best[1]
        stages = [
            topo.stages[0].model_copy(update={"threshold": th0, "timesteps": T0}),
            topo.stages[1].model_copy(update={"threshold": th1}),
        ]
        t = topo.model_copy(update={"stages": stages})
        full_img = tx.numpy(); full_lab = ty.numpy()
        acc_full = _eval(full_img, full_lab, t, weights)
        logger.info("FULL 10K acc = %.4f (at T0=%d theta=[%d, %d])",
                    acc_full, T0, th0, th1)

    return 0


if __name__ == "__main__":
    sys.exit(main())
