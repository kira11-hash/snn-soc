`timescale 1ns/1ps
//======================================================================
// prog_pulse_cfg_tb
//
// 【测试范围】
// 验证 REG_PROG_PULSE_WIDTH (0x90) 的四档写入脉宽 preset：
//   sel=0 → 1us   (50 cycles @ 50MHz)
//   sel=1 → 10us  (500 cycles)
//   sel=2 → 100us (5000 cycles)
//   sel=3 → 保留（硬件按 100us 处理，防止误写 1ms SET 脉冲烧伤器件）
// 以及 REG_PROG_ERASE_WIDTH (0x94) 写入被忽略，始终保持 50000 cycles (1ms)。
//
// 【2026-04-22 main 分支移植说明】
// 从 v2 分支 tb/prog_pulse_cfg_tb.sv 移植过来。main 版 reg_bank 不含 V2.B 多层
// 寄存器，因此本 TB 去掉了 ml_* 端口连接（相比 v2 版去除了 37~42 + 94~99 行）。
//======================================================================
module prog_pulse_cfg_tb;
  import snn_soc_pkg::*;

  logic clk;
  logic rst_n;
  logic req_valid;
  logic req_write;
  logic [31:0] req_addr;
  logic [31:0] req_wdata;
  logic [3:0]  req_wstrb;
  logic [31:0] rdata;

  logic [31:0] neuron_threshold;
  logic [7:0]  timesteps;
  logic        reset_mode;
  logic        start_pulse;
  logic        soft_reset_pulse;
  logic        cim_test_mode;
  logic [ADC_BITS-1:0] cim_test_data_pos;
  logic [ADC_BITS-1:0] cim_test_data_neg;
  logic        out_fifo_pop;
  logic [3:0]  out_fifo_rdata_zero;
  logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] out_fifo_count_zero;

  logic        prog_start_pulse;
  logic        prog_erase;
  logic        prog_full_array;
  logic        prog_handshake_bypass;
  logic [5:0]  prog_row;
  logic [4:0]  prog_col;
  logic [3:0]  prog_level;
  logic [2:0]  prog_retry_limit;
  logic [15:0] prog_pulse_width;
  logic [15:0] prog_erase_width;
  logic [31:0] rd_data;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  reg_bank dut (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid(req_valid),
    .req_write(req_write),
    .req_addr(req_addr),
    .req_wdata(req_wdata),
    .req_wstrb(req_wstrb),
    .rdata(rdata),
    .snn_busy(1'b0),
    .snn_done_pulse(1'b0),
    .timestep_counter(8'd0),
    .in_fifo_empty(1'b1),
    .in_fifo_full(1'b0),
    .out_fifo_empty(1'b1),
    .out_fifo_full(1'b0),
    .out_fifo_rdata(out_fifo_rdata_zero),
    .out_fifo_count(out_fifo_count_zero),
    .adc_sat_high(16'd0),
    .adc_sat_low(16'd0),
    .dbg_dma_frame_cnt(16'd0),
    .dbg_cim_cycle_cnt(16'd0),
    .dbg_spike_cnt(16'd0),
    .dbg_wl_stall_cnt(16'd0),
    .neuron_threshold(neuron_threshold),
    .timesteps(timesteps),
    .reset_mode(reset_mode),
    .start_pulse(start_pulse),
    .soft_reset_pulse(soft_reset_pulse),
    .cim_test_mode(cim_test_mode),
    .cim_test_data_pos(cim_test_data_pos),
    .cim_test_data_neg(cim_test_data_neg),
    .out_fifo_pop(out_fifo_pop),
    .prog_start_pulse(prog_start_pulse),
    .prog_erase(prog_erase),
    .prog_full_array(prog_full_array),
    .prog_handshake_bypass(prog_handshake_bypass),
    .prog_row(prog_row),
    .prog_col(prog_col),
    .prog_level(prog_level),
    .prog_retry_limit(prog_retry_limit),
    .prog_pulse_width(prog_pulse_width),
    .prog_erase_width(prog_erase_width),
    .prog_busy(1'b0),
    .prog_done_pulse(1'b0),
    .prog_pass(1'b0),
    .prog_fail(1'b0),
    .prog_retry_count(3'd0)
  );

  task bus_write(input [7:0] addr, input [31:0] data);
    begin
      @(posedge clk);
      req_valid <= 1'b1;
      req_write <= 1'b1;
      req_addr  <= {24'h0, addr};
      req_wdata <= data;
      req_wstrb <= 4'hF;
      @(posedge clk);
      req_valid <= 1'b0;
      req_write <= 1'b0;
      req_addr  <= 32'h0;
      req_wdata <= 32'h0;
      req_wstrb <= 4'h0;
      @(posedge clk);
    end
  endtask

  task bus_read(input [7:0] addr, output [31:0] data);
    begin
      @(posedge clk);
      req_valid <= 1'b1;
      req_write <= 1'b0;
      req_addr  <= {24'h0, addr};
      req_wdata <= 32'h0;
      req_wstrb <= 4'h0;
      #1 data = rdata;
      @(posedge clk);
      req_valid <= 1'b0;
      req_addr  <= 32'h0;
      @(posedge clk);
    end
  endtask

  // expect_width(write_sel, readback_sel, expected_width)
  // Q1 fix: write_sel=2'd3（保留档）时 RTL 硬件钳 readback_sel 到 2'd2，
  //         此 task 支持两者不等的情形，用于 sel=3 -> clamp 测试。
  task expect_width(input [1:0] write_sel, input [1:0] readback_sel,
                    input [15:0] expected);
    logic [31:0] rd;
    begin
      bus_write(8'h90, {14'h0, write_sel, 16'h0});
      if (prog_pulse_width !== expected) begin
        $display("[FAIL] write_sel=%0d pulse_width=%0d expected=%0d",
                 write_sel, prog_pulse_width, expected);
        $finish;
      end
      bus_read(8'h90, rd);
      if (rd[15:0] !== expected || rd[17:16] !== readback_sel) begin
        $display("[FAIL] readback: write_sel=%0d rd=0x%08x expected readback_sel=%0d width=%0d",
                 write_sel, rd, readback_sel, expected);
        $finish;
      end
    end
  endtask

  initial begin
    rst_n = 1'b0;
    req_valid = 1'b0;
    req_write = 1'b0;
    req_addr = 32'h0;
    req_wdata = 32'h0;
    req_wstrb = 4'h0;
    out_fifo_rdata_zero = '0;
    out_fifo_count_zero = '0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    if (prog_pulse_width !== PROG_WRITE_PULSE_1US_CYC[15:0]) begin
      $display("[FAIL] reset write pulse width=%0d", prog_pulse_width);
      $finish;
    end
    if (prog_erase_width !== PROG_ERASE_WIDTH_CYC[15:0]) begin
      $display("[FAIL] reset erase width=%0d", prog_erase_width);
      $finish;
    end

    // PROG_CTRL readback layout regression:
    // {21'h0, retry_limit[2:0], level[3:0], bypass, full_array, erase, START=0}
    bus_write(8'h38, 32'h0000_05AE); // retry=5, level=A, bypass/full/erase=1, start=0
    bus_read(8'h38, rd_data);
    if (rd_data !== 32'h0000_05AE) begin
      $display("[FAIL] PROG_CTRL readback layout rd=0x%08x expected=0x000005ae", rd_data);
      $finish;
    end
    if (prog_retry_limit !== 3'd5 || prog_level !== 4'hA ||
        !prog_handshake_bypass || !prog_full_array || !prog_erase) begin
      $display("[FAIL] PROG_CTRL decoded outputs retry=%0d level=0x%0h bypass=%0b full=%0b erase=%0b",
               prog_retry_limit, prog_level, prog_handshake_bypass, prog_full_array, prog_erase);
      $finish;
    end

    bus_write(8'h38, 32'h0000_0000);
    bus_read(8'h38, rd_data);
    if (rd_data !== 32'h0000_0000) begin
      $display("[FAIL] PROG_CTRL clear readback rd=0x%08x expected=0x00000000", rd_data);
      $finish;
    end

    // write_sel / readback_sel / expected_width
    expect_width(2'd0, 2'd0, PROG_WRITE_PULSE_1US_CYC[15:0]);
    expect_width(2'd1, 2'd1, PROG_WRITE_PULSE_10US_CYC[15:0]);
    expect_width(2'd2, 2'd2, PROG_WRITE_PULSE_100US_CYC[15:0]);
    // Q1: write sel=3 (保留) -> 硬件钳位 readback sel=2，避免字段不自洽
    expect_width(2'd3, 2'd2, PROG_WRITE_PULSE_100US_CYC[15:0]);

    bus_write(8'h94, 32'd123);
    if (prog_erase_width !== PROG_ERASE_WIDTH_CYC[15:0]) begin
      $display("[FAIL] erase width changed after write: %0d", prog_erase_width);
      $finish;
    end

    $display("PROG_PULSE_CFG_TB_PASS");
    $finish;
  end

  initial begin
    #1000000;
    $display("[FAIL] timeout");
    $finish;
  end
endmodule
