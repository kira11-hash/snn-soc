"""
==========================================================
  导出 RRAM 写阵列表 (Scheme B, 差分列)
==========================================================
用途:
  1) 读取训练好的 ANN 权重 (weights/<method>.pt)
  2) 按器件模型做量化 (默认 4-bit)
  3) 导出可给器件/模拟同学使用的写阵列表 CSV
  4) 导出给 RTL/行为模型使用的 weight_pos.hex / weight_neg.hex

输出列:
  row,col_pos,col_neg,level_pos,level_neg,G_pos,G_neg

说明:
  - row: 输入维度索引 i (0..NUM_INPUTS-1)
  - col_pos/col_neg: 输出类别 j 的差分列号
      * grouped(默认, 与 RTL 一致): col_pos=j, col_neg=j+NUM_OUTPUTS
      * interleaved(兼容旧格式):    col_pos=2*j, col_neg=2*j+1
  - level_pos/level_neg: 对应电导级编号
  - G_pos/G_neg: 目标电导值 (单位取决于器件模型, 通常是 S)
"""

import argparse
import csv
import math
import os
from typing import Dict, Tuple

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


def _resolve_diff_columns(j: int, num_outputs: int, col_map: str) -> Tuple[int, int]:
    """根据列映射模式返回 (col_pos, col_neg)。"""
    if col_map == "grouped":
        # 与 RTL Scheme B 一致: 0..N-1 正列, N..2N-1 负列
        return j, j + num_outputs
    if col_map == "interleaved":
        # 兼容历史导出: 偶数列正, 奇数列负
        return 2 * j, 2 * j + 1
    raise ValueError(f"不支持的列映射模式: {col_map}")


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


def _prepare_export_payload(method: str, weight_bits: int, weights_dir: str) -> Dict[str, object]:
    """统一准备导出所需的量化结果与索引。"""
    w = _load_weight_tensor(method=method, weights_dir=weights_dir)
    num_outputs, num_inputs = int(w.shape[0]), int(w.shape[1])
    rows = int(getattr(cfg, "ARRAY_ROWS", 128))
    cols = int(getattr(cfg, "ARRAY_COLS", 256))
    g_pos, g_neg, levels = _quantize_to_conductance(
        w=w, weight_bits=weight_bits, rows=rows, cols=cols
    )
    idx_pos = _nearest_level_index(g_pos, levels).cpu()
    idx_neg = _nearest_level_index(g_neg, levels).cpu()
    return {
        "weights": w.cpu(),
        "num_outputs": num_outputs,
        "num_inputs": num_inputs,
        "rows": rows,
        "cols": cols,
        "g_pos": g_pos.cpu(),
        "g_neg": g_neg.cpu(),
        "levels": levels.cpu(),
        "idx_pos": idx_pos,
        "idx_neg": idx_neg,
    }


