// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/snn/cim_array_ctrl.sv
// Purpose: Main SNN datapath FSM coordinating fetch -> DAC -> CIM -> ADC -> next bit-plane/next sample progression.
// Role in system: This is the "hardware loop controller" that turns a high-level start command into repeated compute cycles.
// Behavior summary: Pops input FIFO entries, drives WL data/bit-plane index, triggers DAC/CIM/ADC sub-controllers, tracks progress.
// Scheduling model: Processes one frame over PIXEL_BITS sub-steps (and configurable timesteps) using explicit stage handshakes.
// Stability concern: Off-by-one errors in bit-plane/timestep counters can silently break accuracy while keeping simulation alive.
// Verification focus: FSM transitions, done pulse generation, FIFO underflow protection, and barrier-like stage sequencing.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: cim_array_ctrl.sv
// 描述: CIM 阵列控制器核心 FSM。
//       状态流转：
//       IDLE -> STEP_FETCH -> STEP_DAC -> STEP_CIM -> STEP_ADC -> STEP_INC -> DONE
//======================================================================
// NOTE: 每帧拆成 PIXEL_BITS 个 bit-plane（MSB->LSB）输入。
//       bitplane_shift 表示当前位平面权重（用于 LIF 移位累加）。
//
// -----------------------------------------------------------------------
// 整体调度逻辑说明
// -----------------------------------------------------------------------
// 本模块是 SNN 推理数据路径的"调度总控"，负责：
//   1. 管理时间步（timestep）外层循环（共 timesteps 次）
//   2. 管理位平面（bit-plane）内层循环（每帧 PIXEL_BITS=8 个 bit-plane）
//   3. 对每个 bit-plane，依次触发 DAC（写 WL）→ CIM（模拟计算）→ ADC（读 BL）
//   4. ADC 完成后通知 lif_neurons 更新膜电位（通过 neuron_in_valid 信号，
//      由 adc_ctrl 产生，本模块监听 neuron_in_valid 作为 ADC 完成标志）
//
// bit-plane 权重编码：
//   bitplane_shift 从 PIXEL_BITS-1=7（MSB，权重最大）倒数到 0（LSB，权重最小）。
//   lif_neurons 收到 neuron_in_data 后，会将其左移 bitplane_shift 位再累加到膜电位，
//   实现"算术位平面展开"的 temporal coding 方案。
//
// 外层循环（timesteps）：
//   timestep_counter 从 0 累加到 timesteps-1。
//   每完成一帧（PIXEL_BITS 个 bit-plane），timestep_counter 自增。
//   达到 timesteps 后进入 ST_DONE，产生 done_pulse。
//
// 子控制器握手协议：
//   - DAC : cim_array_ctrl 发 wl_valid_pulse（单拍）→ dac_ctrl 接收并处理
//           → dac_ctrl 完成后回 dac_done_pulse（单拍）
//   - CIM : cim_array_ctrl 发 cim_start_pulse（单拍）→ cim_macro 接收
//           → cim_macro 完成后回 cim_done（单拍）
//   - ADC : cim_array_ctrl 发 adc_kick_pulse（单拍）→ adc_ctrl 接收
//           → adc_ctrl 完成 20 路采样 + 差分后回 neuron_in_valid（单拍）
//
// sent 标志（dac_sent / cim_sent / adc_sent）：
//   防止在等待完成信号期间，因状态停留多拍而重复发出 start 脉冲。
//   每进入对应状态时清零 sent，发出 start 后置 1，之后不再重发。
// -----------------------------------------------------------------------
module cim_array_ctrl (
  input  logic clk,
  input  logic rst_n,
  input  logic soft_reset_pulse,    // 软复位：立即归零所有计数器，返回 ST_IDLE（不需要等 rst_n 拉低）

  input  logic start_pulse,         // 单拍启动脉冲，来自 reg_bank 写 START 寄存器
  input  logic [7:0] timesteps,     // 运行时间步数，来自 REG_TIMESTEPS 寄存器（最大 255）

  // input_fifo：存储预处理好的 bit-plane 数据，每个 FIFO 条目 = NUM_INPUTS=64 位
  input  logic [snn_soc_pkg::NUM_INPUTS-1:0] in_fifo_rdata,   // FIFO 读数据端口
  input  logic in_fifo_empty,                                   // FIFO 空标志
  output logic in_fifo_pop,                                     // 弹出请求（单拍高有效）

  // DAC（字线驱动）接口
  output logic [snn_soc_pkg::NUM_INPUTS-1:0] wl_bitmap,        // 当前 bit-plane 的 WL 激活图（64 位）
  output logic wl_valid_pulse,                                   // 单拍，通知 dac_ctrl 新数据到来
  input  logic dac_done_pulse,                                   // 单拍，dac_ctrl 完成回复

  // CIM 宏接口
  output logic cim_start_pulse,     // 单拍，触发 CIM 宏开始模拟计算
  input  logic cim_done,            // 单拍，CIM 宏计算完成

  // ADC 接口（通过 adc_ctrl 中转）
  output logic adc_kick_pulse,      // 单拍，触发 adc_ctrl 开始 20 路采样序列
  input  logic neuron_in_valid,     // 单拍，adc_ctrl 差分完成，neuron_in_data 有效（作为 ADC 完成信号）

  // 状态输出（供 reg_bank 读取）
  output logic busy,                // 推理进行中（高有效，直到 done_pulse）
  output logic done_pulse,          // 单拍，推理完成脉冲
  // timestep_counter 统计帧数（bit-plane 子时间步在内部处理）
  output logic [7:0] timestep_counter,                                         // 当前已完成的时间步数（0-based）
  output logic [$clog2(snn_soc_pkg::PIXEL_BITS)-1:0] bitplane_shift           // 当前 bit-plane 权重（7 down to 0）
);
  import snn_soc_pkg::*;

  // BITPLANE_W: bitplane_shift 计数器位宽 = $clog2(PIXEL_BITS) = $clog2(8) = 3
  localparam int BITPLANE_W = $clog2(PIXEL_BITS);

  // BITPLANE_MAX: 最大 bit-plane 索引 = PIXEL_BITS-1 = 7（MSB 优先，权重最大）
  // 使用 BITPLANE_W'() 做位宽匹配，3'(7) = 3'b111，无截断。
  localparam logic [BITPLANE_W-1:0] BITPLANE_MAX = BITPLANE_W'(PIXEL_BITS-1);

  // -----------------------------------------------------------------------
  // FSM 状态编码（7 个状态，3 位 one-hot 兼容 Gray 编码）
  // -----------------------------------------------------------------------
  // ST_IDLE  : 空闲，等待 start_pulse
  // ST_FETCH : 从 input FIFO 弹出一个 bit-plane 数据到 wl_reg
  // ST_DAC   : 触发 dac_ctrl（写 WL），等待 dac_done_pulse
  // ST_CIM   : 触发 CIM 宏（模拟矩阵乘），等待 cim_done
  // ST_ADC   : 触发 adc_ctrl（20 路 ADC+差分），等待 neuron_in_valid
  // ST_INC   : 更新 bit-plane / timestep 计数器，决定下一步去哪
  // ST_DONE  : 推理完成，拉高 done_pulse 单拍，返回 ST_IDLE
  // -----------------------------------------------------------------------
  typedef enum logic [2:0] {
    ST_IDLE  = 3'd0,
    ST_FETCH = 3'd1,
    ST_DAC   = 3'd2,
    ST_CIM   = 3'd3,
    ST_ADC   = 3'd4,
    ST_INC   = 3'd5,
    ST_DONE  = 3'd6
  } state_t;

  state_t state;

  // wl_reg: WL 激活位图暂存寄存器。
  // 在 ST_FETCH 时从 FIFO 加载当前 bit-plane 数据；
  // 若 FIFO 为空则加载全 0（安全降级：不驱动任何 WL，CIM 结果为 0）。
  logic [NUM_INPUTS-1:0] wl_reg;

  // sent 标志：防止在等待完成信号期间重复发出 start 脉冲。
  // 进入对应状态时清零（由上一状态负责），发出脉冲后置 1。
  logic dac_sent;   // 1 = 本轮已发过 wl_valid_pulse，不再重发
  logic cim_sent;   // 1 = 本轮已发过 cim_start_pulse，不再重发
  logic adc_sent;   // 1 = 本轮已发过 adc_kick_pulse，不再重发

  // wl_bitmap 直接连接 wl_reg（输出为组合逻辑，寄存器在内部）
  assign wl_bitmap = wl_reg;

