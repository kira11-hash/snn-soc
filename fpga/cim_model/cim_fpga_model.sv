`timescale 1ns/1ps
//======================================================================
// 文件名: cim_fpga_model.sv
// 描述: FPGA 可综合 CIM 替代模块（替代 cim_macro_blackbox.sv）
//       - 使用 BRAM 存储 4-bit 量化权重（$readmemh 加载）
//       - 1-bit input × 4-bit weight 条件累加（纯 LUT，不用 DSP）
//       - 接口与 cim_macro_blackbox 100% 端口兼容（即插即换）
//
// Scheme B 架构:
//   20 个 BL 通道：ch[0..9] = 正列, ch[10..19] = 负列
//   weight_pos[row][col]: 64 inputs × 10 outputs, 4-bit unsigned
//   weight_neg[row][col]: 64 inputs × 10 outputs, 4-bit unsigned
//   CIM 计算: acc[j] = Σ_{i=0}^{63} (wl_latched[i] ? weight[i][j] : 0)
//   bl_data[j] = clamp(acc[j], 0, 255)
//
// 时序模型: 保留与 blackbox 相同的延迟特性
//   - cim_start → CIM_LATENCY_CYCLES 后 cim_done
//   - adc_start → ADC_SAMPLE_CYCLES 后 adc_done
//======================================================================
module cim_fpga_model #(
  parameter int P_NUM_INPUTS   = snn_soc_pkg::NUM_INPUTS,
  parameter int P_ADC_CHANNELS = snn_soc_pkg::ADC_CHANNELS
) (
  input  logic clk,
  input  logic rst_n,

  // WL spike input (64-bit bit-plane)
  input  logic [P_NUM_INPUTS-1:0] wl_spike,

  // DAC latch trigger (single-cycle pulse from dac_ctrl)
  input  logic dac_valid,

  // CIM compute trigger/done handshake
  input  logic cim_start,
  output logic cim_done,

  // ADC sample trigger/done + channel select
  input  logic adc_start,
  output logic adc_done,
  input  logic [$clog2(P_ADC_CHANNELS)-1:0] bl_sel,
  output logic [snn_soc_pkg::ADC_BITS-1:0]  bl_data
);
  import snn_soc_pkg::*;

  localparam int BL_SEL_W   = $clog2(P_ADC_CHANNELS);
  localparam int NUM_POS    = NUM_OUTPUTS;              // 10 positive columns
  localparam int NUM_NEG    = NUM_OUTPUTS;              // 10 negative columns
  localparam int WEIGHT_BITS = 4;                       // 4-bit quantized weights

  // -----------------------------------------------------------------------
  // Weight storage: 4-bit weights, 64 rows × 10 columns (pos and neg)
  // Loaded from .hex files via $readmemh at elaboration
  // Memory layout: weight_pos[row] = {col9, col8, ..., col1, col0} packed
  // But for clarity, we use unpacked 2D arrays
  // -----------------------------------------------------------------------
  logic [WEIGHT_BITS-1:0] weight_pos [0:P_NUM_INPUTS-1][0:NUM_POS-1];
  logic [WEIGHT_BITS-1:0] weight_neg [0:P_NUM_INPUTS-1][0:NUM_NEG-1];

  initial begin
    $readmemh("weight_pos.hex", weight_pos);
    $readmemh("weight_neg.hex", weight_neg);
  end

  // -----------------------------------------------------------------------
  // WL latch register (same as blackbox: capture on dac_valid pulse)
  // -----------------------------------------------------------------------
  logic [P_NUM_INPUTS-1:0] wl_latched;

  // -----------------------------------------------------------------------
  // Accumulation results: 20 channels of 8-bit unsigned BL data
  // Computed combinationally from wl_latched and weights
  // -----------------------------------------------------------------------
  logic [P_ADC_CHANNELS-1:0][ADC_BITS-1:0] bl_data_internal;

  // -----------------------------------------------------------------------
  // MAC computation (combinational)
  // For each output column j:
  //   acc_pos[j] = Σ (wl_latched[i] ? weight_pos[i][j] : 0), i=0..63
  //   acc_neg[j] = Σ (wl_latched[i] ? weight_neg[i][j] : 0), i=0..63
  // Clamp to [0, 255] (8-bit unsigned)
  //
  // Max possible accumulation: 64 rows × 15 (max 4-bit weight) = 960
  // Need 10-bit accumulator (2^10 = 1024 > 960)
  // After clamp: 8-bit output
  // -----------------------------------------------------------------------
  logic [9:0] acc_pos [0:NUM_POS-1];
  logic [9:0] acc_neg [0:NUM_NEG-1];

  always_comb begin
    for (int j = 0; j < NUM_POS; j++) begin
      acc_pos[j] = 10'd0;
      acc_neg[j] = 10'd0;
      for (int i = 0; i < P_NUM_INPUTS; i++) begin
        if (wl_latched[i]) begin
          acc_pos[j] = acc_pos[j] + {6'd0, weight_pos[i][j]};
          acc_neg[j] = acc_neg[j] + {6'd0, weight_neg[i][j]};
        end
      end
    end
  end

  // Clamp and store into bl_data_internal
  always_comb begin
    for (int j = 0; j < NUM_POS; j++) begin
      // Positive column: ch[j] (j = 0..9)
      bl_data_internal[j]          = (acc_pos[j] > 10'd255) ? 8'd255 : acc_pos[j][7:0];
      // Negative column: ch[j+10] (j+10 = 10..19)
      bl_data_internal[j + NUM_POS] = (acc_neg[j] > 10'd255) ? 8'd255 : acc_neg[j][7:0];
    end
  end

  // -----------------------------------------------------------------------
  // bl_data output MUX (combinational, same as blackbox)
  // -----------------------------------------------------------------------
  localparam logic [BL_SEL_W-1:0] ADC_CH_MAX = BL_SEL_W'(P_ADC_CHANNELS);

  always_comb begin
    if (bl_sel < ADC_CH_MAX)
      bl_data = bl_data_internal[bl_sel];
    else
      bl_data = {ADC_BITS{1'b0}};
  end

  // -----------------------------------------------------------------------
  // Timing model: CIM and ADC delay counters
  // Identical behavior to cim_macro_blackbox
  // -----------------------------------------------------------------------
  logic [7:0] cim_cnt;
  logic [7:0] adc_cnt;
  logic       cim_busy;
  logic       adc_busy;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wl_latched <= '0;
      cim_done   <= 1'b0;
      adc_done   <= 1'b0;
      cim_cnt    <= 8'h0;
      adc_cnt    <= 8'h0;
      cim_busy   <= 1'b0;
      adc_busy   <= 1'b0;
    end else begin
      cim_done <= 1'b0;
      adc_done <= 1'b0;

      // DAC latch
      if (dac_valid) begin
        wl_latched <= wl_spike;
      end

      // CIM compute delay
      if (cim_start && !cim_busy) begin
        cim_busy <= 1'b1;
        cim_cnt  <= (CIM_LATENCY_CYCLES == 0) ? 8'h0
                                               : (CIM_LATENCY_CYCLES[7:0] - 8'h1);
      end
      if (cim_busy) begin
        if (cim_cnt == 0) begin
          cim_done <= 1'b1;
          cim_busy <= 1'b0;
        end else begin
          cim_cnt <= cim_cnt - 1'b1;
        end
      end

      // ADC sample delay
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

endmodule
