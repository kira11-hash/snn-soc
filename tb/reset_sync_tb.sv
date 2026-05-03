// -----------------------------------------------------------------------------
// File: tb/reset_sync_tb.sv
// Purpose: Unit test for rtl/sys/reset_sync.sv
//
// Coverage:
//   T1. Async assert clears every DUT instance immediately.
//   T2. Sync release latency matches STAGES for STAGES=1/2/3.
//   T3. Sub-cycle reset pulse still asynchronously asserts and then
//       re-releases with the expected latency.
//   T4. Repeated reset cycles keep the latency contract intact.
//   T5. Near-edge reset release (1 ns before posedge) still deasserts on
//       the expected synchronized cycle.
//
// Pass marker: RESET_SYNC_TB_PASS
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module reset_sync_tb;

  localparam int STAGES_1 = 1;
  localparam int STAGES_2 = 2;
  localparam int STAGES_3 = 3;

  logic clk = 1'b0;
  logic rst_n_async = 1'b1;
  logic rst_n_sync_1;
  logic rst_n_sync_2;
  logic rst_n_sync_3;

  // 100 MHz clk → 10 ns period
  always #5 clk = ~clk;

  reset_sync #(.STAGES(STAGES_1)) dut_stages_1 (
    .clk         (clk),
    .rst_n_async (rst_n_async),
    .rst_n_sync  (rst_n_sync_1)
  );

  reset_sync #(.STAGES(STAGES_2)) dut_stages_2 (
    .clk         (clk),
    .rst_n_async (rst_n_async),
    .rst_n_sync  (rst_n_sync_2)
  );

  reset_sync #(.STAGES(STAGES_3)) dut_stages_3 (
    .clk         (clk),
    .rst_n_async (rst_n_async),
    .rst_n_sync  (rst_n_sync_3)
  );

  int errors = 0;

  task automatic check(input string label, input bit cond);
    begin
      if (!cond) begin
        $display("[FAIL] %s @ time=%0t  s1=%0b s2=%0b s3=%0b",
                 label, $time, rst_n_sync_1, rst_n_sync_2, rst_n_sync_3);
        errors++;
      end else begin
        $display("[OK]   %s @ time=%0t", label, $time);
      end
    end
  endtask

  task automatic check_all_low(input string label);
    begin
      check({label, " (STAGES=1)"}, rst_n_sync_1 === 1'b0);
      check({label, " (STAGES=2)"}, rst_n_sync_2 === 1'b0);
      check({label, " (STAGES=3)"}, rst_n_sync_3 === 1'b0);
    end
  endtask

  task automatic check_release_latencies(input string label);
    int cycle;
    int lat_1;
    int lat_2;
    int lat_3;
    begin
      lat_1 = -1;
      lat_2 = -1;
      lat_3 = -1;
      for (cycle = 1; cycle <= 8; cycle++) begin
        @(posedge clk); #1;
        if ((lat_1 < 0) && (rst_n_sync_1 === 1'b1)) lat_1 = cycle;
        if ((lat_2 < 0) && (rst_n_sync_2 === 1'b1)) lat_2 = cycle;
        if ((lat_3 < 0) && (rst_n_sync_3 === 1'b1)) lat_3 = cycle;
      end
      check($sformatf("%s latency STAGES=1 == 1", label), lat_1 == STAGES_1);
      check($sformatf("%s latency STAGES=2 == 2", label), lat_2 == STAGES_2);
      check($sformatf("%s latency STAGES=3 == 3", label), lat_3 == STAGES_3);
    end
  endtask

  initial begin
    // Initial state: assert reset first so every DUT starts from a known zeroed chain.
    rst_n_async = 1'b0;
    #1;
    check_all_low("T1 async-assert clears outputs");

    repeat (4) @(posedge clk); #1;
    check_all_low("T1 hold keeps outputs low");

    // T2: release from mid-cycle and verify stage-dependent latency.
    @(negedge clk);
    rst_n_async = 1'b1;
    check_release_latencies("T2 mid-cycle release");

    // T3: sub-cycle glitch must still assert asynchronously and re-release cleanly.
    repeat (2) @(posedge clk);
    rst_n_async = 1'b0;
    #1;
    check_all_low("T3 sub-cycle pulse asserts reset");
    rst_n_async = 1'b1;
    check_release_latencies("T3 post-glitch release");

    // T4: repeat the whole sequence several times to catch stale-state issues.
    for (int i = 0; i < 2; i++) begin
      @(negedge clk);
      rst_n_async = 1'b0;
      #1;
      check_all_low($sformatf("T4 iter %0d async-assert", i));
      repeat (2) @(posedge clk); #1;
      check_all_low($sformatf("T4 iter %0d hold", i));
      @(negedge clk);
      rst_n_async = 1'b1;
      check_release_latencies($sformatf("T4 iter %0d release", i));
    end

    // T5: release 1 ns before a posedge to approximate a recovery/removal corner.
    @(negedge clk);
    rst_n_async = 1'b0;
    #1;
    check_all_low("T5 near-edge assert");
    @(negedge clk);
    #4;
    rst_n_async = 1'b1;
    check_release_latencies("T5 near-edge release");

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
