import os
import argparse
import numpy as np
import torch
from torchvision import datasets
import config as cfg
import data_utils


def _to_tensor(images):
    if isinstance(images, torch.Tensor):
        return images
    if isinstance(images, np.ndarray):
        return torch.from_numpy(images)
    raise TypeError("images must be torch.Tensor or numpy.ndarray")


def _flatten_images(images_28x28):
    x = _to_tensor(images_28x28)
    if x.dim() == 4:
        x = x.squeeze(1)
    return x.view(x.shape[0], -1).float() / 255.0


def load_projection_params(method_name, weights_dir=None):
    if weights_dir is None:
        weights_dir = cfg.WEIGHTS_DIR
    path = os.path.join(weights_dir, f"{method_name}_proj_params.pt")
    if not os.path.exists(path):
        raise FileNotFoundError(f"projection params not found: {path}")
    return torch.load(path)


def _scale_features(feat, scale_params):
    method = scale_params.get("method", "minmax")
    if method == "p99":
        max_abs = float(scale_params.get("max_abs", 1.0))
        if max_abs < 1e-6:
            max_abs = 1.0
        scaled = (feat / (2 * max_abs) + 0.5) * 255.0
    else:
        min_v = float(scale_params.get("min", 0.0))
        max_v = float(scale_params.get("max", 1.0))
        rng = max(max_v - min_v, 1e-6)
        scaled = (feat - min_v) / rng * 255.0
    return torch.clamp(scaled, 0, 255).round().byte()


def project_and_quantize(images_28x28, method_name, params=None):
    if params is None:
        params = load_projection_params(method_name)

    x = _flatten_images(images_28x28)
    method = params.get("method")
    if method == "proj_pca":
        mean = params["mean"]
        components = params["components"]
        if params.get("center", True):
            x = x - mean
        feat = x @ components
    elif method == "proj_sup":
        w = params["weight"]
        b = params.get("bias", None)
        feat = x @ w.t()
        if b is not None:
            feat = feat + b
    else:
        raise ValueError(f"unknown projection method: {method}")

    scale_params = params.get("scale_params", {"method": "minmax", "min": 0.0, "max": 1.0})
    return _scale_features(feat, scale_params)


def export_flash_inputs(method_name, split="test", out_path=None, weights_dir=None):
    """
    Export uint8 inputs for a given method/split, aligned with data_utils pipeline.
    """
    split = str(split).lower()
    if split not in ("train", "test"):
        raise ValueError(f"unsupported split: {split}")

    # Reuse the exact preprocessing/splitting logic from data_utils to avoid mismatch.
    all_datasets = data_utils.prepare_all_datasets(quick_mode=False)
    if method_name not in all_datasets:
        raise ValueError(f"method not found in data pipeline: {method_name}")

    ds = all_datasets[method_name]
    if split == "test":
        features = ds["test_images_uint8"].cpu().numpy().astype(np.uint8)
    else:
        # Train split here means the training subset after val split in data_utils.
        train_images = ds.get("train_images_uint8")
        if train_images is None:
            raise ValueError("train_images_uint8 is unavailable in dataset; update data_utils output fields.")
        features = train_images.cpu().numpy().astype(np.uint8)

    if out_path is None:
        out_path = os.path.join(cfg.RESULTS_DIR, f"{method_name}_{split}_uint8.npy")

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    np.save(out_path, features)
    return out_path


def verify_export_consistency(method_name, exported_path, split="test"):
    """
    Verify exported uint8 features exactly match data_utils pipeline output.
    Supports both train/test.
    """
    split = str(split).lower()
    if split not in ("train", "test"):
        raise ValueError(f"unsupported split: {split}")

    all_datasets = data_utils.prepare_all_datasets(quick_mode=False)
    if method_name not in all_datasets:
        raise ValueError(f"method not found in data pipeline: {method_name}")

    if split == "test":
        ref = all_datasets[method_name]["test_images_uint8"].cpu().numpy().astype(np.uint8)
    else:
        train_images = all_datasets[method_name].get("train_images_uint8")
        if train_images is None:
            raise ValueError("train_images_uint8 is unavailable in dataset; update data_utils output fields.")
        ref = train_images.cpu().numpy().astype(np.uint8)
    got = np.load(exported_path).astype(np.uint8)

    if ref.shape != got.shape:
        return False, f"shape mismatch: ref={ref.shape}, exported={got.shape}"
    if not np.array_equal(ref, got):
        diff_idx = np.argwhere(ref != got)
        first = tuple(diff_idx[0].tolist())
        return False, f"byte mismatch at index={first}, ref={ref[first]}, exported={got[first]}"
    return True, "byte-exact match"


def main():
    parser = argparse.ArgumentParser(description="Export 64-dim projected inputs for flash")
    parser.add_argument("--method", required=True, help="proj_pca_64 or proj_sup_64")
    parser.add_argument("--split", default="test", choices=["train", "test"], help="MNIST split")
    parser.add_argument("--out", default=None, help="output .npy path")
    parser.add_argument("--check-consistency", action="store_true",
                        help="verify export is byte-identical to data_utils pipeline output")
    args = parser.parse_args()

    out_path = export_flash_inputs(args.method, split=args.split, out_path=args.out)
    print(f"Saved: {out_path}")
    if args.check_consistency:
        ok, msg = verify_export_consistency(args.method, out_path, split=args.split)
        if ok:
            print(f"Consistency check PASS: {msg}")
        else:
            print(f"Consistency check FAIL: {msg}")
            raise SystemExit(2)


if __name__ == "__main__":
    main()
