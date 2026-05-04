// =============================================================
// File: dc/stubs/cim_macro_blackbox_stub.sv
// Purpose: Black-box stub for rtl/snn/cim_macro_blackbox.sv
//
// cim_macro_blackbox is the digital BEHAVIOURAL MODEL of the
// analog CIM macro. At tape-out, the analog team's CIM macro
// replaces this. For area estimation we want it as 0 area so
// the digital area report excludes the model's synthesized
// contents (which are not real silicon).
//
// Real analog CIM macro die area is provided by the analog team
// (see doc/08_cim_analog_interface.md and doc/15_asic_pad_map.md).
// It is added to the digital area separately for total chip area.
//
// See dc/stubs/sram_simple_stub.sv header for usage notes.
// =============================================================
`timescale 1ns/1ps

module cim_macro_blackbox #(
  parameter int P_NUM_INPUTS       = snn_soc_pkg::NUM_INPUTS,
  parameter int P_ADC_CHANNELS     = snn_soc_pkg::ADC_CHANNELS,
  parameter bit P_USE_BRAM_WEIGHTS = 1'b0
) (
  input  logic clk,
  input  logic rst_n,

  // WL spike inputs (per WL)
  input  logic [P_NUM_INPUTS-1:0] wl_spike,

  // Handshake
  input  logic dac_valid,
  input  logic cim_start,
  output logic cim_done,
  input  logic adc_start,
  output logic adc_done,

  // BL scan + readback
  input  logic [$clog2(P_ADC_CHANNELS)-1:0] bl_sel,
  output logic [snn_soc_pkg::ADC_BITS-1:0]  bl_data,

  // Programming side band (write/erase/verify mode)
  input  logic prog_en,
  input  logic erase_en,
  input  logic verify_en
);
  // Outputs tied to constants — analog macro will drive them in real silicon.
  assign cim_done = 1'b0;
  assign adc_done = 1'b0;
  assign bl_data  = '0;
endmodule
