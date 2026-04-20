"""Main entry point for V2 multilayer training / reference / export.

Subcommands (``--train``, ``--rtl-like-ref``, ``--export``, ``--all``) are
mutually exclusive with respect to a single topology. ``--all`` runs the
full pipeline: train -> RTL-like reference -> export.

Usage:
    python run_multilayer.py --train --topology 64_32_10
    python run_multilayer.py --rtl-like-ref --topology 64_32_10
    python run_multilayer.py --export --topology 64_32_10
    python run_multilayer.py --all --topology 64_32_10

    python run_multilayer.py --all-topologies   # run --all for every v2_demo
"""

from __future__ import annotations

import argparse
import json
import logging
import shutil
import sys
from pathlib import Path

import numpy as np
import torch

import config_multilayer as cfg
from _vendored_from_v1.data_utils import (
    load_fashion_mnist_test,
    load_fashion_mnist_train,
    load_mnist_test,
    load_mnist_train,
)


def _dataset_loaders(dataset: str):
    if dataset == "fashion_mnist":
        return load_fashion_mnist_train, load_fashion_mnist_test
    return load_mnist_train, load_mnist_test
from exporter_multilayer import (
    export_topology,
    load_hex_weights_for_topology,
    weights_in_memory_int_form,
)
from snn_engine_multilayer import snn_inference_multilayer
from topologies import (
    TopologyConfig,
    get_topology_by_name,
    load_topology_file,
)
from trainer_multilayer import load_model, save_model, train_multilayer

logging.basicConfig(
    level=logging.INFO,
    format="%(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("run_multilayer")


def _seed_mnist_cache_from_v1(data_dir: Path) -> None:
    """Copy V1's frozen MNIST raw cache into V2's local data dir if available."""
    local_raw = data_dir / "MNIST" / "raw"
    required = [
        "train-images-idx3-ubyte",
        "train-labels-idx1-ubyte",
        "t10k-images-idx3-ubyte",
        "t10k-labels-idx1-ubyte",
    ]
    if all((local_raw / name).exists() for name in required):
        return

    v1_raw = cfg.V1_PYTHON_DIR / "data" / "MNIST" / "raw"
    if not all((v1_raw / name).exists() for name in required):
        return

    local_raw.mkdir(parents=True, exist_ok=True)
    for src in v1_raw.iterdir():
        if src.is_file():
            dst = local_raw / src.name
            if not dst.exists():
                shutil.copy2(src, dst)
    logger.info("Seeded local MNIST cache from V1 data: %s", local_raw)


def _data_dir() -> Path:
    path = cfg.ROOT_DIR / "data"
    path.mkdir(parents=True, exist_ok=True)
    _seed_mnist_cache_from_v1(path)
    return path


def _ensure_v2_demo(topology: TopologyConfig) -> None:
    if topology.role != "v2_demo":
        raise SystemExit(
            f"Topology {topology.name!r} has role={topology.role!r}; "
            "this command only supports role=v2_demo. "
            "For baseline, use run_baseline_64to10.py instead."
        )


def cmd_train(topology: TopologyConfig, dataset: str = "mnist") -> None:
    _ensure_v2_demo(topology)
    logger.info("── Training %s on %s ──", topology.name, dataset)

    load_train, load_test = _dataset_loaders(dataset)
    train_x, train_y = load_train(str(_data_dir()), target_size=8, method="avgpool")
    test_x, test_y = load_test(str(_data_dir()), target_size=8, method="avgpool")

    model, result = train_multilayer(
        topology=topology,
        train_images_uint8=train_x,
        train_labels=train_y,
        test_images_uint8=test_x,
        test_labels=test_y,
    )
    out_dir = cfg.get_topology_results_dir(topology.name)
    model_path = save_model(model, out_dir)
    logger.info("Saved model to %s", model_path)

    summary = (
        f"Topology: {result.topology_name}\n"
        f"Float test accuracy:     {result.float_test_accuracy:.4f}\n"
        f"Quantized test accuracy: {result.quantized_test_accuracy:.4f}\n"
        f"Epochs: {result.num_epochs}   QAT: {result.qat_enabled}\n"
        f"Final loss: {result.final_loss:.4f}\n"
    )
    (out_dir / "summary.txt").write_text(summary, encoding="utf-8")

    # Report ≥95% gate (v2_demo)
    if result.float_test_accuracy >= 0.95:
        logger.info("[PASS] float accuracy %.4f >= 0.95 (A2 gate)", result.float_test_accuracy)
    else:
        logger.warning(
            "[WARN] float accuracy %.4f < 0.95 (A2 gate not yet met)",
            result.float_test_accuracy,
        )


def cmd_rtl_like_ref(topology: TopologyConfig, sample_limit: int | None = None) -> None:
    """A2.5 — run RTL-like integer reference on the trained model.

    Reads the trained model from the topology's results dir, quantizes the
    weights to level indices via exporter's memory-quantize path, then runs
    ``snn_inference_multilayer`` on MNIST test samples.
    """
    _ensure_v2_demo(topology)
    logger.info("── RTL-like reference %s ──", topology.name)

    out_dir = cfg.get_topology_results_dir(topology.name)
    model_path = out_dir / "model.pt"
    if not model_path.exists():
        raise SystemExit(
            f"Model not found at {model_path}; run --train first for this topology."
        )
    model = load_model(model_path, topology)
    stage_weights = weights_in_memory_int_form(topology, model.state_dict())

    test_x, test_y = load_mnist_test(str(_data_dir()), target_size=8, method="avgpool")
    if sample_limit is not None and sample_limit > 0:
        test_x = test_x[:sample_limit]
        test_y = test_y[:sample_limit]
    logger.info("Running RTL-like reference on %d test samples", test_x.shape[0])

    images_np = test_x.numpy()
    labels_np = test_y.numpy()
    accuracy, _ = snn_inference_multilayer(
        images_uint8=images_np, labels=labels_np,
        topology=topology, stage_weights=stage_weights,
    )
    logger.info("[%s] RTL-like test accuracy = %.4f", topology.name, accuracy)

    # Append to summary
    summary_path = out_dir / "summary.txt"
    existing = summary_path.read_text(encoding="utf-8") if summary_path.exists() else ""
    summary_path.write_text(
        existing + f"RTL-like reference accuracy: {accuracy:.4f} "
        f"({test_x.shape[0]} samples)\n",
        encoding="utf-8",
    )


def cmd_export(topology: TopologyConfig) -> None:
    """A3 — export HEX + manifest + bit-parity check."""
    _ensure_v2_demo(topology)
    logger.info("── Export %s ──", topology.name)

    out_dir = cfg.get_topology_results_dir(topology.name)
    model_path = out_dir / "model.pt"
    if not model_path.exists():
        raise SystemExit(
            f"Model not found at {model_path}; run --train first for this topology."
        )
    model = load_model(model_path, topology)

    manifest = export_topology(topology, model.state_dict(), out_dir)
    logger.info(
        "Exported %d stages, total_nonzero_cells=%d, manifest=%s",
        len(manifest["stages"]),
        manifest["total_nonzero_cells"],
        out_dir / "manifest.json",
    )

    # Bit-parity self-check: reload the HEX we just wrote, compare with memory
    logger.info("Running bit-parity self-check (memory vs hex)…")
    stage_weights_mem = weights_in_memory_int_form(topology, model.state_dict())
    stage_weights_hex = load_hex_weights_for_topology(topology, out_dir)
    for i, ((mp, mn), (hp, hn)) in enumerate(zip(stage_weights_mem, stage_weights_hex)):
        if not np.array_equal(mp, hp):
            raise SystemExit(f"[FAIL] stage {i} w_pos memory != hex")
        if not np.array_equal(mn, hn):
            raise SystemExit(f"[FAIL] stage {i} w_neg memory != hex")
    logger.info("[PASS] all stages bit-identical (memory round-trip == hex)")


def cmd_all(topology: TopologyConfig, sample_limit: int | None = None) -> None:
    cmd_train(topology)
    cmd_rtl_like_ref(topology, sample_limit=sample_limit)
    cmd_export(topology)


def _load_topologies(path: Path) -> list[TopologyConfig]:
    topo_file = load_topology_file(path)
    return topo_file.topologies


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="V2 multilayer runner")
    parser.add_argument(
        "--topologies", default=str(cfg.ROOT_DIR / "topologies.yaml"),
        help="Path to topologies.yaml",
    )
    parser.add_argument(
        "--topology", default=None,
        help="Topology name to operate on (e.g., 64_32_10)",
    )
    parser.add_argument(
        "--all-topologies", action="store_true",
        help="Run the full pipeline for every role=v2_demo topology",
    )
    # ML-001 fix: do not mark the group as ``required=True``, because
    # ``--all-topologies`` is a valid top-level action that does not need a
    # subcommand flag. ``main()`` enforces "exactly one of train / rtl / export /
    # all, unless --all-topologies is passed (which implies --all)".
    group = parser.add_mutually_exclusive_group(required=False)
    group.add_argument("--train", action="store_true")
    group.add_argument("--rtl-like-ref", action="store_true")
    group.add_argument("--export", action="store_true")
    group.add_argument("--all", action="store_true")
    parser.add_argument(
        "--rtl-ref-samples", type=int, default=None,
        help="Limit RTL-like reference evaluation to first N samples (default: full test)",
    )
    parser.add_argument(
        "--dataset", default="mnist", choices=["mnist", "fashion_mnist"],
        help="Which dataset to use (default: mnist)",
    )
    return parser.parse_args()


