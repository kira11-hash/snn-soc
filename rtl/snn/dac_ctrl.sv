// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/snn/dac_ctrl.sv
// Purpose: Models DAC stage latency and handshake in the digital control chain.
// Role in system: Separates DAC timing concerns from the main array controller FSM for cleaner sequencing logic.
// Behavior summary: Start/kick input triggers a cycle counter; completion emits a pulse to the next stage.
// Why separate module: Makes latency tuning and waveform debugging easier during analog interface bring-up.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: dac_ctrl.sv
// 描述: DAC 控制器。
//       - wl_valid_pulse 到来时锁存 wl_bitmap
//       - 拉高 dac_valid，等待 dac_ready
//       - dac_ready 后等待 DAC_LATENCY_CYCLES，产生 dac_done_pulse
//======================================================================
//
// -----------------------------------------------------------------------
// 模块功能说明
// -----------------------------------------------------------------------
// dac_ctrl 是 WL（字线）驱动链路的"数字端控制器"，负责：
//   1. 接收来自 cim_array_ctrl 的 wl_valid_pulse 和 wl_bitmap
//   2. 通过标准 valid/ready 握手将 wl_bitmap 传递给模拟 DAC（或其仿真模型）
//   3. DAC ready 确认后，等待 DAC_LATENCY_CYCLES 个周期（模拟 DAC 建立时间）
//   4. 产生 dac_done_pulse 通知 cim_array_ctrl，WL 电压已建立，可以开始 CIM 计算
//
// 信号接口说明：
//   wl_bitmap       : 当前 bit-plane 的 WL 激活图（64 位），来自 cim_array_ctrl
//   wl_valid_pulse  : 单拍输入脉冲，触发本模块开始 DAC 握手序列
//   wl_spike        : 输出给 CIM 宏的 WL 信号（与 wl_reg 内容相同，为锁存值）
//   dac_valid       : DAC 握手有效信号（标准 valid/ready 协议）
//   dac_ready       : DAC 就绪信号（来自模拟 DAC 或其仿真模型）
//                     在 cim_macro_blackbox 仿真模型中，dac_ready 始终为 1
//   dac_done_pulse  : 单拍完成脉冲，通知 cim_array_ctrl 可以进入 ST_CIM
//
// 延迟参数说明（DAC_LATENCY_CYCLES，来自 snn_soc_pkg）：
//   表示 DAC ready 握手完成后，WL 电压需要多少个时钟周期才能真正建立稳定。
//   实现方式：lat_cnt 倒计数器从 (DAC_LATENCY_CYCLES - 1) 数到 0，共经过 N 个周期。
//   特殊情况 DAC_LATENCY_CYCLES == 0：
//     lat_cnt 被设为 0，ST_LAT 状态只停留 1 拍（第一拍 cnt==0 即触发 done），
//     即总延迟为 1 拍（1 拍进入 ST_LAT + 0 拍等待 = 1 拍总延迟）。
//     这是编译时安全处理，避免减法溢出。
//
// FSM 状态说明：
//   ST_IDLE : 等待 wl_valid_pulse，收到后锁存 wl_bitmap，发起 DAC 握手
//   ST_WAIT : 持续拉高 dac_valid，等待 dac_ready 确认
//   ST_LAT  : 延迟计数（模拟 DAC 建立时间），计数到 0 后产生 dac_done_pulse
// -----------------------------------------------------------------------
module dac_ctrl (
  input  logic clk,
  input  logic rst_n,

  input  logic [snn_soc_pkg::NUM_INPUTS-1:0] wl_bitmap,    // 来自 cim_array_ctrl 的 WL 激活图
  input  logic wl_valid_pulse,                               // 单拍，触发 DAC 驱动序列

  output logic [snn_soc_pkg::NUM_INPUTS-1:0] wl_spike,      // 输出给 CIM 宏的锁存 WL 值
  output logic dac_valid,                                    // DAC 握手 valid
  input  logic dac_ready,                                    // DAC 握手 ready（仿真中始终为 1）
  output logic dac_done_pulse                                // 单拍，DAC 建立完成通知
);
  import snn_soc_pkg::*;

  // -----------------------------------------------------------------------
  // FSM 状态编码（3 个状态，2 位编码）
  // -----------------------------------------------------------------------
  typedef enum logic [1:0] {
    ST_IDLE  = 2'd0,   // 空闲，等待 wl_valid_pulse
    ST_WAIT  = 2'd1,   // 握手等待，dac_valid=1，等待 dac_ready
    ST_LAT   = 2'd2    // 延迟计数，模拟 DAC 电压建立时间
  } state_t;

  state_t state;

  // lat_cnt: 延迟倒计数器（8 位，最大支持 255 个周期延迟）。
  // 初值 = DAC_LATENCY_CYCLES - 1（编译时计算，见 ST_WAIT 状态注释）。
  logic [7:0] lat_cnt;

  // wl_reg: 锁存的 WL 激活图。
  // 在 ST_IDLE 收到 wl_valid_pulse 时从 wl_bitmap 捕获，
  // 保持稳定直到下一次 wl_valid_pulse 到来。
  // 连接到 wl_spike 输出，提供给 CIM 宏使用。
  logic [NUM_INPUTS-1:0] wl_reg;

  // wl_spike 直接跟随 wl_reg（组合输出，寄存器在 wl_reg 中）
  assign wl_spike = wl_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // 异步复位：所有状态和输出清零。
      state          <= ST_IDLE;
      dac_valid      <= 1'b0;
      dac_done_pulse <= 1'b0;
      lat_cnt        <= 8'h0;
      wl_reg         <= '0;
    end else begin
      // 每周期默认清除单拍脉冲，只在 ST_LAT 结束时置 1。
      dac_done_pulse <= 1'b0;

      case (state)
        // -------------------------------------------------------------------
        // ST_IDLE: 等待 wl_valid_pulse。
        // 收到脉冲后：
        //   - 锁存 wl_bitmap 到 wl_reg（下游 CIM 宏通过 wl_spike 读取）
        //   - 拉高 dac_valid，启动 valid/ready 握手
        //   - 进入 ST_WAIT
        // 注意：wl_valid_pulse 只需持续 1 拍，本模块在同一拍响应。
        // -------------------------------------------------------------------
        ST_IDLE: begin
          dac_valid <= 1'b0;    // 确保空闲时 dac_valid 为低
          if (wl_valid_pulse) begin
            wl_reg    <= wl_bitmap;   // 锁存 WL 数据（重要：锁存后 wl_bitmap 可以变化）
            dac_valid <= 1'b1;        // 发起 DAC 握手
            state     <= ST_WAIT;
          end
        end

        // -------------------------------------------------------------------
        // ST_WAIT: 等待 dac_ready 握手确认。
        // dac_valid 保持高，直到 dac_ready 到来。
        // 在 cim_macro_blackbox 仿真模型中，dac_ready 始终为 1，
        // 因此本状态通常只停留 1 拍即跳出。
        // 流片后若模拟 DAC 有忙等机制，dac_ready 可能延迟到来。
        //
        // dac_ready 确认后：
        //   - dac_valid 清零（握手结束）
        //   - 计算 lat_cnt 初值：
        //       DAC_LATENCY_CYCLES == 0 → lat_cnt = 0（ST_LAT 只停 1 拍）
        //       DAC_LATENCY_CYCLES > 0  → lat_cnt = LATENCY - 1（倒计到 0 = N 拍延迟）
        //     让"延迟 N 周期"的语义更直观：计数 N 个周期后 done
        //   - 进入 ST_LAT
        // -------------------------------------------------------------------
        ST_WAIT: begin
          if (dac_ready) begin
            dac_valid <= 1'b0;
            // 让"延迟 N 周期"的语义更直观：计数 N 个周期后 done
            lat_cnt   <= (DAC_LATENCY_CYCLES == 0) ? 8'h0
                                                   : (DAC_LATENCY_CYCLES[7:0] - 8'h1);
            // 解释：
            //   DAC_LATENCY_CYCLES == 0：lat_cnt=0，进入 ST_LAT 后第一拍 cnt==0 立即 done，
            //     总额外延迟 = 1 拍（ST_LAT 进入的那一拍）。
            //   DAC_LATENCY_CYCLES == N（N>0）：lat_cnt=N-1，
            //     ST_LAT 从 N-1 数到 0，经过 N 拍后 done，
            //     语义上就是"再等 N 个时钟周期"。
            state     <= ST_LAT;
          end
        end

        // -------------------------------------------------------------------
        // ST_LAT: 模拟 DAC 电压建立时间的延迟计数。
        // lat_cnt 每周期递减，减到 0 时表示延迟已满。
        // 产生 dac_done_pulse 单拍，通知 cim_array_ctrl 可以启动 CIM 计算。
        // 返回 ST_IDLE，等待下一个 bit-plane 的 wl_valid_pulse。
        // -------------------------------------------------------------------
        ST_LAT: begin
          if (lat_cnt == 0) begin
            dac_done_pulse <= 1'b1;    // 单拍完成脉冲（下一拍自动清零）
            state          <= ST_IDLE;
          end else begin
            lat_cnt <= lat_cnt - 1'b1;
          end
        end

        default: state <= ST_IDLE;    // 防止综合器推断不可达锁存态
      endcase
    end
  end
endmodule
