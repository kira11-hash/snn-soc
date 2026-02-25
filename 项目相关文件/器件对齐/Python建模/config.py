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
RESULTS_DIR = os.path.join(PROJECT_DIR, "results")     # 结果输出
WEIGHTS_DIR = os.path.join(PROJECT_DIR, "weights")      # 训练权重保存目录
DATA_DIR    = os.path.join(PROJECT_DIR, "data")          # 手写数字数据目录

# 仓库根目录（当前目录通常位于项目的建模子目录）
REPO_ROOT = os.path.abspath(os.path.join(PROJECT_DIR, "..", "..", ".."))


def _pick_existing_path(path_candidates):
    """
    从候选路径中选择第一个存在的路径；若都不存在，返回第一个候选的绝对路径。
    目的：兼容不同机器上的目录布局，避免 I-V 与 plugin 路径失效。
    """
    for p in path_candidates:
        p_abs = os.path.abspath(p)
        if os.path.exists(p_abs):
            return p_abs
    return os.path.abspath(path_candidates[0])

# 电压-电流数据文件路径（若存在则用于加载真实器件数据）
IV_DATA_PATH = _pick_existing_path([
    os.path.join(PROJECT_DIR, "..", "器件相关参数与数据", "I-V.xlsx"),
    os.path.join(PROJECT_DIR, "..", "项目相关文件", "器件对齐", "器件相关参数与数据", "I-V.xlsx"),
    os.path.join(REPO_ROOT, "项目相关文件", "器件对齐", "器件相关参数与数据", "I-V.xlsx"),
])
MEMRISTOR_PLUGIN_PATH = _pick_existing_path([
    os.path.join(PROJECT_DIR, "..", "器件相关参数与数据", "memristor_plugin.py"),
    os.path.join(PROJECT_DIR, "..", "项目相关文件", "器件对齐", "器件相关参数与数据", "memristor_plugin.py"),
    os.path.join(REPO_ROOT, "项目相关文件", "器件对齐", "器件相关参数与数据", "memristor_plugin.py"),
])

# =====================================================
# 器件参数（来自器件插件）
# =====================================================
ARRAY_ROWS = 128           # 物理阵列行数
ARRAY_COLS = 256           # 物理阵列列数 (128×2 差分)
WEIGHT_BITS_DEVICE = 4     # 器件原生精度：4 位（16 个电导电平）
D2D_VARIATION = 0.05       # 芯片间变化性 5%
C2C_VARIATION = 0.03       # 单元间变化性 3%
READ_NOISE_SIGMA = 0.0005  # 读噪声标准差 (占电导范围的 0.05%)
DRIFT_COEFF = 0.005        # 电导漂移系数

# =====================================================
# 仿真可复现性
# =====================================================
RANDOM_SEED = 42

# =====================================================
# 器件模型接入配置
# =====================================================
USE_MEMRISTOR_PLUGIN = True      # 为真时尝试加载器件组提供的器件插件
PLUGIN_LEVELS_FOR_4BIT = True    # 为真时 4 位量化优先使用器件离散电导级

# =====================================================
# 模数转换量化配置
# =====================================================
# 固定模式：使用固定满量程（更接近真实硬件）
# 动态模式：按当前输入动态缩放（仅用于调试，不建议用于论文结论）
ADC_FULL_SCALE_MODE = "fixed"

# =====================================================
# 脉冲网络推理核心开关
# =====================================================
USE_DEVICE_MODEL = True       # 启用基于插件的器件模型/噪声/线阻压降
SPIKE_THRESHOLD_RATIO = 0.6   # 未做标定时使用的全局默认阈值比例
SPIKE_RESET_MODE = "soft"     # 软复位：V=V-Vth；硬复位：V=0
ADAPTIVE_INIT_SAMPLES = 512   # 自适应阈值初始化时使用的样本数
ALLOW_SIGNED_SCHEME_A = False  # 为假时与当前硬件无符号数据通路保持一致

# 评估口径范围（避免在模型选择/调参阶段泄漏测试集）
TUNE_SPLIT = "val"             # 调参与选方案使用的数据集：验证集或测试集（推荐验证集）
FINAL_REPORT_SPLIT = "test"    # 最终一次报告使用的数据集划分
TARGET_INPUT_DIM_FOR_RECOMMEND = 64  # 推荐配置仅在 64 维输入方法中选择（投影或 8x8 路线）
EVAL_SCHEMES = ["B"]           # 当前硬件口径下参与评估的方案列表
PRIMARY_SCHEME = "B"           # 用于方法、位宽、帧数推荐的主方案

