`timescale 1ns/1ps
// =============================================================================
// 【面试讲解 cheat sheet · spike_feedback.sv】 —— 设计者视角
//
// 一、它是 V2.B multilayer 的"层间 spike 桥"
//   一层推理结束后，lif_neuron_alu 输出一个 spike_mask 位图（每 bit =
//   该 neuron 是否在本层发了 spike）。本模块的工作：把这张位图转换成
//   下一层的输入向量（feedback_wl_data），由 cim_array_ctrl 写到
//   input_fifo。位置：lif_neuron_alu → spike_feedback → cim_array_ctrl
//   → 下一层 cim_macro → ...
//
//   如果没有这一层：FW 必须读 spike → 写 input_fifo → 重启层，bus
//   开销和延迟都难以接受。把"层间数据流"硬件化是 multilayer 性能关键。
//
// 二、面试最容易被深问的 2 个点（这是踩过坑修过的真实 bug）
//   1) 为什么是 spike_latched |= spike_mask（OR 累积）而不是直接赋值？
//      这是开发过程中真实修过的 bug（见本文件 always_ff 块内注释，已经
//      详细记录修复前后的语义差别）：
//      cim_array_ctrl 在每个 bit-plane × timestep 都会触发一次
//      lif_neuron_alu 遍历，并产生 spike_mask_valid。一层推理总共产生
//      T × PIXEL_BITS 次（T=10, PIXEL_BITS=8 → 80 次）spike_mask_valid。
//      如果直接 spike_latched <= spike_mask（覆盖式），最终保留的是
//      最后一次（即 timestep T-1 的 bit 0），对稀疏 MNIST-like 输入
//      最后一拍几乎全 0 → 下一层输入永远 0 → 模型永远预测 class 0。
//      正确语义："本层内任一次 fire 的 neuron"都算 spike，所以必须
//      OR 累积；只有 feedback_en（层间）拉高时才把累积器清零，准备
//      下一层。这是个典型的"语义和直觉不一致"的 bug：硬件上每条
//      spike_mask_valid 看着像独立事件，但层级语义上它们要"或起来"才
//      正确。
//
//   2) feedback_en && latched_flag 这个双重 gate 的作用？
//      - feedback_en 是 layer_sequencer 在层间发出的"现在可以回注了"。
//      - latched_flag 是"是否已经有累积过 spike"。
//      只有两个都为 1 才执行回注。原因：
//      - 如果只看 feedback_en：在 layer_sequencer 没等齐 spike 时
//        feedback_en 误拉高，回注全 0，准确率掉。
//      - 如果只看 latched_flag：每次 spike_mask_valid 都触发一次回注，
//        把数据无序灌到 input_fifo（在层尚未完成时），下层读到不完整
//        spike → 行为不可预测。
//      双重 gate 本质上是把"数据准备好"和"调度允许"解耦，是 FSM 协作
//      模式里的标准技巧。
//
// 三、关键设计指标
//   - spike_mask 位宽 = MAX_NEURONS = 128（V2.B 上限）。
//   - 单层 spike 累积器：128-bit reg + 1-bit flag。
//   - 回注操作：1 拍执行（截取到 next_wl_count 位 + 清累积器 + 拉
//     feedback_valid 单拍 strobe）。
//
// 四、Corner case
//   - 同拍 spike_mask_valid 与 feedback_en 同时高：理论上不会发生
//     （layer_sequencer 是状态机，spike_mask_valid 由本层 alu 在
//     WAIT_ALU 阶段发出，feedback_en 在 FEEDBACK 阶段发出，FSM 不
//     允许两个状态同时）。但 RTL 里我把"清累积器"和"OR 累积"分别
//     放在两个独立 if 分支，靠 always_ff 后赋值优先：feedback_en 那
//     个分支后写，会覆盖 OR 那个分支——即便上游 FSM 出 bug 也不会
//     让累积器卡住。这是防御性写法。
//   - next_wl_count > MAX_NEURONS：循环 `for (i = 0; i < P_MAX_NEURONS;
//     i++)` 物理上限就是 P_MAX_NEURONS，超出 next_wl_count 的位被
//     填 0；如果 next_wl_count > P_MAX_NEURONS，多出的部分根本进不
//     了循环——硬件上限保护，FW 不需要 clamp。
//
// 五、可能的优化（TODO优化方向）
//   - TODO优化方向：spike_latched 用 BRAM 做（128 bit 不值得 BRAM；
//     但若未来 MAX_NEURONS 升到 1024+，应该考虑 BRAM 推断 + 流式
//     OR 累积，避免 1024-bit reg fanout 影响 P&R）。
// =============================================================================

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
      // 几乎永远是全零，导致下一层输入为 0 → 永远预测 class 0。
      // （注：原 commit 注释里此处引用了"FP-009"误报编号，但 CLAUDE.md
      // 误报库实际只到 FP-005，FP-009 是笔误；此 bug 是开发过程中真实
      // 抓到并修复的，行为分析见本文件顶部 cheat sheet。）
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
