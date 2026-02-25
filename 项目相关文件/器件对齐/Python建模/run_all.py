# 统一章节化注释模板：每个函数均固定为 输入 / 处理 / 输出 / 为什么 四段。
"""
run_all.py 第三版教学导读（总调度脚本）
本文件采用统一注释风格：所有函数固定为“输入/处理/输出/为什么”四段。
使用建议：先读注释理解思路，再对照代码行走读执行路径。
本次修改只增强注释可读性，不改变任何运行逻辑。
"""

# `sys`：和解释器、终端输入输出相关（这里主要用于设置 stdout/stderr 编码）。
import sys
# `os`：文件路径、目录创建等操作。
import os
# `argparse`：解析命令行参数（例如 `--quick`、`--skip-train`）。
import argparse
# `time`：统计总运行时长。
import time
# `random`：Python 内置随机库（用于可复现实验）。
import random
# `torch`：PyTorch 主库，负责张量、模型与推理。
import torch
# `numpy`：数值计算库，这里主要用于均值/方差统计和数组操作。
import numpy as np

# 统一终端输出编码，尽量避免系统控制台把中文打印成乱码。
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# 使用无图形后端，即使没有桌面环境也能保存图片文件。
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# 导入项目内部模块（配置、数据、训练、推理引擎）。
import config as cfg
import data_utils
import train_ann
import snn_engine


# =====================================================
#  辅助函数
# =====================================================

def setup_chinese_font():
    """
    输入：
    - 无显式输入参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `setup_chinese_font` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    try:
        plt.rcParams['font.sans-serif'] = ['SimHei', 'Microsoft YaHei',
                                           'DejaVu Sans']
        plt.rcParams['axes.unicode_minus'] = False
        return True
    except Exception:
        return False


def progress_bar(current, total, prefix='', suffix='', length=40):
    """
    输入：
    - `current`：由调用方传入的业务数据或控制参数。
    - `total`：由调用方传入的业务数据或控制参数。
    - `prefix`：由调用方传入的业务数据或控制参数。
    - `suffix`：由调用方传入的业务数据或控制参数。
    - `length`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `progress_bar` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    percent = current / total
    filled = int(length * percent)
    bar = '#' * filled + '-' * (length - filled)
    sys.stdout.write(f'\r  {prefix} |{bar}| {percent:.0%} {suffix}')
    sys.stdout.flush()
    if current == total:
        print()


def set_global_seed(seed):
    """
    输入：
    - `seed`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `set_global_seed` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)



def calibrate_threshold_ratio(ds, W, adc_bits=8, weight_bits=4,
                              timesteps=1, scheme='A'):
    """
    输入：
    - `ds`：由调用方传入的业务数据或控制参数。
    - `W`：由调用方传入的业务数据或控制参数。
    - `adc_bits`：由调用方传入的业务数据或控制参数。
    - `weight_bits`：由调用方传入的业务数据或控制参数。
    - `timesteps`：由调用方传入的业务数据或控制参数。
    - `scheme`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `calibrate_threshold_ratio` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    # `getattr(obj, name, default)` 是 Python 常见写法：
    # 如果配置里没有该字段，就回退到 `default`，避免程序报错。
    if not getattr(cfg, 'CALIBRATE_THRESHOLD_RATIO', False):
        return None, None

    # 候选阈值列表，典型如 [0.3, 0.4, ..., 0.8]
    candidates = list(getattr(cfg, 'THRESHOLD_RATIO_CANDIDATES', []))
    if not candidates:
        return None, None

    n = int(getattr(cfg, 'THRESHOLD_CALIBRATE_SAMPLES', 0) or 0)
    # `dict.get(key)` 的特点：key 不存在时返回 None，不会抛异常。
    images_src = ds.get("val_images_uint8")
    labels_src = ds.get("val_labels")
    if images_src is None or labels_src is None:
        return None, None
    n = min(n, int(labels_src.shape[0]))
    if n <= 0:
        return None, None

    # 固定随机种子后再打乱抽样，避免只取前若干条样本带来顺序偏差。
    gen = torch.Generator().manual_seed(int(getattr(cfg, "RANDOM_SEED", 42)) + 20260207)
    perm = torch.randperm(int(labels_src.shape[0]), generator=gen)[:n]
    images = images_src[perm]
    labels = labels_src[perm]

    # 初始化“当前最优”记录，后面进入“遍历比较”模式。
    best_ratio = None
    best_acc = -1.0
    for ratio in candidates:
        acc, _ = snn_engine.snn_inference(
            images, labels, W,
            adc_bits=adc_bits, weight_bits=weight_bits, timesteps=timesteps,
            scheme=scheme, decision='spike', threshold_ratio=ratio
        )
        if acc > best_acc:
            best_acc = acc
            best_ratio = ratio

    return best_ratio, best_acc


