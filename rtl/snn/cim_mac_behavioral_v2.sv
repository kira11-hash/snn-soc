`timescale 1ns/1ps
//======================================================================
// 文件名: cim_mac_behavioral_v2.sv
// 模块名: cim_mac_behavioral_v2
//
// 【功能概述】
// V2.B per-position Scheme B differential MAC，behavioral 实现（不接
// 真 CIM 模拟宏）。替换 stage_engine_v2 的 popcount 占位，使得 Python
// golden ↔ RTL bit-parity 可以真 per-neuron 对齐。
//
// 【与 cim_array_ctrl 的差别】
// - cim_array_ctrl (V1)：bit-plane 展开 × 8-group WL mux × 20 BL × 8-bit ADC。
//   专为 V1 NUM_INPUTS=64, OUT=10, ADC_BITS=8 写。
// - cim_mac_behavioral_v2：V2.B 语义 per-timestep 1-bit WL × 单 ADC per
//   neuron × 可配 ADC_BITS (8/10/12) × Scheme B per-tile sum_max。
//
// 【接口】
// 权重装载：TB 或 DMA 通过 w_load_* 端口逐 cell 写入内部 weight memory
// （`w_pos_mem[i][j]`，`w_neg_mem[i][j]` 各 4-bit level 0..15）。
//
// MAC 计算：每 timestep 拉 mac_start，给 wl_mask + cfg_in_dim/out_dim/
// sum_max；模块内部串行对每个 neuron j 计算：
//   pos_sum[j]  = sum_{i : wl_mask[i]=1} w_pos_mem[i][j]
//   neg_sum[j]  = sum_{i : wl_mask[i]=1} w_neg_mem[i][j]
//   adc_pos[j]  = rtl_adc_scale_v2(pos_sum[j], sum_max, adc_bits)
//   adc_neg[j]  = rtl_adc_scale_v2(neg_sum[j], sum_max, adc_bits)
//   diff[j]     = adc_pos[j] - adc_neg[j]        // signed P_PARTIAL_W bit
//
// 完成后拉 mac_done，diff 数组在 diff_ram 内供 stage_engine_v2 逐 j 取。
//
// 【ADC 量化公式（match Python adc_scale_v2.rtl_adc_scale_v2）】
//   adc_max = (1 << adc_bits) - 1       // 10-bit 时 1023
//   scaled  = (raw * adc_max + sum_max/2) / sum_max   // 半步四舍五入
//   clamp   to [0, adc_max]
//
// 【为什么串行】
// 256-wide parallel ADC + popcount 会膨胀 LUT；FPGA 综合吃紧。串行每
// neuron 一周期，对 128 neuron × T=64 stage 共 8192 cycle（快）。生产
// 级 ASIC 下 cim_array_ctrl 会用物理并行 + 20-channel ADC + MUX。
//======================================================================
module cim_mac_behavioral_v2
  import snn_soc_pkg::*;
#(
  parameter int P_N_IN      = V2B_NUM_INPUTS,         // 256
  parameter int P_N_OUT     = V2B_MAX_OUT_NEURONS,    // 128
  parameter int P_PARTIAL_W = V2B_PARTIAL_WIDTH,      // signed 14-bit
  parameter int P_ADC_BITS  = 10,
  parameter int P_W_BITS    = 4                        // weight level width
) (
  input  logic clk,
  input  logic rst_n,

  // ── Weight load (TB / DMA ─ single cell per cycle) ───────────────
  input  logic                              w_load_en,
  input  logic [$clog2(P_N_IN) -1:0]        w_load_i,
  input  logic [$clog2(P_N_OUT)-1:0]        w_load_j,
  input  logic [P_W_BITS-1:0]               w_load_pos_data,
  input  logic [P_W_BITS-1:0]               w_load_neg_data,

  // ── MAC request ──────────────────────────────────────────────────
  input  logic                              mac_start,
  input  logic [P_N_IN-1:0]                 wl_mask,
  input  logic [15:0]                       cfg_in_dim,
  input  logic [15:0]                       cfg_out_dim,
  input  logic [31:0]                       cfg_sum_max,
  output logic                              mac_busy,
  output logic                              mac_done,

  // ── Diff read port (stage_engine_v2 addresses after mac_done) ────
  input  logic [$clog2(P_N_OUT)-1:0]        diff_rd_j,
  output logic signed [P_PARTIAL_W-1:0]     diff_rd_data
);

  // ── Weight memory (behavioral only; ASIC path uses RRAM CIM array) ──
  // Size: P_N_IN × P_N_OUT × 4-bit × 2 = 256×128×4×2 = 256 Kbit full
  logic [P_W_BITS-1:0] w_pos_mem [0:P_N_IN-1][0:P_N_OUT-1];
  logic [P_W_BITS-1:0] w_neg_mem [0:P_N_IN-1][0:P_N_OUT-1];

  // Diff result storage (updated at mac_done)
  logic signed [P_PARTIAL_W-1:0] diff_mem [0:P_N_OUT-1];

  assign diff_rd_data = diff_mem[diff_rd_j];

  // ── Weight load ───────────────────────────────────────────────────
  // Synchronous single-port write. Initial reset wipes to zero.
  integer wi, wj;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (wi = 0; wi < P_N_IN; wi = wi + 1)
        for (wj = 0; wj < P_N_OUT; wj = wj + 1) begin
          w_pos_mem[wi][wj] <= '0;
          w_neg_mem[wi][wj] <= '0;
        end
    end else if (w_load_en) begin
      w_pos_mem[w_load_i][w_load_j] <= w_load_pos_data;
      w_neg_mem[w_load_i][w_load_j] <= w_load_neg_data;
    end
  end

  // ── MAC FSM ───────────────────────────────────────────────────────
  typedef enum logic [1:0] {
    MS_IDLE   = 2'd0,
    MS_COMPUTE= 2'd1,
    MS_DONE   = 2'd2
  } mac_state_e;

  mac_state_e mac_state;
  logic [$clog2(P_N_OUT)-1:0] j_idx;
  logic [P_N_IN-1:0]          wl_latched_mac;
  logic [15:0]                in_dim_latched;
  logic [15:0]                out_dim_latched;
  logic [31:0]                sum_max_latched;

  // Combinational: for current j_idx, sum w_pos and w_neg over wl_mask
  // This is O(P_N_IN) adders at synth but Icarus sim handles fine at
  // small dims. For production, replace with CIM bank popcount hardware.
  localparam int RAW_W = $clog2((P_N_IN + 1) * ((1<<P_W_BITS) - 1) + 1);
  logic [RAW_W-1:0] pos_sum_c;
  logic [RAW_W-1:0] neg_sum_c;
  integer si;
  always @* begin
    pos_sum_c = '0;
    neg_sum_c = '0;
    for (si = 0; si < P_N_IN; si = si + 1) begin
      if ((si < in_dim_latched) && wl_latched_mac[si]) begin
        pos_sum_c = pos_sum_c + w_pos_mem[si][j_idx];
        neg_sum_c = neg_sum_c + w_neg_mem[si][j_idx];
      end
    end
  end

  // ADC scale (match Python rtl_adc_scale_v2)
  function automatic logic [RAW_W-1:0] adc_scale
    (input logic [RAW_W-1:0] raw, input logic [31:0] sum_max,
     input int adc_bits);
    logic [31:0] adc_max;
    logic [63:0] num;
    logic [31:0] scaled;
    begin
      adc_max = (32'd1 << adc_bits) - 32'd1;
      num     = raw * adc_max + (sum_max >> 1);
      scaled  = (sum_max == 32'd0) ? 32'd0 : num[63:0] / sum_max;
      if (scaled > adc_max) adc_scale = adc_max[RAW_W-1:0];
      else                  adc_scale = scaled[RAW_W-1:0];
    end
  endfunction

  // Compute ADC-quantised diff at current j.
  // Widen to 32-bit signed for saturation headroom, then clip into P_PARTIAL_W.
  logic [RAW_W-1:0]      adc_pos, adc_neg;
  logic signed [31:0]    raw_diff;
  logic signed [P_PARTIAL_W-1:0] diff_current;
  localparam logic signed [31:0] PARTIAL_MAX_32 = (32'sd1 <<< (P_PARTIAL_W-1)) - 32'sd1;
  localparam logic signed [31:0] PARTIAL_MIN_32 = -(32'sd1 <<< (P_PARTIAL_W-1));

  always @* begin
    adc_pos = adc_scale(pos_sum_c, sum_max_latched, P_ADC_BITS);
    adc_neg = adc_scale(neg_sum_c, sum_max_latched, P_ADC_BITS);
    raw_diff = $signed({20'b0, adc_pos[11:0]}) - $signed({20'b0, adc_neg[11:0]});
    if (raw_diff > PARTIAL_MAX_32)
      diff_current = PARTIAL_MAX_32[P_PARTIAL_W-1:0];
    else if (raw_diff < PARTIAL_MIN_32)
      diff_current = PARTIAL_MIN_32[P_PARTIAL_W-1:0];
    else
      diff_current = raw_diff[P_PARTIAL_W-1:0];
  end

  // FSM
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mac_state       <= MS_IDLE;
      j_idx           <= '0;
      wl_latched_mac  <= '0;
      in_dim_latched  <= '0;
      out_dim_latched <= '0;
      sum_max_latched <= '0;
      for (int k = 0; k < P_N_OUT; k = k + 1) diff_mem[k] <= '0;
    end else begin
      case (mac_state)
        MS_IDLE: begin
          if (mac_start) begin
            wl_latched_mac  <= wl_mask;
            in_dim_latched  <= cfg_in_dim;
            out_dim_latched <= cfg_out_dim;
            sum_max_latched <= cfg_sum_max;
            j_idx           <= '0;
            mac_state       <= MS_COMPUTE;
          end
        end
        MS_COMPUTE: begin
          // latch diff for current j
          diff_mem[j_idx] <= diff_current;
          if (j_idx == out_dim_latched[$clog2(P_N_OUT)-1:0] - 1) begin
            mac_state <= MS_DONE;
          end else begin
            j_idx <= j_idx + 1;
          end
        end
        MS_DONE: begin
          mac_state <= MS_IDLE;
        end
        default: mac_state <= MS_IDLE;
      endcase
    end
  end

  assign mac_busy = (mac_state != MS_IDLE);
  assign mac_done = (mac_state == MS_DONE);

endmodule
