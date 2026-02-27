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
// 输入为离线预处理后的 64 维特征向量（proj_sup_64: 784→64）。
// 原始 MNIST 28×28=784 像素通过监督线性投影压缩至 8×8=64 维。
//
// 【差分方案 B（Scheme B）】
// 20 列 BL（Bit-Line）：10 正列 + 10 负列，数字域做减法。
// adc_ctrl 顺序采样 20 个通道，差分结果为有符号 9-bit 数据。
//
// 【参数决策依据（Python 建模最终锁定结果）】
// 最终配置：proj_sup_64 + Scheme B + ADC=8 + W=4 + T=10 + ratio_code=4(4/255)
// 测试精度：90.42%（MNIST test, spike-only, zero-spike=0.00%）
//======================================================================
package snn_soc_pkg;

  // ──────────────────────────────────────────────────────────────────────────
  // 关键功能参数
  // ──────────────────────────────────────────────────────────────────────────

  // 输入维度：离线对 MNIST 28×28=784 像素进行 proj_sup_64 监督投影
  // 得到 8×8=64 维特征向量，降低引脚数和 CIM 阵列行数
  parameter int NUM_INPUTS   = 64;  // 8x8（离线投影后特征维度，=WL 引脚总数）

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
  // 32 位可覆盖 NEURON_DATA_WIDTH + PIXEL_BITS 的移位累加，留出充足裕量
  // 定版 T=10 时最大累积约 = 255 × 2^7 × 10 = 326400 < 2^19，32 位绰绰有余
  // ──────────────────────────────────────────────────────────────────────────
  parameter int LIF_MEM_WIDTH = 32; // 膜电位寄存器位宽（有符号 32-bit）

  // ──────────────────────────────────────────────────────────────────────────
  // 阈值比例寄存器默认值（8-bit 码值，定版锁定）
  // ratio_code=4 → 4/255 ≈ 0.0157，T=10 下 spike-only 测试精度 90.42%，zero-spike=0.00%
  // 固件可读取此值辅助计算绝对阈值，或直接写 REG_THRESHOLD
  // THRESHOLD_RATIO 仅为软件可见的 shadow 寄存器，不自动更新阈值
  // ──────────────────────────────────────────────────────────────────────────
  parameter int THRESHOLD_RATIO_DEFAULT = 4; // 4/255 ≈ 0.0157（定版 ratio_code）

  // 推理帧数（每帧包含 PIXEL_BITS 个子时间步，MSB->LSB）
  // 建模结果：T=10 达最优精度（spike-only 90.42%，zero-spike=0.00%，定版）
  parameter int TIMESTEPS_DEFAULT = 10; // 默认推理帧数（定版）

  // 阈值默认值：ratio_code × (2^PIXEL_BITS - 1) × TIMESTEPS
  // = 4 × (256-1) × 10 = 4 × 255 × 10 = 10200
  // Scheme B 差分输出为有符号数，膜电位可负，阈值为正值门限
  parameter int THRESHOLD_DEFAULT =
      THRESHOLD_RATIO_DEFAULT * ((1 << PIXEL_BITS) - 1) * TIMESTEPS_DEFAULT;
  // 展开：4 * 255 * 10 = 10200

  // ──────────────────────────────────────────────────────────────────────────
  // FIFO 深度（按 V1 完整版实际需求保留冗余）
  // 需要覆盖 TB 一次性灌入的 bit-plane 数量（TIMESTEPS * PIXEL_BITS = 10 * 8 = 80）
  // 实际需求 80，选 256 提供充足余量，对仿真面积无影响
  // ──────────────────────────────────────────────────────────────────────────
  parameter int INPUT_FIFO_DEPTH  = 256; // 输入 FIFO 深度（64-bit 宽：bit-plane 数据）
  parameter int OUTPUT_FIFO_DEPTH = 256; // 输出 FIFO 深度（4-bit 宽：spike 神经元编号）

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
  // │ 数据 SRAM         │ 0x0001_0000   │ 16KB   │ CPU 数据           │
  // │ 权重/像素 SRAM    │ 0x0003_0000   │ 16KB   │ DMA 读取 + CPU 写  │
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

  // 权重/像素双端口 SRAM：0x0003_0000 ~ 0x0003_3FFF
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
