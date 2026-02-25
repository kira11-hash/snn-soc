# 统一章节化注释模板：每个函数均固定为 输入 / 处理 / 输出 / 为什么 四段。
"""
snn_engine.py 第三版教学导读（SNN 推理与器件非理想建模）
本文件采用统一注释风格：所有函数固定为“输入/处理/输出/为什么”四段。
使用建议：先读注释理解思路，再对照代码行走读执行路径。
本次修改只增强注释可读性，不改变任何运行逻辑。
"""

import os
import math
import inspect
import importlib.util

import torch
import numpy as np
import config as cfg

# ==========================================================
# 绗笁鐗堟暀瀛﹀璇伙紙鍙娉ㄩ噴锛屼笉鏀归€昏緫锛?# ==========================================================
# 杩欎釜鏂囦欢鏄€滀粠 ANN 鏉冮噸鍒?SNN 鎺ㄧ悊缁撴灉鈥濈殑涓诲紩鎿庛€?# 鍙寜涓嬮潰涓婚摼璺悊瑙ｏ細
# 1) 鎶婃潈閲嶆媶鎴愬樊鍒嗗骞堕噺鍖栵細`split_differential` / `quantize_weights`銆?# 2) 娉ㄥ叆鍣ㄤ欢闈炵悊鎯筹細D2D/C2C銆佽鍣０銆佹紓绉汇€両R drop銆?# 3) 缁忚繃 ADC 閲忓寲锛歚quantize_adc`銆?# 4) 鎸?bit-plane 绱姞骞跺仛绁炵粡鍏冨浣嶏細`snn_inference`銆?#
# 瀵瑰簲纭欢鎬濈淮锛?# - `scheme A/B`锛氭ā鎷熷樊鍒?vs 鏁板瓧宸垎璺緞銆?# - `full_scale`锛欰DC 鍥哄畾婊￠噺绋嬭瀹氥€?# - `reset_mode`锛歴oft/hard 涓ょ绁炵粡鍏冨浣嶇瓥鐣ャ€?

_PLUGIN_LEVELS_CACHE = None
_PLUGIN_LEVELS_LOAD_TRIED = False
_PLUGIN_SIM_CACHE = {}
_PLUGIN_MODULE_CACHE = None
_PLUGIN_MODULE_LOAD_TRIED = False
_BACKEND_NOTES = []
_BACKEND_NOTES_SEEN = set()


def _note_backend(message):
    """
    输入：
    - `message`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_note_backend` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    if message in _BACKEND_NOTES_SEEN:
        return
    _BACKEND_NOTES_SEEN.add(message)
    _BACKEND_NOTES.append(message)
    print(f"[snn_engine] {message}")


def _load_plugin_module():
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
    - `_load_plugin_module` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    # 设计目的：
    # 1) 与项目路径解耦，允许按配置切换插件文件。
    # 2) 只加载一次，避免重复 import 的性能损耗。
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
    - `_load_plugin_levels` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    # 教学注释：
    # 4-bit 下优先使用器件离散电平，可更贴近真实量化行为。
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
    输入：
    - `rows`：由调用方传入的业务数据或控制参数。
    - `cols`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_get_plugin_sim` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    # 教学注释：
    # 缓存粒度按 (rows, cols) 区分，避免每次推理都重建仿真器。
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
    - `get_device_backend_status` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
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
#  绗?閮ㄥ垎: 鏉冮噸閲忓寲
# ==========================================================

def split_differential(W):
    """
    输入：
    - `W`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `split_differential` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    W_pos = torch.clamp(W, min=0)       # 淇濈暀姝ｅ€硷紝璐熷€煎彉0
    W_neg = torch.clamp(-W, min=0)      # 璐熷€煎彇缁濆鍊硷紝姝ｅ€煎彉0
    return W_pos, W_neg


