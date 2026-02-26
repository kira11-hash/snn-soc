"""
==========================================================
  SNN SoC Python 建模 - 配置文件
==========================================================
所有可调参数集中在这里。修改参数后重新运行 run_all.py 即可。

文件说明：
  - 器件参数来自器件团队提供的 memristor_plugin.py
  - 扫描范围覆盖论文中需要对比的所有参数组合
  - 路径配置假设从 Python建模/ 目录运行
"""

import os

# =====================================================
# 路径配置
# =====================================================
# 项目根目录（自动检测，无需修改）
PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
RESULTS_DIR = os.path.join(PROJECT_DIR, "results")          # 结果输出
WEIGHTS_DIR_FULL = os.path.join(PROJECT_DIR, "weights_full")   # full-run weights
WEIGHTS_DIR_QUICK = os.path.join(PROJECT_DIR, "weights_quick") # quick-run weights
WEIGHTS_DIR = WEIGHTS_DIR_FULL                                # ANN权重保存 (默认 full)
DATA_DIR    = os.path.join(PROJECT_DIR, "data")               # MNIST数据

# I-V 数据文件路径（如果有的话，用于加载真实器件数据）
IV_DATA_PATH = os.path.join(
    PROJECT_DIR, "..", "项目相关文件", "器件对齐",
    "器件相关参数与数据", "I-V.xlsx"
)
MEMRISTOR_PLUGIN_PATH = os.path.join(
    PROJECT_DIR, "..", "项目相关文件", "器件对齐",
    "器件相关参数与数据", "memristor_plugin.py"
)

# =====================================================
# 器件参数 (来自 memristor_plugin.py)
# =====================================================
ARRAY_ROWS = 128           # 物理阵列行数
ARRAY_COLS = 256           # 物理阵列列数 (128×2 差分)
WEIGHT_BITS_DEVICE = 4     # 器件原生精度: 4-bit (16 个电导电平)
D2D_VARIATION = 0.05       # Die-to-Die 变化性 5%
C2C_VARIATION = 0.03       # Cell-to-Cell 变化性 3%
READ_NOISE_SIGMA = 0.0005  # 读噪声标准差 (占电导范围的 0.05%)
DRIFT_COEFF = 0.005        # 电导漂移系数

# =====================================================
# 仿真可复现性
# =====================================================
RANDOM_SEED = 42

# =====================================================
# 器件模型接入配置
# =====================================================
USE_MEMRISTOR_PLUGIN = True      # True: 尝试加载器件组 memristor_plugin.py
PLUGIN_LEVELS_FOR_4BIT = True    # True: 4-bit 量化优先使用器件电导离散级

# =====================================================
# ADC 量化配置
# =====================================================
# fixed: 使用固定满量程 (更接近真实硬件)
# dynamic: 按当前输入动态缩放 (仅调试，论文不建议)
ADC_FULL_SCALE_MODE = "fixed"

# =====================================================
# SNN inference core switches
# =====================================================
USE_DEVICE_MODEL = True       # Enable plugin-based device model / noise / IR drop
SPIKE_THRESHOLD_RATIO = 0.6   # Default global threshold ratio when not calibrated
SPIKE_RESET_MODE = "soft"     # soft: V=V-Vth; hard: V=0
ADAPTIVE_INIT_SAMPLES = 512   # Samples used for adaptive-threshold initialization
ALLOW_SIGNED_SCHEME_A = False  # False keeps Python aligned with current unsigned RTL data path

# Evaluation scope (avoid test leakage during model/param selection)
TUNE_SPLIT = "val"             # "val" or "test" (recommended: "val")
FINAL_REPORT_SPLIT = "test"    # final one-shot report split
TARGET_INPUT_DIM_FOR_RECOMMEND = 64  # set to 64 for projection/8x8 recommendation
EVAL_SCHEMES = ["B"]           # primary evaluation schemes under current RTL
PRIMARY_SCHEME = "B"           # scheme used for method/ADC/W/T recommendations

# Final fixed-config multi-seed report (inference-only)
FINAL_MULTI_SEEDS = [42, 43, 44, 45, 46]

