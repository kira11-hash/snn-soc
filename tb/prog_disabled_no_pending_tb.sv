`timescale 1ns/1ps

// Verify that PROG_CTRL.START is a no-op when the programming FSM is not
// instantiated. This protects ENABLE_PROGRAM_MODE=0 builds from leaving
// prog_start_pending stuck high and blocking the next CIM_CTRL.START.
module prog_disabled_no_pending_tb;
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

  initial clk = 1'b0;
  always #5 clk = ~clk;

  reg_bank #(.ENABLE_PROGRAM_MODE(1'b0)) dut (
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
    .out_fifo_rdata(4'd0),
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

  task bus_idle;
    begin
      req_valid <= 1'b0;
      req_write <= 1'b0;
      req_addr  <= 32'h0;
      req_wdata <= 32'h0;
      req_wstrb <= 4'h0;
    end
  endtask

  task bus_write(input [7:0] addr, input [31:0] data);
    begin
      req_valid <= 1'b1;
      req_write <= 1'b1;
      req_addr  <= {24'h0, addr};
      req_wdata <= data;
      req_wstrb <= 4'hF;
      @(posedge clk);
      bus_idle;
    end
  endtask

  initial begin
    rst_n = 1'b0;
    bus_idle;
    out_fifo_count_zero = '0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    bus_write(8'h38, 32'h0000_0007); // PROG_CTRL.START + ERASE + FULL_ARRAY
    repeat (3) @(posedge clk);
    if (prog_start_pulse !== 1'b0 || dut.prog_start_pending !== 1'b0) begin
      $display("[FAIL] Disabled programming mode generated pulse or pending: pulse=%0b pending=%0b",
               prog_start_pulse, dut.prog_start_pending);
      $finish;
    end

    bus_write(8'h14, 32'h0000_0001); // CIM_CTRL.START must still pass
    @(posedge clk);
    if (start_pulse !== 1'b1) begin
      $display("[FAIL] CIM_CTRL.START was blocked after disabled PROG_CTRL.START");
      $finish;
    end

    $display("PROG_DISABLED_NO_PENDING_TB_PASS");
    $finish;
  end

  initial begin
    #100_000;
    $display("[FAIL] Global timeout");
    $finish;
  end
endmodule
