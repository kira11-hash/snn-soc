`timescale 1ns/1ps
//======================================================================
// 文件名: spike_feedback.sv
// 模块名: spike_feedback
//
// 【功能概述】
// 多层 SNN 推理中的"层间 spike 回注"模块。
// 当某一层推理结束后，lif_neuron_alu 产生 spike_mask（每 bit 代表一个
// 神经元是否发放了 spike），本模块将这个 spike_mask 转换为下一层的
// 输入向量（feedback_wl_data），由 cim_array_ctrl 写入 input_fifo。
//
// 【工作流程】
// 1. lif_neuron_alu 完成本层所有神经元遍历后，拉高 spike_mask_valid 一拍
// 2. 本模块锁存 spike_mask，等待 layer_sequencer 发出 feedback_en
// 3. 收到 feedback_en 后，将 spike_mask 截取到 next_wl_count 位宽，
//    输出 feedback_wl_data，同时拉高 feedback_valid 通知上游
//
// 【设计要点】
// - spike_mask 是 MAX_NEURONS 位宽（默认 128 位），但下一层的输入宽度
//   可能小于 128（由 next_wl_count 指定），因此超出部分填 0
// - 中间层 spike 是 binary（0/1），不走 bit-plane 编码，只推 1 个入口
//======================================================================
module spike_feedback #(
  parameter int P_MAX_NEURONS = snn_soc_pkg::MAX_NEURONS
) (
  input  logic clk,                                  // 系统时钟
  input  logic rst_n,                                // 异步低有效复位

  // ── 来自 lif_neuron_alu 的 spike 结果 ─────────────────────────────
  input  logic [P_MAX_NEURONS-1:0] spike_mask,       // 本层所有神经元的 spike 位图
  input  logic spike_mask_valid,                     // spike_mask 有效脉冲（单拍高）

  // ── 来自 layer_sequencer 的控制 ────────────────────────────────────
  input  logic feedback_en,                          // 允许回注脉冲（layer_sequencer 在层间间隙发出）
  input  logic [7:0] next_wl_count,                  // 下一层的有效字线数量（截取宽度）

  // ── 输出到 cim_array_ctrl / input_fifo ────────────────────────────
  output logic [P_MAX_NEURONS-1:0] feedback_wl_data, // 回注的字线输入向量
  output logic feedback_valid                        // 回注数据有效脉冲
);

  // ── 内部状态 ──────────────────────────────────────────────────────
  logic [P_MAX_NEURONS-1:0] spike_latched;  // 锁存的 spike_mask（等待 feedback_en）
  logic latched_flag;                       // 标记是否有待处理的 spike_mask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      spike_latched    <= '0;
      latched_flag     <= 1'b0;
      feedback_wl_data <= '0;
      feedback_valid   <= 1'b0;
    end else begin
      // 默认拉低有效信号（单拍脉冲）
      feedback_valid <= 1'b0;

      // 累积 spike_mask：cim_array_ctrl 每个 bit-plane × timestep 都会触发
      // 一次 lif_neuron_alu 遍历并产生 spike_mask_valid 脉冲。若直接赋值会
      // 只保留最后一次（= bit 0 of timestep T-1），对于稀疏 MNIST-like 输入
      // 几乎永远是全零，导致下一层输入为 0 → 永远预测 class 0（FP-009）。
      // 正确语义：OR 累积本层内所有 sub-step 的 spike（"本层内任一次 fire
      // 的神经元" = 1），直到 feedback_en 取走后清零准备下一层。
      if (spike_mask_valid) begin
        spike_latched <= spike_latched | spike_mask;
        latched_flag  <= 1'b1;
      end

      // 执行回注：layer_sequencer 在层间间隙拉高 feedback_en
      // 将 spike_mask 截取到 next_wl_count 位宽，超出部分填 0
      if (feedback_en && latched_flag) begin
        for (int i = 0; i < P_MAX_NEURONS; i++) begin
          feedback_wl_data[i] <= (i < int'(next_wl_count)) ? spike_latched[i] : 1'b0;
        end
        feedback_valid <= 1'b1;   // 通知 layer_sequencer 回注完成
        latched_flag   <= 1'b0;   // 清除锁存标记，防止重复回注
        spike_latched  <= '0;     // 清零累积器，准备下一层（不与下面的 OR 冲突，因为同拍不会有 spike_mask_valid）
      end
    end
  end

endmodule
