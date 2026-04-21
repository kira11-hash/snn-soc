`timescale 1ns/1ps
//======================================================================
// 文件名: layer_sequencer.sv
// 模块名: layer_sequencer
//
// 【功能概述】
// 多层 SNN 推理的"层调度器"。接收 CPU 的 START 命令后，自动按层序
// 依次执行推理，每层使用独立的描述符（wl/bl 范围、timesteps、阈值、
// 活跃神经元数量）。层间通过 spike_feedback 将本层 spike 回注为
// 下一层的输入。
//
// 【支持的层数】
// 最多 4 层（MAX_LAYERS=4），通过 num_layers 参数指定：
//   0=1 层，1=2 层，2=3 层，3=4 层
//
// 【状态机流程】
// IDLE → LOAD_DESC → RUN_LAYER → WAIT_DONE
//   ├─ 最后一层 → ALL_DONE → IDLE
//   └─ 非最后一层 → WAIT_ALU → FEEDBACK → CLEAR_MEM → LOAD_DESC → ...
//
// 【层描述符格式（每层 4 个 32-bit 字段）】
// - layer_cfg:       {bl_count[31:24], bl_offset[23:16], wl_count[15:8], wl_offset[7:0]}
// - layer_timing:    {use_bitplane[8], timesteps[7:0]}
// - layer_threshold: 32-bit LIF 阈值
// - layer_neuron_cfg: {neuron_count[7:0]}
//
// 【层间数据流】
// - 第 0 层：输入来自 DMA（标准 bit-plane 编码），use_bitplane=1
// - 中间层：输入来自 spike_feedback（binary spike），use_bitplane=0
// - 最后一层：spike 写入 output_fifo（output_fifo_en=1）
//======================================================================
module layer_sequencer #(
  parameter int P_MAX_LAYERS  = snn_soc_pkg::MAX_LAYERS,   // 最大层数（默认 4）
  parameter int P_MAX_NEURONS = snn_soc_pkg::MAX_NEURONS   // 最大神经元数（默认 128）
) (
  input  logic clk,                    // 系统时钟
  input  logic rst_n,                  // 异步低有效复位
  input  logic soft_reset_pulse,       // 软复位（清空状态，回到 IDLE）

  // ── CPU 控制接口 ──────────────────────────────────────────────────
  input  logic start_pulse,            // 启动多层推理（由 CIM_CTRL.START 触发）
  input  logic [1:0] num_layers,       // 层数 - 1（0=1层，1=2层，...，3=4层）
  output logic busy,                   // 推理忙（整个多层序列期间保持高）
  output logic done_pulse,             // 推理完成脉冲（所有层完成后单拍高）

  // ── 层描述符输入（从 reg_bank 读取）───────────────────────────────
  input  logic [P_MAX_LAYERS-1:0][31:0] layer_cfg,        // 层配置（wl/bl 范围）
  input  logic [P_MAX_LAYERS-1:0][31:0] layer_timing,     // 层时序（timesteps + use_bitplane）
  input  logic [P_MAX_LAYERS-1:0][31:0] layer_threshold,  // 层 LIF 阈值
  input  logic [P_MAX_LAYERS-1:0][31:0] layer_neuron_cfg, // 层活跃神经元数

  // ── 驱动 cim_array_ctrl ───────────────────────────────────────────
  output logic       ctrl_start_pulse,           // 启动本层推理
  input  logic       ctrl_done_pulse,            // 本层推理完成反馈
  output logic [7:0] ctrl_timesteps,             // 本层时间步数
  output logic       ctrl_binary_mode,           // 二值模式（=!use_bitplane）
  output logic       ctrl_use_layer_cfg,         // 使用层描述符而非全局配置
  output logic       ctrl_use_feedback,          // 使用 spike_feedback 输入

  // ── 驱动 adc_ctrl ────────────────────────────────────────────────
  output logic [7:0] ctrl_bl_scan_count,         // 本层 BL 扫描通道数
  output logic       ctrl_use_scan_cfg,          // 使用层特定扫描配置

  // ── 驱动 lif_neuron_alu ──────────────────────────────────────────
  output logic [31:0] ctrl_threshold,            // 本层 LIF 阈值
  output logic [7:0]  ctrl_active_neuron_count,  // 本层活跃神经元数

  // ── spike_feedback 控制 ──────────────────────────────────────────
  output logic       feedback_en,                // 允许 spike 回注到 input_fifo
  output logic [7:0] feedback_next_wl_count,     // 下一层的有效字线数量
  input  logic       feedback_valid,             // spike_feedback 回注完成

  // ── lif_neuron_alu 状态 ──────────────────────────────────────────
  input  logic       alu_busy,                   // ALU 正在遍历神经元
  output logic       alu_clear_pulse,            // 清零 ALU 膜电位（层间切换时）
  input  logic       alu_clearing,               // ALU 正在清零中
  output logic       ctrl_is_last_layer          // 当前是否最后一层（控制 output_fifo_en）
);

  // ── 状态机定义 ────────────────────────────────────────────────────
  typedef enum logic [2:0] {
    ST_IDLE      = 3'd0,  // 空闲
    ST_LOAD_DESC = 3'd1,  // 加载当前层描述符
    ST_RUN_LAYER = 3'd2,  // 配置并启动本层推理
    ST_WAIT_DONE = 3'd3,  // 等待 cim_array_ctrl 完成本层
    ST_WAIT_ALU  = 3'd4,  // 等待 lif_neuron_alu 处理完所有神经元
    ST_FEEDBACK  = 3'd5,  // 等待 spike_feedback 完成回注
    ST_ALL_DONE  = 3'd6,  // 所有层完成
    ST_CLEAR_MEM = 3'd7   // 清零 ALU 膜电位（准备下一层）
  } state_t;

  state_t state;
  logic [1:0] layer_idx;     // 当前正在执行的层索引（0~3）
  logic [1:0] layer_max;     // 最大层索引（= num_layers 的锁存值）

  // 判断当前是否最后一层（用于控制 output_fifo_en）
  assign ctrl_is_last_layer = (layer_idx == layer_max);

  // ── 当前层的锁存描述符 ────────────────────────────────────────────
  logic [7:0] cur_wl_count;   // 字线数量
  logic [7:0] cur_bl_count;   // 位线数量
  /* verilator lint_off UNUSEDSIGNAL */
  logic [7:0] cur_wl_offset;  // D1-007: 保留用于未来硬件多层 sub-array offset（当前未使用）
  logic [7:0] cur_bl_offset;  // D1-007: 同上
  /* verilator lint_on UNUSEDSIGNAL */
  logic [7:0] cur_timesteps;                 // 时间步数
  logic       cur_use_bitplane;              // 是否使用 bit-plane 编码
  logic [31:0] cur_threshold;                // LIF 阈值
  logic [7:0] cur_neuron_count;              // 活跃神经元数

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state                    <= ST_IDLE;
      layer_idx                <= 2'd0;
      layer_max                <= 2'd0;
      busy                     <= 1'b0;
      done_pulse               <= 1'b0;
      ctrl_start_pulse         <= 1'b0;
      ctrl_timesteps           <= 8'd0;
      ctrl_binary_mode         <= 1'b0;
      ctrl_use_layer_cfg       <= 1'b0;
      ctrl_use_feedback        <= 1'b0;
      ctrl_bl_scan_count       <= 8'd0;
      ctrl_use_scan_cfg        <= 1'b0;
      ctrl_threshold           <= 32'd0;
      ctrl_active_neuron_count <= 8'd0;
      feedback_en              <= 1'b0;
      feedback_next_wl_count   <= 8'd0;
      alu_clear_pulse          <= 1'b0;
      cur_wl_offset            <= 8'd0;
      cur_wl_count             <= 8'd0;
      cur_bl_offset            <= 8'd0;
      cur_bl_count             <= 8'd0;
      cur_timesteps            <= 8'd0;
      cur_use_bitplane         <= 1'b0;
      cur_threshold            <= 32'd0;
      cur_neuron_count         <= 8'd0;
    end else begin
      // 默认拉低单拍脉冲信号
      done_pulse       <= 1'b0;
      ctrl_start_pulse <= 1'b0;
      feedback_en      <= 1'b0;
      alu_clear_pulse  <= 1'b0;

      // ── 软复位：清空状态回到 IDLE ─────────────────────────────────
      if (soft_reset_pulse) begin
        state            <= ST_IDLE;
        busy             <= 1'b0;
        ctrl_use_layer_cfg <= 1'b0;
        ctrl_use_feedback  <= 1'b0;
        ctrl_use_scan_cfg  <= 1'b0;
      end else begin
        case (state)
          // ── 空闲：等待 CPU 启动 ───────────────────────────────────
          ST_IDLE: begin
            if (start_pulse) begin
              layer_idx <= 2'd0;
              layer_max <= num_layers;     // 锁存层数配置
              busy      <= 1'b1;
              state     <= ST_LOAD_DESC;
            end
          end

          // ── 加载当前层描述符 ──────────────────────────────────────
          // 从 reg_bank 的层描述符数组中按 layer_idx 读取对应配置
          // D1-007 说明：cur_wl_offset / cur_bl_offset 当前未用于硬件寻址
          //   —— V2 时间多层为固件驱动，每层使用全阵列且由 CPU 重编程权重，
          //   不需要 sub-array offset；字段保留供未来硬件自动化多层使用（此时会
          //   驱动 cim_array_ctrl 的 row/col 起点）。read-modify-write 值保持
          //   可观测以便调试 / 软件 self-check。
          ST_LOAD_DESC: begin
            case (layer_idx)
              2'd0: begin cur_wl_offset<=layer_cfg[0][7:0]; cur_wl_count<=layer_cfg[0][15:8]; cur_bl_offset<=layer_cfg[0][23:16]; cur_bl_count<=layer_cfg[0][31:24]; cur_timesteps<=layer_timing[0][7:0]; cur_use_bitplane<=layer_timing[0][8]; cur_threshold<=layer_threshold[0]; cur_neuron_count<=layer_neuron_cfg[0][7:0]; end
              2'd1: begin cur_wl_offset<=layer_cfg[1][7:0]; cur_wl_count<=layer_cfg[1][15:8]; cur_bl_offset<=layer_cfg[1][23:16]; cur_bl_count<=layer_cfg[1][31:24]; cur_timesteps<=layer_timing[1][7:0]; cur_use_bitplane<=layer_timing[1][8]; cur_threshold<=layer_threshold[1]; cur_neuron_count<=layer_neuron_cfg[1][7:0]; end
              2'd2: begin cur_wl_offset<=layer_cfg[2][7:0]; cur_wl_count<=layer_cfg[2][15:8]; cur_bl_offset<=layer_cfg[2][23:16]; cur_bl_count<=layer_cfg[2][31:24]; cur_timesteps<=layer_timing[2][7:0]; cur_use_bitplane<=layer_timing[2][8]; cur_threshold<=layer_threshold[2]; cur_neuron_count<=layer_neuron_cfg[2][7:0]; end
              2'd3: begin cur_wl_offset<=layer_cfg[3][7:0]; cur_wl_count<=layer_cfg[3][15:8]; cur_bl_offset<=layer_cfg[3][23:16]; cur_bl_count<=layer_cfg[3][31:24]; cur_timesteps<=layer_timing[3][7:0]; cur_use_bitplane<=layer_timing[3][8]; cur_threshold<=layer_threshold[3]; cur_neuron_count<=layer_neuron_cfg[3][7:0]; end
            endcase
            state <= ST_RUN_LAYER;
          end

          // ── 配置并启动本层推理 ────────────────────────────────────
          ST_RUN_LAYER: begin
            ctrl_timesteps           <= cur_timesteps;
            ctrl_binary_mode         <= ~cur_use_bitplane;   // binary = !use_bitplane
            ctrl_use_layer_cfg       <= 1'b1;
            ctrl_bl_scan_count       <= cur_bl_count;
            ctrl_use_scan_cfg        <= 1'b1;
            ctrl_threshold           <= cur_threshold;
            ctrl_active_neuron_count <= cur_neuron_count;
            // 第 0 层输入来自 DMA，非第 0 层输入来自 spike_feedback
            ctrl_use_feedback        <= (layer_idx != 2'd0);
            ctrl_start_pulse         <= 1'b1;                // 触发 cim_array_ctrl
            state                    <= ST_WAIT_DONE;
          end

          // ── 等待本层推理完成 ──────────────────────────────────────
          ST_WAIT_DONE: begin
            if (ctrl_done_pulse) begin
              if (layer_idx == layer_max) begin
                state <= ST_ALL_DONE;    // 最后一层完成
              end else begin
                // 提前准备下一层的 wl_count（用于 spike_feedback 截取宽度）
                case (layer_idx)
                  2'd0: feedback_next_wl_count <= layer_cfg[1][15:8];
                  2'd1: feedback_next_wl_count <= layer_cfg[2][15:8];
                  2'd2: feedback_next_wl_count <= layer_cfg[3][15:8];
                  default: feedback_next_wl_count <= 8'd0;
                endcase
                state <= ST_WAIT_ALU;    // 等待 ALU 完成神经元遍历
              end
            end
          end

          // ── 等待 ALU 完成所有神经元处理 ───────────────────────────
          ST_WAIT_ALU: begin
            if (!alu_busy) begin
              feedback_en <= 1'b1;       // 触发 spike_feedback 回注
              state       <= ST_FEEDBACK;
            end
          end

          // ── 等待 spike_feedback 完成回注 ──────────────────────────
          ST_FEEDBACK: begin
            if (feedback_valid) begin
              layer_idx       <= layer_idx + 2'd1;  // 前进到下一层
              alu_clear_pulse <= 1'b1;               // 清零 ALU 膜电位
              state           <= ST_CLEAR_MEM;
            end
          end

          // ── 等待 ALU 膜电位清零完成 ───────────────────────────────
          ST_CLEAR_MEM: begin
            if (!alu_clearing) begin
              state <= ST_LOAD_DESC;     // 加载下一层描述符
            end
          end

          // ── 所有层完成 ────────────────────────────────────────────
          ST_ALL_DONE: begin
            busy             <= 1'b0;
            done_pulse       <= 1'b1;     // 通知 CPU 推理完成
            ctrl_use_layer_cfg <= 1'b0;
            ctrl_use_feedback  <= 1'b0;
            ctrl_use_scan_cfg  <= 1'b0;
            state            <= ST_IDLE;
          end

          default: state <= ST_IDLE;
        endcase
      end
    end
  end

endmodule
