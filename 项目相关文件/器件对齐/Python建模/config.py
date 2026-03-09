"""
==========================================================
  SNN SoC Python 建模 - 配置文件
==========================================================
所有可调参数都集中在这里。修改参数后重新运行 `run_all.py` 即可。

文件说明：
  - 器件参数来自器件团队提供的 `memristor_plugin.py`
  - 扫描范围覆盖当前论文与硬件评估需要对比的参数组合
  - 路径配置默认假设从 `Python建模/` 目录运行
"""

import os

# =====================================================
# 路径配置
# =====================================================
# 项目根目录（自动检测，无需修改）
PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
RESULTS_DIR = os.path.join(PROJECT_DIR, "results")              # 结果输出目录
WEIGHTS_DIR_FULL = os.path.join(PROJECT_DIR, "weights_full")    # full-run 权重目录
WEIGHTS_DIR_QUICK = os.path.join(PROJECT_DIR, "weights_quick")  # quick-run 权重目录
WEIGHTS_DIR = WEIGHTS_DIR_FULL                                  # 当前权重目录（默认 full）
DATA_DIR = os.path.join(PROJECT_DIR, "data")                    # MNIST 数据目录


# I-V 数据与器件插件路径（支持多种目录布局 + 环境变量覆盖）
RUN_DIR = os.path.abspath(os.getcwd())


def _dedupe_paths(paths):
    seen = set()
    ordered = []
    for path in paths:
        norm = os.path.normpath(path)
        if norm in seen:
            continue
        seen.add(norm)
        ordered.append(norm)
    return ordered


def _build_search_roots():
    roots = [
        PROJECT_DIR,
        os.path.join(PROJECT_DIR, ".."),
        RUN_DIR,
        os.path.join(RUN_DIR, ".."),
        os.path.expanduser("~/Desktop/器件对齐/Python建模"),
        os.path.expanduser("~/Desktop/器件对齐"),
    ]
    return _dedupe_paths(roots)


def _expand_device_model_candidates(filename):
    candidates = []
    for root in _build_search_roots():
        if os.path.basename(root) == "Python建模":
            candidates.append(os.path.join(root, "..", "器件相关参数与数据", filename))
            candidates.append(os.path.join(root, "device-model", filename))
            candidates.append(os.path.join(root, "..", "device-model", filename))
        else:
            candidates.append(os.path.join(root, "器件相关参数与数据", filename))
            candidates.append(os.path.join(root, "Python建模", "device-model", filename))
            candidates.append(os.path.join(root, "device-model", filename))
    return _dedupe_paths(candidates)


def _pick_existing_path(candidates):
    for p in candidates:
        p_norm = os.path.normpath(p)
        if os.path.exists(p_norm):
            return p_norm
    return os.path.normpath(candidates[0])


def _resolve_path_from_env_or_candidates(env_key, candidates):
    env_val = os.environ.get(env_key, "").strip()
    if env_val:
        env_path = os.path.normpath(os.path.expanduser(env_val))
        if os.path.exists(env_path):
            return env_path
    return _pick_existing_path(candidates)


IV_DATA_PATH = _resolve_path_from_env_or_candidates(
    "SNN_IV_DATA_PATH",
    _expand_device_model_candidates("I-V.xlsx"),
)
MEMRISTOR_PLUGIN_PATH = _resolve_path_from_env_or_candidates(
    "SNN_MEMRISTOR_PLUGIN_PATH",
    _expand_device_model_candidates("memristor_plugin.py"),
)

# =====================================================
# 器件参数（来自 memristor_plugin.py）
# =====================================================
ARRAY_ROWS = 128           # 物理阵列行数
ARRAY_COLS = 256           # 物理阵列列数（128×2 差分列）
WEIGHT_BITS_DEVICE = 4     # 器件原生精度：4-bit（16 个电导级）
D2D_VARIATION = 0.05       # Die-to-Die 变化 5%
C2C_VARIATION = 0.03       # Cell-to-Cell 变化 3%
READ_NOISE_SIGMA = 0.0005  # 读噪声标准差（占电导范围的 0.05%）
DRIFT_COEFF = 0.005        # 电导漂移系数

# =====================================================
# 仿真可复现性
# =====================================================
RANDOM_SEED = 42

# =====================================================
# 器件模型接入配置
# =====================================================
USE_MEMRISTOR_PLUGIN = True   # True: 尝试加载器件插件 memristor_plugin.py
PLUGIN_LEVELS_FOR_4BIT = True # True: 4-bit 量化优先使用器件离散电导级

# =====================================================
# ADC 量化配置
# =====================================================
# fixed: 使用固定满量程，更接近真实硬件
# dynamic: 按当前输入动态缩放，仅建议用于调试
ADC_FULL_SCALE_MODE = "fixed"

# =====================================================
# SNN 推理核心开关
# =====================================================
USE_DEVICE_MODEL = True        # 开启基于插件的器件模型 / 噪声 / IR drop
SPIKE_THRESHOLD_RATIO = 4.0 / 255.0  # 默认固定阈值比例（关闭标定时使用）
SPIKE_RESET_MODE = "soft"      # soft: V=V-Vth; hard: V=0
ADAPTIVE_INIT_SAMPLES = 512    # 自适应阈值初始化样本数
ALLOW_SIGNED_SCHEME_A = False  # Scheme B 已定版，禁用 Scheme A signed

