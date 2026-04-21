`timescale 1ns/1ps
//======================================================================
// 文件名: stage_engine_v2.sv
// 模块名: stage_engine_v2
//
// 【功能概述】
// V2.B REV 3.3 核心 primitive：`run_streamed_stage`。接收 CPU 配置的
// stage descriptor（input_src / output_dst / in_dim / out_dim /
// threshold / sum_max / tile_mode / is_tile_final），读 input buffer
// 每 timestep 的 wl_mask，驱动 CIM 做 binary MAC，收 ADC diff，根据
// tile_mode 决定：
//   (a) tile_mode=0：membrane 累加 + LIF 发射 + 写 output stream_buffer
//   (b) tile_mode=1：累加到 tile_partial_buf[t][j]，不 LIF
// 最后 is_tile_final=1 时额外做 LIF sweep（扫描 tile_partial_buf）。
//
// 【V0 设计说明（本文件）】
// - 本 V0 skeleton **不集成真实 CIM 宏**，使用一个行为 MAC 占位：
//     behavioral_diff[j] = signed(popcount(wl_mask) × (weight_base[j] - neg_base[j]))
//   目的：让 FSM / handshake / 存储 orchestration 先跑起来。B2 阶段
//   会把 behavioral_mac 替换为 cim_array_ctrl + adc_ctrl 的真实 path。
// - tile_mode=1 的 partial-sum 累加路径在 V0 已经线下通路；验证用简化
//   TB 覆盖 tile_mode=0 流程优先。
//
// 【寄存器接口（B0 §B0.1）】
//   由 reg_bank 将下面端口映射到 offset 0x50-0x6F。本模块不直接处理
//   总线，所有配置通过顶层 snn_soc_top 透传过来。
//
// 【FSM】
//   IDLE  → (start) SETUP  → READ_WL → MAC_WAIT → ACCUM → [tile_mode?]
//         tile_mode=0: LIF_FIRE → WRITE_SPIKE → NEXT_T / DONE
//         tile_mode=1: WRITE_PARTIAL → NEXT_T → FINAL_LIF → DONE
//
// 【错误码（写回 err_code 端口）】
//   V2B_STAGE_ERR_START_WHILE_BUSY  当 START 触发时 busy=1
//   V2B_STAGE_ERR_SRC_DST_CONFLICT  input_src 和 output_dst 指同一 buffer
//   V2B_STAGE_ERR_DIM_OUT_OF_RANGE  in_dim 或 out_dim 越界
//======================================================================
module stage_engine_v2
  import snn_soc_pkg::*;
#(
  parameter int P_T_MAX = V2B_MAX_TIMESTEPS,      // 256
  parameter int P_N_IN  = V2B_NUM_INPUTS,         // 256
  parameter int P_N_OUT = V2B_MAX_OUT_NEURONS,    // 128
  parameter int P_PARTIAL_W = V2B_PARTIAL_WIDTH,  // 14
  parameter int P_MEM_W = V2B_LIF_MEM_WIDTH       // 32
) (
  input  logic clk,
  input  logic rst_n,

  // ── CPU control (maps to reg_bank STAGE_CTRL / STAGE_CFG0-5) ───────
  input  logic start_pulse,
  output logic busy,
  output logic done_pulse,
  output logic [7:0] err_code,
  output logic [$clog2(P_T_MAX)-1:0] debug_t_idx,

  input  logic [15:0] cfg_in_dim,                 // 1..P_N_IN
  input  logic [15:0] cfg_out_dim,                // 1..P_N_OUT
  input  logic [31:0] cfg_threshold,
  input  logic [31:0] cfg_sum_max,                // unused in V0 behavioral MAC
  input  logic [1:0]  cfg_input_src,              // V2B_BUF_SEL_*
  input  logic [1:0]  cfg_output_dst,             // V2B_BUF_SEL_*
  input  logic        cfg_tile_mode,
  input  logic        cfg_is_tile_final,
  input  logic        cfg_preserve_membrane,
  input  logic [15:0] cfg_t_count,                // actual T for this run (<= P_T_MAX)

  // ── input_stream_sram read port ────────────────────────────────────
  output logic                         isr_rd_en,
  output logic [$clog2(P_T_MAX)-1:0]   isr_rd_addr,
  input  logic [P_N_IN-1:0]            isr_rd_data,

  // ── stream_buffer_v2 A write port ──────────────────────────────────
  output logic                         sbA_wr_en,
  output logic [$clog2(P_T_MAX)-1:0]   sbA_wr_addr,
  output logic [P_N_OUT-1:0]           sbA_wr_data,

  // ── stream_buffer_v2 B write port ──────────────────────────────────
  output logic                         sbB_wr_en,
  output logic [$clog2(P_T_MAX)-1:0]   sbB_wr_addr,
  output logic [P_N_OUT-1:0]           sbB_wr_data,

  // ── stream_buffer_v2 A/B read port ─────────────────────────────────
  output logic                         sbA_rd_en,
  output logic [$clog2(P_T_MAX)-1:0]   sbA_rd_addr,
  input  logic [P_N_OUT-1:0]           sbA_rd_data,
  output logic                         sbB_rd_en,
  output logic [$clog2(P_T_MAX)-1:0]   sbB_rd_addr,
  input  logic [P_N_OUT-1:0]           sbB_rd_data,

  // ── tile_partial_buf acc/read ports (V0: accumulate + final LIF) ───
  output logic                         tpb_clear_all,
  output logic                         tpb_acc_en,
  output logic [$clog2(P_T_MAX)-1:0]   tpb_wr_t,
  output logic [$clog2(P_N_OUT)-1:0]   tpb_wr_j,
  output logic signed [P_PARTIAL_W-1:0] tpb_wr_diff,
  output logic                         tpb_rd_en,
  output logic [$clog2(P_T_MAX)-1:0]   tpb_rd_t,
  output logic [$clog2(P_N_OUT)-1:0]   tpb_rd_j,
  input  logic signed [P_PARTIAL_W-1:0] tpb_rd_data,

  // ── MAC coupling (external cim_mac_behavioral_v2 or real cim_array_ctrl) ─
  // The stage engine issues mac_start once wl_latched is ready. It then
  // waits for mac_done, after which it reads per-neuron diff via
  // mac_diff_rd_data indexed by mac_diff_rd_j = j_idx.
  output logic                              mac_start,
  input  logic                              mac_done,
  input  logic                              mac_busy,
  output logic [P_N_IN-1:0]                 mac_wl_mask,
  output logic [15:0]                       mac_cfg_in_dim,
  output logic [15:0]                       mac_cfg_out_dim,
  output logic [31:0]                       mac_cfg_sum_max,
  output logic [$clog2(P_N_OUT)-1:0]        mac_diff_rd_j,
  input  logic signed [P_PARTIAL_W-1:0]     mac_diff_rd_data
);

  // ── FSM state encoding ─────────────────────────────────────────────
  typedef enum logic [4:0] {
    S_IDLE       = 5'd0,
    S_SETUP      = 5'd1,
    S_CLEAR_TPB  = 5'd2,
    S_READ_WL    = 5'd3,
    S_MAC_WAIT   = 5'd4,
    S_MAC_LATCH  = 5'd5,
    S_MAC_KICK   = 5'd6,
    S_MAC_RUN    = 5'd7,
    S_NEURON_LOOP= 5'd8,
    S_NEXT_T     = 5'd9,
    S_FINAL_LIF  = 5'd10,
    S_FINAL_READ = 5'd11,
    S_FINAL_WAIT = 5'd12,
    S_FINAL_NEURON = 5'd13,
    S_FINAL_WRITE= 5'd14,   // write sbA after last_j's spike_this_t NBA lands
    S_DONE       = 5'd15
  } state_e;

  state_e state, next_state;

  logic [$clog2(P_T_MAX)-1:0] t_idx;
  logic [$clog2(P_N_OUT)-1:0] j_idx;
  logic signed [P_MEM_W-1:0]  membrane [0:P_N_OUT-1];
  logic [P_N_OUT-1:0]         spike_this_t;
  logic                       write_to_A;

  // Wire MAC coupling out of FSM
  logic [P_N_IN-1:0]           wl_latched;
  assign debug_t_idx = t_idx;
  assign mac_wl_mask     = wl_latched;
  assign mac_cfg_in_dim  = cfg_in_dim;
  assign mac_cfg_out_dim = cfg_out_dim;
  assign mac_cfg_sum_max = cfg_sum_max;
  assign mac_diff_rd_j   = j_idx;

  // Diff used by S_NEURON_LOOP / S_FINAL_NEURON (combinational from external MAC)
  logic signed [P_PARTIAL_W-1:0] mac_diff_used;
  assign mac_diff_used = mac_diff_rd_data;

  // Determine output buffer
  assign write_to_A = (cfg_output_dst == V2B_BUF_SEL_STREAM_A);

  // ── Comparators (avoid Icarus "constant select" issues) ──────────────
  localparam int OUT_DIM_W = $clog2(P_N_OUT + 1);
  localparam int T_DIM_W   = $clog2(P_T_MAX + 1);
  logic [$clog2(P_N_OUT)-1:0] out_dim_minus1;
  logic [$clog2(P_T_MAX)-1:0] t_count_minus1;
  logic [OUT_DIM_W-1:0] out_dim_eff;
  logic [T_DIM_W-1:0]   t_count_eff;

  assign out_dim_eff =
      (cfg_out_dim > 16'(P_N_OUT)) ? OUT_DIM_W'(P_N_OUT)
                                   : cfg_out_dim[OUT_DIM_W-1:0];
  assign t_count_eff =
      (cfg_t_count > 16'(P_T_MAX)) ? T_DIM_W'(P_T_MAX)
                                   : cfg_t_count[T_DIM_W-1:0];
  assign out_dim_minus1 = out_dim_eff - OUT_DIM_W'(1);
  assign t_count_minus1 = t_count_eff - T_DIM_W'(1);
  logic last_j, last_t;
  assign last_j = (j_idx == out_dim_minus1);
  assign last_t = (t_idx == t_count_minus1);

  // ── Next-state logic ───────────────────────────────────────────────
  always_comb begin
    next_state = state;
    case (state)
      S_IDLE:         if (start_pulse) next_state = S_SETUP;
      S_SETUP: begin
                      // tile_mode no longer auto-clears tile_partial_buf:
                      // firmware must issue STREAM_BUF_CTRL.CLEAR_TILE_BUF
                      // before the first tile of a multi-tile stage.
                      // Single-tile demo (tile_mode=0) doesn't use tpb.
                      next_state = S_READ_WL;
                     end
      S_CLEAR_TPB:    next_state = S_READ_WL;   // kept for backward compat; unreachable
      S_READ_WL:      next_state = S_MAC_WAIT;
      S_MAC_WAIT:     next_state = S_MAC_LATCH;
      S_MAC_LATCH:    next_state = S_MAC_KICK;
      S_MAC_KICK:     next_state = S_MAC_RUN;
      S_MAC_RUN:      if (mac_done) next_state = S_NEURON_LOOP;
      S_NEURON_LOOP:  if (last_j) next_state = S_NEXT_T;
      S_NEXT_T: begin
        if (last_t) begin
          if (cfg_tile_mode && cfg_is_tile_final) next_state = S_FINAL_LIF;
          else                                    next_state = S_DONE;
        end else begin
          next_state = S_READ_WL;
        end
      end
      S_FINAL_LIF:    next_state = S_FINAL_READ;
      S_FINAL_READ:   next_state = S_FINAL_WAIT;
      S_FINAL_WAIT:   next_state = S_FINAL_NEURON;
      S_FINAL_NEURON: begin
        if (last_j) next_state = S_FINAL_WRITE;    // commit spike_this_t update first
        else        next_state = S_FINAL_READ;
      end
      S_FINAL_WRITE: begin
        if (last_t) next_state = S_DONE;
        else        next_state = S_FINAL_READ;
      end
      S_DONE:         next_state = S_IDLE;
      default:        next_state = S_IDLE;
    endcase
  end

  // ── Sequential state update + datapath ─────────────────────────────
  integer k;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state        <= S_IDLE;
      t_idx        <= '0;
      j_idx        <= '0;
      busy         <= 1'b0;
      done_pulse   <= 1'b0;
      err_code     <= V2B_STAGE_ERR_OK;
      spike_this_t <= '0;
      wl_latched   <= '0;
      for (k = 0; k < P_N_OUT; k++) membrane[k] <= '0;

      mac_start <= 1'b0;
      isr_rd_en  <= 1'b0; isr_rd_addr <= '0;
      sbA_wr_en  <= 1'b0; sbA_wr_addr <= '0; sbA_wr_data <= '0;
      sbB_wr_en  <= 1'b0; sbB_wr_addr <= '0; sbB_wr_data <= '0;
      sbA_rd_en  <= 1'b0; sbA_rd_addr <= '0;
      sbB_rd_en  <= 1'b0; sbB_rd_addr <= '0;
      tpb_clear_all <= 1'b0;
      tpb_acc_en <= 1'b0; tpb_wr_t <= '0; tpb_wr_j <= '0; tpb_wr_diff <= '0;
      tpb_rd_en  <= 1'b0; tpb_rd_t <= '0; tpb_rd_j <= '0;
    end else begin
      // default pulses
      done_pulse    <= 1'b0;
      isr_rd_en     <= 1'b0;
      sbA_rd_en     <= 1'b0;
      sbB_rd_en     <= 1'b0;
      sbA_wr_en     <= 1'b0;
      sbB_wr_en     <= 1'b0;
      tpb_acc_en    <= 1'b0;
      tpb_rd_en     <= 1'b0;
      tpb_clear_all <= 1'b0;
      mac_start     <= 1'b0;

      state <= next_state;

      case (state)
        S_IDLE: begin
          if (start_pulse) begin
            // validate config
            if (cfg_in_dim == 0 || cfg_in_dim > 16'(P_N_IN) ||
                cfg_out_dim == 0 || cfg_out_dim > 16'(P_N_OUT) ||
                cfg_t_count == 0 || cfg_t_count > 16'(P_T_MAX)) begin
              err_code <= V2B_STAGE_ERR_DIM_OUT_OF_RANGE;
              done_pulse <= 1'b1;  // reject, stay IDLE via default transition
            end else if (cfg_input_src == cfg_output_dst &&
                         cfg_output_dst != V2B_BUF_SEL_OUTPUT_FIFO) begin
              err_code <= V2B_STAGE_ERR_SRC_DST_CONFLICT;
              done_pulse <= 1'b1;
            end else begin
              err_code <= V2B_STAGE_ERR_OK;
              busy <= 1'b1;
              t_idx <= '0;
              j_idx <= '0;
              spike_this_t <= '0;
              if (!cfg_preserve_membrane) begin
                for (k = 0; k < P_N_OUT; k++) membrane[k] <= '0;
              end
            end
          end
        end

        S_SETUP: begin
          // in V0 setup is a single pass-through cycle
        end

        S_CLEAR_TPB: begin
          tpb_clear_all <= 1'b1;
        end

        S_READ_WL: begin
          // Pulse the read-enable of the selected input buffer.
          case (cfg_input_src)
            V2B_BUF_SEL_INPUT_SRAM: begin
              isr_rd_en   <= 1'b1;
              isr_rd_addr <= t_idx;
            end
            V2B_BUF_SEL_STREAM_A: begin
              sbA_rd_en   <= 1'b1;
              sbA_rd_addr <= t_idx;
            end
            V2B_BUF_SEL_STREAM_B: begin
              sbB_rd_en   <= 1'b1;
              sbB_rd_addr <= t_idx;
            end
            default: begin end
          endcase
        end

        S_MAC_WAIT: begin
          // SRAM rd_en went high this cycle (due to S_READ_WL NBA).
          // rd_data will be valid NEXT cycle.
          j_idx <= '0;
        end

        S_MAC_LATCH: begin
          // Now rd_data from the selected buffer is valid; latch it.
          case (cfg_input_src)
            V2B_BUF_SEL_INPUT_SRAM:
              wl_latched <= isr_rd_data;
            V2B_BUF_SEL_STREAM_A:
              // stream_buffer is P_N_OUT wide (128), wl_latched is P_N_IN (256).
              // Zero-pad upper bits; MAC's wl_mask[i] for i>=cfg_in_dim is
              // ignored anyway (gated by in_dim_latched).
              wl_latched <= { {(P_N_IN - P_N_OUT){1'b0}}, sbA_rd_data };
            V2B_BUF_SEL_STREAM_B:
              wl_latched <= { {(P_N_IN - P_N_OUT){1'b0}}, sbB_rd_data };
            default:
              wl_latched <= '0;
          endcase
        end

        S_MAC_KICK: begin
          // Pulse mac_start for one cycle; external cim_mac_behavioral_v2
          // will then compute per-neuron diff in parallel of out_dim cycles.
          mac_start <= 1'b1;
          j_idx <= '0;
        end

        S_MAC_RUN: begin
          // Wait for external MAC to finish. mac_done asserts for 1 cycle.
          // Nothing to drive here; FSM transitions via next_state logic.
          // j_idx already reset in S_MAC_KICK, so S_NEURON_LOOP starts at j=0.
        end

        S_NEURON_LOOP: begin
          // mac_diff_used is combinational from external cim_mac_behavioral_v2
          // indexed by mac_diff_rd_j = j_idx.
          if (cfg_tile_mode) begin
            // accumulate into tile_partial_buf[t][j]
            tpb_acc_en  <= 1'b1;
            tpb_wr_t    <= t_idx;
            tpb_wr_j    <= j_idx;
            tpb_wr_diff <= mac_diff_used;
          end else begin
            // accumulate membrane, fire LIF
            if ((membrane[j_idx] + $signed({{(P_MEM_W-P_PARTIAL_W){mac_diff_used[P_PARTIAL_W-1]}}, mac_diff_used})) >= $signed(cfg_threshold)) begin
              spike_this_t[j_idx] <= 1'b1;
              membrane[j_idx] <= membrane[j_idx] + $signed({{(P_MEM_W-P_PARTIAL_W){mac_diff_used[P_PARTIAL_W-1]}}, mac_diff_used}) - $signed(cfg_threshold);
            end else begin
              spike_this_t[j_idx] <= 1'b0;
              membrane[j_idx] <= membrane[j_idx] + $signed({{(P_MEM_W-P_PARTIAL_W){mac_diff_used[P_PARTIAL_W-1]}}, mac_diff_used});
            end
          end
          j_idx <= j_idx + 1;
        end

        S_NEXT_T: begin
          // Write spike_this_t → output stream buffer
          if (!cfg_tile_mode) begin
            if (write_to_A) begin
              sbA_wr_en   <= 1'b1;
              sbA_wr_addr <= t_idx;
              sbA_wr_data <= spike_this_t;
            end else begin
              sbB_wr_en   <= 1'b1;
              sbB_wr_addr <= t_idx;
              sbB_wr_data <= spike_this_t;
            end
          end
          spike_this_t <= '0;
          if (last_t) begin
            t_idx <= '0;
            j_idx <= '0;
          end else begin
            t_idx <= t_idx + 1;
          end
        end

        // ── tile_mode final LIF sweep over tile_partial_buf ───────────
        S_FINAL_LIF: begin
          t_idx <= '0; j_idx <= '0;
          for (k = 0; k < P_N_OUT; k++) membrane[k] <= '0;
        end

        S_FINAL_READ: begin
          tpb_rd_en <= 1'b1;
          tpb_rd_t  <= t_idx;
          tpb_rd_j  <= j_idx;
        end

        S_FINAL_NEURON: begin
          // accumulate + fire using tpb_rd_data
          if ((membrane[j_idx] + $signed({{(P_MEM_W-P_PARTIAL_W){tpb_rd_data[P_PARTIAL_W-1]}}, tpb_rd_data})) >= $signed(cfg_threshold)) begin
            spike_this_t[j_idx] <= 1'b1;
            membrane[j_idx] <= membrane[j_idx] + $signed({{(P_MEM_W-P_PARTIAL_W){tpb_rd_data[P_PARTIAL_W-1]}}, tpb_rd_data}) - $signed(cfg_threshold);
          end else begin
            spike_this_t[j_idx] <= 1'b0;
            membrane[j_idx] <= membrane[j_idx] + $signed({{(P_MEM_W-P_PARTIAL_W){tpb_rd_data[P_PARTIAL_W-1]}}, tpb_rd_data});
          end
          if (last_j) begin
            // spike_this_t[last_j] just updated above (NBA); S_FINAL_WRITE
            // will commit it to sbA next cycle (after NBA lands).
            j_idx <= '0;
          end else begin
            j_idx <= j_idx + 1;
          end
        end

        S_FINAL_WRITE: begin
          // spike_this_t NBAs from the previous S_FINAL_NEURON (including
          // last_j update) are now visible. Issue the stream buffer write.
          if (write_to_A) begin
            sbA_wr_en   <= 1'b1;
            sbA_wr_addr <= t_idx;
            sbA_wr_data <= spike_this_t;
          end else begin
            sbB_wr_en   <= 1'b1;
            sbB_wr_addr <= t_idx;
            sbB_wr_data <= spike_this_t;
          end
          spike_this_t <= '0;
          if (!last_t) begin
            t_idx <= t_idx + 1;
          end
        end

        S_DONE: begin
          busy <= 1'b0;
          done_pulse <= 1'b1;
        end

        default: ;
      endcase
    end
  end

endmodule
