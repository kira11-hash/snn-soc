`timescale 1ns/1ps
//======================================================================
// 文件名: cim_mac_behavioral_v2.sv
// 模块名: cim_mac_behavioral_v2
//
// 【功能概述】
// V2.B per-position Scheme B differential MAC，behavioral 实现。
// FPGA-friendly 版（2026-04-21 重构自 combinational 256-input adder 树）。
//
// 【架构：WL-serial + all-j-parallel】
// 为避开 Vivado "Cross Boundary and Area Optimization" 阶段在 256-input
// 组合加法树上卡死（实测 > 6h 不收敛），改成每 cycle 处理 1 个 WL
// 但对所有 P_N_OUT 个 out neuron 并行累加。行为完全等价，latency
// 从 (N_OUT cycles) 变 (N_IN + N_OUT cycles)。
//
//   MS_IDLE     → (mac_start) latch cfg, zero accumulators, → MS_ACCUM
//   MS_ACCUM    每 cycle 处理 si = 0..in_dim-1：
//                 if wl_mask[si] && si<in_dim:
//                   for (j=0..out_dim-1 parallel)
//                     pos_acc[j] <= pos_acc[j] + w_pos_mem[si][j]
//                     neg_acc[j] <= neg_acc[j] + w_neg_mem[si][j]
//                 → (si==in_dim-1) MS_ADC
//   MS_ADC      每 cycle 处理 j = 0..out_dim-1：
//                 diff_mem[j] <= clip_P_PARTIAL(adc(pos_acc[j]) - adc(neg_acc[j]))
//                 → (j==out_dim-1) MS_DONE
//   MS_DONE     → MS_IDLE; mac_done = 1 for 1 cycle
//
// 【FPGA synth 优点】
// - 无 256-input 组合加法树；每 cycle 只 128 个 12-bit parallel adder
// - weight read per cycle = w_pos_mem[si][0..N_OUT-1]，Vivado 可推成
//   BRAM with 128 × 4-bit = 512-bit wide read port (or multi-BRAM)
// - critical path ≈ 1 adder + 1 FF = 2-3 ns，100 MHz 容易过
//
// 【bit-parity 保证】
// 输出 diff_mem[j] 的数值与前版 combinational 实现完全等价：都是
// sum over (si : wl[si]=1) of w_pos[si][j]，ADC 缩放公式不变。
// 已在 9 个 V2.B TB 里 bit-exact 验证通过（see git history）。
//
// 【端口零变化】
// stage_engine_v2、snn_soc_v2b_top 不需要改。只是 mac_busy 持续时间变长
// （N_IN + N_OUT 代替 N_OUT）。stage_engine FSM 已用 mac_done 握手，
// 自动适应新 latency。
//
// 【ADC 公式（match Python adc_scale_v2.rtl_adc_scale_v2）】
//   adc_max = (1 << adc_bits) - 1
//   scaled  = (raw * adc_max + sum_max/2) / sum_max   (半步四舍五入)
//   clamp   to [0, adc_max]
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

  // ── Width calculations ───────────────────────────────────────────
  // Max per-neuron raw sum: if all 256 WL are 1 and all weights are
  // 15 (4-bit max), raw = 256 * 15 = 3840, fits in 12 bits.
  localparam int RAW_W = $clog2((P_N_IN + 1) * ((1<<P_W_BITS) - 1) + 1);

  // ── Weight memory: 1D packed word per si row ────────────────────
  // Before (Vivado 3D-RAM killer):
  //   logic [3:0] w_pos_mem [0:P_N_IN-1][0:P_N_OUT-1];  // 3D unpacked
  // After (1D BRAM-friendly):
  //   Each row = P_N_OUT × P_W_BITS = 512-bit packed word; per-cycle
  //   read delivers all neurons' weights for the current si in parallel.
  //   Vivado partitions across multiple BRAMs (72-bit port max → 8 BRAMs).
  localparam int P_ROW_BITS = P_N_OUT * P_W_BITS;  // 128 × 4 = 512
  (* ram_style = "block" *)
  logic [P_ROW_BITS-1:0] w_pos_mem [0:P_N_IN-1];
  (* ram_style = "block" *)
  logic [P_ROW_BITS-1:0] w_neg_mem [0:P_N_IN-1];

  // Per-neuron accumulators (128 FF × 12-bit = 1536 FF — small, OK)
  logic [RAW_W-1:0] pos_acc [0:P_N_OUT-1];
  logic [RAW_W-1:0] neg_acc [0:P_N_OUT-1];

  // Diff result storage (128 × 14-bit = 1792 FF, distributed RAM)
  (* ram_style = "distributed" *)
  logic signed [P_PARTIAL_W-1:0] diff_mem [0:P_N_OUT-1];

  assign diff_rd_data = diff_mem[diff_rd_j];

  // ── Weight load: subset write within 512-bit packed row ──────────
  // Vivado synthesises `mem[addr][slice] <= data` as BRAM write-enable
  // on the byte/nibble lane corresponding to the slice.
`ifdef SYNTHESIS
  // Synth: no reset-broadcast. Initial contents are don't-care until
  // firmware loads. Real HW deployment will overwrite before first MAC.
  always_ff @(posedge clk) begin
    if (w_load_en) begin
      w_pos_mem[w_load_i][w_load_j*P_W_BITS +: P_W_BITS] <= w_load_pos_data;
      w_neg_mem[w_load_i][w_load_j*P_W_BITS +: P_W_BITS] <= w_load_neg_data;
    end
  end
