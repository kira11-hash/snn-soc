# 统一章节化注释模板：每个函数均固定为 输入 / 处理 / 输出 / 为什么 四段。
"""
train_ann.py 第三版教学导读（ANN 训练与 QAT 微调）
本文件采用统一注释风格：所有函数固定为“输入/处理/输出/为什么”四段。
使用建议：先读注释理解思路，再对照代码行走读执行路径。
本次修改只增强注释可读性，不改变任何运行逻辑。
"""

import os
import torch
import torch.nn as nn
import torch.optim as optim
import config as cfg

# ==========================================================
# 第三版教学导读（只增注释，不改逻辑）
# ==========================================================
# 这个文件可以理解成“ANN 训练工厂”，核心流程如下：
# 1) `SingleLayerANN` 定义模型结构（单层全连接，无 bias）。
# 2) `train_model` 负责训练（可开 QAT）。
# 3) `evaluate_model` 负责评估（可选量化推理口径）。
# 4) `get_weights/save_weights/load_weights` 负责权重提取与存盘复用。
#
# 新手建议阅读顺序：
# `SingleLayerANN` -> `train_model` -> `evaluate_model` -> 保存/加载函数。
#
# 为什么“无 bias”：
# 当前项目重点是把线性权重映射到阵列做矩阵乘，去掉 bias 后，
# 软件路径与硬件路径更直接对齐，便于解释误差来源。


class SingleLayerANN(nn.Module):
    """
    单层线性分类器，对应 CIM 阵列的一次矩阵乘法。

    结构: input [batch, input_dim] → Linear → output [batch, 10]
    权重: W [10, input_dim]，无 bias

    这就是整个"神经网络"。看起来简单，但 MNIST 上单层能到 ~92% (28×28)
    或 ~85-90% (8×8)，足够验证硬件方案。
    """
    def __init__(self, input_dim, num_classes=10):
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        - `input_dim`：由调用方传入的业务数据或控制参数。
        - `num_classes`：由调用方传入的业务数据或控制参数。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `SingleLayerANN.__init__` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        super().__init__()
        self.fc = nn.Linear(input_dim, num_classes, bias=False)

    def forward(self, x):
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        - `x`：由调用方传入的业务数据或控制参数。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `SingleLayerANN.forward` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        return self.fc(x)


_QAT_LEVELS_CACHE = None


def _get_qat_levels():
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
    - `_get_qat_levels` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    global _QAT_LEVELS_CACHE
    if _QAT_LEVELS_CACHE is not None:
        return _QAT_LEVELS_CACHE
    if not getattr(cfg, 'QAT_USE_DEVICE_LEVELS', False):
        _QAT_LEVELS_CACHE = None
        return None
    try:
        import snn_engine
        levels = snn_engine._load_plugin_levels()
        _QAT_LEVELS_CACHE = levels
        return levels
    except Exception:
        _QAT_LEVELS_CACHE = None
        return None


def _fake_quantize_signed(weights, weight_bits, levels=None):
    """
    输入：
    - `weights`：由调用方传入的业务数据或控制参数。
    - `weight_bits`：由调用方传入的业务数据或控制参数。
    - `levels`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_fake_quantize_signed` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    max_abs = weights.abs().max()
    if max_abs < 1e-12:
        return weights
    if levels is None:
        qmax = (2 ** (weight_bits - 1)) - 1
        if qmax <= 0:
            return weights
        step = max_abs / qmax
        w_q = torch.round(weights / step) * step
    else:
        sign = torch.sign(weights)
        mag = weights.abs() / max_abs
        diff = (mag.unsqueeze(-1) - levels.view(1, 1, -1)).abs()
        idx = diff.argmin(dim=-1)
        q_mag = levels[idx]
        w_q = sign * q_mag * max_abs
    return weights + (w_q - weights).detach()


def _apply_qat_noise(w_q, noise_std):
    """
    输入：
    - `w_q`：由调用方传入的业务数据或控制参数。
    - `noise_std`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_apply_qat_noise` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    if noise_std is None or noise_std <= 0:
        return w_q
    max_abs = w_q.abs().max()
    if max_abs < 1e-12:
        return w_q
    noise = torch.randn_like(w_q) * noise_std * max_abs
    return w_q + noise


def _ir_drop_scale(inputs, coeff):
    """
    输入：
    - `inputs`：由调用方传入的业务数据或控制参数。
    - `coeff`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_ir_drop_scale` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    if coeff is None or coeff <= 0:
        return None
    # simple proxy: larger input -> larger attenuation
    scale = 1.0 - coeff * inputs.mean(dim=1, keepdim=True)
    return torch.clamp(scale, 0.8, 1.0)


