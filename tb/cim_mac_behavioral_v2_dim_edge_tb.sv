`timescale 1ns/1ps

// Edge-case regression for max dimension handling in cim_mac_behavioral_v2.
//
// The bug this catches:
//   cfg_in_dim=256 has low 8 bits == 0
//   cfg_out_dim=128 has low 7 bits == 0
// Any logic that truncates cfg_*_dim before comparisons will skip the max
// row/column and produce diff[127] == 0 instead of the expected ADC value.
module cim_mac_behavioral_v2_dim_edge_tb;
  import snn_soc_pkg::*;

  localparam int P_N_IN      = V2B_NUM_INPUTS;
  localparam int P_N_OUT     = V2B_MAX_OUT_NEURONS;
  localparam int P_PARTIAL_W = V2B_PARTIAL_WIDTH;
  localparam int P_ADC_BITS  = 10;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic w_load_en;
  logic [$clog2(P_N_IN)-1:0]  w_load_i;
  logic [$clog2(P_N_OUT)-1:0] w_load_j;
  logic [3:0] w_load_pos_data;
  logic [3:0] w_load_neg_data;

  logic mac_start;
  logic [P_N_IN-1:0] wl_mask;
  logic [15:0] cfg_in_dim;
  logic [15:0] cfg_out_dim;
  logic [31:0] cfg_sum_max;
  logic mac_busy;
  logic mac_done;

  logic [$clog2(P_N_OUT)-1:0] diff_rd_j;
  logic signed [P_PARTIAL_W-1:0] diff_rd_data;

  cim_mac_behavioral_v2 #(
    .P_ADC_BITS(P_ADC_BITS)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .w_load_en(w_load_en),
    .w_load_i(w_load_i),
    .w_load_j(w_load_j),
    .w_load_pos_data(w_load_pos_data),
    .w_load_neg_data(w_load_neg_data),
    .mac_start(mac_start),
    .wl_mask(wl_mask),
    .cfg_in_dim(cfg_in_dim),
    .cfg_out_dim(cfg_out_dim),
    .cfg_sum_max(cfg_sum_max),
    .mac_busy(mac_busy),
    .mac_done(mac_done),
    .diff_rd_j(diff_rd_j),
    .diff_rd_data(diff_rd_data)
  );

  initial begin
    w_load_en = 0;
    w_load_i = '0;
    w_load_j = '0;
    w_load_pos_data = '0;
    w_load_neg_data = '0;
    mac_start = 0;
    wl_mask = '0;
    cfg_in_dim = P_N_IN[15:0];
    cfg_out_dim = P_N_OUT[15:0];
    cfg_sum_max = V2B_SUM_MAX_ARRAY;
    diff_rd_j = P_N_OUT - 1;

    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // Put a single non-zero weight in the max row/max output column.
    w_load_i = P_N_IN - 1;
    w_load_j = P_N_OUT - 1;
    w_load_pos_data = 4'd15;
    w_load_neg_data = 4'd0;
    w_load_en = 1'b1;
    @(posedge clk);
    w_load_en = 1'b0;

    wl_mask = '0;
    wl_mask[P_N_IN-1] = 1'b1;
    mac_start = 1'b1;
    @(posedge clk);
    mac_start = 1'b0;

    wait (mac_done);
    @(posedge clk);

    // ADC(15, sum_max=3840, adc_bits=10) = floor((15*1023+1920)/3840) = 4.
    if (diff_rd_data !== 14'sd4) begin
      $display("[FAIL] diff[127] = %0d, expected 4", diff_rd_data);
      $finish;
    end

    $display("[PASS] max-dim diff[127] = %0d", diff_rd_data);
    $display("CIM_MAC_BEHAVIORAL_V2_DIM_EDGE_TB_PASS");
    $finish;
  end
endmodule
