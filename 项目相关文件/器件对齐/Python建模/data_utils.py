# 统一章节化注释模板：每个函数均固定为 输入 / 处理 / 输出 / 为什么 四段。
"""
data_utils.py 第三版教学导读（数据准备与预处理）
本文件采用统一注释风格：所有函数固定为“输入/处理/输出/为什么”四段。
使用建议：先读注释理解思路，再对照代码行走读执行路径。
本次修改只增强注释可读性，不改变任何运行逻辑。
"""

import os
import torch
import torch.nn as nn
import torch.optim as optim
import torch.nn.functional as F
from torchvision import datasets, transforms
from torch.utils.data import DataLoader, TensorDataset
import config as cfg

# ==========================================================
# 第三版教学导读（只增注释，不改逻辑）
# ==========================================================
# 这个文件负责“把原始 MNIST 变成可直接喂给 ANN/SNN 的数据”。
# 可把流程看成四段：
# 1) 读取原始 28x28 图像。
# 2) 执行降采样或投影（得到 64 维/49 维等输入）。
# 3) 统一量化到 uint8（0~255），并可做输入增益。
# 4) 打包成 DataLoader，供训练与推理调用。
#
# 对硬件同学最关键的一点：
# 最终得到的是“定长向量 + uint8 数值范围”，这和后续阵列输入接口是匹配的。


def downsample_batch(images_28x28, target_size, method):
    """
    输入：
    - `images_28x28`：由调用方传入的业务数据或控制参数。
    - `target_size`：由调用方传入的业务数据或控制参数。
    - `method`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `downsample_batch` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    N = images_28x28.shape[0]
    # 转为 float 并增加通道维度: [N, 28, 28] → [N, 1, 28, 28]
    x = images_28x28.float().unsqueeze(1)

    if method == "bilinear":
        out = F.interpolate(x, size=(target_size, target_size),
                            mode='bilinear', align_corners=False)

    elif method == "nearest":
        out = F.interpolate(x, size=(target_size, target_size),
                            mode='nearest')

    elif method == "avgpool":
        out = F.adaptive_avg_pool2d(x, (target_size, target_size))

    elif method == "maxpool":
        out = F.adaptive_max_pool2d(x, (target_size, target_size))

    elif method == "pad32_zero":
        # 28x28 -> 32x32 (zero pad), then 4x4 avgpool -> 8x8
        padded = F.pad(x, (2, 2, 2, 2), mode='constant', value=0)
        out = F.avg_pool2d(padded, kernel_size=4, stride=4)

    elif method == "pad32_replicate":
        # 28x28 -> 32x32 (replicate pad), then 4x4 avgpool -> 8x8
        padded = F.pad(x, (2, 2, 2, 2), mode='replicate')
        out = F.avg_pool2d(padded, kernel_size=4, stride=4)

    elif method == "pad32_reflect":
        # 28x28 -> 32x32 (reflect pad), then 4x4 avgpool -> 8x8
        padded = F.pad(x, (2, 2, 2, 2), mode='reflect')
        out = F.avg_pool2d(padded, kernel_size=4, stride=4)

    else:
        raise ValueError(f"未知的降采样方法: {method}")

    # 去掉通道维度，量化回 [0, 255] 整数，展平
    out = out.squeeze(1)                           # [N, size, size]
    out = torch.clamp(out, 0, 255).round().byte()  # 量化为 uint8
    return out.reshape(N, -1)                      # [N, size*size]


def _flatten_images(images_28x28):
    """
    输入：
    - `images_28x28`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_flatten_images` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    return images_28x28.view(images_28x28.shape[0], -1).float() / 255.0


def _stratified_train_val_split(labels, val_size, seed):
    """
    输入：
    - `labels`：由调用方传入的业务数据或控制参数。
    - `val_size`：由调用方传入的业务数据或控制参数。
    - `seed`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_stratified_train_val_split` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    n_total = int(labels.shape[0])
    if val_size <= 0 or n_total <= 1:
        full_idx = torch.arange(n_total)
        return full_idx, torch.empty(0, dtype=torch.long)

    val_size = min(val_size, n_total - 1)
    gen = torch.Generator().manual_seed(int(seed))
    num_classes = int(labels.max().item()) + 1
    class_counts = torch.bincount(labels, minlength=num_classes).long()

    # Proportional allocation + largest-remainder correction.
    raw = class_counts.float() * float(val_size) / float(n_total)
    val_per_class = torch.floor(raw).long()
    remainder = val_size - int(val_per_class.sum().item())
    if remainder > 0:
        frac = raw - val_per_class.float()
        order = torch.argsort(frac, descending=True)
        for k in range(remainder):
            val_per_class[order[k]] += 1

    # Do not request more val samples than available in any class.
    val_per_class = torch.minimum(val_per_class, class_counts)
    current = int(val_per_class.sum().item())
    if current < val_size:
        deficit = val_size - current
        room = class_counts - val_per_class
        order = torch.argsort(room, descending=True)
        for cls in order.tolist():
            if deficit <= 0:
                break
            add = min(int(room[cls].item()), deficit)
            if add > 0:
                val_per_class[cls] += add
                deficit -= add

    val_idx_parts = []
    train_idx_parts = []
    for cls in range(num_classes):
        idx_cls = torch.nonzero(labels == cls, as_tuple=False).squeeze(1)
        if idx_cls.numel() == 0:
            continue
        perm = idx_cls[torch.randperm(idx_cls.numel(), generator=gen)]
        n_val_cls = int(val_per_class[cls].item())
        val_idx_parts.append(perm[:n_val_cls])
        train_idx_parts.append(perm[n_val_cls:])

    val_idx = torch.cat(val_idx_parts) if val_idx_parts else torch.empty(0, dtype=torch.long)
    train_idx = torch.cat(train_idx_parts) if train_idx_parts else torch.empty(0, dtype=torch.long)
    # Shuffle concatenated indices to avoid class-block ordering bias downstream.
    if val_idx.numel() > 0:
        val_idx = val_idx[torch.randperm(val_idx.numel(), generator=gen)]
    if train_idx.numel() > 0:
        train_idx = train_idx[torch.randperm(train_idx.numel(), generator=gen)]
    return train_idx, val_idx


