"""Paper-oriented staged rerun driver for E0.

This runner keeps the paper workflow separate from ``run_all.py``:

Stage 1:
    Fixed hardware point, Scheme B only, coarse ratio sweep to rank front-ends.
Stage 2:
    Fine ratio sweep around the Stage-1 winners.
Stage 3:
    Freeze the best non-neural method, sweep ADC/W/T under Scheme B, then
    add A/B comparison, noisy-vs-ideal, adaptive-threshold, and final test.
"""

from __future__ import annotations

import argparse
import copy
import csv
import json
import os
import time
from typing import Dict, Iterable, List, Tuple

import config as cfg
import data_utils
import run_all
import snn_engine
from paper_e0_presets import (
    RECOMMEND_ACC_MARGIN,
    STAGE1_COARSE_RATIOS,
    STAGE1_FIXED_CONFIG,
    STAGE1_SCHEMES,
    STAGE2_FINE_HALF_WIDTH,
    STAGE2_FINE_STEP,
    STAGE3_ADC_BITS,
    STAGE3_PRIMARY_SCHEME,
    STAGE3_TIMESTEPS,
    STAGE3_WEIGHT_BITS,
    STAGE_METHODS,
    build_fine_ratio_grid,
    is_learned_method,
    select_stage2_finalists,
)


ORIGINAL_CFG = {
    "RESULTS_DIR": cfg.RESULTS_DIR,
    "DOWNSAMPLE_METHODS": copy.deepcopy(cfg.DOWNSAMPLE_METHODS),
    "TUNE_SPLIT": cfg.TUNE_SPLIT,
    "FINAL_REPORT_SPLIT": cfg.FINAL_REPORT_SPLIT,
    "TARGET_INPUT_DIM_FOR_RECOMMEND": cfg.TARGET_INPUT_DIM_FOR_RECOMMEND,
    "EVAL_SCHEMES": list(cfg.EVAL_SCHEMES),
    "PRIMARY_SCHEME": cfg.PRIMARY_SCHEME,
}


def _restore_cfg() -> None:
    cfg.RESULTS_DIR = ORIGINAL_CFG["RESULTS_DIR"]
    cfg.DOWNSAMPLE_METHODS = copy.deepcopy(ORIGINAL_CFG["DOWNSAMPLE_METHODS"])
    cfg.TUNE_SPLIT = ORIGINAL_CFG["TUNE_SPLIT"]
    cfg.FINAL_REPORT_SPLIT = ORIGINAL_CFG["FINAL_REPORT_SPLIT"]
    cfg.TARGET_INPUT_DIM_FOR_RECOMMEND = ORIGINAL_CFG["TARGET_INPUT_DIM_FOR_RECOMMEND"]
    cfg.EVAL_SCHEMES = list(ORIGINAL_CFG["EVAL_SCHEMES"])
    cfg.PRIMARY_SCHEME = ORIGINAL_CFG["PRIMARY_SCHEME"]


def _configure_stage_runtime(stage_name: str, method_names: List[str]) -> str:
    stage_dir = os.path.join(cfg.PROJECT_DIR, "results", "paper_e0", stage_name)
    os.makedirs(stage_dir, exist_ok=True)

    missing = [name for name in method_names if name not in ORIGINAL_CFG["DOWNSAMPLE_METHODS"]]
    if missing:
        raise KeyError(f"Unknown methods for stage {stage_name}: {missing}")

    cfg.RESULTS_DIR = stage_dir
    cfg.DOWNSAMPLE_METHODS = {
        name: ORIGINAL_CFG["DOWNSAMPLE_METHODS"][name] for name in method_names
    }
    cfg.TUNE_SPLIT = "val"
    cfg.FINAL_REPORT_SPLIT = "test"
    cfg.TARGET_INPUT_DIM_FOR_RECOMMEND = 64
    cfg.EVAL_SCHEMES = [STAGE3_PRIMARY_SCHEME]
    cfg.PRIMARY_SCHEME = STAGE3_PRIMARY_SCHEME
    return stage_dir