def _get_split_tensors(ds, split_name):
    """
    输入：
    - `ds`：由调用方传入的业务数据或控制参数。
    - `split_name`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_get_split_tensors` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    # `str(...).lower()`：把输入统一转成小写字符串，减少大小写歧义。
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
    输入：
    - `metric_dict`：由调用方传入的业务数据或控制参数。
    - `margin`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_pick_min_within_margin` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    # `metric_dict.items()` 会得到 (key, value) 对；
    # `sorted(..., key=lambda kv: kv[0])` 表示按 key 升序排序。
    items = sorted(metric_dict.items(), key=lambda kv: kv[0])
    if not items:
        raise ValueError("metric_dict is empty")
    best = max(v for _, v in items)
    target = best - margin
    candidates = [k for k, v in items if v >= target]
    return min(candidates) if candidates else items[-1][0]


def _resolve_eval_schemes():
    """
    输入：
    - 无显式输入参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_resolve_eval_schemes` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    schemes = list(getattr(cfg, "EVAL_SCHEMES", ["A", "B"]))
    if not schemes:
        schemes = ["B"]
    schemes = [str(s).upper() for s in schemes]
    # 若配置明确不允许 A，则在评估列表中去掉 A。
    if not bool(getattr(cfg, "ALLOW_SIGNED_SCHEME_A", False)):
        schemes = [s for s in schemes if s != "A"]
        if not schemes:
            schemes = ["B"]
    primary = str(getattr(cfg, "PRIMARY_SCHEME", schemes[0])).upper()
    if primary == "A" and not bool(getattr(cfg, "ALLOW_SIGNED_SCHEME_A", False)):
        primary = "B"
    # 防止主方案不在候选里：若缺失，则把主方案插到列表最前。
    if primary not in schemes:
        schemes = [primary] + [s for s in schemes if s != primary]
    return schemes, primary


def _combo_cost_key(item, primary_scheme):
    """
    输入：
    - `item`：由调用方传入的业务数据或控制参数。
    - `primary_scheme`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_combo_cost_key` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
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
#  步骤 2：训练连续网络（或加载已有权重）
# =====================================================

