// =============================================================
// File: dc/stubs/sram_simple_stub.sv
// Purpose: Black-box stub for rtl/mem/sram_simple.sv
//
// Used by dc/flist_blackbox.f when OPT_SRAM_BLACKBOX=1 in set_env.tcl.
// DC sees this empty module instead of the synthesizable behavioural
// model, so the cell occupies 0 area in the synthesis report. Real
// SRAM macro area is added back manually in the closure summary using
// SRAM compiler density × bit count (per-instance MEM_BYTES).
//
// Port list MUST match rtl/mem/sram_simple.sv byte-exact (DC links
// by port name + width). When the upstream module changes ports,
// this stub MUST be updated in lockstep — see CLAUDE.md "RTL 漏洞
// 报告规范" + dc/README.md §area-fixing-overestimate.
// =============================================================
`timescale 1ns/1ps

module sram_simple #(
  parameter int          MEM_BYTES = 16384,
  parameter              INIT_FILE = ""
) (
  input  logic        clk,
  input  logic        rst_n,

  // CPU bus port
  input  logic        req_valid,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  output logic [31:0] rdata,

  // DMA write port
  input  logic        dma_wr_en,
  input  logic [31:0] dma_wr_addr,
  input  logic [31:0] dma_wr_data,
  input  logic [3:0]  dma_wr_strb
);
  // Black-box: outputs tied to 0 so DC infers tie cells (or constant
  // propagation if dont_touch is also applied). Real SRAM macro will
  // be linked at P&R via the foundry SRAM compiler.
  assign rdata = 32'h0;
endmodule
