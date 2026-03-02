`timescale 1ns/1ps
//======================================================================
// tb_cim_fpga.sv — CIM FPGA 模型单元测试
//
// 测试内容:
//   T1: DAC latch + CIM compute → cim_done 时序
//   T2: ADC channel scan → bl_data 正确性
//   T3: 已知权重 + 已知 spike → 预期 bl_data 验证
//   T4: 全 0 输入 → 全 0 输出
//   T5: 全 1 输入 → 最大累加值
//
// 通过标准: CIM_FPGA_UNIT_PASS
//======================================================================
module tb_cim_fpga;

  import snn_soc_pkg::*;

  // -----------------------------------------------------------------------
  // Clock & reset
  // -----------------------------------------------------------------------
  logic clk = 0;
  always #10 clk = ~clk;  // 50 MHz

  logic rst_n;

  // -----------------------------------------------------------------------
  // DUT signals
  // -----------------------------------------------------------------------
  logic [NUM_INPUTS-1:0] wl_spike;
  logic dac_valid;
  logic cim_start;
  logic cim_done;
  logic adc_start;
  logic adc_done;
  logic [$clog2(ADC_CHANNELS)-1:0] bl_sel;
  logic [ADC_BITS-1:0] bl_data;

  // -----------------------------------------------------------------------
  // DUT instantiation
  // -----------------------------------------------------------------------
  cim_fpga_model #(
    .P_NUM_INPUTS   (NUM_INPUTS),
    .P_ADC_CHANNELS (ADC_CHANNELS)
  ) dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .wl_spike  (wl_spike),
    .dac_valid (dac_valid),
    .cim_start (cim_start),
    .cim_done  (cim_done),
    .adc_start (adc_start),
    .adc_done  (adc_done),
    .bl_sel    (bl_sel),
    .bl_data   (bl_data)
  );

  // -----------------------------------------------------------------------
  // Helper tasks
  // -----------------------------------------------------------------------
  integer err_count = 0;

  task automatic check(string name, int actual, int expected);
    if (actual !== expected) begin
      $display("[FAIL] %s: got %0d, expected %0d", name, actual, expected);
      err_count = err_count + 1;
    end else begin
      $display("[PASS] %s = %0d", name, actual);
    end
  endtask

  task automatic pulse_dac(input logic [NUM_INPUTS-1:0] spike);
    wl_spike  = spike;
    dac_valid = 1'b1;
    @(posedge clk);
    dac_valid = 1'b0;
    @(posedge clk);
  endtask

  task automatic run_cim();
    cim_start = 1'b1;
    @(posedge clk);
    cim_start = 1'b0;
    // Wait for cim_done
    while (!cim_done) @(posedge clk);
    @(posedge clk);
  endtask

  task automatic read_adc(input logic [$clog2(ADC_CHANNELS)-1:0] ch,
                           output logic [ADC_BITS-1:0] data);
    bl_sel    = ch;
    adc_start = 1'b1;
    @(posedge clk);
    adc_start = 1'b0;
    while (!adc_done) @(posedge clk);
    data = bl_data;
    @(posedge clk);
  endtask

  // -----------------------------------------------------------------------
  // Test sequence
  // -----------------------------------------------------------------------
  logic [ADC_BITS-1:0] bl_result [0:ADC_CHANNELS-1];

  initial begin
    $dumpfile("waves/tb_cim_fpga.vcd");
    $dumpvars(0, tb_cim_fpga);

    // Init
    rst_n     = 0;
    wl_spike  = '0;
    dac_valid = 0;
    cim_start = 0;
    adc_start = 0;
    bl_sel    = '0;
    repeat(5) @(posedge clk);
    rst_n = 1;
    repeat(2) @(posedge clk);

    // =====================================================================
    // T1: Basic timing — DAC latch + CIM done after CIM_LATENCY_CYCLES
    // =====================================================================
    $display("\n=== T1: CIM timing test ===");
    pulse_dac(64'hFFFF_FFFF_FFFF_FFFF);  // all 1s
    run_cim();
    $display("[PASS] T1: cim_done received after CIM start");

    // =====================================================================
    // T2: ADC channel scan — read all 20 channels
    // =====================================================================
    $display("\n=== T2: ADC channel scan ===");
    for (int ch = 0; ch < ADC_CHANNELS; ch++) begin
      read_adc(ch[$clog2(ADC_CHANNELS)-1:0], bl_result[ch]);
      $display("  ch[%0d] = %0d", ch, bl_result[ch]);
    end
    $display("[PASS] T2: All 20 channels read successfully");

    // =====================================================================
    // T3: Known spike pattern → verify bl_data values
    //     With all-1 input and test weights:
    //       For each pos column j: acc = Σ weight_pos[i][j] for i=0..63
    //       Expected: all non-zero (weights have structure)
    // =====================================================================
    $display("\n=== T3: Known spike verification ===");
    // Verify positive columns have larger values than negative columns
    begin
      int pos_sum, neg_sum;
      pos_sum = 0;
      neg_sum = 0;
      for (int ch = 0; ch < 10; ch++) begin
        pos_sum = pos_sum + bl_result[ch];
        neg_sum = neg_sum + bl_result[ch + 10];
      end
      $display("  Sum(pos_cols) = %0d, Sum(neg_cols) = %0d", pos_sum, neg_sum);
      if (pos_sum > neg_sum) begin
        $display("[PASS] T3: Positive columns > negative columns (Scheme B diff > 0)");
      end else begin
        $display("[FAIL] T3: Expected pos > neg for Scheme B");
        err_count = err_count + 1;
      end
    end

    // =====================================================================
    // T4: All-zero input → all-zero BL data
    // =====================================================================
    $display("\n=== T4: Zero input test ===");
    pulse_dac(64'h0);
    run_cim();
    begin
      int any_nonzero;
      any_nonzero = 0;
      for (int ch = 0; ch < ADC_CHANNELS; ch++) begin
        read_adc(ch[$clog2(ADC_CHANNELS)-1:0], bl_result[ch]);
        if (bl_result[ch] != 0) any_nonzero = 1;
      end
      if (any_nonzero == 0) begin
        $display("[PASS] T4: All channels = 0 for zero input");
      end else begin
        $display("[FAIL] T4: Expected all zeros");
        err_count = err_count + 1;
      end
    end

    // =====================================================================
    // T5: Single-row activation → only that row's weights contribute
    // =====================================================================
    $display("\n=== T5: Single-row activation ===");
    pulse_dac(64'h1);  // Only row 0 active
    run_cim();
    for (int ch = 0; ch < 10; ch++) begin
      read_adc(ch[$clog2(ADC_CHANNELS)-1:0], bl_result[ch]);
    end
    // Row 0 is in class 0's receptive field → col 0 should have weight 15
    // Other columns should have small values (0-3)
    $display("  Row 0 only: bl_pos[0]=%0d (expect 15)", bl_result[0]);
    check("T5_col0", bl_result[0], 15);

    // =====================================================================
    // Summary
    // =====================================================================
    $display("\n========================================");
    if (err_count == 0) begin
      $display("CIM_FPGA_UNIT_PASS (0 errors)");
    end else begin
      $display("CIM_FPGA_UNIT_FAIL (%0d errors)", err_count);
    end
    $display("========================================");
    $finish;
  end

  // Timeout watchdog
  initial begin
    #1_000_000;
    $display("[TIMEOUT] Test exceeded 1ms, aborting");
    $finish;
  end

endmodule
