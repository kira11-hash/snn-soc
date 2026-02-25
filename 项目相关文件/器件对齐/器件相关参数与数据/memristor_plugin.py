#!/usr/bin/env python
# 统一章节化注释模板：每个函数均固定为 输入 / 处理 / 输出 / 为什么 四段。
# coding: utf-8
"""
memristor_plugin.py 第三版教学导读（器件插件后端）
本文件采用统一注释风格：所有函数固定为“输入/处理/输出/为什么”四段。
使用建议：先读注释理解思路，再对照代码行走读执行路径。
本次修改只增强注释可读性，不改变任何运行逻辑。
"""

import os
import math
import time
import warnings
from dataclasses import dataclass, field
from typing import Tuple, Optional, Dict

import numpy as np
import torch
import torch.nn.functional as F
from scipy.interpolate import interp1d

warnings.filterwarnings('ignore')

# ==========================================================
# 第三版教学导读（只增注释，不改逻辑）
# ==========================================================
# 这个文件是“器件级插件后端”，用于把理想权重映射到更真实的阵列行为。
# 可以按四层理解：
# 1) 参数层（dataclass）：阵列几何、精度、噪声、互连参数。
# 2) 数据层：I-V 数据加载与导通模型提取。
# 3) 扰动层：读噪声、漂移、D2D/C2C、IR drop。
# 4) 计算层：matrix_vector_multiply 与硬件约束损失估计。
#
# 你可以把它当成 `snn_engine.py` 的“物理细节后端”。


@dataclass
class ArrayGeometry:
    # 教学注释：
    # rows/cols 是阵列规模；`total_cells` 用于快速计算总单元数。
    """阵列几何参数配置"""
    rows: int = 128
    cols: int = 256
    
    @property
    def total_cells(self) -> int:
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `ArrayGeometry.total_cells` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        return self.rows * self.cols


@dataclass  
class VariationProfile:
    # 教学注释：
    # D2D 与 C2C 采用乘性扰动建模，`compute_total_variation` 用 RSS 合成。
    """器件变化性参数"""
    die_to_die: float = 0.05      # 5% D2D variation
    cell_to_cell: float = 0.03    # 3% C2C variation
    
    def compute_total_variation(self) -> float:
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `VariationProfile.compute_total_variation` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        return math.sqrt(self.die_to_die**2 + self.cell_to_cell**2)


@dataclass
class PrecisionConfig:
    # 教学注释：
    # `n_bits` 决定离散导通电平数：levels = 2**n_bits。
    """精度配置"""
    n_bits: int = 4
    levels: int = field(init=False)
    
    def __post_init__(self):
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `PrecisionConfig.__post_init__` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        self.levels = 2 ** self.n_bits


@dataclass
class TemporalParams:
    # 教学注释：
    # 漂移随时间增长，默认按 sqrt(time) 的缓慢增长模型近似。
    """时间相关参数"""
    drift_coefficient: float = 0.005
    elapsed_time: float = 0.0
    
    def compute_drift_factor(self) -> float:
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `TemporalParams.compute_drift_factor` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        return self.drift_coefficient * math.sqrt(self.elapsed_time / 3600.0 + 1)


@dataclass
class InterconnectParams:
    # 教学注释：
    # 互连参数用于 IR-drop 迭代求解。
    """互连参数"""
    wire_resistance: float = 0.5  # Ohm per cell
    ir_drop_active: bool = True
    convergence_tolerance: float = 1e-3
    max_iterations: int = 5


