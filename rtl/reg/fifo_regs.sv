//======================================================================
// 文件名: fifo_regs.sv
// 描述: FIFO 状态寄存器窗口（地址基址：0x4000_0400）。
//       提供 input_fifo / output_fifo 的计数与空满状态。
//======================================================================
module fifo_regs (
  input  logic        req_valid,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  output logic [31:0] rdata,

  input  logic [$clog2(512+1)-1:0] in_fifo_count,
  input  logic [$clog2(256+1)-1:0] out_fifo_count,
  input  logic in_fifo_empty,
  input  logic in_fifo_full,
  input  logic out_fifo_empty,
  input  logic out_fifo_full
);
  // offset 定义
  localparam logic [7:0] REG_IN_COUNT  = 8'h00;
  localparam logic [7:0] REG_OUT_COUNT = 8'h04;
  localparam logic [7:0] REG_STATUS    = 8'h08;

  wire [7:0] addr_offset = req_addr[7:0];

  // 只读寄存器，写入忽略
  always_comb begin
    rdata = 32'h0;
    case (addr_offset)
      REG_IN_COUNT:  rdata = {16'h0, in_fifo_count};
      REG_OUT_COUNT: rdata = {16'h0, out_fifo_count};
      REG_STATUS: begin
        rdata[0] = in_fifo_empty;
        rdata[1] = in_fifo_full;
        rdata[2] = out_fifo_empty;
        rdata[3] = out_fifo_full;
      end
      default: rdata = 32'h0;
    endcase
  end
endmodule
