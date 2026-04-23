// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/top/chip_top.sv
// Purpose: Tapeout-intent chip-level wrapper around snn_soc_top for pad-facing signal routing.
// Role in system: Freezes package-facing logic ports now, while keeping room for future pad cell insertion and physical constraints.
// Current status: Tapeout-intent digital wrapper; the canonical pad source of truth lives in doc/15_asic_pad_map.md.
// Scope note: This file models only signal-facing ports. Power pads and 3 ESD-reserved pads are documented, not instantiated here.
// Remaining tapeout work is pad-cell-library specific: IO cell instantiation, ESD options, drive-strength config, and final package constraints.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: chip_top.sv
// 描述: 芯片 pad 级顶层包装层（tapeout-intent 逻辑版）
//
// 设计意图:
//   1) 以 snn_soc_top 为内核，提供 pad-facing 端口映射，不改变内部协议语义。
//   2) 冻结外部 45 个信号 pad 相关端口，后续在此层完成 pad cell 与物理约束收口。
//   3) 避免把 pad 级改动直接耦合到 snn_soc_top 内核逻辑。
//
// 注意:
//   - 当前外部复用端口已与 snn_soc_top 的 _ext 端口直连，用于冻结 pad-facing 口径。
//   - 全部 48 pad 的正式编号/名称/方向/类型/复位行为以 doc/15_asic_pad_map.md 为准。
//   - 后续 tapeout 前需在本模块内完成:
//       a) pad cell 实例化
//       b) ESD/drive strength/电平配置收敛
//       c) package/pad-ring/IO 约束收敛
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

  // 45 信号 pad 中与模拟芯片互联相关的复用信号（pad-facing RTL 端口）
  //   推理接口（原有，frozen 2026-03-16）
  output logic [7:0] wl_data_pad,
  output logic [2:0] wl_group_sel_pad,
  output logic       wl_latch_pad,
  output logic       cim_start_pad,
  input  logic       cim_done_pad,
  output logic [4:0] bl_sel_pad,
  input  logic [7:0] bl_data_pad,
  //   外部编程接口（新增，frozen 2026-04-24，方案 α'，7 new pads）
  //   详见 doc/08_cim_analog_interface.md §4 + doc/15_asic_pad_map.md 49..55 号 pad
  output logic [2:0] prog_op_pad,      // op 编码（D→A）
  output logic [3:0] prog_level_pad    // 目标电导等级（D→A，仅 write 生效）
);
  // 核心 SoC（TO 目标路径：默认带 E203 + 外部 CIM pad 接口）
  snn_soc_top #(
    .ENABLE_E203(1'b1),
    .ENABLE_EXT_CIM_IF(1'b1)
  ) u_soc_core (
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
    .jtag_tdo (jtag_tdo_pad),
    .wl_data_ext      (wl_data_pad),
    .wl_group_sel_ext (wl_group_sel_pad),
    .wl_latch_ext     (wl_latch_pad),
    .cim_start_ext    (cim_start_pad),
    .cim_done_ext     (cim_done_pad),
    .bl_sel_ext       (bl_sel_pad),
    .bl_data_ext      (bl_data_pad),
    .prog_op_ext      (prog_op_pad),
    .prog_level_ext   (prog_level_pad)
  );
endmodule