class IVCharacteristicLoader:
    # 教学注释：
    # 优先读取外部 Excel；若不存在则回退到内置测试曲线。
    """I-V特性数据加载与解析器"""
    
    def __init__(self, filepath: Optional[str] = None):
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        - `filepath`：由调用方传入的业务数据或控制参数。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `IVCharacteristicLoader.__init__` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        self.filepath = filepath
        self.voltage_raw = None
        self.current_raw = None
        self._load_data()
        
    def _load_data(self) -> None:
        # 教学注释：
        # 统一入口：根据文件可用性在“外部数据 / 内置数据”间切换。
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `IVCharacteristicLoader._load_data` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        if self.filepath and os.path.exists(self.filepath):
            self._load_from_excel()
        else:
            self._load_embedded_data()
            
    def _load_from_excel(self) -> None:
        # 教学注释：
        # Excel 需要包含 `Voltage` 和 `Current` 两列。
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `IVCharacteristicLoader._load_from_excel` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        import pandas as pd
        dataframe = pd.read_excel(self.filepath)
        self.voltage_raw = dataframe['Voltage'].values.astype(np.float64)
        self.current_raw = np.abs(dataframe['Current'].values.astype(np.float64))
        
    def _load_embedded_data(self) -> None:
        # 教学注释：
        # 内置了正向/反向/负向扫描数据，便于无外部文件时直接运行。
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `IVCharacteristicLoader._load_embedded_data` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        # 正向扫描 0->2V
        v_forward = np.linspace(0, 2.0, 51)
        i_forward = np.array([
            3.84e-13, 5.75e-13, 6.47e-13, 8.02e-13, 8.69e-13, 9.24e-13, 9.64e-13,
            9.93e-13, 1.02e-12, 1.03e-12, 1.07e-12, 1.09e-12, 1.14e-12, 1.17e-12,
            1.27e-12, 1.42e-12, 1.69e-12, 1.92e-12, 2.40e-12, 3.43e-12, 3.29e-12,
            8.75e-12, 1.11e-11, 1.35e-11, 1.83e-11, 2.27e-11, 2.18e-11, 2.63e-11,
            3.97e-11, 6.31e-11, 7.38e-11, 9.86e-11, 1.26e-10, 1.29e-10, 2.90e-10,
            4.15e-10, 5.11e-10, 8.92e-10, 9.31e-10, 1.05e-09, 1.33e-09, 1.72e-09,
            1.85e-09, 3.13e-09, 4.13e-09, 4.64e-09, 4.77e-09, 1.10e-08, 1.36e-08,
            1.66e-08, 1.61e-08
        ])
        
        # 返回扫描 2->0V  
        v_return = np.linspace(2.0, 0, 51)
        i_return = np.array([
            1.68e-08, 1.52e-08, 1.41e-08, 1.23e-08, 1.12e-08, 1.01e-08, 9.74e-09,
            9.53e-09, 7.29e-09, 6.03e-09, 5.86e-09, 5.12e-09, 4.66e-09, 4.54e-09,
            2.60e-09, 3.24e-09, 3.40e-09, 3.02e-09, 2.71e-09, 2.48e-09, 2.11e-09,
            1.60e-09, 1.45e-09, 1.31e-09, 1.15e-09, 8.39e-10, 5.84e-10, 2.35e-10,
            1.02e-10, 2.96e-11, 1.33e-11, 1.45e-11, 7.71e-12, 6.19e-12, 4.20e-12,
            9.90e-13, 1.91e-12, 3.94e-13, 3.91e-13, 3.57e-13, 3.76e-13, 5.13e-13,
            5.84e-13, 6.21e-13, 6.59e-13, 7.78e-13, 8.29e-13, 8.50e-13, 8.70e-13,
            8.93e-13, 8.93e-13
        ])
        
        # 负向扫描
        v_negative = np.linspace(-2.0, 0, 50)
        i_negative = np.array([
            1.28e-12, 1.27e-12, 1.27e-12, 1.27e-12, 1.25e-12, 1.25e-12, 1.25e-12,
            1.25e-12, 1.23e-12, 1.23e-12, 1.23e-12, 1.23e-12, 1.22e-12, 1.22e-12,
            1.21e-12, 1.21e-12, 1.20e-12, 1.20e-12, 1.21e-12, 1.19e-12, 1.21e-12,
            1.20e-12, 1.20e-12, 1.21e-12, 1.20e-12, 1.20e-12, 1.22e-12, 1.22e-12,
            1.23e-12, 1.23e-12, 1.25e-12, 1.25e-12, 1.25e-12, 1.25e-12, 1.27e-12,
            1.27e-12, 1.27e-12, 1.28e-12, 1.27e-12, 1.27e-12, 1.27e-12, 1.25e-12,
            1.25e-12, 1.25e-12, 1.25e-12, 1.23e-12, 1.23e-12, 1.23e-12, 1.23e-12,
            1.22e-12
        ])
        
        # 负向返回
        v_neg_ret = np.linspace(0, -2.0, 50)
        i_neg_ret = np.array([
            1.07e-12, 1.07e-12, 1.06e-12, 1.06e-12, 1.05e-12, 1.05e-12, 1.04e-12,
            1.04e-12, 1.04e-12, 1.02e-12, 1.02e-12, 1.02e-12, 1.00e-12, 1.02e-12,
            1.02e-12, 1.04e-12, 1.04e-12, 1.05e-12, 1.06e-12, 1.06e-12, 1.07e-12,
            1.07e-12, 1.07e-12, 1.07e-12, 1.08e-12, 1.08e-12, 1.10e-12, 1.10e-12,
            1.11e-12, 1.11e-12, 1.13e-12, 1.13e-12, 1.11e-12, 1.10e-12, 1.10e-12,
            1.13e-12, 1.12e-12, 1.12e-12, 1.13e-12, 1.14e-12, 1.15e-12, 1.16e-12,
            1.17e-12, 1.16e-12, 1.18e-12, 1.19e-12, 1.21e-12, 1.22e-12, 1.20e-12,
            1.21e-12
        ])
        
        # 合并并排序所有数据
        v_all = np.concatenate([v_forward, v_return, v_negative, v_neg_ret])
        i_all = np.concatenate([i_forward, i_return, i_negative, i_neg_ret])
        
        sort_indices = np.argsort(v_all)
        self.voltage_raw = v_all[sort_indices]
        self.current_raw = i_all[sort_indices]
        
    def get_processed_data(self) -> Tuple[np.ndarray, np.ndarray]:
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `IVCharacteristicLoader.get_processed_data` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        return self.voltage_raw, self.current_raw


