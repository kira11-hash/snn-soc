// -----------------------------------------------------------------------------
// 自动文档头：本文件的可读性说明（仅注释说明，不改变任何逻辑）
// 文件路径：rtl/top/snn_soc_pkg.sv
// 作用：集中定义全 SoC 共享的常量、参数和地址映射，供 RTL 各模块与 testbench 统一引用。
// 系统角色：避免 NUM_INPUTS、ADC_BITS、FIFO 深度、阈值等关键数值在不同文件里重复手写。
// 行为性质：本文件只有声明和派生常量，没有运行时逻辑。
// 项目规则：文档中的参数和地址若有冲突，应以本 package 为准，避免口径漂移。
// 集成提示：Python 建模阶段最终冻结的参数，应在流片/集成里程碑前同步回本文件。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: snn_soc_pkg.sv
// 包名:   snn_soc_pkg
//
// 【功能概述】
// SNN SoC 全局参数包。集中定义芯片所有关键功能参数、时序参数和
// 地址映射常量，是整个 RTL 的"单一真源（single source of truth，唯一冻结口径）"。
// 所有模块通过 import snn_soc_pkg::* 或 snn_soc_pkg::PARAM 引用，
// 确保全局参数一致，避免各模块手写重复参数导致不一致。
//
// 【V1 输入方案】
// 输入为离线预处理后的 64 维特征向量（当前工程默认口径为 avgpool8x8 得到的 8x8 特征，
// RTL 只约束 64 维接口本身；也可接入其他离线变换结果做实验）。
//
// 【差分方案 B（Scheme B）】
// 20 列 BL（Bit-Line，位线）：10 正列 + 10 负列，数字域做减法。
// adc_ctrl 顺序采样 20 个通道，最后得到 10 路差分结果，每路为有符号 9 位数据。
//
// 【参数决策依据（Python 建模最终锁定结果）】
// 当前默认配置：64 维离线预处理特征 + Scheme B + ADC=8 + T=10 + ratio_code=1（1/255）
// 说明：这组数值就是当前工程默认口径；具体前处理算法不固化在 RTL 常量中。
//      历史建模中的 W=4 属于训练/量化实验口径，不是当前 RTL package 中已冻结的参数。
//======================================================================
/* verilator lint_off UNUSEDPARAM */
package snn_soc_pkg;

  // ──────────────────────────────────────────────────────────────────────────
  // 关键功能参数
  // ──────────────────────────────────────────────────────────────────────────

  // 输入维度：离线预处理后的 64 维特征向量
  // 当前默认口径为 avgpool8x8；数字接口本身只要求 64 维、每维 8 位，
  // 不把具体前处理算法固化进 RTL。
  parameter int NUM_INPUTS   = 64;  // 8x8（默认 avgpool8x8 离线特征维度，=WL 引脚总数）

  // 输出维度：MNIST 分类 0~9，共 10 类
  parameter int NUM_OUTPUTS  = 10;  // 分类类别数（=CIM 正列组数 = 负列组数）

  // ──────────────────────────────────────────────────────────────────────────
  // WL 外部引脚时分复用协议（V1 冻结）
  // 64 根 WL 分 8 组时分发送，每组 8 位
  // 引脚需求：data[7:0] + group_sel[2:0] + latch = 12 个数字引脚
  // 相比 64 根 WL 全并行直连，可显著减少封装引脚占用。
  // ──────────────────────────────────────────────────────────────────────────
  parameter int WL_GROUP_WIDTH = 8; // 每组 WL 位宽（8 根/组）
  parameter int WL_GROUP_COUNT = (NUM_INPUTS / WL_GROUP_WIDTH); // 组数 = 64/8 = 8

  // ──────────────────────────────────────────────────────────────────────────
  // CIM 阵列 BL 通道数（Scheme B：10 正 + 10 负 = 20）
  // ADC MUX 顺序选通 0~19，然后数字域做差分：ch[i] - ch[i+10]
  // ──────────────────────────────────────────────────────────────────────────
  parameter int ADC_CHANNELS = 20; // BL 采样通道总数（= ADC MUX 输入数）

  // 输入位宽（bit-plane 编码）：8 位输入分解为 8 个 bit-plane
  // 发送顺序按 MSB=bit7 → LSB=bit0，即先发最高位，再发最低位。
  parameter int PIXEL_BITS = 8; // bit-plane 数量

  // ADC 输出位宽：8 位对应 256 个量化级别
  // 建模验证：6 位精度约降约 1%，8 位效果最优，12 位无额外收益
  parameter int ADC_BITS   = 8; // ADC 分辨率（位）

  // Scheme B 差分减法后有符号数据位宽（ADC_BITS + 1 位符号位）
  // neuron_data[i] = adc_pos[i] - adc_neg[i]，范围 [-255, +255]
  // 需要 9 位有符号数（最高位为符号位）
  parameter int NEURON_DATA_WIDTH = ADC_BITS + 1; // = 9 位（有符号）

  // ──────────────────────────────────────────────────────────────────────────
  // LIF 膜电位位宽（有符号，需留出位移累加余量）
  // 32 位可覆盖 Scheme B 差分输入在多 bit-plane / 多帧下的累加，留出充足裕量
  // 保守上界：T=10 时最大累积 ≈ (2^ADC_BITS-1) × ((1<<PIXEL_BITS)-1) × T
  //          = 255 × 255 × 10 = 650250 < 2^20，32 位仍绰绰有余
  // ──────────────────────────────────────────────────────────────────────────
  parameter int LIF_MEM_WIDTH = 32; // 膜电位寄存器位宽（有符号 32 位）

  // ──────────────────────────────────────────────────────────────────────────
  // 阈值比例寄存器默认值（8 位码值，定版锁定）
  // ratio_code=1 → 1/255 ≈ 0.00392（当前工程默认 T=10）
  // 固件可读取此值辅助计算绝对阈值，或直接写 REG_THRESHOLD
  // THRESHOLD_RATIO 仅为软件可见的影子寄存器（shadow register），
  // 其作用是保存“比例口径”，并不会自动更新真正生效的 THRESHOLD。
  // ──────────────────────────────────────────────────────────────────────────
  parameter int THRESHOLD_RATIO_DEFAULT = 1; // 1/255 ≈ 0.00392（定版 ratio_code）

  // 推理帧数（每帧包含 PIXEL_BITS 个子时间步，顺序为 MSB->LSB）
  // 工程默认：T=10（当前 ADC=8 / ratio=1/255 冻结配置）
  parameter int TIMESTEPS_DEFAULT = 10; // 默认推理帧数（当前工程默认）

  // 阈值默认值：ratio_code × (2^PIXEL_BITS - 1) × TIMESTEPS
  // = 1 × (256-1) × 10 = 1 × 255 × 10 = 2550
  // Scheme B 差分输出为有符号数，膜电位可负，阈值为正值门限
  parameter int THRESHOLD_DEFAULT =
      THRESHOLD_RATIO_DEFAULT * ((1 << PIXEL_BITS) - 1) * TIMESTEPS_DEFAULT;
  // 展开：1 * 255 * 10 = 2550

  // ──────────────────────────────────────────────────────────────────────────
  // FIFO 深度（按 V1 默认口径保留冗余）
  // 输入 FIFO 需要覆盖 testbench 一次性灌入的 bit-plane 数量：
  //   TIMESTEPS * PIXEL_BITS = 10 * 8 = 80
  // 输出 FIFO 需要覆盖默认 ratio_code=1 下的最坏 spike 数：
  //   单神经元最大累计 = 255 * 255 * T，threshold = 1 * 255 * T，
  //   因此最多约 255 个 spike / 神经元。
  //   NUM_OUTPUTS=10 时保守上界 = 255 * 10 = 2550，故 4096 留出安全余量。
  // ──────────────────────────────────────────────────────────────────────────
  parameter int INPUT_FIFO_DEPTH  = 256;  // 输入 FIFO 深度（64 位宽：bit-plane 数据）
  parameter int OUTPUT_FIFO_DEPTH = 4096; // 输出 FIFO 深度（宽度=$clog2(MAX_NEURONS)：spike 神经元编号）

  // ──────────────────────────────────────────────────────────────────────────
  // 行为模型延迟参数（仅用于仿真，不影响综合；可在仿真顶层覆盖）
  // ──────────────────────────────────────────────────────────────────────────
  parameter int DAC_LATENCY_CYCLES = 5;  // WL 有效→DAC 稳定：5 周期（模拟建立时间）
  parameter int CIM_LATENCY_CYCLES = 10; // CIM 开始→完成：10 周期（RRAM 电流积分）
  // parameter int ADC_LATENCY_CYCLES = 5;  // 未使用，实际由 SETTLE+SAMPLE 控制
  parameter int ADC_MUX_SETTLE_CYCLES = 2; // BL_SEL 切换后 MUX 稳定等待周期
  parameter int ADC_SAMPLE_CYCLES = 3;     // ADC 采样保持持续周期

  // ──────────────────────────────────────────────────────────────────────────
  // 地址映射常量（V1 地址映射）
  // 说明：下面列的是“基地址 + 空间大小”。
  // 真正结束地址统一按 end = base + size - 1 计算。
  // ┌──────────────────┬───────────────┬────────┬─────────────────────┐
  // │ 区域              │ 基地址        │ 大小   │ 用途               │
  // ├──────────────────┼───────────────┼────────┼─────────────────────┤
  // │ 指令 SRAM         │ 0x0000_0000   │ 16KB   │ CPU 取指（E203用） │
  // │ 数据 SRAM         │ 0x0001_0000   │ 16KB   │ CPU 数据 / 当前 DMA 输入源 │
  // │ weight_sram（保留）│ 0x0003_0000   │ 16KB   │ 预留总线窗口 / 非当前 DMA 主路径 │
  // │ 主寄存器 Bank     │ 0x4000_0000   │ 256B   │ SNN 控制/状态      │
  // │ DMA 寄存器        │ 0x4000_0100   │ 256B   │ DMA 控制/状态      │
  // │ UART 控制器       │ 0x4000_0200   │ 256B   │ 串口外设（V1: TX） │
  // │ SPI 控制器        │ 0x4000_0300   │ 256B   │ SPI Master（V1）   │
  // │ FIFO 状态寄存器   │ 0x4000_0400   │ 256B   │ FIFO 计数/状态     │
  // └──────────────────┴───────────────┴────────┴─────────────────────┘
  // ──────────────────────────────────────────────────────────────────────────

  // SRAM 容量（V1：在面积受限下缩减到足够用的规模）
  localparam logic [31:0] INSTR_SRAM_BYTES  = 32'h0000_4000; // 16KB
  localparam logic [31:0] DATA_SRAM_BYTES   = 32'h0000_4000; // 16KB
  localparam logic [31:0] WEIGHT_SRAM_BYTES = 32'h0000_4000; // 16KB

  // 指令 SRAM：0x0000_0000 ~ 0x0000_3FFF
  localparam logic [31:0] ADDR_INSTR_BASE  = 32'h0000_0000;
  localparam logic [31:0] ADDR_INSTR_END   = ADDR_INSTR_BASE + INSTR_SRAM_BYTES - 1;
  // = 0x0000_3FFF

  // 数据 SRAM：0x0001_0000 ~ 0x0001_3FFF
  localparam logic [31:0] ADDR_DATA_BASE   = 32'h0001_0000;
  localparam logic [31:0] ADDR_DATA_END    = ADDR_DATA_BASE + DATA_SRAM_BYTES - 1;
  // = 0x0001_3FFF

  // weight_sram 预留窗口：0x0003_0000 ~ 0x0003_3FFF
  // 当前 main 的正式输入路径仍是 data_sram -> dma_engine -> input_fifo；
  // 本窗口保留给后续 CPU / 启动程序扩展或权重相关实验，不作为默认 DMA 源。
  localparam logic [31:0] ADDR_WEIGHT_BASE = 32'h0003_0000;
  localparam logic [31:0] ADDR_WEIGHT_END  = ADDR_WEIGHT_BASE + WEIGHT_SRAM_BYTES - 1;
  // = 0x0003_3FFF

  // 主寄存器 Bank（SNN 控制/状态）：0x4000_0000 ~ 0x4000_00FF（256B）
  localparam logic [31:0] ADDR_REG_BASE    = 32'h4000_0000;
  localparam logic [31:0] ADDR_REG_END     = 32'h4000_00FF;

  // DMA 引擎寄存器：0x4000_0100 ~ 0x4000_01FF（256B）
  localparam logic [31:0] ADDR_DMA_BASE    = 32'h4000_0100;
  localparam logic [31:0] ADDR_DMA_END     = 32'h4000_01FF;

  // UART 外设（V1：uart_ctrl，TX 可用，RX 保留）：0x4000_0200 ~ 0x4000_02FF（256B）
  localparam logic [31:0] ADDR_UART_BASE   = 32'h4000_0200;
  localparam logic [31:0] ADDR_UART_END    = 32'h4000_02FF;

  // SPI 外设（V1：spi_ctrl，Mode 0）：0x4000_0300 ~ 0x4000_03FF（256B）
  localparam logic [31:0] ADDR_SPI_BASE    = 32'h4000_0300;
  localparam logic [31:0] ADDR_SPI_END     = 32'h4000_03FF;

  // FIFO 状态寄存器窗口：0x4000_0400 ~ 0x4000_04FF（256B）
  localparam logic [31:0] ADDR_FIFO_BASE   = 32'h4000_0400;
  localparam logic [31:0] ADDR_FIFO_END    = 32'h4000_04FF;

  // ARM FPGA demo AXI-Lite window for the standalone V2.B accelerator.
  localparam logic [31:0] ADDR_V2B_BASE    = 32'hA000_0000;
  localparam logic [31:0] ADDR_V2B_END     = 32'hA000_0FFF;

  // ──────────────────────────────────────────────────────────────────────────
  // V2 CIM 编程参数（ENABLE_PROGRAM_MODE=1 时生效）
  // ──────────────────────────────────────────────────────────────────────────
  parameter int PROG_LEVELS           = 16;  // 16 档电阻级别（N pulse = 第 N 档）
  // Programming pulse width presets at 50MHz system clock.
  // Writes use selectable 1us / 10us / 100us pulses; erase always uses 1ms.
  parameter int PROG_WRITE_PULSE_1US_CYC   = 50;
  parameter int PROG_WRITE_PULSE_10US_CYC  = 500;
  parameter int PROG_WRITE_PULSE_100US_CYC = 5000;
  parameter int PROG_ERASE_WIDTH_CYC       = 50000; // 1ms @ 50MHz
  parameter int PROG_PULSE_WIDTH_CYC       = PROG_WRITE_PULSE_1US_CYC; // default write pulse = 1us
  parameter int PROG_VERIFY_RETRY_MAX = 4;   // verify 失败后最大重试次数
  parameter int PROG_ROWS             = 64;  // 可编程行数（= NUM_INPUTS）
  parameter int PROG_COLS             = 20;  // 可编程列数（= ADC_CHANNELS）

  // ──────────────────────────────────────────────────────────────────────────
  // V2 多层 SNN 参数（ENABLE_MULTI_LAYER=1 时生效）
  // ──────────────────────────────────────────────────────────────────────────
