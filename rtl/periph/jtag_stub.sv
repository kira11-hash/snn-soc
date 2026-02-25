`timescale 1ns/1ps
//======================================================================
// 文件名: jtag_stub.sv
// 描述: JTAG stub。
//       - 仅保持端口存在，tdo 固定为 0
//======================================================================
module jtag_stub (
  input  logic jtag_tck,
  input  logic jtag_tms,
  input  logic jtag_tdi,
  output logic jtag_tdo
);
  // 标记未使用信号（lint 友好）
  wire _unused = jtag_tck ^ jtag_tms ^ jtag_tdi;
  assign jtag_tdo = 1'b0;
endmodule
