// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/snn/wl_mux_wrapper.sv
// Purpose: Prototype wrapper that maps internal WL bitmap into a narrower external/physical grouped WL interface.
// Role in system: Bridges logical 64-bit WL activity representation and future pad-level/analog-facing multiplexed protocol.
// Behavior summary: Packs/selects WL groups and exposes a handshake-oriented wrapper-level view for integration experiments.
// Current status: Prototype/helper wrapper; final pad-level connection policy is still completed in chip_top integration stage.
// Integration warning: External pin budgeting and analog ownership of WL multiplexing must be frozen with the analog team.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: wl_mux_wrapper.sv
// 描述: WL 复用包装器（V1 协议原型）。
//       - 输入：cim_array_ctrl 给出的 64-bit 并行 wl_bitmap + 单拍有效
//       - 输出：8bit 分组时分信号（wl_data/wl_group_sel/wl_latch）
//       - 内部：完成 8 组发送后再向内部链路发出 wl_valid_pulse_out
//
// 说明:
//   1) 本模块用于冻结"外部引脚复用协议"的字段与时序，避免接口漂移。
//   2) 当前仍在 snn_soc_top 内部使用，后续可平移到 chip_top/pad wrapper。
//   3) 总延迟：1(IDLE→SEND 锁存) + 8(ST_SEND 发送 group 0~7) + 1(ST_DONE) = 10 cycles。
//      文档中"8 cycles"仅指 ST_SEND 阶段，实际含首尾过渡共 10 cycles。
//======================================================================
//
// -----------------------------------------------------------------------
// 系统背景：
//
//   SNN 的 CIM 阵列有 NUM_INPUTS=64 根 Word Line（WL）。
//   受限于 IO pad 数量（1x1mm 芯片，48 pad 预算），不可能将 64 根 WL
//   全部引出为独立引脚。
//
//   解决方案：时分复用（TDM）
//     - 将 64-bit WL bitmap 分为 8 组，每组 8-bit（WL_GROUP_WIDTH=8）
//     - 每个 CLK 周期发送一组，共需 8 个周期
//     - 外部接收方（模拟芯片或测试仪器）用 wl_latch 指示采样时机
//
//   这样只需要：
//     - wl_data[7:0]      : 8 引脚（当前组数据）
//     - wl_group_sel[2:0] : 3 引脚（8 组选择，$clog2(8)=3）
//     - wl_latch          : 1 引脚（采样指示）
//     共 12 引脚，比 64 引脚节省 52 个 pad（符合 IO Pad Plan）
//
// -----------------------------------------------------------------------
// FSM 状态及时序（3 个状态，共 10 cycles）：
//
//   ST_IDLE → ST_SEND（持续 8 cycles）→ ST_DONE（1 cycle）→ ST_IDLE
//
//   详细时序：
//   Cycle 0（IDLE→SEND）：
//     - 收到 wl_valid_pulse_in=1
//     - wl_buf <= wl_bitmap_in（锁存完整 64-bit 位图）
//     - grp_idx <= 0
//     - wl_busy <= 1
//     - 进入 ST_SEND
//     - wl_latch = (state==ST_SEND) = 0（此拍 IDLE，latch 还是 0）
//
//   Cycle 1（SEND，grp_idx=0）：
//     - wl_data = wl_buf[7:0]（group 0 数据）
//     - wl_group_sel = 0
//     - wl_latch = 1（state==ST_SEND）→ 外部采样 group 0
//     - grp_idx <= 1
//
//   Cycle 2~7（SEND，grp_idx=1~6）：同上，依次发送 group 1~6
//
//   Cycle 8（SEND，grp_idx=7）：
//     - wl_data = wl_buf[63:56]（group 7 数据）
//     - wl_group_sel = 7
//     - wl_latch = 1
//     - grp_idx == GROUPS-1 → 进入 ST_DONE（不再自增 grp_idx）
//
//   Cycle 9（DONE）：
//     - wl_latch = 0（state==ST_DONE，非 ST_SEND）
//     - wl_valid_pulse_out = 1（通知内部链路所有组已发送）
//     - wl_busy <= 0
//     - 进入 ST_IDLE
//
//   总延迟：10 cycles（从 wl_valid_pulse_in 到 wl_valid_pulse_out）
//
// -----------------------------------------------------------------------
// wl_latch 的关键设计（BUG 修复说明）：
//
//   修复前（错误）：wl_latch 是寄存器输出（always_ff 赋值）
//     问题：寄存器赋值有一拍延迟，导致：
//       - group 0 被发送时，wl_latch 还是 0（group 0 数据未被采样）
//       - group 7 被发送后，wl_latch 还是 1（group 8 本不存在，但 latch 还在）
//       → group 0 漏采，group 7 重采（等效 group 7 数据被采 2 次）
//
//   修复后（正确）：assign wl_latch = (state == ST_SEND)
//     wl_latch 是纯组合逻辑，与 state 同步变化：
//       - 进入 ST_SEND 的同拍：wl_latch 立即为 1，wl_data 也已经有效
//       - 退出 ST_SEND（进入 ST_DONE）的同拍：wl_latch 立即为 0
//     → 8 个 SEND 周期内，wl_latch 始终为 1，外部恰好采样 8 次，一一对应 8 组
//
// -----------------------------------------------------------------------
// wl_bitmap_out 的用途：
//
//   wl_bitmap_out = wl_buf（锁存后的完整 64-bit WL 位图）
//   同时供内部模块（dac_ctrl, cim_macro_blackbox）使用，不经过串行化。
//   这样内部模块可以在收到 wl_valid_pulse_out 后，立即并行访问完整位图。
//
// -----------------------------------------------------------------------
module wl_mux_wrapper #(
  parameter int P_NUM_INPUTS = snn_soc_pkg::NUM_INPUTS,    // WL 总数 = 64
  parameter int P_GROUP_W    = snn_soc_pkg::WL_GROUP_WIDTH  // 每组宽度 = 8
) (
  input  logic clk,
  input  logic rst_n,

  // 来自 CIM 控制器（并行协议）
  // wl_bitmap_in: 64-bit，每 bit 对应一根 WL 的激活状态（1=激活）
  // wl_valid_pulse_in: 1 拍脉冲，指示 wl_bitmap_in 本拍有效
  input  logic [P_NUM_INPUTS-1:0] wl_bitmap_in,
  input  logic                    wl_valid_pulse_in,

  // 给内部链路（并行协议，供 dac_ctrl/cim_macro 使用）
  // wl_bitmap_out: 锁存后的完整位图（= wl_buf，并行输出）
  // wl_valid_pulse_out: 1 拍脉冲，在 ST_DONE 拍触发，表示串行化完成
  output logic [P_NUM_INPUTS-1:0] wl_bitmap_out,
  output logic                    wl_valid_pulse_out,

  // 冻结后的外部复用协议（后续 chip_top 可直接复用）
  // wl_data      : 当前组的 8-bit WL 数据（wl_latch=1 时有效）
  // wl_group_sel : 当前组索引（0~7），3-bit，= grp_idx
  // wl_latch     : 组合信号，ST_SEND 期间始终为 1（外部在此期间每拍采样）
  // wl_busy      : 1 = 正在串行化（ST_SEND 或 ST_DONE），0 = 可接受新帧
  output logic [P_GROUP_W-1:0] wl_data,
  output logic [$clog2(P_NUM_INPUTS / P_GROUP_W)-1:0] wl_group_sel,
  output logic                 wl_latch,
  output logic                 wl_busy
);
  // -----------------------------------------------------------------------
  // 参数衍生常量
  // GROUPS    : 总组数 = P_NUM_INPUTS / P_GROUP_W = 64 / 8 = 8
  // GROUP_W_SEL: 组索引宽度 = $clog2(GROUPS) = $clog2(8) = 3
  // -----------------------------------------------------------------------
  localparam int GROUPS = (P_NUM_INPUTS / P_GROUP_W); // = 8
  localparam int GROUP_W_SEL = $clog2(GROUPS);        // = 3（grp_idx 和 wl_group_sel 的宽度）

  // -----------------------------------------------------------------------
  // FSM 状态编码（2-bit，3 个有效状态）
  // ST_IDLE : 等待 wl_valid_pulse_in
  // ST_SEND : 逐组发送 wl_data/wl_group_sel/wl_latch（持续 GROUPS=8 cycles）
  // ST_DONE : 发送完成，触发 wl_valid_pulse_out 通知内部链路
  // -----------------------------------------------------------------------
  typedef enum logic [1:0] {
    ST_IDLE = 2'b00,
    ST_SEND = 2'b01,
    ST_DONE = 2'b10
  } state_t;

  state_t state;
  logic [P_NUM_INPUTS-1:0] wl_buf;     // 锁存的完整 64-bit WL 位图
  logic [GROUP_W_SEL-1:0] grp_idx;     // 当前组索引（0~7），驱动 wl_group_sel 和 wl_data 切片

  // -----------------------------------------------------------------------
  // 内部位图直接导出到 wl_bitmap_out（并行协议）
  // wl_bitmap_out 始终等于 wl_buf，即锁存后的完整位图
  // 内部 dac_ctrl/cim_macro 在收到 wl_valid_pulse_out 后读取此信号
  // -----------------------------------------------------------------------
  // 并行数据直接从内部缓冲导出，确保与发送序列一致
  assign wl_bitmap_out = wl_buf;
  // wl_group_sel 直接等于 grp_idx（外部接收方用此值识别当前是第几组）
  assign wl_group_sel = grp_idx;

  // -----------------------------------------------------------------------
  // wl_data：从 wl_buf 中切片取出当前组的 8-bit 数据
  //
  // 切片语法：wl_buf[grp_idx * P_GROUP_W +: P_GROUP_W]
  //   - grp_idx * P_GROUP_W : 起始 bit 索引（e.g. grp_idx=0 → bit 0，grp_idx=1 → bit 8）
  //   - +: P_GROUP_W        : 取 P_GROUP_W(=8) 个连续 bit
  //   等价于：wl_buf[grp_idx*8 + 7 : grp_idx*8]
  //
  // 注意：grp_idx 是寄存器，组合逻辑根据其当前值实时更新 wl_data。
  //       ST_SEND 期间 grp_idx 每拍推进，wl_data 每拍切换到下一组。
  // -----------------------------------------------------------------------
  // 分组数据：当前组的 8bit
  always_comb begin
    wl_data = '0;
    wl_data = wl_buf[grp_idx*P_GROUP_W +: P_GROUP_W]; // 取第 grp_idx 组的 8 bits
  end

  // -----------------------------------------------------------------------
  // FSM 时序逻辑
  // -----------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state               <= ST_IDLE;
      wl_buf              <= '0;
      grp_idx             <= '0;
      wl_valid_pulse_out  <= 1'b0;
      wl_busy             <= 1'b0;
    end else begin
      // wl_valid_pulse_out 默认每拍清零（1 拍脉冲语义）
      // 只有在 ST_DONE 拍才被置 1
      wl_valid_pulse_out <= 1'b0;

      case (state)
        // ── IDLE：等待新帧 ──────────────────────────────────────────
        ST_IDLE: begin
          wl_busy <= 1'b0; // 空闲状态，busy 为 0
          if (wl_valid_pulse_in) begin
            // 收到新帧：锁存位图，复位组索引，进入 SEND
            wl_buf  <= wl_bitmap_in; // 锁存完整 64-bit 位图（防止 bitmap_in 被修改）
            grp_idx <= '0;           // 从 group 0 开始发送
            wl_busy <= 1'b1;         // 立即置 busy（本拍末 busy 为 1，下拍 SEND 开始）
            state   <= ST_SEND;
          end
        end

        // ── SEND：逐组发送（持续 GROUPS=8 拍）────────────────────────
        // 每拍：wl_data = wl_buf[grp_idx*8 +: 8]（组合逻辑自动更新）
        //         wl_group_sel = grp_idx
        //         wl_latch = 1（由组合 assign 驱动）
        ST_SEND: begin
          wl_busy  <= 1'b1; // 保持 busy
          if (grp_idx == GROUP_W_SEL'(GROUPS - 1)) begin
            // 已发送最后一组（grp_idx=7），进入 DONE
            // grp_idx 不再自增（保持 7），wl_data 在此拍仍为 group 7（wl_latch 仍=1）
            state <= ST_DONE;
          end else begin
            // 推进到下一组
            grp_idx <= grp_idx + GROUP_W_SEL'(1);
          end
        end

        // ── DONE：发送完成通知 ────────────────────────────────────────
        // wl_latch = 0（state!=ST_SEND，组合逻辑立即生效）
        // wl_valid_pulse_out = 1（通知 dac_ctrl/cim_macro 位图已全部串行化完成）
        // 下一拍回到 ST_IDLE，等待新帧
        ST_DONE: begin
          wl_busy            <= 1'b0;
          wl_valid_pulse_out <= 1'b1; // 所有组发送完成后，触发内部链路
          state              <= ST_IDLE;
        end

        // ── 防御性默认分支 ────────────────────────────────────────────
        default: begin
          state <= ST_IDLE;
        end
      endcase

`ifndef SYNTHESIS
      // 异常保护（仅仿真）：忙期间若再次收到新帧，提示协议使用错误
      // 正确使用：上游（cim_array_ctrl）必须等待 wl_busy=0 才能发送下一帧
      // 若违反此约束（wl_valid_pulse_in 在 SEND/DONE 期间拉高），当前帧会丢失
      if (wl_valid_pulse_in && (state != ST_IDLE)) begin
        $warning("[wl_mux_wrapper] 收到重入 wl_valid_pulse_in，当前帧尚未完成发送");
      end
`endif
    end
  end

  // -----------------------------------------------------------------------
  // wl_latch 组合输出（BUG 修复后的正确实现）
  //
  // wl_latch = 1 当且仅当 state == ST_SEND（8 个连续时钟周期）
  //
  // 与 wl_data/wl_group_sel 同拍有效：
  //   外部接收方在 wl_latch=1 期间，每个时钟上升沿采样一次
  //   (wl_data, wl_group_sel) 对，共采样 8 次，重建完整 64-bit 位图。
  //
  // 为什么必须用 assign（组合逻辑）而非寄存器：
  //   寄存器输出比 state 落后一拍 → group 0（SEND 第 1 拍）的 latch 为 0（采不到）
  //   → group 7（SEND 最后一拍）进入 DONE 后还有一拍 latch=1（重采 group 7）
  //   组合逻辑与 state 同步，无此问题。
  //
  // 修复前为寄存器输出，导致 group 0 漏采、group 7 重采。现改为纯组合逻辑。
  assign wl_latch = (state == ST_SEND);

`ifndef SYNTHESIS
  // -----------------------------------------------------------------------
  // 参数合法性检查（仅仿真，综合时跳过）
  //
  // P_GROUP_W 必须 > 0（避免除以零和无意义切片）
  // P_NUM_INPUTS 必须能被 P_GROUP_W 整除（否则最后一组位图不完整）
  // -----------------------------------------------------------------------
  // 参数合法性检查（仅仿真）
  initial begin
    if (P_GROUP_W <= 0) begin
      $fatal(1, "[wl_mux_wrapper] P_GROUP_W 必须 > 0");
    end
    if ((P_NUM_INPUTS % P_GROUP_W) != 0) begin
      $fatal(1, "[wl_mux_wrapper] P_NUM_INPUTS(%0d) 必须能被 P_GROUP_W(%0d) 整除",
             P_NUM_INPUTS, P_GROUP_W);
    end
  end
`endif
endmodule
