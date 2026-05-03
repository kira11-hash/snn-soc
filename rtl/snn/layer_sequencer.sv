`timescale 1ns/1ps
// =============================================================================
// 【面试讲解 cheat sheet · layer_sequencer.sv】 —— 设计者视角
//
// 一、它在 V2.B multilayer 路径里的位置
//   它是"硬件层调度大脑"。CPU 一次写入 4 套层描述符 + START，本模块自动
//   按层序执行：层 0 → spike_feedback 回注 → 层 1 → ... → 最后一层把
//   spike 写到 output_fifo。如果不上这个调度器，FW 必须在每层之间手动
//   ping-pong：发 START → 轮询 DONE → 切换 input source → 清膜电位 →
//   再发 START，bus 开销大、容易漏步骤。
//
// 二、面试最容易被深问的 3 个点
//   1) 为什么 FSM 要 8 个状态而不是 3 个？
//      最少能跑：IDLE → RUN_LAYER → DONE。但实际要分这么细：
//      - LOAD_DESC：从 4×layer_cfg/timing/threshold/neuron_cfg 寄存器
//        阵列里取出当前 layer_idx 的描述符，需要单独一拍让 reg fanout
//        被 mux 选中并寄存（不寄会让长 mux 出现在 ctrl_* 输出路径上）。
//      - RUN_LAYER：发 ctrl_start_pulse 一拍 strobe（必须独立拍，不能
//        和 LOAD_DESC 合并，否则 cim_array_ctrl 看到 cfg 还没稳定）。
//      - WAIT_DONE：等 cim_array_ctrl 推理完成。
//      - WAIT_ALU：等 lif_neuron_alu 把所有 neuron 遍历完（ALU 是串行
//        扫描各 neuron 累计 spike，可能比推理 done 晚几拍）。
//      - FEEDBACK：触发 spike_feedback 把本层 spike 转成下一层输入。
//      - CLEAR_MEM：清 ALU 膜电位，准备下一层。
//      - ALL_DONE/IDLE：层间 vs 整体完成的边界。
//      把每件事拆独立状态，单拍语义清楚，bug 时打个 state trace 就能
//      定位卡在哪一步——这是 V2 多层任务里 silicon bring-up 的关键。
//
//   2) 为什么 layer_cfg 不放进 SRAM 用 BRAM 推断，而是放成 unpacked
//      array of 32-bit reg？
//      MAX_LAYERS=4 → 16 个 32-bit reg = 64 bytes，太小不值得 BRAM
//      推断（Vivado 阈值 ~64 word）；用 LUT/FF 实现，访问 latency 0
//      （组合 mux）。同时 layer 描述符是 CPU 配置阶段一次性写入，运行
//      时只读，不需要专门读端口——直接 mux 选 layer_idx 就好，FSM 一拍
//      LOAD_DESC 把 mux 输出寄存住即可避免长路径。
//
//   3) 中间层 use_bitplane=0 怎么和层 0 的 use_bitplane=1 共存？
//      use_bitplane 由 layer_timing 字段位 [8] 编码。FSM 在 LOAD_DESC
//      期间把这位驱动到 ctrl_binary_mode（=!use_bitplane）。
//      - 层 0：DMA 灌入的是 bit-plane 编码的输入（pixel 拆 8 bit），
//        ctrl_binary_mode=0，cim_array_ctrl 走标准 8 子时间步。
//      - 中间层：上一层的 spike 是 binary（每 timestep 1 bit），由
//        spike_feedback 直接写 input_fifo，ctrl_binary_mode=1，跳过
//        bit-plane 加权（bitplane_shift=0），单拍 timestep。
//      这条 trade-off：用 1 个 bit 切换两种工作模式，节省第二套 cim
//      数据通路；代价：cim_array_ctrl 内部要做 use_bitplane mux。
//
// 三、关键设计指标
//   - 最大 4 层（MAX_LAYERS=4），每层最多 MAX_NEURONS=128 个 neuron。
//   - 单层 latency 主要由 cim_array_ctrl 决定，layer_sequencer 只增加
//     ~8 cycle (FSM 状态切换)。
//   - 4 层端到端额外开销 ≈ 32 cycle，对 ms 级推理完全可忽略。
//
// 四、Corner case
//   - num_layers 编码：0→1层，1→2层，...，3→4层。FW 写 num_layers=0
//     表示单层，layer_sequencer 退化到"装作没有 spike_feedback"行为
//     ——和 V1 单层路径行为等价。
//   - soft_reset_pulse 在任意状态都会清回 IDLE：不只是 ALU 膜电位被清，
//     当前 layer_idx 也清零。如果 SW 在中间层 reset 又不重新 START，
//     系统永远不会再跑——这是设计契约：reset 等价于"重置整个推理意图"。
//   - feedback_valid / alu_busy 这些握手必须电平等待，不能边沿采样——
//     spike_feedback 内部跑串行扫描可能持续几十拍，FSM 必须循环停在
//     WAIT_ALU/FEEDBACK 状态而不是单拍判完。
// =============================================================================

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
