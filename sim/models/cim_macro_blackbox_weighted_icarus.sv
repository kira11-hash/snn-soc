`timescale 1ns/1ps

// Icarus-only weighted CIM behavioral model.
// This file deliberately reuses the production module name so a dedicated
// filelist can swap it in without touching rtl/top/snn_soc_top.sv.
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
module cim_macro_blackbox #(
  parameter int P_NUM_INPUTS   = snn_soc_pkg::NUM_INPUTS,
  parameter int P_ADC_CHANNELS = snn_soc_pkg::ADC_CHANNELS,
  parameter int P_WEIGHT_BITS  = 4
) (
  input  logic clk,
  input  logic rst_n,
  input  logic [P_NUM_INPUTS-1:0] wl_spike,
  input  logic dac_valid,
  input  logic cim_start,
  output logic cim_done,
  input  logic adc_start,
  output logic adc_done,
  input  logic [$clog2(P_ADC_CHANNELS)-1:0] bl_sel,
  output logic [snn_soc_pkg::ADC_BITS-1:0] bl_data
);
  import snn_soc_pkg::*;

  localparam int P_NUM_OUTPUTS = NUM_OUTPUTS;
  localparam int BL_SEL_W      = $clog2(P_ADC_CHANNELS);
  localparam int P_DEPTH       = P_NUM_INPUTS * P_NUM_OUTPUTS;
  localparam int P_ADC_MAX     = (1 << ADC_BITS) - 1;
  localparam int P_LEVEL_MAX   = (1 << P_WEIGHT_BITS) - 1;
  localparam int P_SUM_MAX     = (P_NUM_INPUTS * P_LEVEL_MAX > 0) ? (P_NUM_INPUTS * P_LEVEL_MAX) : 1;
  localparam logic [BL_SEL_W-1:0] ADC_CH_MAX = BL_SEL_W'(P_ADC_CHANNELS);

  logic [P_NUM_INPUTS-1:0] wl_latched;
  logic [P_WEIGHT_BITS-1:0] weight_pos_mem [0:P_DEPTH-1];
  logic [P_WEIGHT_BITS-1:0] weight_neg_mem [0:P_DEPTH-1];
  logic [P_ADC_CHANNELS-1:0][ADC_BITS-1:0] bl_data_internal;
  logic [7:0] cim_cnt;
  logic [7:0] adc_cnt;
  logic       cim_busy;
  logic       adc_busy;

  integer fd_pos;
  integer fd_neg;
  integer idx;

  function automatic [ADC_BITS-1:0] scale_sum_to_adc(input integer raw_sum);
    integer scaled;
    begin
      scaled = (raw_sum * P_ADC_MAX + (P_SUM_MAX / 2)) / P_SUM_MAX;
      if (scaled < 0) begin
        scaled = 0;
      end else if (scaled > P_ADC_MAX) begin
        scaled = P_ADC_MAX;
      end
      scale_sum_to_adc = ADC_BITS'(scaled);
    end
  endfunction

  task automatic compute_bl_channels;
    integer row_i;
    integer col_i;
    integer flat_idx_i;
    integer pos_sum_i;
    integer neg_sum_i;
    begin
      for (col_i = 0; col_i < P_NUM_OUTPUTS; col_i = col_i + 1) begin
        pos_sum_i = 0;
        neg_sum_i = 0;
        for (row_i = 0; row_i < P_NUM_INPUTS; row_i = row_i + 1) begin
          if (wl_latched[row_i]) begin
            flat_idx_i = row_i * P_NUM_OUTPUTS + col_i;
            pos_sum_i = pos_sum_i + integer'(weight_pos_mem[flat_idx_i]);
            neg_sum_i = neg_sum_i + integer'(weight_neg_mem[flat_idx_i]);
          end
        end
        bl_data_internal[col_i]                <= scale_sum_to_adc(pos_sum_i);
        bl_data_internal[col_i + P_NUM_OUTPUTS] <= scale_sum_to_adc(neg_sum_i);
      end
    end
  endtask

  initial begin
    for (idx = 0; idx < P_DEPTH; idx = idx + 1) begin
      weight_pos_mem[idx] = '0;
      weight_neg_mem[idx] = '0;
    end

    fd_pos = $fopen("weight_pos.hex", "r");
    if (fd_pos == 0) begin
      $fatal(1, "[cim_macro_weighted] missing weight_pos.hex");
    end
    $fclose(fd_pos);

    fd_neg = $fopen("weight_neg.hex", "r");
    if (fd_neg == 0) begin
      $fatal(1, "[cim_macro_weighted] missing weight_neg.hex");
    end
    $fclose(fd_neg);

    $readmemh("weight_pos.hex", weight_pos_mem);
    $readmemh("weight_neg.hex", weight_neg_mem);
    $display("[cim_macro_weighted] loaded weight_pos.hex / weight_neg.hex");
    $display("[cim_macro_weighted] layout=row-major by input_row, outputs=%0d inputs=%0d",
             P_NUM_OUTPUTS, P_NUM_INPUTS);
  end

  always_comb begin
    if (bl_sel < ADC_CH_MAX) begin
      bl_data = bl_data_internal[bl_sel];
    end else begin
      bl_data = '0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wl_latched       <= '0;
      cim_done         <= 1'b0;
      adc_done         <= 1'b0;
      cim_cnt          <= 8'h0;
      adc_cnt          <= 8'h0;
      cim_busy         <= 1'b0;
      adc_busy         <= 1'b0;
      bl_data_internal <= '0;
    end else begin
      cim_done <= 1'b0;
      adc_done <= 1'b0;

      if (dac_valid) begin
        wl_latched <= wl_spike;
      end

      if (cim_start && !cim_busy) begin
        cim_busy <= 1'b1;
        cim_cnt  <= (CIM_LATENCY_CYCLES == 0) ? 8'h0
                                              : (CIM_LATENCY_CYCLES[7:0] - 8'h1);
      end
      if (cim_busy) begin
        if (cim_cnt == 0) begin
          compute_bl_channels();
          cim_done <= 1'b1;
          cim_busy <= 1'b0;
        end else begin
          cim_cnt <= cim_cnt - 1'b1;
        end
      end

      if (adc_start && !adc_busy) begin
        adc_busy <= 1'b1;
        adc_cnt  <= (ADC_SAMPLE_CYCLES == 0) ? 8'h0
                                             : (ADC_SAMPLE_CYCLES[7:0] - 8'h1);
      end
      if (adc_busy) begin
        if (adc_cnt == 0) begin
          adc_done <= 1'b1;
          adc_busy <= 1'b0;
        end else begin
          adc_cnt <= adc_cnt - 1'b1;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (!$isunknown(bl_sel)) begin
      assert (bl_sel < ADC_CH_MAX)
        else $error("[cim_macro_weighted] bl_sel out of range: %0d / %0d", bl_sel, P_ADC_CHANNELS);
    end
  end
`endif
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */
endmodule
