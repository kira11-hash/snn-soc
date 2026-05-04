// =============================================================
// File: dc/stubs/boot_rom_stub.sv
// Purpose: Black-box stub for rtl/mem/boot_rom.sv
//
// boot_rom is a synthesizable behavioural mask ROM placeholder
// (filled via $readmemh in sim, replaced by foundry mask ROM
// compiler at tape-out). For area estimation we want it as
// black-box so the digital area report doesn't include FF-array
// over-estimate of ROM contents.
//
// See dc/stubs/sram_simple_stub.sv header for usage notes.
// =============================================================
`timescale 1ns/1ps

module boot_rom #(
  parameter int unsigned SIZE_BYTES = 4096,
  parameter              INIT_FILE  = ""
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        req_valid,
  input  logic        req_write,    // ignored (ROM is read-only)
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,    // unused
  input  logic [3:0]  req_wstrb,    // unused
  output logic [31:0] rdata
);
  assign rdata = 32'h0;
endmodule
