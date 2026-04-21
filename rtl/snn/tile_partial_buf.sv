`timescale 1ns/1ps
//======================================================================
// 文件名: tile_partial_buf.sv
// 模块名: tile_partial_buf
//
// 【功能概述】
// V2.B REV 3.1 D1 / REV 3.2 D8：tile multiplex 下的 partial-sum
// 累加器。逻辑上存储 `[T_MAX × MAX_OUT_NEURONS]` signed V2B_PARTIAL_WIDTH
// 值，跨 tile 在同一 (t, j) 槽累加 per-tile ADC 结果，最后一个 tile
// 完成后按 t=0..T-1 顺序驱动 LIF。
//
// 【FPGA-friendly 重写 (2026-04-21)】
// 之前 2D unpacked array `mem[0:D-1][0:W-1]` 让 Vivado 识别为 "3D RAM with
// 458752 registers" 并卡在 elaboration。改成：
//   1. 1D 扁平地址 mem[0:D*W-1]，addr = t*W + j
//   2. (* ram_style = "distributed" *) 明确使用 LUTRAM，匹配 1-cycle RMW
//   3. reset 不清内存（RAM 没有 content-reset 线，保留初值）
//   4. clear_all 改 counter-driven 多周期 walker，每 cycle 清 1 cell
//
// 【行为语义不变】
// - acc_en @ (wr_t, wr_j): mem[wr_t, wr_j] += wr_diff，单周期 RMW
// - rd_en  @ (rd_t, rd_j): rd_data <= mem[rd_t, rd_j]，sync 1-cycle latency
// - clear_all: 拉 1 cycle 后启动内部清零 FSM，清零期间 acc/rd 无效
//   （stage_engine 使用 pattern: 先 clear → 再 acc → 再 read，不冲突）
//
// 【RMW 实现】
// 为 BRAM inference：用 write-first/read-first 策略不好写，保留 1-cycle
// RMW，Vivado 可能把这块 mem 实现为 distributed RAM（LUTRAM）而不是
// BRAM。LUTRAM 对 32K×14bit ≈ 7K LUT，可接受。若想上 BRAM 需要 2-cycle
// pipeline（stage_engine 也得改 handshake），留给 Phase D 优化迭代。
//
// 【容量预算】
//   D×W×C = 256 × 128 × 14 = 458 752 bit (≈ 56 KB)
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

  localparam int P_TOTAL   = P_DEPTH * P_WIDTH;
  localparam int P_ADDR_W  = $clog2(P_TOTAL);
  localparam int P_W_BITS  = $clog2(P_WIDTH);
  localparam logic [P_ADDR_W-1:0] P_TOTAL_LAST = P_ADDR_W'(P_TOTAL - 1);

  // ── Flat 1D storage — let Vivado pick BRAM/LUTRAM ──────────────────
  // ram_style=distributed is a better fit for 1-cycle RMW; with "block"
  // Vivado may refuse due to RMW timing. distributed gives LUTRAM
  // (no BRAM but manageable LUT cost for 32K × 14-bit ~= 7K LUT).
  (* ram_style = "distributed" *)
  logic signed [P_CELL-1:0] mem [0:P_TOTAL-1];

  // Flatten (t, j) -> linear addr. Cast to P_ADDR_W to keep Vivado happy.
  function automatic [P_ADDR_W-1:0] flat_addr
    (input [$clog2(P_DEPTH)-1:0] t,
     input [$clog2(P_WIDTH)-1:0] j);
    flat_addr = (t * P_WIDTH) + j;
  endfunction

`ifdef SYNTHESIS
  // ── Synth path: counter walker for clear_all ──────────────────────
  // Multi-cycle wipe (32768 cells = 32768 cycles @ clk). Vivado fine
  // because write is single-address-per-cycle, BRAM/LUTRAM inferable.
  // By contract, firmware must wait P_TOTAL cycles after clear_all
  // pulse before issuing next acc_en.
  logic [P_ADDR_W-1:0] clr_ctr;
  logic                clr_busy;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      clr_busy <= 1'b0;
      clr_ctr  <= '0;
    end else begin
      if (!clr_busy) begin
        if (clear_all) begin
          clr_busy <= 1'b1;
          clr_ctr  <= '0;
        end
      end else begin
        if (clr_ctr == P_TOTAL_LAST) begin
          clr_busy <= 1'b0;
        end
        clr_ctr <= clr_ctr + 1;
      end
    end
  end

  always_ff @(posedge clk) begin
    // Memory contents are intentionally not reset.  Keep reset out of this
    // process so Vivado can infer RAM/LUTRAM instead of a huge resettable FF
    // array.  clear_all is implemented by the counter walker above.
    if (clr_busy) begin
      mem[clr_ctr] <= '0;
    end else if (acc_en) begin
      mem[flat_addr(wr_t, wr_j)] <= mem[flat_addr(wr_t, wr_j)] + wr_diff;
    end
  end

`else
  // ── Sim path: single-cycle broadcast clear (TB-friendly) ──────────
  // Synthesis would see this as a huge reset fan-out; only used for
  // simulation where TBs expect clear-to-act in the next cycle.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int k = 0; k < P_TOTAL; k++) mem[k] <= '0;
    end else if (clear_all) begin
      for (int k = 0; k < P_TOTAL; k++) mem[k] <= '0;
    end else if (acc_en) begin
      mem[flat_addr(wr_t, wr_j)] <= mem[flat_addr(wr_t, wr_j)] + wr_diff;
    end
  end
`endif

  // ── Synchronous read ──────────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_data <= '0;
    end else if (rd_en) begin
      rd_data <= mem[flat_addr(rd_t, rd_j)];
    end
  end

`ifndef SYNTHESIS
`ifdef VCS
  property no_rmw_collision;
    @(posedge clk) disable iff (!rst_n)
      (acc_en && rd_en) |-> !(wr_t == rd_t && wr_j == rd_j);
  endproperty
  assert property (no_rmw_collision)
    else $error("[tile_partial_buf] concurrent acc+read on (t=%0d, j=%0d)", wr_t, wr_j);
`endif
`endif

endmodule
