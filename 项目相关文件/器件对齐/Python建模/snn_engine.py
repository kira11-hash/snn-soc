"""
==========================================================
  SNN SoC Python 建模 - SNN 推理引擎 + 器件模型
==========================================================
功能：
  1. 权重量化: 把 ANN 的 float 权重映射到 CIM 阵列的离散电导电平
  2. 器件非理想性: 注入 D2D/C2C 变化、读噪声、电导漂移
  3. ADC 量化: 模拟 N-bit ADC 的量化误差
  4. Bit-plane SNN 推理: 完全匹配 RTL 的行为
  5. 自适应阈值: 对比固定阈值 vs 自适应阈值的效果

核心概念 - 为什么 SNN 等价于 ANN？
  ANN 计算:  output[j] = sum_i(W[j,i] * pixel[i])
  SNN 计算:  对 pixel[i] 做 8-bit 展开 (bit-plane 编码)
             每个 bit 送一个 0/1 到 CIM，得到部分和
             LIF 神经元把 8 个部分和按权重 (128,64,...,1) 累加
             最终结果 = ANN 结果 × 255 (因为 ANN 输入归一化到 [0,1])

差分编码：
  CIM 阵列的电导只能是正值 (G ≥ 0)，但 ANN 权重有正有负。
  解决方案: 差分结构
    W_pos = max(W, 0)     → 映射到正差分列的电导
    W_neg = max(-W, 0)    → 映射到负差分列的电导
    输出 = CIM(input, G_pos) - CIM(input, G_neg)
  这样就能表示正负权重了。

方案 A vs B：
  方案 A (模拟侧差分): 模拟电路先做 I_pos - I_neg，再送给 ADC
    → ADC 收到的是有符号电流，需要处理负值
    → 只需要 10 个 ADC 通道
  方案 B (数字侧差分): 分别对 I_pos 和 I_neg 做 ADC，数字域相减
    → 每个 ADC 只处理正电流（简单）
    → 需要 20 个 ADC 通道
"""

import os
import math
import inspect
import importlib.util

import torch
import numpy as np
import config as cfg


_PLUGIN_LEVELS_CACHE = None
_PLUGIN_LEVELS_LOAD_TRIED = False
_PLUGIN_SIM_CACHE = {}
_PLUGIN_MODULE_CACHE = None
_PLUGIN_MODULE_LOAD_TRIED = False
_BACKEND_NOTES = []
_BACKEND_NOTES_SEEN = set()


def _note_backend(message):
    if message in _BACKEND_NOTES_SEEN:
        return
    _BACKEND_NOTES_SEEN.add(message)
    _BACKEND_NOTES.append(message)
    print(f"[snn_engine] {message}")