# 最终固定配置的多随机种子报告（仅推理侧）
FINAL_MULTI_SEEDS = [42, 43, 44, 45, 46]

# =====================================================
# 输入缩放/增益
# =====================================================
AUTO_INPUT_GAIN = True
INPUT_GAIN_PERCENTILE = 0.99  # 将 99 分位值映射到接近 255 的位置
INPUT_GAIN_MAX = 1.5

# =====================================================
# 阈值标定
# =====================================================
CALIBRATE_THRESHOLD_RATIO = True
THRESHOLD_RATIO_CANDIDATES = [0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
THRESHOLD_CALIBRATE_SAMPLES = 2000

# =====================================================
# 训练侧鲁棒性（量化感知训练 / 噪声 / 线阻压降代理）
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
# 784->64 投影（主成分法 / 监督式）
# =====================================================
PROJ_DIM = 64
PROJ_PCA_SAMPLES = 10000
PROJ_PCA_CENTER = True
PROJ_SCALE_METHOD = "minmax"  # 可选缩放方式：minmax 或 p99
PROJ_SCALE_PERCENTILE = 0.99
PROJ_SUP_EPOCHS = 10
PROJ_SUP_LR = 0.02
PROJ_SUP_BATCH_SIZE = 256
PROJ_SUP_USE_BIAS = False

# =====================================================
# 脉冲网络固定参数
# =====================================================
PIXEL_BITS = 8             # 像素位宽 = 位平面数量（8 位灰度图）
NUM_OUTPUTS = 10           # 输出类别数（手写数字 0-9）

# =====================================================
# 降采样方法列表
# =====================================================
# 每种方法会独立训练模型并对比准确率
# 格式: { 名称: (目标尺寸, 方法) }
DOWNSAMPLE_METHODS = {
    "bilinear_8x8":    (8, "bilinear"),    # 双线性插值 28→8
    "nearest_8x8":     (8, "nearest"),     # 最近邻插值 28→8
    "avgpool_8x8":     (8, "avgpool"),     # 自适应平均池化 28→8
    "maxpool_8x8":     (8, "maxpool"),     # 自适应最大池化 28→8
    "pad32_zero_8x8":      (8, "pad32_zero"),      # 28->32 零填充，再 4x4 平均池化到 8x8
    "pad32_replicate_8x8": (8, "pad32_replicate"), # 28->32 边界复制填充，再 4x4 平均池化到 8x8
    "pad32_reflect_8x8":   (8, "pad32_reflect"),   # 28->32 镜像反射填充，再 4x4 平均池化到 8x8
    "avgpool_7x7":     (7, "avgpool"),     # 自适应平均池化 28->7（49维对比）
    "bilinear_7x7":    (7, "bilinear"),    # 双线性插值 28→7（49维对比）
    "proj_pca_64":    (64, "proj_pca"),    # 主成分投影 784->64 维
    "proj_sup_64":    (64, "proj_sup"),    # 监督式投影 784->64 维
}

# =====================================================
# 参数扫描范围
# =====================================================
ADC_BITS_SWEEP    = [6, 8, 10, 12]      # 模数转换位宽扫描
WEIGHT_BITS_SWEEP = [2, 3, 4, 6, 8]     # 权重量化位宽扫描
TIMESTEPS_SWEEP   = [1, 3, 5, 10, 20]   # 推理帧数扫描

# =====================================================
# 训练超参数
# =====================================================
ANN_EPOCHS     = 30        # 训练轮数（手写数字单层 30 轮通常可收敛）
ANN_LR         = 0.01      # 学习率
ANN_MOMENTUM   = 0.9       # 随机梯度下降动量
ANN_BATCH_SIZE = 128       # 批大小

# =====================================================
# 快速模式（使用 --quick 命令行参数时启用）
# =====================================================
QUICK_TEST_SAMPLES = 500   # 快速模式只用500个测试样本
QUICK_EPOCHS = 5           # 快速模式只训练5轮
NOISE_TRIALS_QUICK = 5
NOISE_TRIALS_FULL = 30

# =====================================================
# 训练/验证拆分
# =====================================================
VAL_SAMPLES = 5000         # 从训练集划分用于阈值标定的验证样本数