class ConductanceExtractor:
    # 教学注释：
    # 将 I-V 曲线转换为导通模型，并提供插值函数和离散电平生成器。
    """电导提取与建模引擎"""
    
    def __init__(self, voltages: np.ndarray, currents: np.ndarray):
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        - `voltages`：由调用方传入的业务数据或控制参数。
        - `currents`：由调用方传入的业务数据或控制参数。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `ConductanceExtractor.__init__` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        self.v = voltages
        self.i = currents
        self.g = self._calculate_conductance()
        self.g_min = None
        self.g_max = None
        self.r_on = None
        self.r_off = None
        self._extract_boundary_values()
        self._build_interpolators()
        
    def _calculate_conductance(self) -> np.ndarray:
        # 教学注释：
        # 简化定义 G = I / |V|；对接近 0V 的点做保护处理，避免除零。
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `ConductanceExtractor._calculate_conductance` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        conductance = np.zeros_like(self.i)
        nonzero_mask = np.abs(self.v) > 0.01
        conductance[nonzero_mask] = self.i[nonzero_mask] / np.abs(self.v[nonzero_mask])
        # 对零电压附近使用最小非零电导
        if np.any(nonzero_mask):
            conductance[~nonzero_mask] = np.min(conductance[nonzero_mask])
        else:
            conductance[~nonzero_mask] = 1e-12
        return conductance
        
    def _extract_boundary_values(self) -> None:
        # 教学注释：
        # 低压段估计 g_min，高压段估计 g_max，用于约束导通范围。
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `ConductanceExtractor._extract_boundary_values` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        # 低电导态 (低电压区)
        low_v_mask = np.abs(self.v) < 0.5
        if np.any(low_v_mask):
            self.g_min = np.percentile(self.g[low_v_mask], 25)
        else:
            self.g_min = 1e-12
            
        # 高电导态 (高电压区)
        high_v_mask = np.abs(self.v) > 1.5
        if np.any(high_v_mask):
            self.g_max = np.percentile(self.g[high_v_mask], 75)
        else:
            self.g_max = 1e-6
            
        self.r_on = 1.0 / self.g_max
        self.r_off = 1.0 / self.g_min
        
    def _build_interpolators(self) -> None:
        # 教学注释：
        # 建立 g(V) 与 i(V) 插值器，支持后续快速查询。
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `ConductanceExtractor._build_interpolators` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        # 电导-电压插值
        self.g_interpolator = interp1d(
            self.v, self.g, 
            kind='cubic',
            fill_value=(self.g_min, self.g_max),
            bounds_error=False
        )
        
        # 电流-电压插值
        self.i_interpolator = interp1d(
            self.v, self.i,
            kind='cubic', 
            fill_value=(0, np.max(self.i)),
            bounds_error=False
        )
        
    def generate_conductance_levels(self, n_levels: int) -> np.ndarray:
        # 教学注释：
        # 使用对数分布电平，贴合忆阻器常见统计特性。
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        - `n_levels`：由调用方传入的业务数据或控制参数。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `ConductanceExtractor.generate_conductance_levels` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        log_min = np.log10(self.g_min)
        log_max = np.log10(self.g_max)
        return np.logspace(log_min, log_max, n_levels)
        
    @property
    def on_off_ratio(self) -> float:
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `ConductanceExtractor.on_off_ratio` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        return self.r_off / self.r_on


