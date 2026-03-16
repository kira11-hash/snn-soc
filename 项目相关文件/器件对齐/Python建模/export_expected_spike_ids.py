# -*- coding: utf-8 -*-
"""
Step 3.4: 导出 Python↔RTL 对齐验证用的正式刺激集。

功能：
  1. 加载 weight_pos.hex / weight_neg.hex（与 RTL 行为模型一致的 4-bit 权重索引）
  2. 加载 MNIST 指定 split（默认 test）并做与训练流程一致的预处理
  3. 使用与 RTL 完全一致的整数算术运行 SNN 推理
  4. 导出 bit-plane hex、Python 预测类别，以及审计用 manifest

默认正式样本规则：
  - split = test
  - 每类取前 10 个样本
  - 类别顺序固定为 0→9
  - 共 100 个样本，按 class-major 顺序导出

说明：
  - expected_classes.hex 存的是 Python predicted_class，用于和 RTL 输出做等价性对齐
  - 真实标签 true_label 保存在 alignment_manifest.json 中
  - 若要做小样本调试，优先在仿真侧使用 +SAMPLE_COUNT= 覆盖，而不是改正式刺激集
"""

import argparse
import json
import os
import sys
from glob import glob

import torch
from torchvision import datasets

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config as cfg
import data_utils


NUM_INPUTS = 64
NUM_OUTPUTS = 10
PIXEL_BITS = 8
LEVEL_MAX = 15
SUM_MAX = NUM_INPUTS * LEVEL_MAX
ADC_MAX = 255


def load_weight_hex(hex_path):
    """加载 row-major 权重 hex，返回 [NUM_INPUTS][NUM_OUTPUTS]。"""
    with open(hex_path, "r", encoding="ascii") as f:
        values = [int(line.strip(), 16) for line in f if line.strip()]

    expected = NUM_INPUTS * NUM_OUTPUTS
    if len(values) != expected:
        raise ValueError(f"Expected {expected} entries in {hex_path}, got {len(values)}")

    weights = [[0] * NUM_OUTPUTS for _ in range(NUM_INPUTS)]
    for row in range(NUM_INPUTS):
        for col in range(NUM_OUTPUTS):
            weights[row][col] = values[row * NUM_OUTPUTS + col]
    return weights


