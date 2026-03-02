"""
==========================================================
  FPGA 权重导出脚本
==========================================================
用途:
  从训练好的 PyTorch 权重文件导出 .hex 格式的 4-bit 量化权重，
  供 cim_fpga_model.sv 的 $readmemh 加载。

输出:
  weight_pos.hex — 正列权重 [64 rows × 10 cols], 4-bit unsigned (0-F)
  weight_neg.hex — 负列权重 [64 rows × 10 cols], 4-bit unsigned (0-F)
  test_image.hex — (可选) 一张 MNIST 测试图的 bit-plane 编码数据

格式:
  $readmemh 读取顺序: weight[0][0], weight[0][1], ..., weight[0][9],
                       weight[1][0], ..., weight[63][9]
  每行一个 hex 值 (1 位 hex = 4-bit)

用法:
  python export_weights.py [--method proj_sup_64] [--out-dir ../cim_model]
"""

import argparse
import os
import sys
import numpy as np

# Add Python modeling directory to path for imports
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
PYTHON_MODEL_DIR = os.path.normpath(
    os.path.join(PROJECT_ROOT, "项目相关文件", "器件对齐", "Python建模")
)

# Constants matching RTL snn_soc_pkg
NUM_INPUTS = 64
NUM_OUTPUTS = 10
WEIGHT_BITS = 4
NUM_LEVELS = 2 ** WEIGHT_BITS  # 16


def load_weight_tensor(method: str, weights_dir: str):
    """Load weight tensor from PyTorch state dict. Returns numpy array [10, 64]."""
    import torch

    path = os.path.join(weights_dir, f"{method}.pt")
    if not os.path.exists(path):
        raise FileNotFoundError(f"Weight file not found: {path}")

    try:
        state = torch.load(path, map_location="cpu", weights_only=True)
    except TypeError:
        state = torch.load(path, map_location="cpu")

    if isinstance(state, dict) and "fc.weight" in state:
        w = state["fc.weight"]
    elif isinstance(state, dict):
        w = None
        for _, v in state.items():
            if isinstance(v, torch.Tensor) and v.ndim == 2:
                w = v
                break
        if w is None:
            raise RuntimeError(f"No 2D weight tensor found in: {path}")
    else:
        raise RuntimeError(f"Unsupported weight format: {path}")

    w = w.detach().float().cpu().numpy()
    print(f"Loaded weight: shape={w.shape}, range=[{w.min():.4f}, {w.max():.4f}]")
    return w


def quantize_uniform(w_pos, w_neg, num_levels=16):
    """
    Uniform 4-bit quantization for FPGA.
    Maps [0, max_val] → [0, num_levels-1] uniformly.
    """
    max_val = max(w_pos.max(), w_neg.max())
    if max_val == 0:
        return np.zeros_like(w_pos, dtype=int), np.zeros_like(w_neg, dtype=int)

    q_pos = np.round(w_pos / max_val * (num_levels - 1)).astype(int)
    q_neg = np.round(w_neg / max_val * (num_levels - 1)).astype(int)
    q_pos = np.clip(q_pos, 0, num_levels - 1)
    q_neg = np.clip(q_neg, 0, num_levels - 1)
    return q_pos, q_neg


def try_device_quantization(w, weights_dir):
    """
    Try to use the device-aware quantization pipeline from snn_engine.
    Returns (q_pos, q_neg) as integer arrays [10, 64] with values 0-15,
    or None if device model is not available.
    """
    try:
        sys.path.insert(0, PYTHON_MODEL_DIR)
        import config as cfg
        import snn_engine
        import torch

        w_tensor = torch.tensor(w, dtype=torch.float32)
        device_sim = snn_engine._get_plugin_sim(
            rows=cfg.ARRAY_ROWS, cols=cfg.ARRAY_COLS
        )
        if device_sim is None:
            print("[WARN] Device model not available, falling back to uniform quantization")
            return None

        g_pos, g_neg = snn_engine.prepare_conductance_pair_device(
            w_tensor, weight_bits=WEIGHT_BITS, device_sim=device_sim
        )

        # Get level table
        levels = torch.tensor(device_sim.conductance_levels, dtype=torch.float32)
        levels = torch.sort(torch.unique(levels))[0]

        # Map to nearest level index
        def nearest_idx(vals, lvls):
            diff = (vals.unsqueeze(-1) - lvls.view(1, 1, -1)).abs()
            return diff.argmin(dim=-1)

        idx_pos = nearest_idx(g_pos, levels).numpy()
        idx_neg = nearest_idx(g_neg, levels).numpy()

        print(f"Device-aware quantization: {len(levels)} levels")
        print(f"  q_pos range: [{idx_pos.min()}, {idx_pos.max()}]")
        print(f"  q_neg range: [{idx_neg.min()}, {idx_neg.max()}]")
        return idx_pos, idx_neg

    except Exception as e:
        print(f"[WARN] Device quantization failed ({e}), using uniform quantization")
        return None


