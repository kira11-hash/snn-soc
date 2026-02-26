"""
==========================================================
  SNN SoC Python 建模 - ANN 训练模块
==========================================================
功能：
  1. 定义单层线性 ANN 模型 (无 bias，与 CIM 硬件一致)
  2. 用标准 SGD 训练，获取 float 基线准确率
  3. 保存权重文件，供后续 SNN 推理使用

为什么用单层？
  因为我们的 CIM 阵列只做一次矩阵乘法 (64 input × 10 output)，
  所以 ANN 就是一个 nn.Linear(64, 10, bias=False)。
  训练后的权重矩阵 W [10, 64] 就是要映射到 CIM 阵列的电导值。

为什么没有 bias？
  CIM 阵列做的是 I = G × V 的矩阵乘法，没有加偏置的硬件。
  虽然可以用额外一行全1输入来模拟 bias，但 V1 为简化不做。

ANN-to-SNN 转换说明：
  对于单层网络，ANN 和 SNN 用完全相同的权重矩阵 W。
  区别只在输入编码方式：
    ANN: output = softmax(W @ x)          其中 x 是 [0,1] float
    SNN: 把 x 编码为 8 个 bit-plane，逐步送入 CIM，LIF 累加
  理想情况下（无量化无噪声），SNN 结果 = ANN 结果 × 255。
"""

import os
import torch
import torch.nn as nn
import torch.optim as optim
import config as cfg


class SingleLayerANN(nn.Module):
    """
    单层线性分类器，对应 CIM 阵列的一次矩阵乘法。

    结构: input [batch, input_dim] → Linear → output [batch, 10]
    权重: W [10, input_dim]，无 bias

    这就是整个"神经网络"。看起来简单，但 MNIST 上单层能到 ~92% (28×28)
    或 ~85-90% (8×8)，足够验证硬件方案。
    """
    def __init__(self, input_dim, num_classes=10):
        super().__init__()
        self.fc = nn.Linear(input_dim, num_classes, bias=False)

    def forward(self, x):
        return self.fc(x)


_QAT_LEVELS_CACHE = None


def _get_qat_levels():
    """Load device conductance levels (normalized 0..1) for QAT."""
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
    """Signed fake quantization with STE. If levels provided, use device levels for magnitude."""
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
    if noise_std is None or noise_std <= 0:
        return w_q
    max_abs = w_q.abs().max()
    if max_abs < 1e-12:
        return w_q
    noise = torch.randn_like(w_q) * noise_std * max_abs
    return w_q + noise


def _ir_drop_scale(inputs, coeff):
    if coeff is None or coeff <= 0:
        return None
    # simple proxy: larger input -> larger attenuation
    scale = 1.0 - coeff * inputs.mean(dim=1, keepdim=True)
    return torch.clamp(scale, 0.8, 1.0)


def train_model(train_loader, input_dim, epochs=None, lr=None, model=None,
                qat=False, weight_bits=None, noise_std=None, ir_drop_coeff=None):
    """
    Train ANN model. Supports QAT (fake quant + noise + IR drop proxy).
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
    """Evaluate model accuracy. Optionally use quantized weights for inference."""
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
    提取模型的权重矩阵。

    返回:
        W: Tensor [num_outputs, input_dim] = [10, 64] (或 [10, 49])

    这个 W 就是要映射到 CIM 阵列的权重。
    W[j, i] 表示: 第 i 个输入到第 j 个输出神经元的连接强度。
    正值 → 映射到 G_pos (正差分列)
    负值 → 取绝对值映射到 G_neg (负差分列)
    """
    return model.fc.weight.data.clone()


def save_weights(model, method_name):
    """保存权重到文件"""
    os.makedirs(cfg.WEIGHTS_DIR, exist_ok=True)
    path = os.path.join(cfg.WEIGHTS_DIR, f"{method_name}.pt")
    torch.save(model.state_dict(), path)


def load_weights(method_name, input_dim):
    """从文件加载权重"""
    path = os.path.join(cfg.WEIGHTS_DIR, f"{method_name}.pt")
    model = SingleLayerANN(input_dim)
    try:
        state = torch.load(path, weights_only=True)
    except TypeError:
        # 兼容较低版本 PyTorch (不支持 weights_only 参数)
        state = torch.load(path)
    model.load_state_dict(state)
    return model
