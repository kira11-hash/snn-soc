"""
==========================================================
  SNN SoC Python 寤烘ā - 閰嶇疆鏂囦欢
==========================================================
鎵€鏈夊彲璋冨弬鏁伴泦涓湪杩欓噷銆備慨鏀瑰弬鏁板悗閲嶆柊杩愯 run_all.py 鍗冲彲銆?

鏂囦欢璇存槑锛?
  - 鍣ㄤ欢鍙傛暟鏉ヨ嚜鍣ㄤ欢鍥㈤槦鎻愪緵鐨?memristor_plugin.py
  - 鎵弿鑼冨洿瑕嗙洊璁烘枃涓渶瑕佸姣旂殑鎵€鏈夊弬鏁扮粍鍚?
  - 璺緞閰嶇疆鍋囪浠?Python寤烘ā/ 鐩綍杩愯
"""

import os

# =====================================================
# 璺緞閰嶇疆
# =====================================================
# 椤圭洰鏍圭洰褰曪紙鑷姩妫€娴嬶紝鏃犻渶淇敼锛?
PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
RESULTS_DIR = os.path.join(PROJECT_DIR, "results")          # 缁撴灉杈撳嚭
WEIGHTS_DIR_FULL = os.path.join(PROJECT_DIR, "weights_full")   # full-run weights
WEIGHTS_DIR_QUICK = os.path.join(PROJECT_DIR, "weights_quick") # quick-run weights
WEIGHTS_DIR = WEIGHTS_DIR_FULL                                # ANN鏉冮噸淇濆瓨 (榛樿 full)
DATA_DIR    = os.path.join(PROJECT_DIR, "data")               # MNIST鏁版嵁

# I-V 鏁版嵁鏂囦欢璺緞锛堝鏋滄湁鐨勮瘽锛岀敤浜庡姞杞界湡瀹炲櫒浠舵暟鎹級
# I-V 数据与器件插件路径（支持多种目录布局 + 环境变量覆盖）
def _pick_existing_path(candidates):
    for p in candidates:
        p_norm = os.path.normpath(p)
        if os.path.exists(p_norm):
            return p_norm
    return os.path.normpath(candidates[0])


def _resolve_path_from_env_or_candidates(env_key, candidates):
    env_val = os.environ.get(env_key, "").strip()
    if env_val:
        return os.path.normpath(env_val)
    return _pick_existing_path(candidates)


IV_DATA_PATH = _resolve_path_from_env_or_candidates(
    "SNN_IV_DATA_PATH",
    [
        os.path.join(PROJECT_DIR, "..", "器件相关参数与数据", "I-V.xlsx"),
        os.path.join(PROJECT_DIR, "device-model", "I-V.xlsx"),
        os.path.join(PROJECT_DIR, "..", "device-model", "I-V.xlsx"),
    ],
)
MEMRISTOR_PLUGIN_PATH = _resolve_path_from_env_or_candidates(
    "SNN_MEMRISTOR_PLUGIN_PATH",
    [
        os.path.join(PROJECT_DIR, "..", "器件相关参数与数据", "memristor_plugin.py"),
        os.path.join(PROJECT_DIR, "device-model", "memristor_plugin.py"),
        os.path.join(PROJECT_DIR, "..", "device-model", "memristor_plugin.py"),
    ],
)

# =====================================================
# 鍣ㄤ欢鍙傛暟 (鏉ヨ嚜 memristor_plugin.py)
# =====================================================
ARRAY_ROWS = 128           # 鐗╃悊闃靛垪琛屾暟
ARRAY_COLS = 256           # 鐗╃悊闃靛垪鍒楁暟 (128脳2 宸垎)
WEIGHT_BITS_DEVICE = 4     # 鍣ㄤ欢鍘熺敓绮惧害: 4-bit (16 涓數瀵肩數骞?
D2D_VARIATION = 0.05       # Die-to-Die 鍙樺寲鎬?5%
C2C_VARIATION = 0.03       # Cell-to-Cell 鍙樺寲鎬?3%
READ_NOISE_SIGMA = 0.0005  # 璇诲櫔澹版爣鍑嗗樊 (鍗犵數瀵艰寖鍥寸殑 0.05%)
DRIFT_COEFF = 0.005        # 鐢靛婕傜Щ绯绘暟

# =====================================================
# 浠跨湡鍙鐜版€?
# =====================================================
RANDOM_SEED = 42

# =====================================================
# 鍣ㄤ欢妯″瀷鎺ュ叆閰嶇疆
# =====================================================
USE_MEMRISTOR_PLUGIN = True      # True: 灏濊瘯鍔犺浇鍣ㄤ欢缁?memristor_plugin.py
PLUGIN_LEVELS_FOR_4BIT = True    # True: 4-bit 閲忓寲浼樺厛浣跨敤鍣ㄤ欢鐢靛绂绘暎绾?