def write_hex_2d(filepath, data, rows, cols):
    """
    Write 2D weight array to .hex file for $readmemh.
    data[output_j][input_i] → weight[input_i][output_j] in RTL
    So we transpose: file order is weight[0][0..9], weight[1][0..9], ...
    Each line: one hex value (single hex digit for 4-bit).
    """
    with open(filepath, "w") as f:
        for i in range(rows):      # input dimension (0..63)
            for j in range(cols):   # output dimension (0..9)
                val = int(data[j][i])  # data is [outputs, inputs], RTL is [inputs][outputs]
                f.write(f"{val:X}\n")
    print(f"  Written: {filepath} ({rows * cols} entries)")


def export_test_image(out_dir):
    """
    Export one MNIST test image as bit-plane encoded data for TB verification.
    Format: Each line is a 16-hex-digit value (64-bit bit-plane).
    Total lines = TIMESTEPS * PIXEL_BITS (e.g. 3 * 8 = 24 for T=3).
    """
    try:
        sys.path.insert(0, PYTHON_MODEL_DIR)
        import torch
        from torchvision import datasets, transforms

        data_dir = os.path.join(PYTHON_MODEL_DIR, "data")
        test_dataset = datasets.MNIST(
            data_dir, train=False, download=True,
            transform=transforms.ToTensor()
        )

        # Pick first test image
        img, label = test_dataset[0]
        img_np = (img.squeeze().numpy() * 255).astype(np.uint8)  # [28, 28], 0-255
        print(f"\n  Test image: label={label}, shape={img_np.shape}")

        # Apply projection (proj_sup_64)
        proj_path = os.path.join(PYTHON_MODEL_DIR, "weights", "proj_sup_64_proj_params.pt")
        if os.path.exists(proj_path):
            proj_state = torch.load(proj_path, map_location="cpu")
            if "weight" in proj_state:
                proj_w = proj_state["weight"].numpy()  # [64, 784]
            elif "proj_weight" in proj_state:
                proj_w = proj_state["proj_weight"].numpy()
            else:
                # Try first 2D tensor
                proj_w = None
                for _, v in proj_state.items():
                    if isinstance(v, torch.Tensor) and v.ndim == 2:
                        proj_w = v.numpy()
                        break
            if proj_w is not None:
                flat = img_np.flatten().astype(np.float32)  # [784]
                projected = proj_w @ flat  # [64]
                # Scale to [0, 255]
                projected = projected - projected.min()
                if projected.max() > 0:
                    projected = projected / projected.max() * 255
                projected = np.clip(projected, 0, 255).astype(np.uint8)
                print(f"  Projected to 64-dim: range=[{projected.min()}, {projected.max()}]")
            else:
                print("  [WARN] Could not find projection weight, using flat pixels[:64]")
                projected = img_np.flatten()[:64]
        else:
            print(f"  [WARN] Projection file not found: {proj_path}")
            projected = img_np.flatten()[:64]

        # Bit-plane encode: for each timestep, for bit 7 down to 0
        # Each bit-plane is a 64-bit vector: bit[b] of each pixel
        timesteps = 3  # Engineering default
        pixel_bits = 8

        hex_path = os.path.join(out_dir, "test_image.hex")
        label_path = os.path.join(out_dir, "test_label.txt")

        with open(hex_path, "w") as f:
            for t in range(timesteps):
                for b in range(pixel_bits - 1, -1, -1):  # MSB first: 7,6,5,...,0
                    bitmap = np.uint64(0)
                    for i in range(64):
                        if (int(projected[i]) >> b) & 1:
                            bitmap |= np.uint64(1) << np.uint64(i)
                    f.write(f"{int(bitmap):016X}\n")

        with open(label_path, "w") as f:
            f.write(f"{label}\n")

        print(f"  Written: {hex_path} ({timesteps * pixel_bits} bit-planes)")
        print(f"  Written: {label_path} (ground truth: {label})")
        return label

    except Exception as e:
        print(f"  [WARN] Test image export failed: {e}")
        return None