def rtl_adc_scale(raw_sum):
    """复现 RTL 的 ADC 缩放公式。"""
    scaled = (raw_sum * ADC_MAX + SUM_MAX // 2) // SUM_MAX
    return max(0, min(ADC_MAX, scaled))


def rtl_snn_inference(pixel_vec, w_pos, w_neg, timesteps, threshold):
    """使用与 RTL 完全一致的整数算术运行 SNN 推理。"""
    membrane = [0] * NUM_OUTPUTS
    spike_counts = [0] * NUM_OUTPUTS

    for _frame in range(timesteps):
        for bit in range(PIXEL_BITS - 1, -1, -1):
            spike_input = [(pixel_vec[row] >> bit) & 1 for row in range(NUM_INPUTS)]

            for col in range(NUM_OUTPUTS):
                pos_sum = 0
                neg_sum = 0
                for row in range(NUM_INPUTS):
                    if spike_input[row]:
                        pos_sum += w_pos[row][col]
                        neg_sum += w_neg[row][col]

                adc_pos = rtl_adc_scale(pos_sum)
                adc_neg = rtl_adc_scale(neg_sum)
                diff = adc_pos - adc_neg

                membrane[col] += diff * (1 << bit)
                if membrane[col] >= threshold:
                    spike_counts[col] += 1
                    membrane[col] -= threshold

    predicted_class = spike_counts.index(max(spike_counts))
    return spike_counts, predicted_class, membrane


def sample_to_planes(pixel_vec, timesteps):
    """将 64 维 uint8 特征转成 frame-major / bit7→bit0 的 64-bit hex。"""
    lines = []
    for _frame in range(timesteps):
        for bit in range(PIXEL_BITS - 1, -1, -1):
            plane = 0
            for idx, pixel in enumerate(pixel_vec):
                if (pixel >> bit) & 1:
                    plane |= 1 << idx
            lines.append(f"{plane:016X}")
    return lines


def prepare_images(method_name, split="test"):
    """加载并预处理 MNIST 图像，流程与 run_all.py 保持一致。"""
    target_size, method = cfg.DOWNSAMPLE_METHODS[method_name]
    train_mnist = datasets.MNIST(cfg.DATA_DIR, train=True, download=True)
    test_mnist = datasets.MNIST(cfg.DATA_DIR, train=False, download=True)

    train_images_28 = train_mnist.data

    if split == "test":
        split_images_28 = test_mnist.data
        split_labels = test_mnist.targets
    elif split == "val":
        val_size = int(getattr(cfg, "VAL_SAMPLES", 0) or 0)
        train_idx, val_idx = data_utils._stratified_train_val_split(
            train_mnist.targets, val_size, seed=cfg.RANDOM_SEED + 999
        )
        split_images_28 = train_images_28[val_idx]
        split_labels = train_mnist.targets[val_idx]
        train_images_28 = train_images_28[train_idx]
    else:
        raise ValueError(f"Unsupported split: {split}")

    train_flat = data_utils.downsample_batch(train_images_28, target_size, method)
    split_flat = data_utils.downsample_batch(split_images_28, target_size, method)

    gain = 1.0
    if getattr(cfg, "AUTO_INPUT_GAIN", False):
        percentile = torch.quantile(train_flat.float(), float(cfg.INPUT_GAIN_PERCENTILE))
        if percentile > 1.0:
            gain = min(float(cfg.INPUT_GAIN_MAX), 255.0 / float(percentile))
    if gain > 1.0 + 1e-6:
        split_flat = torch.clamp(split_flat.float() * gain, 0, 255).round().byte()

    return split_flat, split_labels


def pick_n_per_class(labels, samples_per_class, num_classes=10):
    """按 class-major 顺序为每一类取前 N 个样本。"""
    if samples_per_class <= 0:
        raise ValueError("samples_per_class must be positive")

    picked = []
    for cls in range(num_classes):
        hits = torch.nonzero(labels == cls, as_tuple=False).flatten()
        if hits.numel() < samples_per_class:
            raise RuntimeError(
                f"Class {cls} has only {hits.numel()} samples, need {samples_per_class}"
            )
        picked.extend(int(hit.item()) for hit in hits[:samples_per_class])
    return picked


def cleanup_previous_exports(out_dir):
    """清理旧导出，避免 10 样本历史文件残留在正式 100 样本目录中。"""
    for path in glob(os.path.join(out_dir, "sample_*.hex")):
        os.remove(path)

    for name in ("all_samples.hex", "expected_classes.hex", "expected_spike_counts.hex", "alignment_manifest.json"):
        path = os.path.join(out_dir, name)
        if os.path.exists(path):
            os.remove(path)


def main():
    parser = argparse.ArgumentParser(
        description="Step 3.4: Export expected spike IDs for Python-to-RTL alignment"
    )
    parser.add_argument(
        "--weight-dir",
        default=None,
        help="Directory containing weight_pos.hex and weight_neg.hex",
    )
    parser.add_argument("--method", default="avgpool_8x8", help="Preprocessing method")
    parser.add_argument("--timesteps", type=int, default=10, help="Number of timesteps")
    parser.add_argument("--threshold", type=int, default=2550, help="Spike threshold")
    parser.add_argument(
        "--samples",
        type=int,
        default=100,
        help="Total number of samples. Must be a multiple of 10; default is 100 (10 per class).",
    )
    parser.add_argument("--split", default="test", choices=["test", "val"], help="MNIST split")
    parser.add_argument("--out-dir", default=None, help="Output directory")
    args = parser.parse_args()

    if args.weight_dir:
        weight_dir = args.weight_dir
    else:
        weight_dir = os.path.join(cfg.RESULTS_DIR, cfg.WEIGHT_EXPORT_SUBDIR)

    pos_path = os.path.join(weight_dir, "weight_pos.hex")
    neg_path = os.path.join(weight_dir, "weight_neg.hex")
    if not os.path.exists(pos_path) or not os.path.exists(neg_path):
        print(f"[ERROR] Weight hex not found in {weight_dir}")
        print(f"  Expected: {pos_path}")
        print(f"  Expected: {neg_path}")
        sys.exit(1)

    out_dir = args.out_dir or os.path.join(weight_dir, "rtl_stimulus")
    os.makedirs(out_dir, exist_ok=True)
    cleanup_previous_exports(out_dir)

    print("[Step 3.4] RTL-equivalent SNN inference for alignment verification")
    print(f"  weights:    {weight_dir}")
    print(f"  method:     {args.method}")
    print(f"  timesteps:  {args.timesteps}")
    print(f"  threshold:  {args.threshold}")
    print(f"  split:      {args.split}")
    print(f"  samples:    {args.samples}")
    print(f"  output:     {out_dir}")
    print()

    if args.samples <= 0:
        raise ValueError("--samples must be positive")
    if args.samples % NUM_OUTPUTS != 0:
        raise ValueError(
            f"--samples must be a multiple of {NUM_OUTPUTS} so each class gets the same count"
        )

    samples_per_class = args.samples // NUM_OUTPUTS
    if args.split != "test":
        print(f"[WARN] Formal corpus uses split=test; current run uses split={args.split}")

    w_pos = load_weight_hex(pos_path)
    w_neg = load_weight_hex(neg_path)
    images, labels = prepare_images(args.method, args.split)
    indices = pick_n_per_class(labels, samples_per_class, NUM_OUTPUTS)

    results = []
    all_planes_combined = []

    for slot, ds_idx in enumerate(indices):
        pixel_vec = [int(v) for v in images[ds_idx].tolist()]
        true_label = int(labels[ds_idx].item())

        spike_counts, predicted, membrane_final = rtl_snn_inference(
            pixel_vec, w_pos, w_neg, args.timesteps, args.threshold
        )

        total_spikes = sum(spike_counts)
        match = predicted == true_label
        planes = sample_to_planes(pixel_vec, args.timesteps)

        hex_name = f"sample_{slot:02d}_label{true_label}.hex"
        hex_path = os.path.join(out_dir, hex_name)
        with open(hex_path, "w", encoding="ascii") as f:
            f.write("\n".join(planes) + "\n")

        all_planes_combined.extend(planes)

        print(
            f"  sample[{slot:02d}] ds_idx={ds_idx} label={true_label} predicted={predicted} "
            f"spikes={spike_counts} total={total_spikes} "
            f"[{'PASS' if match else 'MISMATCH'}]"
        )

        results.append(
            {
                "slot": slot,
                "dataset_index": ds_idx,
                "true_label": true_label,
                "predicted_class": predicted,
                "spike_counts": spike_counts,
                "total_spikes": total_spikes,
                "membrane_final": membrane_final,
                "match_label": match,
                "hex_file": hex_name,
            }
        )

    all_hex_path = os.path.join(out_dir, "all_samples.hex")
    with open(all_hex_path, "w", encoding="ascii") as f:
        f.write("\n".join(all_planes_combined) + "\n")

    classes_path = os.path.join(out_dir, "expected_classes.hex")
    with open(classes_path, "w", encoding="ascii") as f:
        for result in results:
            f.write(f"{result['predicted_class']:X}\n")

    spike_counts_path = os.path.join(out_dir, "expected_spike_counts.hex")
    with open(spike_counts_path, "w", encoding="ascii") as f:
        for result in results:
            line = " ".join(f"{count:02X}" for count in result["spike_counts"])
            f.write(line + "\n")

    correct_count = sum(1 for result in results if result["match_label"])
    manifest = {
        "method": args.method,
        "timesteps": args.timesteps,
        "threshold": args.threshold,
        "split": args.split,
        "sample_count": len(results),
        "samples_per_class": samples_per_class,
        "sample_selection_rule": {
            "strategy": "class_major_first_k",
            "class_order": list(range(NUM_OUTPUTS)),
            "samples_per_class": samples_per_class,
            "description": (
                "Select the first K occurrences of each class from the chosen split, "
                "ordered by class."
            ),
        },
        "expected_classes_semantics": (
            "expected_classes.hex stores Python predicted_class for RTL equivalence; "
            "ground-truth labels remain in results[*].true_label."
        ),
        "correct_count": correct_count,
        "accuracy": correct_count / max(1, len(results)),
        "rtl_params": {
            "NUM_INPUTS": NUM_INPUTS,
            "NUM_OUTPUTS": NUM_OUTPUTS,
            "PIXEL_BITS": PIXEL_BITS,
            "LEVEL_MAX": LEVEL_MAX,
            "SUM_MAX": SUM_MAX,
            "ADC_MAX": ADC_MAX,
        },
        "results": results,
    }

    manifest_path = os.path.join(out_dir, "alignment_manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)

    print()
    print(f"[Step 3.4] Classification accuracy vs true labels: {correct_count}/{len(results)}")
    print(f"  all_samples.hex:        {all_hex_path}")
    print(f"  expected_classes.hex:   {classes_path}")
    print(f"  expected_spike_counts:  {spike_counts_path}")
    print(f"  manifest:               {manifest_path}")
    print()
    print(">>> Next step: copy rtl_stimulus/ to sim/ directory, then run:")
    print(">>>   cd sim && bash run_sample_align.sh")
    print(">>> TB will auto-compare RTL output vs expected_classes.hex")
    print(">>> expected_classes.hex contains Python predicted_class, not true labels")


if __name__ == "__main__":
    main()
