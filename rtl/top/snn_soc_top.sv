// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/top/snn_soc_top.sv
// Purpose: Main digital SoC top-level integrating bus, registers, memories, DMA, SNN control chain, and peripheral stubs.
// Role in system: This is the internal digital top used for MVP simulation and later wrapped by chip_top for pad-level integration.
// Behavior summary: Instantiates/muxes all RTL blocks, connects register controls to datapath, and exports CIM interface signals.
// Key boundaries: Bus/control plane, memory/DMA data plane, and analog-facing CIM/DAC/ADC handshake interface.
// Design philosophy: Keep datapath and control interfaces explicit to support later E203/AXI integration with minimal churn.
// Verification focus: Cross-module wiring consistency, signal widths (especially Scheme-B signed data), and status propagation.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: snn_soc_top.sv
// 描述: SNN SoC 顶层。
//       - 实例化总线、SRAM、寄存器、DMA、FIFO、SNN 子系统与外设 stub
//       - 总线 master 由 Testbench 通过 dut.bus_if 直接驱动
//======================================================================
//
// ============================================================
// 模块总览 (Module Overview)
// ============================================================
// snn_soc_top 是整个数字 SoC 的顶层封装（内部数字顶，不含 pad 环）。
// 它将所有子模块"粘合"在一起，形成完整的推理加速系统：
//
//  [Testbench / 外部 Master]
//         │ bus_if (简化总线接口)
//         ▼
//   bus_interconnect         ← 地址译码 + 从设备路由
//    ├── instr_sram           ← 指令 SRAM（供 E203 使用，MVP 阶段备用）
//    ├── data_sram (双端口)   ← 输入像素数据存放，DMA 读端口复用
//    ├── weight_sram          ← 权重 SRAM（MVP 占位，实际权重烧入 RRAM）
//    ├── reg_bank             ← 控制/状态寄存器组（启动、阈值、测试模式等）
//    ├── dma_engine           ← 从 data_sram 读像素，打包后 push 到 input FIFO
//    ├── uart_stub            ← UART 占位（V1 不用）
//    ├── spi_stub             ← SPI Flash 占位（V1 不用）
//    └── fifo_regs            ← FIFO 状态只读寄存器（供 SW 轮询）
//
//  [输入 FIFO] → cim_array_ctrl (FSM主控) → wl_mux_wrapper → dac_ctrl
//             → cim_macro_blackbox (RRAM 仿真行为模型)
//             → adc_ctrl (Scheme B: 数字差分减法，20ch MUX)
//             → lif_neurons (有符号膜电位 LIF，输出 spike)
//             → [输出 FIFO] → SW 读取分类结果
//
//  CIM Test Mode (cim_test_mode=1):
//    旁路 cim_macro_blackbox 的所有输出，由数字侧产生 fake 延迟响应，
//    用于流片后硅上验证数字控制逻辑，不依赖真实 RRAM 宏的模拟特性。
//
//  Debug 计数器 (只随 rst_n 清零，不随 snn_soft_reset_pulse 清零):
//    dbg_dma_frame_cnt  ← DMA 向 FIFO push 的帧数
//    dbg_cim_cycle_cnt  ← SNN 处于 busy 状态的总周期数
//    dbg_spike_cnt      ← LIF 向输出 FIFO push 的 spike 次数
//    dbg_wl_stall_cnt   ← wl_valid_pulse 到来时 wl_mux_busy 冲突次数
// ============================================================

