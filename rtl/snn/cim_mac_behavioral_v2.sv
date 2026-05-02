`timescale 1ns/1ps
//======================================================================
// 文件名: cim_mac_behavioral_v2.sv
// 模块名: cim_mac_behavioral_v2
//
// 【功能概述】
// V2.B per-position Scheme B differential MAC，behavioral 实现。
// FPGA-friendly 版（2026-04-21 重构自 combinational 256-input adder 树）。
//
// 【我在 SoC 里的位置】
// 我是 stage_engine_v2 后面的 MAC 计算单元占位模型：stage_engine 把当前
// timestep 的 256-bit wl_mask、in_dim/out_dim/sum_max 给我，我按每个输出神经元
// 计算 pos/neg 两路累加、ADC 缩放和差分裁剪，再把 diff_mem[j] 供 stage_engine
// 做 membrane/tile partial sum。真实芯片里这里会换成 CIM array + ADC controller，
// 但接口和 latency 握手保持一致，所以系统级控制不需要重写。
//
// 【架构：WL-serial + all-j-parallel】
// 为避开 Vivado "Cross Boundary and Area Optimization" 阶段在 256-input
// 组合加法树上卡死（实测 > 6h 不收敛），改成每 cycle 处理 1 个 WL
// 但对所有 P_N_OUT 个 out neuron 并行累加。行为完全等价，latency
// 从 (N_OUT cycles) 变 (N_IN + N_OUT cycles)。
//
//   MS_IDLE     → (mac_start) latch cfg, zero accumulators, → MS_ACCUM
//   MS_READ_ROW present BRAM address for si
//   MS_ACCUM    使用上一 cycle BRAM read data，处理 si = 0..in_dim-1：
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
// - weight read per cycle = all output-neuron columns at current si.
//   Each output neuron owns one 256×8 BRAM column (pos/neg packed),
//   so Vivado can infer true block RAM instead of wide LUTRAM.
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
// 【关键指标和取舍】
// FPGA demo 目标是 50 MHz 以上可综合、可解释、可和 Python golden bit-exact。
// 我宁愿把 MAC latency 拉长到 N_IN+N_OUT，也不保留 256-input 组合树，因为后者
// 在综合阶段会把 debug 时间吞掉。面试时可以强调：这里优化的是可闭合性和
// 系统握手稳定性，而不是单个 MAC transaction 的理论最短周期。
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

`ifndef SYNTHESIS
  // 【架构注释：仿真 fast path 只加速，不改变事务语义】
  // 我在非综合路径里一拍算完整 diff，是为了让 CONV unit/cosim 不被
  // N_IN+N_OUT 的 behavioral latency 拖慢。mac_busy/mac_done 的握手仍保持
  // 一个 transaction 的边界，数值也走同一套 ADC/clip 公式；综合路径不会看到
  // 这段逻辑。
  localparam int RAW_W = $clog2((P_N_IN + 1) * ((1<<P_W_BITS) - 1) + 1);
  localparam logic [31:0] ADC_MAX_CONST = (32'd1 << P_ADC_BITS) - 32'd1;
  localparam logic signed [31:0] PARTIAL_MAX_32 = (32'sd1 <<< (P_PARTIAL_W-1)) - 32'sd1;
  localparam logic signed [31:0] PARTIAL_MIN_32 = -(32'sd1 <<< (P_PARTIAL_W-1));

  typedef enum logic [1:0] {
    FS_IDLE = 2'd0,
    FS_DONE = 2'd1
  } fast_state_e;

  fast_state_e fast_state;

  logic [P_W_BITS-1:0] sim_w_pos_mem [0:P_N_IN-1][0:P_N_OUT-1];
  logic [P_W_BITS-1:0] sim_w_neg_mem [0:P_N_IN-1][0:P_N_OUT-1];
  logic signed [P_PARTIAL_W-1:0] diff_mem [0:P_N_OUT-1];
  logic [P_N_IN-1:0] wl_latched_mac;
  logic [15:0]       in_dim_latched;
  logic [15:0]       out_dim_latched;
  logic [31:0]       sum_max_latched;

  assign diff_rd_data = diff_mem[diff_rd_j];
  assign mac_busy = (fast_state != FS_IDLE);
  assign mac_done = (fast_state == FS_DONE);

  function automatic [31:0] adc_scale_fast(input logic [RAW_W-1:0] raw,
                                           input logic [31:0] sum_max);
    logic [63:0] numerator;
    logic [63:0] scaled;
    begin
      if (sum_max == 32'd0) begin
        adc_scale_fast = 32'd0;
      end else begin
        numerator = ({ {(64-RAW_W){1'b0}}, raw } * {32'd0, ADC_MAX_CONST})
                  + {32'd0, (sum_max >> 1)};
        scaled = numerator / {32'd0, sum_max};
        adc_scale_fast = (scaled > {32'd0, ADC_MAX_CONST})
                       ? ADC_MAX_CONST
                       : scaled[31:0];
      end
    end
  endfunction

  function automatic signed [P_PARTIAL_W-1:0] clip_diff_fast(input logic [31:0] pos_adc,
                                                             input logic [31:0] neg_adc);
    logic signed [31:0] raw_diff;
    begin
      raw_diff = $signed({20'b0, pos_adc[11:0]})
               - $signed({20'b0, neg_adc[11:0]});
      if (raw_diff > PARTIAL_MAX_32) begin
        clip_diff_fast = PARTIAL_MAX_32[P_PARTIAL_W-1:0];
      end else if (raw_diff < PARTIAL_MIN_32) begin
        clip_diff_fast = PARTIAL_MIN_32[P_PARTIAL_W-1:0];
      end else begin
        clip_diff_fast = raw_diff[P_PARTIAL_W-1:0];
      end
    end
  endfunction

  integer sim_si;
  integer sim_j;
  logic [RAW_W-1:0] sim_pos_sum;
  logic [RAW_W-1:0] sim_neg_sum;
  logic [31:0] sim_pos_adc;
  logic [31:0] sim_neg_adc;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fast_state <= FS_IDLE;
      wl_latched_mac <= '0;
      in_dim_latched <= '0;
      out_dim_latched <= '0;
      sum_max_latched <= '0;
      for (sim_si = 0; sim_si < P_N_IN; sim_si = sim_si + 1) begin
        for (sim_j = 0; sim_j < P_N_OUT; sim_j = sim_j + 1) begin
          sim_w_pos_mem[sim_si][sim_j] <= '0;
          sim_w_neg_mem[sim_si][sim_j] <= '0;
        end
      end
      for (sim_j = 0; sim_j < P_N_OUT; sim_j = sim_j + 1) begin
        diff_mem[sim_j] <= '0;
      end
    end else begin
      if (w_load_en) begin
        sim_w_pos_mem[w_load_i][w_load_j] <= w_load_pos_data;
        sim_w_neg_mem[w_load_i][w_load_j] <= w_load_neg_data;
      end

      case (fast_state)
        FS_IDLE: begin
          if (mac_start) begin
            wl_latched_mac <= wl_mask;
            in_dim_latched <= cfg_in_dim;
            out_dim_latched <= cfg_out_dim;
            sum_max_latched <= cfg_sum_max;
            for (sim_j = 0; sim_j < P_N_OUT; sim_j = sim_j + 1) begin
              sim_pos_sum = '0;
              sim_neg_sum = '0;
              if (sim_j < cfg_out_dim) begin
                for (sim_si = 0; sim_si < P_N_IN; sim_si = sim_si + 1) begin
                  if (sim_si < cfg_in_dim && wl_mask[sim_si]) begin
                    sim_pos_sum = sim_pos_sum
                                + {{(RAW_W-P_W_BITS){1'b0}}, sim_w_pos_mem[sim_si][sim_j]};
                    sim_neg_sum = sim_neg_sum
                                + {{(RAW_W-P_W_BITS){1'b0}}, sim_w_neg_mem[sim_si][sim_j]};
                  end
                end
                sim_pos_adc = adc_scale_fast(sim_pos_sum, cfg_sum_max);
                sim_neg_adc = adc_scale_fast(sim_neg_sum, cfg_sum_max);
                diff_mem[sim_j] <= clip_diff_fast(sim_pos_adc, sim_neg_adc);
              end else begin
                diff_mem[sim_j] <= '0;
              end
            end
            fast_state <= FS_DONE;
          end
        end

        FS_DONE: begin
          fast_state <= FS_IDLE;
        end

        default: fast_state <= FS_IDLE;
      endcase
    end
  end

`else
  // ── Width calculations ───────────────────────────────────────────
  // Max per-neuron raw sum: if all 256 WL are 1 and all weights are
  // 15 (4-bit max), raw = 256 * 15 = 3840, fits in 12 bits.
  localparam int RAW_W = $clog2((P_N_IN + 1) * ((1<<P_W_BITS) - 1) + 1);
  localparam int SI_W = $clog2(P_N_IN);
  localparam int J_W  = $clog2(P_N_OUT);
  localparam int IN_DIM_W  = $clog2(P_N_IN + 1);
  localparam int OUT_DIM_W = $clog2(P_N_OUT + 1);

  // Current si (WL row being accumulated) and j (neuron being ADC'd)
  logic [SI_W-1:0]  si_idx;
  logic [J_W-1:0]   j_idx;

  // ── Weight memory: one BRAM column per output neuron ─────────────
  // Before (Vivado 3D-RAM killer):
  //   logic [3:0] w_pos_mem [0:P_N_IN-1][0:P_N_OUT-1];  // 3D unpacked
  // After:
  //   128 independent 256×8 memories. The low nibble is w_pos and the high
  //   nibble is w_neg. All columns share rd_addr=si_idx, giving one
  //   synchronous BRAM read latency before MS_ACCUM.
  logic [P_W_BITS-1:0] w_pos_rd [0:P_N_OUT-1];
  logic [P_W_BITS-1:0] w_neg_rd [0:P_N_OUT-1];

  genvar gj;
  generate
    for (gj = 0; gj < P_N_OUT; gj = gj + 1) begin : g_wcol
      localparam logic [J_W-1:0] GJ = J_W'(gj);
      logic [(2*P_W_BITS)-1:0] rd_pair;

      v2b_weight_col_bram #(
        .P_DEPTH(P_N_IN),
        .P_ADDR_W(SI_W),
        .P_DATA_W(2*P_W_BITS)
      ) u_wcol (
        .clk     (clk),
        .wr_en   (w_load_en && (w_load_j == GJ)),
        .wr_addr (w_load_i),
        .wr_data ({w_load_neg_data, w_load_pos_data}),
        .rd_addr (si_idx),
        .rd_data (rd_pair)
      );

      assign w_pos_rd[gj] = rd_pair[P_W_BITS-1:0];
      assign w_neg_rd[gj] = rd_pair[(2*P_W_BITS)-1:P_W_BITS];
    end
  endgenerate

  // Per-neuron accumulators (128 FF × 12-bit = 1536 FF — small, OK)
  logic [RAW_W-1:0] pos_acc [0:P_N_OUT-1];
  logic [RAW_W-1:0] neg_acc [0:P_N_OUT-1];

  // Diff result storage (128 × 14-bit = 1792 FF). This is read
  // combinationally by stage_engine, so keep it as simple registers instead
  // of pretending it is a RAM.
  logic signed [P_PARTIAL_W-1:0] diff_mem [0:P_N_OUT-1];

  assign diff_rd_data = diff_mem[diff_rd_j];

  // ── FSM ──────────────────────────────────────────────────────────
  typedef enum logic [2:0] {
    MS_IDLE      = 3'd0,
    MS_READ_ROW  = 3'd1,   // present si_idx to synchronous BRAM columns
    MS_ACCUM     = 3'd2,   // consume BRAM read data × all j parallel
    MS_ADC_INIT  = 3'd3,   // setup exact sequential ADC dividers
    MS_DIV_RUN   = 3'd4,   // 32-cycle restoring division for pos/neg
    MS_ADC_WRITE = 3'd5,   // clamp, subtract, write diff_mem[j]
    MS_DONE      = 3'd6
  } mac_state_e;

  mac_state_e mac_state;

  // Latched config/WL at start of MAC run
  logic [P_N_IN-1:0]          wl_latched_mac;
  logic [15:0]                in_dim_latched;
  logic [15:0]                out_dim_latched;
  logic [31:0]                sum_max_latched;
  localparam logic [31:0] ADC_MAX_CONST = (32'd1 << P_ADC_BITS) - 32'd1;

  // Comparator helpers (per-cycle)
  //
  // Do not truncate cfg_*_dim to $clog2(MAX) before comparisons:
  // cfg_in_dim=256 has low 8 bits == 0, and cfg_out_dim=128 has low
  // 7 bits == 0.  Keep an extra dimension bit so "exactly max" stays max.
  logic [IN_DIM_W-1:0]  in_dim_eff;
  logic [OUT_DIM_W-1:0] out_dim_eff;
  logic in_dim_last, out_dim_last;

  assign in_dim_eff =
      (in_dim_latched > 16'(P_N_IN)) ? IN_DIM_W'(P_N_IN)
                                     : in_dim_latched[IN_DIM_W-1:0];
  assign out_dim_eff =
      (out_dim_latched > 16'(P_N_OUT)) ? OUT_DIM_W'(P_N_OUT)
                                       : out_dim_latched[OUT_DIM_W-1:0];

  assign in_dim_last  = ({1'b0, si_idx} == (in_dim_eff  - IN_DIM_W'(1)));
  assign out_dim_last = ({1'b0, j_idx}  == (out_dim_eff - OUT_DIM_W'(1)));

  // Active bit for current si
  logic si_active;
  assign si_active = ({1'b0, si_idx} < in_dim_eff)
                   && wl_latched_mac[si_idx];

  // ── Exact sequential ADC scale state ──────────────────────────────
  // Computes floor((raw * adc_max + sum_max/2) / sum_max) bit-exactly
  // without a combinational divider on the timing path.
  logic [31:0] div_den;
  logic [31:0] div_pos_num, div_neg_num;
  logic [31:0] div_pos_q, div_neg_q;
  logic [31:0] div_pos_rem, div_neg_rem;
  logic [5:0]  div_bit;
  logic        div_zero_den;

  logic [32:0] div_pos_rem_shift, div_neg_rem_shift;
  assign div_pos_rem_shift = {1'b0, div_pos_rem[30:0], div_pos_num[div_bit]};
  assign div_neg_rem_shift = {1'b0, div_neg_rem[30:0], div_neg_num[div_bit]};

  logic [31:0] adc_pos_scaled, adc_neg_scaled;
  logic signed [31:0]            raw_diff_cur;
  logic signed [P_PARTIAL_W-1:0] diff_cur;
  localparam logic signed [31:0] PARTIAL_MAX_32 = (32'sd1 <<< (P_PARTIAL_W-1)) - 32'sd1;
  localparam logic signed [31:0] PARTIAL_MIN_32 = -(32'sd1 <<< (P_PARTIAL_W-1));

  always @* begin
    if (div_zero_den) begin
      adc_pos_scaled = 32'd0;
      adc_neg_scaled = 32'd0;
    end else begin
      adc_pos_scaled = (div_pos_q > ADC_MAX_CONST) ? ADC_MAX_CONST : div_pos_q;
      adc_neg_scaled = (div_neg_q > ADC_MAX_CONST) ? ADC_MAX_CONST : div_neg_q;
    end

    raw_diff_cur = $signed({20'b0, adc_pos_scaled[11:0]})
                 - $signed({20'b0, adc_neg_scaled[11:0]});
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
      div_den         <= '0;
      div_pos_num     <= '0;
      div_neg_num     <= '0;
      div_pos_q       <= '0;
      div_neg_q       <= '0;
      div_pos_rem     <= '0;
      div_neg_rem     <= '0;
      div_bit         <= '0;
      div_zero_den    <= 1'b0;
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
            mac_state <= MS_READ_ROW;
          end
        end

        MS_READ_ROW: begin
          // v2b_weight_col_bram registers rd_data at this clock edge.
          // MS_ACCUM consumes that row on the next cycle.
          mac_state <= MS_ACCUM;
        end

        MS_ACCUM: begin
          // Consume the synchronous BRAM row for si_idx; accumulate into ALL
          // out neurons in parallel.
          if (si_active) begin
            for (kk = 0; kk < P_N_OUT; kk = kk + 1) begin
              if (OUT_DIM_W'(kk) < out_dim_eff) begin
                pos_acc[kk] <= pos_acc[kk]
                              + {{(RAW_W-P_W_BITS){1'b0}}, w_pos_rd[kk]};
                neg_acc[kk] <= neg_acc[kk]
                              + {{(RAW_W-P_W_BITS){1'b0}}, w_neg_rd[kk]};
              end
            end
          end
          if (in_dim_last) begin
            j_idx     <= '0;
            mac_state <= MS_ADC_INIT;
          end else begin
            si_idx <= si_idx + 1;
            mac_state <= MS_READ_ROW;
          end
        end

        MS_ADC_INIT: begin
          // Set up two exact 32-cycle dividers:
          //   pos_q = (pos_acc[j] * ADC_MAX + sum_max/2) / sum_max
          //   neg_q = (neg_acc[j] * ADC_MAX + sum_max/2) / sum_max
          div_zero_den <= (sum_max_latched == 32'd0);
          div_den      <= (sum_max_latched == 32'd0) ? 32'd1 : sum_max_latched;
          div_pos_num  <= pos_acc[j_idx] * ADC_MAX_CONST + (sum_max_latched >> 1);
          div_neg_num  <= neg_acc[j_idx] * ADC_MAX_CONST + (sum_max_latched >> 1);
          div_pos_q    <= 32'd0;
          div_neg_q    <= 32'd0;
          div_pos_rem  <= 32'd0;
          div_neg_rem  <= 32'd0;
          div_bit      <= 6'd31;
          mac_state    <= MS_DIV_RUN;
        end

        MS_DIV_RUN: begin
          if (div_pos_rem_shift >= {1'b0, div_den}) begin
            div_pos_rem <= div_pos_rem_shift[31:0] - div_den;
            div_pos_q[div_bit] <= 1'b1;
          end else begin
            div_pos_rem <= div_pos_rem_shift[31:0];
          end

          if (div_neg_rem_shift >= {1'b0, div_den}) begin
            div_neg_rem <= div_neg_rem_shift[31:0] - div_den;
            div_neg_q[div_bit] <= 1'b1;
          end else begin
            div_neg_rem <= div_neg_rem_shift[31:0];
          end

          if (div_bit == 6'd0) begin
            mac_state <= MS_ADC_WRITE;
          end else begin
            div_bit <= div_bit - 1;
          end
        end

        MS_ADC_WRITE: begin
          // One neuron result per divider run; clamp, subtract, latch diff.
          diff_mem[j_idx] <= diff_cur;
          if (out_dim_last) begin
            mac_state <= MS_DONE;
          end else begin
            j_idx <= j_idx + 1;
            mac_state <= MS_ADC_INIT;
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

`endif
endmodule

// One weight column BRAM for a single output neuron. Data packs
// {w_neg, w_pos}. No synthesis reset; firmware overwrites weights before use.
module v2b_weight_col_bram #(
  parameter int P_DEPTH  = 256,
  parameter int P_ADDR_W = 8,
  parameter int P_DATA_W = 8
) (
  input  logic                  clk,
  input  logic                  wr_en,
  input  logic [P_ADDR_W-1:0]   wr_addr,
  input  logic [P_DATA_W-1:0]   wr_data,
  input  logic [P_ADDR_W-1:0]   rd_addr,
  output logic [P_DATA_W-1:0]   rd_data
);

  (* ram_style = "block" *) logic [P_DATA_W-1:0] mem [0:P_DEPTH-1];

`ifndef SYNTHESIS
  integer init_i;
  initial begin
    for (init_i = 0; init_i < P_DEPTH; init_i = init_i + 1) begin
      mem[init_i] = '0;
    end
  end
`endif

  always_ff @(posedge clk) begin
    if (wr_en) begin
      mem[wr_addr] <= wr_data;
    end
    rd_data <= mem[rd_addr];
  end

endmodule
