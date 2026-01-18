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
  assign jtag_tdo = 1'b0;
endmodule
