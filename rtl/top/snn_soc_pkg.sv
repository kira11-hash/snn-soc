`timescale 1ns/1ps
//======================================================================
// 文件名: snn_soc_pkg.sv
// 描述: SNN SoC 全局参数与地址映射常量。
//       统一 NUM_INPUTS/NUM_OUTPUTS 等关键参数，避免位宽不一致。
//       V1 输入为离线预处理后的 64 维特征向量（proj_sup_64: 784→64）。
//       差分方案 B：20 列 BL（10 正 + 10 负），数字域做减法。
//======================================================================
package snn_soc_pkg;
  // 关键功能参数
  parameter int NUM_INPUTS   = 64;  // 8x8（离线投影后特征维度）
  parameter int NUM_OUTPUTS  = 10;  // 分类类别数
  // WL 外部复用协议（V1 冻结）：64bit 分 8 组发送，每组 8bit
  parameter int WL_GROUP_WIDTH = 8;
  parameter int WL_GROUP_COUNT = (NUM_INPUTS / WL_GROUP_WIDTH);
  // CIM 阵列 BL 通道数（Scheme B：10 正 + 10 负 = 20）
  parameter int ADC_CHANNELS = 20;
  // 像素位宽（bit-plane 编码）
  parameter int PIXEL_BITS = 8;
  // ADC 输出位宽
  parameter int ADC_BITS   = 8;
  // Scheme B 差分减法后有符号数据位宽（ADC_BITS + 1 位符号）
  parameter int NEURON_DATA_WIDTH = ADC_BITS + 1;
  // LIF 膜电位位宽（有符号，需留出位移累加余量）
  // 32 位可覆盖 NEURON_DATA_WIDTH + PIXEL_BITS 的移位累加，留出充足裕量
  parameter int LIF_MEM_WIDTH = 32;
  // 阈值比例寄存器默认值（8-bit: 102/255 ≈ 0.40，建模最优 ratio）
  parameter int THRESHOLD_RATIO_DEFAULT = 102;
  // 推理帧数（每帧包含 PIXEL_BITS 个子时间步，MSB->LSB）
  // 建模结果：T=1 即达最优精度，无需多帧
  parameter int TIMESTEPS_DEFAULT = 1;
  // 阈值默认值：ratio × (2^PIXEL_BITS - 1) × TIMESTEPS
  // Scheme B 差分输出为有符号数，膜电位可负，阈值为正值门限
  parameter int THRESHOLD_DEFAULT =
      THRESHOLD_RATIO_DEFAULT * ((1 << PIXEL_BITS) - 1) * TIMESTEPS_DEFAULT;

  // FIFO 深度（按 V1 完整版实际需求保留冗余）
  // 需要覆盖 TB 一次性灌入的 bit-plane 数量（TIMESTEPS * PIXEL_BITS）
  parameter int INPUT_FIFO_DEPTH  = 256;
  parameter int OUTPUT_FIFO_DEPTH = 256;

  // 行为模型延迟参数（可在仿真中修改）
  parameter int DAC_LATENCY_CYCLES = 5;
  parameter int CIM_LATENCY_CYCLES = 10;
  // parameter int ADC_LATENCY_CYCLES = 5;  // 未使用，实际使用 ADC_MUX_SETTLE_CYCLES + ADC_SAMPLE_CYCLES
  parameter int ADC_MUX_SETTLE_CYCLES = 2;
  parameter int ADC_SAMPLE_CYCLES = 3;

  // 地址映射常量
  // SRAM 容量（V1：在面积受限下缩减到足够用的规模）
  localparam logic [31:0] INSTR_SRAM_BYTES  = 32'h0000_4000; // 16KB
  localparam logic [31:0] DATA_SRAM_BYTES   = 32'h0000_4000; // 16KB
  localparam logic [31:0] WEIGHT_SRAM_BYTES = 32'h0000_4000; // 16KB

  localparam logic [31:0] ADDR_INSTR_BASE  = 32'h0000_0000;
  localparam logic [31:0] ADDR_INSTR_END   = ADDR_INSTR_BASE + INSTR_SRAM_BYTES - 1;

  localparam logic [31:0] ADDR_DATA_BASE   = 32'h0001_0000;
  localparam logic [31:0] ADDR_DATA_END    = ADDR_DATA_BASE + DATA_SRAM_BYTES - 1;

  localparam logic [31:0] ADDR_WEIGHT_BASE = 32'h0003_0000;
  localparam logic [31:0] ADDR_WEIGHT_END  = ADDR_WEIGHT_BASE + WEIGHT_SRAM_BYTES - 1;

  localparam logic [31:0] ADDR_REG_BASE    = 32'h4000_0000;
  localparam logic [31:0] ADDR_REG_END     = 32'h4000_00FF;

  localparam logic [31:0] ADDR_DMA_BASE    = 32'h4000_0100;
  localparam logic [31:0] ADDR_DMA_END     = 32'h4000_01FF;

  localparam logic [31:0] ADDR_UART_BASE   = 32'h4000_0200;
  localparam logic [31:0] ADDR_UART_END    = 32'h4000_02FF;

  localparam logic [31:0] ADDR_SPI_BASE    = 32'h4000_0300;
  localparam logic [31:0] ADDR_SPI_END     = 32'h4000_03FF;

  localparam logic [31:0] ADDR_FIFO_BASE   = 32'h4000_0400;
  localparam logic [31:0] ADDR_FIFO_END    = 32'h4000_04FF;
endpackage


