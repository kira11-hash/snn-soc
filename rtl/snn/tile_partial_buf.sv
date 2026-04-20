`timescale 1ns/1ps
//======================================================================
// 文件名: tile_partial_buf.sv
// 模块名: tile_partial_buf
//
// 【功能概述】
// V2.B REV 3.1 D1 / REV 3.2 D8：tile multiplex 下的 partial-sum
// 累加器。存储 `[T_MAX × MAX_OUT_NEURONS]` signed V2B_PARTIAL_WIDTH
// 值，跨 tile 在同一 (t, j) 槽累加 per-tile ADC 结果，最后一个 tile
// 完成后按 t=0..T-1 顺序驱动 LIF。
//
// 【为什么必须是 `[T][N]` 而非 `[N]`（D1 关键）】
// 如果只存 `[N]` 一维，tile 的时间信息会被折叠：tile0 的 t=0 partial
// 会和 tile1 的 t=5 partial 混淆。正确的 RTL 语义要求每个 (t, j) 槽
// 独立累加，对应 Python `_run_stage_streamed_rate_tiled` 里
// `partial_diff_buffer[t] += adc(pos_sum) - adc(neg_sum)`（per tile，
// per timestep）。
//
// 【容量预算（B0 §B0.2 D16 精确）】
//   depth = V2B_MAX_TIMESTEPS (256)
//   width = V2B_MAX_OUT_NEURONS (128)
//   cell  = signed V2B_PARTIAL_WIDTH (14 bit)
//   total = 256 × 128 × 14 bit = 459 Kbit (~56 KB)
//   BRAM: ~13 × 36Kb (T=256), ~4 × 36Kb (T=64)
//
// 【操作】
//   - clear_all：所有 cell 清零（stage engine 启动时触发）
//   - acc：mem[wr_t][wr_j] += wr_diff（每周期一个 cell）
//   - read：rd_data = mem[rd_t][rd_j]（1 cycle latency）
//
// 【宽度选择说明】
// per-tile ADC 输出 signed (ADC_BITS+1) = 11 bit。跨最多 4 tile 累加需
// 11 + log2(4) = 13 bit，留 1 bit safety ⇒ V2B_PARTIAL_WIDTH = 14.
//
// 【读写顺序约定】
// 在 stage_engine 内，同一周期不应对同一 (t, j) 同时 acc 和 read。
// stage 运行分两阶段：
//   (a) tile 累加阶段：只 acc，不 read
//   (b) LIF 扫描阶段：只 read，不 acc
// 故无需 true dual-port。
//======================================================================
module tile_partial_buf
  import snn_soc_pkg::*;
#(
  parameter int P_DEPTH = V2B_MAX_TIMESTEPS,    // 256
  parameter int P_WIDTH = V2B_MAX_OUT_NEURONS,  // 128
  parameter int P_CELL  = V2B_PARTIAL_WIDTH     // 14
) (
  input  logic                    clk,
  input  logic                    rst_n,

  input  logic                    clear_all,

  // ── 累加端口：mem[wr_t][wr_j] += wr_diff ───────────────────────────
  input  logic                    acc_en,
  input  logic [$clog2(P_DEPTH)-1:0] wr_t,
  input  logic [$clog2(P_WIDTH)-1:0] wr_j,
  input  logic signed [P_CELL-1:0] wr_diff,

  // ── 读端口：单元素，1 cycle latency ────────────────────────────────
  input  logic                    rd_en,
  input  logic [$clog2(P_DEPTH)-1:0] rd_t,
  input  logic [$clog2(P_WIDTH)-1:0] rd_j,
  output logic signed [P_CELL-1:0] rd_data
);

  // 2D signed storage. Icarus OK; Vivado 会推成多个 BRAM。
  logic signed [P_CELL-1:0] mem [0:P_DEPTH-1][0:P_WIDTH-1];

  // Accumulate / clear
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int t = 0; t < P_DEPTH; t++)
        for (int j = 0; j < P_WIDTH; j++)
          mem[t][j] <= '0;
    end else if (clear_all) begin
      for (int t = 0; t < P_DEPTH; t++)
        for (int j = 0; j < P_WIDTH; j++)
          mem[t][j] <= '0;
    end else if (acc_en) begin
      // Saturation-free: bitgrowth up to P_CELL; upper-layer guarantees
      // raw sums stay within range (ADC_MAX × N_tiles ≤ 2^13)
      mem[wr_t][wr_j] <= mem[wr_t][wr_j] + wr_diff;
    end
  end

  // Synchronous read
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_data <= '0;
    end else if (rd_en) begin
      rd_data <= mem[rd_t][rd_j];
    end
  end

`ifndef SYNTHESIS
`ifdef VCS
  // Contract: no simultaneous acc + read on the same (t, j) cell.
  property no_rmw_collision;
    @(posedge clk) disable iff (!rst_n)
      (acc_en && rd_en) |-> !(wr_t == rd_t && wr_j == rd_j);
  endproperty
  assert property (no_rmw_collision)
    else $error("[tile_partial_buf] concurrent acc+read on (t=%0d, j=%0d)", wr_t, wr_j);
`endif
`endif

endmodule
