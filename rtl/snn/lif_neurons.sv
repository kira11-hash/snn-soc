`timescale 1ns/1ps
//======================================================================
// 文件名: lif_neurons.sv
// 描述: LIF 神经元阵列（10 路并行，Scheme B 有符号输入）。
//       - neuron_in_valid 时更新膜电位（有符号累加）
//       - 触发阈值产生 spike，并按 reset_mode 复位
//       - spike 事件按 i=0..9 顺序写入 output_fifo
//       - 内部使用小队列缓存同一 timestep 的多个 spike
//======================================================================
module lif_neurons (
  input  logic clk,
  input  logic rst_n,
  input  logic soft_reset_pulse,

  input  logic neuron_in_valid,
  input  logic [snn_soc_pkg::NUM_OUTPUTS-1:0][snn_soc_pkg::NEURON_DATA_WIDTH-1:0] neuron_in_data,
  input  logic [$clog2(snn_soc_pkg::PIXEL_BITS)-1:0] bitplane_shift,
  input  logic [31:0] threshold,
  input  logic reset_mode,

  output logic out_fifo_push,
  output logic [3:0] out_fifo_wdata,
  input  logic out_fifo_full
);
  import snn_soc_pkg::*;

  // bit-plane 加权累加位宽（有符号）
  localparam int MEM_W = LIF_MEM_WIDTH;
  localparam int BITPLANE_W = $clog2(PIXEL_BITS);
  localparam logic [BITPLANE_W-1:0] BITPLANE_MAX = BITPLANE_W'(PIXEL_BITS-1);

  // 阈值扩展为有符号（阈值始终为正，高位补 0 即可）
  logic signed [MEM_W-1:0] threshold_ext;
  assign threshold_ext = $signed({{(MEM_W-32){1'b0}}, threshold});

`ifndef SYNTHESIS
  // 参数检查：位宽需留出移位累加余量
  initial begin
    if (LIF_MEM_WIDTH < (NEURON_DATA_WIDTH + PIXEL_BITS)) begin
      $warning("[lif_neurons] LIF_MEM_WIDTH(%0d) 可能不足以容纳 NEURON_DATA_WIDTH=%0d, PIXEL_BITS=%0d 的移位累加",
               LIF_MEM_WIDTH, NEURON_DATA_WIDTH, PIXEL_BITS);
    end
    if (LIF_MEM_WIDTH < 32) begin
      $fatal(1, "[lif_neurons] LIF_MEM_WIDTH(%0d) 小于阈值位宽 32，位宽不足",
             LIF_MEM_WIDTH);
    end
  end
`endif

  localparam int QDEPTH = 32; // spike 缓存深度，足够容纳多个 timestep 的事件
  localparam int QADDR_BITS = $clog2(QDEPTH);

  // 膜电位为有符号数（Scheme B 差分输入可为负）
  logic signed [MEM_W-1:0] membrane [0:NUM_OUTPUTS-1];
  logic [3:0]  spike_q [0:QDEPTH-1];
  logic [QADDR_BITS-1:0] rd_ptr;
  logic [QADDR_BITS-1:0] wr_ptr;
  logic [$clog2(QDEPTH+1)-1:0] q_count;
  logic queue_overflow;
  // 标记未使用信号（lint 友好）
  wire _unused_queue_overflow = queue_overflow;

  integer i;

  // 输出 FIFO 写入与神经元更新
  always_ff @(posedge clk or negedge rst_n) begin : lif_ff
    int temp_count;
    int temp_rd_ptr;
    int temp_wr_ptr;
    logic signed [MEM_W-1:0] new_mem;
    logic signed [MEM_W-1:0] addend;
    logic signed [NEURON_DATA_WIDTH-1:0] signed_in;
    logic        spike;
    if (!rst_n) begin
      for (i = 0; i < NUM_OUTPUTS; i = i + 1) begin
        membrane[i] <= '0;
      end
      rd_ptr        <= '0;
      wr_ptr        <= '0;
      q_count       <= '0;
      out_fifo_push <= 1'b0;
      out_fifo_wdata<= 4'h0;
      queue_overflow<= 1'b0;
    end else begin
      out_fifo_push  <= 1'b0;
      queue_overflow <= 1'b0;

      // 软复位：清空膜电位与队列
      if (soft_reset_pulse) begin
        for (i = 0; i < NUM_OUTPUTS; i = i + 1) begin
          membrane[i] <= '0;
        end
        rd_ptr   <= '0;
        wr_ptr   <= '0;
        q_count  <= '0;
      end else begin
        // 使用临时变量保证同拍 pop + 多个 enqueue 的顺序
        temp_count  = int'(q_count);
        temp_rd_ptr = int'(rd_ptr);
        temp_wr_ptr = int'(wr_ptr);

        // 先尝试从队列 pop 一个 spike 到 output_fifo
        if ((temp_count > 0) && !out_fifo_full) begin
          out_fifo_push  <= 1'b1;
          out_fifo_wdata <= spike_q[temp_rd_ptr];
          temp_rd_ptr    = (temp_rd_ptr == QDEPTH-1) ? 0 : (temp_rd_ptr + 1);
          temp_count     = temp_count - 1;
        end

        // neuron_in_valid 到来：更新膜电位并写入 spike 队列
        if (neuron_in_valid) begin
`ifndef SYNTHESIS
          /* verilator lint_off CMPCONST */
          assert (bitplane_shift <= BITPLANE_MAX)
            else $fatal(1, "[lif_neurons] bitplane_shift 越界: %0d", bitplane_shift);
          /* verilator lint_on CMPCONST */
`endif
          for (i = 0; i < NUM_OUTPUTS; i = i + 1) begin
            // Scheme B: neuron_in_data[i] 为有符号差分值
            // 符号扩展到 MEM_W 位后进行算术左移（bit-plane 加权）
            signed_in = $signed(neuron_in_data[i]);
            addend = (MEM_W'(signed_in)) <<< bitplane_shift;
            new_mem = membrane[i] + addend;
            // 有符号阈值比较：膜电位 >= 正阈值时触发
            if (new_mem >= threshold_ext) begin
              spike = 1'b1;
              if (reset_mode) begin
                new_mem = '0; // hard reset
              end else begin
                new_mem = new_mem - threshold_ext; // soft reset
              end
            end else begin
              spike = 1'b0;
            end

            membrane[i] <= new_mem;

            if (spike) begin
              if (temp_count < QDEPTH) begin
                spike_q[temp_wr_ptr] <= i[3:0];
                temp_wr_ptr = (temp_wr_ptr == QDEPTH-1) ? 0 : (temp_wr_ptr + 1);
                temp_count  = temp_count + 1;
              end else begin
                queue_overflow <= 1'b1; // 队列溢出，丢弃该 spike
              end
            end
          end
        end

        rd_ptr  <= temp_rd_ptr[QADDR_BITS-1:0];
        wr_ptr  <= temp_wr_ptr[QADDR_BITS-1:0];
        q_count <= temp_count[$clog2(QDEPTH+1)-1:0];
      end
    end
  end
endmodule