def _compute_pca_basis(train_x, out_dim, max_samples=None, center=True, generator=None):
    """
    输入：
    - `train_x`：由调用方传入的业务数据或控制参数。
    - `out_dim`：由调用方传入的业务数据或控制参数。
    - `max_samples`：由调用方传入的业务数据或控制参数。
    - `center`：由调用方传入的业务数据或控制参数。
    - `generator`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_compute_pca_basis` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    if max_samples is not None and max_samples > 0 and train_x.shape[0] > max_samples:
        if generator is None:
            idx = torch.randperm(train_x.shape[0])[:max_samples]
        else:
            idx = torch.randperm(train_x.shape[0], generator=generator)[:max_samples]
        x_use = train_x[idx]
    else:
        x_use = train_x

    if center:
        mean = x_use.mean(dim=0)
        x_use = x_use - mean
    else:
        mean = torch.zeros(train_x.shape[1], dtype=train_x.dtype)

    q = min(out_dim, x_use.shape[1])
    _, _, v = torch.pca_lowrank(x_use, q=q, center=False)
    components = v[:, :out_dim]  # [D, out_dim]
    return mean, components


def _scale_projected_features(train_feat, test_feat, val_feat=None):
    """
    输入：
    - `train_feat`：由调用方传入的业务数据或控制参数。
    - `test_feat`：由调用方传入的业务数据或控制参数。
    - `val_feat`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_scale_projected_features` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    method = getattr(cfg, "PROJ_SCALE_METHOD", "minmax")
    if method == "p99":
        p = float(getattr(cfg, "PROJ_SCALE_PERCENTILE", 0.99))
        max_abs = torch.quantile(train_feat.abs(), p)
        if max_abs < 1e-6:
            max_abs = torch.tensor(1.0, dtype=train_feat.dtype)
        def scale(x):
            """
            输入：
            - `x`：由调用方传入的业务数据或控制参数。
            
            处理：
            - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
            - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
            - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
            
            输出：
            - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
            - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
            
            为什么：
            - `scale` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
            - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
            - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
            """
            return (x / (2 * max_abs) + 0.5) * 255.0
        info = f"p{int(p * 100)}_max_abs={max_abs:.4f}"
        params = {"method": "p99", "p": p, "max_abs": float(max_abs)}
    else:
        min_v = train_feat.min()
        max_v = train_feat.max()
        rng = max_v - min_v
        if rng < 1e-6:
            rng = torch.tensor(1.0, dtype=train_feat.dtype)
        def scale(x):
            """
            输入：
            - `x`：由调用方传入的业务数据或控制参数。
            
            处理：
            - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
            - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
            - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
            
            输出：
            - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
            - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
            
            为什么：
            - `scale` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
            - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
            - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
            """
            return (x - min_v) / rng * 255.0
        info = f"min={min_v:.4f}, max={max_v:.4f}"
        params = {"method": "minmax", "min": float(min_v), "max": float(max_v)}

    train_scaled = torch.clamp(scale(train_feat), 0, 255).round().byte()
    test_scaled = torch.clamp(scale(test_feat), 0, 255).round().byte()
    val_scaled = None
    if val_feat is not None:
        val_scaled = torch.clamp(scale(val_feat), 0, 255).round().byte()
    return train_scaled, test_scaled, val_scaled, info, params


def _train_supervised_projection(train_x, train_labels, proj_dim, quick_mode=False):
    """
    输入：
    - `train_x`：由调用方传入的业务数据或控制参数。
    - `train_labels`：由调用方传入的业务数据或控制参数。
    - `proj_dim`：由调用方传入的业务数据或控制参数。
    - `quick_mode`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_train_supervised_projection` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    use_bias = bool(getattr(cfg, "PROJ_SUP_USE_BIAS", False))
    batch_size = int(getattr(cfg, "PROJ_SUP_BATCH_SIZE", cfg.ANN_BATCH_SIZE))
    lr = float(getattr(cfg, "PROJ_SUP_LR", cfg.ANN_LR))
    epochs = int(getattr(cfg, "PROJ_SUP_EPOCHS", 10))
    if quick_mode:
        epochs = max(1, min(2, epochs))

    class _ProjNet(nn.Module):
        # 教学注释：
        # 这里是“仅用于学习投影矩阵”的临时模型，不是最终部署网络。
        def __init__(self, in_dim, proj_dim, bias):
            """
            输入：
            - `self`：当前对象本身，表示“在这个类实例上操作”。
            - `in_dim`：由调用方传入的业务数据或控制参数。
            - `proj_dim`：由调用方传入的业务数据或控制参数。
            - `bias`：由调用方传入的业务数据或控制参数。
            
            处理：
            - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
            - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
            - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
            
            输出：
            - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
            - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
            
            为什么：
            - `_ProjNet.__init__` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
            - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
            - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
            """
            super().__init__()
            self.proj = nn.Linear(in_dim, proj_dim, bias=bias)
            self.cls = nn.Linear(proj_dim, 10, bias=False)
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
            - `_ProjNet.forward` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
            - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
            - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
            """
            return self.cls(self.proj(x))

    rng_state = torch.random.get_rng_state()
    torch.manual_seed(cfg.RANDOM_SEED + 123)
    model = _ProjNet(train_x.shape[1], proj_dim, use_bias)
    optimizer = optim.SGD(model.parameters(), lr=lr, momentum=cfg.ANN_MOMENTUM)
    criterion = nn.CrossEntropyLoss()

    gen = torch.Generator().manual_seed(cfg.RANDOM_SEED + 456)
    loader = DataLoader(
        TensorDataset(train_x, train_labels),
        batch_size=batch_size, shuffle=True, generator=gen
    )

    model.train()
    for _ in range(epochs):
        for inputs, labels in loader:
            outputs = model(inputs)
            loss = criterion(outputs, labels)
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()

    with torch.no_grad():
        weight = model.proj.weight.data.clone()
        bias = model.proj.bias.data.clone() if use_bias else None
    torch.random.set_rng_state(rng_state)

    return weight, bias


def _save_projection_params(method_name, params):
    """
    输入：
    - `method_name`：由调用方传入的业务数据或控制参数。
    - `params`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_save_projection_params` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    os.makedirs(cfg.WEIGHTS_DIR, exist_ok=True)
    path = os.path.join(cfg.WEIGHTS_DIR, f"{method_name}_proj_params.pt")
    torch.save(params, path)
    return path


def prepare_all_datasets(quick_mode=False):
    """
    输入：
    - `quick_mode`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `prepare_all_datasets` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    print("\n[Step 1/4] Prepare MNIST data...")

    train_mnist = datasets.MNIST(cfg.DATA_DIR, train=True, download=True)
    test_mnist = datasets.MNIST(cfg.DATA_DIR, train=False, download=True)

    train_images_28 = train_mnist.data
    train_labels = train_mnist.targets
    test_images_28 = test_mnist.data
    test_labels = test_mnist.targets

    if quick_mode:
        n = cfg.QUICK_TEST_SAMPLES
        test_images_28 = test_images_28[:n]
        test_labels = test_labels[:n]
        train_images_28 = train_images_28[:n * 10]
        train_labels = train_labels[:n * 10]

    # Stratified train/val split (for threshold calibration)
    val_images_28 = None
    val_labels = None
    val_size = int(getattr(cfg, "VAL_SAMPLES", 0) or 0)
    if val_size > 0 and len(train_images_28) > 1:
        max_val = max(1, len(train_images_28) // 10)
        val_size = min(val_size, max_val)
        train_idx, val_idx = _stratified_train_val_split(
            train_labels, val_size, seed=cfg.RANDOM_SEED + 999
        )
        val_images_28 = train_images_28[val_idx]
        val_labels = train_labels[val_idx]
        train_images_28 = train_images_28[train_idx]
        train_labels = train_labels[train_idx]

    all_datasets = {}

    proj_methods = {"proj_pca", "proj_sup"}
    need_proj = any(method in proj_methods for _, method in cfg.DOWNSAMPLE_METHODS.values())
    if need_proj:
        train_flat_784 = _flatten_images(train_images_28)
        test_flat_784 = _flatten_images(test_images_28)
        val_flat_784 = _flatten_images(val_images_28) if val_images_28 is not None else None

    for name, (target_size, method) in cfg.DOWNSAMPLE_METHODS.items():
        scale_info = None
        scale_params = None
        proj_param_path = None

        if method in proj_methods:
            proj_dim = int(getattr(cfg, "PROJ_DIM", target_size))
            if method == "proj_pca":
                gen = torch.Generator().manual_seed(cfg.RANDOM_SEED + 321)
                mean, components = _compute_pca_basis(
                    train_flat_784,
                    proj_dim,
                    max_samples=getattr(cfg, "PROJ_PCA_SAMPLES", None),
                    center=bool(getattr(cfg, "PROJ_PCA_CENTER", True)),
                    generator=gen,
                )
                train_feat = (train_flat_784 - mean) @ components
                test_feat = (test_flat_784 - mean) @ components
                val_feat = (val_flat_784 - mean) @ components if val_flat_784 is not None else None
                train_flat, test_flat, val_flat, scale_info, scale_params = _scale_projected_features(
                    train_feat, test_feat, val_feat
                )
                proj_param_path = _save_projection_params(name, {
                    "method": "proj_pca",
                    "proj_dim": proj_dim,
                    "mean": mean,
                    "components": components,
                    "scale_params": scale_params,
                    "center": bool(getattr(cfg, "PROJ_PCA_CENTER", True)),
                })
            else:
                W_proj, b_proj = _train_supervised_projection(
                    train_flat_784, train_labels, proj_dim, quick_mode=quick_mode
                )
                train_feat = train_flat_784 @ W_proj.t()
                test_feat = test_flat_784 @ W_proj.t()
                val_feat = val_flat_784 @ W_proj.t() if val_flat_784 is not None else None
                if b_proj is not None:
                    train_feat = train_feat + b_proj
                    test_feat = test_feat + b_proj
                    if val_feat is not None:
                        val_feat = val_feat + b_proj
                train_flat, test_flat, val_flat, scale_info, scale_params = _scale_projected_features(
                    train_feat, test_feat, val_feat
                )
                proj_param_path = _save_projection_params(name, {
                    "method": "proj_sup",
                    "proj_dim": proj_dim,
                    "weight": W_proj,
                    "bias": b_proj,
                    "scale_params": scale_params,
                })

            gain = 1.0
            input_dim = proj_dim
        else:
            train_flat = downsample_batch(train_images_28, target_size, method)
            test_flat = downsample_batch(test_images_28, target_size, method)
            val_flat = downsample_batch(val_images_28, target_size, method) if val_images_28 is not None else None

            # Optional input gain (contrast stretch)
            gain = 1.0
            if getattr(cfg, 'AUTO_INPUT_GAIN', False):
                try:
                    p = torch.quantile(train_flat.float(), float(cfg.INPUT_GAIN_PERCENTILE))
                    if p > 1.0:
                        gain = min(float(cfg.INPUT_GAIN_MAX), 255.0 / float(p))
                except Exception:
                    gain = 1.0
            if gain > 1.0 + 1e-6:
                train_flat = torch.clamp(train_flat.float() * gain, 0, 255).round().byte()
                test_flat = torch.clamp(test_flat.float() * gain, 0, 255).round().byte()
                if val_flat is not None:
                    val_flat = torch.clamp(val_flat.float() * gain, 0, 255).round().byte()

            input_dim = target_size * target_size

        train_loader = DataLoader(
            TensorDataset(train_flat.float() / 255.0, train_labels),
            batch_size=cfg.ANN_BATCH_SIZE, shuffle=True
        )

        test_loader_float = DataLoader(
            TensorDataset(test_flat.float() / 255.0, test_labels),
            batch_size=cfg.ANN_BATCH_SIZE, shuffle=False
        )
        val_loader_float = None
        if val_flat is not None and val_labels is not None:
            val_loader_float = DataLoader(
                TensorDataset(val_flat.float() / 255.0, val_labels),
                batch_size=cfg.ANN_BATCH_SIZE, shuffle=False
            )

        all_datasets[name] = {
            'train_loader':      train_loader,
            'train_images_uint8': train_flat,
            'train_labels':       train_labels,
            'test_images_uint8': test_flat,
            'test_labels':       test_labels,
            'val_images_uint8':  val_flat,
            'val_labels':        val_labels,
            'test_loader_float': test_loader_float,
            'val_loader_float':  val_loader_float,
            'input_dim':         input_dim,
            'input_gain':        gain,
            'proj_params_path':  proj_param_path,
        }

        msg = (
            f"  {name:20s} ({input_dim} dims): "
            f"train {len(train_labels)} samples, test {len(test_labels)} samples, "
            f"val {len(val_labels) if val_labels is not None else 0}, gain={gain:.2f}"
        )
        if scale_info is not None:
            msg += f", scale={scale_info}"
        print(msg)

    return all_datasets