def run_training(all_datasets, skip_train=False, quick=False):
    """
    输入：
    - `all_datasets`：由调用方传入的业务数据或控制参数。
    - `skip_train`：由调用方传入的业务数据或控制参数。
    - `quick`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `run_training` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    print("\n[步骤 2/4] 训练连续网络（获取 float 权重）...")

    # 三元表达式：`A if 条件 else B`
    # quick 模式下使用更少轮次，目的是节省时间做流程联调。
    epochs = cfg.QUICK_EPOCHS if quick else cfg.ANN_EPOCHS
    # 统一结果容器：后续画图和文字总结都从这里读取。
    results = {}

    # `all_datasets` 是一个“字典套字典”结构，典型形态如下：
    # {
    #   "bilinear_8x8": {
    #       "input_dim": 64,
    #       "train_loader": ...,
    #       "test_loader_float": ...,
    #       ...
    #   },
    #   ...
    # }
    # 这里 `.items()` 会同时拿到键和值：`name` 是方法名，`ds` 是该方法的数据包。
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
                # 这里只捕获“文件不存在”这个常见场景。
                # 捕获后不终止程序，而是自动回退到“重新训练”。
                print(f"  {name}: 未找到已保存权重，转为重新训练。")

        # 从头训练一个模型，返回模型对象和每轮训练损失。
        model, history = train_ann.train_model(
            ds["train_loader"], ds["input_dim"], epochs=epochs
        )

        # 可选量化感知微调：在量化与噪声代理约束下继续训练几轮。
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

        # 训练完成后，先做普通 float 精度评估。
        acc = train_ann.evaluate_model(model, ds["test_loader_float"])
        if getattr(cfg, 'QAT_ENABLE', False):
            # 若启用 QAT，再额外评估“按量化方式推理”的精度。
            quant_acc = train_ann.evaluate_model(
                model, ds["test_loader_float"],
                quantized=True,
                weight_bits=cfg.QAT_WEIGHT_BITS,
                noise_std=cfg.QAT_NOISE_STD if cfg.QAT_NOISE_ENABLE else 0.0,
                ir_drop_coeff=cfg.QAT_IR_DROP_COEFF
            )
        # 抽取线性层权重矩阵，供后面的 SNN 推理直接使用。
        W = train_ann.get_weights(model)
        # 同时把完整模型参数保存成 .pt，便于之后 `--skip-train` 复用。
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
    输入：
    - `all_datasets`：由调用方传入的业务数据或控制参数。
    - `training_results`：由调用方传入的业务数据或控制参数。
    - `quick`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `run_parameter_sweep` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    print("\n[步骤 3/4] SNN 推理 + 参数扫描...")

    # =====================================================
    # 教学总览：这个函数的“输入 -> 处理 -> 输出”
    # 输入：
    # - all_datasets：每种输入方法对应的数据包（图像、标签、维度等）
    # - training_results：每种方法训练得到的权重与精度
    # - quick：是否快速模式（影响噪声试验次数）
    #
    # 处理：
    # - 按配置过滤方法、标定阈值、全网格扫描、筛选推荐配置
    # - 对推荐配置做最终集评估和多随机种子稳定性统计
    #
    # 输出：
    # - results：完整结构化结果（给画图和 summary 用）
    # - best_method：推荐方法名（后续图表默认用它）
    # =====================================================

    # 这几行读取“本轮评估口径”：
    # - tune_split：用于调参和选配置（通常是 val）
    # - final_split：用于最终一次报告（通常是 test）
    # - target_input_dim：只评估目标维度的方法（0 表示不限制）
    tune_split = str(getattr(cfg, "TUNE_SPLIT", "val")).lower()
    final_split = str(getattr(cfg, "FINAL_REPORT_SPLIT", "test")).lower()
    target_input_dim = int(getattr(cfg, "TARGET_INPUT_DIM_FOR_RECOMMEND", 0) or 0)
    schemes, primary_scheme = _resolve_eval_schemes()
    default_ratio = float(getattr(cfg, "SPIKE_THRESHOLD_RATIO", 0.6))

    # `results` 是本函数唯一“官方输出容器”。
    # 新手阅读建议：后续每个阶段都会往这个字典里写入一个子字段。
    results = {
        "downsample": {},       # 各输入方法的基线结果（调参集）
        "adc_sweep": {},        # 模数位宽扫描结果（调参集）
        "weight_sweep": {},     # 权重量化位宽扫描结果（调参集）
        "timestep_sweep": {},   # 时间步扫描结果（调参集）
        "full_grid": [],        # 全组合扫描记录
        "full_grid_top": [],    # 精度前若干组合
        "best_case": {},        # 单纯按精度最高的组合
        "noise_impact": {},     # 非理想噪声影响统计
        "scheme_compare": {},   # 差分方案对比
        "decision_compare": {}, # 决策规则对比
        "adaptive": {},         # 固定阈值与自适应阈值对比
        "threshold_calibration": {},  # 每种方法/方案的阈值标定结果
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
        "final_test_best_case": {},
        "multi_seed": {},
    }

    # ===== 阶段 0：方法筛选 =====
    # 输入：all_datasets + target_input_dim + tune_split
    # 动作：仅保留“维度满足要求、且存在指定 split 数据”的方法
    # 产出：eligible_methods（后续所有扫描都只在这个列表上进行）
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

    # 保护性检查：没有可用方法时立即停止，避免后续报错更难定位。
    if not eligible_methods:
        raise RuntimeError(
            f"No eligible methods for tuning split='{tune_split}' and target_input_dim={target_input_dim}"
        )

    print(
        f"  Tuning on split='{tune_split}', final report on split='{final_split}', "
        f"primary scheme={primary_scheme}, methods={len(eligible_methods)}"
    )

    # ===== 阶段 3a：理想一致性检查 =====
    # 输入：eligible_methods + 对应权重
    # 动作：跑理想 SNN 推理（不加硬件非理想）
    # 产出：终端日志（sanity check，不写入核心推荐逻辑）
    print(f"\n  [3a] 验证理想推理一致性 (split={tune_split})...")
    for name in eligible_methods:
        ds = all_datasets[name]
        images_eval, labels_eval = _get_split_tensors(ds, tune_split)
        W = training_results[name]["weights"]
        # `snn_inference_ideal`：理想算子口径（不含硬件非理想），用于一致性 sanity check。
        ideal_acc = snn_engine.snn_inference_ideal(images_eval, labels_eval, W, timesteps=1)
        print(f"    {name:20s}: SNN(ideal)={ideal_acc:.2%}")

    # ===== 阶段 3b-0：阈值比例标定 =====
    # 输入：eligible_methods、schemes、候选阈值列表
    # 动作：对每个“方法-方案”独立标定 threshold_ratio
    # 产出：
    # - method_ratio[method][scheme]：后续推理统一读取这个阈值
    # - results["threshold_calibration"]：写入报告的标定明细
    method_ratio = {name: {} for name in eligible_methods}
    if getattr(cfg, "CALIBRATE_THRESHOLD_RATIO", False):
        print(f"\n  [3b-0] 阈值比例标定 (split={tune_split}, 按方法/按方案)...")
        for name in eligible_methods:
            ds = all_datasets[name]
            W = training_results[name]["weights"]
            results["threshold_calibration"][name] = {}
            for scheme in schemes:
                ratio, ratio_acc = calibrate_threshold_ratio(
                    ds, W, adc_bits=8, weight_bits=4, timesteps=1, scheme=scheme
                )
                # 标定失败时回退全局默认阈值，保证流程不中断。
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

    # ===== 阶段 3b：输入方法横向对比 =====
    # 输入：eligible_methods + 主方案 primary_scheme + 各自阈值
    # 动作：在统一硬件口径（8/4/1）下比较不同方法
    # 产出：results["downsample"]，用于后续“方法维度”图和摘要
    print(f"\n  [3b] 输入方法对比 (split={tune_split}, scheme={primary_scheme})...")
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

    # 从基线口径结果中选出当前最佳输入方法（仅用于显示与对照）。
    downsample_best_method = max(results["downsample"], key=lambda k: results["downsample"][k]["snn_acc"])
    downsample_best_ratio = results["downsample"][downsample_best_method]["threshold_ratio"]
    print(
        f"\n  最佳方法 (基线 8/4/1, {tune_split}): {downsample_best_method} "
        f"(SNN={results['downsample'][downsample_best_method]['snn_acc']:.2%}, ratio={downsample_best_ratio:.2f})"
    )

    # ===== 阶段 3b-1：全组合穷举扫描（最核心） =====
    # 输入：eligible_methods × schemes × ADC_BITS_SWEEP × WEIGHT_BITS_SWEEP × TIMESTEPS_SWEEP
    # 动作：把所有组合都跑一遍并记录精度
    # 产出：results["full_grid"]（完整组合表）
    print(f"\n  [3b-1] 全量组合扫描 (split={tune_split})...")
    # 组合总数 = 方法数 × 方案数 × 各扫描维度候选数（用于进度条显示）。
    grid_total = (
        len(eligible_methods)
        * len(schemes)
        * len(cfg.ADC_BITS_SWEEP)
        * len(cfg.WEIGHT_BITS_SWEEP)
        * len(cfg.TIMESTEPS_SWEEP)
    )
    grid_idx = 0
    # 五层循环 = method × scheme × ADC × weight_bits × timesteps。
    # 这就是“穷举扫描”：实现简单且不漏组合。
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
                        # 每个组合都记成一条结构化记录，便于后续排序和生成报告。
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
                        progress_bar(grid_idx, grid_total, prefix="全量组合")

    if not results["full_grid"]:
        raise RuntimeError("full-grid sweep produced no records")

    # ===== 阶段 3b-2：从全组合中挑选 best-case 与 recommendation =====
    # best-case：只看精度最高，不看实现成本。
    best_case = max(results["full_grid"], key=lambda x: x["snn_acc"])
    # `margin` 是“可接受精度损失”门限（例如 0.5%）。
    margin = float(getattr(cfg, "RECOMMEND_ACC_MARGIN", 0.005))
    acc_floor = float(best_case["snn_acc"]) - margin
    near_best = [x for x in results["full_grid"] if float(x["snn_acc"]) >= acc_floor]
    if not near_best:
        near_best = [best_case]
    # recommendation：在“精度足够接近 best-case”前提下，优先低成本。
    recommendation = min(near_best, key=lambda x: _combo_cost_key(x, primary_scheme))

    # 额外保留 Top-K 组合，便于后续工程权衡和复盘。
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
        f"    最佳 (best-case): method={best_case['method']}, scheme={best_case['scheme']}, "
        f"ADC={best_case['adc_bits']}, W={best_case['weight_bits']}, T={best_case['timesteps']}, "
        f"ratio={best_case['threshold_ratio']:.2f}, acc={best_case['snn_acc']:.2%}"
    )
    print(
        f"    推荐 (low-cost, within {margin:.2%}): method={recommendation['method']}, "
        f"scheme={recommendation['scheme']}, ADC={recommendation['adc_bits']}, "
        f"W={recommendation['weight_bits']}, T={recommendation['timesteps']}, "
        f"ratio={recommendation['threshold_ratio']:.2f}, acc={recommendation['snn_acc']:.2%}"
    )

    # ===== 阶段 3c~3e：单维扫描（趋势图） =====
    # 统一固定“推荐方法 + 推荐阈值 + 主方案”，只改变一个维度观察趋势。
    best_method = recommendation["method"]
    best_ratio = recommendation["threshold_ratio"]
    best_ds = all_datasets[best_method]
    best_W = training_results[best_method]["weights"]
    best_images_tune, best_labels_tune = _get_split_tensors(best_ds, tune_split)

    # [3c 输入] 推荐方法数据、推荐阈值
    # [3c 动作] 逐个 ADC 位宽推理
    # [3c 产出] results["adc_sweep"]
    print(f"\n  [3c] ADC 位宽扫描 (split={tune_split}, {best_method})...")
    for adc in cfg.ADC_BITS_SWEEP:
        acc, _ = snn_engine.snn_inference(
            best_images_tune, best_labels_tune, best_W,
            adc_bits=adc, weight_bits=4, timesteps=1,
            scheme=primary_scheme, threshold_ratio=best_ratio
        )
        results["adc_sweep"][adc] = acc
        print(f"    ADC={adc:2d}-bit: {acc:.2%}")

    # [3d 输入] 推荐方法数据、推荐阈值
    # [3d 动作] 逐个权重量化位宽推理
    # [3d 产出] results["weight_sweep"]
    print(f"\n  [3d] 权重位宽扫描 (split={tune_split}, {best_method})...")
    for wb in cfg.WEIGHT_BITS_SWEEP:
        acc, _ = snn_engine.snn_inference(
            best_images_tune, best_labels_tune, best_W,
            adc_bits=8, weight_bits=wb, timesteps=1,
            scheme=primary_scheme, threshold_ratio=best_ratio
        )
        results["weight_sweep"][wb] = acc
        print(f"    W={wb}-bit: {acc:.2%}")

    # [3e 输入] 推荐方法数据、推荐阈值
    # [3e 动作] 逐个时间步推理
    # [3e 产出] results["timestep_sweep"]
    print(f"\n  [3e] 推理帧数扫描 (split={tune_split}, {best_method})...")
    for ts in cfg.TIMESTEPS_SWEEP:
        acc, _ = snn_engine.snn_inference(
            best_images_tune, best_labels_tune, best_W,
            adc_bits=8, weight_bits=4, timesteps=ts,
            scheme=primary_scheme, threshold_ratio=best_ratio
        )
        results["timestep_sweep"][ts] = acc
        print(f"    T={ts:2d}: {acc:.2%}")

    # ===== 阶段 3f：器件非理想影响评估 =====
    # 输入：推荐配置
    # 动作：重复多次 add_noise=True 推理，统计均值和标准差
    # 产出：results["noise_impact"]
    print(f"\n  [3f] 器件非理想影响 (split={tune_split}, {best_method})...")
    # 噪声试验通常需要重复多次取统计值（均值、标准差）。
    n_trials = cfg.NOISE_TRIALS_QUICK if quick else cfg.NOISE_TRIALS_FULL
    noise_accs = []
    for trial in range(n_trials):
        acc, _ = snn_engine.snn_inference(
            best_images_tune, best_labels_tune, best_W,
            adc_bits=8, weight_bits=4, timesteps=1, add_noise=True,
            scheme=primary_scheme, threshold_ratio=best_ratio
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
    print(f"    含噪:   {noise_mean:.2%} +/- {noise_std:.4f}")
    print(f"    退化:   {results['noise_impact']['degradation']:.2%}")

    # ===== 阶段 3g：方案对比 =====
    # 输入：推荐方法 + 所有候选方案
    # 动作：每个方案使用“自己的标定阈值”推理一次
    # 产出：results["scheme_compare"]
    print(f"\n  [3g] 差分方案对比 (split={tune_split}, {best_method})...")
    for scheme in schemes:
        ratio = method_ratio[best_method].get(scheme, default_ratio)
        acc, _ = snn_engine.snn_inference(
            best_images_tune, best_labels_tune, best_W,
            adc_bits=8, weight_bits=4, timesteps=1,
            scheme=scheme, threshold_ratio=ratio
        )
        results["scheme_compare"][scheme] = acc
        print(f"    方案 {scheme}: {acc:.2%} (ratio={ratio:.2f})")

    # ===== 阶段 3h：决策规则对比 =====
    # 输入：推荐方法 + 主方案
    # 动作：对比 spike 与 membrane 两种决策规则
    # 产出：results["decision_compare"]
    print(f"\n  [3h] 决策规则对比 (split={tune_split}, {best_method})...")
    for decision in ["spike", "membrane"]:
        acc, _ = snn_engine.snn_inference(
            best_images_tune, best_labels_tune, best_W,
            adc_bits=8, weight_bits=4, timesteps=1, decision=decision,
            scheme=primary_scheme, threshold_ratio=best_ratio
        )
        results["decision_compare"][decision] = acc
        print(f"    decision={decision:8s}: {acc:.2%}")

    # ===== 阶段 3i：阈值策略对比 =====
    # 输入：推荐方法 + 主方案
    # 动作：固定阈值 与 自适应阈值各跑一次
    # 产出：results["adaptive"]
    print(f"\n  [3i] 阈值策略对比 (split={tune_split}, {best_method})...")
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
    # 记录固定阈值与自适应阈值的差异，后面 summary 会据此给推荐结论。
    results["adaptive"] = {
        "fixed": fixed_acc,
        "adaptive": adaptive_acc,
        "improvement": adaptive_acc - fixed_acc,
        "split": tune_split,
    }
    print(f"    固定阈值(spike):   {fixed_acc:.2%}")
    print(f"    自适应阈值(spike): {adaptive_acc:.2%}")
    print(f"    提升: {results['adaptive']['improvement']:+.2%}")

    # ===== 阶段 3j：固化推荐配置 =====
    # 输入：results["recommendation"]（来自全组合筛选）
    # 动作：提取 method/ratio/ADC/W/T/scheme 到局部变量
    # 产出：后续 final 测试与多 seed 复跑的统一配置
    # `dict(...)` 是浅拷贝，避免直接改动原对象时产生联动副作用。
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
        f"\n  推荐配置 (基于 {tune_split}): "
        f"method={best_method}, scheme={primary_scheme}, "
        f"ADC={best_adc}, W={best_wb}, T={best_ts}, ratio={best_ratio:.2f}"
    )

    # ===== 阶段 3k：最终报告集评估 =====
    # 在 final_split 上跑一次推荐配置，作为对外主口径结果。
    final_images, final_labels = _get_split_tensors(best_ds, final_split)
    final_acc, _ = snn_engine.snn_inference(
        final_images, final_labels, best_W,
        adc_bits=best_adc, weight_bits=best_wb, timesteps=best_ts,
        scheme=primary_scheme, threshold_ratio=best_ratio
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
    print(f"  Final {final_split} 一次评估: {final_acc:.2%}")

    # 额外评估 best-case 在 final_split 上的表现，帮助理解精度上限。
    best_case_cfg = dict(results.get("best_case", {}))
    if best_case_cfg:
        best_case_method = best_case_cfg["method"]
        best_case_ds = all_datasets[best_case_method]
        best_case_W = training_results[best_case_method]["weights"]
        best_case_images, best_case_labels = _get_split_tensors(best_case_ds, final_split)
        best_case_final_acc, _ = snn_engine.snn_inference(
            best_case_images, best_case_labels, best_case_W,
            adc_bits=int(best_case_cfg["adc_bits"]),
            weight_bits=int(best_case_cfg["weight_bits"]),
            timesteps=int(best_case_cfg["timesteps"]),
            scheme=str(best_case_cfg["scheme"]).upper(),
            threshold_ratio=float(best_case_cfg["threshold_ratio"])
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
        print(f"  Final {final_split} best-case 评估: {best_case_final_acc:.2%}")

    # ===== 阶段 3l：多随机种子复跑（稳定性）=====
    # 输入：推荐配置 + seed 列表
    # 动作：每个 seed 各跑 clean/noisy 两次
    # 产出：results["multi_seed"]（均值与标准差）
    seed_list = [int(s) for s in getattr(cfg, "FINAL_MULTI_SEEDS", [])]
    if seed_list:
        clean_accs = []
        noisy_accs = []
        print(f"\n  [3l] 固定配置多seed复跑 ({len(seed_list)} seeds)...")
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
        # 多种子复跑完成后，恢复为配置文件中的默认随机种子。
        set_global_seed(cfg.RANDOM_SEED)
        results["multi_seed"] = {
            "seeds": seed_list,
            "clean_mean": float(np.mean(clean_accs)),
            "clean_std": float(np.std(clean_accs)),
            "noisy_mean": float(np.mean(noisy_accs)),
            "noisy_std": float(np.std(noisy_accs)),
            "split": final_split,
        }

    # 收尾：记录器件后端状态，方便 summary 报告展示。
    results["device_backend"] = snn_engine.get_device_backend_status()
    # 返回值说明：
    # - results：本函数完整产出
    # - best_method：推荐方法名（供后续画图标题使用）
    return results, best_method


# =====================================================
#  步骤 4: 生成图表 + 输出推荐
# =====================================================

def generate_plots(results, training_results, best_method):
    """
    输入：
    - `results`：由调用方传入的业务数据或控制参数。
    - `training_results`：由调用方传入的业务数据或控制参数。
    - `best_method`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `generate_plots` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    print("\n[步骤 4/4] 生成结果图表...")
    # `exist_ok=True`：目录存在时不报错，适合重复运行脚本。
    os.makedirs(cfg.RESULTS_DIR, exist_ok=True)

    # 尝试启用中文字体；即便失败也不影响出图流程。
    has_chinese = setup_chinese_font()

    # ---- 图1：不同输入方法对比 ----
    # `fig` 是整张图，`ax` 是坐标轴对象，后续所有绘图都在 ax 上操作。
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
    # `dpi` 越高图越清晰，但文件也会更大。
    plt.savefig(os.path.join(cfg.RESULTS_DIR, 'fig1_downsample_comparison.png'),
                dpi=150)
    plt.close()
    print("  fig1_downsample_comparison.png")

    # ---- 图2：模数位宽扫描 ----
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

    # ---- 图3：权重量化位宽扫描 ----
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

    # ---- 图4：时间步扫描 ----
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

    # ---- 图5：器件非理想影响 ----
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

    # ---- 图6：差分方案对比 ----
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

    # ---- 图7：固定阈值与自适应阈值对比 ----
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
    """
    输入：
    - `results`：由调用方传入的业务数据或控制参数。
    - `training_results`：由调用方传入的业务数据或控制参数。
    - `best_method`：由调用方传入的业务数据或控制参数。
    - `all_datasets`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `generate_summary` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    meta = results.get("meta", {})
    rec = results.get("recommendation", {})
    best_case = results.get("best_case", {})
    final = results.get("final_test", {})
    final_best = results.get("final_test_best_case", {})
    backend = results.get("device_backend", {})
    top_grid = results.get("full_grid_top", [])

    # 用“字符串列表累积”再 join，是 Python 里构造长文本最常见且高效的写法。
    lines = []
    lines.append("=" * 60)
    lines.append("  SNN SoC 建模结果 - 参数推荐")
    lines.append("=" * 60)
    lines.append(
        f"\n评估口径: tuning_split={meta.get('tune_split', 'val')} "
        f"(选方案/调参), final_split={meta.get('final_split', 'test')} (最终一次报告)"
    )
    lines.append(
        f"全量组合扫描数: {meta.get('full_grid_total', 0)}, "
        f"推荐精度容忍边界: {meta.get('recommend_margin', 0.0):.2%}"
    )

    lines.append(f"\n最佳下采样方法(8/4/1基线): {best_method}")
    lines.append(
        f"  tuning SNN(ADC=8,W=4,T=1): "
        f"{results['downsample'][best_method]['snn_acc']:.2%}"
    )
    lines.append(f"  ANN float 基线准确率(test): {training_results[best_method]['float_acc']:.2%}")
    quant_acc = training_results[best_method].get("quant_acc")
    if quant_acc is not None:
        lines.append(f"  ANN quantized 基线准确率(test): {quant_acc:.2%}")

    if best_case:
        lines.append("\nbest-case(全量网格最高精度):")
        lines.append(
            f"  method={best_case.get('method')}, scheme={best_case.get('scheme')}, "
            f"ADC={best_case.get('adc_bits')}, W={best_case.get('weight_bits')}, "
            f"T={best_case.get('timesteps')}, ratio={best_case.get('threshold_ratio', 0.0):.2f}, "
            f"acc={best_case.get('snn_acc', 0.0):.2%}"
        )

    if rec:
        lines.append("\nrecommendation(精度达标下低成本优先):")
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
    if final_best:
        lines.append(
            f"Final {final_best.get('split', 'test')} (best-case): "
            f"{final_best.get('snn_acc', 0.0):.2%}"
        )

    # Top-K 组合列表可帮助你快速看到“次优但更低成本”的备选方案。
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
        marker = " <- 推荐" if bits == rec.get("adc_bits") else ""
        lines.append(f"  {bits:2d}-bit: {acc:.2%}{marker}")

    w_sorted = sorted(results["weight_sweep"].items())
    lines.append(f"\nWeight sweep ({meta.get('tune_split', 'val')}):")
    for bits, acc in w_sorted:
        marker = " <- 推荐" if bits == rec.get("weight_bits") else ""
        lines.append(f"  {bits}-bit: {acc:.2%}{marker}")

    ts_sorted = sorted(results["timestep_sweep"].items())
    lines.append(f"\nTimesteps sweep ({meta.get('tune_split', 'val')}):")
    for ts, acc in ts_sorted:
        marker = " <- 推荐" if ts == rec.get("timesteps") else ""
        lines.append(f"  T={ts:2d}: {acc:.2%}{marker}")

    ni = results["noise_impact"]
    lines.append(f"\n器件非理想影响({ni.get('split', meta.get('tune_split', 'val'))}):")
    lines.append(f"  理想准确率:      {ni['ideal']:.2%}")
    lines.append(f"  含噪准确率:      {ni['noisy_mean']:.2%} +/- {ni['noisy_std']:.4f}")
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
    lines.append(f"\n自适应阈值({ad.get('split', meta.get('tune_split', 'val'))}):")
    lines.append(f"  固定阈值(spike): {ad['fixed']:.2%}")
    lines.append(f"  自适应阈值:      {ad['adaptive']:.2%}")
    lines.append(f"  提升:            {ad['improvement']:+.2%}")
    lines.append(f"  conclusion: {'recommended' if do_adaptive else 'not recommended'}")

    ms = results.get("multi_seed", {})
    if ms:
        lines.append(f"\n固定配置多seed复跑 ({ms.get('split', meta.get('final_split', 'test'))}):")
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

    lines.append(f"\n{'=' * 60}")
    lines.append("  RTL 参数推荐 (用于更新 snn_soc_pkg.sv)")
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

    # 最后用换行符连接成完整文本。
    summary_text = "\n".join(lines)
    summary_path = os.path.join(cfg.RESULTS_DIR, "summary.txt")
    # 明确指定 UTF-8，避免中文写文件时出现乱码。
    with open(summary_path, 'w', encoding='utf-8') as f:
        f.write(summary_text)

    print(f"\n{summary_text}")
    print(f"\n结果已保存到: {cfg.RESULTS_DIR}")
# =====================================================
#  主入口
# =====================================================

def main():
    """
    输入：
    - 无显式输入参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `main` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    # 创建参数解析器：负责把命令行字符串转换成 Python 变量。
    parser = argparse.ArgumentParser(description='SNN SoC Python 建模系统')
    parser.add_argument('--quick', action='store_true',
                        help='快速模式（少量样本，适合流程联调）')
    parser.add_argument('--skip-train', action='store_true',
                        help='跳过训练，加载已保存权重')
    args = parser.parse_args()

    print("=" * 60)
    print("  SNN SoC Python 建模系统 v1.0")
    print("=" * 60)
    if args.quick:
        print("  模式: 快速测试(--quick)")

    # 在流程最开始统一随机种子，确保训练/推理可复现。
    set_global_seed(cfg.RANDOM_SEED)
    print(f"  随机种子: {cfg.RANDOM_SEED}")
    print(f"  ADC满量程模式: {cfg.ADC_FULL_SCALE_MODE}")
    backend = snn_engine.get_device_backend_status()
    print(
        "  器件模型接入: "
        f"use_device_model={backend['use_device_model']}, "
        f"path_exists={backend['plugin_path_exists']}, "
        f"levels_loaded={backend['plugin_levels_loaded']}, "
        f"levels={backend['plugin_levels_count']}"
    )

    # 记录开始时间，末尾用于统计总耗时。
    start_time = time.time()

    # 创建输出目录
    os.makedirs(cfg.RESULTS_DIR, exist_ok=True)
    os.makedirs(cfg.WEIGHTS_DIR, exist_ok=True)

    # 步骤 1: 准备数据
    all_datasets = data_utils.prepare_all_datasets(quick_mode=args.quick)

    # 步骤 2：训练连续网络（或加载已有权重）
    training_results = run_training(
        all_datasets, skip_train=args.skip_train, quick=args.quick
    )

    # 步骤 3：脉冲推理与参数扫描（核心）
    sweep_results, best_method = run_parameter_sweep(
        all_datasets, training_results, quick=args.quick
    )

    # 步骤 4: 生成图表 + 推荐
    generate_plots(sweep_results, training_results, best_method)
    generate_summary(sweep_results, training_results, best_method, all_datasets)

    elapsed = time.time() - start_time
    print(f"\n总耗时: {elapsed:.1f} 秒 ({elapsed / 60:.1f} 分钟)")
    print("完成!")


if __name__ == '__main__':
    main()

