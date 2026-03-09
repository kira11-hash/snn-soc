"""
==========================================================
  SNN SoC Python 建模 - 主程序
==========================================================
用法：
    python run_all.py              # 完整运行（约 10-30 分钟）
    python run_all.py --quick      # 快速测试（约 2-3 分钟）
    python run_all.py --skip-train # 跳过训练，直接加载已保存权重

运行流程：
    步骤 1：准备 MNIST 数据（多种输入方式）
    步骤 2：训练 ANN（得到 float 基线权重）
    步骤 3：SNN 推理 + 参数扫描（核心步骤）
    步骤 4：生成图表 + 输出推荐参数

输出文件（保存在 results/ 目录）：
    fig1_downsample_comparison.png  - 不同输入方式的 ANN / SNN 对比
    fig2_adc_bits_sweep.png         - ADC 位宽对准确率的影响
    fig3_weight_bits_sweep.png      - 权重量化位宽对准确率的影响
    fig4_timesteps_sweep.png        - 推理时步数对准确率的影响
    fig5_noise_impact.png           - 器件非理想性对准确率的影响
    fig6_scheme_comparison.png      - Scheme A / B 对比
    fig7_adaptive_threshold.png     - 自适应阈值与固定阈值对比
    summary.txt                     - 参数推荐总结
    exports/*.csv                   - 推荐配置 / best-case 的权重映射导出
    exports/*weight_pos.hex         - 推荐配置 / best-case 的正权重 HEX
    exports/*weight_neg.hex         - 推荐配置 / best-case 的负权重 HEX
    exports/weight_export_manifest.json - 权重导出清单
"""
import sys
import os
import argparse
import time
import random
import shutil
import hashlib
import json
import subprocess
from datetime import datetime
import torch
import numpy as np

# Keep terminal output robust on Windows code pages.
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# 让 matplotlib 在无 GUI 环境下也能保存图片
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# 导入本项目模块
import config as cfg
import data_utils
import train_ann
import snn_engine
import export_weight_map


# =====================================================
#  辅助函数
# =====================================================

def setup_chinese_font():
    """Try to set Chinese-capable fonts for plotting."""
    try:
        plt.rcParams['font.sans-serif'] = ['SimHei', 'Microsoft YaHei',
                                           'DejaVu Sans']
        plt.rcParams['axes.unicode_minus'] = False
        return True
    except Exception:
        return False


def progress_bar(current, total, prefix='', suffix='', length=40):
    """Print a simple terminal progress bar."""
    percent = current / total
    filled = int(length * percent)
    bar = '#' * filled + '-' * (length - filled)
    sys.stdout.write(f'\r  {prefix} |{bar}| {percent:.0%} {suffix}')
    sys.stdout.flush()
    if current == total:
        print()


