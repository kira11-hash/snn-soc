// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/reg/reg_bank.sv
// Purpose: Central memory-mapped control/status register bank for SNN datapath and runtime configuration.
// Role in system: Software/testbench programs thresholds, timesteps, start/reset controls, and reads status/outputs here.
// Behavior summary: Decodes register offsets, handles writes/reads, exposes clean control wires to datapath blocks.
// Important distinction: Some fields are "shadow/metadata" values (e.g., threshold ratio) while others directly drive hardware.
// Verification focus: Bitfield definitions, sticky status semantics, and alignment with doc/02_reg_map.md.
// Evolution note: This file is the primary compatibility surface when E203/UART firmware takes over from the TB master.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: reg_bank.sv
// 描述: SNN SoC 主寄存器 Bank。
//       - 地址基址：0x4000_0000
//       - 提供阈值、时步数、控制与状态寄存器
//       - CIM_CTRL.DONE 为 sticky，使用 W1C 清零
//       - CIM_CTRL.START/RESET 为 W1P，写 1 仅产生单拍脉冲
//======================================================================
// TIMESTEPS 表示帧数；每帧包含 PIXEL_BITS 个子时间步（MSB->LSB）。
//
// -----------------------------------------------------------------------
// 寄存器地址映射（物理地址 = 0x4000_0000 + offset）：
//
//   0x00  REG_THRESHOLD      [31:0]  LIF 神经元绝对阈值（直接驱动 neuron_threshold）
//   0x04  REG_TIMESTEPS      [7:0]   推理时步数（即帧数，V1 定版=10）
//   0x08  REG_NUM_INPUTS     [15:0]  只读：NUM_INPUTS 参数值（=64）
//   0x0C  REG_NUM_OUTPUTS    [7:0]   只读：NUM_OUTPUTS 参数值（=10）
//   0x10  REG_RESET_MODE     [0]     重置模式选择（0=soft/1=hard）
//   0x14  REG_CIM_CTRL       [7:0]   控制/状态复合寄存器：
//                                      bit[0] START      W1P  写 1 产生 1 拍 start_pulse
//                                      bit[1] SOFT_RESET W1P  写 1 产生 1 拍 soft_reset_pulse
//                                      bit[7] DONE       W1C  sticky，推理完成后由硬件置 1，写 1 清零
//   0x18  REG_STATUS         只读：
//                                      bit[0]    snn_busy
//                                      bit[1]    in_fifo_empty
//                                      bit[2]    in_fifo_full
//                                      bit[3]    out_fifo_empty
//                                      bit[4]    out_fifo_full
//                                      bit[15:8] timestep_counter（当前时步）
//   0x1C  REG_OUT_DATA       [3:0]   只读：弹出 output_fifo 的 spike_id（读后自动 pop）
//   0x20  REG_OUT_COUNT      只读：output_fifo 当前 entry 数
//   0x24  REG_THRESHOLD_RATIO [7:0]  shadow 寄存器：Scheme B 阈值比例（定版默认 4 ≈ 1.57%）
//                                     注意：此寄存器不驱动硬件，固件需手动计算后写 REG_THRESHOLD
//   0x28  REG_ADC_SAT_COUNT  只读：{adc_sat_low[31:16], adc_sat_high[15:0]}
//   0x2C  REG_CIM_TEST       bit[0]=cim_test_mode, bit[15:8]=cim_test_data_pos（正通道 ch0~9）, bit[23:16]=cim_test_data_neg（负通道 ch10~19）
//   0x30  REG_DBG_CNT_0      只读：{cim_cycle_cnt[31:16], dma_frame_cnt[15:0]}
//   0x34  REG_DBG_CNT_1      只读：{wl_stall_cnt[31:16], spike_cnt[15:0]}
//
// -----------------------------------------------------------------------
// 写操作语义说明：
//
//   W1P（Write-1-to-Pulse）：START（bit0）和 SOFT_RESET（bit1）
//     实现机制：
//       1. always_ff 开头默认：start_pulse <= 0; soft_reset_pulse <= 0;（每拍清零）
//       2. case(addr_offset) 中 REG_CIM_CTRL 分支：若 req_wdata[0]=1 则 start_pulse <= 1
//       3. 因为是同一 always_ff 块，第 2 步的赋值覆盖第 1 步默认值
//       4. 下一拍开头第 1 步再次清零 → 只产生 1 拍脉冲
//     注意：默认清零必须在 case 之前，否则 case 内赋值会被覆盖。
//     这是 SystemVerilog always_ff 中"后赋值覆盖"语义，安全且符合规范。
//
//   W1C（Write-1-to-Clear）：DONE（bit7）
//     实现机制：
//       1. 硬件置位：snn_done_pulse=1 时，done_sticky <= 1
//       2. 软件清零：写 REG_CIM_CTRL 且 req_wdata[7]=1 时，done_sticky <= 0
//       3. 两者在同一 always_ff 中，若同拍 done_pulse 和 W1C 同时发生，
//          case 内的 done_sticky <= 0 比 if(snn_done_pulse) done_sticky <= 1 后执行
//          → 清零优先（SystemVerilog last-assignment 语义）
//          → 固件如需确认完成，应在 snn_done_pulse 之后再读 DONE
//
//   sticky DONE 语义：
//     snn_done_pulse 是 SNN 子系统发出的 1 拍完成脉冲。
//     done_sticky 将其"锁存"，CPU 可以在稍后（多个总线周期后）轮询到 DONE=1。
//     与中断类似，但通过轮询实现（V1 无中断控制器）。
//
// -----------------------------------------------------------------------
// OUT_FIFO 读取的 2-cycle pipeline（pop_pending 机制）：
//
//   目的：避免"同拍读出 rd_data 同拍 pop"导致数据竞争。
//   fifo_sync 是 first-word fall-through：rd_data = mem[rd_ptr] 是组合读。
//   若同拍 pop（rd_ptr 推进），rd_data 会立即切换，可能导致总线读到下一个数据。
//
//   解决方案（2 拍流水）：
//     Cycle 0: CPU 读 REG_OUT_DATA → rdata 组合读出 rd_data（当前队头）
//              → pop_pending <= 1（但此刻 out_fifo_pop 还是 0）
//     Cycle 1: out_fifo_pop <= pop_pending（= 1）→ FIFO 实际 pop
//              → pop_pending <= 0（除非又来一次读）
//
//   关键：CPU 在 Cycle 0 读到的是 pop 发生前的队头，时序正确，无竞争。
//
//   pop_pending 的触发条件：req_valid && !req_write && addr_offset==REG_OUT_DATA && !out_fifo_empty
//     - 必须 !out_fifo_empty：空 FIFO 读不应触发 pop（避免 underflow）
//     - 必须是有效读请求（req_valid && !req_write）
// -----------------------------------------------------------------------
module reg_bank (
  input  logic        clk,
  input  logic        rst_n,

  // 简化总线接口（地址为 offset）
  // req_addr[7:0] 为寄存器偏移，高位忽略（见 _unused lint 处理）
  input  logic        req_valid,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  output logic [31:0] rdata,

  // 来自 SNN 子系统的状态输入
  input  logic        snn_busy,          // SNN 推理进行中（高电平有效）
  input  logic        snn_done_pulse,    // SNN 推理完成脉冲（1 拍，用于置 done_sticky）
  input  logic [7:0]  timestep_counter,  // 当前时步计数器（用于 STATUS 状态读回）

  // FIFO 状态
  input  logic        in_fifo_empty,    // 输入 FIFO 空（DMA 尚未写入或全被消耗）
  input  logic        in_fifo_full,     // 输入 FIFO 满（DMA 暂停）
  input  logic        out_fifo_empty,   // 输出 FIFO 空（无 spike 可读）
  input  logic        out_fifo_full,    // 输出 FIFO 满（LIF 暂停输出）
  input  logic [3:0]  out_fifo_rdata,   // 输出 FIFO 队头 spike_id（4-bit，fall-through）
  input  logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] out_fifo_count, // 当前 spike 数量

  // ADC 饱和监控（来自 adc_ctrl）
  // adc_sat_high: 高阈值饱和次数（ADC 输出 >= 最大正值）
  // adc_sat_low : 低阈值饱和次数（ADC 输出 <= 最大负值）
  input  logic [15:0] adc_sat_high,
  input  logic [15:0] adc_sat_low,

  // Debug 计数器（来自 snn_soc_top 内部采样，只读）
  input  logic [15:0] dbg_dma_frame_cnt,  // DMA 已传输的帧数
  input  logic [15:0] dbg_cim_cycle_cnt,  // CIM 推理总时钟周期数
  input  logic [15:0] dbg_spike_cnt,      // 输出 spike 总数
  input  logic [15:0] dbg_wl_stall_cnt,   // WL 总线停顿次数

  // 输出到 SNN 子系统
  output logic [31:0] neuron_threshold,   // 直接驱动 LIF 神经元阈值
  output logic [7:0]  timesteps,          // 推理时步数（帧数）
  output logic        reset_mode,         // 0=soft reset，1=hard reset
  output logic        start_pulse,        // 1 拍脉冲，触发 SNN 推理开始（W1P）
  output logic        soft_reset_pulse,   // 1 拍脉冲，触发软复位（W1P）

  // CIM Test Mode 输出
  // cim_test_mode=1 时，cim_macro_blackbox 用合成数据替代真实 RRAM 响应
  // cim_test_data_pos：正通道（ch 0~9）合成 ADC 值；cim_test_data_neg：负通道（ch 10~19）合成 ADC 值
  // 将两者设置为不同值（如 pos=100, neg=0）可使 Scheme B 差分非零，LIF 膜电位可积累并产生 spike
  output logic        cim_test_mode,
  output logic [snn_soc_pkg::ADC_BITS-1:0] cim_test_data_pos, // 正通道合成值（8-bit，ch 0~9）
  output logic [snn_soc_pkg::ADC_BITS-1:0] cim_test_data_neg, // 负通道合成值（8-bit，ch 10~19）

  // 输出 FIFO 弹出控制（在 rvalid 那拍）
  // 由 pop_pending 2-cycle pipeline 驱动，确保读出后下一拍才 pop
  output logic        out_fifo_pop
);
  import snn_soc_pkg::*;

  // -----------------------------------------------------------------------
  // 寄存器偏移地址常量（相对于模块挂载基址 0x4000_0000）
  // 每个常量对应一个逻辑寄存器的字节地址偏移（4B 对齐）
  // -----------------------------------------------------------------------
  // 寄存器 offset
  localparam logic [7:0] REG_THRESHOLD   = 8'h00; // 阈值（32-bit，直接驱动硬件）
  localparam logic [7:0] REG_TIMESTEPS   = 8'h04; // 时步数/帧数（8-bit）
  localparam logic [7:0] REG_NUM_INPUTS  = 8'h08; // 只读：NUM_INPUTS 参数（=64）
  localparam logic [7:0] REG_NUM_OUTPUTS = 8'h0C; // 只读：NUM_OUTPUTS 参数（=10）
  localparam logic [7:0] REG_RESET_MODE  = 8'h10; // 复位模式（1-bit）
  localparam logic [7:0] REG_CIM_CTRL    = 8'h14; // 复合控制：START W1P / SOFT_RESET W1P / DONE W1C
  localparam logic [7:0] REG_STATUS      = 8'h18; // 只读状态：busy/fifo flags/timestep_counter
  localparam logic [7:0] REG_OUT_DATA    = 8'h1C; // 只读：output_fifo 队头 spike_id（读触发 pop）
  localparam logic [7:0] REG_OUT_COUNT   = 8'h20; // 只读：output_fifo 当前 entry 数
  // Scheme B 阈值比例寄存器（8-bit, 定版默认 4/255 ≈ 0.0157）
  // 固件可读取 ratio 辅助计算绝对阈值，或直接用于 bring-up 调试
  // THRESHOLD_RATIO is a software/debug-visible ratio shadow register only.
  // Writing REG_THRESHOLD_RATIO does NOT auto-update neuron_threshold.
  // Firmware should compute absolute threshold and write REG_THRESHOLD explicitly.
  localparam logic [7:0] REG_THRESHOLD_RATIO = 8'h24; // shadow 寄存器，不驱动硬件
  // ADC 饱和计数（只读，由 adc_ctrl 驱动，每次推理自动清零）
  localparam logic [7:0] REG_ADC_SAT_COUNT   = 8'h28; // {sat_low[31:16], sat_high[15:0]}
  // CIM Test Mode: bit[0]=test_mode, bit[15:8]=test_data_pos(ch0~9), bit[23:16]=test_data_neg(ch10~19)
  localparam logic [7:0] REG_CIM_TEST        = 8'h2C; // bit[0]=test_mode, bit[15:8]=test_data_pos(ch0~9), bit[23:16]=test_data_neg(ch10~19)
  // Debug 计数器（只读，打包两组 16-bit）
  localparam logic [7:0] REG_DBG_CNT_0       = 8'h30; // [15:0]=dma_frame, [31:16]=cim_cycle
  localparam logic [7:0] REG_DBG_CNT_1       = 8'h34; // [15:0]=spike, [31:16]=wl_stall

  // -----------------------------------------------------------------------
  // 内部寄存器说明
  // threshold_ratio : Scheme B 阈值比例 shadow（不驱动硬件，仅 SW 可见）
  // done_sticky     : SNN 完成 sticky 标志（snn_done_pulse 置位，W1C 清零）
  // pop_pending     : OUT_FIFO pop 流水线第一级（读 REG_OUT_DATA 的下一拍触发 pop）
  // -----------------------------------------------------------------------
  logic [7:0] threshold_ratio;
  logic done_sticky;
  logic pop_pending;

  // addr_offset 只取低 8 位用于寄存器解码
  wire [7:0] addr_offset = req_addr[7:0];
  // write_en: 总线有效且为写操作时拉高
  wire write_en = req_valid && req_write;
  // 标记未使用高位（lint 友好）
  // req_addr[31:8]: 高位用于顶层 bus_interconnect 路由，本模块不使用
  // req_wstrb[3:2]: 暂未用于任何字节精确写逻辑（当前只有 byte0/byte1 被精确控制）
  wire _unused = &{1'b0, req_addr[31:8], req_wstrb[3]}; // wstrb[2] 现用于 cim_test_data_neg 写入

  // -----------------------------------------------------------------------
  // 主寄存器写逻辑（同步时序）
  //
  // 结构说明：
  //   1. 复位后设置所有寄存器默认值（来自 snn_soc_pkg 参数）
  //   2. always_ff 开头：start_pulse/soft_reset_pulse 默认清零（W1P 机制的关键）
  //   3. sticky DONE 检测：snn_done_pulse 高时置 done_sticky
  //   4. case 写解码：写寄存器和 W1P/W1C 处理
  //
  // W1P 安全性分析：
  //   默认清零（step 2）先执行，case 分支（step 4）后执行，
  //   后赋值覆盖前赋值 → start_pulse/soft_reset_pulse 仅在写入拍为 1，
  //   下一拍再次被步骤 2 清零 → 精确 1 拍脉冲。
  //
  // W1C 与 sticky 同拍竞争：
  //   若同一拍 snn_done_pulse=1 且 CPU 写 DONE W1C=1：
  //     - if(snn_done_pulse) done_sticky <= 1  （先执行）
  //     - case: if(req_wdata[7]) done_sticky <= 0（后执行，覆盖）
  //   结果：清零优先（SystemVerilog last-write-wins）
  //   这在实践中极少发生，且清零优先是合理行为（CPU 认为已处理）。
  // -----------------------------------------------------------------------
  // 产生 W1P 脉冲（默认 0）
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // 复位值来自 snn_soc_pkg 参数（保证与包定义一致）
      neuron_threshold  <= THRESHOLD_DEFAULT[31:0];      // 默认阈值
      timesteps         <= TIMESTEPS_DEFAULT[7:0];       // 默认时步数
      threshold_ratio   <= THRESHOLD_RATIO_DEFAULT[7:0]; // 默认比例 4（定版 ratio_code=4）
      reset_mode        <= 1'b0;
      start_pulse      <= 1'b0;
      soft_reset_pulse <= 1'b0;
      done_sticky      <= 1'b0;
      cim_test_mode     <= 1'b0;
      cim_test_data_pos <= '0;
      cim_test_data_neg <= '0;
    end else begin
      // W1P 默认每拍清零（确保脉冲只有 1 拍宽度）
      // 这两行必须在 case 之前，以便 case 中的赋值可以覆盖它们
      start_pulse      <= 1'b0;
      soft_reset_pulse <= 1'b0;

      // sticky DONE：SNN 推理完成脉冲将 done_sticky 置 1（直到 W1C 清零）
      if (snn_done_pulse) begin
        done_sticky <= 1'b1;
      end

      if (write_en) begin
        case (addr_offset)
          REG_THRESHOLD: begin
            // 字节使能写入 neuron_threshold（32-bit，直接驱动 LIF 神经元）
            if (req_wstrb[0]) neuron_threshold[7:0]   <= req_wdata[7:0];
            if (req_wstrb[1]) neuron_threshold[15:8]  <= req_wdata[15:8];
            if (req_wstrb[2]) neuron_threshold[23:16] <= req_wdata[23:16];
            if (req_wstrb[3]) neuron_threshold[31:24] <= req_wdata[31:24];
          end
          REG_TIMESTEPS: begin
            // 只写 byte0（timesteps 是 8-bit，byte1~3 忽略）
            if (req_wstrb[0]) timesteps <= req_wdata[7:0];
          end
          REG_RESET_MODE: begin
            // 只写 bit0（reset_mode 是 1-bit）
            if (req_wstrb[0]) reset_mode <= req_wdata[0];
          end
          REG_THRESHOLD_RATIO: begin
            // Shadow-only register: keep ratio visible/configurable for firmware,
            // but leave actual threshold control to REG_THRESHOLD.
            // 仅是 SW 可见的比例系数寄存器，不驱动任何硬件信号
            if (req_wstrb[0]) threshold_ratio <= req_wdata[7:0];
          end
          REG_CIM_TEST: begin
            // bit[0]    = cim_test_mode（byte0，wstrb[0]）
            if (req_wstrb[0]) cim_test_mode     <= req_wdata[0];
            // bit[15:8] = cim_test_data_pos（正通道 ch0~9，byte1，wstrb[1]）
            if (req_wstrb[1]) cim_test_data_pos <= req_wdata[15:8];
            // bit[23:16]= cim_test_data_neg（负通道 ch10~19，byte2，wstrb[2]）
            // 建议写法：bus_write(REG_CIM_TEST, {8'h00, neg_val, pos_val, 7'h0, mode})
            //           wstrb=4'b0111 同时写三个字节
            if (req_wstrb[2]) cim_test_data_neg <= req_wdata[23:16];
          end
          REG_CIM_CTRL: begin
            // W1P: START / RESET
            // 写 bit[0]=1 → start_pulse 被置 1，覆盖本拍开头的默认清零
            if (req_wdata[0]) start_pulse <= 1'b1;
            // 写 bit[1]=1 → soft_reset_pulse 被置 1，同上
            if (req_wdata[1]) soft_reset_pulse <= 1'b1;
            // W1C: DONE
            // 写 bit[7]=1 → done_sticky 清零（SW 确认完成）
            if (req_wdata[7]) done_sticky <= 1'b0;
          end
          default: begin
            // 其他地址忽略（包括只读寄存器：写入无效）
          end
        endcase
      end
    end
  end

  // -----------------------------------------------------------------------
  // OUT_FIFO pop 2-cycle pipeline
  //
  // 目的：防止"读出队头数据"与"弹出队头"发生在同一周期，导致读到下一个数据。
  // fifo_sync 是 fall-through FIFO：pop 的同拍 rd_data 就切换为下一个。
  //
  // Cycle N:   CPU 读 REG_OUT_DATA
  //              → rdata 组合读出 out_fifo_rdata（当前队头，正确）
  //              → pop_pending <= 1（下一拍触发 pop）
  //              → out_fifo_pop = pop_pending 上一拍值（=0，本拍不 pop）
  //
  // Cycle N+1: out_fifo_pop <= pop_pending（=1）→ FIFO 实际 pop，rd_ptr 推进
  //              → pop_pending <= 0（无新读请求时）
  //
  // 若连续两拍都读 REG_OUT_DATA（如 for 循环），pop_pending 连续为 1，
  // out_fifo_pop 也连续为 1，正确地逐拍弹出。
  // -----------------------------------------------------------------------
  // OUT_FIFO_DATA 读出后下一拍弹出，避免同拍竞争
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pop_pending <= 1'b0;
      out_fifo_pop <= 1'b0;
    end else begin
      // 第 2 拍：将上一拍的 pop_pending 转化为实际 pop
      out_fifo_pop <= pop_pending;
      // 第 1 拍：检测本拍是否为有效 OUT_DATA 读请求
      // 条件：有效读操作 + 地址匹配 + FIFO 非空（空 FIFO 不应触发 pop）
      pop_pending <= (req_valid && !req_write && (addr_offset == REG_OUT_DATA) && !out_fifo_empty);
    end
  end

  // -----------------------------------------------------------------------
  // 寄存器读回（纯组合逻辑，无流水线）
  //
  // 所有只读寄存器（NUM_INPUTS, NUM_OUTPUTS, STATUS 等）均为组合读出，
  // 与总线请求同拍返回 rdata（bus_interconnect 支持 1 cycle 响应）。
  //
  // REG_ADC_SAT_COUNT 字段布局：
  //   rdata = {adc_sat_low, adc_sat_high}
  //   → rdata[31:16] = adc_sat_low  （低饱和计数，放在高 16 位）
  //   → rdata[15:0]  = adc_sat_high （高饱和计数，放在低 16 位）
  //   注意：这个打包顺序看起来反直觉（"low"在高位），但这是设计选择，
  //         固件读取时需按此顺序解析（参见 top_tb.sv 的读取示例）。
  //
  // REG_CIM_TEST 字段布局：
  //   rdata = {8'h0, cim_test_data_neg[7:0], cim_test_data_pos[7:0], 7'h0, cim_test_mode}
  //   → bit[23:16] = cim_test_data_neg（负通道合成值，ch 10~19）
  //   → bit[15:8]  = cim_test_data_pos（正通道合成值，ch 0~9）
  //   → bit[0]     = cim_test_mode
  //
  // REG_DBG_CNT_0 字段布局：
  //   rdata = {dbg_cim_cycle_cnt[31:16], dbg_dma_frame_cnt[15:0]}
  //   → bit[31:16] = cim_cycle_cnt
  //   → bit[15:0]  = dma_frame_cnt
  // -----------------------------------------------------------------------
  // 状态寄存器组合逻辑
  always_comb begin
    rdata = 32'h0;
    case (addr_offset)
      REG_THRESHOLD:   rdata = neuron_threshold;                    // 读回当前阈值
      REG_TIMESTEPS:   rdata = {24'h0, timesteps};                  // 高 24 位填 0
      REG_NUM_INPUTS:  rdata = {16'h0, NUM_INPUTS[15:0]};           // 只读参数：=64
      REG_NUM_OUTPUTS: rdata = {24'h0, NUM_OUTPUTS[7:0]};           // 只读参数：=10
      REG_RESET_MODE:  rdata = {31'h0, reset_mode};                 // 高 31 位填 0
      REG_CIM_CTRL: begin
        rdata = 32'h0;
        rdata[7] = done_sticky; // bit[7]: DONE（W1C sticky，硬件完成后为 1）
        // bit[0]/bit[1] START/SOFT_RESET 为 W1P，读回固定为 0（脉冲只有 1 拍，读时已清零）
      end
      REG_STATUS: begin
        rdata[0]   = snn_busy;          // SNN 推理进行中
        rdata[1]   = in_fifo_empty;     // 输入 FIFO 空
        rdata[2]   = in_fifo_full;      // 输入 FIFO 满
        rdata[3]   = out_fifo_empty;    // 输出 FIFO 空
        rdata[4]   = out_fifo_full;     // 输出 FIFO 满
        rdata[15:8]= timestep_counter;  // 当前时步（0 ~ timesteps-1）
      end
      REG_OUT_DATA: begin
        // 若 FIFO 空，返回 0（不触发 pop）；否则返回 fall-through 队头
        // pop_pending 机制确保下一拍才弹出，本拍读到的值有效
        if (out_fifo_empty) begin
          rdata = 32'h0;
        end else begin
          rdata = {{(32-4){1'b0}}, out_fifo_rdata}; // 高 28 位填 0，低 4 位 = spike_id
        end
      end
      REG_OUT_COUNT:  rdata = {{(32-$clog2(OUTPUT_FIFO_DEPTH+1)){1'b0}}, out_fifo_count}; // entry 数
      REG_THRESHOLD_RATIO: rdata = {24'h0, threshold_ratio}; // 高 24 位填 0，低 8 位 = ratio
      // ADC 饱和计数：sat_low 在高 16 位，sat_high 在低 16 位（见顶部注释）
      REG_ADC_SAT_COUNT:   rdata = {adc_sat_low, adc_sat_high};
      // CIM Test 寄存器：bit[23:16]=test_data_neg, bit[15:8]=test_data_pos, bit[0]=test_mode
      REG_CIM_TEST:        rdata = {8'h0, cim_test_data_neg, cim_test_data_pos, 7'h0, cim_test_mode};
      // Debug 计数器 0：高 16=cim_cycle，低 16=dma_frame
      REG_DBG_CNT_0:       rdata = {dbg_cim_cycle_cnt, dbg_dma_frame_cnt};
      // Debug 计数器 1：高 16=wl_stall，低 16=spike
      REG_DBG_CNT_1:       rdata = {dbg_wl_stall_cnt, dbg_spike_cnt};
      default:        rdata = 32'h0; // 未映射地址读回 0
    endcase
  end
endmodule
