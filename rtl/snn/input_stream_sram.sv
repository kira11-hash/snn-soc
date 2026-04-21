`timescale 1ns/1ps
//======================================================================
// 文件名: input_stream_sram.sv
// 模块名: input_stream_sram
//
// 【功能概述】
// V2.B REV 3.3 D6：input stream SRAM 显式 primitive。
// 存放 firmware-encoded 的像素 spike stream（even_rate accumulator 在
// CPU 侧生成），cim_array_ctrl 在每个 timestep 读出一个 in_dim mask
// 作为 CIM WL 输入。
//
// 【与 input_fifo 的区分】
// V1 使用 input_fifo（流式 DMA 接口）喂 CIM。V2.B 改用随机访问 SRAM：
// DMA 一次性灌入全部 T × in_dim 比特，推理时随机读 [t] 行，保留时间
// 结构（streamed rate 语义要求）。
//
// 【容量预算（B0 §B0.2）】
//   depth  = V2B_MAX_TIMESTEPS (= 256)
//   width  = V2B_NUM_INPUTS    (= 256)
//   total  = 64 Kbit ≈ 2 × 36Kb BRAM (Xilinx 7-series)
//
// 【时序语义】
// 写（DMA）: 每个 timestep 地址 t 写 V2B_NUM_INPUTS 位 mask
// 读（CIM）: 每个 timestep 地址 t 读 V2B_NUM_INPUTS 位 mask（1 cycle latency）
// 同周期读写同一地址：UB（firmware 必须保证 DMA 阶段结束再启动推理）
//
// 【B0.2 buffer ownership】
// 状态机由上层 stream_buffer_ctrl 管理（FREE→WRITING→READY→READING→FREE）。
// 本模块只做物理存储，不维护 ownership。
//======================================================================
module input_stream_sram
  import snn_soc_pkg::*;
#(
  parameter int P_DEPTH = V2B_MAX_TIMESTEPS,   // 256
  parameter int P_WIDTH = V2B_NUM_INPUTS       // 256
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // ── 写端口（DMA / firmware pre-encode） ────────────────────────────
  input  logic                    wr_en,
  input  logic [$clog2(P_DEPTH)-1:0] wr_addr,   // 0..T-1
  input  logic [P_WIDTH-1:0]      wr_data,

  // ── 读端口（cim_array_ctrl 每 timestep 读一次） ────────────────────
  input  logic                    rd_en,
  input  logic [$clog2(P_DEPTH)-1:0] rd_addr,
  output logic [P_WIDTH-1:0]      rd_data,     // 1-cycle latency after rd_en

  // ── 全清（chunk 边界 / sample 切换） ───────────────────────────────
  input  logic                    clear_all    // 单拍脉冲；优先级高于 wr_en
);

  // LUTRAM-friendly 1D array. The async read interface is intentional for
  // the current stage-engine timing model, so mark this as distributed RAM
  // instead of asking Vivado to infer infeasible BRAM.
  (* ram_style = "distributed" *)
  logic [P_WIDTH-1:0] mem [0:P_DEPTH-1];

`ifdef SYNTHESIS
  // ── Synth path: counter-walker for clear, NO reset-broadcast ──────
  // Rationale: P_DEPTH-cell reset fan-out is a Vivado synth hazard
  // (clear_all wipes 65536 bits in one cycle → reset fan-out on BRAM).
  // By contract firmware waits P_DEPTH cycles after clear pulse.
  logic [$clog2(P_DEPTH)-1:0] clr_ctr_isr;
  logic                        clr_busy_isr;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      clr_busy_isr <= 1'b0;
      clr_ctr_isr  <= '0;
    end else if (clear_all && !clr_busy_isr) begin
      clr_busy_isr <= 1'b1;
      clr_ctr_isr  <= '0;
    end else if (clr_busy_isr) begin
      clr_ctr_isr <= clr_ctr_isr + 1;
      if (clr_ctr_isr == ($clog2(P_DEPTH))'(P_DEPTH-1)) clr_busy_isr <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (clr_busy_isr)   mem[clr_ctr_isr] <= '0;
    else if (wr_en)     mem[wr_addr]     <= wr_data;
  end

`else
  // ── Sim path: single-cycle broadcast clear (Icarus / bit-exact) ──
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

  // 同步读（1 cycle latency；和 Xilinx BRAM read-first 一致）
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_data <= '0;
    end else if (rd_en) begin
      rd_data <= mem[rd_addr];
    end
  end

  // ── 断言：同地址读写冲突防守（仿真 only） ────────────────────────
`ifndef SYNTHESIS
`ifdef VCS
  property no_simultaneous_rw_same_addr;
    @(posedge clk) disable iff (!rst_n)
      (wr_en && rd_en) |-> (wr_addr != rd_addr);
  endproperty
  assert property (no_simultaneous_rw_same_addr)
    else $error("[input_stream_sram] same-addr read+write in same cycle (UB per B0.2)");
`endif
`endif

endmodule
