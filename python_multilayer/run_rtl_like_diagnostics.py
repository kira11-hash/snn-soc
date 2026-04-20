"""Full-test RTL-like evaluation + diagnostics per GPT's checklist.

For each v2_demo topology:
  * numpy-golden RTL-like accuracy on 10k MNIST test set
  * per-stage spike count histogram
  * stage 0 zero-rate / saturation-rate
  * final-stage spike margin (top1 - top2), per-class collapse detection
  * trainer's forward_rtl_like accuracy for cross-check

Run after training to confirm the learned thresholds + weights actually
generalize on the full test set (not just the 1k calibration subset).
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

import numpy as np
import torch

import config_multilayer as cfg
from _vendored_from_v1.data_utils import load_mnist_test
from exporter_multilayer import weights_in_memory_int_form
from snn_engine_multilayer import snn_inference_multilayer_sample
from topologies import TopologyConfig, get_topology_by_name, load_topology_file
from trainer_multilayer import (
    _evaluate_rtl_like,
    _get_device_levels,
    load_model,
)

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("diag")


def evaluate_topology(topo: TopologyConfig, sample_limit: int | None = None) -> dict:
    model = load_model(cfg.get_topology_results_dir(topo.name) / "model.pt", topo)
    learned_th = model.snapshot_thresholds()
    # Apply learned thresholds
    new_stages = [s.model_copy(update={"threshold": int(t)})
                  for s, t in zip(topo.stages, learned_th)]
    topo_eval = topo.model_copy(update={"stages": new_stages})

    weights = weights_in_memory_int_form(topo_eval, model.state_dict())
    tx, ty = load_mnist_test(str(cfg.ROOT_DIR / "data"), target_size=8, method="avgpool")
    if sample_limit:
        tx = tx[:sample_limit]
        ty = ty[:sample_limit]

    logger.info("[%s] learned thresholds = %s, eval on %d samples",
                topo.name, learned_th, tx.shape[0])

    # numpy golden
    correct = 0
    per_stage_counts = [[] for _ in topo_eval.stages]
    per_sample_margins = []
    per_class_acc = np.zeros(10, dtype=np.int64)
    per_class_total = np.zeros(10, dtype=np.int64)

    for i in range(tx.shape[0]):
        pred, stage_counts, _ = snn_inference_multilayer_sample(
            tx[i].numpy().astype(np.int64), topo_eval, weights
        )
        label = int(ty[i])
        per_class_total[label] += 1
        if pred == label:
            correct += 1
            per_class_acc[label] += 1
        # Record diagnostics
        for s_idx, c in enumerate(stage_counts):
            per_stage_counts[s_idx].append(c)
        final = stage_counts[-1]
        sorted_final = np.sort(final)[::-1]
        margin = int(sorted_final[0]) - int(sorted_final[1]) if len(sorted_final) >= 2 else int(sorted_final[0])
        per_sample_margins.append(margin)

    acc = correct / tx.shape[0]
    margins = np.array(per_sample_margins)
    stage_arrays = [np.stack(c) for c in per_stage_counts]

    report = {
        "name": topo.name,
        "thresholds": learned_th,
        "num_samples": tx.shape[0],
        "accuracy": acc,
        "spike_margin_mean": float(margins.mean()),
        "spike_margin_median": float(np.median(margins)),
        "spike_margin_zero_rate": float(np.mean(margins == 0)),
        "per_class_accuracy": [
            float(per_class_acc[c]) / max(1, per_class_total[c]) for c in range(10)
        ],
        "per_class_counts": per_class_total.tolist(),
        "stage_stats": [],
    }
    for s_idx, arr in enumerate(stage_arrays):
        stage = topo_eval.stages[s_idx]
        report["stage_stats"].append({
            "stage": s_idx,
            "out_dim": stage.out_dim,
            "threshold": stage.threshold,
            "count_mean": float(arr.mean()),
            "count_p50": int(np.median(arr)),
            "count_p90": int(np.percentile(arr, 90)),
            "count_max": int(arr.max()),
            "zero_rate": float(np.mean(arr == 0)),
            "saturation_rate": float(np.mean(arr >= 255)),
        })

    # Torch forward_rtl_like cross-check (subset only to keep fast)
    check_n = min(1000, tx.shape[0])
    levels = _get_device_levels(2 ** cfg.QAT_WEIGHT_BITS)
    torch_acc = _evaluate_rtl_like(
        model, tx[:check_n].float(), ty[:check_n], levels, batch_size=128
    )
    report["torch_rtl_acc_1k"] = torch_acc
    report["torch_vs_numpy_gap"] = torch_acc - acc

    return report


def print_report(r: dict) -> None:
    print(f"\n=== Topology: {r['name']} ===")
    print(f"  Learned thresholds:     {r['thresholds']}")
    print(f"  Samples:                {r['num_samples']}")
    print(f"  * Numpy-golden acc:     {r['accuracy']:.4f}")
    print(f"  * Torch RTL-like acc:   {r['torch_rtl_acc_1k']:.4f} (1k subset)")
    print(f"  * Torch vs numpy gap:   {r['torch_vs_numpy_gap']:+.4f} (should ~0)")
    print(f"  Spike margin top1-top2: mean={r['spike_margin_mean']:.2f} "
          f"median={r['spike_margin_median']} zero_rate={r['spike_margin_zero_rate']*100:.1f}%")
    print(f"  Per-class accuracy:")
    for c, a in enumerate(r["per_class_accuracy"]):
        marker = " [LOW]" if a < 0.5 else ""
        print(f"    class {c} ({r['per_class_counts'][c]:5d} samples): {a:.3f}{marker}")
    print(f"  Stage stats:")
    for s in r["stage_stats"]:
        print(f"    stage {s['stage']}: th={s['threshold']:6d} out_dim={s['out_dim']:3d} "
              f"count mean={s['count_mean']:5.2f} p50={s['count_p50']:3d} "
              f"p90={s['count_p90']:3d} max={s['count_max']:3d} "
              f"zero_rate={s['zero_rate']*100:4.1f}% sat_rate={s['saturation_rate']*100:4.1f}%")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--topology", default=None)
    parser.add_argument("--all-topologies", action="store_true")
    parser.add_argument("--sample-limit", type=int, default=None,
                        help="limit eval size (default: full 10k test set)")
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
        try:
            r = evaluate_topology(topo, args.sample_limit)
            print_report(r)
        except FileNotFoundError as e:
            logger.warning("[%s] skipped: %s", topo.name, e)

    return 0


if __name__ == "__main__":
    sys.exit(main())