def _nearest_level_quantize(normalized_values, normalized_levels):
    """
    输入：
    - `normalized_values`：由调用方传入的业务数据或控制参数。
    - `normalized_levels`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_nearest_level_quantize` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    diff = (normalized_values.unsqueeze(-1) - normalized_levels.view(1, 1, -1)).abs()
    idx = diff.argmin(dim=-1)
    return normalized_levels[idx]


def quantize_weights(W_half, weight_bits, mode='linear', ref_max=None, plugin_levels=None):
    """
    输入：
    - `W_half`：由调用方传入的业务数据或控制参数。
    - `weight_bits`：由调用方传入的业务数据或控制参数。
    - `mode`：由调用方传入的业务数据或控制参数。
    - `ref_max`：由调用方传入的业务数据或控制参数。
    - `plugin_levels`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `quantize_weights` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    w_max = W_half.max() if ref_max is None else ref_max
    if w_max < 1e-10:
        return W_half.clone()

    num_levels = 2 ** weight_bits
    # 4-bit 时优先使用器件电平，并与正负支路共享同一 ref_max。
    if plugin_levels is not None and weight_bits == 4:
        levels = plugin_levels.to(device=W_half.device, dtype=W_half.dtype)
        normalized = torch.clamp(W_half / w_max, 0.0, 1.0)
        q_norm = _nearest_level_quantize(normalized, levels)
        return q_norm * w_max

    if mode == 'linear':
        # 绾挎€х瓑闂撮殧: [0, step, 2*step, ..., w_max]
        step = w_max / (num_levels - 1)
        W_q = torch.round(W_half / step) * step

    elif mode == 'log':
        # 瀵规暟闂撮殧: RRAM 鐢靛澶╃劧鏄鏁板垎甯冪殑
        # 鍦ㄥ鏁板煙鍋氬潎鍖€閲忓寲
        W_safe = torch.clamp(W_half, min=w_max * 1e-4)  # 閬垮厤 log(0)
        log_min = torch.log10(torch.tensor(w_max * 1e-4))
        log_max = torch.log10(w_max)
        log_step = (log_max - log_min) / (num_levels - 1)
        log_val = torch.log10(W_safe)
        log_q = torch.round((log_val - log_min) / log_step) * log_step + log_min
        W_q = torch.pow(10, log_q)
        # 鍘熸湰灏辨槸 0 鐨勪綅缃繚鎸佷负 0
        W_q[W_half < w_max * 1e-4] = 0.0

    else:
        raise ValueError(f"鏈煡閲忓寲妯″紡: {mode}")

    return torch.clamp(W_q, 0, w_max)


