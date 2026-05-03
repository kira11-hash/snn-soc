// -----------------------------------------------------------------------------
// File: tb/reset_sync_tb.sv
// Purpose: Unit test for rtl/sys/reset_sync.sv
//
// Coverage:
//   T1. Async assert: when rst_n_async drops mid-cycle, rst_n_sync must
//       fall in the same simulation timestep (async path).
//   T2. Sync release: when rst_n_async rises, rst_n_sync must stay low
//       for STAGES clk cycles, then rise on the STAGES+1-th rising edge.
//   T3. Glitch immunity: if rst_n_async pulses low for less than 1 clk
//       cycle, downstream rst_n_sync still drops (async assert sees it).
//   T4. Repeated resets: assert/release cycle multiple times, verify
//       STAGES-cycle release latency every time.
//
// Pass marker: RESET_SYNC_TB_PASS
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module reset_sync_tb;

  localparam int STAGES = 2;

  logic clk = 1'b0;
  logic rst_n_async = 1'b1;
  logic rst_n_sync;

  // 100 MHz clk → 10 ns period
  always #5 clk = ~clk;

  reset_sync #(.STAGES(STAGES)) dut (
    .clk         (clk),
    .rst_n_async (rst_n_async),
    .rst_n_sync  (rst_n_sync)
  );

  int errors = 0;
  int t_release_latency;
  bit done4;     // T4 loop-exit flag (declared at module scope to ensure fresh init each iter)

  task automatic check(input string label, input bit cond);
    begin
      if (!cond) begin
        $display("[FAIL] %s @ time=%0t  rst_n_sync=%0b", label, $time, rst_n_sync);
        errors++;
      end else begin
        $display("[OK]   %s @ time=%0t", label, $time);
      end
    end
  endtask

  initial begin
    // Initial state: rst_n_async high, but flops uninitialised.
    // First assert reset to bring chain to known 0.
    rst_n_async = 1'b0;
    #2;  // T1: assert async — rst_n_sync should drop within this delta cycle
    check("T1 async-assert: rst_n_sync drops with rst_n_async",
          rst_n_sync === 1'b0);

    // Hold reset for several clks
    repeat (5) @(posedge clk);
    check("T1 hold: rst_n_sync stays low while rst_n_async low",
          rst_n_sync === 1'b0);

    // T2: release reset on a clean clk edge, count cycles until rst_n_sync rises
    // Use #1 after @(posedge clk) to let NBA apply before observing.
    @(negedge clk);     // align release to mid-cycle so rst is valid for next posedge
    rst_n_async = 1'b1;
    t_release_latency = 0;
    begin
      bit done = 1'b0;
      while (!done) begin
        @(posedge clk); #1;
        t_release_latency++;
        if (rst_n_sync === 1'b1)  done = 1'b1;
        if (t_release_latency >= 10) done = 1'b1;
      end
    end
    check($sformatf("T2 sync-release latency = STAGES (%0d cycles)", STAGES),
          t_release_latency == STAGES);

    // T3: glitch test — drop rst_n_async for sub-cycle pulse
    repeat (3) @(posedge clk);
    rst_n_async = 1'b0;
    #1;     // 1 ns pulse, much shorter than 10 ns clk period
    check("T3 glitch async-assert: rst_n_sync drops on sub-cycle pulse",
          rst_n_sync === 1'b0);
    rst_n_async = 1'b1;
    // After glitch release, sync chain must walk 1 back through STAGES clks
    t_release_latency = 0;
    begin
      bit done3 = 1'b0;
      while (!done3) begin
        @(posedge clk); #1;
        t_release_latency++;
        if (rst_n_sync === 1'b1)     done3 = 1'b1;
        if (t_release_latency >= 10) done3 = 1'b1;
      end
    end
    check($sformatf("T3 post-glitch sync-release latency = STAGES (%0d)", STAGES),
          t_release_latency == STAGES);

    // T4: repeated cycles
    for (int i = 0; i < 3; i++) begin
      @(negedge clk);
      rst_n_async = 1'b0;
      repeat (3) @(posedge clk);
      check($sformatf("T4 iter %0d: rst_n_sync low while reset asserted", i),
            rst_n_sync === 1'b0);
      @(negedge clk);
      rst_n_async = 1'b1;
      t_release_latency = 0;
      done4 = 1'b0;
      while (!done4) begin
        @(posedge clk); #1;
        t_release_latency++;
        if (rst_n_sync === 1'b1)     done4 = 1'b1;
        if (t_release_latency >= 10) done4 = 1'b1;
      end
      check($sformatf("T4 iter %0d: release latency = STAGES (%0d)", i, STAGES),
            t_release_latency == STAGES);
    end

    if (errors == 0) $display("RESET_SYNC_TB_PASS");
    else             $display("RESET_SYNC_TB_FAIL errors=%0d", errors);
    $finish;
  end

  initial begin
    #100000;
    $display("RESET_SYNC_TB_FAIL timeout");
    $finish;
  end

endmodule