# =====================================================
# Input scaling / gain
# =====================================================
AUTO_INPUT_GAIN = True
INPUT_GAIN_PERCENTILE = 0.99  # Scale so p99 maps near 255
INPUT_GAIN_MAX = 1.5

# =====================================================
# Threshold calibration
# =====================================================
CALIBRATE_THRESHOLD_RATIO = True
THRESHOLD_RATIO_CANDIDATES = [0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
THRESHOLD_CALIBRATE_SAMPLES = 2000

# =====================================================
# Training-side robustness (QAT / noise / IR-drop proxy)
# =====================================================
QAT_ENABLE = True
QAT_WEIGHT_BITS = 4
QAT_USE_DEVICE_LEVELS = True
QAT_NOISE_ENABLE = True
QAT_NOISE_STD = 0.02
QAT_IR_DROP_COEFF = 0.05
QAT_LR = 0.002
POST_QUANT_FINE_TUNE_EPOCHS = 5

# =====================================================
# 784->64 projection (PCA / supervised)
# =====================================================
PROJ_DIM = 64
PROJ_PCA_SAMPLES = 10000
PROJ_PCA_CENTER = True
PROJ_SCALE_METHOD = "minmax"  # minmax | p99
PROJ_SCALE_PERCENTILE = 0.99
PROJ_SUP_EPOCHS = 10
PROJ_SUP_LR = 0.02
PROJ_SUP_BATCH_SIZE = 256
PROJ_SUP_USE_BIAS = False

# =====================================================
# SNN 固定参数
# =====================================================
PIXEL_BITS = 8             # 像素位宽 = bit-plane 数量 (8-bit 灰度图)
NUM_OUTPUTS = 10           # 输出类别数 (MNIST 0-9)

# =====================================================
# 降采样方法列表
# =====================================================
# 每种方法会独立训练ANN并对比准确率
# 格式: { 名称: (目标尺寸, 方法) }
DOWNSAMPLE_METHODS = {
    "bilinear_8x8":    (8, "bilinear"),    # 双线性插值 28→8
    "nearest_8x8":     (8, "nearest"),     # 最近邻插值 28→8
    "avgpool_8x8":     (8, "avgpool"),     # 自适应平均池化 28→8
    "maxpool_8x8":     (8, "maxpool"),     # 自适应最大池化 28→8
    "pad32_zero_8x8":      (8, "pad32_zero"),      # 28->32 zero pad + 4x4 avgpool -> 8
    "pad32_replicate_8x8": (8, "pad32_replicate"), # 28->32 replicate pad + 4x4 avgpool -> 8
    "pad32_reflect_8x8":   (8, "pad32_reflect"),   # 28->32 reflect pad + 4x4 avgpool -> 8
    "avgpool_7x7":     (7, "avgpool"),     # 自适应平均池化 28->7（49维对比）
    "bilinear_7x7":    (7, "bilinear"),    # 双线性插值 28→7 (49维对比)
    "proj_pca_64":    (64, "proj_pca"),    # PCA 投影 784->64 维
    "proj_sup_64":    (64, "proj_sup"),    # 监督式投影 784->64 维
}

# =====================================================
# 参数扫描范围
# =====================================================
ADC_BITS_SWEEP    = [6, 8, 10, 12]      # ADC 位宽扫描
WEIGHT_BITS_SWEEP = [2, 3, 4, 6, 8]     # 权重量化位宽扫描
TIMESTEPS_SWEEP   = [1, 3, 5, 10, 20]   # 推理帧数扫描

# =====================================================
# ANN 训练超参数
# =====================================================
ANN_EPOCHS     = 30        # 训练轮数 (MNIST 单层30轮足够收敛)
ANN_LR         = 0.01      # 学习率
ANN_MOMENTUM   = 0.9       # SGD 动量
ANN_BATCH_SIZE = 128       # 批大小

# =====================================================
# 快速模式 (--quick 命令行参数时使用)
# =====================================================
QUICK_TEST_SAMPLES = 500   # 快速模式只用500个测试样本
QUICK_EPOCHS = 5           # 快速模式只训练5轮
NOISE_TRIALS_QUICK = 5
NOISE_TRIALS_FULL = 30

# =====================================================
# 训练/验证拆分
# =====================================================
VAL_SAMPLES = 5000         # 从训练集划分用于阈值标定的验证样本数
