`timescale 1ns/1ps

module cim_program_ctrl_tb;
  import snn_soc_pkg::*;

  logic clk;
  logic rst_n;

  logic        prog_start;
  logic        prog_erase;
  logic        prog_full_array;
  logic [5:0]  prog_row;
  logic [4:0]  prog_col;
  logic [3:0]  prog_level;
  logic [2:0]  prog_retry_limit;
  logic [15:0] prog_pulse_width;
  logic [15:0] prog_erase_width;

  logic        prog_busy;
  logic        prog_done_pulse;
  logic        prog_pass;
  logic        prog_fail;
  logic [2:0]  prog_retry_count;

  logic [NUM_INPUTS-1:0] prog_wl_spike;
  logic        prog_dac_valid;
  logic        prog_cim_start;
  logic        prog_cim_done;
  logic        prog_adc_start;
  logic        prog_adc_done;
  logic [$clog2(MAX_BL_SCAN)-1:0] prog_bl_sel;
  logic [ADC_BITS-1:0] prog_bl_data;
  logic        prog_en;
  logic        erase_en;
  logic        verify_en;

  int pass_count;
  int fail_count;
  int adc_response_val;
  int adc_readback_count;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  cim_program_ctrl dut (
    .clk             (clk),
    .rst_n           (rst_n),
    .prog_start      (prog_start),
    .prog_erase      (prog_erase),
    .prog_full_array (prog_full_array),
    .prog_row        (prog_row),
    .prog_col        (prog_col),
    .prog_level      (prog_level),
    .prog_retry_limit(prog_retry_limit),
    .prog_pulse_width(prog_pulse_width),
    .prog_erase_width(prog_erase_width),
    .prog_busy       (prog_busy),
    .prog_done_pulse (prog_done_pulse),
    .prog_pass       (prog_pass),
    .prog_fail       (prog_fail),
    .prog_retry_count(prog_retry_count),
    .prog_wl_spike   (prog_wl_spike),
    .prog_dac_valid  (prog_dac_valid),
    .prog_cim_start  (prog_cim_start),
    .prog_cim_done   (prog_cim_done),
    .prog_adc_start  (prog_adc_start),
    .prog_adc_done   (prog_adc_done),
    .prog_bl_sel     (prog_bl_sel),
    .prog_bl_data    (prog_bl_data),
    .prog_en         (prog_en),
    .erase_en        (erase_en),
    .verify_en       (verify_en)
  );

  // ADC readback model: respond 1 cycle after prog_adc_start, latch value at start edge
  logic prev_adc_start;
  logic [ADC_BITS-1:0] latched_adc_val;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prog_adc_done    <= 1'b0;
      prog_bl_data     <= '0;
      prev_adc_start   <= 1'b0;
      latched_adc_val  <= '0;
      adc_readback_count <= 0;
    end else begin
      prog_adc_done <= prev_adc_start;
      if (prev_adc_start) begin
        prog_bl_data <= latched_adc_val;
        adc_readback_count <= adc_readback_count + 1;
      end
      if (prog_adc_start)
        latched_adc_val <= ADC_BITS'(adc_response_val);
      prev_adc_start <= prog_adc_start;
    end
  end

  assign prog_cim_done = 1'b0;

  task do_reset;
    begin
      rst_n = 1'b0;
      prog_start = 1'b0;
      prog_erase = 1'b0;
      prog_full_array = 1'b0;
      prog_row = 6'd0;
      prog_col = 5'd0;
      prog_level = 4'd0;
      prog_retry_limit = 3'd0;
      prog_pulse_width = PROG_WRITE_PULSE_1US_CYC[15:0];
      prog_erase_width = 16'd50000;
      adc_response_val = 0;
      adc_readback_count = 0;
      repeat (4) @(posedge clk);
      rst_n = 1'b1;
      repeat (2) @(posedge clk);
    end
  endtask

  task fire_start;
    begin
      prog_start = 1'b1;
      @(posedge clk);
      prog_start = 1'b0;
    end
  endtask

  task wait_done;
    input integer timeout_cycles;
    begin : wd_block
      integer cnt;
      cnt = 0;
      while (!prog_done_pulse && cnt < timeout_cycles) begin
        @(posedge clk);
        cnt = cnt + 1;
      end
      if (cnt >= timeout_cycles) begin
        $display("[FAIL] wait_done timeout after %0d cycles", timeout_cycles);
        $finish;
      end
      @(posedge clk);
    end
  endtask

  // ── Main test sequence ────────────────────────────────────────────
  initial begin
    pass_count = 0;
    fail_count = 0;

    // ── T1: 逐 cell 擦除 ─────────────────────────────────────────
    $display("--- T1: Per-cell erase uses 1ms erase_width ---");
    do_reset;
    prog_erase = 1'b1;
    prog_row   = 6'd3;
    prog_col   = 5'd5;
    prog_retry_limit = 3'd2;
    adc_response_val = 0;
    fire_start;
    wait_done(60000);
    if (!prog_pass || prog_fail) begin
      $display("[FAIL] T1: expected PASS"); fail_count = fail_count + 1;
    end else if (prog_retry_count != 3'd0) begin
      $display("[FAIL] T1: expected retry_count=0, got %0d", prog_retry_count);
      fail_count = fail_count + 1;
    end else begin
      $display("[PASS] T1"); pass_count = pass_count + 1;
    end

    // ── T2: 写入 level=5 ─────────────────────────────────────────
    $display("--- T2: Write level=5, verify pass ---");
    do_reset;
    prog_erase = 1'b0;
    prog_row   = 6'd10;
    prog_col   = 5'd2;
    prog_level = 4'd5;
    prog_retry_limit = 3'd3;
    adc_response_val = 80;  // target = 5*(256/16) = 80
    fire_start;
    wait_done(2000);
    if (!prog_pass || prog_fail) begin
      $display("[FAIL] T2: expected PASS"); fail_count = fail_count + 1;
    end else begin
      $display("[PASS] T2"); pass_count = pass_count + 1;
    end

    // ── T3: 写入 level=0 → 直接 PASS ─────────────────────────────
    $display("--- T3: Write level=0 fast path ---");
    do_reset;
    prog_erase = 1'b0;
    prog_level = 4'd0;
    fire_start;
    wait_done(100);
    if (!prog_pass || prog_fail) begin
      $display("[FAIL] T3: expected PASS"); fail_count = fail_count + 1;
    end else begin
      $display("[PASS] T3"); pass_count = pass_count + 1;
    end

    // ── T4: 擦除验证失败 → 重试 → 成功 ───────────────────────────
    $display("--- T4: Erase with retry ---");
    do_reset;
    prog_erase = 1'b1;
    prog_row   = 6'd7;
    prog_col   = 5'd0;
    prog_retry_limit = 3'd3;
    adc_response_val = 200;  // first: high → fail
    fire_start;
    wait (prog_adc_done);
    @(posedge clk);
    adc_response_val = 0;    // subsequent: low → pass
    wait_done(160000);
    if (!prog_pass || prog_fail) begin
      $display("[FAIL] T4: expected PASS after retry"); fail_count = fail_count + 1;
    end else if (prog_retry_count < 3'd1) begin
      $display("[FAIL] T4: expected at least 1 retry, got %0d", prog_retry_count);
      fail_count = fail_count + 1;
    end else begin
      $display("[PASS] T4 (retries=%0d)", prog_retry_count); pass_count = pass_count + 1;
    end

    // ── T5: 写入脉冲宽度 100us preset ────────────────────────────
    $display("--- T5: Write pulse width=100us (5000 cycles) ---");
    do_reset;
    prog_erase = 1'b0;
    prog_row   = 6'd0;
    prog_col   = 5'd1;
    prog_level = 4'd1;
    prog_pulse_width = PROG_WRITE_PULSE_100US_CYC[15:0];
    prog_retry_limit = 3'd0;
    adc_response_val = 16;
    fire_start;
    wait (prog_dac_valid);
    begin : t5_measure
      integer dac_high_cycles;
      dac_high_cycles = 0;
      while (prog_dac_valid && dac_high_cycles < 6000) begin
        @(posedge clk);
        dac_high_cycles = dac_high_cycles + 1;
      end
      $display("  T5: dac_valid was high for %0d cycles", dac_high_cycles);
      if (dac_high_cycles < PROG_WRITE_PULSE_100US_CYC) begin
        $display("[FAIL] T5: pulse too short"); fail_count = fail_count + 1;
      end
    end
    wait_done(8000);
    if (!prog_pass || prog_fail) begin
      $display("[FAIL] T5: expected PASS"); fail_count = fail_count + 1;
    end else begin
      $display("[PASS] T5"); pass_count = pass_count + 1;
    end

    // ── T6: 全阵列擦除（所有 WL 拉高，跳过 verify）──────────────
    $display("--- T6: Full-array erase ---");
    do_reset;
    prog_erase       = 1'b1;
    prog_full_array   = 1'b1;
    prog_erase_width  = PROG_ERASE_WIDTH_CYC[15:0];
    prog_retry_limit  = 3'd0;
    fire_start;
    wait (prog_dac_valid);
    @(posedge clk);
    if (prog_wl_spike !== {NUM_INPUTS{1'b1}}) begin
      $display("[FAIL] T6: WL not all-ones (got %h)", prog_wl_spike);
      fail_count = fail_count + 1;
    end else if (!erase_en) begin
      $display("[FAIL] T6: erase_en not asserted"); fail_count = fail_count + 1;
    end else begin
      wait_done(60000);
      if (!prog_pass || prog_fail) begin
        $display("[FAIL] T6: expected PASS"); fail_count = fail_count + 1;
      end else begin
        $display("[PASS] T6"); pass_count = pass_count + 1;
      end
    end

    // ── T7: 逐 cell 擦除也必须使用 erase_width，不使用 write pulse ──
    $display("--- T7: Per-cell erase uses 1ms erase_width, not write pulse ---");
    do_reset;
    prog_erase        = 1'b1;
    prog_full_array    = 1'b0;
    prog_row           = 6'd2;
    prog_col           = 5'd2;
    prog_pulse_width   = PROG_WRITE_PULSE_1US_CYC[15:0];
    prog_erase_width   = PROG_ERASE_WIDTH_CYC[15:0];
    adc_response_val   = 0;
    fire_start;
    wait (prog_dac_valid);
    begin : t7_measure
      integer hold_cycles;
      hold_cycles = 0;
      while (prog_dac_valid && hold_cycles < 60000) begin
        @(posedge clk);
        hold_cycles = hold_cycles + 1;
      end
      $display("  T7: per-cell erase dac_valid high for %0d cycles", hold_cycles);
      if (hold_cycles < PROG_ERASE_WIDTH_CYC) begin
        $display("[FAIL] T7: erase pulse too short (%0d)", hold_cycles);
        fail_count = fail_count + 1;
      end
      wait_done(80000);
      if (!prog_pass || prog_fail) begin
        $display("[FAIL] T7: expected PASS"); fail_count = fail_count + 1;
      end else if (hold_cycles >= PROG_ERASE_WIDTH_CYC) begin
        $display("[PASS] T7"); pass_count = pass_count + 1;
      end
    end

    // ── T8: Full-array erase uses 1ms erase_width ───────────────────
    $display("--- T8: Full-array erase uses 1ms erase_width ---");
    do_reset;
    prog_erase        = 1'b1;
    prog_full_array    = 1'b1;
    prog_pulse_width   = PROG_WRITE_PULSE_1US_CYC[15:0];
    prog_erase_width   = PROG_ERASE_WIDTH_CYC[15:0];
    fire_start;
    wait (prog_dac_valid);
    begin : t8_measure
      integer hold_cycles;
      hold_cycles = 0;
      while (prog_dac_valid && hold_cycles < 60000) begin
        @(posedge clk);
        hold_cycles = hold_cycles + 1;
      end
      $display("  T8: full-array erase dac_valid high for %0d cycles", hold_cycles);
      if (hold_cycles < PROG_ERASE_WIDTH_CYC) begin
        $display("[FAIL] T8: erase pulse too short (%0d)", hold_cycles);
        fail_count = fail_count + 1;
      end else begin
        wait_done(80000);
        if (!prog_pass || prog_fail) begin
          $display("[FAIL] T8: expected PASS"); fail_count = fail_count + 1;
        end else begin
          $display("[PASS] T8"); pass_count = pass_count + 1;
        end
      end
    end

    // ── Summary ─────────────────────────────────────────────────────
    $display("");
    $display("=== Results: %0d PASS, %0d FAIL ===", pass_count, fail_count);
    if (fail_count == 0)
      $display("CIM_PROGRAM_CTRL_PASS");
    else
      $display("CIM_PROGRAM_CTRL_FAIL");
    $finish;
  end

  initial begin
    #20000000;
    $display("[FAIL] Global timeout");
    $finish;
  end
endmodule
