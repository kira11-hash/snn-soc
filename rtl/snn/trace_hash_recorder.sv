// -----------------------------------------------------------------------------
// 自动文档头：本文件的可读性说明（仅注释说明，不改变任何逻辑）
// 文件路径：rtl/snn/trace_hash_recorder.sv
// 作用：M1 trace-hash recorder（Path B paper add-on #1）的硬件实现。
// 系统角色：sidecar 模块，挂在 stage_engine_v2 的 spike-commit 边界，监听
//           (sbA_wr_en | sbB_wr_en) 拍 CRC-32 指纹存进 BRAM，host 通过
//           CSR 读出后做跨 host (ARM ↔ E203) 一致性校验。
// 行为性质：cfg_recorder_en=0 时完全 sidecar，零反向驱动 stage_engine。
// 项目规则：本文件 Phase 1 Day Mon 是 SKELETON（端口 + 状态 + reset 落定，
//           hash compute / BRAM write 主逻辑留 Day Tue 完成）；Day Mon 不
//           碰 snn_soc_v2b_top.sv 的实例化和 wiring。
// 集成提示：实例化和 CSR decode 见 snn_soc_v2b_top.sv（Day Wed 引入）。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: trace_hash_recorder.sv
// 模块名: trace_hash_recorder
//
// 【功能概述（最终版，Day Tue 完整实现）】
// 监听 stage_engine_v2 的 spike-commit pulse (sbA_wr_en | sbB_wr_en)，
// 把 {layer_id, buf_sel, t_idx, spike_vec[127:0]} 联合算 CRC-32-IEEE，
// 32-bit hash + 16-bit metadata 存进 BRAM。host 通过 CSR (TRACE_HASH_A_*)
// 设置 read address 后读出 hash + meta，UART dump 给 Python diff 工具做
// 跨 host 比对。详见 essay/m1_design_doc_2026_05_05.md (Codex Phase 0 PASS)。
//
// 【Day Mon (本 commit) skeleton 范围】
// - 端口列表 + 类型 (与 design doc §1.1 一致)
// - 内部状态声明 (log BRAM / log_count / overflow sticky / layer_id_fault sticky)
// - reset 行为 (所有 status / sticky 清零，BRAM 不强清)
// - cfg_recorder_clear W1P 处理 (清 log_count + sticky，保留 BRAM)
// - cfg_recorder_en = 0 时的 no-op 隔离 (sidecar 保证)
// - rd_data / rd_meta 占位返回 0 (Day Tue 接 BRAM read port)
// - hash compute / write path: 留 TODO，Day Tue 实现
//
// 【硬约束（Codex Phase 0 review 拍板）】
// 1. cfg_recorder_en = 0 时 recorder 不写 BRAM，不抬 log_count，不抬 sticky
// 2. cfg_recorder_clear W1P 清 log_count / overflow / layer_id_fault，但**不清 BRAM**
// 3. spike_commit_valid 拍点只在 cfg_recorder_en=1 时被消化
// 4. layer_id 在同一 stage 内变化即抬 layer_id_fault sticky
// 5. log_count >= P_LOG_DEPTH 时 reject 写 + 抬 log_overflow，不阻塞 stage_engine
//
// 【后续 Phase 边界（绝不在本 skeleton 落地）】
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
  // 0. Sanity checks (synth-time)
  // ──────────────────────────────────────────────────────────────────────────
  // Module is V2.B-scoped: P_N_OUT must equal V2B_MAX_OUT_NEURONS, etc.
  // Top-level instantiation must override these, but if defaults are used
  // they should at least be consistent. (No-op assertion form to keep
  // Icarus + Verilator happy; design doc §1.1 documents the contract.)
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

  // ──────────────────────────────────────────────────────────────────────────
  // 1. Internal state declarations
  // ──────────────────────────────────────────────────────────────────────────

  // BRAM: 2048 entries × 48 bits (32 hash + 16 meta).
  // Use two separate arrays so synth can lift each into its own BRAM slice.
  logic [31:0]                              hash_mem [0:P_LOG_DEPTH-1];
  logic [TRACE_HASH_META_PACKED_W-1:0]      meta_mem [0:P_LOG_DEPTH-1];

  // Counters / sticky status
  logic [TRACE_HASH_LOG_COUNT_W-1:0]        log_count_q;
  logic                                     log_overflow_q;
  logic                                     layer_id_fault_q;

  // Layer-ID drift detector state
  // first_commit_seen_q latches the layer_id from the first commit after
  // each clear, so subsequent commits in the same stage can be compared.
  logic                                     first_commit_seen_q;
  logic [$clog2(P_LAYER_MAX)-1:0]           layer_id_lock_q;

  // Read-side latency-1 register (write 0x070 -> next MMIO read 0x074/0x078)
  logic [31:0]                              rd_data_q;
  logic [TRACE_HASH_META_PACKED_W-1:0]      rd_meta_q;

  // ──────────────────────────────────────────────────────────────────────────
  // 2. Output wiring (continuous assigns from registered state)
  // ──────────────────────────────────────────────────────────────────────────

  assign log_count       = log_count_q;
  assign log_overflow    = log_overflow_q;
  assign layer_id_fault  = layer_id_fault_q;
  assign rd_data         = rd_data_q;
  assign rd_meta         = rd_meta_q;

  // ──────────────────────────────────────────────────────────────────────────
  // 3. Reset + clear handling (Day Mon: PASS; Day Tue: extends with hash write)
  // ──────────────────────────────────────────────────────────────────────────
  //
  // Behavior at reset_n=0 OR cfg_recorder_clear pulse:
  //   - log_count_q       -> 0
  //   - log_overflow_q    -> 0
  //   - layer_id_fault_q  -> 0
  //   - first_commit_seen_q -> 0
  //   - layer_id_lock_q   -> '0
  //
  // BRAM is NOT cleared on cfg_recorder_clear (per design doc §1; saves power
  // and lets reviewer audit prior-run residue if needed). At reset_n=0 the
  // BRAM contents are left as `x` (synth) / `0` (sim) — host must initialize
  // by writing CLEAR_W1P before relying on log_count for indexing.

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      log_count_q          <= '0;
      log_overflow_q       <= 1'b0;
      layer_id_fault_q     <= 1'b0;
      first_commit_seen_q  <= 1'b0;
      layer_id_lock_q      <= '0;
    end else if (cfg_recorder_clear) begin
      log_count_q          <= '0;
      log_overflow_q       <= 1'b0;
      layer_id_fault_q     <= 1'b0;
      first_commit_seen_q  <= 1'b0;
      layer_id_lock_q      <= '0;
    end else begin
      // ─────────────────────────────────────────────────────────────────────
      // TODO (Day Tue): hash compute + BRAM write path
      //
      //   if (cfg_recorder_en && spike_commit_valid && !log_overflow_q) begin
      //     compute crc32 of {layer_id, buf_sel, t_idx, spike_data}
      //     hash_mem[log_count_q] <= crc32
      //     meta_mem[log_count_q] <= {21'b0, buf_sel, layer_id, t_idx}  (16-bit packed)
      //     log_count_q <= log_count_q + 1
      //     if (log_count_q == P_LOG_DEPTH-1) log_overflow_q <= 1
      //
      //     // Layer-ID drift detector
      //     if (!first_commit_seen_q) begin
      //       layer_id_lock_q     <= spike_commit_layer_id
      //       first_commit_seen_q <= 1
      //     end else if (spike_commit_layer_id != layer_id_lock_q) begin
      //       layer_id_fault_q <= 1
      //     end
      //   end
      // ─────────────────────────────────────────────────────────────────────
      ;  // empty until Day Tue
    end
  end

  // ──────────────────────────────────────────────────────────────────────────
  // 4. Read port latency-1 register (Day Mon stub; Day Tue connects to BRAM)
  // ──────────────────────────────────────────────────────────────────────────
  //
  // Contract per design doc §2: host writes A_LOG_RD_ADDR (0x070), then the
  // NEXT MMIO read of A_LOG_RD_DATA (0x074) / A_LOG_RD_META (0x078) returns
  // the corresponding entry. We honor that by registering the BRAM output.
  //
  // Day Mon stub returns 0 unconditionally; Day Tue replaces with
  //   rd_data_q <= hash_mem[rd_addr]
  //   rd_meta_q <= meta_mem[rd_addr]

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_data_q <= '0;
      rd_meta_q <= '0;
    end else if (rd_en) begin
      // TODO (Day Tue): replace with BRAM tap.
      //   rd_data_q <= hash_mem[rd_addr]
      //   rd_meta_q <= meta_mem[rd_addr]
      rd_data_q <= '0;
      rd_meta_q <= '0;
    end
    // else: hold previous (host can re-read without re-writing addr).
  end

  // ──────────────────────────────────────────────────────────────────────────
  // 5. Sidecar isolation (Codex Phase 0 review §3 SVA seeds)
  // ──────────────────────────────────────────────────────────────────────────
  //
  // These are *advisory* assertions — Day Tue will turn them into proper
  // SVA `assert property` blocks. For Day Mon we keep them as documentation
  // anchors so the intent is captured in the same file as the contract.
  //
  //   SVA_1: cfg_recorder_en == 0 |-> never write BRAM
  //   SVA_2: cfg_recorder_en == 0 |-> log_count_q stable (modulo reset/clear)
  //   SVA_3: spike_commit_valid && !cfg_recorder_en |-> no observable change
  //
  // (Day Tue turns SVA_1/2/3 into real assertions inside `ifdef VCS guards.)

  /* verilator lint_off UNUSEDSIGNAL */
  // Day Mon: many signals not yet consumed by the empty body. Verilator
  // would warn; we silence until Day Tue closes the implementation.
  wire _unused_ok = &{1'b0,
                     spike_commit_data,
                     spike_commit_t_idx,
                     spike_commit_buf_sel,
                     spike_commit_layer_id,
                     cfg_recorder_en,
                     spike_commit_valid,
                     rd_addr,
                     1'b0};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