# =====================================================
# 评估范围控制
# =====================================================
TUNE_SPLIT = "val"             # 用哪个数据集调参："val" 或 "test"
FINAL_REPORT_SPLIT = "test"    # 参数冻结后最终只在 test 上报告一次
TARGET_INPUT_DIM_FOR_RECOMMEND = 64  # 只推荐 8x8=64 维输入方式
EVAL_SCHEMES = ["B"]            # Scheme B 已定版，只扫 B
PRIMARY_SCHEME = "B"           # 方法/ADC/W/T 的主推荐方案

# 最终固定配置的多 seed 推理报告
FINAL_MULTI_SEEDS = [42, 43, 44, 45, 46]

# =====================================================
# 输入缩放 / 增益
# =====================================================
AUTO_INPUT_GAIN = True
INPUT_GAIN_PERCENTILE = 0.99   # 让 p99 映射到接近 255
INPUT_GAIN_MAX = 1.5

# =====================================================
# 阈值标定
# =====================================================
CALIBRATE_THRESHOLD_RATIO = True
THRESHOLD_RATIO_CANDIDATES = [
    # ratio_code / 255.0 — 1~16 逐1全覆盖 + 16以上对数间距
    # ratio_code:  1   2   3   4   5   6   7   8
    1/255, 2/255, 3/255, 4/255, 5/255, 6/255, 7/255, 8/255,
    # ratio_code:  9  10  11  12  13  14  15  16
    9/255, 10/255, 11/255, 12/255, 13/255, 14/255, 15/255, 16/255,
    # ratio_code: 20  25  32  40  50  64  80 100 128 160 200
    20/255, 25/255, 32/255, 40/255, 50/255, 64/255, 80/255, 100/255, 128/255, 160/255, 200/255,
]
FULL_GRID_INCLUDE_RATIO = True
FULL_GRID_RATIO_CANDIDATES = list(THRESHOLD_RATIO_CANDIDATES)
THRESHOLD_CALIBRATE_SAMPLES = 5000
RECOMMEND_ACC_MARGIN = 0.005
RECOMMEND_ZERO_SPIKE_MAX = 0.10
SUMMARY_TOPK_COMBOS = 50

# =====================================================
# 训练侧稳健性增强（QAT / 噪声 / IR-drop 代理）
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
# 784 -> 64 投影（PCA / supervised）
# =====================================================
PROJ_DIM = 64
PROJ_PCA_SAMPLES = 10000
PROJ_PCA_CENTER = True
PROJ_SCALE_METHOD = "minmax"   # minmax | p99
PROJ_SCALE_PERCENTILE = 0.99
PROJ_SUP_EPOCHS = 10
PROJ_SUP_LR = 0.02
PROJ_SUP_BATCH_SIZE = 256
PROJ_SUP_USE_BIAS = False

# =====================================================
# SNN 固定参数
# =====================================================
PIXEL_BITS = 8             # 像素位宽 = bit-plane 数量（8-bit 灰度）
NUM_OUTPUTS = 10           # 输出类别数（MNIST 0-9）

# =====================================================
# 输入方式列表
# =====================================================
# 每种方法都会独立训练 ANN，并对比对应 SNN 准确率。
# 格式：{名称: (目标尺寸, 方法名)}
# 当前只保留 8x8 非神经网络输入方式。
DOWNSAMPLE_METHODS = {
    "avgpool_8x8":          (8,  "avgpool"),
    "bilinear_8x8":         (8,  "bilinear"),
    "maxpool_8x8":          (8,  "maxpool"),
    "nearest_8x8":          (8,  "nearest"),
    "pad32_zero_8x8":       (8,  "pad32_zero"),
    "pad32_replicate_8x8":  (8,  "pad32_replicate"),
    "pad32_reflect_8x8":    (8,  "pad32_reflect"),
}

# =====================================================
# 参数扫描范围
# =====================================================
ADC_BITS_SWEEP = [6, 8, 10, 12]
WEIGHT_BITS_SWEEP = [2, 3, 4, 6, 8]
TIMESTEPS_SWEEP = [1, 2, 3, 4, 5, 10, 20]
RESET_MODE_SWEEP = ["soft", "hard"]

# =====================================================
# 权重导出
# =====================================================
AUTO_EXPORT_WEIGHT_MAP = True          # run_all 结束后自动导出推荐配置和 best-case 的权重映射
AUTO_EXPORT_WEIGHT_HEX = True          # 若权重量化位宽兼容当前 RTL，则同时导出 HEX
WEIGHT_HEX_REQUIRE_4BIT = True         # 当前主线行为模型确认是 4-bit level index
WEIGHT_EXPORT_SUBDIR = "exports"       # 导出目录：results/exports/
WEIGHT_EXPORT_COL_MAP = "grouped"      # grouped 与当前 RTL 列映射一致

# =====================================================
# ANN 训练超参数
# =====================================================
ANN_EPOCHS = 30            # 训练轮数
ANN_LR = 0.01              # 学习率
ANN_MOMENTUM = 0.9         # SGD 动量
ANN_BATCH_SIZE = 128       # 批大小

# =====================================================
# 快速模式（命令行传入 --quick 时启用）
# =====================================================
QUICK_TEST_SAMPLES = 500   # quick 模式只用 500 个测试样本
QUICK_EPOCHS = 5           # quick 模式只训练 5 轮
NOISE_TRIALS_QUICK = 5
NOISE_TRIALS_FULL = 30

# =====================================================
# 训练/验证拆分
# =====================================================
VAL_SAMPLES = 5000         # 从训练集划出的验证样本数
