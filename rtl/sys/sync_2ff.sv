// -----------------------------------------------------------------------------
// File: rtl/sys/sync_2ff.sv
// Purpose: Generic 2-FF metastability synchronizer for single-bit (or
//          parametric WIDTH bit) async control signals crossing into the
//          local clock domain.
//
// Use cases on this SoC:
//   - cim_done_ext: completion strobe coming from the analog CIM macro;
//     analog timing is asynchronous to the digital clk, so the strobe must
//     be 2-FF synced before any clk-domain FSM consumes it.
//   - any future single-bit async input (button, GPIO interrupt, etc.).
//
// NOT for:
//   - multi-bit data buses (use Gray code or handshake instead — bit-wise
//     2-FF on a bus risks per-bit cycle skew → corrupted word).
//   - reset signals (use reset_sync.sv: that flavor needs async-assert
//     semantics, this one assumes async data with synchronous reset).
//
// Implementation notes:
//   - Uses async-assert / sync-release reset (rst_n_sync feeding this
//     module must already be the reset_sync output, not the raw pad
//     reset, otherwise the metastability fix is partial).
//   - (* async_reg = "TRUE" *) helps Vivado place the 2 flops adjacent
//     and avoid optimization. The attribute is harmless for ASIC tools
//     that ignore it.
//   - Reset clears both flops to zero; on a deassertion edge the input
//     value propagates after exactly 2 clk cycles.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module sync_2ff #(
  parameter int WIDTH = 1
) (
  input  logic                 clk,
  input  logic                 rst_n_sync,   // already-synced reset (output of reset_sync)
  input  logic [WIDTH-1:0]     din_async,    // async input from off-chip / other clk domain
  output logic [WIDTH-1:0]     dout_sync     // 2-cycle delayed, metastability-resolved
);

  (* async_reg = "TRUE" *) logic [WIDTH-1:0] sync_ff1;
  (* async_reg = "TRUE" *) logic [WIDTH-1:0] sync_ff2;

  always_ff @(posedge clk or negedge rst_n_sync) begin
    if (!rst_n_sync) begin
      sync_ff1 <= '0;
      sync_ff2 <= '0;
    end else begin
      sync_ff1 <= din_async;
      sync_ff2 <= sync_ff1;
    end
  end

  assign dout_sync = sync_ff2;

endmodule