def set_global_seed(seed):
    """Set random seeds for deterministic runs."""
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def _sha256_file(path, chunk_size=1024 * 1024):
    """Return SHA256 hex digest for a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def _iter_files(root_dir):
    """Yield absolute file paths under root_dir in stable order."""
    if not os.path.isdir(root_dir):
        return
    for cur_root, _, files in os.walk(root_dir):
        for name in sorted(files):
            yield os.path.join(cur_root, name)


def _copy_tree(src_dir, dst_dir):
    """Copy directory tree if source exists."""
    if not os.path.isdir(src_dir):
        return False
    os.makedirs(dst_dir, exist_ok=True)
    for src_path in _iter_files(src_dir):
        rel = os.path.relpath(src_path, src_dir)
        dst_path = os.path.join(dst_dir, rel)
        os.makedirs(os.path.dirname(dst_path), exist_ok=True)
        shutil.copy2(src_path, dst_path)
    return True


def _git_run(*args, cwd=None):
    """Run a git command and return stripped stdout or None."""
    try:
        out = subprocess.check_output(
            ["git", *args], cwd=cwd, stderr=subprocess.DEVNULL, text=True
        )
        return out.strip()
    except Exception:
        return None


def _get_git_metadata():
    """Collect git commit metadata for reproducibility."""
    repo_root = os.path.dirname(cfg.PROJECT_DIR)
    commit = _git_run("rev-parse", "HEAD", cwd=repo_root)
    short = _git_run("rev-parse", "--short", "HEAD", cwd=repo_root)
    status = _git_run("status", "--short", cwd=repo_root)
    branch = _git_run("rev-parse", "--abbrev-ref", "HEAD", cwd=repo_root)
    return {
        "repo_root": repo_root,
        "commit": commit,
        "commit_short": short,
        "branch": branch,
        "dirty": bool(status),
        "status_short": status or "",
    }


def _list_file_records(root_dir):
    """Collect file timestamp/size/hash records under root_dir."""
    records = []
    if not os.path.isdir(root_dir):
        return records
    for path in _iter_files(root_dir):
        stat = os.stat(path)
        records.append({
            "relpath": os.path.relpath(path, root_dir).replace("\\", "/"),
            "size": int(stat.st_size),
            "mtime": datetime.fromtimestamp(stat.st_mtime).isoformat(timespec="seconds"),
            "sha256": _sha256_file(path),
        })
    return records


def _ensure_mode_weight_dir(args):
    """
    Split quick/full runs into separate weight directories to avoid overwrite.
    Full mode uses weights_full (with one-time migration from legacy weights/).
    """
    project_dir = cfg.PROJECT_DIR
    legacy_weights_dir = os.path.join(project_dir, "weights")
    full_weights_dir = getattr(cfg, "WEIGHTS_DIR_FULL", os.path.join(project_dir, "weights_full"))
    quick_weights_dir = getattr(cfg, "WEIGHTS_DIR_QUICK", os.path.join(project_dir, "weights_quick"))
    target_weights_dir = quick_weights_dir if args.quick else full_weights_dir

    # One-time migration keeps old full-run weights usable after introducing split dirs.
    if (not args.quick
            and not os.path.isdir(full_weights_dir)
            and os.path.isdir(legacy_weights_dir)):
        legacy_pt = [p for p in os.listdir(legacy_weights_dir) if p.endswith(".pt")]
        if legacy_pt:
            os.makedirs(full_weights_dir, exist_ok=True)
            for name in legacy_pt:
                shutil.copy2(
                    os.path.join(legacy_weights_dir, name),
                    os.path.join(full_weights_dir, name),
                )
            print(
                f"  [dir] Migrated {len(legacy_pt)} legacy weight files: "
                f"{legacy_weights_dir} -> {full_weights_dir}"
            )

    cfg.WEIGHTS_DIR = target_weights_dir
    os.makedirs(cfg.WEIGHTS_DIR, exist_ok=True)
    os.makedirs(cfg.RESULTS_DIR, exist_ok=True)
    print(f"  [dir] Results: {cfg.RESULTS_DIR}")
    print(f"  [dir] Weights ({'quick' if args.quick else 'full'}): {cfg.WEIGHTS_DIR}")
    return {
        "results_dir": cfg.RESULTS_DIR,
        "weights_dir": cfg.WEIGHTS_DIR,
        "legacy_weights_dir": legacy_weights_dir,
        "full_weights_dir": full_weights_dir,
        "quick_weights_dir": quick_weights_dir,
    }


def _write_backup_manifest(backup_dir, run_meta, git_meta, weights_records, results_records):
    """Write a reproducibility manifest for a completed full run."""
    lines = []
    lines.append("SNN SoC Python Modeling Backup Manifest")
    lines.append("=" * 48)
    for key in [
        "created_at",
        "run_mode",
        "skip_train",
        "elapsed_sec",
        "elapsed_min",
        "cwd",
        "argv",
        "results_dir",
        "weights_dir",
    ]:
        lines.append(f"{key}: {run_meta.get(key)}")

    lines.append("")
    lines.append("[git]")
    for key in ["repo_root", "branch", "commit", "commit_short", "dirty"]:
        lines.append(f"{key}: {git_meta.get(key)}")
    status_short = git_meta.get("status_short", "")
    if status_short:
        lines.append("status_short:")
        lines.extend(f"  {ln}" for ln in status_short.splitlines())

    lines.append("")
    lines.append("[config_snapshot]")
    cfg_snapshot_path = os.path.join(backup_dir, "config.py")
    if os.path.isfile(cfg_snapshot_path):
        stat = os.stat(cfg_snapshot_path)
        lines.append(f"path: {cfg_snapshot_path}")
        lines.append(f"mtime: {datetime.fromtimestamp(stat.st_mtime).isoformat(timespec='seconds')}")
        lines.append(f"size: {int(stat.st_size)}")
        lines.append(f"sha256: {_sha256_file(cfg_snapshot_path)}")

    def _append_records(title, records):
        lines.append("")
        lines.append(f"[{title}] count={len(records)}")
        for rec in records:
            lines.append(
                f"{rec['relpath']} | size={rec['size']} | mtime={rec['mtime']} | sha256={rec['sha256']}"
            )

    _append_records("weights_files", weights_records)
    _append_records("results_files", results_records)

    manifest_path = os.path.join(backup_dir, "backup_manifest.txt")
    with open(manifest_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return manifest_path


def _auto_backup_full_run(args, elapsed_sec):
    """
    Backup results + weights + config immediately after a successful non-quick run.
    """
    if args.quick:
        return None

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    backups_root = os.path.join(cfg.PROJECT_DIR, "backups")
    backup_dir = os.path.join(backups_root, f"full_run_{ts}")
    os.makedirs(backup_dir, exist_ok=True)

    copied_results = _copy_tree(cfg.RESULTS_DIR, os.path.join(backup_dir, "results"))
    copied_weights = _copy_tree(cfg.WEIGHTS_DIR, os.path.join(backup_dir, "weights"))
    shutil.copy2(os.path.join(cfg.PROJECT_DIR, "config.py"), os.path.join(backup_dir, "config.py"))

    run_meta = {
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "run_mode": "quick" if args.quick else "full",
        "skip_train": bool(args.skip_train),
        "elapsed_sec": f"{elapsed_sec:.1f}",
        "elapsed_min": f"{elapsed_sec / 60.0:.1f}",
        "cwd": os.getcwd(),
        "argv": " ".join(sys.argv),
        "results_dir": cfg.RESULTS_DIR,
        "weights_dir": cfg.WEIGHTS_DIR,
        "results_copied": bool(copied_results),
        "weights_copied": bool(copied_weights),
    }
    git_meta = _get_git_metadata()
    weights_records = _list_file_records(os.path.join(backup_dir, "weights"))
    results_records = _list_file_records(os.path.join(backup_dir, "results"))
    manifest_path = _write_backup_manifest(
        backup_dir, run_meta, git_meta, weights_records, results_records
    )

    latest_path_file = os.path.join(backups_root, "latest_backup_path.txt")
    with open(latest_path_file, "w", encoding="utf-8") as f:
        f.write(backup_dir + "\n")

    return {
        "backup_dir": backup_dir,
        "manifest_path": manifest_path,
        "latest_path_file": latest_path_file,
        "weights_count": len(weights_records),
        "results_count": len(results_records),
    }



def calibrate_threshold_ratio(ds, W, adc_bits=8, weight_bits=4,
                              timesteps=1, scheme='A'):
    """
    Calibrate spike threshold ratio on a validation subset.
    Returns (best_ratio, best_acc, candidate_scores) or (None, None, []) if disabled.
    candidate_scores is a list of {"ratio": float, "val_acc": float} for all candidates.
    """
    if not getattr(cfg, 'CALIBRATE_THRESHOLD_RATIO', False):
        return None, None, []

    candidates = list(getattr(cfg, 'THRESHOLD_RATIO_CANDIDATES', []))
    if not candidates:
        return None, None, []

    n = int(getattr(cfg, 'THRESHOLD_CALIBRATE_SAMPLES', 0) or 0)
    images_src = ds.get("val_images_uint8")
    labels_src = ds.get("val_labels")
    if images_src is None or labels_src is None:
        return None, None, []
    n = min(n, int(labels_src.shape[0]))
    if n <= 0:
        return None, None, []

    # Use a deterministic random subset to avoid positional/class-order bias.
    gen = torch.Generator().manual_seed(int(getattr(cfg, "RANDOM_SEED", 42)) + 20260207)
    perm = torch.randperm(int(labels_src.shape[0]), generator=gen)[:n]
    images = images_src[perm]
    labels = labels_src[perm]

    best_ratio = None
    best_acc = -1.0
    candidate_scores = []
    for ratio in candidates:
        acc, _, stats = snn_engine.snn_inference(
            images, labels, W,
            adc_bits=adc_bits, weight_bits=weight_bits, timesteps=timesteps,
            scheme=scheme, decision='spike', threshold_ratio=ratio,
            spike_fallback_to_membrane=False,  # 以纯 spike 指标标定，与硬件行为对齐
            return_stats=True,
        )
        spike_acc = stats.get("spike_only_acc", acc)
        candidate_scores.append({
            "ratio": float(ratio),
            "val_acc": float(spike_acc),
        })
        if spike_acc > best_acc:
            best_acc = spike_acc
            best_ratio = ratio

    return best_ratio, best_acc, candidate_scores


def _get_split_tensors(ds, split_name):
    """
    Return (images_uint8, labels) for the requested split.
    """
    split = str(split_name).lower()
    if split == "val":
        images = ds.get("val_images_uint8")
        labels = ds.get("val_labels")
    elif split == "test":
        images = ds.get("test_images_uint8")
        labels = ds.get("test_labels")
    else:
        raise ValueError(f"unknown split: {split_name}")

    if images is None or labels is None:
        raise ValueError(f"split '{split}' is unavailable for current dataset")
    return images, labels


def _pick_min_within_margin(metric_dict, margin=0.005):
    """
    Pick the smallest key whose value is within `margin` of the best value.
    """
    items = sorted(metric_dict.items(), key=lambda kv: kv[0])
    if not items:
        raise ValueError("metric_dict is empty")
    best = max(v for _, v in items)
    target = best - margin
    candidates = [k for k, v in items if v >= target]
    return min(candidates) if candidates else items[-1][0]


def _resolve_eval_schemes():
    schemes = list(getattr(cfg, "EVAL_SCHEMES", ["A", "B"]))
    if not schemes:
        schemes = ["B"]
    schemes = [str(s).upper() for s in schemes]
    if not bool(getattr(cfg, "ALLOW_SIGNED_SCHEME_A", False)):
        schemes = [s for s in schemes if s != "A"]
        if not schemes:
            schemes = ["B"]
    primary = str(getattr(cfg, "PRIMARY_SCHEME", schemes[0])).upper()
    if primary == "A" and not bool(getattr(cfg, "ALLOW_SIGNED_SCHEME_A", False)):
        primary = "B"
    if primary not in schemes:
        schemes = [primary] + [s for s in schemes if s != primary]
    return schemes, primary


def _run_spike_only_inference(images, labels, weights, **kwargs):
    """
    Run SNN inference in hardware-aligned spike-only mode.
    """
    acc, membranes, stats = snn_engine.snn_inference(
        images, labels, weights,
        decision='spike',
        spike_fallback_to_membrane=False,
        return_stats=True,
        **kwargs,
    )
    stats = dict(stats or {})
    stats["acc"] = float(acc)
    stats["spike_only_acc"] = float(stats.get("spike_only_acc", acc))
    stats["zero_spike_rate"] = float(stats.get("zero_spike_rate", 0.0))
    stats["zero_spike_count"] = int(stats.get("zero_spike_count", 0))
    stats["decision_mode"] = "spike_only_no_fallback"
    return float(stats["spike_only_acc"]), membranes, stats


def _best_case_rank_key(item):
    """
    Order exhaustive combinations by hardware-aligned quality first.
    Higher spike_only_acc wins; lower zero_spike_rate breaks ties.
    """
    return (
        -float(item.get("spike_only_acc", item.get("snn_acc", 0.0))),
        float(item.get("zero_spike_rate", 1.0)),
        int(item.get("adc_bits", 1_000_000)),
        int(item.get("weight_bits", 1_000_000)),
        int(item.get("timesteps", 1_000_000)),
        0 if str(item.get("reset_mode", "soft")).lower() == "soft" else 1,
        str(item.get("method", "")),
    )


def _combo_cost_key(item, primary_scheme):
    """
    Recommendation ordering after filtering to near-best spike accuracy.
    Lower zero-spike rate wins first, then lower cost, then prefer primary scheme.
    """
    return (
        float(item.get("zero_spike_rate", 1.0)),
        int(item["adc_bits"]),
        int(item["weight_bits"]),
        int(item["timesteps"]),
        0 if str(item["scheme"]).upper() == str(primary_scheme).upper() else 1,
        0 if str(item.get("reset_mode", "soft")).lower() == "soft" else 1,
        -float(item.get("spike_only_acc", item.get("snn_acc", 0.0))),
        str(item["method"]),
    )

# =====================================================
#  步骤 2: 训练 ANN
# =====================================================

def run_training(all_datasets, skip_train=False, quick=False):
    """
    对每种降采样方法分别训练一个 ANN，并记录 float 基线准确率。

    返回：
        results: dict, {方法名: {"float_acc": 准确率, "weights": W 矩阵}}
    """
    print("\n[步骤 2/4] 训练 ANN（获取 float 权重）...")

    epochs = cfg.QUICK_EPOCHS if quick else cfg.ANN_EPOCHS
    results = {}

    for name, ds in all_datasets.items():
        if skip_train:
            # 加载已保存的权重
            try:
                model = train_ann.load_weights(name, ds["input_dim"])
                W = train_ann.get_weights(model)
                acc = train_ann.evaluate_model(model, ds["test_loader_float"])
                quant_acc = None
                if getattr(cfg, 'QAT_ENABLE', False):
                    quant_acc = train_ann.evaluate_model(
                        model, ds["test_loader_float"],
                        quantized=True,
                        weight_bits=cfg.QAT_WEIGHT_BITS,
                        noise_std=cfg.QAT_NOISE_STD if cfg.QAT_NOISE_ENABLE else 0.0,
                        ir_drop_coeff=cfg.QAT_IR_DROP_COEFF
                    )
                if quant_acc is not None:
                    print(f"  {name:20s}: loaded weights, acc={acc:.2%}, QAT={quant_acc:.2%}")
                else:
                    print(f"  {name:20s}: loaded weights, acc={acc:.2%}")
                results[name] = {"float_acc": acc, "weights": W, "quant_acc": quant_acc}
                continue
            except FileNotFoundError:
                print(f"  {name}: 未找到已保存权重，重新训练。")

        # +/-+/-
        model, history = train_ann.train_model(
            ds["train_loader"], ds["input_dim"], epochs=epochs
        )

        # QAT fine-tune (optional)
        quant_acc = None
        if getattr(cfg, 'QAT_ENABLE', False) and getattr(cfg, 'POST_QUANT_FINE_TUNE_EPOCHS', 0) > 0:
            qat_epochs = cfg.POST_QUANT_FINE_TUNE_EPOCHS
            if quick:
                qat_epochs = min(1, qat_epochs)
            qat_lr = getattr(cfg, 'QAT_LR', cfg.ANN_LR * 0.2)
            model, qat_history = train_ann.train_model(
                ds["train_loader"], ds["input_dim"],
                epochs=qat_epochs, lr=qat_lr, model=model,
                qat=True, weight_bits=cfg.QAT_WEIGHT_BITS,
                noise_std=cfg.QAT_NOISE_STD,
                ir_drop_coeff=cfg.QAT_IR_DROP_COEFF
            )
            if qat_history:
                history.extend(qat_history)

        acc = train_ann.evaluate_model(model, ds["test_loader_float"])
        if getattr(cfg, 'QAT_ENABLE', False):
            quant_acc = train_ann.evaluate_model(
                model, ds["test_loader_float"],
                quantized=True,
                weight_bits=cfg.QAT_WEIGHT_BITS,
                noise_std=cfg.QAT_NOISE_STD if cfg.QAT_NOISE_ENABLE else 0.0,
                ir_drop_coeff=cfg.QAT_IR_DROP_COEFF
            )
        W = train_ann.get_weights(model)
        train_ann.save_weights(model, name)

        if quant_acc is not None:
            print(f"  {name:20s}: loss={history[-1]:.4f}, acc={acc:.2%}, QAT={quant_acc:.2%}")
        else:
            print(f"  {name:20s}: loss={history[-1]:.4f}, acc={acc:.2%}")
        results[name] = {"float_acc": acc, "weights": W, "quant_acc": quant_acc}

    return results


# =====================================================
#  步骤 3: 参数扫描
# =====================================================

def run_parameter_sweep(all_datasets, training_results, quick=False):
    """
    核心步骤：在不同硬件参数下运行 SNN 推理，收集准确率和零脉冲统计。

    扫描维度：
        1. 降采样方法
        2. threshold ratio
        3. ADC 位宽 (6/8/10/12)
        4. 权重量化位宽 (2/3/4/6/8)
        5. 推理时步数 (1/3/5/10/20)
        6. reset_mode (soft/hard)
        7. 差分方案 (A/B)
        8. 自适应阈值（作为单独对比项）
    """
    print("\n[步骤 3/4] SNN 推理 + 参数扫描...")

    tune_split = str(getattr(cfg, "TUNE_SPLIT", "val")).lower()
    final_split = str(getattr(cfg, "FINAL_REPORT_SPLIT", "test")).lower()
    target_input_dim = int(getattr(cfg, "TARGET_INPUT_DIM_FOR_RECOMMEND", 0) or 0)
    schemes, primary_scheme = _resolve_eval_schemes()
    reset_modes = [str(mode).lower() for mode in getattr(cfg, "RESET_MODE_SWEEP", ["soft"])]
    if not reset_modes:
        reset_modes = [str(getattr(cfg, "SPIKE_RESET_MODE", "soft")).lower()]
    default_ratio = float(getattr(cfg, "SPIKE_THRESHOLD_RATIO", 0.6))
    if getattr(cfg, "FULL_GRID_INCLUDE_RATIO", False):
        full_grid_ratio_candidates = [
            float(x) for x in getattr(cfg, "FULL_GRID_RATIO_CANDIDATES", [])
        ]
    else:
        full_grid_ratio_candidates = []
    if not full_grid_ratio_candidates:
        full_grid_ratio_candidates = [
            float(x) for x in getattr(cfg, "THRESHOLD_RATIO_CANDIDATES", [])
        ]
    if not full_grid_ratio_candidates:
        full_grid_ratio_candidates = [default_ratio]
    full_grid_ratio_candidates = sorted({float(x) for x in full_grid_ratio_candidates})

    results = {
        "downsample": {},       # tuning split
        "adc_sweep": {},        # tuning split
        "weight_sweep": {},     # tuning split
        "timestep_sweep": {},   # tuning split
        "full_grid": [],        # exhaustive tuning split combinations
        "full_grid_top": [],    # top-K by tuning accuracy
        "best_case": {},        # best tuning configuration (max acc)
        "noise_impact": {},     # tuning split
        "scheme_compare": {},   # tuning split
        "decision_compare": {}, # tuning split
        "adaptive": {},         # tuning split
        "threshold_calibration": {},  # {method: {scheme: ...}}
        "meta": {
            "tune_split": tune_split,
            "final_split": final_split,
            "primary_scheme": primary_scheme,
            "schemes": schemes,
            "reset_modes": reset_modes,
            "ratio_candidates": full_grid_ratio_candidates,
            "target_input_dim": target_input_dim,
            "allow_signed_scheme_a": bool(getattr(cfg, "ALLOW_SIGNED_SCHEME_A", False)),
            "ranking_metric": "spike_only_acc",
            "ranking_secondary_metric": "zero_spike_rate",
        },
        "recommendation": {},
        "final_test": {},
        "final_test_hw_aligned": {},
        "final_test_best_case": {},
        "final_test_best_case_hw_aligned": {},
        "multi_seed": {},
    }

    eligible_methods = []
    for name, ds in all_datasets.items():
        input_dim = int(ds["input_dim"])
        if target_input_dim > 0 and input_dim != target_input_dim:
            continue
        try:
            _get_split_tensors(ds, tune_split)
        except ValueError:
            continue
        eligible_methods.append(name)

    if not eligible_methods:
        raise RuntimeError(
            f"No eligible methods for tuning split='{tune_split}' and target_input_dim={target_input_dim}"
        )

    print(
        f"  Tuning on split='{tune_split}', final report on split='{final_split}', "
        f"primary scheme={primary_scheme}, methods={len(eligible_methods)}"
    )
    print("  Recommendation objective: maximize spike_only_acc, then minimize zero_spike_rate.")
    print(f"  Ratio candidates in full-grid: {full_grid_ratio_candidates}")
    print(f"  Reset modes in full-grid: {reset_modes}")

    # ---- 3a. 验证 SNN-ANN 数学等价性（ideal, tuning split） ----
    print(f"\n  [3a] 验证 SNN 与 ANN 的数学等价性（split={tune_split}）...")
    for name in eligible_methods:
        ds = all_datasets[name]
        images_eval, labels_eval = _get_split_tensors(ds, tune_split)
        W = training_results[name]["weights"]
        ideal_acc = snn_engine.snn_inference_ideal(images_eval, labels_eval, W, timesteps=1)
        print(f"    {name:20s}: SNN(ideal)={ideal_acc:.2%}")

    # ---- 3b-0. 每种方法、每种方案分别标定阈值 ratio ----
    method_ratio = {name: {} for name in eligible_methods}
    if getattr(cfg, "CALIBRATE_THRESHOLD_RATIO", False):
        print(f"\n  [3b-0] Calibrate threshold ratio (split={tune_split}, per-method/per-scheme)...")
        for name in eligible_methods:
            ds = all_datasets[name]
            W = training_results[name]["weights"]
            results["threshold_calibration"][name] = {}
            for scheme in schemes:
                ratio, ratio_acc, ratio_candidates = calibrate_threshold_ratio(
                    ds, W, adc_bits=8, weight_bits=4, timesteps=1, scheme=scheme
                )
                if ratio is None:
                    ratio = default_ratio
                else:
                    ratio = float(ratio)
                method_ratio[name][scheme] = ratio
                results["threshold_calibration"][name][scheme] = {
                    "ratio": ratio,
                    "val_acc": ratio_acc,
                    "candidates": ratio_candidates,
                }
                if ratio_acc is None:
                    print(f"    {name:20s} [{scheme}] ratio={ratio:.2f} (fallback)")
                else:
                    print(f"    {name:20s} [{scheme}] ratio={ratio:.2f}, val_acc={ratio_acc:.2%}")
                if ratio_candidates:
                    cand_line = ", ".join(
                        f"{item['ratio']:.5f}->{item['val_acc']:.2%}" for item in ratio_candidates
                    )
                    print(f"      candidates: {cand_line}")
    else:
        for name in eligible_methods:
            for scheme in schemes:
                method_ratio[name][scheme] = default_ratio

    # ---- 3b. 方法选择（只用 tuning split） ----
    print(f"\n  [3b] 输入方式对比（split={tune_split}, scheme={primary_scheme}）...")
    for name in eligible_methods:
        ds = all_datasets[name]
        W = training_results[name]["weights"]
        images_eval, labels_eval = _get_split_tensors(ds, tune_split)
        ratio = method_ratio[name].get(primary_scheme, default_ratio)
        acc, _, stats = _run_spike_only_inference(
            images_eval, labels_eval, W,
            adc_bits=8, weight_bits=4, timesteps=1,
            scheme=primary_scheme, threshold_ratio=ratio
        )
        results["downsample"][name] = {
            "float_acc": training_results[name]["float_acc"],
            "snn_acc": acc,
            "spike_only_acc": acc,
            "zero_spike_rate": float(stats["zero_spike_rate"]),
            "zero_spike_count": int(stats["zero_spike_count"]),
            "threshold_ratio": ratio,
            "input_dim": int(ds["input_dim"]),
            "scheme": primary_scheme,
            "adc_bits": 8,
            "weight_bits": 4,
            "timesteps": 1,
        }
        print(
            f"    {name:20s}: spike_only={acc:.2%}, zero-spike={stats['zero_spike_rate']:.2%} "
            f"(ratio={ratio:.2f}, dim={int(ds['input_dim'])})"
        )

    downsample_best_method = min(
        results["downsample"], key=lambda k: _best_case_rank_key(results["downsample"][k])
    )
    downsample_best_ratio = results["downsample"][downsample_best_method]["threshold_ratio"]
    print(
        f"\n  最佳方法（基线 8/4/1, {tune_split}）: {downsample_best_method} "
        f"(spike_only={results['downsample'][downsample_best_method]['snn_acc']:.2%}, "
        f"zero-spike={results['downsample'][downsample_best_method]['zero_spike_rate']:.2%}, "
        f"ratio={downsample_best_ratio:.2f})"
    )

    # ---- 3b-1. 全量组合扫描 (method/scheme/ratio/ADC/W/T/reset) ----
    print(f"\n  [3b-1] 全量组合扫描（split={tune_split}）...")
    grid_total = (
        len(eligible_methods)
        * len(schemes)
        * len(full_grid_ratio_candidates)
        * len(cfg.ADC_BITS_SWEEP)
        * len(cfg.WEIGHT_BITS_SWEEP)
        * len(cfg.TIMESTEPS_SWEEP)
        * len(reset_modes)
    )
    grid_idx = 0
    for method_name in eligible_methods:
        ds = all_datasets[method_name]
        W = training_results[method_name]["weights"]
        images_eval, labels_eval = _get_split_tensors(ds, tune_split)
        for scheme in schemes:
            for ratio in full_grid_ratio_candidates:
                for adc_bits in cfg.ADC_BITS_SWEEP:
                    for weight_bits in cfg.WEIGHT_BITS_SWEEP:
                        for timesteps in cfg.TIMESTEPS_SWEEP:
                            for reset_mode in reset_modes:
                                acc, _, stats = _run_spike_only_inference(
                                    images_eval, labels_eval, W,
                                    adc_bits=adc_bits,
                                    weight_bits=weight_bits,
                                    timesteps=timesteps,
                                    scheme=scheme,
                                    threshold_ratio=ratio,
                                    reset_mode=reset_mode,
                                )
                                results["full_grid"].append({
                                    "method": method_name,
                                    "scheme": scheme,
                                    "reset_mode": str(reset_mode),
                                    "threshold_ratio": float(ratio),
                                    "adc_bits": int(adc_bits),
                                    "weight_bits": int(weight_bits),
                                    "timesteps": int(timesteps),
                                    "snn_acc": float(acc),
                                    "spike_only_acc": float(acc),
                                    "zero_spike_rate": float(stats["zero_spike_rate"]),
                                    "zero_spike_count": int(stats["zero_spike_count"]),
                                })
                                grid_idx += 1
                                progress_bar(grid_idx, grid_total, prefix="全量组合")

    if not results["full_grid"]:
        raise RuntimeError("full-grid sweep produced no records")

    best_case = min(results["full_grid"], key=_best_case_rank_key)
    margin = float(getattr(cfg, "RECOMMEND_ACC_MARGIN", 0.005))
    zero_spike_max = float(getattr(cfg, "RECOMMEND_ZERO_SPIKE_MAX", 1.0))
    acc_floor = float(best_case["spike_only_acc"]) - margin
    near_best = [x for x in results["full_grid"] if float(x["spike_only_acc"]) >= acc_floor]
    if not near_best:
        near_best = [best_case]
    zero_spike_filtered = [
        x for x in near_best if float(x.get("zero_spike_rate", 1.0)) <= zero_spike_max
    ]
    recommendation_pool = zero_spike_filtered or near_best
    recommendation = min(recommendation_pool, key=lambda x: _combo_cost_key(x, primary_scheme))

    topk_n = int(getattr(cfg, "SUMMARY_TOPK_COMBOS", 10))
    results["full_grid_top"] = sorted(
        results["full_grid"], key=_best_case_rank_key
    )[:max(1, topk_n)]
    results["best_case"] = dict(best_case)
    results["recommendation"] = dict(recommendation)
    results["meta"]["recommend_margin"] = margin
    results["meta"]["recommend_zero_spike_max"] = zero_spike_max
    results["meta"]["full_grid_total"] = len(results["full_grid"])
    results["meta"]["downsample_best_method"] = downsample_best_method

    print(
        f"    最优(best-case): method={best_case['method']}, scheme={best_case['scheme']}, "
        f"reset={best_case['reset_mode']}, ADC={best_case['adc_bits']}, "
        f"W={best_case['weight_bits']}, T={best_case['timesteps']}, "
        f"ratio={best_case['threshold_ratio']:.2f}, spike_only={best_case['spike_only_acc']:.2%}, "
        f"zero-spike={best_case['zero_spike_rate']:.2%}"
    )
    print(
        f"    推荐 (within {margin:.2%}, zero-spike <= {zero_spike_max:.2%} preferred): "
        f"method={recommendation['method']}, scheme={recommendation['scheme']}, "
        f"reset={recommendation['reset_mode']}, ADC={recommendation['adc_bits']}, "
        f"W={recommendation['weight_bits']}, T={recommendation['timesteps']}, "
        f"ratio={recommendation['threshold_ratio']:.2f}, spike_only={recommendation['spike_only_acc']:.2%}, "
        f"zero-spike={recommendation['zero_spike_rate']:.2%}"
    )

    # 后续单维扫描图表固定在推荐方法上，便于解释趋势
    best_method = recommendation["method"]
    best_ratio = recommendation["threshold_ratio"]
    best_scheme = str(recommendation["scheme"]).upper()
    best_reset_mode = str(recommendation["reset_mode"]).lower()
    best_ds = all_datasets[best_method]
    best_W = training_results[best_method]["weights"]
    best_images_tune, best_labels_tune = _get_split_tensors(best_ds, tune_split)

    # ---- 3c. ADC sweep (tuning split) ----
    print(f"\n  [3c] ADC 位宽扫描（split={tune_split}, {best_method}）...")
    for adc in cfg.ADC_BITS_SWEEP:
        acc, _, _ = _run_spike_only_inference(
            best_images_tune, best_labels_tune, best_W,
            adc_bits=adc, weight_bits=4, timesteps=1,
            scheme=best_scheme, threshold_ratio=best_ratio, reset_mode=best_reset_mode
        )
        results["adc_sweep"][adc] = acc
        print(f"    ADC={adc:2d}-bit: {acc:.2%}")

    # ---- 3d. Weight sweep (tuning split) ----
    print(f"\n  [3d] 权重量化位宽扫描（split={tune_split}, {best_method}）...")
    for wb in cfg.WEIGHT_BITS_SWEEP:
        acc, _, _ = _run_spike_only_inference(
            best_images_tune, best_labels_tune, best_W,
            adc_bits=8, weight_bits=wb, timesteps=1,
            scheme=best_scheme, threshold_ratio=best_ratio, reset_mode=best_reset_mode
        )
        results["weight_sweep"][wb] = acc
        print(f"    W={wb}-bit: {acc:.2%}")

    # ---- 3e. Timestep sweep (tuning split) ----
    print(f"\n  [3e] 推理时步数扫描（split={tune_split}, {best_method}）...")
    for ts in cfg.TIMESTEPS_SWEEP:
        acc, _, _ = _run_spike_only_inference(
            best_images_tune, best_labels_tune, best_W,
            adc_bits=8, weight_bits=4, timesteps=ts,
            scheme=best_scheme, threshold_ratio=best_ratio, reset_mode=best_reset_mode
        )
        results["timestep_sweep"][ts] = acc
        print(f"    T={ts:2d}: {acc:.2%}")

    # ---- 3f. 器件非理想性影响 (tuning split) ----
    print(f"\n  [3f] 器件非理想性影响（split={tune_split}, {best_method}）...")
    n_trials = cfg.NOISE_TRIALS_QUICK if quick else cfg.NOISE_TRIALS_FULL
    noise_accs = []
    for trial in range(n_trials):
        acc, _, _ = _run_spike_only_inference(
            best_images_tune, best_labels_tune, best_W,
            adc_bits=8, weight_bits=4, timesteps=1, add_noise=True,
            scheme=best_scheme, threshold_ratio=best_ratio, reset_mode=best_reset_mode
        )
        noise_accs.append(acc)
        progress_bar(trial + 1, n_trials, prefix="噪声实验")

    ideal_acc = results["adc_sweep"].get(8, 0.0)
    noise_mean = float(np.mean(noise_accs))
    noise_std = float(np.std(noise_accs))
    results["noise_impact"] = {
        "ideal": ideal_acc,
        "noisy_mean": noise_mean,
        "noisy_std": noise_std,
        "degradation": ideal_acc - noise_mean,
        "split": tune_split,
    }
    print(f"    理想:   {ideal_acc:.2%}")
    print(f"    有噪声: {noise_mean:.2%} +/- {noise_std:.4f}")
    print(f"    退化:   {results['noise_impact']['degradation']:.2%}")

    # ---- 3g. 差分方案对比 (tuning split, per-scheme ratio) ----
    print(f"\n  [3g] 差分方案对比（split={tune_split}, {best_method}）...")
    for scheme in schemes:
        ratio = method_ratio[best_method].get(scheme, default_ratio)
        acc, _, _ = _run_spike_only_inference(
            best_images_tune, best_labels_tune, best_W,
            adc_bits=8, weight_bits=4, timesteps=1,
            scheme=scheme, threshold_ratio=ratio, reset_mode=best_reset_mode
        )
        results["scheme_compare"][scheme] = acc
        print(f"    方案 {scheme}: {acc:.2%} (ratio={ratio:.2f})")

    # ---- 3h. 决策规则对比 (tuning split) ----
    print(f"\n  [3h] 决策规则对比（split={tune_split}, {best_method}）...")
    for decision in ["spike", "membrane"]:
        if decision == "spike":
            acc, _, _ = _run_spike_only_inference(
                best_images_tune, best_labels_tune, best_W,
                adc_bits=8, weight_bits=4, timesteps=1,
                scheme=best_scheme, threshold_ratio=best_ratio, reset_mode=best_reset_mode
            )
        else:
            acc, _ = snn_engine.snn_inference(
                best_images_tune, best_labels_tune, best_W,
                adc_bits=8, weight_bits=4, timesteps=1, decision=decision,
                scheme=best_scheme, threshold_ratio=best_ratio, reset_mode=best_reset_mode
            )
        results["decision_compare"][decision] = acc
        print(f"    decision={decision:8s}: {acc:.2%}")

    # ---- 3i. 自适应阈值对比 (tuning split) ----
    print(f"\n  [3i] 自适应阈值对比（split={tune_split}, {best_method}）...")
    fixed_acc, _, _ = _run_spike_only_inference(
        best_images_tune, best_labels_tune, best_W,
        adc_bits=8, weight_bits=4, timesteps=10,
        scheme=best_scheme, threshold_ratio=best_ratio, reset_mode=best_reset_mode
    )
    adaptive_acc, _ = snn_engine.snn_inference_adaptive_threshold(
        best_images_tune, best_labels_tune, best_W,
        adc_bits=8, weight_bits=4, timesteps=10,
        scheme=best_scheme, add_noise=False, reset_mode=best_reset_mode
    )
    results["adaptive"] = {
        "fixed": fixed_acc,
        "adaptive": adaptive_acc,
        "improvement": adaptive_acc - fixed_acc,
        "split": tune_split,
    }
    print(f"    固定阈值(spike):   {fixed_acc:.2%}")
    print(f"    自适应阈值(spike): {adaptive_acc:.2%}")
    print(f"    提升: {results['adaptive']['improvement']:+.2%}")

    # ---- 3j. 基于 tuning split 生成推荐配置 ----
    rec_cfg = dict(results.get("recommendation", {}))
    if not rec_cfg:
        raise RuntimeError("recommendation is missing after full-grid sweep")
    rec_cfg["based_on_split"] = tune_split
    results["recommendation"] = rec_cfg
    best_method = rec_cfg["method"]
    best_ratio = float(rec_cfg["threshold_ratio"])
    best_adc = int(rec_cfg["adc_bits"])
    best_wb = int(rec_cfg["weight_bits"])
    best_ts = int(rec_cfg["timesteps"])
    primary_scheme = str(rec_cfg["scheme"]).upper()
    best_reset_mode = str(rec_cfg["reset_mode"]).lower()
    print(
        f"\n  推荐配置（基于 {tune_split}）: "
        f"method={best_method}, scheme={primary_scheme}, "
        f"reset={best_reset_mode}, ADC={best_adc}, W={best_wb}, T={best_ts}, ratio={best_ratio:.2f}"
    )

    # ---- 3k. 仅一次 final split 评估 ----
    final_images, final_labels = _get_split_tensors(best_ds, final_split)
    final_acc, _, final_stats = _run_spike_only_inference(
        final_images, final_labels, best_W,
        adc_bits=best_adc, weight_bits=best_wb, timesteps=best_ts,
        scheme=primary_scheme, threshold_ratio=best_ratio, reset_mode=best_reset_mode,
    )
    results["final_test"] = {
        "split": final_split,
        "method": best_method,
        "scheme": primary_scheme,
        "reset_mode": best_reset_mode,
        "threshold_ratio": best_ratio,
        "adc_bits": int(best_adc),
        "weight_bits": int(best_wb),
        "timesteps": int(best_ts),
        "snn_acc": final_acc,
        "spike_only_acc": float(final_stats["spike_only_acc"]),
        "zero_spike_rate": float(final_stats.get("zero_spike_rate", 0.0)),
        "zero_spike_count": int(final_stats.get("zero_spike_count", 0)),
        "decision_mode": str(final_stats.get("decision_mode", "spike_only_no_fallback")),
    }
    results["final_test_hw_aligned"] = dict(results["final_test"])
    print(
        f"  Final {final_split} 硬件对齐口径(spike-only): "
        f"{final_acc:.2%} (zero-spike={float(final_stats.get('zero_spike_rate', 0.0)):.2%})"
    )

    best_case_cfg = dict(results.get("best_case", {}))
    if best_case_cfg:
        best_case_method = best_case_cfg["method"]
        best_case_ds = all_datasets[best_case_method]
        best_case_W = training_results[best_case_method]["weights"]
        best_case_images, best_case_labels = _get_split_tensors(best_case_ds, final_split)
        best_case_final_acc, _, best_case_final_stats = _run_spike_only_inference(
            best_case_images, best_case_labels, best_case_W,
            adc_bits=int(best_case_cfg["adc_bits"]),
            weight_bits=int(best_case_cfg["weight_bits"]),
            timesteps=int(best_case_cfg["timesteps"]),
            scheme=str(best_case_cfg["scheme"]).upper(),
            threshold_ratio=float(best_case_cfg["threshold_ratio"]),
            reset_mode=str(best_case_cfg["reset_mode"]).lower(),
        )
        results["final_test_best_case"] = {
            "split": final_split,
            "method": best_case_method,
            "scheme": str(best_case_cfg["scheme"]).upper(),
            "reset_mode": str(best_case_cfg["reset_mode"]).lower(),
            "threshold_ratio": float(best_case_cfg["threshold_ratio"]),
            "adc_bits": int(best_case_cfg["adc_bits"]),
            "weight_bits": int(best_case_cfg["weight_bits"]),
            "timesteps": int(best_case_cfg["timesteps"]),
            "snn_acc": float(best_case_final_acc),
            "spike_only_acc": float(best_case_final_stats["spike_only_acc"]),
            "zero_spike_rate": float(best_case_final_stats.get("zero_spike_rate", 0.0)),
            "zero_spike_count": int(best_case_final_stats.get("zero_spike_count", 0)),
            "decision_mode": str(best_case_final_stats.get("decision_mode", "spike_only_no_fallback")),
        }
        results["final_test_best_case_hw_aligned"] = dict(results["final_test_best_case"])
        print(
            f"  Final {final_split} best-case 硬件对齐口径(spike-only): "
            f"{float(best_case_final_stats['spike_only_acc']):.2%} "
            f"(zero-spike={float(best_case_final_stats.get('zero_spike_rate', 0.0)):.2%})"
        )

    # ---- 3l. 固定配置多 seed 复跑（推理侧） ----
    seed_list = [int(s) for s in getattr(cfg, "FINAL_MULTI_SEEDS", [])]
    if seed_list:
        clean_accs = []
        noisy_accs = []
        print(f"\n  [3l] 固定配置多 seed 复跑（{len(seed_list)} seeds）...")
        for seed in seed_list:
            set_global_seed(seed)
            clean_acc, _, _ = _run_spike_only_inference(
                final_images, final_labels, best_W,
                adc_bits=best_adc, weight_bits=best_wb, timesteps=best_ts,
                scheme=primary_scheme, threshold_ratio=best_ratio, reset_mode=best_reset_mode
            )
            noisy_acc, _, _ = _run_spike_only_inference(
                final_images, final_labels, best_W,
                adc_bits=best_adc, weight_bits=best_wb, timesteps=best_ts,
                scheme=primary_scheme, threshold_ratio=best_ratio,
                reset_mode=best_reset_mode, add_noise=True
            )
            clean_accs.append(clean_acc)
            noisy_accs.append(noisy_acc)
            print(f"    seed={seed}: clean={clean_acc:.2%}, noisy={noisy_acc:.2%}")
        # Restore configured seed for any follow-up routines.
        set_global_seed(cfg.RANDOM_SEED)
        results["multi_seed"] = {
            "seeds": seed_list,
            "clean_mean": float(np.mean(clean_accs)),
            "clean_std": float(np.std(clean_accs)),
            "noisy_mean": float(np.mean(noisy_accs)),
            "noisy_std": float(np.std(noisy_accs)),
            "split": final_split,
        }

    results["device_backend"] = snn_engine.get_device_backend_status()
    return results, best_method


# =====================================================
#  步骤 4: 生成图表 + 输出推荐
# =====================================================

def generate_plots(results, training_results, best_method):
    """Generate all result figures."""
    print("\n[步骤 4/4] 生成结果图表...")
    os.makedirs(cfg.RESULTS_DIR, exist_ok=True)

    has_chinese = setup_chinese_font()

    # ---- 图1: 输入方式对比 ----
    fig, ax = plt.subplots(figsize=(10, 5))
    methods = list(results["downsample"].keys())
    float_accs = [results["downsample"][m]["float_acc"] for m in methods]
    snn_accs = [results["downsample"][m]["snn_acc"] for m in methods]
    x = np.arange(len(methods))
    ax.bar(x - 0.2, [a * 100 for a in float_accs], 0.35,
           label='ANN (float)', color='steelblue')
    ax.bar(x + 0.2, [a * 100 for a in snn_accs], 0.35,
           label='SNN (4-bit, ADC=8)', color='coral')
    ax.set_ylabel('Accuracy (%)')
    ax.set_title('Downsample Method Comparison')
    ax.set_xticks(x)
    ax.set_xticklabels(methods, rotation=30, ha='right')
    ax.legend()
    ax.grid(axis='y', alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(cfg.RESULTS_DIR, 'fig1_downsample_comparison.png'),
                dpi=150)
    plt.close()
    print("  fig1_downsample_comparison.png")

    # ---- 图2: ADC 位宽 ----
    fig, ax = plt.subplots(figsize=(8, 5))
    adc_bits = sorted(results["adc_sweep"].keys())
    adc_accs = [results["adc_sweep"][b] * 100 for b in adc_bits]
    ax.plot(adc_bits, adc_accs, 'o-', color='steelblue', linewidth=2,
            markersize=8)
    float_baseline = training_results[best_method]["float_acc"] * 100
    ax.axhline(y=float_baseline, color='red', linestyle='--',
               label=f'ANN float baseline ({float_baseline:.1f}%)')
    ax.set_xlabel('ADC Bits')
    ax.set_ylabel('SNN Accuracy (%)')
    ax.set_title(f'ADC Bit Width vs Accuracy ({best_method})')
    ax.set_xticks(adc_bits)
    ax.legend()
    ax.grid(alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(cfg.RESULTS_DIR, 'fig2_adc_bits_sweep.png'),
                dpi=150)
    plt.close()
    print("  fig2_adc_bits_sweep.png")

    # ---- 图3: 权重量化位宽 ----
    fig, ax = plt.subplots(figsize=(8, 5))
    w_bits = sorted(results["weight_sweep"].keys())
    w_accs = [results["weight_sweep"][b] * 100 for b in w_bits]
    ax.plot(w_bits, w_accs, 's-', color='forestgreen', linewidth=2,
            markersize=8)
    ax.axhline(y=float_baseline, color='red', linestyle='--',
               label=f'ANN float baseline ({float_baseline:.1f}%)')
    ax.set_xlabel('Weight Bits')
    ax.set_ylabel('SNN Accuracy (%)')
    ax.set_title(f'Weight Quantization vs Accuracy ({best_method})')
    ax.set_xticks(w_bits)
    ax.legend()
    ax.grid(alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(cfg.RESULTS_DIR, 'fig3_weight_bits_sweep.png'),
                dpi=150)
    plt.close()
    print("  fig3_weight_bits_sweep.png")

    # ---- 图4: 推理时步数 ----
    fig, ax = plt.subplots(figsize=(8, 5))
    ts_list = sorted(results["timestep_sweep"].keys())
    ts_accs = [results["timestep_sweep"][t] * 100 for t in ts_list]
    ax.plot(ts_list, ts_accs, 'D-', color='darkorange', linewidth=2,
            markersize=8)
    ax.axhline(y=float_baseline, color='red', linestyle='--',
               label=f'ANN float baseline ({float_baseline:.1f}%)')
    ax.set_xlabel('Timesteps (frames)')
    ax.set_ylabel('SNN Accuracy (%)')
    ax.set_title(f'Inference Timesteps vs Accuracy ({best_method})')
    ax.set_xticks(ts_list)
    ax.legend()
    ax.grid(alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(cfg.RESULTS_DIR, 'fig4_timesteps_sweep.png'),
                dpi=150)
    plt.close()
    print("  fig4_timesteps_sweep.png")

    # ---- 图5: 器件非理想性影响 ----
    fig, ax = plt.subplots(figsize=(6, 5))
    labels = ['Ideal', 'With Device\nNon-ideality']
    vals = [results["noise_impact"]["ideal"] * 100,
            results["noise_impact"]["noisy_mean"] * 100]
    err = [0, results["noise_impact"]["noisy_std"] * 100]
    bars = ax.bar(labels, vals, yerr=err, capsize=10,
                  color=['steelblue', 'coral'])
    ax.set_ylabel('Accuracy (%)')
    ax.set_title('Impact of Device Non-ideality')
    for bar, val in zip(bars, vals):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.5,
                f'{val:.1f}%', ha='center')
    ax.grid(axis='y', alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(cfg.RESULTS_DIR, 'fig5_noise_impact.png'),
                dpi=150)
    plt.close()
    print("  fig5_noise_impact.png")

    # ---- 图6: 差分方案 ----
    fig, ax = plt.subplots(figsize=(6, 5))
    scheme_items = sorted(results["scheme_compare"].items(), key=lambda kv: kv[0])
    labels = [f"Scheme {k}" for k, _ in scheme_items]
    vals = [v * 100 for _, v in scheme_items]
    bars = ax.bar(labels, vals, color=['steelblue', 'coral'])
    ax.set_ylabel('Accuracy (%)')
    ax.set_title('Differential Scheme Comparison')
    for bar, val in zip(bars, vals):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.5,
                f'{val:.1f}%', ha='center')
    ax.grid(axis='y', alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(cfg.RESULTS_DIR, 'fig6_scheme_comparison.png'),
                dpi=150)
    plt.close()
    print("  fig6_scheme_comparison.png")

    # ---- 图7: 自适应阈值 ----
    fig, ax = plt.subplots(figsize=(6, 5))
    labels = ['Fixed Threshold\n(spike)', 'Adaptive\nThreshold']
    vals = [results["adaptive"]["fixed"] * 100,
            results["adaptive"]["adaptive"] * 100]
    bars = ax.bar(labels, vals, color=['steelblue', 'coral'])
    ax.set_ylabel('Accuracy (%)')
    ax.set_title(f'Adaptive Threshold (T={10})')
    for bar, val in zip(bars, vals):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.5,
                f'{val:.1f}%', ha='center')
    ax.grid(axis='y', alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(cfg.RESULTS_DIR, 'fig7_adaptive_threshold.png'),
                dpi=150)
    plt.close()
    print("  fig7_adaptive_threshold.png")


def generate_summary(results, training_results, best_method, all_datasets):
    """Generate summary and recommendation text."""
    meta = results.get("meta", {})
    rec = results.get("recommendation", {})
    best_case = results.get("best_case", {})
    final = results.get("final_test", {})
    final_hw = results.get("final_test_hw_aligned", {})
    final_best = results.get("final_test_best_case", {})
    final_best_hw = results.get("final_test_best_case_hw_aligned", {})
    backend = results.get("device_backend", {})
    top_grid = results.get("full_grid_top", [])
    weight_exports = results.get("weight_exports", {})

    lines = []
    lines.append("=" * 60)
    lines.append("  SNN SoC 建模结果 - 参数推荐")
    lines.append("=" * 60)
    lines.append(
        f"\n评估口径: tuning_split={meta.get('tune_split', 'val')}（用于选方法和调参），"
        f"final_split={meta.get('final_split', 'test')}（用于最终一次性报告）"
    )
    lines.append(
        f"全量组合扫描数: {meta.get('full_grid_total', 0)}, "
        f"推荐精度容忍边界: {meta.get('recommend_margin', 0.0):.2%}, "
        f"零脉冲偏好上限: {meta.get('recommend_zero_spike_max', 1.0):.2%}"
    )

    best_downsample = results.get("downsample", {}).get(best_method, {})
    lines.append(f"\n最佳输入方式(8/4/1 基线): {best_method}")
    if best_downsample:
        lines.append(
            f"  tuning spike-only: {best_downsample.get('spike_only_acc', best_downsample.get('snn_acc', 0.0)):.2%} "
            f"(zero-spike={best_downsample.get('zero_spike_rate', 0.0):.2%}, "
            f"ratio={best_downsample.get('threshold_ratio', 0.0):.2f}, "
            f"scheme={best_downsample.get('scheme', meta.get('primary_scheme', 'B'))})"
        )
    lines.append(f"  ANN float 基线准确率(test): {training_results[best_method]['float_acc']:.2%}")
    quant_acc = training_results[best_method].get("quant_acc")
    if quant_acc is not None:
        lines.append(f"  ANN quantized 基线准确率(test): {quant_acc:.2%}")

    if best_case:
        lines.append("\nbest-case（全量网格最高纯 spike 精度）:")
        lines.append(
            f"  method={best_case.get('method')}, scheme={best_case.get('scheme')}, "
            f"reset={best_case.get('reset_mode')}, ADC={best_case.get('adc_bits')}, W={best_case.get('weight_bits')}, "
            f"T={best_case.get('timesteps')}, ratio={best_case.get('threshold_ratio', 0.0):.2f}, "
            f"spike_only={best_case.get('spike_only_acc', best_case.get('snn_acc', 0.0)):.2%}, "
            f"zero-spike={best_case.get('zero_spike_rate', 0.0):.2%}"
        )

    if rec:
        lines.append("\nrecommendation（先保 spike_only_acc，再压低 zero_spike_rate 与成本）:")
        lines.append(
            f"  method={rec.get('method')}, scheme={rec.get('scheme')}, "
            f"reset={rec.get('reset_mode')}, ADC={rec.get('adc_bits')}, W={rec.get('weight_bits')}, "
            f"T={rec.get('timesteps')}, ratio={rec.get('threshold_ratio', 0.0):.2f}, "
            f"tuning_spike_only={rec.get('spike_only_acc', rec.get('snn_acc', 0.0)):.2%}, "
            f"zero-spike={rec.get('zero_spike_rate', 0.0):.2%}"
        )

    if final:
        lines.append(
            f"\nFinal {final.get('split', 'test')} (recommendation): "
            f"{final.get('snn_acc', 0.0):.2%}"
        )
    if final_hw:
        lines.append(
            f"  Hardware-aligned (spike-only, no fallback): "
            f"{final_hw.get('snn_acc', 0.0):.2%} "
            f"(zero-spike={final_hw.get('zero_spike_rate', 0.0):.2%}, "
            f"count={int(final_hw.get('zero_spike_count', 0))})"
        )
    if final_best:
        lines.append(
            f"Final {final_best.get('split', 'test')} (best-case): "
            f"{final_best.get('snn_acc', 0.0):.2%}"
        )
    if final_best_hw:
        lines.append(
            f"  Hardware-aligned best-case (spike-only, no fallback): "
            f"{final_best_hw.get('snn_acc', 0.0):.2%} "
            f"(zero-spike={final_best_hw.get('zero_spike_rate', 0.0):.2%}, "
            f"count={int(final_best_hw.get('zero_spike_count', 0))})"
        )

    if top_grid:
        lines.append("\nTop full-grid combinations:")
        for i, item in enumerate(top_grid, start=1):
            lines.append(
                f"  #{i:02d}: method={item.get('method')}, scheme={item.get('scheme')}, "
                f"reset={item.get('reset_mode')}, ADC={item.get('adc_bits')}, W={item.get('weight_bits')}, "
                f"T={item.get('timesteps')}, ratio={item.get('threshold_ratio', 0.0):.2f}, "
                f"spike_only={item.get('spike_only_acc', item.get('snn_acc', 0.0)):.2%}, "
                f"zero-spike={item.get('zero_spike_rate', 0.0):.2%}"
            )

    if results.get("threshold_calibration"):
        lines.append("\n各方法阈值 ratio 标定结果（按 scheme 区分）:")
        for name in sorted(results["threshold_calibration"].keys()):
            sch_map = results["threshold_calibration"][name]
            for scheme in sorted(sch_map.keys()):
                item = sch_map[scheme]
                ratio = item.get("ratio")
                val_acc = item.get("val_acc")
                if val_acc is None:
                    lines.append(f"  {name:20s}[{scheme}] ratio={ratio:.2f} (fallback)")
                else:
                    lines.append(f"  {name:20s}[{scheme}] ratio={ratio:.2f}, val_acc={val_acc:.2%}")
                cand_items = item.get("candidates") or []
                if cand_items:
                    cand_line = ", ".join(
                        f"{c.get('ratio', 0.0):.5f}->{c.get('val_acc', 0.0):.2%}" for c in cand_items
                    )
                    lines.append(f"    候选: {cand_line}")

    adc_sorted = sorted(results["adc_sweep"].items())
    lines.append(f"\nADC 扫描 ({meta.get('tune_split', 'val')}):")
    for bits, acc in adc_sorted:
        marker = " <- 推荐" if bits == rec.get("adc_bits") else ""
        lines.append(f"  {bits:2d}-bit: {acc:.2%}{marker}")

    w_sorted = sorted(results["weight_sweep"].items())
    lines.append(f"\n权重量化位宽扫描 ({meta.get('tune_split', 'val')}):")
    for bits, acc in w_sorted:
        marker = " <- 推荐" if bits == rec.get("weight_bits") else ""
        lines.append(f"  {bits}-bit: {acc:.2%}{marker}")

    ts_sorted = sorted(results["timestep_sweep"].items())
    lines.append(f"\n时步扫描 ({meta.get('tune_split', 'val')}):")
    for ts, acc in ts_sorted:
        marker = " <- 推荐" if ts == rec.get("timesteps") else ""
        lines.append(f"  T={ts:2d}: {acc:.2%}{marker}")

    ni = results["noise_impact"]
    lines.append(f"\n器件非理想性影响 ({ni.get('split', meta.get('tune_split', 'val'))}):")
    lines.append(f"  理想准确率:      {ni['ideal']:.2%}")
    lines.append(f"  有噪声准确率:    {ni['noisy_mean']:.2%} +/- {ni['noisy_std']:.4f}")
    lines.append(f"  准确率退化:      {ni['degradation']:.2%}")

    sc = results.get("scheme_compare", {})
    if sc:
        lines.append(f"\n差分方案对比 ({meta.get('tune_split', 'val')}):")
        for scheme, acc in sorted(sc.items(), key=lambda kv: kv[0]):
            marker = " <- 推荐" if scheme == rec.get("scheme") else ""
            lines.append(f"  方案 {scheme}: {acc:.2%}{marker}")

    dc = results.get("decision_compare", {})
    if dc:
        lines.append(f"\n决策规则对比 ({meta.get('tune_split', 'val')}):")
        for decision in ["spike", "membrane"]:
            if decision in dc:
                lines.append(f"  {decision:8s}: {dc[decision]:.2%}")

    ad = results["adaptive"]
    do_adaptive = ad["improvement"] >= 0.01
    lines.append(f"\n自适应阈值对比 ({ad.get('split', meta.get('tune_split', 'val'))}):")
    lines.append(f"  固定阈值(spike): {ad['fixed']:.2%}")
    lines.append(f"  自适应阈值:      {ad['adaptive']:.2%}")
    lines.append(f"  提升:            {ad['improvement']:+.2%}")
    lines.append(f"  结论: {'recommended' if do_adaptive else 'not recommended'}")

    ms = results.get("multi_seed", {})
    if ms:
        lines.append(f"\n固定配置多 seed 复跑 ({ms.get('split', meta.get('final_split', 'test'))}):")
        lines.append(f"  seeds: {ms.get('seeds')}")
        lines.append(f"  clean: {ms.get('clean_mean', 0.0):.2%} +/- {ms.get('clean_std', 0.0):.4f}")
        lines.append(f"  noisy: {ms.get('noisy_mean', 0.0):.2%} +/- {ms.get('noisy_std', 0.0):.4f}")

    if backend:
        lines.append("\nDevice backend:")
        lines.append(f"  use_device_model={backend.get('use_device_model')}")
        lines.append(f"  plugin_path_exists={backend.get('plugin_path_exists')}")
        lines.append(f"  plugin_levels_loaded={backend.get('plugin_levels_loaded')}")
        lines.append(f"  plugin_sim_available={backend.get('plugin_sim_available')}")
        if backend.get("backend_mode"):
            lines.append(f"  backend_mode={backend.get('backend_mode')}")
        notes = backend.get("runtime_notes") or []
        for note in notes:
            lines.append(f"  note: {note}")
    if weight_exports:
        lines.append("\nWeight export:")
        lines.append(f"  enabled={weight_exports.get('enabled')}")
        lines.append(f"  hex_enabled={weight_exports.get('hex_enabled')}")
        if weight_exports.get("manifest_path"):
            lines.append(f"  manifest={weight_exports.get('manifest_path')}")
        for item in weight_exports.get("artifacts", []):
            lines.append(
                f"  {item.get('label')}: {item.get('csv_path')} "
                f"(method={item.get('method')}, scheme={item.get('scheme')}, reset={item.get('reset_mode')}, "
                f"ADC={item.get('adc_bits')}, W={item.get('weight_bits')}, T={item.get('timesteps')})"
            )
            if item.get("pos_hex_path") and item.get("neg_hex_path"):
                lines.append(f"    HEX(pos)={item.get('pos_hex_path')}")
                lines.append(f"    HEX(neg)={item.get('neg_hex_path')}")
            if item.get("staged_pos_hex_path") and item.get("staged_neg_hex_path"):
                lines.append(f"    staged_pos={item.get('staged_pos_hex_path')}")
                lines.append(f"    staged_neg={item.get('staged_neg_hex_path')}")
        for warning in weight_exports.get("warnings", []):
            lines.append(f"  warning: {warning}")
    if final_hw:
        lines.append("\n注：Hardware-aligned 口径禁用“零脉冲时回退到 membrane”兜底，用于与当前 RTL 输出能力对齐。")

    lines.append(f"\n{'=' * 60}")
    lines.append("  RTL 参数推荐（用于更新 snn_soc_pkg.sv）")
    lines.append(f"{'=' * 60}")
    rec_method = rec.get("method", best_method)
    input_dim = int(all_datasets[rec_method]["input_dim"])
    lines.append(f"  NUM_INPUTS  = {input_dim}")
    lines.append("  NUM_OUTPUTS = 10")
    lines.append(f"  ADC_BITS    = {rec.get('adc_bits')}")
    lines.append("  PIXEL_BITS  = 8")
    lines.append(f"  // WEIGHT_BITS = {rec.get('weight_bits')} (device-side parameter)")
    lines.append(f"  // SCHEME = {rec.get('scheme')}")
    lines.append(f"  // RESET_MODE = {rec.get('reset_mode', 'soft')}")
    lines.append(f"  // THRESHOLD_RATIO = {rec.get('threshold_ratio', 0.0):.5f}")
    lines.append(f"  // ADAPTIVE_THRESHOLD = {'ON' if do_adaptive else 'OFF'}")
    if meta.get("target_input_dim", 0) > 0 and input_dim != int(meta["target_input_dim"]):
        lines.append(
            f"  // WARNING: recommended dim ({input_dim}) != target_input_dim ({meta['target_input_dim']})"
        )

    summary_text = "\n".join(lines)
    summary_path = os.path.join(cfg.RESULTS_DIR, "summary.txt")
    with open(summary_path, 'w', encoding='utf-8') as f:
        f.write(summary_text)

    print(f"\n{summary_text}")
    print(f"\n结果已保存到: {cfg.RESULTS_DIR}")


def _artifact_tag(value):
    """Convert config fields into stable filename-safe fragments."""
    text = str(value)
    keep = []
    for ch in text:
        if ch.isalnum() or ch in ("-", "_", "."):
            keep.append(ch)
        else:
            keep.append("_")
    return "".join(keep).strip("_") or "na"


def export_weight_artifacts(results):
    """
    Export weight maps for the recommendation and best-case configurations.

    The export format reuses export_weight_map.py and writes CSV artifacts under
    results/exports/ by default. Failures are recorded as warnings and do not
    abort the modeling run.
    """
    export_info = {
        "enabled": bool(getattr(cfg, "AUTO_EXPORT_WEIGHT_MAP", False)),
        "hex_enabled": bool(getattr(cfg, "AUTO_EXPORT_WEIGHT_HEX", False)),
        "artifacts": [],
        "warnings": [],
    }
    if not export_info["enabled"]:
        return export_info

    export_dir = os.path.join(
        cfg.RESULTS_DIR,
        str(getattr(cfg, "WEIGHT_EXPORT_SUBDIR", "exports")),
    )
    col_map = str(getattr(cfg, "WEIGHT_EXPORT_COL_MAP", "grouped")).lower()
    os.makedirs(export_dir, exist_ok=True)

    targets = []
    recommendation = results.get("recommendation") or {}
    best_case = results.get("best_case") or {}
    if recommendation:
        targets.append(("recommendation", recommendation))
    if best_case:
        targets.append(("best_case", best_case))

    if not targets:
        export_info["warnings"].append("No recommendation/best-case configuration available for export.")
        return export_info

    for label, item in targets:
        method = str(item.get("method", "")).strip()
        if not method:
            export_info["warnings"].append(f"{label}: missing method, skipped export.")
            continue

        try:
            weight_bits = int(item.get("weight_bits", 4))
            scheme = _artifact_tag(item.get("scheme", "na"))
            reset_mode = _artifact_tag(item.get("reset_mode", cfg.SPIKE_RESET_MODE))
            adc_bits = int(item.get("adc_bits", 8))
            timesteps = int(item.get("timesteps", 1))
            ratio = float(item.get("threshold_ratio", getattr(cfg, "SPIKE_THRESHOLD_RATIO", 0.0)))
            ratio_tag = f"{ratio:.5f}".replace(".", "p")
            out_csv = os.path.join(
                export_dir,
                f"{label}_{method}_scheme{scheme}_reset{reset_mode}_adc{adc_bits}_w{weight_bits}_t{timesteps}_r{ratio_tag}.csv",
            )
            export_weight_map.export_weight_map(
                method=method,
                weight_bits=weight_bits,
                out_csv=out_csv,
                weights_dir=cfg.WEIGHTS_DIR,
                col_map=col_map,
            )
            artifact = {
                "label": label,
                "method": method,
                "scheme": str(item.get("scheme", "")),
                "reset_mode": str(item.get("reset_mode", cfg.SPIKE_RESET_MODE)),
                "adc_bits": adc_bits,
                "weight_bits": weight_bits,
                "timesteps": timesteps,
                "threshold_ratio": ratio,
                "col_map": col_map,
                "weights_dir": cfg.WEIGHTS_DIR,
                "csv_path": out_csv,
            }

            require_4bit = bool(getattr(cfg, "WEIGHT_HEX_REQUIRE_4BIT", True))
            can_export_hex = bool(getattr(cfg, "AUTO_EXPORT_WEIGHT_HEX", False))
            if can_export_hex and require_4bit and weight_bits != 4:
                export_info["warnings"].append(
                    f"{label}: skipped HEX export because current RTL staging expects 4-bit, got weight_bits={weight_bits}."
                )
                can_export_hex = False

            if can_export_hex:
                pos_hex = os.path.join(
                    export_dir,
                    f"{label}_{method}_scheme{scheme}_reset{reset_mode}_adc{adc_bits}_w{weight_bits}_t{timesteps}_r{ratio_tag}_weight_pos.hex",
                )
                neg_hex = os.path.join(
                    export_dir,
                    f"{label}_{method}_scheme{scheme}_reset{reset_mode}_adc{adc_bits}_w{weight_bits}_t{timesteps}_r{ratio_tag}_weight_neg.hex",
                )
                export_weight_map.export_weight_hex(
                    method=method,
                    weight_bits=weight_bits,
                    out_pos_hex=pos_hex,
                    out_neg_hex=neg_hex,
                    weights_dir=cfg.WEIGHTS_DIR,
                )
                artifact["pos_hex_path"] = pos_hex
                artifact["neg_hex_path"] = neg_hex

                if label == "recommendation":
                    staged_pos = os.path.join(export_dir, "weight_pos.hex")
                    staged_neg = os.path.join(export_dir, "weight_neg.hex")
                    shutil.copy2(pos_hex, staged_pos)
                    shutil.copy2(neg_hex, staged_neg)
                    artifact["staged_pos_hex_path"] = staged_pos
                    artifact["staged_neg_hex_path"] = staged_neg

            export_info["artifacts"].append(artifact)
        except Exception as exc:
            export_info["warnings"].append(f"{label}: {exc}")

    manifest_path = os.path.join(export_dir, "weight_export_manifest.json")
    export_info["manifest_path"] = manifest_path
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(export_info, f, ensure_ascii=False, indent=2)

    return export_info
# =====================================================
#  主入口
# =====================================================

def main():
    parser = argparse.ArgumentParser(description='SNN SoC Python 建模系统')
    parser.add_argument('--quick', action='store_true',
                        help='快速模式（少量样本，适合调试）')
    parser.add_argument('--skip-train', action='store_true',
                        help='跳过训练，加载已保存权重')
    args = parser.parse_args()

    print("=" * 60)
    print("  SNN SoC Python 建模系统 v1.0")
    print("=" * 60)
    if args.quick:
        print("  模式: 快速测试 (--quick)")

    set_global_seed(cfg.RANDOM_SEED)
    print(f"  随机种子: {cfg.RANDOM_SEED}")
    print(f"  ADC 满量程模式: {cfg.ADC_FULL_SCALE_MODE}")
    backend = snn_engine.get_device_backend_status()
    print(
        "  器件模型接入: "
        f"use_device_model={backend['use_device_model']}, "
        f"path_exists={backend['plugin_path_exists']}, "
        f"levels_loaded={backend['plugin_levels_loaded']}, "
        f"levels={backend['plugin_levels_count']}"
    )

    start_time = time.time()

    # Separate quick/full weights to avoid accidental overwrite.
    _ensure_mode_weight_dir(args)

    # 步骤 1: 准备数据
    all_datasets = data_utils.prepare_all_datasets(quick_mode=args.quick)

    # 步骤 2: 训练 ANN
    training_results = run_training(
        all_datasets, skip_train=args.skip_train, quick=args.quick
    )

    # 步骤 3: SNN 推理 + 参数扫描
    sweep_results, best_method = run_parameter_sweep(
        all_datasets, training_results, quick=args.quick
    )

    # 步骤 4: 生成图表 + 输出推荐
    generate_plots(sweep_results, training_results, best_method)
    sweep_results["weight_exports"] = export_weight_artifacts(sweep_results)
    generate_summary(sweep_results, training_results, best_method, all_datasets)

    elapsed = time.time() - start_time
    print(f"\n总耗时: {elapsed:.1f} 秒 ({elapsed / 60:.1f} 分钟)")
    try:
        backup_info = _auto_backup_full_run(args, elapsed)
        if backup_info is not None:
            print(
                "  [backup] Saved full-run snapshot: "
                f"{backup_info['backup_dir']} "
                f"(results={backup_info['results_count']}, weights={backup_info['weights_count']})"
            )
            print(f"  [backup] Manifest: {backup_info['manifest_path']}")
    except Exception as e:
        print(f"  [backup] WARNING: auto-backup failed: {e}")
    print("完成!")


if __name__ == '__main__':
    main()