def _load_plugin_module():
    """
    Load memristor_plugin.py once and cache the imported module.
    """
    global _PLUGIN_MODULE_CACHE, _PLUGIN_MODULE_LOAD_TRIED

    if _PLUGIN_MODULE_LOAD_TRIED:
        return _PLUGIN_MODULE_CACHE
    _PLUGIN_MODULE_LOAD_TRIED = True

    if not cfg.USE_MEMRISTOR_PLUGIN:
        _note_backend("USE_MEMRISTOR_PLUGIN=False, plugin backend disabled.")
        return None
    if not os.path.exists(cfg.MEMRISTOR_PLUGIN_PATH):
        _note_backend(f"Plugin path not found: {cfg.MEMRISTOR_PLUGIN_PATH}")
        return None

    try:
        spec = importlib.util.spec_from_file_location(
            "memristor_plugin_dynamic", cfg.MEMRISTOR_PLUGIN_PATH
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _PLUGIN_MODULE_CACHE = module
        return _PLUGIN_MODULE_CACHE
    except Exception as exc:
        _note_backend(f"Failed to import plugin module: {exc}")
        _PLUGIN_MODULE_CACHE = None
        return None


def _load_plugin_levels():
    """
    尝试从器件团队提供的 memristor_plugin.py 加载 4-bit 电导电平。
    返回:
        levels_norm: Tensor [L], 值域 [0,1]，首元素保证为 0
                     失败时返回 None
    """
    global _PLUGIN_LEVELS_CACHE, _PLUGIN_LEVELS_LOAD_TRIED

    if _PLUGIN_LEVELS_LOAD_TRIED:
        return _PLUGIN_LEVELS_CACHE
    _PLUGIN_LEVELS_LOAD_TRIED = True

    if not cfg.PLUGIN_LEVELS_FOR_4BIT:
        return None
    module = _load_plugin_module()
    if module is None:
        return None

    try:
        sim = module.MemristorArraySimulator(
            iv_data_path=cfg.IV_DATA_PATH, device="cpu"
        )
        levels = torch.tensor(sim.conductance_levels, dtype=torch.float32)
        levels = torch.sort(torch.unique(levels))[0]
        levels_norm = levels / levels.max()
        if levels_norm[0] > 0:
            levels_norm = torch.cat([torch.zeros(1), levels_norm])
        _PLUGIN_LEVELS_CACHE = levels_norm
        return _PLUGIN_LEVELS_CACHE
    except Exception as exc:
        _note_backend(f"Failed to load plugin conductance levels: {exc}")
        _PLUGIN_LEVELS_CACHE = None
        return None


def _get_plugin_sim(rows, cols):
    """
    获取器件仿真器实例（按阵列尺寸缓存）。
    返回 None 表示器件模型不可用。
    """
    if not getattr(cfg, "USE_DEVICE_MODEL", False):
        return None
    module = _load_plugin_module()
    if module is None:
        return None
    key = (int(rows), int(cols))
    if key in _PLUGIN_SIM_CACHE:
        return _PLUGIN_SIM_CACHE[key]
    try:
        kwargs = {"iv_data_path": cfg.IV_DATA_PATH, "device": "cpu"}
        ctor_sig = inspect.signature(module.MemristorArraySimulator.__init__)
        if "rows" in ctor_sig.parameters:
            kwargs["rows"] = int(rows)
        if "cols" in ctor_sig.parameters:
            kwargs["cols"] = int(cols)
        sim = module.MemristorArraySimulator(**kwargs)
        _PLUGIN_SIM_CACHE[key] = sim
        if "rows" not in kwargs or "cols" not in kwargs:
            _note_backend(
                "Plugin simulator does not expose rows/cols args; using plugin default array geometry."
            )
        return sim
    except Exception as exc:
        # Retry without rows/cols for compatibility with older plugin versions.
        try:
            sim = module.MemristorArraySimulator(iv_data_path=cfg.IV_DATA_PATH, device="cpu")
            _PLUGIN_SIM_CACHE[key] = sim
            _note_backend(
                "Plugin simulator init with rows/cols failed; fallback to default-geometry simulator. "
                f"reason={exc}"
            )
            return sim
        except Exception as exc2:
            _note_backend(f"Plugin simulator unavailable, fallback to simplified path. reason={exc2}")
        _PLUGIN_SIM_CACHE[key] = None
        return None


def get_device_backend_status():
    levels = _load_plugin_levels()
    sim_entries = [v for v in _PLUGIN_SIM_CACHE.values() if v is not None]
    sim_available = len(sim_entries) > 0
    backend_mode = "plugin" if sim_available else "fallback"
    return {
        "use_device_model": getattr(cfg, "USE_DEVICE_MODEL", False),
        "use_memristor_plugin": cfg.USE_MEMRISTOR_PLUGIN,
        "plugin_path_exists": os.path.exists(cfg.MEMRISTOR_PLUGIN_PATH),
        "plugin_levels_loaded": levels is not None,
        "plugin_levels_count": int(levels.numel()) if levels is not None else 0,
        "plugin_sim_available": sim_available,
        "plugin_sim_instances": len(sim_entries),
        "backend_mode": backend_mode,
        "runtime_notes": list(_BACKEND_NOTES),
    }


# ==========================================================
#  第1部分: 权重量化
# ==========================================================

def split_differential(W):
    """
    将 ANN 权重拆分为差分对。

    参数:
        W: Tensor [num_outputs, input_dim], float, 有正有负

    返回:
        W_pos: Tensor [num_outputs, input_dim], ≥ 0, 正权重部分
        W_neg: Tensor [num_outputs, input_dim], ≥ 0, 负权重的绝对值

    性质: W = W_pos - W_neg (可以验证)
    """
    W_pos = torch.clamp(W, min=0)       # 保留正值，负值变0
    W_neg = torch.clamp(-W, min=0)      # 负值取绝对值，正值变0
    return W_pos, W_neg


def _nearest_level_quantize(normalized_values, normalized_levels):
    """
    将 [0,1] 的值量化到给定离散电平（最近邻）。
    """
    diff = (normalized_values.unsqueeze(-1) - normalized_levels.view(1, 1, -1)).abs()
    idx = diff.argmin(dim=-1)
    return normalized_levels[idx]


def quantize_weights(W_half, weight_bits, mode='linear', ref_max=None, plugin_levels=None):
    """
    将权重量化到有限个离散电平（模拟 CIM 阵列的有限电导级数）。

    参数:
        W_half:      Tensor, ≥ 0, 正差分或负差分的权重
        weight_bits: int, 量化位宽 (4 → 16 个电平, 8 → 256 个电平)
        mode:        'linear' 线性等间隔 | 'log' 对数间隔(匹配RRAM特性)

    返回:
        W_q: Tensor, 量化后的权重

    量化过程:
        1. 找到最大值 w_max
        2. 生成 2^N 个离散电平 (从 0 到 w_max)
        3. 把每个权重值 snap 到最近的电平

    为什么要做这一步？
        因为 RRAM 只能被编程到有限个电导状态 (4-bit = 16 个状态)。
        量化后的权重和原始 float 权重有误差，这个误差会降低准确率。
    """
    w_max = W_half.max() if ref_max is None else ref_max
    if w_max < 1e-10:
        return W_half.clone()

    num_levels = 2 ** weight_bits

    # 4-bit 时优先用器件电平（如果可用），并且与正/负支路共享同一个 ref_max。
    if plugin_levels is not None and weight_bits == 4:
        levels = plugin_levels.to(device=W_half.device, dtype=W_half.dtype)
        normalized = torch.clamp(W_half / w_max, 0.0, 1.0)
        q_norm = _nearest_level_quantize(normalized, levels)
        return q_norm * w_max

    if mode == 'linear':
        # 线性等间隔: [0, step, 2*step, ..., w_max]
        step = w_max / (num_levels - 1)
        W_q = torch.round(W_half / step) * step

    elif mode == 'log':
        # 对数间隔: RRAM 电导天然是对数分布的
        # 在对数域做均匀量化
        W_safe = torch.clamp(W_half, min=w_max * 1e-4)  # 避免 log(0)
        log_min = torch.log10(torch.tensor(w_max * 1e-4))
        log_max = torch.log10(w_max)
        log_step = (log_max - log_min) / (num_levels - 1)
        log_val = torch.log10(W_safe)
        log_q = torch.round((log_val - log_min) / log_step) * log_step + log_min
        W_q = torch.pow(10, log_q)
        # 原本就是 0 的位置保持为 0
        W_q[W_half < w_max * 1e-4] = 0.0

    else:
        raise ValueError(f"未知量化模式: {mode}")

    return torch.clamp(W_q, 0, w_max)


def prepare_conductance_pair(W, weight_bits, quant_mode='linear'):
    """
    使用统一标尺量化差分对，避免正/负支路量化尺度不一致。
    """
    W_pos, W_neg = split_differential(W)
    shared_max = W.abs().max()
    plugin_levels = _load_plugin_levels()
    G_pos = quantize_weights(
        W_pos, weight_bits, mode=quant_mode, ref_max=shared_max, plugin_levels=plugin_levels
    )
    G_neg = quantize_weights(
        W_neg, weight_bits, mode=quant_mode, ref_max=shared_max, plugin_levels=plugin_levels
    )
    return G_pos, G_neg


def _quantize_weights_device(W_half, weight_bits, device_sim, ref_max):
    """使用器件电导电平进行量化，返回真实电导值。"""
    if ref_max < 1e-10:
        return W_half.clone()
    g_levels = torch.tensor(
        device_sim.conductance_levels, device=W_half.device, dtype=W_half.dtype
    )
    g_max = g_levels.max()
    normalized = torch.clamp(W_half / ref_max, 0.0, 1.0)

    if weight_bits == 4:
        # 使用器件真实电平（不强行补零，体现漏电）
        levels_norm = g_levels / g_max
        q_norm = _nearest_level_quantize(normalized, levels_norm)
        G = q_norm * g_max
    else:
        # 其它位宽：线性量化到 [0, g_max]
        num_levels = 2 ** weight_bits
        step = 1.0 / (num_levels - 1)
        q_norm = torch.round(normalized / step) * step
        G = q_norm * g_max

    g_min = float(device_sim.conductance_model.g_min)
    g_max_val = float(device_sim.conductance_model.g_max)
    return torch.clamp(G, min=g_min, max=g_max_val)


def prepare_conductance_pair_device(W, weight_bits, device_sim):
    """器件模型版：差分拆分 + 器件电导量化。"""
    W_pos, W_neg = split_differential(W)
    shared_max = W.abs().max()
    if shared_max < 1e-10:
        return W_pos.clone(), W_neg.clone()
    G_pos = _quantize_weights_device(W_pos, weight_bits, device_sim, shared_max)
    G_neg = _quantize_weights_device(W_neg, weight_bits, device_sim, shared_max)
    return G_pos, G_neg


def _cim_mac(spike_input, G, device_sim=None):
    """CIM 矩阵乘法：可选 IR drop 仿真。"""
    if device_sim is not None and device_sim.interconnect.ir_drop_active:
        v_effective = device_sim.ir_simulator.compute_effective_voltages(spike_input, G)
        current_map = G.unsqueeze(0) * v_effective
        return current_map.sum(dim=2)
    return spike_input @ G.T


def _estimate_spike_threshold(fs_cfg, timesteps, ratio):
    """估算固定阈值（与 RTL 的 ~60% 经验一致）。"""
    if "signed" in fs_cfg:
        full_scale = fs_cfg["signed"]
    else:
        full_scale = max(fs_cfg["pos"], fs_cfg["neg"])
    return full_scale * ((1 << cfg.PIXEL_BITS) - 1) * max(1, timesteps) * ratio


def _apply_d2d_c2c_to_diff_pair(G_pos, G_neg, d2d, c2c):
    """
    Apply shared D2D and independent C2C variations to differential conductance pair.
    """
    d2d_factor = 1.0 + torch.randn(1, device=G_pos.device, dtype=G_pos.dtype) * d2d
    c2c_pos = 1.0 + torch.randn_like(G_pos) * c2c
    c2c_neg = 1.0 + torch.randn_like(G_neg) * c2c
    G_pos_out = G_pos * d2d_factor * c2c_pos
    G_neg_out = G_neg * d2d_factor * c2c_neg
    return G_pos_out, G_neg_out


# ==========================================================
#  第2部分: 器件非理想性
# ==========================================================

def add_device_variation(W_q, d2d=None, c2c=None, d2d_factor=None):
    """
    给量化后的权重添加器件变化性（模拟制造工艺偏差）。

    参数:
        W_q:  Tensor, 量化后的权重
        d2d:  float, Die-to-Die 变化 (整个芯片的系统性偏移, 默认 5%)
        c2c:  float, Cell-to-Cell 变化 (每个单元的随机偏差, 默认 3%)

    返回:
        W_noisy: Tensor, 添加变化后的权重

    物理含义:
        D2D: 同一批芯片之间的差异（比如同一晶圆不同位置的工艺偏差）
             → 所有单元共享同一个偏移量
        C2C: 同一芯片上不同单元之间的差异（局部缺陷、掺杂不均匀等）
             → 每个单元独立的随机偏差
    """
    if d2d is None:
        d2d = cfg.D2D_VARIATION
    if c2c is None:
        c2c = cfg.C2C_VARIATION

    # D2D: 整体乘性偏移 (所有单元同一个随机因子)
    if d2d_factor is None:
        d2d_factor = 1.0 + torch.randn(1, device=W_q.device, dtype=W_q.dtype) * d2d

    # C2C: 逐单元乘性偏移
    c2c_factor = 1.0 + torch.randn_like(W_q) * c2c

    W_noisy = W_q * d2d_factor * c2c_factor
    return torch.clamp(W_noisy, min=0)  # 电导不能为负


def add_read_noise(W_q, noise_sigma=None):
    """
    添加读噪声（每次读取电导值时的随机波动）。

    参数:
        W_q:         Tensor, 权重
        noise_sigma: float, 噪声标准差 (占电导范围的比例)

    返回:
        W_noisy: Tensor, 添加噪声后的权重

    物理含义:
        每次读取 RRAM 单元时，电流值会有微小的随机波动。
        这是由热噪声、1/f 噪声等引起的，每次读都不同。
    """
    if noise_sigma is None:
        noise_sigma = cfg.READ_NOISE_SIGMA

    w_range = W_q.max() - W_q.min()
    if w_range < 1e-10:
        return W_q

    noise = torch.randn_like(W_q) * noise_sigma * w_range
    return torch.clamp(W_q + noise, min=0)


def add_read_noise_to_signal(signal, full_scale, noise_sigma=None):
    """
    对读出信号添加动态噪声。full_scale 固定时更接近硬件。
    """
    if noise_sigma is None:
        noise_sigma = cfg.READ_NOISE_SIGMA
    sigma = noise_sigma * max(full_scale, 1e-12)
    return signal + torch.randn_like(signal) * sigma


# ==========================================================
#  第3部分: ADC 量化
# ==========================================================

def quantize_adc(values, adc_bits, signed=True, full_scale=None, full_scale_mode=None):
    """
    模拟 ADC 量化过程。

    参数:
        values:   Tensor, CIM 矩阵乘法的模拟输出 (电流值)
        adc_bits: int, ADC 位宽 (8 → 256 个量化级)
        signed:   bool, True=有符号(方案A), False=无符号(方案B的单路)

    返回:
        quantized: Tensor, 量化后的数字值

    ADC 的工作原理:
        把连续的模拟电流值转换为离散的数字码。
        N-bit ADC 有 2^N 个量化级。
        量化步长 = 满量程 / (2^N - 1)
        量化后的值 = round(原值 / 步长) × 步长

    量程设定:
        满量程根据"最大可能电流"固定（不是按数据自适应的）。
        这和真实硬件一致：ADC 的参考电压是设计时固定的。
    """
    if full_scale_mode is None:
        full_scale_mode = cfg.ADC_FULL_SCALE_MODE

    num_levels = 2 ** adc_bits
    use_dynamic_fs = (full_scale_mode == "dynamic") or (full_scale is None)

    if signed:
        # 有符号 ADC (方案 A: I_pos - I_neg, 结果可正可负)
        # 量程: [-full_scale, +full_scale]
        if use_dynamic_fs:
            full_scale = values.abs().max().item()
        if full_scale < 1e-30:
            return values
        step = (2 * full_scale) / (num_levels - 1)
        quantized = torch.round(values / step) * step
        return torch.clamp(quantized, -full_scale, full_scale)
    else:
        # 无符号 ADC (方案 B: 单路 I_pos 或 I_neg, 只有正值)
        if use_dynamic_fs:
            full_scale = values.max().item()
        if full_scale < 1e-30:
            return values
        step = full_scale / (num_levels - 1)
        quantized = torch.round(values / step) * step
        return torch.clamp(quantized, 0, full_scale)


# ==========================================================
#  第4部分: SNN 推理 (匹配 RTL 行为)
# ==========================================================

def estimate_adc_full_scale(G_pos, G_neg, scheme):
    """
    基于量化后导通值估计固定 ADC 满量程（bit-plane 单次读出量程）。
    假设最坏情况下该 bit-plane 的输入全为1。
    """
    pos_fs = G_pos.sum(dim=1).max().item()
    neg_fs = G_neg.sum(dim=1).max().item()
    if scheme == 'A':
        return {"signed": max(pos_fs, neg_fs)}
    return {"pos": pos_fs, "neg": neg_fs}


def _normalize_scheme(scheme):
    s = str(scheme).upper()
    if s not in ("A", "B"):
        raise ValueError(f"unknown differential scheme: {scheme}")
    if s == "A" and not bool(getattr(cfg, "ALLOW_SIGNED_SCHEME_A", False)):
        raise ValueError(
            "Scheme A is disabled (ALLOW_SIGNED_SCHEME_A=False) to align with unsigned RTL data path."
        )
    return s


def snn_inference(test_images_uint8, test_labels, W, adc_bits=8,
                  weight_bits=4, timesteps=1, scheme='A',
                  add_noise=False, quant_mode='linear',
                  decision='spike', threshold_ratio=None, threshold=None,
                  reset_mode=None, use_device_model=None,
                  spike_fallback_to_membrane=True,
                  return_stats=False):
    """
    SNN 推理主入口，支持 spike 计数决策与膜电位决策。

    decision:
        - 'spike' / 'count' : 使用每个输出神经元的发放次数做分类
        - 'membrane'        : 直接对最终膜电位做 argmax 分类
    """
    N = test_images_uint8.shape[0]
    input_dim = W.shape[1]
    num_outputs = W.shape[0]

    if use_device_model is None:
        use_device_model = getattr(cfg, 'USE_DEVICE_MODEL', False)
    if reset_mode is None:
        reset_mode = getattr(cfg, 'SPIKE_RESET_MODE', 'soft')

    use_spike = decision in ('spike', 'count', 'spike_count')
    scheme = _normalize_scheme(scheme)

    device_sim = _get_plugin_sim(num_outputs, input_dim) if use_device_model else None

    # ---- Step 1 + 2: 差分拆分 + 权重量化 ----
    if device_sim is not None:
        G_pos, G_neg = prepare_conductance_pair_device(W, weight_bits, device_sim)
    else:
        G_pos, G_neg = prepare_conductance_pair(W, weight_bits, quant_mode)

    # Keep ADC full-scale tied to nominal conductance map (hardware-fixed reference).
    fs_cfg = estimate_adc_full_scale(G_pos, G_neg, scheme)

    # ---- Step 3: 注入器件非理想 ----
    if add_noise:
        if device_sim is not None:
            # D2D/C2C 共享同一个 D2D 系统偏移
            d2d = float(device_sim.variation.die_to_die)
            c2c = float(device_sim.variation.cell_to_cell)
            G_pos, G_neg = _apply_d2d_c2c_to_diff_pair(G_pos, G_neg, d2d, c2c)
            # 再叠加读噪声与漂移
            G_pos = device_sim.apply_non_idealities(G_pos, add_noise=True, add_drift=True)
            G_neg = device_sim.apply_non_idealities(G_neg, add_noise=True, add_drift=True)
        else:
            shared_d2d = 1.0 + torch.randn(1, device=G_pos.device, dtype=G_pos.dtype) * cfg.D2D_VARIATION
            G_pos = add_device_variation(G_pos, d2d_factor=shared_d2d)
            G_neg = add_device_variation(G_neg, d2d_factor=shared_d2d)

    if use_spike and threshold is None:
        ratio = threshold_ratio
        if ratio is None:
            ratio = float(getattr(cfg, 'SPIKE_THRESHOLD_RATIO', 0.6))
        threshold = _estimate_spike_threshold(fs_cfg, timesteps, ratio)

    # ---- Step 4: Bit-plane SNN 累加 ----
    membranes = torch.zeros(N, num_outputs, dtype=torch.float32)
    spike_counts = torch.zeros(N, num_outputs, dtype=torch.float32) if use_spike else None

    pixels = test_images_uint8.long()  # [N, input_dim]

    for frame in range(timesteps):
        for bit in range(cfg.PIXEL_BITS - 1, -1, -1):
            spike_input = ((pixels >> bit) & 1).float()  # [N, input_dim]

            # CIM MAC（可选 IR drop 建模）
            mac_pos = _cim_mac(spike_input, G_pos, device_sim)
            mac_neg = _cim_mac(spike_input, G_neg, device_sim)

            # 差分方案 + ADC 量化
            if scheme == 'A':
                mac_diff = mac_pos - mac_neg
                if add_noise:
                    mac_diff = add_read_noise_to_signal(mac_diff, fs_cfg['signed'])
                adc_out = quantize_adc(
                    mac_diff,
                    adc_bits,
                    signed=True,
                    full_scale=fs_cfg['signed'],
                    full_scale_mode=cfg.ADC_FULL_SCALE_MODE,
                )
            elif scheme == 'B':
                if add_noise:
                    mac_pos = add_read_noise_to_signal(mac_pos, fs_cfg['pos'])
                    mac_neg = add_read_noise_to_signal(mac_neg, fs_cfg['neg'])
                adc_pos = quantize_adc(
                    mac_pos,
                    adc_bits,
                    signed=False,
                    full_scale=fs_cfg['pos'],
                    full_scale_mode=cfg.ADC_FULL_SCALE_MODE,
                )
                adc_neg = quantize_adc(
                    mac_neg,
                    adc_bits,
                    signed=False,
                    full_scale=fs_cfg['neg'],
                    full_scale_mode=cfg.ADC_FULL_SCALE_MODE,
                )
                adc_out = adc_pos - adc_neg
            else:
                raise ValueError(f"未知差分方案: {scheme}")

            membranes += adc_out * (2 ** bit)

            if use_spike:
                fired = membranes >= threshold
                spike_counts += fired.float()
                if reset_mode == 'hard':
                    membranes[fired] = 0.0
                else:
                    membranes[fired] -= threshold

    # ---- Step 5: 分类决策 ----
    stats = {}
    if use_spike:
        predictions_spike_only = spike_counts.argmax(dim=1)
        all_zero = (spike_counts.sum(dim=1) == 0)
        zero_spike_count = int(all_zero.sum().item())
        zero_spike_rate = zero_spike_count / max(1, N)

        stats["zero_spike_count"] = zero_spike_count
        stats["zero_spike_rate"] = float(zero_spike_rate)
        stats["spike_fallback_to_membrane"] = bool(spike_fallback_to_membrane)
        stats["spike_only_acc"] = float(
            (predictions_spike_only == test_labels).sum().item() / N
        )

        predictions = predictions_spike_only.clone()
        if spike_fallback_to_membrane and zero_spike_count > 0:
            predictions[all_zero] = membranes[all_zero].argmax(dim=1)
            stats["decision_mode"] = "spike_with_membrane_fallback"
        else:
            stats["decision_mode"] = "spike_only"
    else:
        predictions = membranes.argmax(dim=1)
        stats["decision_mode"] = "membrane"

    accuracy = (predictions == test_labels).sum().item() / N
    if return_stats:
        stats["acc"] = float(accuracy)
        return accuracy, membranes, stats
    return accuracy, membranes


def snn_inference_ideal(test_images_uint8, test_labels, W, timesteps=1):
    """
    理想 SNN 推理 (无量化无噪声)。
    用于验证 SNN 与 ANN 的数学等价性。

    理想情况下:
      SNN 膜电位 = timesteps × W @ pixel_vector × 1.0
      与 ANN 输出 × 255 × timesteps 成正比 (因为 ANN 输入归一化到 [0,1])
    所以 argmax 结果应该完全一致。
    """
    N = test_images_uint8.shape[0]
    membranes = torch.zeros(N, W.shape[0])
    pixels = test_images_uint8.long()

    for frame in range(timesteps):
        for bit in range(cfg.PIXEL_BITS - 1, -1, -1):
            spike_input = ((pixels >> bit) & 1).float()
            mac = spike_input @ W.T  # 直接用原始权重，无差分拆分
            membranes += mac * (2 ** bit)

    predictions = membranes.argmax(dim=1)
    accuracy = (predictions == test_labels).sum().item() / N
    return accuracy


# ==========================================================
#  第5部分: 自适应阈值推理
# ==========================================================

def snn_inference_adaptive_threshold(test_images_uint8, test_labels, W,
                                      adc_bits=8, weight_bits=4,
                                      timesteps=10, scheme='A',
                                      delta=None, quant_mode='linear',
                                      use_device_model=None, add_noise=False,
                                      reset_mode=None):
    """
    自适应阈值 SNN 推理。
    决策规则：argmax(spike_count)。
    """
    N = test_images_uint8.shape[0]
    input_dim = W.shape[1]
    num_outputs = W.shape[0]

    if use_device_model is None:
        use_device_model = getattr(cfg, 'USE_DEVICE_MODEL', False)
    if reset_mode is None:
        reset_mode = getattr(cfg, 'SPIKE_RESET_MODE', 'soft')
    scheme = _normalize_scheme(scheme)

    device_sim = _get_plugin_sim(num_outputs, input_dim) if use_device_model else None

    # 差分拆分 + 权重量化
    if device_sim is not None:
        G_pos, G_neg = prepare_conductance_pair_device(W, weight_bits, device_sim)
    else:
        G_pos, G_neg = prepare_conductance_pair(W, weight_bits, quant_mode)

    # Keep ADC full-scale tied to nominal conductance map (hardware-fixed reference).
    fs_cfg = estimate_adc_full_scale(G_pos, G_neg, scheme)

    # 注入器件非理想
    if add_noise:
        if device_sim is not None:
            d2d = float(device_sim.variation.die_to_die)
            c2c = float(device_sim.variation.cell_to_cell)
            G_pos, G_neg = _apply_d2d_c2c_to_diff_pair(G_pos, G_neg, d2d, c2c)
            G_pos = device_sim.apply_non_idealities(G_pos, add_noise=True, add_drift=True)
            G_neg = device_sim.apply_non_idealities(G_neg, add_noise=True, add_drift=True)
        else:
            shared_d2d = 1.0 + torch.randn(1, device=G_pos.device, dtype=G_pos.dtype) * cfg.D2D_VARIATION
            G_pos = add_device_variation(G_pos, d2d_factor=shared_d2d)
            G_neg = add_device_variation(G_neg, d2d_factor=shared_d2d)

    pixels = test_images_uint8.long()

    # 估计初始阈值
    init_samples = max(1, int(getattr(cfg, 'ADAPTIVE_INIT_SAMPLES', 512)))
    sample_n = min(init_samples, N)
    sample_membrane = torch.zeros(sample_n, num_outputs)
    for bit in range(cfg.PIXEL_BITS - 1, -1, -1):
        spike = ((pixels[:sample_n] >> bit) & 1).float()
        mac_pos = _cim_mac(spike, G_pos, device_sim)
        mac_neg = _cim_mac(spike, G_neg, device_sim)
        if scheme == 'A':
            sample_signal = mac_pos - mac_neg
            if add_noise:
                sample_signal = add_read_noise_to_signal(sample_signal, fs_cfg['signed'])
            sample_adc = quantize_adc(
                sample_signal,
                adc_bits,
                signed=True,
                full_scale=fs_cfg['signed'],
                full_scale_mode=cfg.ADC_FULL_SCALE_MODE,
            )
        else:
            if add_noise:
                mac_pos = add_read_noise_to_signal(mac_pos, fs_cfg['pos'])
                mac_neg = add_read_noise_to_signal(mac_neg, fs_cfg['neg'])
            sample_pos = quantize_adc(
                mac_pos,
                adc_bits,
                signed=False,
                full_scale=fs_cfg['pos'],
                full_scale_mode=cfg.ADC_FULL_SCALE_MODE,
            )
            sample_neg = quantize_adc(
                mac_neg,
                adc_bits,
                signed=False,
                full_scale=fs_cfg['neg'],
                full_scale_mode=cfg.ADC_FULL_SCALE_MODE,
            )
            sample_adc = sample_pos - sample_neg
        sample_membrane += sample_adc * (2 ** bit)

    init_threshold = sample_membrane.abs().median().item() * 0.8
    if init_threshold < 1e-10:
        init_threshold = 1.0

    if delta is None:
        delta = init_threshold * 0.1

    membranes = torch.zeros(N, num_outputs)
    spike_counts = torch.zeros(N, num_outputs)
    thresholds = torch.full((N, num_outputs), init_threshold)

    for frame in range(timesteps):
        for bit in range(cfg.PIXEL_BITS - 1, -1, -1):
            spike_input = ((pixels >> bit) & 1).float()
            mac_pos = _cim_mac(spike_input, G_pos, device_sim)
            mac_neg = _cim_mac(spike_input, G_neg, device_sim)

            if scheme == 'A':
                mac_diff = mac_pos - mac_neg
                if add_noise:
                    mac_diff = add_read_noise_to_signal(mac_diff, fs_cfg['signed'])
                adc_out = quantize_adc(
                    mac_diff,
                    adc_bits,
                    signed=True,
                    full_scale=fs_cfg['signed'],
                    full_scale_mode=cfg.ADC_FULL_SCALE_MODE,
                )
            else:
                if add_noise:
                    mac_pos = add_read_noise_to_signal(mac_pos, fs_cfg['pos'])
                    mac_neg = add_read_noise_to_signal(mac_neg, fs_cfg['neg'])
                adc_pos = quantize_adc(
                    mac_pos,
                    adc_bits,
                    signed=False,
                    full_scale=fs_cfg['pos'],
                    full_scale_mode=cfg.ADC_FULL_SCALE_MODE,
                )
                adc_neg = quantize_adc(
                    mac_neg,
                    adc_bits,
                    signed=False,
                    full_scale=fs_cfg['neg'],
                    full_scale_mode=cfg.ADC_FULL_SCALE_MODE,
                )
                adc_out = adc_pos - adc_neg

            membranes += adc_out * (2 ** bit)

            fired = membranes >= thresholds
            spike_counts += fired.float()
            if reset_mode == 'hard':
                membranes[fired] = 0.0
            else:
                membranes[fired] -= thresholds[fired]

            thresholds[fired] += delta
            thresholds[~fired] -= delta
            thresholds = torch.clamp(thresholds, min=init_threshold * 0.2)

    all_zero = (spike_counts.sum(dim=1) == 0)
    predictions = spike_counts.argmax(dim=1)
    predictions[all_zero] = membranes[all_zero].argmax(dim=1)

    accuracy = (predictions == test_labels).sum().item() / N
    return accuracy, spike_counts
