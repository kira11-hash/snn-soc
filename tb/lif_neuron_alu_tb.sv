`timescale 1ns/1ps

module lif_neuron_alu_tb;
  import snn_soc_pkg::*;

  localparam int P_MAX_NEURONS = 8;
  localparam int IDX_W = $clog2(P_MAX_NEURONS);

  logic clk;
  logic rst_n;
  logic soft_reset_pulse;
  logic neuron_in_valid;
  logic [P_MAX_NEURONS-1:0][NEURON_DATA_WIDTH-1:0] neuron_in_data;
  logic [$clog2(PIXEL_BITS)-1:0] bitplane_shift;
  logic [31:0] threshold;
  logic reset_mode;
  logic [7:0] active_neuron_count;
  logic out_fifo_push;
  logic [IDX_W-1:0] out_fifo_wdata;
  logic out_fifo_full;
  logic [P_MAX_NEURONS-1:0] spike_mask;
  logic spike_mask_valid;
  logic alu_busy;
  logic spike_q_overflow;
  logic clearing_busy;
  logic output_fifo_en;

  int push_count;
  time push_time_0;
  time push_time_1;
  logic [IDX_W-1:0] push_id_0;
  logic [IDX_W-1:0] push_id_1;
  int wait_cycles;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  lif_neuron_alu #(
    .P_MAX_NEURONS(P_MAX_NEURONS)
  ) dut (
    .clk              (clk),
    .rst_n            (rst_n),
    .soft_reset_pulse (soft_reset_pulse),
    .neuron_in_valid  (neuron_in_valid),
    .neuron_in_data   (neuron_in_data),
    .bitplane_shift   (bitplane_shift),
    .threshold        (threshold),
    .reset_mode       (reset_mode),
    .active_neuron_count(active_neuron_count),
    .out_fifo_push    (out_fifo_push),
    .out_fifo_wdata   (out_fifo_wdata),
    .out_fifo_full    (out_fifo_full),
    .spike_mask       (spike_mask),
    .spike_mask_valid (spike_mask_valid),
    .alu_busy         (alu_busy),
    .spike_q_overflow (spike_q_overflow),
    .clearing_busy    (clearing_busy),
    .output_fifo_en   (output_fifo_en)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      push_count  <= 0;
      push_time_0 <= 0;
      push_time_1 <= 0;
      push_id_0   <= '0;
      push_id_1   <= '0;
    end else if (out_fifo_push) begin
      push_count <= push_count + 1;
      if (push_count == 0) begin
        push_time_0 <= $time;
        push_id_0   <= out_fifo_wdata;
      end else if (push_count == 1) begin
        push_time_1 <= $time;
        push_id_1   <= out_fifo_wdata;
      end
    end
  end

  initial begin
    rst_n = 1'b0;
    soft_reset_pulse = 1'b0;
    neuron_in_valid = 1'b0;
    neuron_in_data = '0;
    bitplane_shift = '0;
    threshold = 32'd1;
    reset_mode = 1'b0;
    active_neuron_count = 8'd2;
    out_fifo_full = 1'b0;
    output_fifo_en = 1'b1;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    wait (!clearing_busy);
    @(posedge clk);

    neuron_in_data[0] = NEURON_DATA_WIDTH'(1);
    neuron_in_data[1] = NEURON_DATA_WIDTH'(1);
    neuron_in_valid = 1'b1;
    @(posedge clk);
    neuron_in_valid = 1'b0;

    wait_cycles = 0;
    while ((push_count != 2) && (wait_cycles < 20)) begin
      @(posedge clk);
      wait_cycles = wait_cycles + 1;
    end

    neuron_in_data = '0;

    if (push_count != 2) begin
      $display("[FAIL] expected 2 output pushes, got %0d running=%0d s1_valid=%0d sq_count=%0d neuron_idx=%0d limit=%0d clearing=%0d out_fifo_push=%0d output_fifo_en=%0d",
        push_count, dut.running, dut.s1_valid, dut.sq_count, dut.neuron_idx, dut.neuron_limit, dut.clearing, out_fifo_push, output_fifo_en);
      $finish;
    end

    if (push_id_0 != IDX_W'(0)) begin
      $display("[FAIL] first spike id mismatch: got %0d", push_id_0);
      $finish;
    end

    if (push_id_1 != IDX_W'(1)) begin
      $display("[FAIL] second spike id mismatch: got %0d", push_id_1);
      $finish;
    end

    if ((push_time_1 - push_time_0) != 10ns) begin
      $display("[FAIL] second spike was not drained on the next cycle (delta=%0t)", push_time_1 - push_time_0);
      $finish;
    end

    if (spike_q_overflow) begin
      $display("[FAIL] unexpected spike queue overflow");
      $finish;
    end

    $display("LIF_NEURON_ALU_PASS");
    $finish;
  end

  initial begin
    #20000;
    $display("[FAIL] lif_neuron_alu_tb timeout push_count=%0d running=%0d s1_valid=%0d sq_count=%0d neuron_idx=%0d limit=%0d clearing=%0d",
      push_count, dut.running, dut.s1_valid, dut.sq_count, dut.neuron_idx, dut.neuron_limit, dut.clearing);
    $finish;
  end
endmodule
