// -----------------------------------------------------------------------------
// 自动文档头：本文件的可读性说明（仅注释说明，不改变任何逻辑）
// 文件路径：rtl/snn/trace_hash_recorder.sv
// 作用：M1 trace-hash recorder（Path B paper add-on #1）的硬件实现。
// 系统角色：sidecar 模块，挂在 stage_engine_v2 的 spike-commit 边界，监听
//           (sbA_wr_en | sbB_wr_en) 拍 CRC-32 指纹存进 BRAM，host 通过
//           CSR 读出后做跨 host (ARM ↔ E203) 一致性校验。
// 行为性质：cfg_recorder_en=0 时完全 sidecar，零反向驱动 stage_engine。
// 项目规则：本文件 Day Tue 完整实现 hash compute + BRAM write + layer-id drift
//           + 读 BRAM tap；Day Mon skeleton 已 PASS。Day Wed 才碰 top wiring。
// 集成提示：实例化和 CSR decode 见 snn_soc_v2b_top.sv（Day Wed 引入）。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: trace_hash_recorder.sv
// 模块名: trace_hash_recorder
//
// 【功能概述】
// 监听 stage_engine_v2 的 spike-commit pulse (sbA_wr_en | sbB_wr_en)，
// 把 {layer_id, buf_sel, t_idx, spike_vec} 联合算 CRC-32-IEEE，
// 32-bit hash + 16-bit metadata 存进 BRAM。host 通过 CSR (TRACE_HASH_A_*)
// 设置 read address 后读出 hash + meta，UART dump 给 Python diff 工具做
// 跨 host 比对。详见 essay/m1_design_doc_2026_05_05.md (Codex Phase 0 PASS)。
//
// 【Day Tue (本 commit) 完整实现范围】
// - CRC-32-IEEE reflected 组合函数 crc32_compute（bit-serial 展开成组合逻辑）
// - hash compute + BRAM write 主路径（cfg_recorder_en && spike_commit_valid）
// - log_count_q 自增 + log_overflow_q sticky
// - Layer-ID drift detector (option C: firmware 写 + RTL sticky fault)
// - Read port BRAM tap (rd_en -> next-cycle rd_data_q / rd_meta_q latched)
// - SVA-1/2/3 真实 ifdef VCS assert property 块
//
// 【硬约束（Codex Phase 0 review 拍板）】
// 1. cfg_recorder_en = 0 时 recorder 不写 BRAM，不抬 log_count，不抬 sticky
// 2. cfg_recorder_clear W1P 清 log_count / overflow / layer_id_fault，但**不清 BRAM**
// 3. spike_commit_valid 拍点只在 cfg_recorder_en=1 时被消化
// 4. layer_id 在同一 stage 内变化即抬 layer_id_fault sticky
// 5. log_count >= P_LOG_DEPTH 时 reject 写 + 抬 log_overflow，不阻塞 stage_engine
//
// 【Hash 输入位宽 NOTE】
// Day Mon 用 default P_LAYER_MAX=8 / P_T_MAX=256 / P_N_OUT=128 时，
// 联合输入 = $clog2(8) + 1 + $clog2(256) + 128 = 3 + 1 + 8 + 128 = **140 bits**。
// design doc §1.1 写"137 bits"是 doc 旧版 typo（编写时假设其它参数）。
// 实际 RTL 以 parameter 推算为准。Codex Day Tue review 时同步修 doc。
//
// 【后续 Phase 边界（绝不在 Day Tue 落地）】
// - 不实例化进 snn_soc_v2b_top.sv (Day Wed)
// - 不 wire 到 stage_engine_v2 的 sbA/sbB (Day Wed)
// - 不动 byte-mask invariant TB (Day Wed)
// - 不写 firmware helper (Day Thu/Fri)
//======================================================================

module trace_hash_recorder
  import trace_hash_recorder_pkg::*;
