//======================================================================
// 文件名: snn_soc_pkg.sv
// 描述: SNN SoC 全局参数与地址映射常量。
//       统一 NUM_INPUTS/NUM_OUTPUTS 等关键参数，避免位宽不一致。
//       本工程固定输入 7x7 -> NUM_INPUTS=49，输出类别 NUM_OUTPUTS=10。
//======================================================================
package snn_soc_pkg;
  // 关键功能参数
  parameter int NUM_INPUTS  = 49;  // 7x7
  parameter int NUM_OUTPUTS = 10;
  parameter int TIMESTEPS_DEFAULT = 20;

  // 行为模型延迟参数（可在仿真中修改）
  parameter int DAC_LATENCY_CYCLES = 5;
  parameter int CIM_LATENCY_CYCLES = 10;
  parameter int ADC_LATENCY_CYCLES = 5;
  parameter int ADC_MUX_SETTLE_CYCLES = 2;
  parameter int ADC_SAMPLE_CYCLES = 3;

  // 地址映射常量
  localparam logic [31:0] ADDR_INSTR_BASE  = 32'h0000_0000;
  localparam logic [31:0] ADDR_INSTR_END   = 32'h0000_FFFF;

  localparam logic [31:0] ADDR_DATA_BASE   = 32'h0001_0000;
  localparam logic [31:0] ADDR_DATA_END    = 32'h0002_FFFF;

  localparam logic [31:0] ADDR_WEIGHT_BASE = 32'h0003_0000;
  localparam logic [31:0] ADDR_WEIGHT_END  = 32'h0003_3FFF;

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
