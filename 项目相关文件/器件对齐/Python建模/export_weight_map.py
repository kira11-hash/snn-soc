"""
==========================================================
  导出 RRAM 写阵列表 (Scheme B, 差分列)
==========================================================
用途:
  1) 读取训练好的 ANN 权重 (weights/<method>.pt)
  2) 按器件模型做量化 (默认 4-bit)
  3) 导出可给器件/模拟同学使用的写阵列表 CSV

输出列:
  row,col_pos,col_neg,level_pos,level_neg,G_pos,G_neg

说明:
  - row: 输入维度索引 i (0..NUM_INPUTS-1)
  - col_pos/col_neg: 输出类别 j 的差分列号 (2*j, 2*j+1)
  - level_pos/level_neg: 对应电导级编号
  - G_pos/G_neg: 目标电导值 (单位取决于器件模型, 通常是 S)
"""

import argparse
import csv
import os
from typing import Tuple

import torch

import config as cfg
import snn_engine


def _load_weight_tensor(method: str, weights_dir: str) -> torch.Tensor:
    """从 state_dict 中提取 fc.weight，返回 [num_outputs, num_inputs]。"""
    path = os.path.join(weights_dir, f"{method}.pt")
    if not os.path.exists(path):
        raise FileNotFoundError(f"未找到权重文件: {path}")

    try:
        state = torch.load(path, map_location="cpu", weights_only=True)
    except TypeError:
        state = torch.load(path, map_location="cpu")

    if isinstance(state, dict) and "fc.weight" in state:
        w = state["fc.weight"]
    elif isinstance(state, dict):
        # 兼容非标准 key 命名: 找到第一项二维张量作为权重
        w = None
        for _, v in state.items():
            if isinstance(v, torch.Tensor) and v.ndim == 2:
                w = v
                break
        if w is None:
            raise RuntimeError(f"权重文件中找不到二维权重张量: {path}")
    else:
        raise RuntimeError(f"不支持的权重文件格式: {path}")

    return w.detach().float().cpu()


def _get_level_table(device_sim, weight_bits: int, use_plugin_levels_4bit: bool) -> torch.Tensor:
    """
    构造电导级表:
      - 4-bit 且允许时，优先使用器件离散级
      - 其他情况，在线性区间 [g_min, g_max] 生成 2^bits 级
    """
    if weight_bits == 4 and use_plugin_levels_4bit:
        levels = torch.tensor(device_sim.conductance_levels, dtype=torch.float32)
        levels = torch.sort(torch.unique(levels))[0]
        if levels.numel() < 2:
            raise RuntimeError("器件离散电导级数量异常，无法导出映射")
        return levels

    num_levels = 2 ** int(weight_bits)
    g_min = float(device_sim.conductance_model.g_min)
    g_max = float(device_sim.conductance_model.g_max)
    if g_max <= g_min:
        raise RuntimeError(f"器件导电范围异常: g_min={g_min}, g_max={g_max}")
    return torch.linspace(g_min, g_max, steps=num_levels, dtype=torch.float32)


def _nearest_level_index(values: torch.Tensor, levels: torch.Tensor) -> torch.Tensor:
    """把 values 映射到最近的 level 索引。"""
    diff = (values.unsqueeze(-1) - levels.view(1, 1, -1)).abs()
    return diff.argmin(dim=-1)


def _quantize_to_conductance(
    w: torch.Tensor, weight_bits: int, rows: int, cols: int
) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    """
    使用 snn_engine 现有器件量化链路，得到 G_pos/G_neg 和 level 表。
    """
    device_sim = snn_engine._get_plugin_sim(rows=rows, cols=cols)
    if device_sim is None:
        raise RuntimeError(
            "器件模型不可用，无法导出物理写阵列表。请先检查 MEMRISTOR_PLUGIN_PATH 与 IV_DATA_PATH。"
        )

    g_pos, g_neg = snn_engine.prepare_conductance_pair_device(
        w, weight_bits=weight_bits, device_sim=device_sim
    )
    levels = _get_level_table(
        device_sim=device_sim,
        weight_bits=weight_bits,
        use_plugin_levels_4bit=bool(getattr(cfg, "PLUGIN_LEVELS_FOR_4BIT", True)),
    )
    return g_pos.cpu(), g_neg.cpu(), levels.cpu()


def export_weight_map(
    method: str,
    weight_bits: int,
    out_csv: str,
    weights_dir: str,
) -> None:
    w = _load_weight_tensor(method=method, weights_dir=weights_dir)
    num_outputs, num_inputs = int(w.shape[0]), int(w.shape[1])

    rows = int(getattr(cfg, "ARRAY_ROWS", 128))
    cols = int(getattr(cfg, "ARRAY_COLS", 256))
    g_pos, g_neg, levels = _quantize_to_conductance(
        w=w, weight_bits=weight_bits, rows=rows, cols=cols
    )

    idx_pos = _nearest_level_index(g_pos, levels)
    idx_neg = _nearest_level_index(g_neg, levels)

    os.makedirs(os.path.dirname(out_csv) or ".", exist_ok=True)
    with open(out_csv, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(
            ["row", "col_pos", "col_neg", "level_pos", "level_neg", "G_pos", "G_neg"]
        )
        for j in range(num_outputs):
            col_pos = 2 * j
            col_neg = 2 * j + 1
            for i in range(num_inputs):
                writer.writerow(
                    [
                        i,
                        col_pos,
                        col_neg,
                        int(idx_pos[j, i].item()),
                        int(idx_neg[j, i].item()),
                        float(g_pos[j, i].item()),
                        float(g_neg[j, i].item()),
                    ]
                )

    print("导出完成:")
    print(f"  method={method}")
    print(f"  weight_bits={weight_bits}")
    print(f"  权重形状=[{num_outputs}, {num_inputs}]")
    print(f"  电导级数量={int(levels.numel())}")
    print(f"  输出文件={out_csv}")


def main():
    parser = argparse.ArgumentParser(description="导出 RRAM 写阵列映射表 (Scheme B)")
    parser.add_argument("--method", type=str, default="proj_sup_64", help="权重文件名(不含 .pt)")
    parser.add_argument("--weight-bits", type=int, default=4, help="权重量化位宽")
    parser.add_argument(
        "--weights-dir",
        type=str,
        default=cfg.WEIGHTS_DIR,
        help="权重目录，默认读取 config.WEIGHTS_DIR",
    )
    parser.add_argument(
        "--out",
        type=str,
        default=None,
        help="输出 CSV 路径，默认 results/weight_map_<method>_w<bits>.csv",
    )
    args = parser.parse_args()

    out_csv = args.out
    if out_csv is None:
        out_csv = os.path.join(
            cfg.RESULTS_DIR, f"weight_map_{args.method}_w{int(args.weight_bits)}.csv"
        )

    export_weight_map(
        method=args.method,
        weight_bits=int(args.weight_bits),
        out_csv=out_csv,
        weights_dir=args.weights_dir,
    )


if __name__ == "__main__":
    main()