#(
  parameter int P_N_OUT     = TRACE_HASH_P_N_OUT_DEFAULT,     // = V2B_MAX_OUT_NEURONS = 128
  parameter int P_T_MAX     = TRACE_HASH_P_T_MAX_DEFAULT,     // = V2B_MAX_TIMESTEPS = 256
  parameter int P_LAYER_MAX = TRACE_HASH_P_LAYER_MAX_DEFAULT, // = 8
  parameter int P_LOG_DEPTH = TRACE_HASH_P_LOG_DEPTH_DEFAULT  // = 2048
) (
  input  logic                                  clk,
  input  logic                                  rst_n,

  // ---- Enable / control (default off = backward-compat) ----
  input  logic                                  cfg_recorder_en,        // 1 = record; 0 = no-op (datapath untouched)
  input  logic                                  cfg_recorder_clear,     // W1P from CSR: clears log_count + sticky

  // ---- Tap point: spike vector + timestep + buffer-select + layer id ----
  input  logic                                  spike_commit_valid,     // = (sbA_wr_en | sbB_wr_en) from stage_engine_v2
  input  logic [P_N_OUT-1:0]                    spike_commit_data,      // = sbA_wr_data or sbB_wr_data (mux upstream)
  input  logic [$clog2(P_T_MAX)-1:0]            spike_commit_t_idx,     // = sbA_wr_addr or sbB_wr_addr
  input  logic                                  spike_commit_buf_sel,   // 0=A, 1=B
  input  logic [$clog2(P_LAYER_MAX)-1:0]        spike_commit_layer_id,  // host-supplied via CSR, latched per stage start

  // ---- CSR-readable status ----
  output logic [TRACE_HASH_LOG_COUNT_W-1:0]     log_count,              // # of (layer, t) hash entries logged so far
  output logic                                  log_overflow,           // sticky: tried to write past P_LOG_DEPTH
  output logic                                  layer_id_fault,         // sticky: layer_id drifted within one stage

  // ---- BRAM read port (host CSR-mediated readback) ----
  input  logic                                  rd_en,
  input  logic [$clog2(P_LOG_DEPTH)-1:0]        rd_addr,
  output logic [31:0]                           rd_data,
  output logic [TRACE_HASH_META_PACKED_W-1:0]   rd_meta
);

  // ──────────────────────────────────────────────────────────────────────────
  // 0. Derived widths
  // ──────────────────────────────────────────────────────────────────────────
  localparam int LAYER_ID_W = $clog2(P_LAYER_MAX);
  localparam int T_IDX_W    = $clog2(P_T_MAX);
  localparam int LOG_ADDR_W = $clog2(P_LOG_DEPTH);
  localparam int HASH_INPUT_W = LAYER_ID_W + 1 + T_IDX_W + P_N_OUT;
  // For default (3 + 1 + 8 + 128) = 140 bits

  // ──────────────────────────────────────────────────────────────────────────
  // 1. CRC-32-IEEE reflected combinational compute
  // ──────────────────────────────────────────────────────────────────────────
  //
  // Algorithm (matches IEEE-802.3 standard reflected-CRC32):
  //   crc = INIT (0xFFFFFFFF)
  //   for each bit of input from LSB to MSB:
  //     feedback = crc[0] XOR bit
  //     crc      = (crc >> 1) XOR (feedback ? POLY_REFLECTED : 0)
  //   return crc XOR XOROUT (0xFFFFFFFF)
  //
  // The for-loop is unrolled by the synthesizer into a fixed combinational
  // network whose depth grows with HASH_INPUT_W. Day Tue keeps this purely
  // combinational; Day Wed integration must still check post-synth timing
  // before claiming the sidecar is timing-neutral at 100 MHz.

  function automatic logic [31:0] crc32_compute(input logic [HASH_INPUT_W-1:0] data);
    logic [31:0] crc;
    logic        feedback;
    begin
      crc = TRACE_HASH_CRC32_INIT;
      for (int i = 0; i < HASH_INPUT_W; i++) begin
        feedback = crc[0] ^ data[i];
        crc      = (crc >> 1) ^ (feedback ? TRACE_HASH_CRC32_POLY_REFLECTED : 32'h0);
      end
      crc32_compute = crc ^ TRACE_HASH_CRC32_XOROUT;
    end
  endfunction

  // Concatenated input for the current spike_commit pulse.
  // Bit order is {layer_id, buf_sel, t_idx, spike_data}:
  //   [HASH_INPUT_W-1 : HASH_INPUT_W-LAYER_ID_W]   layer_id
  //   [HASH_INPUT_W-LAYER_ID_W-1]                  buf_sel
  //   [HASH_INPUT_W-LAYER_ID_W-2 : P_N_OUT]        t_idx
  //   [P_N_OUT-1 : 0]                              spike_data
  // CRC processes from bit 0 upward, so spike_data goes in first.
  logic [HASH_INPUT_W-1:0] hash_input_w;
  assign hash_input_w = {spike_commit_layer_id,
                         spike_commit_buf_sel,
                         spike_commit_t_idx,
                         spike_commit_data};

  logic [31:0] hash_combinational;
  assign hash_combinational = crc32_compute(hash_input_w);

  // ──────────────────────────────────────────────────────────────────────────
  // 2. Internal state declarations
  // ──────────────────────────────────────────────────────────────────────────

  // BRAM: 2048 entries × 48 bits (32 hash + 16 meta).
  // Use two separate arrays so synth can lift each into its own BRAM slice.
  logic [31:0]                              hash_mem [0:P_LOG_DEPTH-1];
  logic [TRACE_HASH_META_PACKED_W-1:0]      meta_mem [0:P_LOG_DEPTH-1];

  // Counters / sticky status
  logic [TRACE_HASH_LOG_COUNT_W-1:0]        log_count_q;
  logic                                     log_overflow_q;
  logic                                     layer_id_fault_q;
  logic                                     cfg_recorder_en_q;

  // Layer-ID drift detector
  logic                                     first_commit_seen_q;
  logic [LAYER_ID_W-1:0]                    layer_id_lock_q;

  // Read-side latency-1 register (write 0x070 -> next MMIO read 0x074/0x078)
  logic [31:0]                              rd_data_q;
  logic [TRACE_HASH_META_PACKED_W-1:0]      rd_meta_q;

  // ──────────────────────────────────────────────────────────────────────────
  // 3. Output wiring
  // ──────────────────────────────────────────────────────────────────────────

  assign log_count       = TRACE_HASH_LOG_COUNT_W'(log_count_q);
  assign log_overflow    = log_overflow_q;
  assign layer_id_fault  = layer_id_fault_q;
  assign rd_data         = rd_data_q;
  assign rd_meta         = rd_meta_q;

  // ──────────────────────────────────────────────────────────────────────────
  // 4. Main always_ff: reset / clear / sidecar / write path
  // ──────────────────────────────────────────────────────────────────────────
  //
  // Behavior priority (highest first):
  //   1) async reset_n=0       -> all status cleared
  //   2) cfg_recorder_clear=1  -> log_count_q + sticky cleared (BRAM intact)
  //   3) cfg_recorder_en=1
  //      AND spike_commit_valid=1
  //      AND !log_overflow_q   -> compute hash, write BRAM, advance counter
  //   4) otherwise              -> hold

  // Packed meta payload: {RSVD[3:0]_reserved_for_future, buf_sel[1], layer_id[3], t_idx[8]} = 16 bits
  logic [TRACE_HASH_META_PACKED_W-1:0] meta_pack_w;
  assign meta_pack_w = { {(TRACE_HASH_META_PACKED_W - 1 - LAYER_ID_W - T_IDX_W){1'b0}},
                        spike_commit_buf_sel,
                        spike_commit_layer_id,
                        spike_commit_t_idx };

  // do_write: this cycle the recorder commits one (hash, meta) entry to BRAM.
  logic do_write;
  assign do_write = cfg_recorder_en
                  & spike_commit_valid
                  & ~log_overflow_q;

  // Treat a 0->1 enable edge as a fresh recorder session for the layer-id
  // lock, while keeping sticky fault semantics unchanged until explicit clear.
  logic recorder_session_start;
  assign recorder_session_start = cfg_recorder_en & ~cfg_recorder_en_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      log_count_q          <= '0;
      log_overflow_q       <= 1'b0;
      layer_id_fault_q     <= 1'b0;
      cfg_recorder_en_q    <= 1'b0;
      first_commit_seen_q  <= 1'b0;
      layer_id_lock_q      <= '0;
    end else if (cfg_recorder_clear) begin
      log_count_q          <= '0;
      log_overflow_q       <= 1'b0;
      layer_id_fault_q     <= 1'b0;
      cfg_recorder_en_q    <= cfg_recorder_en;
      first_commit_seen_q  <= 1'b0;
      layer_id_lock_q      <= '0;
    end else begin
      cfg_recorder_en_q <= cfg_recorder_en;

      if (!cfg_recorder_en) begin
        first_commit_seen_q <= 1'b0;
        layer_id_lock_q     <= '0;
      end else if (recorder_session_start) begin
        first_commit_seen_q <= 1'b0;
        layer_id_lock_q     <= '0;
      end

      if (do_write) begin
        // BRAM write: hash + meta at log_count_q
        hash_mem[log_count_q[LOG_ADDR_W-1:0]] <= hash_combinational;
        meta_mem[log_count_q[LOG_ADDR_W-1:0]] <= meta_pack_w;

        // Advance count + raise overflow on the LAST in-range write.
        // After this write, log_count_q points to the next free slot. If we
        // just consumed slot P_LOG_DEPTH-1, then log_count would become
        // P_LOG_DEPTH (out of range) so we mark overflow to reject the *next*
        // commit instead of double-writing slot P_LOG_DEPTH-1.
        log_count_q    <= log_count_q + TRACE_HASH_LOG_COUNT_W'(1);
        if (log_count_q == TRACE_HASH_LOG_COUNT_W'(P_LOG_DEPTH - 1))
          log_overflow_q <= 1'b1;

        // Layer-ID drift detector
        if (recorder_session_start || !first_commit_seen_q) begin
          layer_id_lock_q     <= spike_commit_layer_id;
          first_commit_seen_q <= 1'b1;
        end else if (spike_commit_layer_id != layer_id_lock_q) begin
          layer_id_fault_q <= 1'b1;
        end
      end
    end
  end

  // ──────────────────────────────────────────────────────────────────────────
  // 5. Read port BRAM tap (latency-1 register)
  // ──────────────────────────────────────────────────────────────────────────
  //
  // Contract per design doc §2:
  //   - host writes A_LOG_RD_ADDR (CSR 0x070)
  //   - on the NEXT MMIO read of A_LOG_RD_DATA (0x074) / A_LOG_RD_META (0x078)
  //     the registered hash_mem[rd_addr] / meta_mem[rd_addr] is returned
  //
  // Day Wed top wiring should pulse rd_en when the host commits a new
  // TRACE_HASH_LOG_RD_ADDR value, not on the later data read. The common
  // integration pattern is "write RD_ADDR with bypassed write-data -> rd_en
  // pulse", then the next MMIO read of 0x074/0x078 returns rd_data_q/rd_meta_q.

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_data_q <= '0;
      rd_meta_q <= '0;
    end else if (rd_en) begin
      rd_data_q <= hash_mem[rd_addr];
      rd_meta_q <= meta_mem[rd_addr];
    end
    // else: hold previous value (host can re-read same address without rewriting addr).
  end

  // ──────────────────────────────────────────────────────────────────────────
  // 6. SVA (ifdef VCS — Icarus skips with -gno-assertions per CLAUDE.md)
  // ──────────────────────────────────────────────────────────────────────────

  `ifdef VCS

  // SVA-1: cfg_recorder_en == 0 |-> never write BRAM
  // (do_write is gated on cfg_recorder_en, so the gating drives this property.)
  property p_sva1_disabled_no_write;
    @(posedge clk) disable iff (!rst_n)
      (cfg_recorder_en == 1'b0) |-> (do_write == 1'b0);
  endproperty
  a_sva1_disabled_no_write : assert property (p_sva1_disabled_no_write)
    else $error("SVA-1 violated: cfg_recorder_en=0 but do_write asserted");

  // SVA-2: log_count_q stable when no commit and no clear and not in reset.
  property p_sva2_log_count_stable_when_idle;
    @(posedge clk) disable iff (!rst_n)
      (!cfg_recorder_clear && !do_write) |-> ##1 (log_count_q == $past(log_count_q));
  endproperty
  a_sva2_log_count_stable : assert property (p_sva2_log_count_stable_when_idle)
    else $error("SVA-2 violated: log_count_q changed without commit or clear");

  // SVA-3: log_overflow_q monotone: once set, stays set until clear.
  property p_sva3_overflow_monotone;
    @(posedge clk) disable iff (!rst_n)
      (log_overflow_q && !cfg_recorder_clear) |-> ##1 (log_overflow_q == 1'b1);
  endproperty
  a_sva3_overflow_monotone : assert property (p_sva3_overflow_monotone)
    else $error("SVA-3 violated: log_overflow_q dropped without clear");

  // SVA-4: layer_id_fault_q monotone: once set, stays set until clear.
  property p_sva4_layer_id_fault_monotone;
    @(posedge clk) disable iff (!rst_n)
      (layer_id_fault_q && !cfg_recorder_clear) |-> ##1 (layer_id_fault_q == 1'b1);
  endproperty
  a_sva4_layer_id_fault_monotone : assert property (p_sva4_layer_id_fault_monotone)
    else $error("SVA-4 violated: layer_id_fault_q dropped without clear");

  // SVA-5: readback registers only change when rd_en is pulsed or reset hits.
  property p_sva5_readback_stable_without_rd_en;
    @(posedge clk) disable iff (!rst_n)
      (!rd_en) |-> ##1 ((rd_data_q == $past(rd_data_q)) &&
                        (rd_meta_q == $past(rd_meta_q)));
  endproperty
  a_sva5_readback_stable_without_rd_en : assert property (p_sva5_readback_stable_without_rd_en)
    else $error("SVA-5 violated: readback registers changed without rd_en");

  `endif

  // ──────────────────────────────────────────────────────────────────────────
  // 7. Sanity / lint suppression
  // ──────────────────────────────────────────────────────────────────────────

  `ifndef SYNTHESIS
  initial begin
    if (P_N_OUT !== TRACE_HASH_P_N_OUT_DEFAULT)
      $display("trace_hash_recorder: NOTE P_N_OUT=%0d (default=%0d)",
               P_N_OUT, TRACE_HASH_P_N_OUT_DEFAULT);
    if (P_T_MAX !== TRACE_HASH_P_T_MAX_DEFAULT)
      $display("trace_hash_recorder: NOTE P_T_MAX=%0d (default=%0d)",
               P_T_MAX, TRACE_HASH_P_T_MAX_DEFAULT);
  end
  `endif

endmodule