def main(args: argparse.Namespace) -> int:
    # ML-001 fix: validate the subcommand flag combination.
    # --all-topologies implies --all (full pipeline per topology).
    any_subcmd = any([args.train, args.rtl_like_ref, args.export, args.all])
    if not args.all_topologies and not any_subcmd:
        logger.error(
            "Must specify one of --train / --rtl-like-ref / --export / --all "
            "(or --all-topologies for the full pipeline over every v2_demo)."
        )
        return 2

    topologies = _load_topologies(Path(args.topologies).resolve())

    if args.all_topologies:
        targets = [t for t in topologies if t.role == "v2_demo"]
        if not targets:
            logger.error("No v2_demo topologies found")
            return 2
        logger.info("Running --all for %d topologies", len(targets))
        for topology in targets:
            # ML-003 fix: forward --rtl-ref-samples into the RTL-like step.
            cmd_all(topology, sample_limit=args.rtl_ref_samples)
        return 0

    if not args.topology:
        logger.error("Must specify --topology NAME or --all-topologies")
        return 2

    try:
        topology = get_topology_by_name(topologies, args.topology)
    except KeyError:
        available = ", ".join(t.name for t in topologies)
        logger.error("Topology %r not found. Available: %s", args.topology, available)
        return 2

    if args.train:
        cmd_train(topology, dataset=args.dataset)
    elif args.rtl_like_ref:
        cmd_rtl_like_ref(topology, sample_limit=args.rtl_ref_samples)
    elif args.export:
        cmd_export(topology)
    elif args.all:
        # ML-003 fix: forward sample_limit into cmd_all's rtl-like-ref step.
        cmd_all(topology, sample_limit=args.rtl_ref_samples)

    return 0


if __name__ == "__main__":
    sys.exit(main(_parse_args()))
