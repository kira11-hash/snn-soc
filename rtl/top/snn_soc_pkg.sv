// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/top/snn_soc_pkg.sv
// Purpose: Central package for SoC-wide constants/parameters used across RTL modules and testbench assumptions.
// Role in system: Prevents duplicated magic numbers (NUM_INPUTS, ADC_BITS, FIFO depths, thresholds, etc.).
// Behavior summary: Pure declarations and derived constants; no runtime logic.
// Critical project rule: Documentation values should follow this package (single source of truth) to avoid stale mismatches.
// Integration note: Python final parameter decisions should be reflected here before tapeout/integration milestones.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: snn_soc_pkg.sv
// 包名:   snn_soc_pkg
//
// 【功能概述】
// SNN SoC 全局参数包。集中定义芯片所有关键功能参数、时序参数和
// 地址映射常量，是整个 RTL 的"单一真理源（Single Source of Truth）"。
// 所有模块通过 import snn_soc_pkg::* 或 snn_soc_pkg::PARAM 引用，
// 确保全局参数一致，避免各模块手写重复参数导致不一致。
//
// 【V1 输入方案】
// 输入为离线预处理后的 64 维特征向量（当前工程默认口径为 avgpool8x8 得到的 8x8 特征，
// RTL 只约束 64 维接口本身；也可接入其他离线变换结果做实验）。
//
// 【差分方案 B（Scheme B）】
// 20 列 BL（Bit-Line）：10 正列 + 10 负列，数字域做减法。
// adc_ctrl 顺序采样 20 个通道，差分结果为有符号 9-bit 数据。
//
// 【参数决策依据（Python 建模最终锁定结果）】
// 当前默认配置：64 维离线预处理特征 + Scheme B + ADC=8 + T=10 + ratio_code=1(1/255)
// 说明：这组数值就是当前工程默认口径；具体前处理算法不固化在 RTL 常量中。
//      历史建模中的 W=4 属于训练/量化实验口径，不是当前 RTL package 中的冻结参数。
//======================================================================
/* verilator lint_off UNUSEDPARAM */
package snn_soc_pkg;

  // ──────────────────────────────────────────────────────────────────────────
  // 关键功能参数
  // ──────────────────────────────────────────────────────────────────────────

  // 输入维度：离线预处理后的 64 维特征向量
  // 当前默认口径为 avgpool8x8；数字接口本身只要求 64 维、每维 8bit
  parameter int NUM_INPUTS   = 64;  // 8x8（默认 avgpool8x8 离线特征维度，=WL 引脚总数）

  // 输出维度：MNIST 分类 0~9，共 10 类
  parameter int NUM_OUTPUTS  = 10;  // 分类类别数（=CIM 正列组数 = 负列组数）

  // ──────────────────────────────────────────────────────────────────────────
  // WL 外部引脚时分复用协议（V1 冻结）
  // 64 根 WL 分 8 组时分发送，每组 8bit
  // 引脚需求：data[7:0] + group_sel[2:0] + latch = 12 PAD（vs 直连 64 PAD）
  // ──────────────────────────────────────────────────────────────────────────
  parameter int WL_GROUP_WIDTH = 8; // 每组 WL 位宽（8 根/组）
  parameter int WL_GROUP_COUNT = (NUM_INPUTS / WL_GROUP_WIDTH); // 组数 = 64/8 = 8

  // ──────────────────────────────────────────────────────────────────────────
  // CIM 阵列 BL 通道数（Scheme B：10 正 + 10 负 = 20）
  // ADC MUX 顺序选通 0~19，然后数字域差分：ch[i]-ch[i+10]
  // ──────────────────────────────────────────────────────────────────────────
  parameter int ADC_CHANNELS = 20; // BL 采样通道总数（= ADC MUX 输入数）

  // 像素位宽（bit-plane 编码）：8-bit 像素分解为 8 个 bit-plane
  parameter int PIXEL_BITS = 8; // bit-plane 数量（MSB=bit7→LSB=bit0 依次发送）

  // ADC 输出位宽：8-bit 对应 256 量化级别
  // 建模验证：6-bit 精度约降 1%，8-bit 最优，12-bit 无增益
  parameter int ADC_BITS   = 8; // ADC 分辨率（bit）

  // Scheme B 差分减法后有符号数据位宽（ADC_BITS + 1 位符号）
  // neuron_data[i] = adc_pos[i] - adc_neg[i]，范围 [-255, +255]
  // 需要 9-bit 有符号（最高位为符号位）
  parameter int NEURON_DATA_WIDTH = ADC_BITS + 1; // = 9（有符号）

  // ──────────────────────────────────────────────────────────────────────────
  // LIF 膜电位位宽（有符号，需留出位移累加余量）
  // 32 位可覆盖 Scheme B 差分输入在多 bit-plane / 多帧下的累加，留出充足裕量
  // 保守上界：T=10 时最大累积 ≈ (2^ADC_BITS-1) × ((1<<PIXEL_BITS)-1) × T
  //          = 255 × 255 × 10 = 650250 < 2^20，32 位仍绰绰有余
  // ──────────────────────────────────────────────────────────────────────────
  parameter int LIF_MEM_WIDTH = 32; // 膜电位寄存器位宽（有符号 32-bit）

  // ──────────────────────────────────────────────────────────────────────────
  // 阈值比例寄存器默认值（8-bit 码值，定版锁定）
  // ratio_code=1 → 1/255 ≈ 0.00392（当前工程默认 T=10）
  // 固件可读取此值辅助计算绝对阈值，或直接写 REG_THRESHOLD
  // THRESHOLD_RATIO 仅为软件可见的 shadow 寄存器，不自动更新阈值
  // ──────────────────────────────────────────────────────────────────────────
  parameter int THRESHOLD_RATIO_DEFAULT = 1; // 1/255 ≈ 0.00392（定版 ratio_code）

  // 推理帧数（每帧包含 PIXEL_BITS 个子时间步，MSB->LSB）
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
  // 输入 FIFO 需要覆盖 TB 一次性灌入的 bit-plane 数量（TIMESTEPS * PIXEL_BITS = 10 * 8 = 80）
  // 输出 FIFO 需要覆盖默认 ratio_code=1 下的最坏 spike 数：
  //   单神经元最大累计 = 255 * 255 * T，threshold = 1 * 255 * T，因此最多 255 spikes / neuron
  //   NUM_OUTPUTS=10 时保守上界 = 255 * 10 = 2550 spikes，4096 预留安全余量
  // ──────────────────────────────────────────────────────────────────────────
  parameter int INPUT_FIFO_DEPTH  = 256; // 输入 FIFO 深度（64-bit 宽：bit-plane 数据）
  parameter int OUTPUT_FIFO_DEPTH = 4096; // 输出 FIFO 深度（4-bit 宽：spike 神经元编号）

  // ──────────────────────────────────────────────────────────────────────────
  // 行为模型延迟参数（仿真专用，不影响综合；可在仿真顶层覆盖）
  // ──────────────────────────────────────────────────────────────────────────
  parameter int DAC_LATENCY_CYCLES = 5;  // WL 有效→DAC 稳定：5 周期（模拟建立时间）
  parameter int CIM_LATENCY_CYCLES = 10; // CIM 开始→完成：10 周期（RRAM 电流积分）
  // parameter int ADC_LATENCY_CYCLES = 5;  // 未使用，实际由 SETTLE+SAMPLE 控制
  parameter int ADC_MUX_SETTLE_CYCLES = 2; // BL_SEL 切换后 MUX 稳定等待周期
  parameter int ADC_SAMPLE_CYCLES = 3;     // ADC 采样保持持续周期

  // ──────────────────────────────────────────────────────────────────────────
  // 地址映射常量（V1 memory map）
  // ┌──────────────────┬───────────────┬────────┬─────────────────────┐
  // │ 区域              │ 基地址        │ 大小   │ 用途               │
  // ├──────────────────┼───────────────┼────────┼─────────────────────┤
  // │ 指令 SRAM         │ 0x0000_0000   │ 16KB   │ CPU 取指（E203用） │
  // │ 数据 SRAM         │ 0x0001_0000   │ 16KB   │ CPU 数据 / 当前 DMA 输入源 │
  // │ weight_sram(保留) │ 0x0003_0000   │ 16KB   │ 预留总线窗口 / 非当前 DMA 主路径 │
  // │ 主寄存器 Bank     │ 0x4000_0000   │ 256B   │ SNN 控制/状态      │
  // │ DMA 寄存器        │ 0x4000_0100   │ 256B   │ DMA 控制/状态      │
  // │ UART stub         │ 0x4000_0200   │ 256B   │ 串口外设（占位）   │
  // │ SPI stub          │ 0x4000_0300   │ 256B   │ SPI Flash（占位）  │
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
  // 本窗口保留给后续 CPU/bootloader 扩展或权重相关实验，不作为默认 DMA 源。
  localparam logic [31:0] ADDR_WEIGHT_BASE = 32'h0003_0000;
  localparam logic [31:0] ADDR_WEIGHT_END  = ADDR_WEIGHT_BASE + WEIGHT_SRAM_BYTES - 1;
  // = 0x0003_3FFF

  // 主寄存器 Bank（SNN 控制/状态）：0x4000_0000 ~ 0x4000_00FF（256B）
  localparam logic [31:0] ADDR_REG_BASE    = 32'h4000_0000;
  localparam logic [31:0] ADDR_REG_END     = 32'h4000_00FF;

  // DMA 引擎寄存器：0x4000_0100 ~ 0x4000_01FF（256B）
  localparam logic [31:0] ADDR_DMA_BASE    = 32'h4000_0100;
  localparam logic [31:0] ADDR_DMA_END     = 32'h4000_01FF;

  // UART 外设（stub）：0x4000_0200 ~ 0x4000_02FF（256B）
  localparam logic [31:0] ADDR_UART_BASE   = 32'h4000_0200;
  localparam logic [31:0] ADDR_UART_END    = 32'h4000_02FF;

  // SPI 外设（stub）：0x4000_0300 ~ 0x4000_03FF（256B）
  localparam logic [31:0] ADDR_SPI_BASE    = 32'h4000_0300;
  localparam logic [31:0] ADDR_SPI_END     = 32'h4000_03FF;

  // FIFO 状态寄存器窗口：0x4000_0400 ~ 0x4000_04FF（256B）
  localparam logic [31:0] ADDR_FIFO_BASE   = 32'h4000_0400;
  localparam logic [31:0] ADDR_FIFO_END    = 32'h4000_04FF;

endpackage
/* verilator lint_on UNUSEDPARAM */
