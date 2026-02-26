"""
==========================================================
  SNN SoC Python 寤烘ā - 涓荤▼搴?
==========================================================
鐢ㄦ硶:
    python run_all.py              # 瀹屾暣杩愯 (绾?10-30 鍒嗛挓)
    python run_all.py --quick      # 蹇€熸祴璇?(绾?2-3 鍒嗛挓)
    python run_all.py --skip-train # 璺宠繃璁粌锛屽姞杞藉凡淇濆瓨鐨勬潈閲?

杩愯娴佺▼:
    姝ラ 1: 鍑嗗 MNIST 鏁版嵁 (澶氱闄嶉噰鏍锋柟娉?
    姝ラ 2: 璁粌 ANN (鑾峰彇 float 鍩虹嚎鏉冮噸)
    姝ラ 3: SNN 鎺ㄧ悊 + 鍙傛暟鎵弿 (鏍稿績!)
    姝ラ 4: 鐢熸垚鍥捐〃 + 杈撳嚭鎺ㄨ崘鍙傛暟

杈撳嚭鏂囦欢 (淇濆瓨鍦?results/ 鐩綍):
    fig1_downsample_comparison.png  - 涓嶅悓闄嶉噰鏍锋柟娉曠殑 ANN 鍑嗙‘鐜?
    fig2_adc_bits_sweep.png         - ADC 浣嶅 vs SNN 鍑嗙‘鐜?
    fig3_weight_bits_sweep.png      - 鏉冮噸浣嶅 vs SNN 鍑嗙‘鐜?
    fig4_timesteps_sweep.png        - 鎺ㄧ悊甯ф暟 vs SNN 鍑嗙‘鐜?
    fig5_noise_impact.png           - 鍣ㄤ欢闈炵悊鎯虫€у鍑嗙‘鐜囩殑褰卞搷
    fig6_scheme_comparison.png      - 鏂规A vs B 瀵规瘮
    fig7_adaptive_threshold.png     - 鑷€傚簲闃堝€?vs 鍥哄畾闃堝€?
    summary.txt                     - 鍙傛暟鎺ㄨ崘鎬荤粨
"""

import sys
import os
import argparse
import time
import random
import shutil
import hashlib
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

# 璁?matplotlib 鍦ㄦ病鏈?GUI 鐨勭幆澧冧篃鑳戒繚瀛樺浘鐗?
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# 瀵煎叆鏈」鐩殑妯″潡
import config as cfg
import data_utils
import train_ann
import snn_engine


