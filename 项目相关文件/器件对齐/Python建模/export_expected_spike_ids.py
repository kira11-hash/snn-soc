# -*- coding: utf-8 -*-
"""
Step 3.4: 导出 RTL 对齐验证用的预期 spike_id

功能：
  1. 加载 weight_pos.hex / weight_neg.hex（与 RTL 行为模型相同的 4-bit 级索引）
  2. 加载 10 个 MNIST 测试样本（每类一个）并预处理（avgpool 8x8）
  3. 使用与 RTL 完全一致的整数算术运行 SNN 推理
  4. 导出 bit-plane hex（供 TB $readmemh）和预期分类结果

RTL 等效计算链：
  - MAC: pos_sum = sum of weight_level_idx for active rows
  - ADC: scaled = (raw_sum * 255 + 480) // 960  (integer division, rounding)
         其中 SUM_MAX = NUM_INPUTS * LEVEL_MAX = 64 * 15 = 960
  - diff = adc_pos - adc_neg (signed 9-bit)
  - membrane += diff << bitplane_shift
  - spike if membrane >= threshold (default 2550), soft reset: membrane -= threshold
  - classification: argmax(spike_counts)

用法：
  cd 项目相关文件/器件对齐/Python建模
  python export_expected_spike_ids.py

  生成目录: results/exports/rtl_stimulus/
    - sample_00_label0.hex ~ sample_09_label9.hex  (per-sample bit-plane hex)
    - all_samples.hex          (所有样本合并，供 TB 一次性 $readmemh)
    - expected_classes.hex     (10 行，每行一个预期分类 hex)
    - alignment_manifest.json  (详细结果清单)
"""

import argparse
import json
import os
import sys

import torch
from torchvision import datasets

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config as cfg
import data_utils

# ── RTL 参数（必须与 snn_soc_pkg.sv 一致）──────────────────────────────
NUM_INPUTS = 64
NUM_OUTPUTS = 10
PIXEL_BITS = 8
LEVEL_MAX = 15          # 4-bit weight: 0~15
SUM_MAX = NUM_INPUTS * LEVEL_MAX  # 64 * 15 = 960
ADC_MAX = 255           # 8-bit ADC: 0~255


def load_weight_hex(hex_path):
    """
    加载 weight hex 文件为 2D 整数数组 [NUM_INPUTS][NUM_OUTPUTS]。
    HEX 文件布局：row-major by input_row，flat_idx = row * NUM_OUTPUTS + col。
    """
    with open(hex_path, "r") as f:
        values = [int(line.strip(), 16) for line in f if line.strip()]
    expected = NUM_INPUTS * NUM_OUTPUTS
    if len(values) != expected:
        raise ValueError(f"Expected {expected} entries in {hex_path}, got {len(values)}")
    W = [[0] * NUM_OUTPUTS for _ in range(NUM_INPUTS)]
    for row in range(NUM_INPUTS):
        for col in range(NUM_OUTPUTS):
            W[row][col] = values[row * NUM_OUTPUTS + col]
    return W