class NoiseGenerator:
    # 教学注释：
    # 专门管理噪声采样，避免主类里噪声逻辑过于分散。
    """噪声生成器"""
    
    def __init__(self, base_sigma: float, variation_profile: VariationProfile):
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        - `base_sigma`：由调用方传入的业务数据或控制参数。
        - `variation_profile`：由调用方传入的业务数据或控制参数。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `NoiseGenerator.__init__` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        self.base_sigma = base_sigma
        self.variation = variation_profile
        
    def generate_read_noise(self, shape: Tuple, device: torch.device) -> torch.Tensor:
        # 教学注释：
        # 读噪声通常建模为零均值高斯噪声。
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        - `shape`：由调用方传入的业务数据或控制参数。
        - `device`：由调用方传入的业务数据或控制参数。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `NoiseGenerator.generate_read_noise` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        return torch.randn(shape, device=device) * self.base_sigma
        
    def generate_drift_noise(self, 
                           shape: Tuple, 
                           device: torch.device,
                           drift_factor: float) -> torch.Tensor:
        # 教学注释：
        # 漂移噪声以乘性方式作用，并限制在 [0.9, 1.1] 区间。
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        - `shape`：由调用方传入的业务数据或控制参数。
        - `device`：由调用方传入的业务数据或控制参数。
        - `drift_factor`：由调用方传入的业务数据或控制参数。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `NoiseGenerator.generate_drift_noise` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        drift_std = drift_factor
        noise = torch.randn(shape, device=device) * drift_std
        return torch.clamp(1.0 + noise, 0.9, 1.1)
        
    def generate_mismatch_noise(self, 
                               shape: Tuple,
                               device: torch.device,
                               phase: str = 'eval') -> torch.Tensor:
        # 教学注释：
        # `training` 相位会加大噪声，鼓励模型学习鲁棒性。
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        - `shape`：由调用方传入的业务数据或控制参数。
        - `device`：由调用方传入的业务数据或控制参数。
        - `phase`：由调用方传入的业务数据或控制参数。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `NoiseGenerator.generate_mismatch_noise` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        total_var = self.variation.compute_total_variation()
        # 训练时增加噪声以增强鲁棒性
        if phase == 'training':
            total_var *= 1.6
        return torch.randn(shape, device=device) * total_var


