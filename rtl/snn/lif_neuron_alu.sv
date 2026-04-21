`timescale 1ns/1ps
//======================================================================
// 文件名: lif_neuron_alu.sv
// 模块名: lif_neuron_alu
//
// 【功能概述】
// V2 多层推理专用的时分复用 LIF 神经元 ALU。
// 与 V1 的 lif_neurons（10 路并行）不同，本模块用串行流水线
// 依次处理最多 MAX_NEURONS=128 个神经元，适用于多层 SNN 中每层
// 神经元数量不同的场景。
//
// 【工作原理】
// 1. 每当 neuron_in_valid 拉高，启动一轮遍历：
//    从 neuron_idx=0 到 active_neuron_count-1，逐个处理
// 2. 每个神经元的处理（2 级流水线）：
//    - Stage 0：从 mem_array 读出膜电位，锁存输入
//    - Stage 1：计算 addend = input <<< bitplane_shift，累加到膜电位，
//      判阈值，产生 spike
// 3. spike 写入内部队列（深度 32），每拍最多 pop 一个到 output_fifo
// 4. 所有神经元处理完后，产生 spike_mask_valid 和 spike_mask
//
// 【与 V1 lif_neurons 的关系】
// - V1 场景（单层推理）：snn_soc_top 中通过 generate 选择 lif_neurons
// - V2 场景（多层推理）：snn_soc_top 中 lif_neuron_alu 和 lif_neurons
//   同时存在，由 ml_mode_active 信号选择谁接收 neuron_in_valid
// - output_fifo_en 控制是否将 spike 推入 output_fifo：
//   只有最后一层（ctrl_is_last_layer=1）才推，中间层只产生 spike_mask
//
// 【膜电位清零】
// soft_reset_pulse 或 alu_clear_pulse 触发 clearing 模式：
// 逐拍将 mem_array[0..MAX_NEURONS-1] 清零，期间不接受新的推理请求。
// clearing_busy 输出让 layer_sequencer 知道何时清零完成。
//======================================================================
module lif_neuron_alu #(
  parameter int P_MAX_NEURONS = snn_soc_pkg::MAX_NEURONS  // 最大神经元数（默认 128）
) (
  input  logic clk,                    // 系统时钟
  input  logic rst_n,                  // 异步低有效复位
  input  logic soft_reset_pulse,       // 软复位（层间切换时清零膜电位）

  // ── 来自 cim_array_ctrl / adc_ctrl 的输入 ──────────────────────────
  input  logic neuron_in_valid,        // 有效脉冲：本轮 ADC 差分结果就绪
  // neuron_in_data[i]：第 i 个神经元的 ADC 差分输入（有符号 NEURON_DATA_WIDTH 位）
  input  logic [P_MAX_NEURONS-1:0][snn_soc_pkg::NEURON_DATA_WIDTH-1:0] neuron_in_data,
  input  logic [$clog2(snn_soc_pkg::PIXEL_BITS)-1:0] bitplane_shift, // 当前 bit-plane 位权
  input  logic [31:0] threshold,       // LIF 阈值（本层，来自 layer_sequencer）
  input  logic reset_mode,             // 膜电位复位模式：0=soft，1=hard

  // ── 来自 layer_sequencer 的配置 ────────────────────────────────────
  input  logic [7:0] active_neuron_count,  // 本层活跃神经元数量

  // ── 到 output FIFO 的写接口 ───────────────────────────────────────
  output logic out_fifo_push,                              // FIFO 写请求
  output logic [$clog2(P_MAX_NEURONS)-1:0] out_fifo_wdata, // FIFO 写数据（神经元编号）
  input  logic out_fifo_full,                              // FIFO 满标志

  // ── spike 结果输出 ────────────────────────────────────────────────
  output logic [P_MAX_NEURONS-1:0] spike_mask,       // 本轮所有神经元的 spike 位图
  output logic spike_mask_valid,                     // spike_mask 有效脉冲
  output logic alu_busy,                             // ALU 正在遍历神经元
  output logic spike_q_overflow,                     // spike 队列溢出（调试用）
  output logic clearing_busy,                        // 正在清零膜电位

  // ── 来自 layer_sequencer 的控制 ────────────────────────────────────
  input  logic output_fifo_en   // 是否将 spike 推入 output_fifo（仅最后一层=1）
);
  import snn_soc_pkg::*;

  // ── 参数派生 ──────────────────────────────────────────────────────
  localparam int MEM_W      = LIF_MEM_WIDTH;         // 膜电位位宽（32 位有符号）
  localparam int NDW        = NEURON_DATA_WIDTH;      // 输入数据位宽（9 位有符号）
  localparam int IDX_W      = $clog2(P_MAX_NEURONS);  // 神经元索引位宽（7 位）
  localparam int QDEPTH     = 32;                     // spike 队列深度
  localparam int QADDR_W    = $clog2(QDEPTH);         // 队列地址位宽（5 位）

  // 阈值符号扩展：threshold 是无符号 32-bit，扩展到有符号 MEM_W 位
  logic signed [MEM_W-1:0] threshold_ext;
  assign threshold_ext = $signed({{(MEM_W-32){1'b0}}, threshold});

  // ── 膜电位存储阵列 ────────────────────────────────────────────────
  // 每个神经元一个 32-bit 有符号膜电位，最多 MAX_NEURONS 个
`ifdef FPGA_BEHAVIORAL
  (* ram_style = "block" *) logic signed [MEM_W-1:0] mem_array [0:P_MAX_NEURONS-1];