def _write_csv(path: str, rows: Iterable[dict], fieldnames: List[str]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def _write_json(path: str, payload: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)


def _write_text(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def _best_rows_by_method(rows: Iterable[dict]) -> List[dict]:
    best: Dict[str, dict] = {}
    for row in rows:
        method = row["method"]
        if method not in best or float(row["val_acc"]) > float(best[method]["best_val_acc"]):
            best[method] = {
                "method": method,
                "scheme": row["scheme"],
                "best_ratio": float(row["threshold_ratio"]),
                "best_val_acc": float(row["val_acc"]),
                "float_acc": float(row["float_acc"]),
                "input_dim": int(row["input_dim"]),
            }
    return sorted(best.values(), key=lambda item: item["best_val_acc"], reverse=True)


def _evaluate_ratio_grid(
    all_datasets: dict,
    training_results: dict,
    methods: List[str],
    ratio_map: Dict[str, List[float]],
    fixed_cfg: Dict[str, int],
    schemes: List[str],
    split_name: str = "val",
) -> List[dict]:
    rows: List[dict] = []
    total = len(methods) * len(schemes) * sum(len(ratio_map[m]) for m in methods)
    idx = 0

    for method in methods:
        ds = all_datasets[method]
        weights = training_results[method]["weights"]
        images_eval, labels_eval = run_all._get_split_tensors(ds, split_name)
        for scheme in schemes:
            for ratio in ratio_map[method]:
                acc, _ = snn_engine.snn_inference(
                    images_eval,
                    labels_eval,
                    weights,
                    adc_bits=fixed_cfg["adc_bits"],
                    weight_bits=fixed_cfg["weight_bits"],
                    timesteps=fixed_cfg["timesteps"],
                    scheme=scheme,
                    threshold_ratio=ratio,
                    decision="spike",
                    add_noise=False,
                )
                rows.append(
                    {
                        "method": method,
                        "input_dim": int(ds["input_dim"]),
                        "scheme": scheme,
                        "threshold_ratio": float(ratio),
                        "adc_bits": int(fixed_cfg["adc_bits"]),
                        "weight_bits": int(fixed_cfg["weight_bits"]),
                        "timesteps": int(fixed_cfg["timesteps"]),
                        "float_acc": float(training_results[method]["float_acc"]),
                        "val_acc": float(acc),
                    }
                )
                idx += 1
                run_all.progress_bar(idx, total, prefix="ratio-sweep")
    return rows


def _load_stage_summary(stage_name: str) -> dict:
    path = os.path.join(cfg.PROJECT_DIR, "results", "paper_e0", stage_name, "summary.json")
    if not os.path.isfile(path):
        raise FileNotFoundError(
            f"Missing stage summary: {path}. Run the previous stage first."
        )
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _build_stage1_summary(best_rows: List[dict]) -> dict:
    best_overall = best_rows[0]
    non_neural = [row for row in best_rows if not is_learned_method(row["method"])]
    if not non_neural:
        raise RuntimeError("Stage 1 produced no non-neural candidate.")
    best_non_neural = non_neural[0]
    finalists = select_stage2_finalists(best_rows)
    return {
        "stage": "stage1",
        "fixed_config": dict(STAGE1_FIXED_CONFIG),
        "schemes": list(STAGE1_SCHEMES),
        "coarse_ratio_candidates": list(STAGE1_COARSE_RATIOS),
        "best_by_method": best_rows,
        "best_overall": best_overall,
        "best_non_neural": best_non_neural,
        "recommended_finalists": finalists,
    }


def _build_stage2_summary(best_rows: List[dict], fine_ratio_map: Dict[str, List[float]]) -> dict:
    best_overall = best_rows[0]
    non_neural = [row for row in best_rows if not is_learned_method(row["method"])]
    if not non_neural:
        raise RuntimeError("Stage 2 produced no non-neural candidate.")
    best_non_neural = non_neural[0]
    return {
        "stage": "stage2",
        "fixed_config": dict(STAGE1_FIXED_CONFIG),
        "schemes": list(STAGE1_SCHEMES),
        "best_by_method": best_rows,
        "best_overall": best_overall,
        "best_non_neural": best_non_neural,
        "fine_ratio_map": fine_ratio_map,
    }


def _save_stage_summary(stage_dir: str, summary: dict, note_lines: List[str]) -> None:
    _write_json(os.path.join(stage_dir, "summary.json"), summary)
    _write_text(os.path.join(stage_dir, "summary.txt"), "\n".join(note_lines) + "\n")


def _stage_banner(title: str) -> None:
    print("\n" + "=" * 72)
    print(title)
    print("=" * 72)


def run_stage1(args: argparse.Namespace) -> None:
    stage_dir = _configure_stage_runtime("stage1", list(STAGE_METHODS))
    run_all.set_global_seed(cfg.RANDOM_SEED)
    run_all._ensure_mode_weight_dir(args)

    _stage_banner("Stage 1: fixed 8/4/3, Scheme B only, coarse ratio sweep")
    all_datasets = data_utils.prepare_all_datasets(quick_mode=args.quick)
    training_results = run_all.run_training(
        all_datasets, skip_train=args.skip_train, quick=args.quick
    )

    ratio_map = {method: list(STAGE1_COARSE_RATIOS) for method in STAGE_METHODS}
    rows = _evaluate_ratio_grid(
        all_datasets,
        training_results,
        methods=list(STAGE_METHODS),
        ratio_map=ratio_map,
        fixed_cfg=STAGE1_FIXED_CONFIG,
        schemes=list(STAGE1_SCHEMES),
    )
    _write_csv(
        os.path.join(stage_dir, "coarse_ratio_results.csv"),
        rows,
        [
            "method",
            "input_dim",
            "scheme",
            "threshold_ratio",
            "adc_bits",
            "weight_bits",
            "timesteps",
            "float_acc",
            "val_acc",
        ],
    )

    best_rows = _best_rows_by_method(rows)
    _write_csv(
        os.path.join(stage_dir, "best_by_method.csv"),
        best_rows,
        ["method", "scheme", "best_ratio", "best_val_acc", "float_acc", "input_dim"],
    )
    summary = _build_stage1_summary(best_rows)
    notes = [
        "Stage 1 summary",
        f"Fixed config: ADC={STAGE1_FIXED_CONFIG['adc_bits']}, W={STAGE1_FIXED_CONFIG['weight_bits']}, T={STAGE1_FIXED_CONFIG['timesteps']}",
        f"Scheme(s): {', '.join(STAGE1_SCHEMES)}",
        "Best overall: "
        f"{summary['best_overall']['method']} @ ratio={summary['best_overall']['best_ratio']:.4f} "
        f"(val_acc={summary['best_overall']['best_val_acc']:.4%})",
        "Best non-neural: "
        f"{summary['best_non_neural']['method']} @ ratio={summary['best_non_neural']['best_ratio']:.4f} "
        f"(val_acc={summary['best_non_neural']['best_val_acc']:.4%})",
        "Recommended finalists: " + ", ".join(summary["recommended_finalists"]),
    ]
    _save_stage_summary(stage_dir, summary, notes)


def run_stage2(args: argparse.Namespace) -> None:
    stage1_summary = _load_stage_summary("stage1")
    finalists = args.stage2_finalists or stage1_summary["recommended_finalists"]
    stage_dir = _configure_stage_runtime("stage2", finalists)
    run_all.set_global_seed(cfg.RANDOM_SEED)
    run_all._ensure_mode_weight_dir(args)

    _stage_banner("Stage 2: fine ratio sweep on finalists")
    all_datasets = data_utils.prepare_all_datasets(quick_mode=args.quick)
    training_results = run_all.run_training(
        all_datasets, skip_train=args.skip_train, quick=args.quick
    )

    coarse_best = {
        row["method"]: float(row["best_ratio"]) for row in stage1_summary["best_by_method"]
    }
    fine_ratio_map = {
        method: build_fine_ratio_grid(
            coarse_best[method],
            half_width=STAGE2_FINE_HALF_WIDTH,
            step=STAGE2_FINE_STEP,
        )
        for method in finalists
    }
    rows = _evaluate_ratio_grid(
        all_datasets,
        training_results,
        methods=finalists,
        ratio_map=fine_ratio_map,
        fixed_cfg=STAGE1_FIXED_CONFIG,
        schemes=list(STAGE1_SCHEMES),
    )
    _write_csv(
        os.path.join(stage_dir, "fine_ratio_results.csv"),
        rows,
        [
            "method",
            "input_dim",
            "scheme",
            "threshold_ratio",
            "adc_bits",
            "weight_bits",
            "timesteps",
            "float_acc",
            "val_acc",
        ],
    )

    best_rows = _best_rows_by_method(rows)
    _write_csv(
        os.path.join(stage_dir, "best_by_method.csv"),
        best_rows,
        ["method", "scheme", "best_ratio", "best_val_acc", "float_acc", "input_dim"],
    )
    summary = _build_stage2_summary(best_rows, fine_ratio_map)
    notes = [
        "Stage 2 summary",
        "Fine-ratio finalists: " + ", ".join(finalists),
        "Best non-neural: "
        f"{summary['best_non_neural']['method']} @ ratio={summary['best_non_neural']['best_ratio']:.4f} "
        f"(val_acc={summary['best_non_neural']['best_val_acc']:.4%})",
        "Upper-bound reference: "
        f"{summary['best_overall']['method']} @ ratio={summary['best_overall']['best_ratio']:.4f} "
        f"(val_acc={summary['best_overall']['best_val_acc']:.4%})",
    ]
    _save_stage_summary(stage_dir, summary, notes)


def _recommend_from_full_grid(rows: List[dict]) -> Tuple[dict, dict]:
    best_case = max(rows, key=lambda item: float(item["val_acc"]))
    acc_floor = float(best_case["val_acc"]) - RECOMMEND_ACC_MARGIN
    near_best = [row for row in rows if float(row["val_acc"]) >= acc_floor]
    recommendation = min(
        near_best,
        key=lambda row: (
            int(row["adc_bits"]),
            int(row["weight_bits"]),
            int(row["timesteps"]),
            -float(row["val_acc"]),
        ),
    )
    return best_case, recommendation


def _run_stage3_full_grid(ds: dict, weights, ratio_b: float) -> List[dict]:
    rows: List[dict] = []
    images_eval, labels_eval = run_all._get_split_tensors(ds, "val")
    total = len(STAGE3_ADC_BITS) * len(STAGE3_WEIGHT_BITS) * len(STAGE3_TIMESTEPS)
    idx = 0

    for adc_bits in STAGE3_ADC_BITS:
        for weight_bits in STAGE3_WEIGHT_BITS:
            for timesteps in STAGE3_TIMESTEPS:
                acc, _ = snn_engine.snn_inference(
                    images_eval,
                    labels_eval,
                    weights,
                    adc_bits=adc_bits,
                    weight_bits=weight_bits,
                    timesteps=timesteps,
                    scheme=STAGE3_PRIMARY_SCHEME,
                    threshold_ratio=ratio_b,
                    decision="spike",
                    add_noise=False,
                )
                rows.append(
                    {
                        "scheme": STAGE3_PRIMARY_SCHEME,
                        "threshold_ratio": float(ratio_b),
                        "adc_bits": int(adc_bits),
                        "weight_bits": int(weight_bits),
                        "timesteps": int(timesteps),
                        "val_acc": float(acc),
                    }
                )
                idx += 1
                run_all.progress_bar(idx, total, prefix="stage3-grid")
    return rows


def _filter_1d_slice(rows: List[dict], adc_bits: int, weight_bits: int, timesteps: int, axis: str) -> List[dict]:
    filtered: List[dict] = []
    for row in rows:
        if axis != "adc_bits" and int(row["adc_bits"]) != adc_bits:
            continue
        if axis != "weight_bits" and int(row["weight_bits"]) != weight_bits:
            continue
        if axis != "timesteps" and int(row["timesteps"]) != timesteps:
            continue
        filtered.append(row)
    return sorted(filtered, key=lambda item: int(item[axis]))


def _run_scheme_a_compare(ds: dict, weights, ref_cfg: dict, ratio_b: float) -> Tuple[List[dict], List[dict], float, List[dict]]:
    images_eval, labels_eval = run_all._get_split_tensors(ds, "val")
    coarse_rows: List[dict] = []
    for ratio in STAGE1_COARSE_RATIOS:
        acc, _ = snn_engine.snn_inference(
            images_eval,
            labels_eval,
            weights,
            adc_bits=ref_cfg["adc_bits"],
            weight_bits=ref_cfg["weight_bits"],
            timesteps=ref_cfg["timesteps"],
            scheme="A",
            threshold_ratio=ratio,
            decision="spike",
            add_noise=False,
        )
        coarse_rows.append({"scheme": "A", "threshold_ratio": float(ratio), "val_acc": float(acc)})

    coarse_best = max(coarse_rows, key=lambda item: item["val_acc"])
    fine_rows: List[dict] = []
    for ratio in build_fine_ratio_grid(
        coarse_best["threshold_ratio"],
        half_width=STAGE2_FINE_HALF_WIDTH,
        step=STAGE2_FINE_STEP,
    ):
        acc, _ = snn_engine.snn_inference(
            images_eval,
            labels_eval,
            weights,
            adc_bits=ref_cfg["adc_bits"],
            weight_bits=ref_cfg["weight_bits"],
            timesteps=ref_cfg["timesteps"],
            scheme="A",
            threshold_ratio=ratio,
            decision="spike",
            add_noise=False,
        )
        fine_rows.append({"scheme": "A", "threshold_ratio": float(ratio), "val_acc": float(acc)})

    best_ratio_a = max(fine_rows, key=lambda item: item["val_acc"])["threshold_ratio"]
    scheme_compare: List[dict] = []
    for scheme, ratio in [("A", best_ratio_a), ("B", ratio_b)]:
        acc, _ = snn_engine.snn_inference(
            images_eval,
            labels_eval,
            weights,
            adc_bits=ref_cfg["adc_bits"],
            weight_bits=ref_cfg["weight_bits"],
            timesteps=ref_cfg["timesteps"],
            scheme=scheme,
            threshold_ratio=ratio,
            decision="spike",
            add_noise=False,
        )
        scheme_compare.append(
            {
                "scheme": scheme,
                "threshold_ratio": float(ratio),
                "adc_bits": int(ref_cfg["adc_bits"]),
                "weight_bits": int(ref_cfg["weight_bits"]),
                "timesteps": int(ref_cfg["timesteps"]),
                "val_acc": float(acc),
            }
        )
    return coarse_rows, fine_rows, float(best_ratio_a), scheme_compare


def _run_noise_compare(ds: dict, weights, rec_cfg: dict, trials: int) -> dict:
    images_eval, labels_eval = run_all._get_split_tensors(ds, "val")
    ideal_acc, _ = snn_engine.snn_inference(
        images_eval,
        labels_eval,
        weights,
        adc_bits=rec_cfg["adc_bits"],
        weight_bits=rec_cfg["weight_bits"],
        timesteps=rec_cfg["timesteps"],
        scheme="B",
        threshold_ratio=rec_cfg["threshold_ratio"],
        decision="spike",
        add_noise=False,
    )
    noisy_accs: List[float] = []
    for idx in range(trials):
        acc, _ = snn_engine.snn_inference(
            images_eval,
            labels_eval,
            weights,
            adc_bits=rec_cfg["adc_bits"],
            weight_bits=rec_cfg["weight_bits"],
            timesteps=rec_cfg["timesteps"],
            scheme="B",
            threshold_ratio=rec_cfg["threshold_ratio"],
            decision="spike",
            add_noise=True,
        )
        noisy_accs.append(float(acc))
        run_all.progress_bar(idx + 1, trials, prefix="stage3-noise")
    noisy_mean = float(sum(noisy_accs) / max(1, len(noisy_accs)))
    noisy_var = sum((acc - noisy_mean) ** 2 for acc in noisy_accs) / max(1, len(noisy_accs))
    return {
        "ideal_val_acc": float(ideal_acc),
        "noisy_mean_val_acc": noisy_mean,
        "noisy_std_val_acc": noisy_var ** 0.5,
        "trials": int(trials),
    }


def _run_adaptive_compare(ds: dict, weights, rec_cfg: dict) -> dict:
    images_eval, labels_eval = run_all._get_split_tensors(ds, "val")
    fixed_acc, _ = snn_engine.snn_inference(
        images_eval,
        labels_eval,
        weights,
        adc_bits=rec_cfg["adc_bits"],
        weight_bits=rec_cfg["weight_bits"],
        timesteps=rec_cfg["timesteps"],
        scheme="B",
        threshold_ratio=rec_cfg["threshold_ratio"],
        decision="spike",
        add_noise=False,
    )
    adaptive_acc, _ = snn_engine.snn_inference_adaptive_threshold(
        images_eval,
        labels_eval,
        weights,
        adc_bits=rec_cfg["adc_bits"],
        weight_bits=rec_cfg["weight_bits"],
        timesteps=rec_cfg["timesteps"],
        scheme="B",
        add_noise=False,
    )
    return {
        "fixed_val_acc": float(fixed_acc),
        "adaptive_val_acc": float(adaptive_acc),
        "improvement": float(adaptive_acc - fixed_acc),
    }


def _run_final_test(ds: dict, weights, rec_cfg: dict) -> dict:
    images_eval, labels_eval = run_all._get_split_tensors(ds, "test")
    acc, _, stats = snn_engine.snn_inference(
        images_eval,
        labels_eval,
        weights,
        adc_bits=rec_cfg["adc_bits"],
        weight_bits=rec_cfg["weight_bits"],
        timesteps=rec_cfg["timesteps"],
        scheme="B",
        threshold_ratio=rec_cfg["threshold_ratio"],
        decision="spike",
        add_noise=False,
        return_stats=True,
    )
    payload = {
        "test_acc": float(acc),
        "adc_bits": int(rec_cfg["adc_bits"]),
        "weight_bits": int(rec_cfg["weight_bits"]),
        "timesteps": int(rec_cfg["timesteps"]),
        "threshold_ratio": float(rec_cfg["threshold_ratio"]),
    }
    if "spike_only_acc" in stats:
        payload["hardware_aligned_test_acc"] = float(stats["spike_only_acc"])
        payload["zero_spike_rate"] = float(stats.get("zero_spike_rate", 0.0))
        payload["zero_spike_count"] = int(stats.get("zero_spike_count", 0))
    return payload


def run_stage3(args: argparse.Namespace) -> None:
    stage2_summary = _load_stage_summary("stage2")
    main_method = args.stage3_method or stage2_summary["best_non_neural"]["method"]
    stage_dir = _configure_stage_runtime("stage3", [main_method])
    run_all.set_global_seed(cfg.RANDOM_SEED)
    run_all._ensure_mode_weight_dir(args)

    _stage_banner("Stage 3: freeze best non-neural method and sweep hardware params")
    all_datasets = data_utils.prepare_all_datasets(quick_mode=args.quick)
    training_results = run_all.run_training(
        all_datasets, skip_train=args.skip_train, quick=args.quick
    )

    ds = all_datasets[main_method]
    weights = training_results[main_method]["weights"]
    fine_best = {row["method"]: float(row["best_ratio"]) for row in stage2_summary["best_by_method"]}
    ratio_b = fine_best[main_method]

    full_grid = _run_stage3_full_grid(ds, weights, ratio_b)
    _write_csv(
        os.path.join(stage_dir, "full_grid_scheme_b.csv"),
        full_grid,
        ["scheme", "threshold_ratio", "adc_bits", "weight_bits", "timesteps", "val_acc"],
    )

    best_case, recommendation = _recommend_from_full_grid(full_grid)
    _write_json(os.path.join(stage_dir, "best_case.json"), best_case)
    _write_json(os.path.join(stage_dir, "recommendation.json"), recommendation)

    adc_sweep = _filter_1d_slice(
        full_grid,
        adc_bits=STAGE1_FIXED_CONFIG["adc_bits"],
        weight_bits=STAGE1_FIXED_CONFIG["weight_bits"],
        timesteps=STAGE1_FIXED_CONFIG["timesteps"],
        axis="adc_bits",
    )
    weight_sweep = _filter_1d_slice(
        full_grid,
        adc_bits=STAGE1_FIXED_CONFIG["adc_bits"],
        weight_bits=STAGE1_FIXED_CONFIG["weight_bits"],
        timesteps=STAGE1_FIXED_CONFIG["timesteps"],
        axis="weight_bits",
    )
    timestep_sweep = _filter_1d_slice(
        full_grid,
        adc_bits=STAGE1_FIXED_CONFIG["adc_bits"],
        weight_bits=STAGE1_FIXED_CONFIG["weight_bits"],
        timesteps=STAGE1_FIXED_CONFIG["timesteps"],
        axis="timesteps",
    )
    _write_csv(
        os.path.join(stage_dir, "adc_sweep.csv"),
        adc_sweep,
        ["scheme", "threshold_ratio", "adc_bits", "weight_bits", "timesteps", "val_acc"],
    )
    _write_csv(
        os.path.join(stage_dir, "weight_sweep.csv"),
        weight_sweep,
        ["scheme", "threshold_ratio", "adc_bits", "weight_bits", "timesteps", "val_acc"],
    )
    _write_csv(
        os.path.join(stage_dir, "timestep_sweep.csv"),
        timestep_sweep,
        ["scheme", "threshold_ratio", "adc_bits", "weight_bits", "timesteps", "val_acc"],
    )

    coarse_a, fine_a, best_ratio_a, scheme_compare = _run_scheme_a_compare(
        ds,
        weights,
        recommendation,
        ratio_b=ratio_b,
    )
    _write_csv(
        os.path.join(stage_dir, "scheme_a_coarse_ratio.csv"),
        coarse_a,
        ["scheme", "threshold_ratio", "val_acc"],
    )
    _write_csv(
        os.path.join(stage_dir, "scheme_a_fine_ratio.csv"),
        fine_a,
        ["scheme", "threshold_ratio", "val_acc"],
    )
    _write_csv(
        os.path.join(stage_dir, "scheme_compare.csv"),
        scheme_compare,
        ["scheme", "threshold_ratio", "adc_bits", "weight_bits", "timesteps", "val_acc"],
    )

    noise_trials = int(args.noise_trials or (cfg.NOISE_TRIALS_QUICK if args.quick else cfg.NOISE_TRIALS_FULL))
    noise_compare = _run_noise_compare(ds, weights, recommendation, trials=noise_trials)
    adaptive_compare = _run_adaptive_compare(ds, weights, recommendation)
    final_test = _run_final_test(ds, weights, recommendation)
    _write_json(os.path.join(stage_dir, "noise_compare.json"), noise_compare)
    _write_json(os.path.join(stage_dir, "adaptive_compare.json"), adaptive_compare)
    _write_json(os.path.join(stage_dir, "final_test.json"), final_test)

    summary = {
        "stage": "stage3",
        "main_method": main_method,
        "ratio_b": float(ratio_b),
        "ratio_a": float(best_ratio_a),
        "best_case": best_case,
        "recommendation": recommendation,
        "noise_compare": noise_compare,
        "adaptive_compare": adaptive_compare,
        "final_test": final_test,
    }
    notes = [
        "Stage 3 summary",
        f"Main method: {main_method}",
        f"Scheme B ratio (from Stage 2): {ratio_b:.4f}",
        f"Scheme A ratio (stage-3 compare): {best_ratio_a:.4f}",
        "Best case (Scheme B full grid): "
        f"ADC={best_case['adc_bits']}, W={best_case['weight_bits']}, T={best_case['timesteps']}, "
        f"val_acc={best_case['val_acc']:.4%}",
        "Recommendation (within margin): "
        f"ADC={recommendation['adc_bits']}, W={recommendation['weight_bits']}, "
        f"T={recommendation['timesteps']}, val_acc={recommendation['val_acc']:.4%}",
        f"Final test: {final_test['test_acc']:.4%}",
    ]
    _save_stage_summary(stage_dir, summary, notes)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Paper E0 staged rerun runner")
    parser.add_argument("--stage", type=int, choices=[1, 2, 3], required=True)
    parser.add_argument("--quick", action="store_true", help="Use quick-mode data/training.")
    parser.add_argument(
        "--skip-train",
        action="store_true",
        help="Reuse saved weights if training-side settings are unchanged.",
    )
    parser.add_argument(
        "--stage2-finalists",
        nargs="*",
        default=None,
        help="Optional explicit finalist list for Stage 2.",
    )
    parser.add_argument(
        "--stage3-method",
        default=None,
        help="Optional explicit main method for Stage 3.",
    )
    parser.add_argument(
        "--noise-trials",
        type=int,
        default=None,
        help="Override Stage-3 noisy trial count.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    start = time.time()
    try:
        if args.stage == 1:
            run_stage1(args)
        elif args.stage == 2:
            run_stage2(args)
        else:
            run_stage3(args)
    finally:
        _restore_cfg()

    elapsed = time.time() - start
    print(f"\nStage {args.stage} finished in {elapsed / 60.0:.1f} minutes.")


if __name__ == "__main__":
    main()
