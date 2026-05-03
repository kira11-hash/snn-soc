// -----------------------------------------------------------------------------
// File: tb/sync_2ff_tb.sv
// Purpose: Unit test for rtl/sys/sync_2ff.sv (generic 2-FF metastability
//          synchronizer for async control signals).
//
// Coverage:
//   T1. Reset state: when rst_n_sync=0, dout_sync==0 regardless of din_async.
//   T2. Steady-state propagation: din_async stable high, dout_sync rises
//       exactly 2 clk cycles later.
//   T3. Steady-state low: din_async stable low, dout_sync stays low.
//   T4. Multi-bit (WIDTH=4): each bit independently propagates with the
//       same 2-cycle latency.
//   T5. Async edge mid-cycle: din_async rises in the middle of a clk cycle
//       (no setup violation since this is async input by definition);
//       dout_sync still rises 2 cycles after the next clk edge.
//
// Pass marker: SYNC_2FF_TB_PASS
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module sync_2ff_tb;

  // ── Single-bit instance ─────────────────────────────────────────────
  logic clk = 1'b0;
  logic rst_n_sync = 1'b0;
  logic din_1b = 1'b0;
  logic dout_1b;

  always #5 clk = ~clk;     // 100 MHz

  sync_2ff #(.WIDTH(1)) dut_1b (
    .clk        (clk),
    .rst_n_sync (rst_n_sync),
    .din_async  (din_1b),
    .dout_sync  (dout_1b)
  );

  // ── 4-bit instance ──────────────────────────────────────────────────
  logic [3:0] din_4b = '0;
  logic [3:0] dout_4b;

  sync_2ff #(.WIDTH(4)) dut_4b (
    .clk        (clk),
    .rst_n_sync (rst_n_sync),
    .din_async  (din_4b),
    .dout_sync  (dout_4b)
  );

  int errors = 0;
  int latency;

  task automatic check(input string label, input bit cond);
    begin
      if (!cond) begin
        $display("[FAIL] %s @ time=%0t  dout_1b=%0b dout_4b=%0h",
                 label, $time, dout_1b, dout_4b);
        errors++;
      end else begin
        $display("[OK]   %s @ time=%0t", label, $time);
      end
    end
  endtask

  initial begin
    // T1: reset asserted → both DUTs hold dout at 0 even if din toggles
    rst_n_sync = 1'b0;
    din_1b = 1'b1;
    din_4b = 4'hF;
    repeat (3) @(posedge clk);
    check("T1 reset: dout_1b=0 while rst_n_sync=0", dout_1b === 1'b0);
    check("T1 reset: dout_4b=0 while rst_n_sync=0", dout_4b === 4'h0);

    // Release reset (use the reset_sync module externally in real design;
    // here we just toggle rst_n_sync to model the post-reset_sync output).
    // Use `#1` after each `@(posedge clk)` so non-blocking assignments
    // settle before observing dout — observing in the active region of
    // the same posedge would see pre-NBA values and race the always_ff.
    @(negedge clk);
    rst_n_sync = 1'b1;
    @(posedge clk); #1;    // first cycle: ff1 captures din, ff2 captures old ff1
    @(posedge clk); #1;    // second cycle: ff2 captures din via ff1

    // T2: din_1b was high before release, so after 2 cycles dout_1b=1
    check("T2 propagation: dout_1b=1 after 2 cycles (din_1b held high)",
          dout_1b === 1'b1);
    check("T2 propagation: dout_4b=F after 2 cycles (din_4b held F)",
          dout_4b === 4'hF);

    // T3: drop din_1b/din_4b, count cycles until dout follows
    @(negedge clk);
    din_1b = 1'b0;
    din_4b = 4'h0;
    latency = 0;
    begin
      bit done3 = 1'b0;
      while (!done3) begin
        @(posedge clk); #1;
        latency++;
        if (dout_1b === 1'b0)  done3 = 1'b1;
        if (latency >= 5)      done3 = 1'b1;
      end
    end
    check("T3 falling edge: dout_1b=0 after exactly 2 cycles",
          latency == 2);
    check("T3 falling edge: dout_4b=0 too",
          dout_4b === 4'h0);

    // T4: per-bit independence — set bits 0 and 2 only
    @(negedge clk);
    din_4b = 4'b0101;
    @(posedge clk); #1;
    @(posedge clk); #1;
    check("T4 per-bit: dout_4b == 0101 after 2 cycles",
          dout_4b === 4'b0101);

    // T5: async edge mid-cycle on din_1b
    // Wait for next negedge so we're mid-cycle, then flip din at a
    // non-boundary time
    @(negedge clk);
    din_1b = 1'b0;
    @(posedge clk); #1;
    @(posedge clk); #1;
    check("T5 setup: dout_1b reset to 0 before async edge test",
          dout_1b === 1'b0);
    #3;     // 3 ns after a posedge — middle of next half-cycle
    din_1b = 1'b1;
    // Now din_1b rose mid-cycle. Wait through 2 more posedges; dout
    // should be 1 by then.
    @(posedge clk); #1;
    @(posedge clk); #1;
    check("T5 async-edge propagation: dout_1b=1 within 2 cycles of next posedge",
          dout_1b === 1'b1);

    if (errors == 0) $display("SYNC_2FF_TB_PASS");
    else             $display("SYNC_2FF_TB_FAIL errors=%0d", errors);
    $finish;
  end

  initial begin
    #100000;
    $display("SYNC_2FF_TB_FAIL timeout");
    $finish;
  end

endmodule