def main():
    parser = argparse.ArgumentParser(description="Export FPGA CIM weights (.hex)")
    parser.add_argument("--method", default="proj_sup_64", help="Weight file name (no .pt)")
    parser.add_argument(
        "--weights-dir", default=None,
        help="Weights directory (default: auto-detect)"
    )
    parser.add_argument(
        "--out-dir", default=None,
        help="Output directory (default: ../cim_model)"
    )
    parser.add_argument(
        "--no-device", action="store_true",
        help="Skip device-aware quantization, use uniform"
    )
    parser.add_argument(
        "--export-image", action="store_true",
        help="Also export a test image for verification"
    )
    args = parser.parse_args()

    # Resolve paths
    if args.weights_dir is None:
        # Try multiple locations
        candidates = [
            os.path.join(PYTHON_MODEL_DIR, "weights_full"),
            os.path.join(PYTHON_MODEL_DIR, "weights"),
        ]
        args.weights_dir = next((d for d in candidates if os.path.isdir(d)), candidates[0])

    if args.out_dir is None:
        args.out_dir = os.path.join(SCRIPT_DIR, "..", "cim_model")

    os.makedirs(args.out_dir, exist_ok=True)
    print(f"=== FPGA Weight Export ===")
    print(f"  Method: {args.method}")
    print(f"  Weights dir: {args.weights_dir}")
    print(f"  Output dir: {args.out_dir}")

    # Load weights [10, 64]
    w = load_weight_tensor(args.method, args.weights_dir)
    assert w.shape == (NUM_OUTPUTS, NUM_INPUTS), \
        f"Expected shape ({NUM_OUTPUTS}, {NUM_INPUTS}), got {w.shape}"

    # Scheme B split: positive/negative
    w_pos = np.maximum(w, 0)   # [10, 64]
    w_neg = np.maximum(-w, 0)  # [10, 64]

    # Quantize to 4-bit (0-15)
    result = None
    if not args.no_device:
        result = try_device_quantization(w, args.weights_dir)

    if result is not None:
        q_pos, q_neg = result
    else:
        print("Using uniform quantization")
        q_pos, q_neg = quantize_uniform(w_pos, w_neg, NUM_LEVELS)
        print(f"  q_pos range: [{q_pos.min()}, {q_pos.max()}]")
        print(f"  q_neg range: [{q_neg.min()}, {q_neg.max()}]")

    # Write .hex files
    print(f"\nWriting hex files:")
    write_hex_2d(
        os.path.join(args.out_dir, "weight_pos.hex"),
        q_pos, NUM_INPUTS, NUM_OUTPUTS
    )
    write_hex_2d(
        os.path.join(args.out_dir, "weight_neg.hex"),
        q_neg, NUM_INPUTS, NUM_OUTPUTS
    )

    # Summary statistics
    print(f"\n=== Weight Statistics ===")
    print(f"  Total weights: {NUM_INPUTS * NUM_OUTPUTS * 2} (pos + neg)")
    print(f"  Non-zero pos: {np.count_nonzero(q_pos)} / {q_pos.size}")
    print(f"  Non-zero neg: {np.count_nonzero(q_neg)} / {q_neg.size}")
    print(f"  Sparsity: {1 - (np.count_nonzero(q_pos) + np.count_nonzero(q_neg)) / (q_pos.size + q_neg.size):.1%}")

    # Optional: export test image
    if args.export_image:
        print(f"\n=== Test Image Export ===")
        export_test_image(args.out_dir)

    print("\nDone!")


if __name__ == "__main__":
    main()
