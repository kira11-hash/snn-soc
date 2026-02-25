`timescale 1ns/1ps
//======================================================================
// 文件名: sram_simple_dp.sv
// 描述: 简化双端口 SRAM 模型（1 个总线端口 + 1 个只读 DMA 端口）。
//       - 总线端口：同步写 + 组合读
//       - DMA 端口：只读组合读
//======================================================================
module sram_simple_dp #(
  parameter int MEM_BYTES = 16384  // 例如 16KB
) (
  input  logic        clk,
  input  logic        rst_n,
  // 总线端口
  input  logic        req_valid,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  output logic [31:0] rdata,
  // DMA 只读端口
  input  logic        dma_rd_en,
  input  logic [31:0] dma_rd_addr,
  output logic [31:0] dma_rdata
);
  localparam int WORDS = MEM_BYTES / 4;
  localparam int ADDR_BITS = $clog2(WORDS);

  logic [31:0] mem [0:WORDS-1];

  wire [ADDR_BITS-1:0] bus_word_addr = req_addr[ADDR_BITS+1:2];
  wire [ADDR_BITS-1:0] dma_word_addr = dma_rd_addr[ADDR_BITS+1:2];
  // 标记未使用信号位（lint 友好）
  wire _unused = &{1'b0, rst_n, req_addr, dma_rd_addr};

  // 组合读
  assign rdata    = mem[bus_word_addr];
  assign dma_rdata = dma_rd_en ? mem[dma_word_addr] : 32'h0;

  // 同步写
  always_ff @(posedge clk) begin
    if (req_valid && req_write) begin
      if (req_wstrb[0]) mem[bus_word_addr][7:0]   <= req_wdata[7:0];
      if (req_wstrb[1]) mem[bus_word_addr][15:8]  <= req_wdata[15:8];
      if (req_wstrb[2]) mem[bus_word_addr][23:16] <= req_wdata[23:16];
      if (req_wstrb[3]) mem[bus_word_addr][31:24] <= req_wdata[31:24];
    end
  end
endmodule