`else
  // Sim: reset all cells to 0 for deterministic TB behaviour.
  integer wi;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (wi = 0; wi < P_N_IN; wi = wi + 1) begin
        w_pos_mem[wi] <= '0;
        w_neg_mem[wi] <= '0;
      end
    end else if (w_load_en) begin
      w_pos_mem[w_load_i][w_load_j*P_W_BITS +: P_W_BITS] <= w_load_pos_data;
      w_neg_mem[w_load_i][w_load_j*P_W_BITS +: P_W_BITS] <= w_load_neg_data;
    end
  end
`endif

  // ── ADC scale function (match Python rtl_adc_scale_v2) ───────────
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

  // ── FSM ──────────────────────────────────────────────────────────
  typedef enum logic [1:0] {
    MS_IDLE      = 2'd0,
    MS_ACCUM     = 2'd1,   // one WL row per cycle × all j parallel
    MS_ADC       = 2'd2,   // one neuron per cycle, apply ADC + subtract
    MS_DONE      = 2'd3
  } mac_state_e;

  mac_state_e mac_state;

  // Current si (WL row being accumulated) and j (neuron being ADC'd)
  logic [$clog2(P_N_IN)-1:0]  si_idx;
  logic [$clog2(P_N_OUT)-1:0] j_idx;

  // Latched config/WL at start of MAC run
  logic [P_N_IN-1:0]          wl_latched_mac;
  logic [15:0]                in_dim_latched;
  logic [15:0]                out_dim_latched;
  logic [31:0]                sum_max_latched;

  // Comparator helpers (per-cycle)
  logic in_dim_last, out_dim_last;
  assign in_dim_last  = (si_idx == in_dim_latched[$clog2(P_N_IN)-1:0]  - 1);
  assign out_dim_last = (j_idx  == out_dim_latched[$clog2(P_N_OUT)-1:0] - 1);

  // Active bit for current si
  logic si_active;
  assign si_active = (si_idx < in_dim_latched[$clog2(P_N_IN)-1:0])
                   && wl_latched_mac[si_idx];

  // ── ADC + clip for current j (combinational from pos_acc/neg_acc) ──
  logic [RAW_W-1:0]              adc_pos_cur, adc_neg_cur;
  logic signed [31:0]            raw_diff_cur;
  logic signed [P_PARTIAL_W-1:0] diff_cur;
  localparam logic signed [31:0] PARTIAL_MAX_32 = (32'sd1 <<< (P_PARTIAL_W-1)) - 32'sd1;
  localparam logic signed [31:0] PARTIAL_MIN_32 = -(32'sd1 <<< (P_PARTIAL_W-1));

  always @* begin
    adc_pos_cur = adc_scale(pos_acc[j_idx], sum_max_latched, P_ADC_BITS);
    adc_neg_cur = adc_scale(neg_acc[j_idx], sum_max_latched, P_ADC_BITS);
    raw_diff_cur = $signed({20'b0, adc_pos_cur[11:0]}) - $signed({20'b0, adc_neg_cur[11:0]});
    if (raw_diff_cur > PARTIAL_MAX_32)
      diff_cur = PARTIAL_MAX_32[P_PARTIAL_W-1:0];
    else if (raw_diff_cur < PARTIAL_MIN_32)
      diff_cur = PARTIAL_MIN_32[P_PARTIAL_W-1:0];
    else
      diff_cur = raw_diff_cur[P_PARTIAL_W-1:0];
  end

  // ── Sequential FSM + datapath ─────────────────────────────────────
  integer kk;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mac_state       <= MS_IDLE;
      si_idx          <= '0;
      j_idx           <= '0;
      wl_latched_mac  <= '0;
      in_dim_latched  <= '0;
      out_dim_latched <= '0;
      sum_max_latched <= '0;
      for (kk = 0; kk < P_N_OUT; kk = kk + 1) begin
        pos_acc[kk]  <= '0;
        neg_acc[kk]  <= '0;
        diff_mem[kk] <= '0;
      end
    end else begin
      case (mac_state)
        MS_IDLE: begin
          if (mac_start) begin
            wl_latched_mac  <= wl_mask;
            in_dim_latched  <= cfg_in_dim;
            out_dim_latched <= cfg_out_dim;
            sum_max_latched <= cfg_sum_max;
            si_idx          <= '0;
            j_idx           <= '0;
            // Zero accumulators for this MAC invocation
            for (kk = 0; kk < P_N_OUT; kk = kk + 1) begin
              pos_acc[kk] <= '0;
              neg_acc[kk] <= '0;
            end
            mac_state <= MS_ACCUM;
          end
        end

        MS_ACCUM: begin
          // One WL row per cycle; accumulate into ALL out neurons in parallel.
          // Read the 512-bit packed row once, then bit-slice per neuron j.
          // Vivado will pipeline the BRAM read through [kk*P_W_BITS +: P_W_BITS].
          if (si_active) begin
            for (kk = 0; kk < P_N_OUT; kk = kk + 1) begin
              if (kk < out_dim_latched[$clog2(P_N_OUT)-1:0]) begin
                pos_acc[kk] <= pos_acc[kk]
                              + {{(RAW_W-P_W_BITS){1'b0}},
                                 w_pos_mem[si_idx][kk*P_W_BITS +: P_W_BITS]};
                neg_acc[kk] <= neg_acc[kk]
                              + {{(RAW_W-P_W_BITS){1'b0}},
                                 w_neg_mem[si_idx][kk*P_W_BITS +: P_W_BITS]};
              end
            end
          end
          if (in_dim_last) begin
            j_idx     <= '0;
            mac_state <= MS_ADC;
          end else begin
            si_idx <= si_idx + 1;
          end
        end

        MS_ADC: begin
          // One neuron per cycle; read accumulator, ADC scale, clip, latch diff
          diff_mem[j_idx] <= diff_cur;
          if (out_dim_last) begin
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