# =====================================================
#  杈呭姪鍑芥暟
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
    Returns (best_ratio, best_acc) or (None, None) if disabled.
    """
    if not getattr(cfg, 'CALIBRATE_THRESHOLD_RATIO', False):
        return None, None

    candidates = list(getattr(cfg, 'THRESHOLD_RATIO_CANDIDATES', []))
    if not candidates:
        return None, None

    n = int(getattr(cfg, 'THRESHOLD_CALIBRATE_SAMPLES', 0) or 0)
    images_src = ds.get("val_images_uint8")
    labels_src = ds.get("val_labels")
    if images_src is None or labels_src is None:
        return None, None
    n = min(n, int(labels_src.shape[0]))
    if n <= 0:
        return None, None

    # Use a deterministic random subset to avoid positional/class-order bias.
    gen = torch.Generator().manual_seed(int(getattr(cfg, "RANDOM_SEED", 42)) + 20260207)
    perm = torch.randperm(int(labels_src.shape[0]), generator=gen)[:n]
    images = images_src[perm]
    labels = labels_src[perm]

    best_ratio = None
    best_acc = -1.0
    for ratio in candidates:
        acc, _, stats = snn_engine.snn_inference(
            images, labels, W,
            adc_bits=adc_bits, weight_bits=weight_bits, timesteps=timesteps,
            scheme=scheme, decision='spike', threshold_ratio=ratio,
            spike_fallback_to_membrane=False,  # 以纯 spike 指标标定，与硬件行为对齐
            return_stats=True,
        )
        spike_acc = stats.get("spike_only_acc", acc)
        if spike_acc > best_acc:
            best_acc = spike_acc
            best_ratio = ratio

    return best_ratio, best_acc


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


def _combo_cost_key(item, primary_scheme):
    """
    Cost-oriented ordering for recommendation under an accuracy margin.
    Lower ADC/weight/timesteps first, then prefer primary scheme, then higher acc.
    """
    return (
        int(item["adc_bits"]),
        int(item["weight_bits"]),
        int(item["timesteps"]),
        0 if str(item["scheme"]).upper() == str(primary_scheme).upper() else 1,
        -float(item["snn_acc"]),
        str(item["method"]),
    )

# =====================================================
#  姝ラ 2: 璁粌 ANN
# =====================================================

def run_training(all_datasets, skip_train=False, quick=False):
    """
    瀵规瘡绉嶉檷閲囨牱鏂规硶璁粌涓€涓?ANN锛岃褰?float 鍩虹嚎鍑嗙‘鐜囥€?

    杩斿洖:
        results: dict, {鏂规硶鍚? {"float_acc": 鍑嗙‘鐜? "weights": W鐭╅樀}}
    """
    print("\n[姝ラ 2/4] 璁粌 ANN (鑾峰彇 float 鏉冮噸)...")

    epochs = cfg.QUICK_EPOCHS if quick else cfg.ANN_EPOCHS
    results = {}

    for name, ds in all_datasets.items():
        if skip_train:
            # 鍔犺浇宸蹭繚瀛樼殑鏉冮噸
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
                print(f"  {name}: 鏈壘鍒板凡淇濆瓨鏉冮噸锛岄噸鏂拌缁?.")

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
#  姝ラ 3: 鍙傛暟鎵弿
# =====================================================

def run_parameter_sweep(all_datasets, training_results, quick=False):
    """
    鏍稿績: 鍦ㄤ笉鍚岀‖浠跺弬鏁颁笅杩愯 SNN 鎺ㄧ悊锛屾敹闆嗗噯纭巼鏁版嵁銆?

    鎵弿缁村害:
        1. 闄嶉噰鏍锋柟娉?
        2. ADC 浣嶅 (6/8/10/12)
        3. 鏉冮噸浣嶅 (2/3/4/6/8)
        4. 鎺ㄧ悊甯ф暟 (1/3/5/10/20)
        5. 鍣ㄤ欢鍣０ (鏈?鏃?
        6. 宸垎鏂规 (A/B)
        7. 鑷€傚簲闃堝€?(鏈?鏃?
    """
    print("\n[姝ラ 3/4] SNN 鎺ㄧ悊 + 鍙傛暟鎵弿...")

    tune_split = str(getattr(cfg, "TUNE_SPLIT", "val")).lower()
    final_split = str(getattr(cfg, "FINAL_REPORT_SPLIT", "test")).lower()
    target_input_dim = int(getattr(cfg, "TARGET_INPUT_DIM_FOR_RECOMMEND", 0) or 0)
    schemes, primary_scheme = _resolve_eval_schemes()
    default_ratio = float(getattr(cfg, "SPIKE_THRESHOLD_RATIO", 0.6))

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
            "target_input_dim": target_input_dim,
            "allow_signed_scheme_a": bool(getattr(cfg, "ALLOW_SIGNED_SCHEME_A", False)),
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

    # ---- 3a. 楠岃瘉 SNN-ANN 绛変环鎬?(ideal, tuning split) ----
    print(f"\n  [3a] 楠岃瘉 SNN 涓?ANN 鐨勬暟瀛︾瓑浠锋€?(split={tune_split})...")
    for name in eligible_methods:
        ds = all_datasets[name]
        images_eval, labels_eval = _get_split_tensors(ds, tune_split)
        W = training_results[name]["weights"]
        ideal_acc = snn_engine.snn_inference_ideal(images_eval, labels_eval, W, timesteps=1)
        print(f"    {name:20s}: SNN(ideal)={ideal_acc:.2%}")

    # ---- 3b-0. 姣忕鏂规硶銆佹瘡绉嶆柟妗堝崟鐙仛闃堝€兼爣瀹?----
    method_ratio = {name: {} for name in eligible_methods}
    if getattr(cfg, "CALIBRATE_THRESHOLD_RATIO", False):
        print(f"\n  [3b-0] Calibrate threshold ratio (split={tune_split}, per-method/per-scheme)...")
        for name in eligible_methods:
            ds = all_datasets[name]
            W = training_results[name]["weights"]
            results["threshold_calibration"][name] = {}
            for scheme in schemes:
                ratio, ratio_acc = calibrate_threshold_ratio(
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
                }
                if ratio_acc is None:
                    print(f"    {name:20s} [{scheme}] ratio={ratio:.2f} (fallback)")
                else:
                    print(f"    {name:20s} [{scheme}] ratio={ratio:.2f}, val_acc={ratio_acc:.2%}")
    else:
        for name in eligible_methods:
            for scheme in schemes:
                method_ratio[name][scheme] = default_ratio

    # ---- 3b. 鏂规硶閫夋嫨锛堝彧鐢?tuning split锛?--
    print(f"\n  [3b] 闄嶉噰鏍锋柟娉曞姣?(split={tune_split}, scheme={primary_scheme})...")
    for name in eligible_methods:
        ds = all_datasets[name]
        W = training_results[name]["weights"]
        images_eval, labels_eval = _get_split_tensors(ds, tune_split)
        ratio = method_ratio[name].get(primary_scheme, default_ratio)
        acc, _ = snn_engine.snn_inference(
            images_eval, labels_eval, W,
            adc_bits=8, weight_bits=4, timesteps=1,
            scheme=primary_scheme, threshold_ratio=ratio
        )
        results["downsample"][name] = {
            "float_acc": training_results[name]["float_acc"],
            "snn_acc": acc,
            "threshold_ratio": ratio,
            "input_dim": int(ds["input_dim"]),
        }
        print(f"    {name:20s}: SNN={acc:.2%} (ratio={ratio:.2f}, dim={int(ds['input_dim'])})")

    downsample_best_method = max(results["downsample"], key=lambda k: results["downsample"][k]["snn_acc"])
    downsample_best_ratio = results["downsample"][downsample_best_method]["threshold_ratio"]
    print(
        f"\n  鏈€浣虫柟娉?(鍩虹嚎 8/4/1, {tune_split}): {downsample_best_method} "
        f"(SNN={results['downsample'][downsample_best_method]['snn_acc']:.2%}, ratio={downsample_best_ratio:.2f})"
    )

    # ---- 3b-1. 鍏ㄩ噺缁勫悎鎵弿 (method/scheme/ADC/W/T) ----
    print(f"\n  [3b-1] 鍏ㄩ噺缁勫悎鎵弿 (split={tune_split})...")
    grid_total = (
        len(eligible_methods)
        * len(schemes)
        * len(cfg.ADC_BITS_SWEEP)
        * len(cfg.WEIGHT_BITS_SWEEP)
        * len(cfg.TIMESTEPS_SWEEP)
    )
    grid_idx = 0
    for method_name in eligible_methods:
        ds = all_datasets[method_name]
        W = training_results[method_name]["weights"]
        images_eval, labels_eval = _get_split_tensors(ds, tune_split)
        for scheme in schemes:
            ratio = method_ratio[method_name].get(scheme, default_ratio)
            for adc_bits in cfg.ADC_BITS_SWEEP:
                for weight_bits in cfg.WEIGHT_BITS_SWEEP:
                    for timesteps in cfg.TIMESTEPS_SWEEP:
                        acc, _ = snn_engine.snn_inference(
                            images_eval, labels_eval, W,
                            adc_bits=adc_bits,
                            weight_bits=weight_bits,
                            timesteps=timesteps,
                            scheme=scheme,
                            threshold_ratio=ratio
                        )
                        results["full_grid"].append({
                            "method": method_name,
                            "scheme": scheme,
                            "threshold_ratio": float(ratio),
                            "adc_bits": int(adc_bits),
                            "weight_bits": int(weight_bits),
                            "timesteps": int(timesteps),
                            "snn_acc": float(acc),
                        })
                        grid_idx += 1
                        progress_bar(grid_idx, grid_total, prefix="鍏ㄩ噺缁勫悎")

    if not results["full_grid"]:
        raise RuntimeError("full-grid sweep produced no records")

    best_case = max(results["full_grid"], key=lambda x: x["snn_acc"])
    margin = float(getattr(cfg, "RECOMMEND_ACC_MARGIN", 0.005))
    acc_floor = float(best_case["snn_acc"]) - margin
    near_best = [x for x in results["full_grid"] if float(x["snn_acc"]) >= acc_floor]
    if not near_best:
        near_best = [best_case]
    recommendation = min(near_best, key=lambda x: _combo_cost_key(x, primary_scheme))

    topk_n = int(getattr(cfg, "SUMMARY_TOPK_COMBOS", 10))
    results["full_grid_top"] = sorted(
        results["full_grid"], key=lambda x: float(x["snn_acc"]), reverse=True
    )[:max(1, topk_n)]
    results["best_case"] = dict(best_case)
    results["recommendation"] = dict(recommendation)
    results["meta"]["recommend_margin"] = margin
    results["meta"]["full_grid_total"] = len(results["full_grid"])
    results["meta"]["downsample_best_method"] = downsample_best_method

    print(
        f"    鏈€浣?(best-case): method={best_case['method']}, scheme={best_case['scheme']}, "
        f"ADC={best_case['adc_bits']}, W={best_case['weight_bits']}, T={best_case['timesteps']}, "
        f"ratio={best_case['threshold_ratio']:.2f}, acc={best_case['snn_acc']:.2%}"
    )
    print(
        f"    鎺ㄨ崘 (low-cost, within {margin:.2%}): method={recommendation['method']}, "
        f"scheme={recommendation['scheme']}, ADC={recommendation['adc_bits']}, "
        f"W={recommendation['weight_bits']}, T={recommendation['timesteps']}, "
        f"ratio={recommendation['threshold_ratio']:.2f}, acc={recommendation['snn_acc']:.2%}"
    )

    # 鍚庣画鍗曠淮鎵弿鍥捐〃鍥哄畾鍦ㄦ帹鑽愭柟娉曚笂鍋氾紝渚夸簬瑙ｉ噴瓒嬪娍
    best_method = recommendation["method"]
    best_ratio = recommendation["threshold_ratio"]
    best_ds = all_datasets[best_method]
    best_W = training_results[best_method]["weights"]
    best_images_tune, best_labels_tune = _get_split_tensors(best_ds, tune_split)

    # ---- 3c. ADC sweep (tuning split) ----
    print(f"\n  [3c] ADC 浣嶅鎵弿 (split={tune_split}, {best_method})...")
    for adc in cfg.ADC_BITS_SWEEP:
        acc, _ = snn_engine.snn_inference(
            best_images_tune, best_labels_tune, best_W,
            adc_bits=adc, weight_bits=4, timesteps=1,
            scheme=primary_scheme, threshold_ratio=best_ratio
        )
        results["adc_sweep"][adc] = acc
        print(f"    ADC={adc:2d}-bit: {acc:.2%}")

    # ---- 3d. Weight sweep (tuning split) ----
    print(f"\n  [3d] 鏉冮噸浣嶅鎵弿 (split={tune_split}, {best_method})...")
    for wb in cfg.WEIGHT_BITS_SWEEP:
        acc, _ = snn_engine.snn_inference(
            best_images_tune, best_labels_tune, best_W,
            adc_bits=8, weight_bits=wb, timesteps=1,
            scheme=primary_scheme, threshold_ratio=best_ratio
        )
        results["weight_sweep"][wb] = acc
        print(f"    W={wb}-bit: {acc:.2%}")

    # ---- 3e. Timestep sweep (tuning split) ----
    print(f"\n  [3e] 鎺ㄧ悊甯ф暟鎵弿 (split={tune_split}, {best_method})...")
    for ts in cfg.TIMESTEPS_SWEEP:
        acc, _ = snn_engine.snn_inference(
            best_images_tune, best_labels_tune, best_W,
            adc_bits=8, weight_bits=4, timesteps=ts,
            scheme=primary_scheme, threshold_ratio=best_ratio
        )
        results["timestep_sweep"][ts] = acc
        print(f"    T={ts:2d}: {acc:.2%}")

    # ---- 3f. 鍣ㄤ欢闈炵悊鎯虫€у奖鍝?tuning split) ----
    print(f"\n  [3f] 鍣ㄤ欢闈炵悊鎯虫€у奖鍝?split={tune_split}, {best_method})...")
    n_trials = cfg.NOISE_TRIALS_QUICK if quick else cfg.NOISE_TRIALS_FULL
    noise_accs = []
    for trial in range(n_trials):
        acc, _ = snn_engine.snn_inference(
            best_images_tune, best_labels_tune, best_W,
            adc_bits=8, weight_bits=4, timesteps=1, add_noise=True,
            scheme=primary_scheme, threshold_ratio=best_ratio
        )
        noise_accs.append(acc)
        progress_bar(trial + 1, n_trials, prefix="鍣０瀹為獙")

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
    print(f"    鐞嗘兂:   {ideal_acc:.2%}")
    print(f"    鏈夊櫔澹? {noise_mean:.2%} +/- {noise_std:.4f}")
    print(f"    閫€鍖?   {results['noise_impact']['degradation']:.2%}")

    # ---- 3g. 宸垎鏂规瀵规瘮 (tuning split, per-scheme ratio) ----
    print(f"\n  [3g] 宸垎鏂规瀵规瘮 (split={tune_split}, {best_method})...")
    for scheme in schemes:
        ratio = method_ratio[best_method].get(scheme, default_ratio)
        acc, _ = snn_engine.snn_inference(
            best_images_tune, best_labels_tune, best_W,
            adc_bits=8, weight_bits=4, timesteps=1,
            scheme=scheme, threshold_ratio=ratio
        )
        results["scheme_compare"][scheme] = acc
        print(f"    鏂规 {scheme}: {acc:.2%} (ratio={ratio:.2f})")

    # ---- 3h. 鍐崇瓥瑙勫垯瀵规瘮 (tuning split) ----
    print(f"\n  [3h] 鍐崇瓥瑙勫垯瀵规瘮 (split={tune_split}, {best_method})...")
    for decision in ["spike", "membrane"]:
        acc, _ = snn_engine.snn_inference(
            best_images_tune, best_labels_tune, best_W,
            adc_bits=8, weight_bits=4, timesteps=1, decision=decision,
            scheme=primary_scheme, threshold_ratio=best_ratio
        )
        results["decision_compare"][decision] = acc
        print(f"    decision={decision:8s}: {acc:.2%}")

    # ---- 3i. 鑷€傚簲闃堝€?(tuning split) ----
    print(f"\n  [3i] 鑷€傚簲闃堝€煎姣?(split={tune_split}, {best_method})...")
    fixed_acc, _ = snn_engine.snn_inference(
        best_images_tune, best_labels_tune, best_W,
        adc_bits=8, weight_bits=4, timesteps=10,
        scheme=primary_scheme, threshold_ratio=best_ratio
    )
    adaptive_acc, _ = snn_engine.snn_inference_adaptive_threshold(
        best_images_tune, best_labels_tune, best_W,
        adc_bits=8, weight_bits=4, timesteps=10,
        scheme=primary_scheme, add_noise=False
    )
    results["adaptive"] = {
        "fixed": fixed_acc,
        "adaptive": adaptive_acc,
        "improvement": adaptive_acc - fixed_acc,
        "split": tune_split,
    }
    print(f"    鍥哄畾闃堝€?(spike):   {fixed_acc:.2%}")
    print(f"    鑷€傚簲闃堝€?(spike): {adaptive_acc:.2%}")
    print(f"    鎻愬崌: {results['adaptive']['improvement']:+.2%}")

    # ---- 3j. 鍩轰簬 tuning split 鐢熸垚鎺ㄨ崘閰嶇疆 ----
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
    print(
        f"\n  鎺ㄨ崘閰嶇疆 (鍩轰簬 {tune_split}): "
        f"method={best_method}, scheme={primary_scheme}, "
        f"ADC={best_adc}, W={best_wb}, T={best_ts}, ratio={best_ratio:.2f}"
    )

    # ---- 3k. 浠呬竴娆?final split 璇勪及 ----
    final_images, final_labels = _get_split_tensors(best_ds, final_split)
    final_acc, _, final_stats = snn_engine.snn_inference(
        final_images, final_labels, best_W,
        adc_bits=best_adc, weight_bits=best_wb, timesteps=best_ts,
        scheme=primary_scheme, threshold_ratio=best_ratio,
        return_stats=True
    )
    results["final_test"] = {
        "split": final_split,
        "method": best_method,
        "scheme": primary_scheme,
        "threshold_ratio": best_ratio,
        "adc_bits": int(best_adc),
        "weight_bits": int(best_wb),
        "timesteps": int(best_ts),
        "snn_acc": final_acc,
    }
    if "spike_only_acc" in final_stats:
        results["final_test"]["spike_only_acc"] = float(final_stats["spike_only_acc"])
        results["final_test"]["zero_spike_rate"] = float(final_stats.get("zero_spike_rate", 0.0))
        results["final_test"]["zero_spike_count"] = int(final_stats.get("zero_spike_count", 0))
        results["final_test"]["decision_mode"] = str(final_stats.get("decision_mode", "spike"))
        results["final_test_hw_aligned"] = {
            "split": final_split,
            "method": best_method,
            "scheme": primary_scheme,
            "threshold_ratio": best_ratio,
            "adc_bits": int(best_adc),
            "weight_bits": int(best_wb),
            "timesteps": int(best_ts),
            "snn_acc": float(final_stats["spike_only_acc"]),
            "zero_spike_rate": float(final_stats.get("zero_spike_rate", 0.0)),
            "zero_spike_count": int(final_stats.get("zero_spike_count", 0)),
            "decision_mode": "spike_only_no_fallback",
        }
    print(f"  Final {final_split} 涓€娆¤瘎浼? {final_acc:.2%}")
    if "spike_only_acc" in final_stats:
        print(
            f"  Final {final_split} 硬件对齐口径(spike-only): "
            f"{float(final_stats['spike_only_acc']):.2%} "
            f"(zero-spike={float(final_stats.get('zero_spike_rate', 0.0)):.2%})"
        )

    best_case_cfg = dict(results.get("best_case", {}))
    if best_case_cfg:
        best_case_method = best_case_cfg["method"]
        best_case_ds = all_datasets[best_case_method]
        best_case_W = training_results[best_case_method]["weights"]
        best_case_images, best_case_labels = _get_split_tensors(best_case_ds, final_split)
        best_case_final_acc, _, best_case_final_stats = snn_engine.snn_inference(
            best_case_images, best_case_labels, best_case_W,
            adc_bits=int(best_case_cfg["adc_bits"]),
            weight_bits=int(best_case_cfg["weight_bits"]),
            timesteps=int(best_case_cfg["timesteps"]),
            scheme=str(best_case_cfg["scheme"]).upper(),
            threshold_ratio=float(best_case_cfg["threshold_ratio"]),
            return_stats=True
        )
        results["final_test_best_case"] = {
            "split": final_split,
            "method": best_case_method,
            "scheme": str(best_case_cfg["scheme"]).upper(),
            "threshold_ratio": float(best_case_cfg["threshold_ratio"]),
            "adc_bits": int(best_case_cfg["adc_bits"]),
            "weight_bits": int(best_case_cfg["weight_bits"]),
            "timesteps": int(best_case_cfg["timesteps"]),
            "snn_acc": float(best_case_final_acc),
        }
        if "spike_only_acc" in best_case_final_stats:
            results["final_test_best_case"]["spike_only_acc"] = float(best_case_final_stats["spike_only_acc"])
            results["final_test_best_case"]["zero_spike_rate"] = float(best_case_final_stats.get("zero_spike_rate", 0.0))
            results["final_test_best_case"]["zero_spike_count"] = int(best_case_final_stats.get("zero_spike_count", 0))
            results["final_test_best_case"]["decision_mode"] = str(best_case_final_stats.get("decision_mode", "spike"))
            results["final_test_best_case_hw_aligned"] = {
                "split": final_split,
                "method": best_case_method,
                "scheme": str(best_case_cfg["scheme"]).upper(),
                "threshold_ratio": float(best_case_cfg["threshold_ratio"]),
                "adc_bits": int(best_case_cfg["adc_bits"]),
                "weight_bits": int(best_case_cfg["weight_bits"]),
                "timesteps": int(best_case_cfg["timesteps"]),
                "snn_acc": float(best_case_final_stats["spike_only_acc"]),
                "zero_spike_rate": float(best_case_final_stats.get("zero_spike_rate", 0.0)),
                "zero_spike_count": int(best_case_final_stats.get("zero_spike_count", 0)),
                "decision_mode": "spike_only_no_fallback",
            }
        print(f"  Final {final_split} best-case 璇勪及: {best_case_final_acc:.2%}")
        if "spike_only_acc" in best_case_final_stats:
            print(
                f"  Final {final_split} best-case 硬件对齐口径(spike-only): "
                f"{float(best_case_final_stats['spike_only_acc']):.2%} "
                f"(zero-spike={float(best_case_final_stats.get('zero_spike_rate', 0.0)):.2%})"
            )

    # ---- 3l. 鍥哄畾閰嶇疆澶?seed 澶嶈窇锛堟帹鐞嗕晶锛?--
    seed_list = [int(s) for s in getattr(cfg, "FINAL_MULTI_SEEDS", [])]
    if seed_list:
        clean_accs = []
        noisy_accs = []
        print(f"\n  [3l] 鍥哄畾閰嶇疆澶歴eed澶嶈窇 ({len(seed_list)} seeds)...")
        for seed in seed_list:
            set_global_seed(seed)
            clean_acc, _ = snn_engine.snn_inference(
                final_images, final_labels, best_W,
                adc_bits=best_adc, weight_bits=best_wb, timesteps=best_ts,
                scheme=primary_scheme, threshold_ratio=best_ratio
            )
            noisy_acc, _ = snn_engine.snn_inference(
                final_images, final_labels, best_W,
                adc_bits=best_adc, weight_bits=best_wb, timesteps=best_ts,
                scheme=primary_scheme, threshold_ratio=best_ratio, add_noise=True
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
#  姝ラ 4: 鐢熸垚鍥捐〃 + 杈撳嚭鎺ㄨ崘
# =====================================================

def generate_plots(results, training_results, best_method):
    """Generate all result figures."""
    print("\n[姝ラ 4/4] 鐢熸垚缁撴灉鍥捐〃...")
    os.makedirs(cfg.RESULTS_DIR, exist_ok=True)

    has_chinese = setup_chinese_font()

    # ---- 鍥?: 闄嶉噰鏍锋柟娉曞姣?----
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

    # ---- 鍥?: ADC 浣嶅 ----
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

    # ---- 鍥?: 鏉冮噸浣嶅 ----
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

    # ---- 鍥?: 鎺ㄧ悊甯ф暟 ----
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

    # ---- 鍥?: 鍣０褰卞搷 ----
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

    # ---- 鍥?: 宸垎鏂规 ----
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

    # ---- 鍥?: 鑷€傚簲闃堝€?----
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

    lines = []
    lines.append("=" * 60)
    lines.append("  SNN SoC 寤烘ā缁撴灉 - 鍙傛暟鎺ㄨ崘")
    lines.append("=" * 60)
    lines.append(
        f"\n璇勪及鍙ｅ緞: tuning_split={meta.get('tune_split', 'val')} "
        f"(閫夋柟妗?璋冨弬), final_split={meta.get('final_split', 'test')} (鏈€缁堜竴娆℃姤鍛?"
    )
    lines.append(
        f"鍏ㄩ噺缁勫悎鎵弿鏁? {meta.get('full_grid_total', 0)}, "
        f"鎺ㄨ崘绮惧害瀹瑰繊杈圭晫: {meta.get('recommend_margin', 0.0):.2%}"
    )

    lines.append(f"\n鏈€浣充笅閲囨牱鏂规硶(8/4/1鍩虹嚎): {best_method}")
    lines.append(
        f"  tuning SNN(ADC=8,W=4,T=1): "
        f"{results['downsample'][best_method]['snn_acc']:.2%}"
    )
    lines.append(f"  ANN float 鍩虹嚎鍑嗙‘鐜?test): {training_results[best_method]['float_acc']:.2%}")
    quant_acc = training_results[best_method].get("quant_acc")
    if quant_acc is not None:
        lines.append(f"  ANN quantized 鍩虹嚎鍑嗙‘鐜?test): {quant_acc:.2%}")

    if best_case:
        lines.append("\nbest-case(鍏ㄩ噺缃戞牸鏈€楂樼簿搴?:")
        lines.append(
            f"  method={best_case.get('method')}, scheme={best_case.get('scheme')}, "
            f"ADC={best_case.get('adc_bits')}, W={best_case.get('weight_bits')}, "
            f"T={best_case.get('timesteps')}, ratio={best_case.get('threshold_ratio', 0.0):.2f}, "
            f"acc={best_case.get('snn_acc', 0.0):.2%}"
        )

    if rec:
        lines.append("\nrecommendation(绮惧害杈炬爣涓嬩綆鎴愭湰浼樺厛):")
        lines.append(
            f"  method={rec.get('method')}, scheme={rec.get('scheme')}, "
            f"ADC={rec.get('adc_bits')}, W={rec.get('weight_bits')}, "
            f"T={rec.get('timesteps')}, ratio={rec.get('threshold_ratio', 0.0):.2f}, "
            f"tuning_acc={rec.get('snn_acc', 0.0):.2%}"
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
                f"ADC={item.get('adc_bits')}, W={item.get('weight_bits')}, "
                f"T={item.get('timesteps')}, ratio={item.get('threshold_ratio', 0.0):.2f}, "
                f"acc={item.get('snn_acc', 0.0):.2%}"
            )

    if results.get("threshold_calibration"):
        lines.append("\nPer-method calibrated ratio (by scheme):")
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

    adc_sorted = sorted(results["adc_sweep"].items())
    lines.append(f"\nADC sweep ({meta.get('tune_split', 'val')}):")
    for bits, acc in adc_sorted:
        marker = " <- 鎺ㄨ崘" if bits == rec.get("adc_bits") else ""
        lines.append(f"  {bits:2d}-bit: {acc:.2%}{marker}")

    w_sorted = sorted(results["weight_sweep"].items())
    lines.append(f"\nWeight sweep ({meta.get('tune_split', 'val')}):")
    for bits, acc in w_sorted:
        marker = " <- 鎺ㄨ崘" if bits == rec.get("weight_bits") else ""
        lines.append(f"  {bits}-bit: {acc:.2%}{marker}")

    ts_sorted = sorted(results["timestep_sweep"].items())
    lines.append(f"\nTimesteps sweep ({meta.get('tune_split', 'val')}):")
    for ts, acc in ts_sorted:
        marker = " <- 鎺ㄨ崘" if ts == rec.get("timesteps") else ""
        lines.append(f"  T={ts:2d}: {acc:.2%}{marker}")

    ni = results["noise_impact"]
    lines.append(f"\n鍣ㄤ欢闈炵悊鎯冲奖鍝?({ni.get('split', meta.get('tune_split', 'val'))}):")
    lines.append(f"  鐞嗘兂鍑嗙‘鐜?      {ni['ideal']:.2%}")
    lines.append(f"  鍚櫔鍑嗙‘鐜?      {ni['noisy_mean']:.2%} +/- {ni['noisy_std']:.4f}")
    lines.append(f"  鍑嗙‘鐜囬€€鍖?      {ni['degradation']:.2%}")

    sc = results.get("scheme_compare", {})
    if sc:
        lines.append(f"\n宸垎鏂规瀵规瘮 ({meta.get('tune_split', 'val')}):")
        for scheme, acc in sorted(sc.items(), key=lambda kv: kv[0]):
            marker = " <- 鎺ㄨ崘" if scheme == rec.get("scheme") else ""
            lines.append(f"  鏂规 {scheme}: {acc:.2%}{marker}")

    dc = results.get("decision_compare", {})
    if dc:
        lines.append(f"\n鍐崇瓥瑙勫垯瀵规瘮 ({meta.get('tune_split', 'val')}):")
        for decision in ["spike", "membrane"]:
            if decision in dc:
                lines.append(f"  {decision:8s}: {dc[decision]:.2%}")

    ad = results["adaptive"]
    do_adaptive = ad["improvement"] >= 0.01
    lines.append(f"\n鑷€傚簲闃堝€?({ad.get('split', meta.get('tune_split', 'val'))}):")
    lines.append(f"  鍥哄畾闃堝€?spike): {ad['fixed']:.2%}")
    lines.append(f"  鑷€傚簲闃堝€?      {ad['adaptive']:.2%}")
    lines.append(f"  鎻愬崌:            {ad['improvement']:+.2%}")
    lines.append(f"  conclusion: {'recommended' if do_adaptive else 'not recommended'}")

    ms = results.get("multi_seed", {})
    if ms:
        lines.append(f"\n鍥哄畾閰嶇疆澶歴eed澶嶈窇 ({ms.get('split', meta.get('final_split', 'test'))}):")
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
    if final_hw:
        lines.append("\n注：Hardware-aligned 口径禁用“零脉冲时回退到 membrane”兜底，用于与当前 RTL 输出能力对齐。")

    lines.append(f"\n{'=' * 60}")
    lines.append("  RTL 鍙傛暟鎺ㄨ崘 (鐢ㄤ簬鏇存柊 snn_soc_pkg.sv)")
    lines.append(f"{'=' * 60}")
    rec_method = rec.get("method", best_method)
    input_dim = int(all_datasets[rec_method]["input_dim"])
    lines.append(f"  NUM_INPUTS  = {input_dim}")
    lines.append("  NUM_OUTPUTS = 10")
    lines.append(f"  ADC_BITS    = {rec.get('adc_bits')}")
    lines.append("  PIXEL_BITS  = 8")
    lines.append(f"  // WEIGHT_BITS = {rec.get('weight_bits')} (device-side parameter)")
    lines.append(f"  // SCHEME = {rec.get('scheme')}")
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
    print(f"\n缁撴灉宸蹭繚瀛樺埌: {cfg.RESULTS_DIR}")
# =====================================================
#  涓诲叆鍙?
# =====================================================

def main():
    parser = argparse.ArgumentParser(description='SNN SoC Python 寤烘ā绯荤粺')
    parser.add_argument('--quick', action='store_true',
                        help='蹇€熸ā寮?(灏戦噺鏍锋湰锛岄€傚悎璋冭瘯)')
    parser.add_argument('--skip-train', action='store_true',
                        help='璺宠繃璁粌锛屽姞杞藉凡淇濆瓨鏉冮噸')
    args = parser.parse_args()

    print("=" * 60)
    print("  SNN SoC Python 寤烘ā绯荤粺 v1.0")
    print("=" * 60)
    if args.quick:
        print("  妯″紡: 蹇€熸祴璇?(--quick)")

    set_global_seed(cfg.RANDOM_SEED)
    print(f"  闅忔満绉嶅瓙: {cfg.RANDOM_SEED}")
    print(f"  ADC婊￠噺绋嬫ā寮? {cfg.ADC_FULL_SCALE_MODE}")
    backend = snn_engine.get_device_backend_status()
    print(
        "  鍣ㄤ欢妯″瀷鎺ュ叆: "
        f"use_device_model={backend['use_device_model']}, "
        f"path_exists={backend['plugin_path_exists']}, "
        f"levels_loaded={backend['plugin_levels_loaded']}, "
        f"levels={backend['plugin_levels_count']}"
    )

    start_time = time.time()

    # Separate quick/full weights to avoid accidental overwrite.
    _ensure_mode_weight_dir(args)

    # 姝ラ 1: 鍑嗗鏁版嵁
    all_datasets = data_utils.prepare_all_datasets(quick_mode=args.quick)

    # 姝ラ 2: 璁粌 ANN
    training_results = run_training(
        all_datasets, skip_train=args.skip_train, quick=args.quick
    )

    # 姝ラ 3: SNN 鎺ㄧ悊 + 鍙傛暟鎵弿
    sweep_results, best_method = run_parameter_sweep(
        all_datasets, training_results, quick=args.quick
    )

    # 姝ラ 4: 鐢熸垚鍥捐〃 + 鎺ㄨ崘
    generate_plots(sweep_results, training_results, best_method)
    generate_summary(sweep_results, training_results, best_method, all_datasets)

    elapsed = time.time() - start_time
    print(f"\n鎬昏€楁椂: {elapsed:.1f} 绉?({elapsed / 60:.1f} 鍒嗛挓)")
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
    print("瀹屾垚!")


if __name__ == '__main__':
    main()

