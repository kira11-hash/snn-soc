`timescale 1ns/1ps

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
  logic [$clog2(MAX_NEURONS)-1:0] out_fifo_rdata_zero;
  logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] out_fifo_count_zero;

  logic        prog_start_pulse;
  logic        prog_erase;
  logic        prog_full_array;
  logic [5:0]  prog_row;
  logic [4:0]  prog_col;
  logic [3:0]  prog_level;
  logic [2:0]  prog_retry_limit;
  logic [15:0] prog_pulse_width;
  logic [15:0] prog_erase_width;

  logic [1:0]  ml_num_layers;
  logic        ml_enable;
  logic [MAX_LAYERS-1:0][31:0] ml_layer_cfg;
  logic [MAX_LAYERS-1:0][31:0] ml_layer_timing;
  logic [MAX_LAYERS-1:0][31:0] ml_layer_threshold;
  logic [MAX_LAYERS-1:0][31:0] ml_layer_neuron_cfg;

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
    .prog_retry_count(3'd0),
    .ml_num_layers(ml_num_layers),
    .ml_enable(ml_enable),
    .ml_layer_cfg(ml_layer_cfg),
    .ml_layer_timing(ml_layer_timing),
    .ml_layer_threshold(ml_layer_threshold),
    .ml_layer_neuron_cfg(ml_layer_neuron_cfg),
    .spike_q_overflow(1'b0)
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

  task expect_width(input [1:0] sel, input [15:0] expected);
    logic [31:0] rd;
    begin
      bus_write(8'h90, {14'h0, sel, 16'h0});
      if (prog_pulse_width !== expected) begin
        $display("[FAIL] sel=%0d pulse_width=%0d expected=%0d",
                 sel, prog_pulse_width, expected);
        $finish;
      end
      bus_read(8'h90, rd);
      if (rd[15:0] !== expected || rd[17:16] !== sel) begin
        $display("[FAIL] readback sel=%0d rd=0x%08x expected width=%0d",
                 sel, rd, expected);
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

    expect_width(2'd0, PROG_WRITE_PULSE_1US_CYC[15:0]);
    expect_width(2'd1, PROG_WRITE_PULSE_10US_CYC[15:0]);
    expect_width(2'd2, PROG_WRITE_PULSE_100US_CYC[15:0]);
    expect_width(2'd3, PROG_WRITE_PULSE_100US_CYC[15:0]);

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