def prepare_conductance_pair(W, weight_bits, quant_mode='linear'):
    """
    输入：
    - `W`：由调用方传入的业务数据或控制参数。
    - `weight_bits`：由调用方传入的业务数据或控制参数。
    - `quant_mode`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `prepare_conductance_pair` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
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
    # 鏁欏娉ㄩ噴锛?    # 璁惧妯″瀷璺緞涓嬶紝閲忓寲鐩爣鏄€滅湡瀹炲閫氬€尖€濓紝骞堕檺鍒跺湪鍣ㄤ欢鍙鑼冨洿鍐呫€?    """浣跨敤鍣ㄤ欢鐢靛鐢靛钩杩涜閲忓寲锛岃繑鍥炵湡瀹炵數瀵煎€笺€?""
    """
    输入：
    - `W_half`：由调用方传入的业务数据或控制参数。
    - `weight_bits`：由调用方传入的业务数据或控制参数。
    - `device_sim`：由调用方传入的业务数据或控制参数。
    - `ref_max`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_quantize_weights_device` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    if ref_max < 1e-10:
        return W_half.clone()
    g_levels = torch.tensor(
        device_sim.conductance_levels, device=W_half.device, dtype=W_half.dtype
    )
    g_max = g_levels.max()
    normalized = torch.clamp(W_half / ref_max, 0.0, 1.0)

    if weight_bits == 4:
        # 浣跨敤鍣ㄤ欢鐪熷疄鐢靛钩锛堜笉寮鸿琛ラ浂锛屼綋鐜版紡鐢碉級
        levels_norm = g_levels / g_max
        q_norm = _nearest_level_quantize(normalized, levels_norm)
        G = q_norm * g_max
    else:
        # 鍏跺畠浣嶅锛氱嚎鎬ч噺鍖栧埌 [0, g_max]
        num_levels = 2 ** weight_bits
        step = 1.0 / (num_levels - 1)
        q_norm = torch.round(normalized / step) * step
        G = q_norm * g_max

    g_min = float(device_sim.conductance_model.g_min)
    g_max_val = float(device_sim.conductance_model.g_max)
    return torch.clamp(G, min=g_min, max=g_max_val)


def prepare_conductance_pair_device(W, weight_bits, device_sim):
    # 鏁欏娉ㄩ噴锛?    # 涓?`prepare_conductance_pair` 瀵瑰簲锛屼絾閲忓寲鍣ㄦ崲鎴?device_sim 椹卞姩銆?    """鍣ㄤ欢妯″瀷鐗堬細宸垎鎷嗗垎 + 鍣ㄤ欢鐢靛閲忓寲銆?""
    """
    输入：
    - `W`：由调用方传入的业务数据或控制参数。
    - `weight_bits`：由调用方传入的业务数据或控制参数。
    - `device_sim`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `prepare_conductance_pair_device` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    W_pos, W_neg = split_differential(W)
    shared_max = W.abs().max()
    if shared_max < 1e-10:
        return W_pos.clone(), W_neg.clone()
    G_pos = _quantize_weights_device(W_pos, weight_bits, device_sim, shared_max)
    G_neg = _quantize_weights_device(W_neg, weight_bits, device_sim, shared_max)
    return G_pos, G_neg


def _cim_mac(spike_input, G, device_sim=None):
    # 鏁欏娉ㄩ噴锛?    # CIM 鐨勬牳蹇冪畻瀛愶細I = G * V锛屽啀鎸夊垪姹傚拰寰楀埌姣忎釜杈撳嚭閫氶亾鐢垫祦銆?    """CIM 鐭╅樀涔樻硶锛氬彲閫?IR drop 浠跨湡銆?""
    """
    输入：
    - `spike_input`：由调用方传入的业务数据或控制参数。
    - `G`：由调用方传入的业务数据或控制参数。
    - `device_sim`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_cim_mac` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    if device_sim is not None and device_sim.interconnect.ir_drop_active:
        v_effective = device_sim.ir_simulator.compute_effective_voltages(spike_input, G)
        current_map = G.unsqueeze(0) * v_effective
        return current_map.sum(dim=2)
    return spike_input @ G.T


def _estimate_spike_threshold(fs_cfg, timesteps, ratio):
    # 鏁欏娉ㄩ噴锛?    # 杩欓噷闃堝€间笌 ADC 婊￠噺绋嬨€佸儚绱犱綅瀹姐€佹椂闂存鎴愭瘮渚嬶紝
    # 鐩磋涓婃槸鈥滄妸闃堝€煎浐瀹氬埌绯荤粺鍙敤鍔ㄦ€佽寖鍥寸殑涓€瀹氭瘮渚嬧€濄€?    """浼扮畻鍥哄畾闃堝€硷紙涓?RTL 鐨?~60% 缁忛獙涓€鑷达級銆?""
    """
    输入：
    - `fs_cfg`：由调用方传入的业务数据或控制参数。
    - `timesteps`：由调用方传入的业务数据或控制参数。
    - `ratio`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_estimate_spike_threshold` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    if "signed" in fs_cfg:
        full_scale = fs_cfg["signed"]
    else:
        full_scale = max(fs_cfg["pos"], fs_cfg["neg"])
    return full_scale * ((1 << cfg.PIXEL_BITS) - 1) * max(1, timesteps) * ratio


def _apply_d2d_c2c_to_diff_pair(G_pos, G_neg, d2d, c2c):
    """
    输入：
    - `G_pos`：由调用方传入的业务数据或控制参数。
    - `G_neg`：由调用方传入的业务数据或控制参数。
    - `d2d`：由调用方传入的业务数据或控制参数。
    - `c2c`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_apply_d2d_c2c_to_diff_pair` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    d2d_factor = 1.0 + torch.randn(1, device=G_pos.device, dtype=G_pos.dtype) * d2d
    c2c_pos = 1.0 + torch.randn_like(G_pos) * c2c
    c2c_neg = 1.0 + torch.randn_like(G_neg) * c2c
    G_pos_out = G_pos * d2d_factor * c2c_pos
    G_neg_out = G_neg * d2d_factor * c2c_neg
    return G_pos_out, G_neg_out


# ==========================================================
#  绗?閮ㄥ垎: 鍣ㄤ欢闈炵悊鎯虫€?# ==========================================================

def add_device_variation(W_q, d2d=None, c2c=None, d2d_factor=None):
    """
    输入：
    - `W_q`：由调用方传入的业务数据或控制参数。
    - `d2d`：由调用方传入的业务数据或控制参数。
    - `c2c`：由调用方传入的业务数据或控制参数。
    - `d2d_factor`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `add_device_variation` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    if d2d is None:
        d2d = cfg.D2D_VARIATION
    if c2c is None:
        c2c = cfg.C2C_VARIATION

    # D2D: 鏁翠綋涔樻€у亸绉?(鎵€鏈夊崟鍏冨悓涓€涓殢鏈哄洜瀛?
    if d2d_factor is None:
        d2d_factor = 1.0 + torch.randn(1, device=W_q.device, dtype=W_q.dtype) * d2d
    # C2C: 逐单元乘性偏移。
    c2c_factor = 1.0 + torch.randn_like(W_q) * c2c
    W_noisy = W_q * d2d_factor * c2c_factor
    return torch.clamp(W_noisy, min=0)  # 鐢靛涓嶈兘涓鸿礋


def add_read_noise(W_q, noise_sigma=None):
    """
    输入：
    - `W_q`：由调用方传入的业务数据或控制参数。
    - `noise_sigma`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `add_read_noise` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
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
    输入：
    - `signal`：由调用方传入的业务数据或控制参数。
    - `full_scale`：由调用方传入的业务数据或控制参数。
    - `noise_sigma`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `add_read_noise_to_signal` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    if noise_sigma is None:
        noise_sigma = cfg.READ_NOISE_SIGMA
    sigma = noise_sigma * max(full_scale, 1e-12)
    return signal + torch.randn_like(signal) * sigma


# ==========================================================
#  绗?閮ㄥ垎: ADC 閲忓寲
# ==========================================================

def quantize_adc(values, adc_bits, signed=True, full_scale=None, full_scale_mode=None):
    """
    输入：
    - `values`：由调用方传入的业务数据或控制参数。
    - `adc_bits`：由调用方传入的业务数据或控制参数。
    - `signed`：由调用方传入的业务数据或控制参数。
    - `full_scale`：由调用方传入的业务数据或控制参数。
    - `full_scale_mode`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `quantize_adc` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    if full_scale_mode is None:
        full_scale_mode = cfg.ADC_FULL_SCALE_MODE

    num_levels = 2 ** adc_bits
    use_dynamic_fs = (full_scale_mode == "dynamic") or (full_scale is None)

    if signed:
        # 鏈夌鍙?ADC (鏂规 A: I_pos - I_neg, 缁撴灉鍙鍙礋)
        # 閲忕▼: [-full_scale, +full_scale]
        if use_dynamic_fs:
            full_scale = values.abs().max().item()
        if full_scale < 1e-30:
            return values
        step = (2 * full_scale) / (num_levels - 1)
        quantized = torch.round(values / step) * step
        return torch.clamp(quantized, -full_scale, full_scale)
    else:
        # 鏃犵鍙?ADC (鏂规 B: 鍗曡矾 I_pos 鎴?I_neg, 鍙湁姝ｅ€?
        if use_dynamic_fs:
            full_scale = values.max().item()
        if full_scale < 1e-30:
            return values
        step = full_scale / (num_levels - 1)
        quantized = torch.round(values / step) * step
        return torch.clamp(quantized, 0, full_scale)


# ==========================================================
#  绗?閮ㄥ垎: SNN 鎺ㄧ悊 (鍖归厤 RTL 琛屼负)
# ==========================================================

def estimate_adc_full_scale(G_pos, G_neg, scheme):
    """
    输入：
    - `G_pos`：由调用方传入的业务数据或控制参数。
    - `G_neg`：由调用方传入的业务数据或控制参数。
    - `scheme`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `estimate_adc_full_scale` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    pos_fs = G_pos.sum(dim=1).max().item()
    neg_fs = G_neg.sum(dim=1).max().item()
    if scheme == 'A':
        return {"signed": max(pos_fs, neg_fs)}
    return {"pos": pos_fs, "neg": neg_fs}


def _normalize_scheme(scheme):
    """
    输入：
    - `scheme`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `_normalize_scheme` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
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
                  reset_mode=None, use_device_model=None):
    """
    输入：
    - `test_images_uint8`：由调用方传入的业务数据或控制参数。
    - `test_labels`：由调用方传入的业务数据或控制参数。
    - `W`：由调用方传入的业务数据或控制参数。
    - `adc_bits`：由调用方传入的业务数据或控制参数。
    - `weight_bits`：由调用方传入的业务数据或控制参数。
    - `timesteps`：由调用方传入的业务数据或控制参数。
    - `scheme`：由调用方传入的业务数据或控制参数。
    - `add_noise`：由调用方传入的业务数据或控制参数。
    - `quant_mode`：由调用方传入的业务数据或控制参数。
    - `decision`：由调用方传入的业务数据或控制参数。
    - `threshold_ratio`：由调用方传入的业务数据或控制参数。
    - `threshold`：由调用方传入的业务数据或控制参数。
    - `reset_mode`：由调用方传入的业务数据或控制参数。
    - `use_device_model`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `snn_inference` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    # 教学阅读提示：
    # 先看 Step1/2（导通准备），再看 Step3（非理想注入），
    # 最后看 Step4/5（bit-plane 累加与分类决策）。
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

    # ---- Step 1 + 2: 宸垎鎷嗗垎 + 鏉冮噸閲忓寲 ----
    if device_sim is not None:
        G_pos, G_neg = prepare_conductance_pair_device(W, weight_bits, device_sim)
    else:
        G_pos, G_neg = prepare_conductance_pair(W, weight_bits, quant_mode)

    # Keep ADC full-scale tied to nominal conductance map (hardware-fixed reference).
    fs_cfg = estimate_adc_full_scale(G_pos, G_neg, scheme)

    # ---- Step 3: 娉ㄥ叆鍣ㄤ欢闈炵悊鎯?----
    if add_noise:
        if device_sim is not None:
            # D2D/C2C 鍏变韩鍚屼竴涓?D2D 绯荤粺鍋忕Щ
            d2d = float(device_sim.variation.die_to_die)
            c2c = float(device_sim.variation.cell_to_cell)
            G_pos, G_neg = _apply_d2d_c2c_to_diff_pair(G_pos, G_neg, d2d, c2c)
            # 再叠加读噪声与漂移。
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

    # ---- Step 4: Bit-plane SNN 绱姞 ----
    membranes = torch.zeros(N, num_outputs, dtype=torch.float32)
    spike_counts = torch.zeros(N, num_outputs, dtype=torch.float32) if use_spike else None

    pixels = test_images_uint8.long()  # [N, input_dim]

    for frame in range(timesteps):
        for bit in range(cfg.PIXEL_BITS - 1, -1, -1):
            spike_input = ((pixels >> bit) & 1).float()  # [N, input_dim]
            # CIM MAC（可选 IR-drop 建模）。
            mac_pos = _cim_mac(spike_input, G_pos, device_sim)
            mac_neg = _cim_mac(spike_input, G_neg, device_sim)

            # 宸垎鏂规 + ADC 閲忓寲
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
                raise ValueError(f"鏈煡宸垎鏂规: {scheme}")

            membranes += adc_out * (2 ** bit)

            if use_spike:
                fired = membranes >= threshold
                spike_counts += fired.float()
                if reset_mode == 'hard':
                    membranes[fired] = 0.0
                else:
                    membranes[fired] -= threshold

    # ---- Step 5: 鍒嗙被鍐崇瓥 ----
    if use_spike:
        predictions = spike_counts.argmax(dim=1)
        all_zero = (spike_counts.sum(dim=1) == 0)
        predictions[all_zero] = membranes[all_zero].argmax(dim=1)
    else:
        predictions = membranes.argmax(dim=1)

    accuracy = (predictions == test_labels).sum().item() / N
    return accuracy, membranes


def snn_inference_ideal(test_images_uint8, test_labels, W, timesteps=1):
    """
    输入：
    - `test_images_uint8`：由调用方传入的业务数据或控制参数。
    - `test_labels`：由调用方传入的业务数据或控制参数。
    - `W`：由调用方传入的业务数据或控制参数。
    - `timesteps`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `snn_inference_ideal` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
    """
    N = test_images_uint8.shape[0]
    membranes = torch.zeros(N, W.shape[0])
    pixels = test_images_uint8.long()

    for frame in range(timesteps):
        for bit in range(cfg.PIXEL_BITS - 1, -1, -1):
            spike_input = ((pixels >> bit) & 1).float()
            mac = spike_input @ W.T  # 鐩存帴鐢ㄥ師濮嬫潈閲嶏紝鏃犲樊鍒嗘媶鍒?            membranes += mac * (2 ** bit)

    predictions = membranes.argmax(dim=1)
    accuracy = (predictions == test_labels).sum().item() / N
    return accuracy


# ==========================================================
#  绗?閮ㄥ垎: 鑷€傚簲闃堝€兼帹鐞?# ==========================================================

def snn_inference_adaptive_threshold(test_images_uint8, test_labels, W,
                                      adc_bits=8, weight_bits=4,
                                      timesteps=10, scheme='A',
                                      delta=None, quant_mode='linear',
                                      use_device_model=None, add_noise=False,
                                      reset_mode=None):
    """
    输入：
    - `test_images_uint8`：由调用方传入的业务数据或控制参数。
    - `test_labels`：由调用方传入的业务数据或控制参数。
    - `W`：由调用方传入的业务数据或控制参数。
    - `adc_bits`：由调用方传入的业务数据或控制参数。
    - `weight_bits`：由调用方传入的业务数据或控制参数。
    - `timesteps`：由调用方传入的业务数据或控制参数。
    - `scheme`：由调用方传入的业务数据或控制参数。
    - `delta`：由调用方传入的业务数据或控制参数。
    - `quant_mode`：由调用方传入的业务数据或控制参数。
    - `use_device_model`：由调用方传入的业务数据或控制参数。
    - `add_noise`：由调用方传入的业务数据或控制参数。
    - `reset_mode`：由调用方传入的业务数据或控制参数。
    
    处理：
    - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
    - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
    - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
    
    输出：
    - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
    - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
    
    为什么：
    - `snn_inference_adaptive_threshold` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
    - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
    - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
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

    # 宸垎鎷嗗垎 + 鏉冮噸閲忓寲
    if device_sim is not None:
        G_pos, G_neg = prepare_conductance_pair_device(W, weight_bits, device_sim)
    else:
        G_pos, G_neg = prepare_conductance_pair(W, weight_bits, quant_mode)

    # Keep ADC full-scale tied to nominal conductance map (hardware-fixed reference).
    fs_cfg = estimate_adc_full_scale(G_pos, G_neg, scheme)
    # 注入器件非理想。
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
    # 估计初始阈值。
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