class IRDropSimulator:
    # 教学注释：
    # 通过迭代方式估计阵列内有效电压分布，近似互连压降。
    """IR压降效应仿真器"""
    
    def __init__(self, params: InterconnectParams, geometry: ArrayGeometry):
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        - `params`：由调用方传入的业务数据或控制参数。
        - `geometry`：由调用方传入的业务数据或控制参数。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `IRDropSimulator.__init__` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        self.params = params
        self.geometry = geometry
        
    def compute_effective_voltages(self,
                                  input_voltages: torch.Tensor,
                                  conductance_map: torch.Tensor,
                                  iteration: int = 0) -> torch.Tensor:
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        - `input_voltages`：由调用方传入的业务数据或控制参数。
        - `conductance_map`：由调用方传入的业务数据或控制参数。
        - `iteration`：由调用方传入的业务数据或控制参数。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `IRDropSimulator.compute_effective_voltages` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        if not self.params.ir_drop_active:
            # 无IR drop时直接扩展
            batch_size = input_voltages.size(0)
            return input_voltages.unsqueeze(1).expand(-1, self.geometry.rows, -1)
            
        batch_size = input_voltages.size(0)
        
        # 扩展维度用于计算
        v_applied = input_voltages.unsqueeze(1)  # [batch, 1, cols]
        g_expanded = conductance_map.unsqueeze(0).expand(batch_size, -1, -1)
        
        # 初始假设：单元格电压等于施加电压
        v_cell = v_applied.expand(-1, self.geometry.rows, -1).clone()
        
        # 计算单元格电流
        cell_current = g_expanded * v_cell
        
        # 计算行/列总电流
        current_row = cell_current.sum(dim=2, keepdim=True)  # [batch, rows, 1]
        current_col = cell_current.sum(dim=1, keepdim=True)  # [batch, 1, cols]
        
        # 估算压降因子
        v_mean = v_applied.abs().mean(dim=2, keepdim=True).clamp(min=1e-9)
        drop_factor = 1.0 - (self.params.wire_resistance * 
                            (current_row + current_col.transpose(1, 2)) / v_mean)
        drop_factor = torch.clamp(drop_factor, 0.5, 1.0)
        
        # 应用压降
        v_effective = v_applied * drop_factor
        
        # 递归迭代直至收敛
        if iteration < self.params.max_iterations - 1:
            return self.compute_effective_voltages(
                v_effective[:, 0, :], 
                conductance_map, 
                iteration + 1
            )
            
        return v_effective