`ifdef SIM_MULTI_LAYER
  parameter bit ENABLE_MULTI_LAYER = 1'b1;
`else
  parameter bit ENABLE_MULTI_LAYER = 1'b0;
`endif
  parameter int MAX_LAYERS         = 4;   // 最多支持层数
  parameter int MAX_NEURONS        = 128; // 时分复用神经元最大数目
  parameter int MAX_WL_COUNT       = 128; // 单层最大 WL 行数
  parameter int MAX_BL_COUNT       = 256; // 单层最大 BL 列数（含 pos+neg）
  parameter int MAX_BL_SCAN        = 128; // ADC 单次推理最大扫描列数（含 pos+neg）

  // 层描述符实际在 REG_BANK offset 0x50..0x8F（REG_LAYER_BASE 起）

  // ──────────────────────────────────────────────────────────────────────────
  // V2 行为模型开关（D3-002 修复）
  // ──────────────────────────────────────────────────────────────────────────
  // 【为什么要独立这个开关？】
  //   cim_macro_blackbox 行为模型有两种模式：
  //     (a) popcount 近似：BL 返回 ~popcount(wl_spike)，V1 smoke 默认用此
  //     (b) BRAM 权重：`$readmemh` 加载真实权重，BL 返回 weighted sum
  //
  //   之前 snn_soc_top 把 P_USE_BRAM_WEIGHTS 绑在 ENABLE_PROGRAM_MODE 上，
  //   但 V2 多层 sample_align TB 的需求可能是：
  //     - 不要编程控制器（ENABLE_PROGRAM_MODE=0，省面积）
  //     - 但仍要 BRAM 权重模型（才能对齐 Python 结果）
  //
  //   解耦后：
  //     - V1 baseline: 两个都 0（popcount 行为）
  //     - V2 编程 TB:   ENABLE_PROGRAM_MODE=1（BRAM 跟着自动开）
  //     - V2 对齐 TB:   定义 SIM_BRAM_WEIGHT_MODEL，ENABLE_PROGRAM_MODE 可独立选
  //
  //   snn_soc_top 的 P_USE_BRAM_WEIGHTS 入参改为 OR 两者。
`ifdef SIM_BRAM_WEIGHT_MODEL
  parameter bit ENABLE_BRAM_WEIGHT_MODEL = 1'b1;
