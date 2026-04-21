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
  parameter int OUTPUT_FIFO_DEPTH = 4096; // 输出 FIFO 深度（4 位宽：spike 神经元编号）

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

  // ──────────────────────────────────────────────────────────────────────────
  // V1 单层 CIM 编程参数（2026-04-22 从 v2 分支移植到 main）
  //
  // 功能：支持写入（SET）、逐 cell 擦除（RESET）、全阵列擦除、读回验证。
  // 只保留 V1 单层 64 WL × 20 BL 架构所需的常量；不引入 V2.B 多层 / 256×256
  // 相关的 MAX_LAYERS / V2B_* 等参数。
  // ──────────────────────────────────────────────────────────────────────────

  parameter int PROG_LEVELS  = 16;           // 4-bit 权重量化等级（16 档，0=HRS，15=LRS）
  parameter int PROG_ROWS    = NUM_INPUTS;   // = 64，可编程行（= WL 数）
  parameter int PROG_COLS    = ADC_CHANNELS; // = 20，可编程列（= ADC 通道/BL）

  // 写入脉冲宽度三档（1us / 10us / 100us @ 50MHz 系统时钟）。
  // 器件实际编程窗口待实验标定，因此给三档灵活选择；擦除固定 1ms。
  parameter int PROG_WRITE_PULSE_1US_CYC   = 50;    // 1  us * 50 MHz =   50 cycles
  parameter int PROG_WRITE_PULSE_10US_CYC  = 500;   // 10 us * 50 MHz =  500 cycles
  parameter int PROG_WRITE_PULSE_100US_CYC = 5000;  // 100us * 50 MHz = 5000 cycles
  parameter int PROG_ERASE_WIDTH_CYC       = 50000; // 1ms @ 50 MHz  = 50000 cycles
  // 默认复位值 = 1us（最短，安全默认）
  parameter int PROG_PULSE_WIDTH_CYC       = PROG_WRITE_PULSE_1US_CYC;

  parameter int PROG_VERIFY_RETRY_MAX = 4;   // verify 失败后最大重试次数

  // bl_sel 位宽上界：V1 单层只需 ADC_CHANNELS=20 通道，$clog2(20)=5。
  // 为保持 cim_program_ctrl / cim_macro_arbiter 接口 V1↔V2 同构，这里统一
  // 命名为 MAX_BL_SCAN（等价于 ADC_CHANNELS），方便未来复用代码。
  parameter int MAX_BL_SCAN = ADC_CHANNELS;

endpackage
/* verilator lint_on UNUSEDPARAM */