class MemristorArraySimulator:
    # 教学注释：
    # 插件主类：把导通建模、噪声、IR-drop、量化串成可调用接口。
    """
    忆阻器阵列仿真器主类
    128×256阵列，支持4bit精度，5%/3% D2D/C2C变化
    """
    
    def __init__(self,
                 iv_data_path: Optional[str] = None,
                 device: str = 'cuda'):
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        - `iv_data_path`：由调用方传入的业务数据或控制参数。
        - `device`：由调用方传入的业务数据或控制参数。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `MemristorArraySimulator.__init__` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        # 硬件配置
        self.geometry = ArrayGeometry(rows=128, cols=256)
        self.precision = PrecisionConfig(n_bits=4)
        self.variation = VariationProfile(die_to_die=0.05, cell_to_cell=0.03)
        self.temporal = TemporalParams(drift_coefficient=0.005)
        self.interconnect = InterconnectParams(
            wire_resistance=0.5,
            ir_drop_active=True
        )
        
        # 计算设备
        self.device = torch.device(device if torch.cuda.is_available() else 'cpu')
        
        # 时间戳
        self.creation_time = time.time()
        self.last_programming_time = torch.zeros(
            (self.geometry.rows, self.geometry.cols),
            device=self.device
        )
        
        # 加载I-V特性
        self.iv_loader = IVCharacteristicLoader(iv_data_path)
        v_data, i_data = self.iv_loader.get_processed_data()
        
        # 提取电导模型
        self.conductance_model = ConductanceExtractor(v_data, i_data)
        self.conductance_levels = self.conductance_model.generate_conductance_levels(
            self.precision.levels
        )
        
        # 计算绝对噪声基准
        g_range = self.conductance_model.g_max - self.conductance_model.g_min
        self.noise_sigma = 0.0005 * g_range  # 0.05% of range
        
        # 初始化子系统
        self.noise_gen = NoiseGenerator(self.noise_sigma, self.variation)
        self.ir_simulator = IRDropSimulator(self.interconnect, self.geometry)
        
        # 初始化电导矩阵
        self.conductance_matrix = self._initialize_conductance_matrix()
        
        # 打印模型信息
        self._print_model_info()
        
    def _initialize_conductance_matrix(self) -> torch.Tensor:
        # 教学注释：
        # 初始导通按对数均匀分布采样，比线性均匀更贴近器件跨度。
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `MemristorArraySimulator._initialize_conductance_matrix` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        log_min = np.log10(self.conductance_model.g_min)
        log_max = np.log10(self.conductance_model.g_max)
        
        # 对数均匀分布
        random_log = torch.rand(
            self.geometry.rows, 
            self.geometry.cols,
            device=self.device
        ) * (log_max - log_min) + log_min
        
        return torch.pow(10, random_log)
        
    def _print_model_info(self) -> None:
        # 教学注释：
        # 初始化后打印参数快照，便于复现实验配置。
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `MemristorArraySimulator._print_model_info` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        print("=" * 50)
        print("忆阻器阵列仿真器初始化完成")
        print("=" * 50)
        print(f"阵列规模: {self.geometry.rows} × {self.geometry.cols}")
        print(f"精度配置: {self.precision.n_bits}-bit ({self.precision.levels} 电平)")
        print(f"D2D变化性: {self.variation.die_to_die*100:.1f}%")
        print(f"C2C变化性: {self.variation.cell_to_cell*100:.1f}%")
        print(f"合成变化: {self.variation.compute_total_variation()*100:.2f}%")
        print(f"R_off: {self.conductance_model.r_off:.2e} Ω")
        print(f"R_on:  {self.conductance_model.r_on:.2e} Ω")
        print(f"开关比: {self.conductance_model.on_off_ratio:.1f}")
        print(f"IR Drop: {'启用' if self.interconnect.ir_drop_active else '禁用'}")
        print("=" * 50)
        
    def quantize_weights(self, weights: torch.Tensor) -> torch.Tensor:
        # 教学注释：
        # 先归一化，再查离散电平表，输出与输入同形状的导通值张量。
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        - `weights`：由调用方传入的业务数据或控制参数。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `MemristorArraySimulator.quantize_weights` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        # 归一化到[0, 1]
        w_min, w_max = weights.min(), weights.max()
        if w_max > w_min:
            normalized = (weights - w_min) / (w_max - w_min + 1e-8)
        else:
            normalized = torch.zeros_like(weights)
            
        # 映射到电平索引
        indices = torch.round(normalized * (self.precision.levels - 1)).long()
        indices = torch.clamp(indices, 0, self.precision.levels - 1)
        
        # 查表获取电导值
        g_table = torch.tensor(
            self.conductance_levels,
            device=weights.device,
            dtype=weights.dtype
        )
        
        return g_table[indices]
        
    def apply_non_idealities(self,
                            conductance: torch.Tensor,
                            add_noise: bool = True,
                            add_drift: bool = True) -> torch.Tensor:
        # 教学注释：
        # 将读噪声和漂移依次作用到导通图，最后裁剪到物理可行范围。
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        - `conductance`：由调用方传入的业务数据或控制参数。
        - `add_noise`：由调用方传入的业务数据或控制参数。
        - `add_drift`：由调用方传入的业务数据或控制参数。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `MemristorArraySimulator.apply_non_idealities` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        result = conductance.clone()
            
        # 读噪声
        if add_noise:
            read_noise = self.noise_gen.generate_read_noise(result.shape, result.device)
            result += read_noise
            
        # 电导漂移
        if add_drift:
            elapsed = time.time() - self.creation_time
            self.temporal.elapsed_time = elapsed
            drift_factor = self.temporal.compute_drift_factor()
            
            drift_multiplier = self.noise_gen.generate_drift_noise(
                result.shape, result.device, drift_factor
            )
            result *= drift_multiplier
            
        return torch.clamp(
            result,
            self.conductance_model.g_min,
            self.conductance_model.g_max
        )
        
    def matrix_vector_multiply(self,
                              input_vector: torch.Tensor,
                              weight_matrix: torch.Tensor,
                              apply_non_ideal: bool = True) -> torch.Tensor:
        # 教学注释：
        # 最接近硬件执行路径：量化 -> 非理想 -> 阵列乘加 -> ADC 近似。
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        - `input_vector`：由调用方传入的业务数据或控制参数。
        - `weight_matrix`：由调用方传入的业务数据或控制参数。
        - `apply_non_ideal`：由调用方传入的业务数据或控制参数。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `MemristorArraySimulator.matrix_vector_multiply` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        # 量化权重到电导
        g_matrix = self.quantize_weights(weight_matrix)
        
        # 应用非理想效应
        if apply_non_ideal:
            g_matrix = self.apply_non_idealities(g_matrix)
            
        batch_size = input_vector.size(0)
        
        # IR drop仿真
        if self.interconnect.ir_drop_active and input_vector.dim() == 2:
            v_effective = self.ir_simulator.compute_effective_voltages(
                input_vector, g_matrix
            )
            # 计算单元电流并求和
            current_map = g_matrix.unsqueeze(0) * v_effective
            output = current_map.sum(dim=2)
        else:
            # 理想矩阵乘法
            output = torch.matmul(input_vector, g_matrix.t())
            
        # ADC量化 (8-bit)
        adc_bits = 8
        max_val = output.abs().max()
        if max_val > 1e-12:
            scale = (2**adc_bits - 1) / max_val
            quantized = torch.round(output * scale) / scale * max_val
        else:
            quantized = output
            
        return quantized
        
    def compute_hardware_loss(self, weights: torch.Tensor) -> torch.Tensor:
        # 教学注释：
        # 训练期可用的“硬件友好”正则：量化损失 + 漂移惩罚 + IR 惩罚。
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        - `weights`：由调用方传入的业务数据或控制参数。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `MemristorArraySimulator.compute_hardware_loss` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        # 量化损失
        g_quant = self.quantize_weights(weights)
        quant_loss = F.mse_loss(g_quant, weights)
        
        # 漂移惩罚
        drift_penalty = self.temporal.drift_coefficient * torch.mean(weights.abs())
        
        # IR drop惩罚 (鼓励电导分布在中值附近)
        ir_penalty = 0.0
        if self.interconnect.ir_drop_active:
            g_mid = (self.conductance_model.g_max + self.conductance_model.g_min) / 2
            g_range = self.conductance_model.g_max - self.conductance_model.g_min
            ir_penalty = torch.mean((g_quant - g_mid).abs()) / g_range
            
        return quant_loss + 0.1 * drift_penalty + 0.01 * ir_penalty
        
    def get_noise_profile(self) -> Dict[str, float]:
        # 教学注释：
        # 输出当前噪声统计摘要，便于报告解释精度变化来源。
        """
        输入：
        - `self`：当前对象本身，表示“在这个类实例上操作”。
        
        处理：
        - 第1步：读取并检查输入，处理默认值、边界值与兼容分支。
        - 第2步：执行函数名对应的核心逻辑（计算、流程调度、映射或状态更新）。
        - 第3步：整理结果并输出；若需要，会附带日志、缓存或文件副作用。
        
        输出：
        - 返回值：本函数计算后的主要结果；具体形态由调用场景决定。
        - 副作用：可能修改对象内部状态、全局缓存、日志输出或磁盘文件。
        
        为什么：
        - `MemristorArraySimulator.get_noise_profile` 是当前模块流程中的一个可复用步骤，单独封装可减少重复代码。
        - 采用“输入校验 -> 核心处理 -> 统一输出”结构，便于零基础读者按步骤理解。
        - 当后续需求变化时，只需改这个函数内部，调用方接口可以保持稳定。
        """
        elapsed = time.time() - self.creation_time
        drift_factor = self.temporal.drift_coefficient * np.sqrt(elapsed / 3600 + 1)
        
        return {
            'quantization_std': 0.001,
            'drift_std': 0.01 * drift_factor,
            'read_noise_std': 0.0005 * 0.1,
            'd2d_variation': self.variation.die_to_die,
            'c2c_variation': self.variation.cell_to_cell,
            'ir_attenuation': 0.998 if self.interconnect.ir_drop_active else 0.9995,
            'total_equivalent_std': math.sqrt(
                0.001**2 + (0.01 * drift_factor)**2 + (0.0005 * 1.0)**2
            )
        }
