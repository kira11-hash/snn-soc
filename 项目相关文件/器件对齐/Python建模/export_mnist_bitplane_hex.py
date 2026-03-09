import argparse
import json
import os

import torch
from torchvision import datasets

import config as cfg
import data_utils


def _load_recommendation(manifest_path):
    with open(manifest_path, "r", encoding="utf-8") as f:
        manifest = json.load(f)
    for artifact in manifest.get("artifacts", []):
        if artifact.get("label") == "recommendation":
            return artifact
    raise RuntimeError(f"Recommendation artifact not found in manifest: {manifest_path}")


def _prepare_split_images(method_name, split_name):
    target_size, method = cfg.DOWNSAMPLE_METHODS[method_name]
    train_mnist = datasets.MNIST(cfg.DATA_DIR, train=True, download=True)
    test_mnist = datasets.MNIST(cfg.DATA_DIR, train=False, download=True)

    train_images_28 = train_mnist.data
    train_labels = train_mnist.targets

    if split_name == "test":
        split_images_28 = test_mnist.data
        split_labels = test_mnist.targets
    elif split_name == "val":
        val_size = int(getattr(cfg, "VAL_SAMPLES", 0) or 0)
        train_idx, val_idx = data_utils._stratified_train_val_split(
            train_labels, val_size, seed=cfg.RANDOM_SEED + 999
        )
        split_images_28 = train_images_28[val_idx]
        split_labels = train_labels[val_idx]
        train_images_28 = train_images_28[train_idx]
        train_labels = train_labels[train_idx]
    else:
        raise ValueError(f"Unsupported split: {split_name}")

    train_flat = data_utils.downsample_batch(train_images_28, target_size, method)
    split_flat = data_utils.downsample_batch(split_images_28, target_size, method)

    gain = 1.0
    if getattr(cfg, "AUTO_INPUT_GAIN", False):
        p = torch.quantile(train_flat.float(), float(cfg.INPUT_GAIN_PERCENTILE))
        if p > 1.0:
            gain = min(float(cfg.INPUT_GAIN_MAX), 255.0 / float(p))
    if gain > 1.0 + 1e-6:
        split_flat = torch.clamp(split_flat.float() * gain, 0, 255).round().byte()

    return split_flat, split_labels


def _pick_indices(labels, sample_count):
    labels = labels.cpu()
    if sample_count == 10:
        picked = []
        for cls in range(10):
            hits = torch.nonzero(labels == cls, as_tuple=False).flatten()
            if hits.numel() == 0:
                raise RuntimeError(f"Class {cls} not found in selected split.")
            picked.append(int(hits[0].item()))
        return picked
    return list(range(min(sample_count, int(labels.shape[0]))))


def _sample_to_planes(pixel_vec, timesteps):
    pixels = [int(v) for v in pixel_vec.tolist()]
    lines = []
    for _frame in range(timesteps):
        for bit in range(int(cfg.PIXEL_BITS) - 1, -1, -1):
            plane = 0
            for idx, pixel in enumerate(pixels):
                if (pixel >> bit) & 1:
                    plane |= (1 << idx)
            lines.append(f"{plane:016X}")
    return lines


def main():
    parser = argparse.ArgumentParser(description="Export MNIST bit-plane HEX for RTL/TB stimulus.")
    parser.add_argument(
        "--manifest",
        default=os.path.join(cfg.RESULTS_DIR, cfg.WEIGHT_EXPORT_SUBDIR, "weight_export_manifest.json"),
        help="Path to weight_export_manifest.json produced by run_all.py",
    )
    parser.add_argument("--method", default="", help="Override recommendation method.")
    parser.add_argument("--split", default="test", choices=["test", "val"], help="MNIST split to export.")
    parser.add_argument("--samples", type=int, default=10, help="Number of samples to export.")
    parser.add_argument("--timesteps", type=int, default=0, help="Override timesteps; default uses recommendation.")
    parser.add_argument(
        "--out-dir",
        default=os.path.join(cfg.RESULTS_DIR, cfg.WEIGHT_EXPORT_SUBDIR, "rtl_stimulus"),
        help="Output directory for sample HEX files.",
    )
    args = parser.parse_args()

    recommendation = {}
    if os.path.exists(args.manifest):
        recommendation = _load_recommendation(args.manifest)
    elif not args.method:
        raise RuntimeError(
            f"Manifest not found: {args.manifest}. "
            "Either run after run_all.py or pass --method explicitly."
        )

    method_name = args.method or str(recommendation["method"])
    timesteps = int(args.timesteps or recommendation.get("timesteps", 1) or 1)

    if method_name not in cfg.DOWNSAMPLE_METHODS:
        raise RuntimeError(f"Method {method_name} is not enabled in config.DOWNSAMPLE_METHODS")

    images_uint8, labels = _prepare_split_images(method_name, args.split)
    selected = _pick_indices(labels, args.samples)

    out_dir = os.path.join(args.out_dir, method_name, args.split)
    os.makedirs(out_dir, exist_ok=True)

    manifest = {
        "method": method_name,
        "split": args.split,
        "timesteps": timesteps,
        "pixel_bits": int(cfg.PIXEL_BITS),
        "plane_order": "frame-major, per-frame bit7->bit0 (MSB->LSB), one 64-bit plane per line",
        "samples": [],
    }

    for slot, ds_idx in enumerate(selected):
        label = int(labels[ds_idx].item())
        hex_name = f"sample_{slot:02d}_idx{ds_idx:05d}_label{label}.hex"
        hex_path = os.path.join(out_dir, hex_name)
        lines = _sample_to_planes(images_uint8[ds_idx], timesteps)
        with open(hex_path, "w", encoding="ascii") as f:
            f.write("\n".join(lines) + "\n")
        manifest["samples"].append(
            {
                "slot": slot,
                "dataset_index": int(ds_idx),
                "label": label,
                "hex_path": hex_path,
                "plane_count": len(lines),
            }
        )

    manifest_path = os.path.join(out_dir, "stimulus_manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    print(f"[stimulus] method={method_name} split={args.split} timesteps={timesteps}")
    print(f"[stimulus] samples={len(manifest['samples'])} out_dir={out_dir}")
    print(f"[stimulus] manifest={manifest_path}")


if __name__ == "__main__":
    main()