module snn_soc_top (
  // ----------------------------------------------------------
  // 全局时钟与异步低有效复位
  // clk  : 系统主时钟，所有寄存器均在上升沿采样
  // rst_n: 异步低有效复位，所有 always_ff 均使用 negedge rst_n 异步释放
  // ----------------------------------------------------------
  input  logic        clk,
  input  logic        rst_n,

  // UART (stub)
  // uart_rx / uart_tx: V1 阶段仅作为占位 IO 引出，uart_stub 内部直接将 tx 拉高
  input  logic        uart_rx,
  output logic        uart_tx,

  // SPI Flash (stub)
  // spi_*: SPI 接口占位信号，spi_stub 内部将片选拉高（不选中），其余信号接地
  output logic        spi_cs_n,
  output logic        spi_sck,
  output logic        spi_mosi,
  input  logic        spi_miso,

  // JTAG (stub)
  // jtag_*: JTAG 接口占位，jtag_stub 将 tdo 直接连 tdi（pass-through），V2 接 E203 DM
  input  logic        jtag_tck,
  input  logic        jtag_tms,
  input  logic        jtag_tdi,
  output logic        jtag_tdo
);
  // 导入 snn_soc_pkg 中的全局参数与地址常量
  // 例如：NUM_INPUTS=64, ADC_BITS=8, ADC_CHANNELS=20, NEURON_DATA_WIDTH=9 等
  import snn_soc_pkg::*;

  // ----------------------------------------------------------
  // 简化总线接口（Testbench 通过层级引用驱动）
  // bus_simple_if 是一个 interface，内含 m_valid/m_write/m_addr/m_wdata/
  // m_wstrb/m_ready/m_rdata/m_rvalid 等信号。
  // MVP 阶段 Testbench 直接写 dut.bus_if.m_valid 等信号来模拟 CPU 总线事务。
  // ----------------------------------------------------------
  bus_simple_if bus_if(.clk(clk));

  // ----------------------------------------------------------
  // bus_interconnect → slave 连接信号组
  // 每个从设备对应一组：
  //   *_req_valid : 总线发给该从设备的请求有效脉冲（单拍）
  //   *_req_write : 1=写操作，0=读操作
  //   *_req_addr  : 字节地址（已由互联模块减去 BASE，变为从设备本地偏移）
  //   *_req_wdata : 写数据（32-bit）
  //   *_req_wstrb : 字节写使能（4-bit，1 bit per byte）
  //   *_rdata     : 从设备返回的读数据（组合输出，读请求当拍有效）
  // ----------------------------------------------------------

  // 指令 SRAM 接口：存放 E203 CPU 指令（MVP 阶段由 TB 预加载，CPU 未接入）
  logic        instr_req_valid, instr_req_write;
  logic [31:0] instr_req_addr,  instr_req_wdata;
  logic [3:0]  instr_req_wstrb;
  logic [31:0] instr_rdata;

  // 数据 SRAM 接口：存放输入像素矩阵（8x8=64 pixels），DMA 从这里读取
  // 使用 sram_simple_dp（双端口）：bus 侧端口 + DMA 专用只读端口
  logic        data_req_valid,  data_req_write;
  logic [31:0] data_req_addr,   data_req_wdata;
  logic [3:0]  data_req_wstrb;
  logic [31:0] data_rdata;

  // 权重 SRAM 接口：MVP 占位，实际 RRAM 权重在流片前 program 进阵列
  logic        weight_req_valid, weight_req_write;
  logic [31:0] weight_req_addr,  weight_req_wdata;
  logic [3:0]  weight_req_wstrb;
  logic [31:0] weight_rdata;

  // 控制寄存器接口：reg_bank 包含启动/状态/阈值/测试模式等寄存器
  logic        reg_req_valid, reg_req_write;
  logic [31:0] reg_req_addr,  reg_req_wdata;
  logic [3:0]  reg_req_wstrb;
  logic [31:0] reg_rdata;
  // reg_resp_read_pulse: 当前周期 reg_bank 读操作完成脉冲（bus_interconnect 产生）
  // reg_resp_addr      : 对应的读响应地址（bus_interconnect 产生，reg_bank 可用于调试）
  logic        reg_resp_read_pulse;
  logic [31:0] reg_resp_addr;

  // DMA 寄存器接口：dma_engine 的控制寄存器（源地址、长度、启动等）
  logic        dma_req_valid, dma_req_write;
  logic [31:0] dma_req_addr,  dma_req_wdata;
  logic [3:0]  dma_req_wstrb;
  logic [31:0] dma_rdata;

  // UART stub 接口（V1 占位，内部无实际功能逻辑）
  logic        uart_req_valid, uart_req_write;
  logic [31:0] uart_req_addr,  uart_req_wdata;
  logic [3:0]  uart_req_wstrb;
  logic [31:0] uart_rdata;

  // SPI stub 接口（V1 占位，内部无实际功能逻辑）
  logic        spi_req_valid, spi_req_write;
  logic [31:0] spi_req_addr,  spi_req_wdata;
  logic [3:0]  spi_req_wstrb;
  logic [31:0] spi_rdata;

  // FIFO 只读状态寄存器接口（fifo_regs 提供 count/empty/full 给 SW 查询）
  logic        fifo_req_valid, fifo_req_write;
  logic [31:0] fifo_req_addr,  fifo_req_wdata;
  logic [3:0]  fifo_req_wstrb;
  logic [31:0] fifo_rdata;

  // ----------------------------------------------------------
  // 输入 FIFO 连接信号
  // 宽度 = NUM_INPUTS = 64 bits，每个 bit 对应一个像素的当前比特平面值
  // DMA 负责 push，cim_array_ctrl 负责 pop
  // ----------------------------------------------------------
  logic        in_fifo_push, in_fifo_pop;
  logic [NUM_INPUTS-1:0] in_fifo_wdata; // DMA 写入的 64-bit spike bitmap
  logic [NUM_INPUTS-1:0] in_fifo_rdata; // cim_array_ctrl 读出的 64-bit bitmap
  logic        in_fifo_empty, in_fifo_full;
  logic        in_fifo_overflow, in_fifo_underflow;  // 错误标志（接 _unused 以抑制 lint）
  logic [$clog2(INPUT_FIFO_DEPTH+1)-1:0] in_fifo_count; // 当前 FIFO 中的有效条目数

  // ----------------------------------------------------------
  // 输出 FIFO 连接信号
  // 宽度 = 4 bits = $clog2(NUM_OUTPUTS=10) 上取整，存放 LIF 的分类结果（0-9 类别）
  // lif_neurons 负责 push，reg_bank 读操作时 pop（或 SW 通过 reg_bank 读取）
  // ----------------------------------------------------------
  logic        out_fifo_push, out_fifo_pop;
  logic [3:0]  out_fifo_wdata; // LIF 写入的 4-bit 类别标签
  logic [3:0]  out_fifo_rdata; // reg_bank/SW 读出的分类结果
  logic        out_fifo_empty, out_fifo_full;
  logic        out_fifo_overflow, out_fifo_underflow; // 错误标志（接 _unused 以抑制 lint）
  logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] out_fifo_count;

  // ----------------------------------------------------------
  // lint 抑制：将未使用的信号 XOR 成一根 wire，防止 EDA 工具警告
  // reg_resp_read_pulse / reg_resp_addr: bus_interconnect 产生，当前版本 reg_bank 未使用
  // in_fifo_overflow/underflow, out_fifo_overflow/underflow: 错误检测信号，
  //   功能仿真中暂不处理（可在 TB assertion 中检查）
  // ----------------------------------------------------------
  wire _unused_top = reg_resp_read_pulse ^ &reg_resp_addr ^
                     in_fifo_overflow ^ in_fifo_underflow ^
                     out_fifo_overflow ^ out_fifo_underflow;

  // ----------------------------------------------------------
  // DMA 与 data_sram 之间的专用只读总线
  // DMA 通过此端口直接访问 data_sram，不占用主总线带宽
  // dma_rd_en  : DMA 发出的读使能（单拍）
  // dma_rd_addr: DMA 发出的字节地址
  // dma_rd_data: data_sram 返回的 32-bit 数据（组合输出，同拍有效）
  // ----------------------------------------------------------
  logic        dma_rd_en;
  logic [31:0] dma_rd_addr;
  logic [31:0] dma_rd_data;

  // ----------------------------------------------------------
  // SNN 子系统内部连接信号
  // 信号流向：
  //   cim_array_ctrl → (wl_bitmap, wl_valid_pulse)
  //     → wl_mux_wrapper → (wl_bitmap_wrapped, wl_valid_pulse_wrapped)
  //       → dac_ctrl → (wl_spike, dac_valid) → cim_macro_blackbox
  // ----------------------------------------------------------

  // wl_bitmap       : 64-bit WL 激活位图（来自 input FIFO，1=该行被激活）
  // wl_valid_pulse  : wl_bitmap 有效脉冲（单拍，cim_array_ctrl 产生）
  logic [NUM_INPUTS-1:0] wl_bitmap;
  logic                  wl_valid_pulse;

  // wl_bitmap_wrapped / wl_valid_pulse_wrapped:
  //   经过 wl_mux_wrapper 时序对齐后的 bitmap 和有效脉冲
  //   wl_mux_wrapper 负责将 64-bit bitmap 分组（8组x8bits）时分复用，
  //   通过外部 WL 数字 MUX 发送到 128 条真实字线（IO 引脚有限时使用）
  logic [NUM_INPUTS-1:0] wl_bitmap_wrapped;
  logic                  wl_valid_pulse_wrapped;

  // WL 复用协议原型信号（与外部 WL MUX 芯片的接口，当前版本未连到 chip_top pad）
  // wl_data     : 当前分组的 8-bit WL 数据
  // wl_group_sel: 当前选中的组编号（3-bit，0-7）
  // wl_latch    : WL MUX 锁存使能脉冲
  // wl_mux_busy : WL MUX 当前正在发送（忙标志），cim_array_ctrl 需等待其就绪
  logic [WL_GROUP_WIDTH-1:0] wl_data;
  logic [$clog2(WL_GROUP_COUNT)-1:0] wl_group_sel;
  logic                               wl_latch;
  logic                               wl_mux_busy;

  // wl_spike: dac_ctrl 将 wl_bitmap 转换为模拟脉冲的数字控制信号（每 bit 对应一条 WL）
  logic [NUM_INPUTS-1:0] wl_spike;

  // DAC 握手信号
  // dac_valid      : dac_ctrl 通知 cim_macro 当前 WL spike 有效，可以读取
  // dac_ready      : cim_macro 通知 dac_ctrl 已准备好接收（MUX 后信号）
  // dac_done_pulse : dac_ctrl 完成本次 WL 行激活的完成脉冲（单拍）
  logic                  dac_valid;
  logic                  dac_ready;
  logic                  dac_done_pulse;

  // CIM 启动/完成握手
  // cim_start_pulse : cim_array_ctrl 发给 cim_macro_blackbox 的计算启动脉冲（单拍）
  // cim_done        : cim_macro_blackbox 通知 cim_array_ctrl 计算完成（MUX 后信号）
  logic                  cim_start_pulse;
  logic                  cim_done;

  // ADC 相关信号
  // adc_kick_pulse : cim_array_ctrl 发给 adc_ctrl 的采样触发脉冲（单拍）
  // adc_start      : adc_ctrl 发给 cim_macro_blackbox 的 BL 列选通启动信号
  // adc_done       : cim_macro_blackbox 通知 adc_ctrl 本列采样完成（MUX 后信号）
  // bl_sel         : 当前选中的 BL 列编号（5-bit，0-19，对应 20 个差分通道）
  // bl_data        : 当前 BL 列的 ADC 采样结果（8-bit，MUX 后信号）
  logic                  adc_kick_pulse;
  logic                  adc_start;
  logic                  adc_done;
  logic [$clog2(ADC_CHANNELS)-1:0] bl_sel;
  logic [ADC_BITS-1:0]   bl_data;

  // LIF 神经元输入
  // neuron_in_valid: adc_ctrl 通知 lif_neurons 本批 ADC 结果已就绪（单拍）
  // neuron_in_data : 20 通道 Scheme B 差分结果，每通道 9-bit 有符号数
  //   维度：[NUM_OUTPUTS-1:0][NEURON_DATA_WIDTH-1:0] = [9:0][8:0]
  //   注意：NUM_OUTPUTS=10（分类数），NEURON_DATA_WIDTH=9（含符号位）
  logic                  neuron_in_valid;
  logic [NUM_OUTPUTS-1:0][NEURON_DATA_WIDTH-1:0] neuron_in_data;

  // 来自 reg_bank 的控制寄存器
  // neuron_threshold: LIF 膜电位阈值（32-bit，默认 THRESHOLD_DEFAULT=10200）
  // timesteps       : 推理时间步数（8-bit，定版默认 10）
  // reset_mode      : LIF 复位模式：0=减法复位（soft），1=归零复位（hard）
  // snn_busy        : SNN 子系统忙标志（cim_array_ctrl → reg_bank，SW 轮询）
  // snn_done_pulse  : SNN 推理完成脉冲（单拍，cim_array_ctrl → reg_bank）
  // snn_start_pulse : SW 写寄存器触发的推理启动脉冲（reg_bank → cim_array_ctrl）
  // snn_soft_reset_pulse: SW 写寄存器触发的软复位脉冲（不清零 debug 计数器）
  // timestep_counter: 当前时间步计数值（cim_array_ctrl → reg_bank 用于状态显示）
  // bitplane_shift  : 当前处理的比特平面偏移（0~7，用于多比特精度编码）
  logic [31:0] neuron_threshold;
  logic [7:0]  timesteps;
  logic        reset_mode;
  logic        snn_busy;
  logic        snn_done_pulse;
  logic        snn_start_pulse;
  logic        snn_soft_reset_pulse;
  logic [7:0]  timestep_counter;
  logic [$clog2(PIXEL_BITS)-1:0] bitplane_shift;

  // ----------------------------------------------------------
  // lint 抑制：WL MUX 协议信号当前未连接到 chip_top pad，
  // 用一根 wire 将它们消费掉，避免 EDA 未连接警告。
  // 后续 chip_top 集成时需删除此 wire 并真正连接到 IO pad。
  // ----------------------------------------------------------
  wire _unused_wl_mux = ^wl_data ^ ^wl_group_sel ^ wl_latch ^ wl_mux_busy;

  // ----------------------------------------------------------
  // ADC 饱和监控（adc_ctrl → reg_bank）
  // adc_sat_high: 所有采样中超过高饱和门限的计数（16-bit 饱和计数器）
  // adc_sat_low : 所有采样中低于低饱和门限的计数（16-bit 饱和计数器）
  // SW 可读取这两个计数器来评估 ADC 工作点是否合理
  // ----------------------------------------------------------
  logic [15:0] adc_sat_high;
  logic [15:0] adc_sat_low;

  // ----------------------------------------------------------
  // CIM Test Mode 相关信号
  //
  // 设计意图：流片后上电，在模拟宏（RRAM 阵列）就绪之前，
  // 先用 cim_test_mode=1 验证数字控制链路是否正常工作。
  //
  // cim_test_mode : reg_bank 中的测试使能位（SW 写入）
  // cim_test_data : reg_bank 中的测试数据（8-bit，SW 写入，作为 fake ADC 输出）
  //
  // _hw 后缀：cim_macro_blackbox 的原始输出（test mode MUX 之前）
  // _test 后缀：数字侧产生的 fake 延迟响应
  // 无后缀（dac_ready/cim_done/adc_done/bl_data）：MUX 后信号，是实际连接到控制链路的
  // ----------------------------------------------------------
  logic                cim_test_mode;
  logic [ADC_BITS-1:0] cim_test_data;
  // 硬件侧（cim_macro_blackbox 原始输出，test mode MUX 前）
  logic                dac_ready_hw;
  logic                cim_done_hw;
  logic                adc_done_hw;
  logic [ADC_BITS-1:0] bl_data_hw;
  // 测试侧响应信号
  // dac_ready_test: test mode 下 DAC 始终就绪（组合赋值 1'b1）
  // cim_done_test : test mode 下由计数器产生的 2 拍延迟 done 脉冲
  // adc_done_test : test mode 下由计数器产生的 1 拍延迟 done 脉冲
  // test_cim_cnt  : CIM fake 延迟倒计时计数器（4-bit，初值=1，即 2 拍延迟）
  // test_cim_busy : CIM fake 延迟进行中标志
  // test_adc_cnt  : ADC fake 延迟倒计时计数器（4-bit，初值=0，即 1 拍延迟）
  // test_adc_busy : ADC fake 延迟进行中标志
  logic                dac_ready_test;
  logic                cim_done_test;
  logic                adc_done_test;
  logic [3:0]          test_cim_cnt;
  logic                test_cim_busy;
  logic [3:0]          test_adc_cnt;
  logic                test_adc_busy;

  // ----------------------------------------------------------
  // Debug 计数器（16-bit 饱和计数，仅 rst_n 清零）
  // 这些计数器帮助 SW 诊断系统运行状态，不受 snn_soft_reset_pulse 影响，
  // 避免软复位时丢失调试信息。
  // 饱和策略：到达 0xFFFF 后保持不再递增（!(&cnt) 判断非全1再加）
  // ----------------------------------------------------------
  logic [15:0] dbg_dma_frame_cnt;  // DMA 向 input FIFO 成功 push 的次数（每次 = 一帧 64-bit bitmap）
  logic [15:0] dbg_cim_cycle_cnt;  // SNN 处于 busy 状态的累计时钟周期数
  logic [15:0] dbg_spike_cnt;      // LIF 向 output FIFO push spike 的次数（每次 = 一个推理结果）
  logic [15:0] dbg_wl_stall_cnt;   // wl_valid_pulse 到来时 wl_mux 仍忙的冲突次数（协议违规计数）

  //======================
  // 总线互联
  // bus_interconnect 是 1-master N-slave 的简化总线结构：
  //   - 地址译码：将 m_addr 与各从设备地址段比较，确定目标从设备
  //   - 请求寄存：将主设备请求寄存一拍后转发给从设备
  //   - 读数据 MUX：根据目标从设备选择对应的 rdata 返回给主设备
  //   - 固定 1-cycle 延迟：主设备发出请求后，下一拍收到响应
  //======================
  bus_interconnect u_bus_interconnect (
    .clk            (clk),
    .rst_n          (rst_n),

    // 主设备侧：来自 bus_if 接口（Testbench 直接驱动）
    .m_valid        (bus_if.m_valid),   // 主设备请求有效
    .m_write        (bus_if.m_write),   // 1=写，0=读
    .m_addr         (bus_if.m_addr),    // 32-bit 字节地址
    .m_wdata        (bus_if.m_wdata),   // 32-bit 写数据
    .m_wstrb        (bus_if.m_wstrb),   // 4-bit 字节写使能
    .m_ready        (bus_if.m_ready),   // 写操作完成握手（互联 → 主设备）
    .m_rdata        (bus_if.m_rdata),   // 32-bit 读数据返回（互联 → 主设备）
    .m_rvalid       (bus_if.m_rvalid),  // 读数据有效（互联 → 主设备）

    // 从设备侧：各从设备接口信号（已在上方声明）
    .instr_req_valid(instr_req_valid),
    .instr_req_write(instr_req_write),
    .instr_req_addr (instr_req_addr),
    .instr_req_wdata(instr_req_wdata),
    .instr_req_wstrb(instr_req_wstrb),
    .instr_rdata    (instr_rdata),

    .data_req_valid (data_req_valid),
    .data_req_write (data_req_write),
    .data_req_addr  (data_req_addr),
    .data_req_wdata (data_req_wdata),
    .data_req_wstrb (data_req_wstrb),
    .data_rdata     (data_rdata),

    .weight_req_valid(weight_req_valid),
    .weight_req_write(weight_req_write),
    .weight_req_addr (weight_req_addr),
    .weight_req_wdata(weight_req_wdata),
    .weight_req_wstrb(weight_req_wstrb),
    .weight_rdata    (weight_rdata),

    .reg_req_valid  (reg_req_valid),
    .reg_req_write  (reg_req_write),
    .reg_req_addr   (reg_req_addr),
    .reg_req_wdata  (reg_req_wdata),
    .reg_req_wstrb  (reg_req_wstrb),
    .reg_rdata      (reg_rdata),
    // reg_resp_read_pulse / reg_resp_addr: 由互联生成，表示当前拍是 reg 区域的读响应
    // 接到 _unused_top 以抑制 lint（reg_bank 当前不使用这两个信号）
    .reg_resp_read_pulse(reg_resp_read_pulse),
    .reg_resp_addr  (reg_resp_addr),

    .dma_req_valid  (dma_req_valid),
    .dma_req_write  (dma_req_write),
    .dma_req_addr   (dma_req_addr),
    .dma_req_wdata  (dma_req_wdata),
    .dma_req_wstrb  (dma_req_wstrb),
    .dma_rdata      (dma_rdata),

    .uart_req_valid (uart_req_valid),
    .uart_req_write (uart_req_write),
    .uart_req_addr  (uart_req_addr),
    .uart_req_wdata (uart_req_wdata),
    .uart_req_wstrb (uart_req_wstrb),
    .uart_rdata     (uart_rdata),

    .spi_req_valid  (spi_req_valid),
    .spi_req_write  (spi_req_write),
    .spi_req_addr   (spi_req_addr),
    .spi_req_wdata  (spi_req_wdata),
    .spi_req_wstrb  (spi_req_wstrb),
    .spi_rdata      (spi_rdata),

    .fifo_req_valid (fifo_req_valid),
    .fifo_req_write (fifo_req_write),
    .fifo_req_addr  (fifo_req_addr),
    .fifo_req_wdata (fifo_req_wdata),
    .fifo_req_wstrb (fifo_req_wstrb),
    .fifo_rdata     (fifo_rdata)
  );

  //======================
  // SRAM 实例
  // 三块 SRAM 分别服务于不同用途，地址范围来自 snn_soc_pkg
  //======================

  // 指令 SRAM：MEM_BYTES = INSTR_SRAM_BYTES（见 pkg）
  // sram_simple：单端口，1-cycle 读延迟（组合输出），支持字节写使能
  // MVP 阶段：TB 通过总线预加载指令，CPU 不实际执行（E203 V2 接入）
  sram_simple #(.MEM_BYTES(INSTR_SRAM_BYTES)) u_instr_sram (
    .clk       (clk),
    .rst_n     (rst_n),
    .req_valid (instr_req_valid),
    .req_write (instr_req_write),
    .req_addr  (instr_req_addr),   // 已由 bus_interconnect 转换为本地偏移
    .req_wdata (instr_req_wdata),
    .req_wstrb (instr_req_wstrb),
    .rdata     (instr_rdata)       // 读数据，组合输出（下一拍经 bus_interconnect 寄存后返回主设备）
  );

  // 数据 SRAM：MEM_BYTES = DATA_SRAM_BYTES，双端口（sram_simple_dp）
  // 端口 A（bus 侧）：由总线读写（TB 写入像素数据）
  // 端口 B（DMA 侧）：DMA 专用只读端口，不占用总线带宽
  // 为什么需要双端口：DMA 搬运数据时若与总线共用单端口会产生冲突
  sram_simple_dp #(.MEM_BYTES(DATA_SRAM_BYTES)) u_data_sram (
    .clk       (clk),
    .rst_n     (rst_n),
    // 端口 A：总线访问
    .req_valid (data_req_valid),
    .req_write (data_req_write),
    .req_addr  (data_req_addr),
    .req_wdata (data_req_wdata),
    .req_wstrb (data_req_wstrb),
    .rdata     (data_rdata),
    // 端口 B：DMA 只读访问
    .dma_rd_en (dma_rd_en),        // DMA 读使能（单拍有效）
    .dma_rd_addr(dma_rd_addr),     // DMA 字节地址
    .dma_rdata (dma_rd_data)       // 32-bit 读出数据（组合，同拍有效）
  );

  // 权重 SRAM：MEM_BYTES = WEIGHT_SRAM_BYTES
  // MVP 阶段：占位用，实际 RRAM 权重直接固化在阵列中，无需在线加载
  // V2 规划：通过 SPI/DMA 下载量化权重到 SRAM，再 program 到 RRAM
  sram_simple #(.MEM_BYTES(WEIGHT_SRAM_BYTES)) u_weight_sram (
    .clk       (clk),
    .rst_n     (rst_n),
    .req_valid (weight_req_valid),
    .req_write (weight_req_write),
    .req_addr  (weight_req_addr),
    .req_wdata (weight_req_wdata),
    .req_wstrb (weight_req_wstrb),
    .rdata     (weight_rdata)
  );

  //======================
  // DMA
  // dma_engine 负责将 data_sram 中的像素数据搬运到 input FIFO。
  // 工作流程：
  //   SW 配置 dma_engine 寄存器（源地址、长度），写 START bit →
  //   DMA 从 data_sram 端口 B 读出 32-bit 字，拼接成 64-bit bitmap →
  //   每凑齐 64-bit 就 push 一次 input FIFO →
  //   搬运完成后置 done 中断（当前版本无中断，靠 dbg_dma_frame_cnt 监控）
  // 注意：in_fifo_full 时 DMA 暂停 push（背压机制）
  //======================
  dma_engine u_dma (
    .clk         (clk),
    .rst_n       (rst_n),
    // 总线寄存器访问（SW 配置 DMA）
    .req_valid   (dma_req_valid),
    .req_write   (dma_req_write),
    .req_addr    (dma_req_addr),
    .req_wdata   (dma_req_wdata),
    .req_wstrb   (dma_req_wstrb),
    .rdata       (dma_rdata),
    // data_sram 端口 B（DMA 专用只读）
    .dma_rd_en   (dma_rd_en),
    .dma_rd_addr (dma_rd_addr),
    .dma_rd_data (dma_rd_data),
    // input FIFO 写接口
    .in_fifo_push(in_fifo_push),   // push 使能（单拍）
    .in_fifo_wdata(in_fifo_wdata), // 64-bit bitmap 数据
    .in_fifo_full(in_fifo_full)    // 背压信号：full 时 DMA 不 push
  );

  //======================
  // FIFO
  // 两个同步 FIFO：input FIFO（像素 bitmap）和 output FIFO（分类结果）
  //======================

  // 输入 FIFO：WIDTH=NUM_INPUTS=64，DEPTH=INPUT_FIFO_DEPTH（见 pkg）
  // 生产者：dma_engine；消费者：cim_array_ctrl
  // 时序解耦：DMA 搬运速度与 SNN 推理速度可以不同步
  fifo_sync #(.WIDTH(NUM_INPUTS), .DEPTH(INPUT_FIFO_DEPTH)) u_input_fifo (
    .clk       (clk),
    .rst_n     (rst_n),
    .push      (in_fifo_push),
    .push_data (in_fifo_wdata),
    .pop       (in_fifo_pop),       // cim_array_ctrl 消费 bitmap 时发出
    .rd_data   (in_fifo_rdata),     // 当前 FIFO 头部的 64-bit bitmap
    .empty     (in_fifo_empty),     // cim_array_ctrl 检查 empty 来决定是否启动
    .full      (in_fifo_full),      // DMA 背压信号
    .count     (in_fifo_count),     // SW 通过 fifo_regs 读取，用于调试
    .overflow  (in_fifo_overflow),  // push 时已满（接 _unused，TB 可加 assertion）
    .underflow (in_fifo_underflow)  // pop 时已空（接 _unused，TB 可加 assertion）
  );

  // 输出 FIFO：WIDTH=4（分类结果 0-9，4-bit 足够），DEPTH=OUTPUT_FIFO_DEPTH
  // 生产者：lif_neurons（推理完成后 push 获胜神经元编号）
  // 消费者：reg_bank（SW 读取分类结果时 pop）
  fifo_sync #(.WIDTH(4), .DEPTH(OUTPUT_FIFO_DEPTH)) u_output_fifo (
    .clk       (clk),
    .rst_n     (rst_n),
    .push      (out_fifo_push),
    .push_data (out_fifo_wdata),
    .pop       (out_fifo_pop),       // reg_bank 被 SW 读取结果时产生 pop 脉冲
    .rd_data   (out_fifo_rdata),     // SW 读到的 4-bit 分类结果
    .empty     (out_fifo_empty),
    .full      (out_fifo_full),
    .count     (out_fifo_count),
    .overflow  (out_fifo_overflow),
    .underflow (out_fifo_underflow)
  );

  //======================
  // Reg Bank + FIFO Regs
  // reg_bank：核心控制/状态寄存器，包含：
  //   - REG_CTRL: snn_start_pulse / snn_soft_reset_pulse / reset_mode / cim_test_mode
  //   - REG_STATUS: snn_busy / snn_done_pulse / timestep_counter 等
  //   - REG_THRESHOLD_RATIO: 8-bit 阈值比率（定版默认 4 = 0x04）
  //   - REG_TIMESTEPS: 时间步数（定版默认 10）
  //   - REG_CIM_TEST_DATA: 8-bit fake ADC 数据（测试模式用）
  //   - REG_ADC_SAT: ADC 饱和计数高/低
  //   - REG_DBG_*: 4 个调试计数器
  //   - REG_OUT_FIFO: 输出 FIFO 读取（包含 pop 动作）
  //
  // fifo_regs：轻量级只读寄存器，提供 FIFO count/empty/full 给 SW 查询
  //   与 reg_bank 分离的原因：地址空间分配设计决策，简化各模块接口
  //======================
  reg_bank u_reg_bank (
    .clk            (clk),
    .rst_n          (rst_n),
    // 总线访问接口
    .req_valid      (reg_req_valid),
    .req_write      (reg_req_write),
    .req_addr       (reg_req_addr),
    .req_wdata      (reg_req_wdata),
    .req_wstrb      (reg_req_wstrb),
    .rdata          (reg_rdata),
    // SNN 状态输入（reg_bank 将这些状态映射到 SW 可读寄存器）
    .snn_busy       (snn_busy),
    .snn_done_pulse (snn_done_pulse),
    .timestep_counter(timestep_counter),
    // FIFO 状态输入（SW 通过 reg_bank 查询 FIFO 满/空状态）
    .in_fifo_empty  (in_fifo_empty),
    .in_fifo_full   (in_fifo_full),
    .out_fifo_empty (out_fifo_empty),
    .out_fifo_full  (out_fifo_full),
    .out_fifo_rdata (out_fifo_rdata),  // SW 读结果寄存器时直接返回这个值
    .out_fifo_count (out_fifo_count),  // 待读取结果数量
    // ADC 饱和监控（来自 adc_ctrl，映射到可读寄存器）
    .adc_sat_high   (adc_sat_high),
    .adc_sat_low    (adc_sat_low),
    // Debug 计数器（来自顶层，映射到可读寄存器）
    .dbg_dma_frame_cnt(dbg_dma_frame_cnt),
    .dbg_cim_cycle_cnt(dbg_cim_cycle_cnt),
    .dbg_spike_cnt    (dbg_spike_cnt),
    .dbg_wl_stall_cnt (dbg_wl_stall_cnt),
    // 控制输出（SW 写 reg_bank 后产生的脉冲/电平信号）
    .neuron_threshold(neuron_threshold), // 阈值（32-bit，低 8-bit 有效）
    .timesteps      (timesteps),          // 时间步数
    .reset_mode     (reset_mode),         // LIF 复位模式（0=软, 1=硬）
    .start_pulse    (snn_start_pulse),    // 推理启动脉冲（单拍）
    .soft_reset_pulse(snn_soft_reset_pulse), // 软复位脉冲（单拍）
    .cim_test_mode  (cim_test_mode),      // CIM 测试模式使能（电平）
    .cim_test_data  (cim_test_data),      // fake ADC 数据（电平）
    .out_fifo_pop   (out_fifo_pop)        // SW 读输出结果时触发 pop（脉冲）
  );

  // FIFO 只读状态寄存器（供 SW 轮询 FIFO 占用情况）
  // fifo_regs 没有时序逻辑，是纯组合的寄存器视图
  fifo_regs u_fifo_regs (
    .req_valid    (fifo_req_valid),
    .req_write    (fifo_req_write),
    .req_addr     (fifo_req_addr),
    .req_wdata    (fifo_req_wdata),
    .req_wstrb    (fifo_req_wstrb),
    .rdata        (fifo_rdata),
    // FIFO 状态输入（直接来自两个 fifo_sync 实例）
    .in_fifo_count(in_fifo_count),
    .out_fifo_count(out_fifo_count),
    .in_fifo_empty(in_fifo_empty),
    .in_fifo_full (in_fifo_full),
    .out_fifo_empty(out_fifo_empty),
    .out_fifo_full(out_fifo_full)
  );

  //======================
  // SNN 子系统
  // 推理数据流（单个时间步示意）：
  //   周期 0 : SW 写 START → snn_start_pulse 脉冲
  //   周期 1 : cim_array_ctrl 从 input FIFO pop 64-bit bitmap，置 snn_busy
  //   周期 2 : cim_array_ctrl 发出 wl_bitmap + wl_valid_pulse
  //   周期 3 : wl_mux_wrapper 转发（可能多拍用于时分复用）
  //   周期 4 : dac_ctrl 将 bitmap 转为模拟脉冲，发出 dac_valid
  //   周期 5 : cim_macro_blackbox 接收 spike，发出 cim_done（模拟/fake 延迟）
  //   周期 6 : cim_array_ctrl 发出 adc_kick_pulse → adc_ctrl 开始 20 路扫描
  //   周期 7~26: adc_ctrl 逐列扫描（每列: adc_start → adc_done → 采样 bl_data）
  //   周期 27: adc_ctrl 发出 neuron_in_valid + neuron_in_data[19:0]（20 个 9-bit）
  //   周期 28: lif_neurons 更新膜电位，判断阈值，push spike 到 output FIFO
  //   周期 29: cim_array_ctrl 完成当前时间步；若达到 timesteps 则发出 snn_done_pulse
  //======================

  // cim_array_ctrl：SNN 主控 FSM
  // 状态：IDLE → FETCH（pop FIFO）→ SEND_WL → WAIT_DAC → WAIT_CIM → WAIT_ADC → DONE
  // 输出：wl_bitmap, wl_valid_pulse, cim_start_pulse, adc_kick_pulse, neuron_in_valid
  // 输入：snn_start_pulse, in_fifo_empty, dac_done_pulse, cim_done, adc_kick_pulse
  cim_array_ctrl u_cim_ctrl (
    .clk             (clk),
    .rst_n           (rst_n),
    .soft_reset_pulse(snn_soft_reset_pulse), // SW 软复位：FSM 回到 IDLE，不清 debug 计数器
    .start_pulse     (snn_start_pulse),      // SW 启动推理（单拍触发）
    .timesteps       (timesteps),            // 时间步总数（MVP=1）
    .in_fifo_rdata   (in_fifo_rdata),        // 从 input FIFO 读出的 64-bit bitmap
    .in_fifo_empty   (in_fifo_empty),        // FIFO 空则无法启动
    .in_fifo_pop     (in_fifo_pop),          // FSM 控制的 FIFO pop 信号
    .wl_bitmap       (wl_bitmap),            // 输出给 wl_mux_wrapper 的 WL 激活位图
    .wl_valid_pulse  (wl_valid_pulse),       // bitmap 有效脉冲
    .dac_done_pulse  (dac_done_pulse),       // dac_ctrl 完成脉冲（FSM 等待此信号）
    .cim_start_pulse (cim_start_pulse),      // 触发 cim_macro 开始计算
    .cim_done        (cim_done),             // 等待 cim_macro 完成（MUX 后信号）
    .adc_kick_pulse  (adc_kick_pulse),       // 触发 adc_ctrl 开始扫描
    .neuron_in_valid (neuron_in_valid),      // adc_ctrl 完成后产生（透传）
    .busy            (snn_busy),             // 推理进行中标志
    .done_pulse      (snn_done_pulse),       // 当前图片推理完成脉冲
    .timestep_counter(timestep_counter),     // 当前时间步计数（供 SW 监控）
    .bitplane_shift  (bitplane_shift)        // 比特平面偏移（多位精度，MVP=0）
  );

  // wl_mux_wrapper：WL 字线时分复用包装器
  // 功能：将 64-bit wl_bitmap 分为 8 组，每组 8-bit，通过外部 WL MUX 时分发送到 128 条字线
  // 原因：芯片 IO 有限（48 pad），无法将 128 条 WL 全部引出，用 MUX 节省 pin count
  // 接口：
  //   输入侧  ← cim_array_ctrl（wl_bitmap, wl_valid_pulse）
  //   输出侧  → dac_ctrl（wl_bitmap_wrapped, wl_valid_pulse_wrapped，时序对齐后）
  //   MUX 侧  → 外部 WL MUX（wl_data, wl_group_sel, wl_latch, wl_busy）
  //           这些信号当前接 _unused_wl_mux（未引出到 pad，后续 chip_top 集成时连接）
  wl_mux_wrapper u_wl_mux_wrapper (
    .clk               (clk),
    .rst_n             (rst_n),
    .wl_bitmap_in      (wl_bitmap),
    .wl_valid_pulse_in (wl_valid_pulse),
    .wl_bitmap_out     (wl_bitmap_wrapped),     // 时序对齐后的 bitmap → dac_ctrl
    .wl_valid_pulse_out(wl_valid_pulse_wrapped), // 时序对齐后的有效脉冲 → dac_ctrl
    .wl_data           (wl_data),               // → 外部 WL MUX（当前 _unused）
    .wl_group_sel      (wl_group_sel),           // → 外部 WL MUX（当前 _unused）
    .wl_latch          (wl_latch),               // → 外部 WL MUX（当前 _unused）
    .wl_busy           (wl_mux_busy)             // 来自外部 WL MUX（当前 _unused，用于 stall 检测）
  );

  // dac_ctrl：DAC 控制器（数字 → 模拟 WL 脉冲驱动）
  // 功能：接收 wl_bitmap_wrapped，逐位产生对应 WL 的模拟激活脉冲
  // 握手：
  //   dac_ctrl 产生 dac_valid → cim_macro 看到后拉高 dac_ready（表示已接收）→
  //   dac_ctrl 检测到 dac_ready 后发出 dac_done_pulse 通知 cim_array_ctrl
  // 注意：dac_ready 是 MUX 后信号（test mode 时为 1'b1）
  dac_ctrl u_dac (
    .clk          (clk),
    .rst_n        (rst_n),
    .wl_bitmap    (wl_bitmap_wrapped),      // 来自 wl_mux_wrapper 的 64-bit bitmap
    .wl_valid_pulse(wl_valid_pulse_wrapped), // bitmap 有效脉冲
    .wl_spike     (wl_spike),               // 输出：每 bit 对应一条 WL 的模拟脉冲驱动信号
    .dac_valid    (dac_valid),              // 输出：当前 WL spike 有效
    .dac_ready    (dac_ready),              // 输入：cim_macro 已准备好接收（MUX 后）
    .dac_done_pulse(dac_done_pulse)         // 输出：本次 DAC 操作完成（单拍）
  );

  // cim_macro_blackbox：RRAM CIM 阵列行为模型（黑盒仿真）
  // 功能：模拟 128x256 RRAM 阵列（差分结构，实际 64x20 有效计算）的推理行为
  //   - 接收 wl_spike（WL 激活信号）
  //   - 在 cim_start 后执行内积计算（权重 x 输入）
  //   - 通过 adc_start/adc_done/bl_data 串行输出 20 个 BL 列的 ADC 结果
  // 注意：这里连接的是 _hw 后缀信号（原始输出），之后由 MUX 选择 hw 还是 test
  cim_macro_blackbox u_macro (
    .clk       (clk),
    .rst_n     (rst_n),
    .wl_spike  (wl_spike),       // 来自 dac_ctrl：WL 激活位图的数字表示
    .dac_valid (dac_valid),      // 来自 dac_ctrl：spike 有效指示
    .dac_ready (dac_ready_hw),   // 输出：模型就绪（→ test mode MUX 后接 dac_ready）
    .cim_start (cim_start_pulse), // 来自 cim_array_ctrl：计算启动脉冲
    .cim_done  (cim_done_hw),    // 输出：计算完成（→ test mode MUX 后接 cim_done）
    .adc_start (adc_start),      // 来自 adc_ctrl：当前列开始采样
    .adc_done  (adc_done_hw),    // 输出：当前列采样完成（→ test mode MUX 后接 adc_done）
    .bl_sel    (bl_sel),         // 来自 adc_ctrl：当前列编号（5-bit，0-19）
    .bl_data   (bl_data_hw)      // 输出：当前列 ADC 结果（8-bit，→ test mode MUX 后接 bl_data）
  );

  // adc_ctrl：ADC 控制器（Scheme B：数字侧差分减法，20 通道 MUX 扫描）
  // 功能：
  //   1. 收到 adc_kick_pulse 后，开始逐列扫描 20 个 BL 列（差分对）
  //   2. 对每列：发出 adc_start → 等待 adc_done → 读取 bl_data（8-bit ADC）
  //   3. Scheme B：在数字侧计算 pos_col - neg_col（有符号 9-bit）
  //   4. 所有 20 列扫描完毕后，发出 neuron_in_valid + neuron_in_data[9:0][8:0]
  // 饱和监控：统计 bl_data 超过饱和门限（高/低）的次数，输出 adc_sat_high/low
  adc_ctrl u_adc (
    .clk            (clk),
    .rst_n          (rst_n),
    .adc_kick_pulse (adc_kick_pulse),   // 来自 cim_array_ctrl：开始 ADC 扫描
    .adc_start      (adc_start),        // 输出给 cim_macro_blackbox：单列采样启动
    .adc_done       (adc_done),         // 来自 MUX：单列采样完成（hw 或 test）
    .bl_sel         (bl_sel),           // 输出给 cim_macro_blackbox：当前列编号
    .bl_data        (bl_data),          // 来自 MUX：当前列 ADC 结果（hw 或 test）
    .neuron_in_valid(neuron_in_valid),  // 输出：所有列扫描完成，数据就绪
    .neuron_in_data (neuron_in_data),   // 输出：20 个 9-bit 有符号差分结果
    .adc_sat_high   (adc_sat_high),     // 输出：高饱和计数 → reg_bank
    .adc_sat_low    (adc_sat_low)       // 输出：低饱和计数 → reg_bank
  );

  // lif_neurons：LIF 神经元阵列（10 个输出神经元，对应 MNIST 10 类）
  // 功能：
  //   收到 neuron_in_valid 时，将 neuron_in_data（20x9-bit）累加到 10 个神经元的膜电位
  //   （注：20 个差分通道对应 10 个输出，每个神经元的输入是对应差分对的和）
  //   每个时间步结束后，比较膜电位与 threshold：
  //     若超过阈值 → 产生 spike，根据 reset_mode 复位膜电位（减法或归零）
  //   所有时间步完成后，找最大膜电位对应的神经元编号，push 到 output FIFO
  // 关键信号：
  //   bitplane_shift : 比特平面偏移（0~7，对应 8-bit 输入位平面）
  //   threshold      : 来自 reg_bank（32-bit 绝对阈值，默认 10200）
  //   reset_mode     : 0=减法复位（membrane -= threshold），1=归零（membrane=0）
  lif_neurons u_lif (
    .clk            (clk),
    .rst_n          (rst_n),
    .soft_reset_pulse(snn_soft_reset_pulse), // 软复位：清空所有膜电位，回到初始状态
    .neuron_in_valid(neuron_in_valid),       // adc_ctrl 产生：输入数据就绪
    .neuron_in_data (neuron_in_data),        // 20 个 9-bit 有符号差分结果（输入电流）
    .bitplane_shift (bitplane_shift),        // 比特平面偏移（来自 cim_array_ctrl）
    .threshold      (neuron_threshold),      // LIF 阈值（来自 reg_bank）
    .reset_mode     (reset_mode),            // 复位模式（来自 reg_bank）
    .out_fifo_push  (out_fifo_push),         // 推理完成时 push 分类结果
    .out_fifo_wdata (out_fifo_wdata),        // 4-bit 类别编号（0-9）
    .out_fifo_full  (out_fifo_full)          // FIFO 满时不 push（防 overflow）
  );

  //======================
  // CIM Test Mode MUX + 响应生成器
  // 设计意图：
  //   流片后硅上测试时，RRAM 宏的模拟特性可能无法立即工作（编程电压、温度等问题）。
  //   通过 cim_test_mode=1，数字侧产生 fake 延迟响应，验证数字控制 FSM 是否正常运行，
  //   而不依赖真实 RRAM 宏的行为。
  //
  // MUX 选择逻辑（纯组合）：
  //   cim_test_mode=0 → 使用 _hw 信号（真实 cim_macro_blackbox 输出）
  //   cim_test_mode=1 → 使用 _test 信号（数字侧 fake 响应）
  //
  // fake 延迟规格：
  //   CIM 延迟：cim_start_pulse 后 2 个时钟周期产生 cim_done_test 脉冲
  //     原理：test_cim_cnt 初始化为 1，每拍减 1，减到 0 时发出 done 并清 busy
  //   ADC 延迟：adc_start 后 1 个时钟周期产生 adc_done_test 脉冲
  //     原理：test_adc_cnt 初始化为 0，第一拍检测到 cnt==0 时立即发出 done 并清 busy
  //
  // 为什么 CIM 用 2 拍、ADC 用 1 拍？
  //   模拟真实 cim_macro_blackbox 行为模型的典型延迟，保证控制链路时序正确性验证
  //======================
  assign dac_ready_test = 1'b1; // 测试模式下 DAC 始终就绪（无需等待模拟 macro）

  // 根据 cim_test_mode 选择信号来源
  assign dac_ready = cim_test_mode ? dac_ready_test : dac_ready_hw; // MUX: DAC 就绪
  assign cim_done  = cim_test_mode ? cim_done_test  : cim_done_hw;  // MUX: CIM 完成
  assign adc_done  = cim_test_mode ? adc_done_test  : adc_done_hw;  // MUX: ADC 完成
  assign bl_data   = cim_test_mode ? cim_test_data   : bl_data_hw;  // MUX: BL 数据（ADC 结果）

  // CIM / ADC fake 延迟响应生成器（寄存器逻辑）
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // 复位：清空所有 fake 响应相关寄存器
      cim_done_test  <= 1'b0;
      adc_done_test  <= 1'b0;
      test_cim_cnt   <= 4'd0;
      test_cim_busy  <= 1'b0;
      test_adc_cnt   <= 4'd0;
      test_adc_busy  <= 1'b0;
    end else begin
      // 每拍默认将 done 脉冲清零（单拍脉冲）
      cim_done_test <= 1'b0;
      adc_done_test <= 1'b0;

      // ---- CIM fake 延迟：cim_start_pulse 后 2 拍产生 cim_done_test ----
      // 状态机：IDLE → BUSY（cnt=1）→ 等待 1 拍（cnt=0）→ 发出 done，回 IDLE
      if (cim_start_pulse && !test_cim_busy) begin
        // 新的 CIM 启动请求：进入 busy，倒计时从 1 开始
        test_cim_busy <= 1'b1;
        test_cim_cnt  <= 4'd1; // cnt=1 意味着还需要 1 拍到 0，共 2 拍延迟
      end else if (test_cim_busy) begin
        if (test_cim_cnt == 4'd0) begin
          // 倒计时到 0：发出 done 脉冲，退出 busy
          cim_done_test <= 1'b1;
          test_cim_busy <= 1'b0;
        end else begin
          // 继续倒计时
          test_cim_cnt <= test_cim_cnt - 4'd1;
        end
      end

      // ---- ADC fake 延迟：adc_start 后 1 拍产生 adc_done_test ----
      // 状态机：IDLE → BUSY（cnt=0）→ 立即检测到 cnt==0 发出 done，回 IDLE
      // 注意：cnt 初始值为 0，进入 busy 后的下一拍（检测 busy 分支）即发出 done
      // 因此 adc_start → adc_done_test 延迟正好是 1 个时钟周期
      if (adc_start && !test_adc_busy) begin
        // 新的 ADC 采样请求：进入 busy，cnt 置 0（下一拍立即触发 done）
        test_adc_busy <= 1'b1;
        test_adc_cnt  <= 4'd0;
      end else if (test_adc_busy) begin
        if (test_adc_cnt == 4'd0) begin
          // cnt 已为 0：发出 done 脉冲，退出 busy
          adc_done_test <= 1'b1;
          test_adc_busy <= 1'b0;
        end else begin
          test_adc_cnt <= test_adc_cnt - 4'd1;
        end
      end
    end
  end

  //======================
  // Debug 计数器（16-bit 饱和）
  // 设计规格：
  //   - 仅 rst_n 可清零（电源复位），snn_soft_reset_pulse 不清零
  //     原因：调试信息需要在多次推理之间保留，避免软复位时清除诊断数据
  //   - 饱和策略：!(&cnt) 等价于 cnt != 16'hFFFF，防止溢出回绕到 0
  //   - 各计数器独立递增，互不干扰
  //======================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // 上电复位：清零所有 debug 计数器
      dbg_dma_frame_cnt <= 16'h0;
      dbg_cim_cycle_cnt <= 16'h0;
      dbg_spike_cnt     <= 16'h0;
      dbg_wl_stall_cnt  <= 16'h0;
    end else begin
      // DMA frame count: 每次成功 push 64-bit bitmap 到 FIFO 时 +1
      // 含义：已向 SNN 送入的图像帧数（每帧 = 一张 8x8 像素图）
      if (in_fifo_push && !(&dbg_dma_frame_cnt))
        dbg_dma_frame_cnt <= dbg_dma_frame_cnt + 16'h1;

      // CIM cycle count: snn_busy 为高的每个时钟周期 +1
      // 含义：SNN 子系统处理所有图像的累计时钟周期，用于性能分析
      if (snn_busy && !(&dbg_cim_cycle_cnt))
        dbg_cim_cycle_cnt <= dbg_cim_cycle_cnt + 16'h1;

      // Spike count: 每次 LIF 向 output_fifo push 分类结果时 +1
      // 含义：已完成推理并输出分类结果的次数
      if (out_fifo_push && !(&dbg_spike_cnt))
        dbg_spike_cnt <= dbg_spike_cnt + 16'h1;

      // WL stall count: wl_valid_pulse 到来时 wl_mux 仍忙 → 协议冲突 → 计数 +1
      // 含义：WL 发送速度与 MUX 处理速度不匹配的次数，正常应为 0
      // 如果此计数器非零，说明 cim_array_ctrl 的 WL 发送时序需要调整
      if (wl_valid_pulse && wl_mux_busy && !(&dbg_wl_stall_cnt))
        dbg_wl_stall_cnt <= dbg_wl_stall_cnt + 16'h1;
    end
  end

  //======================
  // 外设 stub
  // V1 阶段这三个外设仅作为 IO 占位，内部无实际逻辑。
  // 保留接口是为了：
  //   1. 验证 pad 数量和引脚分配的正确性
  //   2. 为 V2 实现真实 UART/SPI/JTAG 提供无缝升级路径（只需替换 stub 模块）
  //   3. 防止 EDA 工具因未驱动的 IO 产生报警
  //======================

  // UART stub：uart_rx 输入忽略，uart_tx 输出恒高（空闲状态）
  // 地址范围：ADDR_UART_BASE ~ ADDR_UART_END（见 snn_soc_pkg）
  uart_stub u_uart (
    .clk       (clk),
    .rst_n     (rst_n),
    .req_valid (uart_req_valid),
    .req_write (uart_req_write),
    .req_addr  (uart_req_addr),
    .req_wdata (uart_req_wdata),
    .req_wstrb (uart_req_wstrb),
    .rdata     (uart_rdata),    // 读操作返回 0（stub 行为）
    .uart_rx   (uart_rx),
    .uart_tx   (uart_tx)
  );

  // SPI stub：spi_cs_n 恒高（片选无效），sck/mosi 恒低，miso 输入忽略
  // 地址范围：ADDR_SPI_BASE ~ ADDR_SPI_END
  spi_stub u_spi (
    .clk       (clk),
    .rst_n     (rst_n),
    .req_valid (spi_req_valid),
    .req_write (spi_req_write),
    .req_addr  (spi_req_addr),
    .req_wdata (spi_req_wdata),
    .req_wstrb (spi_req_wstrb),
    .rdata     (spi_rdata),
    .spi_cs_n  (spi_cs_n),
    .spi_sck   (spi_sck),
    .spi_mosi  (spi_mosi),
    .spi_miso  (spi_miso)
  );

  // JTAG stub：tdo 直接连 tdi（旁路，不做任何 TAP 处理）
  // 无时钟/复位端口：纯组合连接
  // V2 规划：接入 E203 的 Debug Module（DM）实现真实 JTAG 调试
  jtag_stub u_jtag (
    .jtag_tck (jtag_tck),
    .jtag_tms (jtag_tms),
    .jtag_tdi (jtag_tdi),
    .jtag_tdo (jtag_tdo)
  );
endmodule
