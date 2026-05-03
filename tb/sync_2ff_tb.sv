// -----------------------------------------------------------------------------
// File: tb/sync_2ff_tb.sv
// Purpose: Unit test for rtl/sys/sync_2ff.sv (generic 2-FF metastability
//          synchronizer for async control signals).
//
// Coverage:
//   T1. Reset clears 1/4/8/16-bit instances regardless of din_async.
//   T2. Stable values propagate after exactly 2 cycles for WIDTH=1/4/8/16.
//   T3. Outputs still hold the old value after 1 cycle, then update on cycle 2.
//   T4. Mid-cycle async transitions still emerge 2 clocks later.
//   T5. X on din_async propagates through the 2-FF pipe after 2 clocks, then
//       clears again after 2 clocks once the input is driven back to 0.
//   T6. Reset re-assertion clears all outputs immediately even from an X state.
//
// Pass marker: SYNC_2FF_TB_PASS
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module sync_2ff_tb;

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

  logic [3:0] din_4b = '0;
  logic [3:0] dout_4b;

  sync_2ff #(.WIDTH(4)) dut_4b (
    .clk        (clk),
    .rst_n_sync (rst_n_sync),
    .din_async  (din_4b),
    .dout_sync  (dout_4b)
  );

  logic [7:0] din_8b = '0;
  logic [7:0] dout_8b;

  sync_2ff #(.WIDTH(8)) dut_8b (
    .clk        (clk),
    .rst_n_sync (rst_n_sync),
    .din_async  (din_8b),
    .dout_sync  (dout_8b)
  );

  logic [15:0] din_16b = '0;
  logic [15:0] dout_16b;

  sync_2ff #(.WIDTH(16)) dut_16b (
    .clk        (clk),
    .rst_n_sync (rst_n_sync),
    .din_async  (din_16b),
    .dout_sync  (dout_16b)
  );

  int errors = 0;

  task automatic check(input string label, input bit cond);
    begin
      if (!cond) begin
        $display("[FAIL] %s @ time=%0t  d1=%0b d4=%0h d8=%0h d16=%0h",
                 label, $time, dout_1b, dout_4b, dout_8b, dout_16b);
        errors++;
      end else begin
        $display("[OK]   %s @ time=%0t", label, $time);
      end
    end
  endtask

  task automatic wait_two_cycles;
    begin
      @(posedge clk); #1;
      @(posedge clk); #1;
    end
  endtask

  initial begin
    // T1: reset asserted -> every DUT must hold zero regardless of input activity.
    rst_n_sync = 1'b0;
    din_1b = 1'b1;
    din_4b = 4'hF;
    din_8b = 8'hA5;
    din_16b = 16'hCAFE;
    repeat (3) @(posedge clk); #1;
    check("T1 reset: dout_1b=0 while rst_n_sync=0", dout_1b === 1'b0);
    check("T1 reset: dout_4b=0 while rst_n_sync=0", dout_4b === 4'h0);
    check("T1 reset: dout_8b=0 while rst_n_sync=0", dout_8b === 8'h00);
    check("T1 reset: dout_16b=0 while rst_n_sync=0", dout_16b === 16'h0000);

    // T2: after release, stable inputs appear exactly 2 clocks later.
    @(negedge clk);
    rst_n_sync = 1'b1;
    wait_two_cycles();
    check("T2 propagation: dout_1b=1 after 2 cycles (din_1b held high)",
          dout_1b === 1'b1);
    check("T2 propagation: dout_4b=F after 2 cycles (din_4b held F)",
          dout_4b === 4'hF);
    check("T2 propagation: dout_8b=A5 after 2 cycles", dout_8b === 8'hA5);
    check("T2 propagation: dout_16b=CAFE after 2 cycles", dout_16b === 16'hCAFE);

    // T3: outputs must still show the old value after 1 cycle and update on cycle 2.
    @(negedge clk);
    din_1b = 1'b0;
    din_4b = 4'b0101;
    din_8b = 8'h3C;
    din_16b = 16'h1234;
    @(posedge clk); #1;
    check("T3 after 1 cycle: dout_1b still old", dout_1b === 1'b1);
    check("T3 after 1 cycle: dout_4b still old", dout_4b === 4'hF);
    check("T3 after 1 cycle: dout_8b still old", dout_8b === 8'hA5);
    check("T3 after 1 cycle: dout_16b still old", dout_16b === 16'hCAFE);
    @(posedge clk); #1;
    check("T3 after 2 cycles: dout_1b updated", dout_1b === 1'b0);
    check("T3 after 2 cycles: dout_4b updated", dout_4b === 4'b0101);
    check("T3 after 2 cycles: dout_8b updated", dout_8b === 8'h3C);
    check("T3 after 2 cycles: dout_16b updated", dout_16b === 16'h1234);

    // T4: mid-cycle async edge still takes 2 clocks from the next sampling edge.
    @(negedge clk);
    din_1b = 1'b0;
    wait_two_cycles();
    check("T4 setup: dout_1b back to 0", dout_1b === 1'b0);
    #3;
    din_1b = 1'b1;
    @(posedge clk); #1;
    check("T4 async edge: still old after 1 cycle", dout_1b === 1'b0);
    @(posedge clk); #1;
    check("T4 async edge: updated after 2 cycles", dout_1b === 1'b1);

    // T5: X-prop should traverse the pipe after 2 clocks, then clear again after 2 clocks.
    @(negedge clk);
    din_1b = 1'bx;
    din_4b = 4'hx;
    din_8b = 8'hxx;
    din_16b = 16'hxxxx;
    @(posedge clk); #1;
    check("T5 X-prop: cycle 1 still shows previous value", dout_1b === 1'b1);
    @(posedge clk); #1;
    check("T5 X-prop: 1b becomes X after 2 cycles", dout_1b === 1'bx);
    check("T5 X-prop: 4b becomes X after 2 cycles", dout_4b === 4'hx);
    check("T5 X-prop: 8b becomes X after 2 cycles", dout_8b === 8'hxx);
    check("T5 X-prop: 16b becomes X after 2 cycles", dout_16b === 16'hxxxx);

    @(negedge clk);
    din_1b = 1'b0;
    din_4b = 4'h0;
    din_8b = 8'h00;
    din_16b = 16'h0000;
    wait_two_cycles();
    check("T5 clear after X: 1b returns to 0", dout_1b === 1'b0);
    check("T5 clear after X: 4b returns to 0", dout_4b === 4'h0);
    check("T5 clear after X: 8b returns to 0", dout_8b === 8'h00);
    check("T5 clear after X: 16b returns to 0", dout_16b === 16'h0000);

    // T6: async reset must clear the synchronizer immediately even from an X state.
    @(negedge clk);
    din_1b = 1'b1;
    din_4b = 4'hA;
    din_8b = 8'h5A;
    din_16b = 16'h55AA;
    wait_two_cycles();
    check("T6 setup: known values present before reset", dout_16b === 16'h55AA);
    @(negedge clk);
    din_1b = 1'bx;
    din_4b = 4'hx;
    din_8b = 8'hxx;
    din_16b = 16'hxxxx;
    rst_n_sync = 1'b0;
    #1;
    check("T6 reset dominates X on 1b", dout_1b === 1'b0);
    check("T6 reset dominates X on 4b", dout_4b === 4'h0);
    check("T6 reset dominates X on 8b", dout_8b === 8'h00);
    check("T6 reset dominates X on 16b", dout_16b === 16'h0000);

    @(negedge clk);
    rst_n_sync = 1'b1;
    din_1b = 1'b1;
    din_4b = 4'b0101;
    din_8b = 8'hA5;
    din_16b = 16'h0F0F;
    wait_two_cycles();
    check("T6 post-reset recovery: dout_4b == 0101 after 2 cycles",
          dout_4b === 4'b0101);
    check("T6 post-reset recovery: dout_8b == A5 after 2 cycles", dout_8b === 8'hA5);
    check("T6 post-reset recovery: dout_16b == 0F0F after 2 cycles", dout_16b === 16'h0F0F);

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