`ifndef SYNTHESIS
  // 参数与运行期简单断言
  // 这段代码仅在仿真时编译，`ifdef SYNTHESIS 保护下不进入综合。
  initial begin
    // PIXEL_BITS 必须为正数（至少 1 bit-plane），否则循环逻辑无意义。
    if (PIXEL_BITS <= 0) begin
      $fatal(1, "[cim_array_ctrl] PIXEL_BITS 需 > 0");
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n && busy) begin
      /* verilator lint_off CMPCONST */
      // bitplane_shift 只在 busy 期间有意义，越界表示 ST_INC 递减逻辑错误。
      assert (bitplane_shift <= BITPLANE_MAX)
        else $fatal(1, "[cim_array_ctrl] bitplane_shift 越界: %0d", bitplane_shift);
      /* verilator lint_on CMPCONST */
    end
  end
`endif

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // 异步复位：所有寄存器归零，FSM 回 ST_IDLE。
      state            <= ST_IDLE;
      wl_reg           <= '0;
      wl_valid_pulse   <= 1'b0;
      cim_start_pulse  <= 1'b0;
      adc_kick_pulse   <= 1'b0;
      in_fifo_pop      <= 1'b0;
      busy             <= 1'b0;
      done_pulse       <= 1'b0;
      timestep_counter<= 8'h0;
      bitplane_shift  <= BITPLANE_MAX;   // 初始化为最高位平面（MSB=7）
      dac_sent         <= 1'b0;
      cim_sent         <= 1'b0;
      adc_sent         <= 1'b0;
    end else begin
      // 每周期默认清除所有单拍脉冲输出（在各状态中按需置 1）。
      // 这种"默认清零、按需拉高"的风格确保脉冲宽度精确为 1 个周期。
      wl_valid_pulse  <= 1'b0;
      cim_start_pulse <= 1'b0;
      adc_kick_pulse  <= 1'b0;
      in_fifo_pop     <= 1'b0;
      done_pulse      <= 1'b0;

      if (soft_reset_pulse) begin
        // 软复位优先级高于 FSM 正常逻辑。
        // 用于错误恢复或 SW 主动中止推理，无需拉低 rst_n。
        state             <= ST_IDLE;
        busy              <= 1'b0;
        timestep_counter <= 8'h0;
        bitplane_shift   <= BITPLANE_MAX;
        dac_sent          <= 1'b0;
        cim_sent          <= 1'b0;
        adc_sent          <= 1'b0;
        // 注意：wl_reg 不清零，保留上次数据（不影响正确性，只影响诊断）
      end else begin
        case (state)
          // -----------------------------------------------------------------
          // ST_IDLE: 等待 start_pulse。
          // 收到 start_pulse 后检查 timesteps：
          //   - timesteps == 0：退化情况，立即产生 done_pulse，不执行推理。
          //   - timesteps > 0 ：初始化计数器，进入 ST_FETCH 开始推理。
          // 注意：busy 在进入 ST_IDLE 后的下一拍才可能变高，
          //       所以 reg_bank 读 STATUS 寄存器时，start_pulse 当拍 busy 已为 1。
          // -----------------------------------------------------------------
          ST_IDLE: begin
            busy <= 1'b0;
            if (start_pulse) begin
              if (timesteps == 0) begin
                // timesteps=0：立即完成，不进入推理流程
                // 特殊情况处理：software 写了 0 个时间步，返回空结果。
                busy              <= 1'b0;
                timestep_counter <= 8'h0;
                bitplane_shift    <= BITPLANE_MAX;
                done_pulse        <= 1'b1;          // 立即产生 done 脉冲
                state             <= ST_IDLE;
              end else begin
                busy              <= 1'b1;
                timestep_counter <= 8'h0;           // 从第 0 帧开始
                bitplane_shift    <= BITPLANE_MAX;   // 从 MSB（bit 7）开始
                state             <= ST_FETCH;
              end
            end
          end

          // -----------------------------------------------------------------
          // ST_FETCH: 从 input FIFO 弹出一个 bit-plane 到 wl_reg。
          // FIFO 存储经过预处理的 bit-plane 向量（NUM_INPUTS=64 位/条目）。
          // 若 FIFO 为空（underflow 保护）：使用全 0 作为 WL 激活，
          //   相当于"无输入"，不影响 FSM 流程，但推理结果无意义（应由 SW 保证）。
          // in_fifo_pop 为单拍信号，FIFO 模块在下一拍提供新数据（流水线模型）。
          // 进入 ST_DAC 时清零 dac_sent，准备发 wl_valid_pulse。
          // -----------------------------------------------------------------
          ST_FETCH: begin
            // 每个 FIFO 条目是一幅输入帧的一个 bit-plane（MSB->LSB）
            // 若 FIFO 为空，本步使用全 0 wl_bitmap
            if (!in_fifo_empty) begin
              wl_reg      <= in_fifo_rdata;   // 加载 bit-plane 数据
              in_fifo_pop <= 1'b1;            // 弹出请求（单拍），FIFO 在下一拍更新读指针
            end else begin
              wl_reg <= '0;                   // FIFO 空时安全降级：全 0 WL
            end
            dac_sent <= 1'b0;   // 清除 sent 标志，允许 ST_DAC 发出 wl_valid_pulse
            state    <= ST_DAC;
          end

          // -----------------------------------------------------------------
          // ST_DAC: 触发 dac_ctrl，等待 DAC 完成。
          // 首拍：发 wl_valid_pulse（单拍），通知 dac_ctrl 锁存 wl_bitmap 并开始驱动 WL。
          // dac_sent 防止后续周期（等待 dac_done_pulse 期间）重复触发。
          // 收到 dac_done_pulse 后清零 cim_sent，进入 ST_CIM。
          // -----------------------------------------------------------------
          ST_DAC: begin
            if (!dac_sent) begin
              wl_valid_pulse <= 1'b1;    // 触发 dac_ctrl（WL 数据已在 wl_reg 中就绪）
              dac_sent       <= 1'b1;    // 标记已发，防止重复
            end
            if (dac_done_pulse) begin
              cim_sent <= 1'b0;          // 清除 sent，允许 ST_CIM 发出 cim_start_pulse
              state    <= ST_CIM;
            end
          end

          // -----------------------------------------------------------------
          // ST_CIM: 触发 CIM 宏进行模拟矩阵乘法，等待计算完成。
          // 首拍：发 cim_start_pulse（单拍），CIM 宏开始计算（延迟由 CIM_LATENCY_CYCLES 控制）。
          // cim_sent 防止重复触发。
          // 收到 cim_done 后清零 adc_sent，进入 ST_ADC。
          // -----------------------------------------------------------------
          ST_CIM: begin
            if (!cim_sent) begin
              cim_start_pulse <= 1'b1;   // 触发 CIM 宏（WL 已建立，WL voltage 稳定）
              cim_sent        <= 1'b1;
            end
            if (cim_done) begin
              adc_sent <= 1'b0;          // 清除 sent，允许 ST_ADC 发出 adc_kick_pulse
              state    <= ST_ADC;
            end
          end

          // -----------------------------------------------------------------
          // ST_ADC: 触发 adc_ctrl 执行 20 路时分 ADC 采样 + Scheme B 差分，
          //         等待 neuron_in_valid（差分完成信号）。
          // 首拍：发 adc_kick_pulse（单拍），adc_ctrl 开始 bl_sel 循环。
          // neuron_in_valid 由 adc_ctrl 在 ST_DONE 状态拉高，表示 neuron_in_data 有效。
          // 此时 lif_neurons 也在同一周期采样 neuron_in_data，本模块只需监听此信号。
          // -----------------------------------------------------------------
          ST_ADC: begin
            if (!adc_sent) begin
              adc_kick_pulse <= 1'b1;    // 启动 adc_ctrl 20 路采样序列
              adc_sent       <= 1'b1;
            end
            if (neuron_in_valid) begin
              // neuron_in_valid = ADC 完成 + 差分完成，lif_neurons 已收到数据
              state <= ST_INC;
            end
          end

          // -----------------------------------------------------------------
          // ST_INC: 更新 bit-plane 和 timestep 计数器，决定下一步跳转目标。
          //
          // 内层循环（bit-plane）：
          //   bitplane_shift 从 BITPLANE_MAX=7 倒数到 0，代表当前位平面的移位权重。
          //   bitplane_shift > 0：还有更低权重的 bit-plane 未处理，bitplane_shift-- 后回 ST_FETCH。
          //   bitplane_shift == 0：本帧（所有 8 个 bit-plane）处理完毕。
          //
          // 外层循环（timestep）：
          //   bitplane_shift==0 时检查时间步：
          //   timestep_counter + 1 < timesteps：还有更多帧，timestep_counter++，
          //                                     bitplane_shift 重置为 BITPLANE_MAX，回 ST_FETCH。
          //   timestep_counter + 1 >= timesteps：所有帧完成，进入 ST_DONE。
          //
          // 注意：比较式用 (timestep_counter + 1 >= timesteps)，避免 timestep_counter
          //       先自增再比较导致的时序问题（先判断后更新计数器）。
          // -----------------------------------------------------------------
          ST_INC: begin
            // bit-plane 子时间步：先 MSB 后 LSB（bit 7 -> bit 0）
            if (bitplane_shift == 0) begin
              // 当前帧的所有 PIXEL_BITS 个 bit-plane 已全部处理完
              if (timestep_counter + 1 >= timesteps) begin
                // 所有时间步完成，推理结束
                state <= ST_DONE;
              end else begin
                // 还有未完成的时间步，重置 bit-plane 为 MSB，读取下一帧
                timestep_counter <= timestep_counter + 1'b1;
                bitplane_shift   <= BITPLANE_MAX;   // 下一帧从 MSB=7 开始
                state            <= ST_FETCH;
              end
            end else begin
              // 还有更低权重的 bit-plane，递减 shift 权重后继续
              bitplane_shift <= bitplane_shift - 1'b1;
              state <= ST_FETCH;
            end
          end

          // -----------------------------------------------------------------
          // ST_DONE: 推理完成，产生 done_pulse 单拍，通知 reg_bank / DMA。
          // busy 清零，state 返回 ST_IDLE，等待下一次 start_pulse。
          // -----------------------------------------------------------------
          ST_DONE: begin
            busy       <= 1'b0;
            done_pulse <= 1'b1;    // 单拍脉冲，SW 可通过中断或轮询 STATUS 寄存器检测
            state      <= ST_IDLE;
          end

          default: state <= ST_IDLE;    // 防止综合器推断不可达锁存态
        endcase
      end
    end
  end
endmodule