def train_model(train_loader, input_dim, epochs=None, lr=None, model=None,
                qat=False, weight_bits=None, noise_std=None, ir_drop_coeff=None):
    """
    输入：
    - `train_loader`：由调用方传入的业务数据或控制参数。
    - `input_dim`：由调用方传入的业务数据或控制参数。
    - `epochs`：由调用方传入的业务数据或控制参数。
    - `lr`：由调用方传入的业务数据或控制参数。
    - `model`：由调用方传入的业务数据或控制参数。
    - `qat`：由调用方传入的业务数据或控制参数。
    - `weight_bits`：由调用方传入的业务数据或控制参数。
    - `noise_std`：由调用方传入的业务数据或控制参数。
    - `ir_drop_coeff`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `train_model` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    if epochs is None:
        epochs = cfg.ANN_EPOCHS
    if lr is None:
        lr = cfg.ANN_LR

    if model is None:
        model = SingleLayerANN(input_dim)

    if weight_bits is None:
        weight_bits = getattr(cfg, 'QAT_WEIGHT_BITS', 4)
    if noise_std is None:
        noise_std = getattr(cfg, 'QAT_NOISE_STD', 0.0)
    if ir_drop_coeff is None:
        ir_drop_coeff = getattr(cfg, 'QAT_IR_DROP_COEFF', 0.0)

    levels = _get_qat_levels() if qat else None

    criterion = nn.CrossEntropyLoss()
    optimizer = optim.SGD(model.parameters(), lr=lr, momentum=cfg.ANN_MOMENTUM)

    history = []
    model.train()
    for _ in range(epochs):
        total_loss = 0.0
        num_batches = 0
        for inputs, labels in train_loader:
            if qat:
                w_q = _fake_quantize_signed(model.fc.weight, weight_bits, levels)
                if getattr(cfg, 'QAT_NOISE_ENABLE', False):
                    w_q = _apply_qat_noise(w_q, noise_std)
                outputs = inputs @ w_q.t()
                scale = _ir_drop_scale(inputs, ir_drop_coeff)
                if scale is not None:
                    outputs = outputs * scale
            else:
                outputs = model(inputs)

            loss = criterion(outputs, labels)
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()

            total_loss += loss.item()
            num_batches += 1

        avg_loss = total_loss / max(1, num_batches)
        history.append(avg_loss)

    return model, history


def evaluate_model(model, test_loader, quantized=False, weight_bits=None,
                   noise_std=0.0, ir_drop_coeff=0.0):
    """
    输入：
    - `model`：由调用方传入的业务数据或控制参数。
    - `test_loader`：由调用方传入的业务数据或控制参数。
    - `quantized`：由调用方传入的业务数据或控制参数。
    - `weight_bits`：由调用方传入的业务数据或控制参数。
    - `noise_std`：由调用方传入的业务数据或控制参数。
    - `ir_drop_coeff`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `evaluate_model` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    model.eval()
    correct = 0
    total = 0

    if weight_bits is None:
        weight_bits = getattr(cfg, 'QAT_WEIGHT_BITS', 4)

    levels = _get_qat_levels() if quantized else None

    with torch.no_grad():
        for inputs, labels in test_loader:
            if quantized:
                w_q = _fake_quantize_signed(model.fc.weight, weight_bits, levels)
                if getattr(cfg, 'QAT_NOISE_ENABLE', False) and noise_std > 0:
                    w_q = _apply_qat_noise(w_q, noise_std)
                outputs = inputs @ w_q.t()
                scale = _ir_drop_scale(inputs, ir_drop_coeff)
                if scale is not None:
                    outputs = outputs * scale
            else:
                outputs = model(inputs)
            predictions = outputs.argmax(dim=1)
            correct += (predictions == labels).sum().item()
            total += labels.size(0)

    return correct / max(1, total)


def get_weights(model):
    """
    输入：
    - `model`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `get_weights` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    return model.fc.weight.data.clone()


def save_weights(model, method_name):
    # 教学注释：
    # 把当前模型参数保存到 `weights/{method_name}.pt`，
    # 方便后续 `--skip-train` 直接复用。
    """
    输入：
    - `model`：由调用方传入的业务数据或控制参数。
    - `method_name`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `save_weights` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    os.makedirs(cfg.WEIGHTS_DIR, exist_ok=True)
    path = os.path.join(cfg.WEIGHTS_DIR, f"{method_name}.pt")
    torch.save(model.state_dict(), path)


def load_weights(method_name, input_dim):
    # 教学注释：
    # 从磁盘恢复同结构模型参数；兼容新旧 PyTorch 的加载接口差异。
    """
    输入：
    - `method_name`：由调用方传入的业务数据或控制参数。
    - `input_dim`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `load_weights` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    path = os.path.join(cfg.WEIGHTS_DIR, f"{method_name}.pt")
    model = SingleLayerANN(input_dim)
    try:
        state = torch.load(path, weights_only=True)
    except TypeError:
        # 兼容较低版本 PyTorch (不支持 weights_only 参数)
        state = torch.load(path)
    model.load_state_dict(state)
    return model
