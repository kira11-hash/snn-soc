// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/snn/lif_neurons.sv
// Purpose: Implements the digital LIF neuron update/integration stage and spike generation for output neurons.
// Role in system: Converts signed ADC-domain accumulated inputs into spikes/membrane state updates for classification.
// Behavior summary: Integrates neuron inputs over sub-steps, compares against threshold, emits spikes, stores/queues outputs.
// Current design choice: Fixed threshold path is primary; adaptive-threshold experiments are evaluated in Python, not enabled by default.
// Data width note: Scheme-B differential subtraction requires signed neuron input and sufficient membrane width margin.
// Verification focus: Signed arithmetic, reset mode semantics, threshold compare, and output FIFO/event generation.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: lif_neurons.sv
// 模块名: lif_neurons
//
// 【功能概述】
// LIF（Leaky Integrate-and-Fire）神经元阵列，NUM_OUTPUTS=10 路并行。
// 接收来自 adc_ctrl 的 Scheme B 差分有符号输入，累积膜电位，
// 触发阈值时产生 spike 并通过内部队列写入 output FIFO。
//
// 【LIF 神经元原理】
// 标准 LIF 方程（离散化，无泄漏项）：
//   V[t] = V[t-1] + I[t]
//   if V[t] >= Vth:
//     spike = 1
//     V[t] = V[t] - Vth  (soft reset) 或  V[t] = 0  (hard reset)
//
// 本项目中：
//   I[t] = adc_out[i] * 2^bitplane_shift  （bit-plane 加权）
//   Vth  = neuron_threshold（32-bit 有符号正值，来自 reg_bank）
//
// 【bit-plane 加权机制】
// 输入像素 8-bit（0~255）被分解为 8 个 bit-plane（MSB→LSB）：
//   pixel = b7*128 + b6*64 + ... + b0*1
// cim_array_ctrl 依次发送每个 bit-plane，lif_neurons 对应累积：
//   membrane += adc_out * (1 << bitplane_shift)  （bitplane_shift 从 7 递减到 0）
// 等价于对完整像素值进行了加权 MAC，无需存储全精度像素。
//
// 【Scheme B 有符号输入】
// adc_ctrl 输出 NEURON_DATA_WIDTH=9 位有符号差分值（范围 -255 ~ +255）
// 膜电位 membrane 为 LIF_MEM_WIDTH=32 位有符号，留出足够位移余量：
//   最大累积 = 255 * (2^7) * 1 = 32640 < 2^15，32 位绰绰有余
//
// 【spike 队列机制】
// 同一 bit-plane 处理期间可能产生多个 neuron 的 spike，
// 内部环形队列（深度 32）缓存 spike（神经元 index 0~9），
// 每拍最多 pop 一个写入 output_fifo（4-bit 宽：存神经元编号 0~9）。
// pop 优先于 push：先 pop，再 push，临时变量保证同拍一致性。
//
// 【soft/hard reset】
// reset_mode=0（soft）：V = V - Vth（保留超阈部分，可在同一 timestep 再次触发）
// reset_mode=1（hard）：V = 0（彻底清零，每次 spike 后从零开始）
//
// 【输出格式】
// out_fifo_wdata[3:0] = 神经元编号（0~9，表示哪个输出神经元发出了 spike）
// 固件读取所有 spike 后统计各编号出现次数，取最多的作为分类结果。
//======================================================================
module lif_neurons (
  // ── 时钟和复位 ────────────────────────────────────────────────────────────
  input  logic clk,              // 系统时钟
  input  logic rst_n,            // 异步低有效复位
  input  logic soft_reset_pulse, // 软复位脉冲（来自 reg_bank，写 CIM_CTRL.SOFT_RESET=1 产生）
                                 // 作用：清空膜电位和内部 spike 队列（推理帧间隙调用）

  // ── 来自 cim_array_ctrl 的输入 ───────────────────────────────────────────
  input  logic neuron_in_valid,  // 有效脉冲：1 拍高，同拍 neuron_in_data 有效
  // neuron_in_data[i]：第 i 个输出神经元的 ADC 差分输入（有符号 NEURON_DATA_WIDTH 位）
  // 范围：-(2^ADC_BITS-1) ~ +(2^ADC_BITS-1) = -255 ~ +255（ADC_BITS=8）
  input  logic [snn_soc_pkg::NUM_OUTPUTS-1:0][snn_soc_pkg::NEURON_DATA_WIDTH-1:0] neuron_in_data,
  // bitplane_shift：当前 bit-plane 的位权（7=MSB,6,5,...,0=LSB）
  // 用于算术左移（等效于乘以 2^shift），实现 bit-plane 加权
  input  logic [$clog2(snn_soc_pkg::PIXEL_BITS)-1:0] bitplane_shift,
  input  logic [31:0] threshold,  // 脉冲阈值（来自 reg_bank.neuron_threshold，定版默认 10200）
  input  logic reset_mode,        // 复位模式：0=soft，1=hard（来自 reg_bank.reset_mode）

  // ── 到 output FIFO 的写接口 ──────────────────────────────────────────────
  // output FIFO 实例在 snn_soc_top 中，容量 OUTPUT_FIFO_DEPTH=256（足够容纳全部 spike）
  output logic out_fifo_push,       // 写 FIFO 请求（1 拍高）
  output logic [3:0] out_fifo_wdata,// 写 FIFO 数据：神经元编号（0~9）
  input  logic out_fifo_full        // FIFO 满标志：1=不能 push（背压）
);
  import snn_soc_pkg::*; // 引入 NUM_OUTPUTS、LIF_MEM_WIDTH 等包参数

  // ── 参数派生 ──────────────────────────────────────────────────────────────
  localparam int MEM_W      = LIF_MEM_WIDTH;          // 膜电位位宽（32 位有符号）
  localparam int BITPLANE_W = $clog2(PIXEL_BITS);     // bitplane_shift 位宽（log2(8)=3）
  // BITPLANE_MAX = PIXEL_BITS-1 = 7（bit-plane 范围 0~7）
  localparam logic [BITPLANE_W-1:0] BITPLANE_MAX = BITPLANE_W'(PIXEL_BITS-1);

  // ── 阈值符号扩展 ──────────────────────────────────────────────────────────
  // threshold 来自寄存器（32-bit 无符号，但值为正整数）
  // 膜电位为有符号数，比较时需要同符号；零扩展后当有符号处理（阈值始终为正）
  logic signed [MEM_W-1:0] threshold_ext;
  assign threshold_ext = $signed({{(MEM_W-32){1'b0}}, threshold});
  // 展开：threshold_ext[31:0] = threshold[31:0]，threshold_ext[MEM_W-1:32] = 0（当 MEM_W>32 时）
  // 当 MEM_W=32 时，threshold_ext = $signed(threshold)，直接解释为有符号正数

`ifndef SYNTHESIS
  // ── 仿真期间参数合法性检查 ────────────────────────────────────────────────
  initial begin
    // 位宽检查：LIF_MEM_WIDTH 必须足够容纳最大累积值
    // 最大单次贡献：2^(PIXEL_BITS-1) * (2^ADC_BITS-1) = 128 * 255 = 32640（<2^15）
    // NEURON_DATA_WIDTH + PIXEL_BITS = 9 + 8 = 17，32 位远超需求
    if (LIF_MEM_WIDTH < (NEURON_DATA_WIDTH + PIXEL_BITS)) begin
      $warning("[lif_neurons] LIF_MEM_WIDTH(%0d) 可能不足以容纳 NEURON_DATA_WIDTH=%0d, PIXEL_BITS=%0d 的移位累加",
               LIF_MEM_WIDTH, NEURON_DATA_WIDTH, PIXEL_BITS);
    end
    // 致命检查：LIF_MEM_WIDTH 必须 >= 32，否则阈值比较位宽不够
    if (LIF_MEM_WIDTH < 32) begin
      $fatal(1, "[lif_neurons] LIF_MEM_WIDTH(%0d) 小于阈值位宽 32，位宽不足",
             LIF_MEM_WIDTH);
    end
  end
`endif

  // ── 内部 spike 队列（环形缓冲区）────────────────────────────────────────
  // 用于在同一拍产生多个神经元 spike 时缓冲，每拍向 output FIFO pop 一个
  localparam int QDEPTH     = 32; // 队列深度（单拍最多 10 个神经元触发，32 留足余量）
  localparam int QADDR_BITS = $clog2(QDEPTH); // 队列指针位宽（log2(32)=5）

  // ── 内部状态寄存器 ────────────────────────────────────────────────────────
  // 膜电位阵列：10 个有符号 32-bit 值，下标对应神经元编号 0~9
  logic signed [MEM_W-1:0] membrane [0:NUM_OUTPUTS-1];

  // spike 环形队列（存储神经元编号，4-bit 足够 0~9）
  logic [3:0]  spike_q [0:QDEPTH-1];
  logic [QADDR_BITS-1:0] rd_ptr;          // 队列读指针（下一个待 pop 的位置）
  logic [QADDR_BITS-1:0] wr_ptr;          // 队列写指针（下一个待 push 的位置）
  logic [$clog2(QDEPTH+1)-1:0] q_count;   // 队列当前元素数
  logic queue_overflow;                    // 队列溢出标志（spike 丢弃警告）

  // lint 友好：queue_overflow 仅仿真观测用，不驱动任何逻辑
  wire _unused_queue_overflow = queue_overflow;

  integer i; // for 循环变量（用于 always_ff 内部迭代 NUM_OUTPUTS=10 个神经元）

  // ── 主逻辑（神经元更新 + spike 队列管理）────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin : lif_ff
    // 仿真用临时变量（automatic 语义：每次 always 触发时重新初始化）
    // 用于在同一 always_ff 拍内模拟 pop+push 的顺序操作
    int temp_count;    // 临时队列计数（用于本拍内的 pop+push 逻辑）
    int temp_rd_ptr;   // 临时读指针（pop 后更新）
    int temp_wr_ptr;   // 临时写指针（push 后更新）
    logic signed [MEM_W-1:0] new_mem;  // 当前神经元新膜电位（循环内临时）
    logic signed [MEM_W-1:0] addend;   // bit-plane 加权输入（符号扩展后左移）
    logic signed [NEURON_DATA_WIDTH-1:0] signed_in; // 有符号差分输入（9-bit）
    logic spike;       // 当前神经元是否触发 spike

    if (!rst_n) begin
      // ── 异步复位：清零所有状态 ─────────────────────────────────────────
      for (i = 0; i < NUM_OUTPUTS; i = i + 1) begin
        membrane[i] <= '0; // 全部膜电位清零
      end
      rd_ptr         <= '0;
      wr_ptr         <= '0;
      q_count        <= '0;
      out_fifo_push  <= 1'b0;
      out_fifo_wdata <= 4'h0;
      queue_overflow <= 1'b0;

    end else begin
      // ── 时钟上升沿正常逻辑 ─────────────────────────────────────────────
      // 默认：本拍不向 output FIFO 写数据，无溢出
      out_fifo_push  <= 1'b0;
      queue_overflow <= 1'b0;

      // ── 软复位（推理帧间调用）────────────────────────────────────────────
      // soft_reset_pulse 来自固件向 REG_CIM_CTRL 写 bit1=1，
      // 用于在两次推理之间清空膜电位和 spike 队列。
      if (soft_reset_pulse) begin
        for (i = 0; i < NUM_OUTPUTS; i = i + 1) begin
          membrane[i] <= '0; // 清空所有神经元膜电位
        end
        rd_ptr  <= '0;
        wr_ptr  <= '0;
        q_count <= '0; // 清空队列（丢弃未 pop 的 spike）

      end else begin
        // ── 正常工作时序 ─────────────────────────────────────────────────
        // 使用临时变量跟踪本拍内的队列指针变化：
        // 先 pop（移出一个 spike 到 output FIFO），再 push（可能新的 spike）
        // 这种方式避免同拍竞争，且允许 FIFO 满时先 pop 再 push（不丢失）
        temp_count  = int'(q_count);
        temp_rd_ptr = int'(rd_ptr);
        temp_wr_ptr = int'(wr_ptr);

        // ── Step 1: 尝试 pop 一个 spike 到 output FIFO ─────────────────
        // 条件：队列非空 且 output FIFO 未满（背压处理）
        // 每拍最多 pop 一个（串行化 spike 输出到 4-bit FIFO）
        if ((temp_count > 0) && !out_fifo_full) begin
          out_fifo_push  <= 1'b1;                     // 本拍 push 到 output FIFO
          out_fifo_wdata <= spike_q[temp_rd_ptr];     // 输出神经元编号（0~9）
          // 环形指针前进（wrap-around：到达末尾后回 0）
          temp_rd_ptr    = (temp_rd_ptr == QDEPTH-1) ? 0 : (temp_rd_ptr + 1);
          temp_count     = temp_count - 1;            // 队列计数 -1
        end

        // ── Step 2: 更新膜电位并产生新 spike（neuron_in_valid 有效时）──
        // neuron_in_valid 由 cim_array_ctrl 在 ST_ADC 完成后发出（1 拍脉冲）
        if (neuron_in_valid) begin
`ifndef SYNTHESIS
          /* verilator lint_off CMPCONST */
          // 仿真期间检查 bitplane_shift 不越界（必须在 [0, PIXEL_BITS-1] 范围内）
          assert (bitplane_shift <= BITPLANE_MAX)
            else $fatal(1, "[lif_neurons] bitplane_shift 越界: %0d", bitplane_shift);
          /* verilator lint_on CMPCONST */
`endif
          // 对 10 个输出神经元逐一更新（并行电路，展开为 10 个独立路径）
          for (i = 0; i < NUM_OUTPUTS; i = i + 1) begin
            // ── 有符号 bit-plane 加权累积 ────────────────────────────────
            // neuron_in_data[i] 是 9-bit 有符号差分值（Scheme B 输出）
            // 步骤：
            //   1) $signed(neuron_in_data[i])：解释为有符号数（范围 -255~+255）
            //   2) MEM_W'(signed_in)：符号扩展到 32-bit（保持符号）
            //   3) <<< bitplane_shift：算术左移（有符号，等效于乘以 2^shift）
            signed_in = $signed(neuron_in_data[i]);  // 9-bit 有符号提取
            addend = (MEM_W'(signed_in)) <<< bitplane_shift; // 符号扩展后算术左移
            // 注：MEM_W'(signed_in) 按 SV LRM §6.24.1 保留符号（sign-extending cast）
            new_mem = membrane[i] + addend; // 膜电位累积（有符号加法）

            // ── 阈值比较（有符号比较）────────────────────────────────────
            // threshold_ext 为正数，membrane 可能为负（负差分输入时）
            // 只有膜电位 >= 正阈值时才发出 spike
            if (new_mem >= threshold_ext) begin
              spike = 1'b1;
              // 复位膜电位
              if (reset_mode) begin
                new_mem = '0;             // hard reset：清零（彻底重置）
              end else begin
                new_mem = new_mem - threshold_ext; // soft reset：保留超阈部分
              end
            end else begin
              spike = 1'b0; // 膜电位未达阈值，不发 spike
            end

            membrane[i] <= new_mem; // 更新膜电位寄存器

            // ── spike 入队 ───────────────────────────────────────────────
            if (spike) begin
              if (temp_count < QDEPTH) begin
                // 队列未满：将神经元编号 i 入队
                spike_q[temp_wr_ptr] <= i[3:0]; // i[3:0]：取低4位（0~9 < 16）
                // 环形写指针前进
                temp_wr_ptr = (temp_wr_ptr == QDEPTH-1) ? 0 : (temp_wr_ptr + 1);
                temp_count  = temp_count + 1;
              end else begin
                // 队列已满：丢弃该 spike，置溢出标志（仿真可观测）
                // 正常使用下不应发生（QDEPTH=32 远大于单帧最大 spike 数 10）
                queue_overflow <= 1'b1;
              end
            end
          end // for i
        end // if neuron_in_valid

        // ── 将临时指针/计数写回寄存器 ────────────────────────────────────
        // 取低位（类型截断：int → QADDR_BITS/COUNT_W 位）
        rd_ptr  <= temp_rd_ptr[QADDR_BITS-1:0];
        wr_ptr  <= temp_wr_ptr[QADDR_BITS-1:0];
        q_count <= temp_count[$clog2(QDEPTH+1)-1:0];
      end
    end
  end
endmodule