def export_weight_map(
    method: str,
    weight_bits: int,
    out_csv: str,
    weights_dir: str,
    col_map: str,
) -> None:
    payload = _prepare_export_payload(
        method=method, weight_bits=weight_bits, weights_dir=weights_dir
    )
    num_outputs = int(payload["num_outputs"])
    num_inputs = int(payload["num_inputs"])
    cols = int(payload["cols"])
    g_pos = payload["g_pos"]
    g_neg = payload["g_neg"]
    levels = payload["levels"]

    # 防误用检查：保证导出列号不会越界物理列数。
    max_col = -1
    for j in range(num_outputs):
        col_pos, col_neg = _resolve_diff_columns(
            j=j, num_outputs=num_outputs, col_map=col_map
        )
        max_col = max(max_col, col_pos, col_neg)
    if max_col >= cols:
        raise RuntimeError(
            f"列映射越界: col_map={col_map}, max_col={max_col}, ARRAY_COLS={cols}. "
            "请检查 NUM_OUTPUTS / ARRAY_COLS / col_map 配置。"
        )

    idx_pos = payload["idx_pos"]
    idx_neg = payload["idx_neg"]

    os.makedirs(os.path.dirname(out_csv) or ".", exist_ok=True)
    with open(out_csv, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(
            ["row", "col_pos", "col_neg", "level_pos", "level_neg", "G_pos", "G_neg"]
        )
        for j in range(num_outputs):
            col_pos, col_neg = _resolve_diff_columns(
                j=j, num_outputs=num_outputs, col_map=col_map
            )
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
    print(f"  col_map={col_map}")
    if col_map == "interleaved":
        print("  [WARN] interleaved 与当前 RTL 默认分组映射不一致，仅用于兼容旧流程。")
    print(f"  权重形状=[{num_outputs}, {num_inputs}]")
    print(f"  电导级数量={int(levels.numel())}")
    print(f"  输出文件={out_csv}")


def _write_hex_levels(level_idx: torch.Tensor, out_hex: str, hex_width: int) -> None:
    """
    按当前 RTL 行优先布局写出 HEX。

    布局顺序：
      index = input_row * NUM_OUTPUTS + output_col
    即：
      row0-col0, row0-col1, ... row0-col9,
      row1-col0, row1-col1, ... row63-col9
    """
    os.makedirs(os.path.dirname(out_hex) or ".", exist_ok=True)
    num_outputs, num_inputs = int(level_idx.shape[0]), int(level_idx.shape[1])
    with open(out_hex, "w", encoding="utf-8") as f:
        for row in range(num_inputs):
            for col in range(num_outputs):
                val = int(level_idx[col, row].item())
                f.write(f"{val:0{hex_width}X}\n")


def export_weight_hex(
    method: str,
    weight_bits: int,
    out_pos_hex: str,
    out_neg_hex: str,
    weights_dir: str,
) -> None:
    """
    导出 RTL / 行为模型可用的差分权重 HEX。

    当前假定布局与已编译行为模型一致：
      - `weight_pos.hex` / `weight_neg.hex`
      - 每个文件 64 * 10 = 640 行
      - 每行一个量化级编号（HEX 文本）
      - 展平顺序：input_row 优先，再 output_col
    """
    payload = _prepare_export_payload(
        method=method, weight_bits=weight_bits, weights_dir=weights_dir
    )
    hex_width = max(1, int(math.ceil(int(weight_bits) / 4.0)))
    _write_hex_levels(payload["idx_pos"], out_pos_hex, hex_width=hex_width)
    _write_hex_levels(payload["idx_neg"], out_neg_hex, hex_width=hex_width)

    print("HEX 导出完成:")
    print(f"  method={method}")
    print(f"  weight_bits={weight_bits}")
    print("  layout=row-major by input_row (index = row * NUM_OUTPUTS + col)")
    print(f"  输出文件(pos)={out_pos_hex}")
    print(f"  输出文件(neg)={out_neg_hex}")


def main():
    parser = argparse.ArgumentParser(description="导出 RRAM 写阵列映射表 (Scheme B)")
    parser.add_argument("--method", type=str, default="proj_sup_64", help="权重文件名(不含 .pt)")
    parser.add_argument("--weight-bits", type=int, default=4, help="权重量化位宽")
    parser.add_argument(
        "--emit",
        type=str,
        choices=["csv", "hex", "both"],
        default="csv",
        help="导出格式：csv、hex 或 both",
    )
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
    parser.add_argument(
        "--out-pos-hex",
        type=str,
        default=None,
        help="输出正权重 HEX 路径，默认 results/weight_pos_<method>_w<bits>.hex",
    )
    parser.add_argument(
        "--out-neg-hex",
        type=str,
        default=None,
        help="输出负权重 HEX 路径，默认 results/weight_neg_<method>_w<bits>.hex",
    )
    parser.add_argument(
        "--col-map",
        type=str,
        choices=["grouped", "interleaved"],
        default="grouped",
        help=(
            "差分列映射: grouped(默认, 与 RTL 一致: pos=0..N-1, neg=N..2N-1) "
            "或 interleaved(兼容旧格式: pos=2*j, neg=2*j+1)"
        ),
    )
    args = parser.parse_args()

    if args.emit in ("csv", "both"):
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
            col_map=args.col_map,
        )

    if args.emit in ("hex", "both"):
        out_pos_hex = args.out_pos_hex
        out_neg_hex = args.out_neg_hex
        if out_pos_hex is None:
            out_pos_hex = os.path.join(
                cfg.RESULTS_DIR, f"weight_pos_{args.method}_w{int(args.weight_bits)}.hex"
            )
        if out_neg_hex is None:
            out_neg_hex = os.path.join(
                cfg.RESULTS_DIR, f"weight_neg_{args.method}_w{int(args.weight_bits)}.hex"
            )
        export_weight_hex(
            method=args.method,
            weight_bits=int(args.weight_bits),
            out_pos_hex=out_pos_hex,
            out_neg_hex=out_neg_hex,
            weights_dir=args.weights_dir,
        )


if __name__ == "__main__":
    main()