`else
  parameter bit ENABLE_BRAM_WEIGHT_MODEL = 1'b0;
`endif

  // ──────────────────────────────────────────────────────────────────────────
  // V2.B streamed-rate constants (REV 3.3 D15/D16)
  //
  // Additive to V1 parameters above. New V2.B modules
  // (input_stream_sram, stream_buffer_v2, tile_partial_buf, layer_sequencer_v2)
  // reference these. V1 regressions remain untouched.
  //
  // Policy (B0 mini-spec §B0.1):
  //   - HW array is 256×256 (square for easier RRAM fabrication)
  //   - ADC compile-time 10-bit (D15; runtime-switchable deferred to V3)
  //   - T_MAX=256 (covers T ∈ {32, 64, 128, 256} Python sweep)
  //   - Scheme B differential (unchanged from V1)
  //   - Partial-sum accumulator stored [T_MAX × MAX_OUT_NEURONS] per D1
  //
  // Memory budget (Phase B0 §B0.2, D16 precise):
  //   - input_stream_sram   = T_MAX × V2B_NUM_INPUTS = 64 Kbit (~8 KB)
  //   - stream_buf_A/B each = T_MAX × V2B_MAX_OUT_NEURONS = 32 Kbit (~4 KB)
  //   - tile_partial_buf    = T_MAX × V2B_MAX_OUT_NEURONS × signed V2B_PARTIAL_WIDTH
  //                         = 256 × 128 × 14 bit = 459 Kbit (~56 KB)
  // ──────────────────────────────────────────────────────────────────────────
  parameter int V2B_NUM_INPUTS         = 256; // WL rows in V2.B 256×256 array
  parameter int V2B_MAX_BL_SCAN        = 256; // Scheme B pos+neg = 2 × out_dim, up to 256
  parameter int V2B_MAX_OUT_NEURONS    = 128; // = V2B_MAX_BL_SCAN / 2
  parameter int V2B_MAX_TIMESTEPS      = 256; // T_MAX for streamed rate (P5-P7 T=256 covered)
  parameter int V2B_ADC_BITS           = 10;  // REV 3.3 D15: compile-time 10-bit
  parameter int V2B_ADC_MAX            = (1 << V2B_ADC_BITS) - 1;
  // Per-tile ADC diff width = adc_bits + 1 (signed pos - neg); widen for safe
  // cross-tile accumulation: diff + ceil(log2(N_tiles_max=4)) = 11 + 2 = 13 → pad to 14.
  parameter int V2B_PARTIAL_WIDTH      = 14;
  // LIF membrane width grows to absorb T_MAX × partial_diff accumulation + safety margin.
  // Max per-t partial_diff ≤ 2 * V2B_ADC_MAX = 2046 ≤ 2^11.
  // Worst-case membrane over T=256 ≤ 256 × 2046 ≈ 2^19. 32-bit signed is ample.
  parameter int V2B_LIF_MEM_WIDTH      = 32;

  // Sum-max policy (topology_desc.bin adc_full_scale field):
  //   mode 0 = ARRAY:     SUM_MAX = V2B_NUM_INPUTS × 15     (fixed 3840)
  //   mode 1 = ACTIVE_WL: SUM_MAX = stage.in_dim × 15      (per-tile, firmware-supplied)
  parameter int V2B_SUM_MAX_ARRAY      = V2B_NUM_INPUTS * 15; // = 3840

  // V2.B CONV extension constants (REV 5, M3.A).
  parameter int V2B_CONV_FMAP_BANK_KIB         = 256;       // ping-pong A/B each
  parameter int V2B_CONV_MAX_K                 = 5;
  parameter int V2B_CONV_MAX_C_IN              = 128;
  parameter int V2B_CONV_MAX_KKC               = 1152;      // K*K*C_in <= this
  parameter int V2B_CONV_MAX_H                 = 64;
  parameter int V2B_CONV_MAX_W                 = 64;
  parameter int V2B_FMAP_WORDS_PER_STREAM_MAX  = 8;         // T<=256 => ceil(T/32)
  parameter int V2B_CONV_WEIGHT_TIMEOUT_CYCLES = 1_000_000;

  // Stream buffer ownership encoding (REV 3.3 D14 state machine)
  parameter logic [1:0] V2B_BUF_STATE_FREE    = 2'd0;
  parameter logic [1:0] V2B_BUF_STATE_WRITING = 2'd1;
  parameter logic [1:0] V2B_BUF_STATE_READY   = 2'd2;
  parameter logic [1:0] V2B_BUF_STATE_READING = 2'd3;

  // INPUT_SRC / OUTPUT_DST encoding for STAGE_CFG3.
  // REV 5 MINOR-6 widens input source IDs to 3 bits for dynamic CONV
  // sources. The legacy values keep the original low 2-bit encoding, so
  // existing FC paths with selector[2]=0 remain byte-compatible.
  parameter int V2B_BUF_SEL_W = 3;
  parameter logic [V2B_BUF_SEL_W-1:0] V2B_BUF_SEL_INPUT_SRAM     = 3'b000; // was 2'b00
  parameter logic [V2B_BUF_SEL_W-1:0] V2B_BUF_SEL_STREAM_A       = 3'b001; // was 2'b01
  parameter logic [V2B_BUF_SEL_W-1:0] V2B_BUF_SEL_STREAM_B       = 3'b010; // was 2'b10
  parameter logic [V2B_BUF_SEL_W-1:0] V2B_BUF_SEL_OUTPUT_FIFO    = 3'b011; // OUTPUT_DST only
  parameter logic [V2B_BUF_SEL_W-1:0] V2B_BUF_SEL_PATCH_UNROLLER = 3'b100;
  parameter logic [V2B_BUF_SEL_W-1:0] V2B_BUF_SEL_FMAP_FLATTEN   = 3'b101;

  // Stage error codes (STAGE_STATUS.ERR[23:16])
  parameter logic [7:0] V2B_STAGE_ERR_OK                   = 8'h00;
  parameter logic [7:0] V2B_STAGE_ERR_START_WHILE_BUSY     = 8'h01;
  parameter logic [7:0] V2B_STAGE_ERR_SRC_DST_CONFLICT     = 8'h02;
  parameter logic [7:0] V2B_STAGE_ERR_TILE_BUF_UNAVAILABLE = 8'h03;
  parameter logic [7:0] V2B_STAGE_ERR_CIM_NOT_READY        = 8'h04;
  parameter logic [7:0] V2B_STAGE_ERR_DIM_OUT_OF_RANGE     = 8'h05;
  // PATCH_UNROLLER / FMAP_FLATTEN 这两个 dynamic WL 源必须在 cfg_conv_mode=1
  // 才合法。CPU 误把 cfg_input_src 设到 PATCH/FLATTEN 但忘记打开 cfg_conv_mode
  // 时，stage_engine 必须立刻 reject 这一轮，避免 FSM 在 dyn_wl_resp 永远拿不到
  // 数据的状态下静默卡死。
  parameter logic [7:0] V2B_STAGE_ERR_DYN_SRC_NEEDS_CONV_MODE = 8'h06;

endpackage
/* verilator lint_on UNUSEDPARAM */
