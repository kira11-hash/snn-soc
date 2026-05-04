// =============================================================
// File: dc/stubs/sram_simple_dp_stub.sv
// Purpose: Black-box stub for rtl/mem/sram_simple_dp.sv
// (dual-port: CPU 32-bit RW + DMA 32-bit RD-only zero-latency)
//
// See dc/stubs/sram_simple_stub.sv header for usage notes.
// =============================================================
`timescale 1ns/1ps

module sram_simple_dp #(
  parameter int MEM_BYTES = 16384
) (
  input  logic        clk,
  input  logic        rst_n,

  // CPU bus port (R/W)
  input  logic        req_valid,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  output logic [31:0] rdata,

  // DMA read port (zero-latency read-only)
  input  logic        dma_rd_en,
  input  logic [31:0] dma_rd_addr,
  output logic [31:0] dma_rdata
);
  assign rdata     = 32'h0;
  assign dma_rdata = 32'h0;
endmodule
