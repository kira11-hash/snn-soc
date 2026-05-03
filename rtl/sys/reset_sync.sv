// -----------------------------------------------------------------------------
// File: rtl/sys/reset_sync.sv
// Purpose: Async-assert / sync-release reset synchronizer.
//
// Why this exists:
//   Pure async reset (used pre-2026-05-03 throughout the SoC: every
//   `always_ff @(posedge clk or negedge rst_n)` directly took the
//   pad-level rst_n) is unsafe at deassertion: if the rst_n rising edge
//   violates a flop's recovery / removal timing window, the flop can
//   enter a metastable state and resolve to an arbitrary value, putting
//   the design into an unknown post-reset state.
//
//   The standard fix is "async-assert / sync-release":
//     - assertion (rst_n falling) is async — guarantees all flops reset
//       immediately even before clk is stable;
//     - release (rst_n rising) propagates through 2-FF chain on clk so
//       all downstream flops see the deassertion edge with proper
//       setup/hold to clk.
//
// This module is the canonical synchronizer that should sit between the
// pad-level rst_n and the SoC core. After this module, every downstream
// always_ff uses the synced reset and the deassertion edge is clean.
//
// Hierarchy on this SoC:
//   chip_top.rst_n_pad  →  reset_sync  →  rst_n_sync  →  snn_soc_top.rst_n
//                                                      →  sync_2ff.rst_n_sync
//                                                      →  ...
//
// Implementation notes:
//   - STAGES default 2 is the textbook minimum. STAGES=3 buys more
//     metastability margin at the cost of one extra reset-release cycle.
//   - (* async_reg = "TRUE" *) helps Vivado place the chain adjacent and
//     avoid optimization. Harmless for ASIC tools that ignore it.
//   - At reset assertion, all chain stages clear to 0 instantly (async).
//   - At reset release, a logic 1 walks through the chain on each clk
//     edge; the output deasserts STAGES cycles after rst_n_async rises.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module reset_sync #(
  parameter int STAGES = 2
) (
  input  logic clk,
  input  logic rst_n_async,    // raw async reset from pad / external source
  output logic rst_n_sync       // async-assert, sync-release reset for clk domain
);

  (* async_reg = "TRUE" *) logic [STAGES-1:0] sync_chain;

`ifndef SYNTHESIS
  initial begin
    if (STAGES < 1) begin
      $fatal(1, "[reset_sync] STAGES must be >= 1");
    end
  end
`endif

  always_ff @(posedge clk or negedge rst_n_async) begin
    if (!rst_n_async) begin
      sync_chain <= '0;                                        // async assert
    end else if (STAGES == 1) begin
      sync_chain[0] <= 1'b1;                                   // STAGES=1 has no shift tail
    end else begin
      sync_chain <= {sync_chain[STAGES-2:0], 1'b1};            // sync release: walk a 1 in
    end
  end

  assign rst_n_sync = sync_chain[STAGES-1];

endmodule
