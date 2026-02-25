`timescale 1ns/1ps
//======================================================================
// 文件名: chip_top.sv
// 描述: 芯片 pad 级顶层骨架（预留）
//
// 设计意图:
//   1) 当前阶段先复用 snn_soc_top 的内部接口与仿真链路，不改变现有行为。
//   2) 预留外部 45-pin 复用方案相关端口，后续在此层完成 pad 映射与引脚复用。
//   3) 避免把 pad 级改动直接耦合到 snn_soc_top 内核逻辑。
//
// 注意:
//   - 当前外部复用端口仅占位，尚未与 snn_soc_top 内部 wl_mux_wrapper 相连。
//   - 后续 tapeout 前需在本模块内完成:
//       a) pad cell 实例化
//       b) wl_data/wl_group_sel/wl_latch 与内部信号连接
//       c) 电平/驱动能力/IO 约束收敛
//======================================================================
module chip_top (
  // 基础时钟复位（pad）
  input  logic clk_pad,
  input  logic rst_n_pad,

  // 常规外设（pad）
  input  logic uart_rx_pad,
  output logic uart_tx_pad,
  output logic spi_cs_n_pad,
  output logic spi_sck_pad,
  output logic spi_mosi_pad,
  input  logic spi_miso_pad,
  input  logic jtag_tck_pad,
  input  logic jtag_tms_pad,
  input  logic jtag_tdi_pad,
  output logic jtag_tdo_pad,

  // 45-pin 方案相关复用信号（pad，占位）
  output logic [7:0] wl_data_pad,
  output logic [2:0] wl_group_sel_pad,
  output logic       wl_latch_pad,
  output logic       cim_start_pad,
  input  logic       cim_done_pad,
  output logic [4:0] bl_sel_pad,
  input  logic [7:0] bl_data_pad
);
  // 核心 SoC（当前保持原有接口）
  snn_soc_top u_soc_core (
    .clk      (clk_pad),
    .rst_n    (rst_n_pad),
    .uart_rx  (uart_rx_pad),
    .uart_tx  (uart_tx_pad),
    .spi_cs_n (spi_cs_n_pad),
    .spi_sck  (spi_sck_pad),
    .spi_mosi (spi_mosi_pad),
    .spi_miso (spi_miso_pad),
    .jtag_tck (jtag_tck_pad),
    .jtag_tms (jtag_tms_pad),
    .jtag_tdi (jtag_tdi_pad),
    .jtag_tdo (jtag_tdo_pad)
  );

  // 占位默认值（后续由 pad-wrapper 正式连接替换）
  assign wl_data_pad      = 8'h00;
  assign wl_group_sel_pad = 3'h0;
  assign wl_latch_pad     = 1'b0;
  assign cim_start_pad    = 1'b0;
  assign bl_sel_pad       = 5'h00;

  // 占位输入消警告
  wire _unused_chip_top = cim_done_pad ^ ^bl_data_pad;
endmodule

