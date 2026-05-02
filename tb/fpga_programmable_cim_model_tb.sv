`timescale 1ns/1ps
//===========================================================================
// tb/fpga_programmable_cim_model_tb.sv
//
// Unit testbench for cim_fpga_programmable_model.sv (module: cim_macro_blackbox).
//
// T1: After reset, all ADC channels = 0
// T2: Program cell (row=3,col=5) 1 pulse → weight=16, verify via single-row MAC
// T3: Per-cell erase of (row=3,col=5) → weight back to 0
// T4: 4 prog pulses to (row=7,col=2) → weight=64, verify via single-row MAC
// T5: Full-array erase clears all channels
// T6: 10 cells (rows 0..9,col=0) programmed → all-active MAC = 160
// T7a: 15 prog pulses to (row=0,col=0) → weight=240 (max level)
// T7b: 16th pulse does not increase (prog_pulse_acc saturates at 15)
// T8: verify_en is a no-op in the FPGA model
//
// Pass tag: FPGA_PROGRAMMABLE_CIM_MODEL_TB_PASS
//===========================================================================
module fpga_programmable_cim_model_tb;
  import snn_soc_pkg::*;

  // DUT signals
  logic clk;
  logic rst_n;

  logic [NUM_INPUTS-1:0]            wl_spike;
  logic                             dac_valid;
  logic                             cim_start;
  logic                             cim_done;
  logic                             adc_start;
  logic                             adc_done;
  logic [$clog2(ADC_CHANNELS)-1:0]  bl_sel;
  logic [ADC_BITS-1:0]              bl_data;

  logic prog_en;
  logic erase_en;
  logic verify_en;

  // Test counters and temporaries
  int pass_count;
  int fail_count;
  int zeroes;
  int p_idx;
  int r_idx;
  int c_idx;
  logic [ADC_BITS-1:0] r_val;
  logic [ADC_BITS-1:0] r_before;
  logic [ADC_BITS-1:0] r_after;
  logic [NUM_INPUTS-1:0] wl_tmp;

  initial clk = 1'b0;
  always #5 clk = ~clk; // 100 MHz for fast simulation

  // DUT
  cim_macro_blackbox dut (
    .clk        (clk),
    .rst_n      (rst_n),
    .wl_spike   (wl_spike),
    .dac_valid  (dac_valid),
    .cim_start  (cim_start),
    .cim_done   (cim_done),
    .adc_start  (adc_start),
    .adc_done   (adc_done),
    .bl_sel     (bl_sel),
    .bl_data    (bl_data),
    .prog_en    (prog_en),
    .erase_en   (erase_en),
    .verify_en  (verify_en)
  );

  // -------------------------------------------------------------------------
  // Task: latch wl_spike into model
  // -------------------------------------------------------------------------
  task latch_wl(input logic [NUM_INPUTS-1:0] wl);
    begin
      @(negedge clk);
      wl_spike  = wl;
      dac_valid = 1'b1;
      @(posedge clk); #1;
      dac_valid = 1'b0;
      wl_spike  = '0;
    end
  endtask

  // Task: pulse cim_start and wait for cim_done
  task run_cim_wait;
    begin
      @(negedge clk);
      cim_start = 1'b1;
      @(posedge clk); #1;
      cim_start = 1'b0;
      @(posedge cim_done);
      @(posedge clk); #1;
    end
  endtask

  // Task: run ADC sample for column col, output to r_val (module-level)
  task run_adc_col(input int col);
    begin
      @(negedge clk);
      bl_sel    = col[$clog2(ADC_CHANNELS)-1:0];
      adc_start = 1'b1;
      @(posedge clk); #1;
      adc_start = 1'b0;
      @(posedge adc_done);
      @(negedge clk);
      r_val = bl_data;
    end
  endtask

  // Task: program cell (row,col) — one prog_en pulse
  task prog_cell(input int row, input int col);
    begin
      wl_tmp        = '0;
      wl_tmp[row]   = 1'b1;
      latch_wl(wl_tmp);
      @(negedge clk);
      bl_sel  = col[$clog2(ADC_CHANNELS)-1:0];
      prog_en = 1'b1;
      run_cim_wait();
      prog_en = 1'b0;
    end
  endtask

  // Task: erase cell (row,col)
  task erase_cell(input int row, input int col);
    begin
      wl_tmp      = '0;
      wl_tmp[row] = 1'b1;
      latch_wl(wl_tmp);
      @(negedge clk);
      bl_sel   = col[$clog2(ADC_CHANNELS)-1:0];
      erase_en = 1'b1;
      run_cim_wait();
      erase_en = 1'b0;
    end
  endtask

  // Task: full-array erase (wl_latched = all-ones)
  task full_array_erase;
    begin
      latch_wl({NUM_INPUTS{1'b1}});
      @(negedge clk);
      bl_sel   = '0;
      erase_en = 1'b1;
      run_cim_wait();
      erase_en = 1'b0;
    end
  endtask

  // Task: all-active MAC readback for column col → r_val
  task mac_readback(input int col);
    begin
      latch_wl({NUM_INPUTS{1'b1}});
      run_cim_wait();
      run_adc_col(col);
    end
  endtask

  // -------------------------------------------------------------------------
  // Test sequence
  // -------------------------------------------------------------------------
  initial begin
    rst_n      = 1'b0;
    wl_spike   = '0;
    dac_valid  = 1'b0;
    cim_start  = 1'b0;
    adc_start  = 1'b0;
    bl_sel     = '0;
    prog_en    = 1'b0;
    erase_en   = 1'b0;
    verify_en  = 1'b0;
    pass_count = 0;
    fail_count = 0;
    wl_tmp     = '0;
    r_val      = '0;
    r_before   = '0;
    r_after    = '0;
    zeroes     = 0;

    repeat(5) @(posedge clk);
    rst_n = 1'b1;
    repeat(3) @(posedge clk);

    // -------------------------------------------------------
    // T1: Reset — all ADC channels = 0
    // -------------------------------------------------------
    latch_wl({NUM_INPUTS{1'b1}});
    run_cim_wait();
    zeroes = 0;
    for (c_idx = 0; c_idx < ADC_CHANNELS; c_idx++) begin
      run_adc_col(c_idx);
      if (r_val == 8'd0) zeroes++;
    end
    if (zeroes == ADC_CHANNELS) begin
      $display("[PASS] T1 (reset): all %0d ADC channels = 0", ADC_CHANNELS);
      pass_count++;
    end else begin
      $display("[FAIL] T1 (reset): %0d non-zero channels after reset",
               ADC_CHANNELS - zeroes);
      fail_count++;
    end

    // -------------------------------------------------------
    // T2: Program (row=3,col=5) 1 pulse → weight=16
    //     Single-row MAC: wl[3]=1, col=5 → bl_data = 16
    // -------------------------------------------------------
    prog_cell(3, 5);
    wl_tmp    = '0;
    wl_tmp[3] = 1'b1;
    latch_wl(wl_tmp);
    run_cim_wait();
    run_adc_col(5);
    if (r_val == 8'd16) begin
      $display("[PASS] T2 (single-cell 1 pulse): col=5 bl_data=%0d (expected 16)", r_val);
      pass_count++;
    end else begin
      $display("[FAIL] T2 (single-cell 1 pulse): col=5 bl_data=%0d (expected 16)", r_val);
      fail_count++;
    end

    // -------------------------------------------------------
    // T3: Per-cell erase (row=3,col=5) → weight=0
    // -------------------------------------------------------
    erase_cell(3, 5);
    wl_tmp    = '0;
    wl_tmp[3] = 1'b1;
    latch_wl(wl_tmp);
    run_cim_wait();
    run_adc_col(5);
    if (r_val == 8'd0) begin
      $display("[PASS] T3 (per-cell erase): col=5 bl_data=%0d (expected 0)", r_val);
      pass_count++;
    end else begin
      $display("[FAIL] T3 (per-cell erase): col=5 bl_data=%0d (expected 0)", r_val);
      fail_count++;
    end

    // -------------------------------------------------------
    // T4: 4 prog pulses to (row=7,col=2) → weight=64
    // -------------------------------------------------------
    for (p_idx = 0; p_idx < 4; p_idx++) prog_cell(7, 2);
    wl_tmp    = '0;
    wl_tmp[7] = 1'b1;
    latch_wl(wl_tmp);
    run_cim_wait();
    run_adc_col(2);
    if (r_val == 8'd64) begin
      $display("[PASS] T4 (4 prog pulses): col=2 bl_data=%0d (expected 64)", r_val);
      pass_count++;
    end else begin
      $display("[FAIL] T4 (4 prog pulses): col=2 bl_data=%0d (expected 64)", r_val);
      fail_count++;
    end

    // -------------------------------------------------------
    // T5: Full-array erase clears all channels
    // -------------------------------------------------------
    full_array_erase();
    latch_wl({NUM_INPUTS{1'b1}});
    run_cim_wait();
    zeroes = 0;
    for (c_idx = 0; c_idx < ADC_CHANNELS; c_idx++) begin
      run_adc_col(c_idx);
      if (r_val == 8'd0) zeroes++;
    end
    if (zeroes == ADC_CHANNELS) begin
      $display("[PASS] T5 (full-array erase): all %0d channels = 0", ADC_CHANNELS);
      pass_count++;
    end else begin
      $display("[FAIL] T5 (full-array erase): %0d channels non-zero",
               ADC_CHANNELS - zeroes);
      fail_count++;
    end

    // -------------------------------------------------------
    // T6: 10 rows (0..9) × col=0, 1 pulse each
    //     all-active MAC: bl_data[0] = 10 * 16 = 160
    // -------------------------------------------------------
    for (r_idx = 0; r_idx < 10; r_idx++) prog_cell(r_idx, 0);
    mac_readback(0);
    if (r_val == 8'd160) begin
      $display("[PASS] T6 (MAC 10 rows col=0): bl_data=%0d (expected 160)", r_val);
      pass_count++;
    end else begin
      $display("[FAIL] T6 (MAC 10 rows col=0): bl_data=%0d (expected 160)", r_val);
      fail_count++;
    end

    // -------------------------------------------------------
    // T7a: 15 pulses → prog_pulse_acc=15, weight=240
    // -------------------------------------------------------
    full_array_erase();
    for (p_idx = 0; p_idx < 15; p_idx++) prog_cell(0, 0);
    wl_tmp    = '0;
    wl_tmp[0] = 1'b1;
    latch_wl(wl_tmp);
    run_cim_wait();
    run_adc_col(0);
    if (r_val == 8'd240) begin
      $display("[PASS] T7a (15 pulses max): col=0 bl_data=%0d (expected 240)", r_val);
      pass_count++;
    end else begin
      $display("[FAIL] T7a (15 pulses max): col=0 bl_data=%0d (expected 240)", r_val);
      fail_count++;
    end

    // -------------------------------------------------------
    // T7b: 16th pulse should NOT increase (saturates at acc=15)
    // -------------------------------------------------------
    prog_cell(0, 0);
    wl_tmp    = '0;
    wl_tmp[0] = 1'b1;
    latch_wl(wl_tmp);
    run_cim_wait();
    run_adc_col(0);
    if (r_val == 8'd240) begin
      $display("[PASS] T7b (saturate 16th pulse): col=0 bl_data=%0d (still 240)", r_val);
      pass_count++;
    end else begin
      $display("[FAIL] T7b (16th pulse should saturate): col=0 bl_data=%0d (expected 240)", r_val);
      fail_count++;
    end

    // -------------------------------------------------------
    // T8: verify_en is a no-op (weight unchanged)
    // -------------------------------------------------------
    wl_tmp    = '0;
    wl_tmp[0] = 1'b1;
    latch_wl(wl_tmp);
    run_cim_wait();
    run_adc_col(0);
    r_before = r_val;

    // Apply verify_en with cim_start
    latch_wl(wl_tmp);
    @(negedge clk);
    verify_en = 1'b1;
    cim_start = 1'b1;
    @(posedge clk); #1;
    cim_start = 1'b0;
    verify_en = 1'b0;
    @(posedge cim_done);
    @(posedge clk); #1;

    latch_wl(wl_tmp);
    run_cim_wait();
    run_adc_col(0);
    r_after = r_val;

    if (r_before == r_after) begin
      $display("[PASS] T8 (verify_en no-op): weight unchanged at %0d", r_after);
      pass_count++;
    end else begin
      $display("[FAIL] T8 (verify_en changed weight): before=%0d after=%0d",
               r_before, r_after);
      fail_count++;
    end

    // -------------------------------------------------------
    // Summary
    // -------------------------------------------------------
    $display("");
    $display("=================================================");
    $display("[RESULT] %0d/%0d tests passed", pass_count, pass_count + fail_count);
    if (fail_count == 0) begin
      $display("FPGA_PROGRAMMABLE_CIM_MODEL_TB_PASS");
    end else begin
      $display("FPGA_PROGRAMMABLE_CIM_MODEL_TB_FAIL (%0d failures)", fail_count);
    end
    $display("=================================================");
    $finish;
  end

  // Watchdog
  initial begin
    #5_000_000;
    $display("[TIMEOUT] Simulation exceeded 5ms — check for hang");
    $finish;
  end

endmodule