def rtl_adc_scale(raw_sum):
    """
    复现 RTL scale_sum_to_adc 函数（整数算术，完全匹配）。
    Verilog: scaled = (raw_sum * P_ADC_MAX + (P_SUM_MAX / 2)) / P_SUM_MAX;
    Python:  scaled = (raw_sum * 255 + 480) // 960
    """
    scaled = (raw_sum * ADC_MAX + SUM_MAX // 2) // SUM_MAX
    return max(0, min(ADC_MAX, scaled))


def rtl_snn_inference(pixel_vec, W_pos, W_neg, timesteps, threshold):
    """
    使用与 RTL 完全一致的整数算术运行 SNN 推理。

    Args:
        pixel_vec: list[64] of uint8 pixel values
        W_pos: weight_pos[row][col], 4-bit level indices (0-15)
        W_neg: weight_neg[row][col], 4-bit level indices (0-15)
        timesteps: 推理帧数
        threshold: spike 阈值（整数）

    Returns:
        spike_counts: list[10] 每个神经元的 spike 次数
        predicted_class: int (argmax of spike_counts)
        membrane_final: list[10] 最终膜电位
    """
    membrane = [0] * NUM_OUTPUTS
    spike_counts = [0] * NUM_OUTPUTS

    for _frame in range(timesteps):
        for bit in range(PIXEL_BITS - 1, -1, -1):
            # 提取 bit-plane 二值输入
            spike_input = [(pixel_vec[i] >> bit) & 1 for i in range(NUM_INPUTS)]

            for col in range(NUM_OUTPUTS):
                # CIM MAC: 对活跃行的权重级索引求和
                pos_sum = 0
                neg_sum = 0
                for row in range(NUM_INPUTS):
                    if spike_input[row]:
                        pos_sum += W_pos[row][col]
                        neg_sum += W_neg[row][col]

                # ADC 量化（RTL 公式）
                adc_pos = rtl_adc_scale(pos_sum)
                adc_neg = rtl_adc_scale(neg_sum)

                # Scheme B 数字域差分
                diff = adc_pos - adc_neg

                # LIF 膜电位累积: membrane += diff << bit
                membrane[col] += diff * (1 << bit)

                # 阈值比较 + soft reset
                if membrane[col] >= threshold:
                    spike_counts[col] += 1
                    membrane[col] -= threshold

    # 分类: argmax(spike_counts)
    predicted_class = spike_counts.index(max(spike_counts))
    return spike_counts, predicted_class, membrane


def sample_to_planes(pixel_vec, timesteps):
    """
    将像素向量转换为 bit-plane hex 行。
    格式：frame-major，每帧 bit7→bit0（MSB→LSB），每行 64-bit hex。
    与 export_mnist_bitplane_hex._sample_to_planes 完全一致。
    """
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
    """加载并预处理 MNIST 图像（与 run_all.py 完全一致的流程）。"""
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

    # 输入增益（与 run_all 一致）
    gain = 1.0
    if getattr(cfg, "AUTO_INPUT_GAIN", False):
        p = torch.quantile(train_flat.float(), float(cfg.INPUT_GAIN_PERCENTILE))
        if p > 1.0:
            gain = min(float(cfg.INPUT_GAIN_MAX), 255.0 / float(p))
    if gain > 1.0 + 1e-6:
        split_flat = torch.clamp(split_flat.float() * gain, 0, 255).round().byte()

    return split_flat, split_labels


def pick_one_per_class(labels, num_classes=10):
    """每类取第一个样本（与 export_mnist_bitplane_hex._pick_indices 一致）。"""
    picked = []
    for cls in range(num_classes):
        hits = torch.nonzero(labels == cls, as_tuple=False).flatten()
        if hits.numel() == 0:
            raise RuntimeError(f"Class {cls} not found in dataset")
        picked.append(int(hits[0].item()))
    return picked


def main():
    parser = argparse.ArgumentParser(
        description="Step 3.4: Export expected spike IDs for Python↔RTL alignment"
    )
    parser.add_argument(
        "--weight-dir", default=None,
        help="Directory containing weight_pos.hex and weight_neg.hex"
    )
    parser.add_argument("--method", default="avgpool_8x8", help="Preprocessing method")
    parser.add_argument("--timesteps", type=int, default=10, help="Number of timesteps")
    parser.add_argument("--threshold", type=int, default=2550, help="Spike threshold")
    parser.add_argument("--samples", type=int, default=10, help="Number of samples (10=one per class)")
    parser.add_argument("--split", default="test", choices=["test", "val"], help="MNIST split")
    parser.add_argument("--out-dir", default=None, help="Output directory")
    args = parser.parse_args()

    # ── 定位权重 hex ──
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

    # ── 输出目录 ──
    if args.out_dir:
        out_dir = args.out_dir
    else:
        out_dir = os.path.join(weight_dir, "rtl_stimulus")
    os.makedirs(out_dir, exist_ok=True)

    print(f"[Step 3.4] RTL-equivalent SNN inference for alignment verification")
    print(f"  weights:    {weight_dir}")
    print(f"  method:     {args.method}")
    print(f"  timesteps:  {args.timesteps}")
    print(f"  threshold:  {args.threshold}")
    print(f"  split:      {args.split}")
    print(f"  output:     {out_dir}")
    print()

    # ── 加载权重 ──
    W_pos = load_weight_hex(pos_path)
    W_neg = load_weight_hex(neg_path)

    # ── 加载并预处理图像 ──
    images, labels = prepare_images(args.method, args.split)
    if args.samples == 10:
        indices = pick_one_per_class(labels, 10)
    else:
        indices = list(range(min(args.samples, int(labels.shape[0]))))

    results = []
    all_planes_combined = []  # 合并所有样本的 bit-plane，供 TB $readmemh

    for slot, ds_idx in enumerate(indices):
        pixel_vec = [int(v) for v in images[ds_idx].tolist()]
        true_label = int(labels[ds_idx].item())

        # RTL 等效推理
        spike_counts, predicted, membrane_final = rtl_snn_inference(
            pixel_vec, W_pos, W_neg, args.timesteps, args.threshold
        )

        total_spikes = sum(spike_counts)
        match = predicted == true_label

        # 导出单样本 bit-plane hex
        planes = sample_to_planes(pixel_vec, args.timesteps)
        hex_name = f"sample_{slot:02d}_label{true_label}.hex"
        hex_path = os.path.join(out_dir, hex_name)
        with open(hex_path, "w", encoding="ascii") as f:
            f.write("\n".join(planes) + "\n")

        all_planes_combined.extend(planes)

        print(f"  sample[{slot}] label={true_label} predicted={predicted} "
              f"spikes={spike_counts} total={total_spikes} "
              f"[{'PASS' if match else 'MISMATCH'}]")

        results.append({
            "slot": slot,
            "dataset_index": ds_idx,
            "true_label": true_label,
            "predicted_class": predicted,
            "spike_counts": spike_counts,
            "total_spikes": total_spikes,
            "membrane_final": membrane_final,
            "match_label": match,
            "hex_file": hex_name,
        })

    # ── 导出合并 hex（供 TB 一次性 $readmemh）──
    all_hex_path = os.path.join(out_dir, "all_samples.hex")
    with open(all_hex_path, "w", encoding="ascii") as f:
        f.write("\n".join(all_planes_combined) + "\n")

    # ── 导出预期分类 hex（每行一个 hex 数字）──
    classes_path = os.path.join(out_dir, "expected_classes.hex")
    with open(classes_path, "w", encoding="ascii") as f:
        for r in results:
            f.write(f"{r['predicted_class']:X}\n")

    # ── 导出 RTL 预期 spike counts（供 TB 详细对比）──
    spike_counts_path = os.path.join(out_dir, "expected_spike_counts.hex")
    with open(spike_counts_path, "w", encoding="ascii") as f:
        # 每样本一行，10 个 hex 值（每个 2 位 hex = 8 bit，足够表示 spike count）
        for r in results:
            line = " ".join(f"{c:02X}" for c in r["spike_counts"])
            f.write(line + "\n")

    # ── 导出详细结果清单 ──
    correct_count = sum(1 for r in results if r["match_label"])
    manifest = {
        "method": args.method,
        "timesteps": args.timesteps,
        "threshold": args.threshold,
        "split": args.split,
        "sample_count": len(results),
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
    print(f"[Step 3.4] Classification accuracy: {correct_count}/{len(results)}")
    print(f"  all_samples.hex:        {all_hex_path}")
    print(f"  expected_classes.hex:    {classes_path}")
    print(f"  expected_spike_counts:   {spike_counts_path}")
    print(f"  manifest:               {manifest_path}")
    print()

    # ── Step 3.4 对齐标准：Python 预期与 RTL 输出完全一致 ──
    # 此脚本产生 Python 侧的预期值；RTL 侧由 top_tb_sample_align.sv 仿真产生
    # 两者的 predicted_class 必须 10/10 完全一致
    print(">>> Next step: copy rtl_stimulus/ to sim/ directory, then run:")
    print(">>>   cd sim && bash run_sample_align.sh")
    print(">>> TB will auto-compare RTL output vs expected_classes.hex")


if __name__ == "__main__":
    main()