`else
  logic signed [MEM_W-1:0] mem_array [0:P_MAX_NEURONS-1];
`endif

  // ── 流水线寄存器 ──────────────────────────────────────────────────
  logic        running;          // 正在遍历神经元
  logic [7:0]  neuron_idx;       // 当前处理的神经元索引
  logic [7:0]  neuron_limit;     // 本轮需要处理的神经元总数

  logic        s1_valid;         // Stage 1 有效
  logic [7:0]  s1_idx;           // Stage 1 处理的神经元索引
  logic signed [MEM_W-1:0] s1_mem_rd;   // Stage 1 读出的膜电位
  logic signed [NDW-1:0]   s1_input;    // Stage 1 锁存的输入值

  // ── spike 内部队列 ────────────────────────────────────────────────
  // spike 产生可能集中在短时间内（多个神经元同时超阈值），
  // 但 output_fifo 每拍只能接收一个，因此用队列缓冲
  logic [IDX_W-1:0] spike_q [0:QDEPTH-1];
  logic [QADDR_W-1:0] sq_rd_ptr, sq_wr_ptr;
  logic [$clog2(QDEPTH+1)-1:0] sq_count;

  // ── 膜电位清零控制 ────────────────────────────────────────────────
  logic        clearing;         // 正在逐拍清零 mem_array
  logic [7:0]  clear_idx;        // 当前清零的索引
  assign clearing_busy = clearing;

  always_ff @(posedge clk or negedge rst_n) begin
    // 临时变量（组合逻辑语义，用于 Stage 1 计算）
    logic signed [MEM_W-1:0] addend;
    logic signed [MEM_W-1:0] new_mem;
    logic spike_bit;
    logic draining_this_cycle;

    // spike 队列的临时指针（blocking 赋值，用于同拍 push+drain 协调）
    int tq_count;
    int tq_wr_ptr;

    if (!rst_n) begin
      running         <= 1'b0;
      neuron_idx      <= 8'd0;
      neuron_limit    <= 8'd0;
      s1_valid        <= 1'b0;
      s1_idx          <= 8'd0;
      s1_mem_rd       <= '0;
      s1_input        <= '0;
      out_fifo_push   <= 1'b0;
      out_fifo_wdata  <= '0;
      spike_mask      <= '0;
      spike_mask_valid <= 1'b0;
      alu_busy        <= 1'b0;
      sq_rd_ptr       <= '0;
      sq_wr_ptr       <= '0;
      sq_count        <= '0;
      spike_q_overflow <= 1'b0;
      clearing        <= 1'b1;     // 上电后自动清零膜电位
      clear_idx       <= 8'd0;
    end else begin
      // 默认拉低单拍脉冲
      out_fifo_push    <= 1'b0;
      spike_mask_valid <= 1'b0;
      draining_this_cycle = 1'b0;

      // ── spike 队列排空：每拍最多弹出一个到 output_fifo ────────────
      if ((sq_count > 0) && !out_fifo_full) begin
        draining_this_cycle = 1'b1;
        out_fifo_push  <= 1'b1;
        out_fifo_wdata <= spike_q[sq_rd_ptr];
        sq_rd_ptr      <= (sq_rd_ptr == QADDR_W'(QDEPTH-1)) ? '0 : (sq_rd_ptr + 1'b1);
        sq_count       <= sq_count - 1'b1;
      end

      // ── 软复位触发清零 ────────────────────────────────────────────
      if (soft_reset_pulse && !clearing) begin
        clearing  <= 1'b1;
        clear_idx <= 8'd0;
        sq_rd_ptr <= '0;
        sq_wr_ptr <= '0;
        sq_count  <= '0;
        running   <= 1'b0;
        s1_valid  <= 1'b0;
        alu_busy  <= 1'b0;
        spike_q_overflow <= 1'b0;
      end

      // ── 逐拍清零 mem_array ────────────────────────────────────────
      if (clearing) begin
        mem_array[IDX_W'(clear_idx)] <= '0;
        if (clear_idx == 8'(P_MAX_NEURONS - 1)) begin
          clearing <= 1'b0;            // 清零完成
        end else begin
          clear_idx <= clear_idx + 8'd1;
        end
      end

      // ── 启动遍历：neuron_in_valid 触发 ───────────────────────────
      if (neuron_in_valid && !running && !clearing) begin
        running      <= 1'b1;
        neuron_idx   <= 8'd0;
        neuron_limit <= active_neuron_count;
        spike_mask   <= '0;            // 清空本轮 spike 位图
        alu_busy     <= 1'b1;
      end

      // ── Stage 0：发出读请求，锁存输入 ────────────────────────────
      if (running && !clearing) begin
        if (neuron_idx < neuron_limit) begin
          s1_valid  <= 1'b1;
          s1_idx    <= neuron_idx;
          s1_mem_rd <= mem_array[IDX_W'(neuron_idx)];       // 读出当前膜电位
          s1_input  <= $signed(neuron_in_data[neuron_idx]);  // 锁存有符号输入
          neuron_idx <= neuron_idx + 8'd1;
        end else begin
          s1_valid <= 1'b0;
          // 等待 Stage 1 排空后结束遍历
          if (!s1_valid) begin
            running          <= 1'b0;
            spike_mask_valid <= 1'b1;  // 通知 spike_feedback 可以取 mask
            alu_busy         <= 1'b0;
          end
        end
      end

      // ── Stage 1：计算膜电位 + 阈值判断 + spike 生成 ──────────────
      if (s1_valid && !clearing) begin
        // bit-plane 加权：input × 2^bitplane_shift（算术左移保留符号）
        addend  = (MEM_W'(s1_input)) <<< bitplane_shift;
        new_mem = s1_mem_rd + addend;

        // 阈值比较
        if (new_mem >= threshold_ext) begin
          spike_bit = 1'b1;
          // 膜电位复位
          if (reset_mode)
            new_mem = '0;              // hard reset：清零
          else
            new_mem = new_mem - threshold_ext;  // soft reset：减去阈值
        end else begin
          spike_bit = 1'b0;
        end

        // 写回膜电位
        mem_array[IDX_W'(s1_idx)] <= new_mem;

        // spike 处理
        if (spike_bit) begin
          spike_mask[IDX_W'(s1_idx)] <= 1'b1;   // 记录到 spike 位图

          // 如果是最后一层，将 spike 推入队列等待写入 output_fifo
          if (output_fifo_en) begin
            // 用 blocking 赋值协调同拍的 drain 和 push
            tq_count  = int'(sq_count) - int'(draining_this_cycle);
            tq_wr_ptr = int'(sq_wr_ptr);
            if (tq_count < QDEPTH) begin
              spike_q[tq_wr_ptr] <= IDX_W'(s1_idx);
              tq_wr_ptr = (tq_wr_ptr == QDEPTH-1) ? 0 : (tq_wr_ptr + 1);
              tq_count  = tq_count + 1;
              sq_wr_ptr <= QADDR_W'(tq_wr_ptr);
              sq_count  <= $bits(sq_count)'(tq_count);
            end else begin
              spike_q_overflow <= 1'b1; // 队列满，溢出警告
            end
          end
        end
      end

    end
  end

  // ── 参数合法性检查（仅仿真时生效）─────────────────────────────────
`ifndef SYNTHESIS
  initial begin
    if (P_MAX_NEURONS > 256)
      $fatal(1, "[lif_neuron_alu] P_MAX_NEURONS=%0d 超过上限 256", P_MAX_NEURONS);
  end
`endif

endmodule