# =====================================================
# ADC 閲忓寲閰嶇疆
# =====================================================
# fixed: 浣跨敤鍥哄畾婊￠噺绋?(鏇存帴杩戠湡瀹炵‖浠?
# dynamic: 鎸夊綋鍓嶈緭鍏ュ姩鎬佺缉鏀?(浠呰皟璇曪紝璁烘枃涓嶅缓璁?
ADC_FULL_SCALE_MODE = "fixed"

# =====================================================
# SNN inference core switches
# =====================================================
USE_DEVICE_MODEL = True       # Enable plugin-based device model / noise / IR drop
SPIKE_THRESHOLD_RATIO = 0.10  # Default global threshold ratio when not calibrated
                               # (降低以保证 spike-only 决策时胜出类别始终能发放脉冲)
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
# 候选值大幅下调：calibration 现在按纯 spike 精度优化（无 membrane fallback）
# 目标：找到使胜出类别始终发放脉冲、且零脉冲率接近 0% 的最小阈值
THRESHOLD_RATIO_CANDIDATES = [0.02, 0.03, 0.05, 0.08, 0.10, 0.12, 0.15, 0.20, 0.25, 0.30, 0.40]
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
# SNN 鍥哄畾鍙傛暟
# =====================================================
PIXEL_BITS = 8             # 鍍忕礌浣嶅 = bit-plane 鏁伴噺 (8-bit 鐏板害鍥?
NUM_OUTPUTS = 10           # 杈撳嚭绫诲埆鏁?(MNIST 0-9)

# =====================================================
# 闄嶉噰鏍锋柟娉曞垪琛?
# =====================================================
# 姣忕鏂规硶浼氱嫭绔嬭缁傾NN骞跺姣斿噯纭巼
# 鏍煎紡: { 鍚嶇О: (鐩爣灏哄, 鏂规硶) }
DOWNSAMPLE_METHODS = {
    "bilinear_8x8":    (8, "bilinear"),    # 鍙岀嚎鎬ф彃鍊?28鈫?
    "nearest_8x8":     (8, "nearest"),     # 鏈€杩戦偦鎻掑€?28鈫?
    "avgpool_8x8":     (8, "avgpool"),     # 鑷€傚簲骞冲潎姹犲寲 28鈫?
    "maxpool_8x8":     (8, "maxpool"),     # 鑷€傚簲鏈€澶ф睜鍖?28鈫?
    "pad32_zero_8x8":      (8, "pad32_zero"),      # 28->32 zero pad + 4x4 avgpool -> 8
    "pad32_replicate_8x8": (8, "pad32_replicate"), # 28->32 replicate pad + 4x4 avgpool -> 8
    "pad32_reflect_8x8":   (8, "pad32_reflect"),   # 28->32 reflect pad + 4x4 avgpool -> 8
    "avgpool_7x7":     (7, "avgpool"),     # 鑷€傚簲骞冲潎姹犲寲 28->7锛?9缁村姣旓級
    "bilinear_7x7":    (7, "bilinear"),    # 鍙岀嚎鎬ф彃鍊?28鈫? (49缁村姣?
    "proj_pca_64":    (64, "proj_pca"),    # PCA 鎶曞奖 784->64 缁?
    "proj_sup_64":    (64, "proj_sup"),    # 鐩戠潱寮忔姇褰?784->64 缁?
}

# =====================================================
# 鍙傛暟鎵弿鑼冨洿
# =====================================================
ADC_BITS_SWEEP    = [6, 8, 10, 12]      # ADC 浣嶅鎵弿
WEIGHT_BITS_SWEEP = [2, 3, 4, 6, 8]     # 鏉冮噸閲忓寲浣嶅鎵弿
TIMESTEPS_SWEEP   = [1, 3, 5, 10, 20]   # 鎺ㄧ悊甯ф暟鎵弿

# =====================================================
# ANN 璁粌瓒呭弬鏁?
# =====================================================
ANN_EPOCHS     = 30        # 璁粌杞暟 (MNIST 鍗曞眰30杞冻澶熸敹鏁?
ANN_LR         = 0.01      # 瀛︿範鐜?
ANN_MOMENTUM   = 0.9       # SGD 鍔ㄩ噺
ANN_BATCH_SIZE = 128       # 鎵瑰ぇ灏?

# =====================================================
# 蹇€熸ā寮?(--quick 鍛戒护琛屽弬鏁版椂浣跨敤)
# =====================================================
QUICK_TEST_SAMPLES = 500   # 蹇€熸ā寮忓彧鐢?00涓祴璇曟牱鏈?
QUICK_EPOCHS = 5           # 蹇€熸ā寮忓彧璁粌5杞?
NOISE_TRIALS_QUICK = 5
NOISE_TRIALS_FULL = 30

# =====================================================
# 璁粌/楠岃瘉鎷嗗垎
# =====================================================
VAL_SAMPLES = 5000         # 浠庤缁冮泦鍒掑垎鐢ㄤ簬闃堝€兼爣瀹氱殑楠岃瘉鏍锋湰鏁?
