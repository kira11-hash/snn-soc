`timescale 1ns/1ps
//======================================================================
// 文件名: stream_buffer_v2.sv
// 模块名: stream_buffer_v2
//
// 【功能概述】
// V2.B REV 3.3 D14：streamed-rate 层间 spike stream buffer，替代 V1
// `spike_feedback.sv` 的 OR-latch 语义。stage engine 每 timestep 写
// 一个 out_dim 位 mask 进来；下一级 stage engine 逐 timestep 读出当
// 作 WL 输入。两个 instance（A/B）由上层固件/控制器 ping-pong 切换。
//
// 【和 input_stream_sram 的区别】
//   - input_stream_sram: WIDTH = V2B_NUM_INPUTS (256)  — stage 0 输入
//   - stream_buffer_v2:  WIDTH = V2B_MAX_OUT_NEURONS (128) — 中间层 spike
//
// 两者结构相似（1-bit 深度 SRAM），但参数不同 + 实例化时机 / ownership
// 不同。故分为独立模块便于追踪。
//
// 【容量（B0 §B0.2）】
//   depth = V2B_MAX_TIMESTEPS (256)
//   width = V2B_MAX_OUT_NEURONS (128)
//   total = 32 Kbit (~4 KB) ≈ 1 × 36Kb BRAM
//
// 【ownership 语义（B0 §B0.7）】
// 本模块只做物理存储。FREE→WRITING→READY→READING→FREE 状态机由
// 上层 reg_bank 寄存器 + 固件驱动。ownership 冲突保护由 stage_engine
// 的 INPUT_SRC/OUTPUT_DST 检查完成（V2B_STAGE_ERR_SRC_DST_CONFLICT）。
//======================================================================
module stream_buffer_v2
  import snn_soc_pkg::*;
#(
  parameter int P_DEPTH = V2B_MAX_TIMESTEPS,     // 256
  parameter int P_WIDTH = V2B_MAX_OUT_NEURONS    // 128
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // ── 写端口（本 stage 每 timestep 写 spike_mask） ────────────────────
  input  logic                    wr_en,
  input  logic [$clog2(P_DEPTH)-1:0] wr_addr,
  input  logic [P_WIDTH-1:0]      wr_data,

  // ── 读端口（下一 stage 每 timestep 读 WL 输入） ─────────────────────
  input  logic                    rd_en,
  input  logic [$clog2(P_DEPTH)-1:0] rd_addr,
  output logic [P_WIDTH-1:0]      rd_data,

  // ── 清零（sample / chunk 切换时使用） ───────────────────────────────
  input  logic                    clear_all
);

  (* ram_style = "distributed" *)
  logic [P_WIDTH-1:0] mem [0:P_DEPTH-1];

`ifdef SYNTHESIS
  // Synth: counter-walker clear to avoid P_DEPTH-wide reset fan-out.
  // Firmware must wait P_DEPTH cycles after clear pulse.
  logic [$clog2(P_DEPTH)-1:0] clr_ctr_sb;
  logic                        clr_busy_sb;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      clr_busy_sb <= 1'b0;
      clr_ctr_sb  <= '0;
    end else if (clear_all && !clr_busy_sb) begin
      clr_busy_sb <= 1'b1;
      clr_ctr_sb  <= '0;
    end else if (clr_busy_sb) begin
      clr_ctr_sb <= clr_ctr_sb + 1;
      if (clr_ctr_sb == ($clog2(P_DEPTH))'(P_DEPTH-1)) clr_busy_sb <= 1'b0;
    end
  end
  always_ff @(posedge clk) begin
    if (clr_busy_sb) mem[clr_ctr_sb] <= '0;
    else if (wr_en)  mem[wr_addr]    <= wr_data;
  end
`else
  // Sim: single-cycle broadcast clear (bit-exact to existing TBs).
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < P_DEPTH; i++) mem[i] <= '0;
    end else if (clear_all) begin
      for (int i = 0; i < P_DEPTH; i++) mem[i] <= '0;
    end else if (wr_en) begin
      mem[wr_addr] <= wr_data;
    end
  end
`endif

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_data <= '0;
    end else if (rd_en) begin
      rd_data <= mem[rd_addr];
    end
  end

`ifndef SYNTHESIS
`ifdef VCS
  property no_simultaneous_rw_same_addr_sbv2;
    @(posedge clk) disable iff (!rst_n)
      (wr_en && rd_en) |-> (wr_addr != rd_addr);
  endproperty
  assert property (no_simultaneous_rw_same_addr_sbv2)
    else $error("[stream_buffer_v2] same-addr read+write in same cycle (UB per B0.7)");
`endif
`endif

endmodule
