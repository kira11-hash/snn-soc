// -----------------------------------------------------------------------------
// 自动文档头：本文件的可读性说明（仅注释说明，不改变任何逻辑）
// 文件路径：rtl/top/snn_soc_top.sv
// 作用：这是数字 SoC 的主顶层，把总线、寄存器、存储、DMA、SNN 数据通路和占位外设接成一个完整系统。
// 系统角色：它是当前 MVP 仿真与后续综合使用的“内部数字顶层”，之后再由 chip_top 包上 pad 环。
// 行为概览：本文件主要做三件事：
//   1. 实例化所有子模块；
//   2. 把寄存器控制信号接到数据通路；
//   3. 把与模拟侧相关的 CIM / DAC / ADC 接口统一汇总出来。
// 阅读重点：如果要排查功能问题，优先看模块之间的连线关系、状态信号流向和读写寄存器入口。
// 设计原则：顶层尽量保持“接线图式”的显式风格，方便后续接入 E203 / AXI / pad 集成时少改动。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: snn_soc_top.sv
// 描述: SNN SoC 顶层。
//       - 实例化总线、SRAM、寄存器、DMA、FIFO、SNN 子系统与外设占位模块
//       - 当前总线主设备由 Testbench 通过 dut.bus_if 直接驱动
//======================================================================
//
// ============================================================
// 模块总览
// ============================================================
// snn_soc_top 是整个数字 SoC 的内部顶层封装（不含 pad 环）。
// 如果把整个工程看成一台机器，这个文件就是“总装配图”：
//   - 左边是总线和寄存器控制面；
//   - 中间是 SRAM / DMA / FIFO 等数据搬运通路；
//   - 右边是 SNN 推理主链路和面向模拟侧的接口。
//
// 建议阅读顺序：
//   1. 先看下面这张模块总图，建立“谁连谁”的整体感；
//   2. 再看 Reg Bank + FIFO Regs，理解软件如何控制系统；
//   3. 再看 SNN 子系统，理解一次推理如何流动；
//   4. 最后看 CIM Test Mode 和 Debug 计数器，理解调试抓手。
//
// 它把所有子模块“粘”在一起，形成完整的推理系统：
//
//  [Testbench / 外部 Master]
//         │ bus_if (简化总线接口)
//         ▼
//   bus_interconnect         ← 地址译码 + 从设备路由
//    ├── instr_sram           ← 指令 SRAM（供 E203 使用，MVP 阶段备用）
//    ├── data_sram (双端口)   ← 输入像素数据存放，DMA 读端口复用
//    ├── weight_sram          ← 预留 SRAM 窗口（当前主推理路径不从此窗口取数）
//    ├── reg_bank             ← 控制/状态寄存器组（启动、阈值、测试模式等）
//    ├── dma_engine           ← 从 data_sram 读像素，打包后 push 到 input FIFO
//    ├── uart_ctrl            ← UART TX 控制器（V1：TX only，RX 占位）
//    ├── spi_ctrl             ← SPI Master 控制器（V1：Mode 0，软件控 CS）
//    └── fifo_regs            ← FIFO 状态只读寄存器（供 SW 轮询）
//
//  [输入 FIFO] → cim_array_ctrl (FSM 主控) → wl_mux_wrapper → dac_ctrl
//             → cim_macro_blackbox (RRAM 仿真行为模型)
//             → adc_ctrl (Scheme B：数字差分减法，20 通道 MUX)
//             → lif_neurons (有符号膜电位 LIF，输出 spike)
//             → [输出 FIFO] → SW 读取分类结果
//
//  CIM Test Mode（cim_test_mode=1）：
//    旁路 cim_macro_blackbox 的所有输出，由数字侧产生伪造延迟响应，
//    目的是在模拟宏尚不可用时，先验证数字控制链是否通畅。
//
//  Debug 计数器（只随 rst_n 清零，不随 snn_soft_reset_pulse 清零）：
//    dbg_dma_frame_cnt  ← DMA 向 FIFO push 的帧数
//    dbg_cim_cycle_cnt  ← SNN 处于 busy 状态的总周期数
//    dbg_spike_cnt      ← LIF 向输出 FIFO push 的 spike 次数
//    dbg_wl_stall_cnt   ← wl_valid_pulse 到来时 wl_mux_busy 冲突次数
// ============================================================

module snn_soc_top #(
  parameter bit ENABLE_E203      = 1'b0,
  parameter bit ENABLE_EXT_CIM_IF = 1'b0
) (
  // ----------------------------------------------------------
  // 全局时钟与异步低有效复位
  // clk  : 系统主时钟，所有寄存器均在上升沿采样
  // rst_n: 异步低有效复位，所有 always_ff 均使用 negedge rst_n 异步释放
  // ----------------------------------------------------------
  input  logic        clk,
  input  logic        rst_n,

  // UART（V1：TX 已实现，RX 仍占位）
  // uart_tx 由 uart_ctrl 产生标准 8N1 发送波形，默认空闲高电平；
  // uart_rx 端口已引出，但当前 V1 主线暂未实现接收路径。
  input  logic        uart_rx,
  output logic        uart_tx,

  // SPI Master（V1：Mode 0，8-bit 全双工，软件控 CS）
  // spi_*：由 spi_ctrl 产生；空闲时 CS_n=1、SCK=0、MOSI=0。
  // 当前版本已支持基础 RDID / READ 访问，Mode 3 留到后续版本扩展。
  output logic        spi_cs_n,
  output logic        spi_sck,
  output logic        spi_mosi,
  input  logic        spi_miso,

  // JTAG（占位实现）
  // jtag_*：当前 jtag_stub 固定输出 tdo=0，不实现 TAP/旁路逻辑；
  // 后续如接入 E203 Debug Module，可在这里替换。
  input  logic        jtag_tck,
  input  logic        jtag_tms,
  input  logic        jtag_tdi,
  output logic        jtag_tdo,

  // Optional external CIM interface for chip_top / tapeout path.
  output logic [7:0]  wl_data_ext,
  output logic [2:0]  wl_group_sel_ext,
  output logic        wl_latch_ext,
  output logic        cim_start_ext,
  input  logic        cim_done_ext,
  output logic [4:0]  bl_sel_ext,
  input  logic [7:0]  bl_data_ext
);
  // 导入 snn_soc_pkg 中的全局参数与地址常量
  // 例如：NUM_INPUTS=64, ADC_BITS=8, ADC_CHANNELS=20, NEURON_DATA_WIDTH=9 等
  import snn_soc_pkg::*;

  // ----------------------------------------------------------
  // 简化总线接口（当前由 Testbench 通过层级引用驱动）
  // bus_simple_if 是一个 interface，可把它看成“主设备访问 SoC 的门口”。
  // 里面封装了 m_valid / m_write / m_addr / m_wdata / m_wstrb /
  // m_ready / m_rdata / m_rvalid 等总线信号。
  // MVP 阶段没有真实 CPU，总线事务由 Testbench 直接驱动这些信号来模拟。
  // ----------------------------------------------------------
  bus_simple_if bus_if(.clk(clk));

  logic        fabric_m_valid, fabric_m_write;
  logic [31:0] fabric_m_addr,  fabric_m_wdata;
  logic [3:0]  fabric_m_wstrb;
  logic        fabric_m_ready, fabric_m_rvalid;
  logic [31:0] fabric_m_rdata;

  logic        cpu_bus_m_valid, cpu_bus_m_write;
  logic [31:0] cpu_bus_m_addr,  cpu_bus_m_wdata;
  logic [3:0]  cpu_bus_m_wstrb;

  logic        cpu_mem_icb_cmd_valid;
  logic        cpu_mem_icb_cmd_ready;
  logic [31:0] cpu_mem_icb_cmd_addr;
  logic        cpu_mem_icb_cmd_read;
  logic [31:0] cpu_mem_icb_cmd_wdata;
  logic [3:0]  cpu_mem_icb_cmd_wmask;
  logic        cpu_mem_icb_rsp_valid;
  logic        cpu_mem_icb_rsp_ready;
  logic        cpu_mem_icb_rsp_err;
  logic [31:0] cpu_mem_icb_rsp_rdata;
  logic [31:0] cpu_inspect_pc;
  logic        cpu_core_wfi;

  wire _unused_e203 = ^cpu_inspect_pc ^ cpu_core_wfi;

  assign fabric_m_valid = ENABLE_E203 ? cpu_bus_m_valid : bus_if.m_valid;
  assign fabric_m_write = ENABLE_E203 ? cpu_bus_m_write : bus_if.m_write;
  assign fabric_m_addr  = ENABLE_E203 ? cpu_bus_m_addr  : bus_if.m_addr;
  assign fabric_m_wdata = ENABLE_E203 ? cpu_bus_m_wdata : bus_if.m_wdata;
  assign fabric_m_wstrb = ENABLE_E203 ? cpu_bus_m_wstrb : bus_if.m_wstrb;

  assign bus_if.m_ready  = ENABLE_E203 ? 1'b0  : fabric_m_ready;
  assign bus_if.m_rdata  = ENABLE_E203 ? 32'h0 : fabric_m_rdata;
  assign bus_if.m_rvalid = ENABLE_E203 ? 1'b0  : fabric_m_rvalid;

  // ----------------------------------------------------------
  // bus_interconnect → 各从设备的连接信号组
  // 可以把这些信号理解成“总线互联发给每个模块的专属小接口”。
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

  // 数据 SRAM 接口：存放输入 bit-plane 数据，当前正式主链路由 DMA 从这里读取
  // 使用 sram_simple_dp（双端口）：bus 侧端口 + DMA 专用只读端口
  logic        data_req_valid,  data_req_write;
  logic [31:0] data_req_addr,   data_req_wdata;
  logic [3:0]  data_req_wstrb;
  logic [31:0] data_rdata;

  // weight_sram 接口：保留总线窗口，当前主链路不从此窗口取数；
  // 实际权重仍以阵列内 program / 后续扩展方案为准
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

  // UART 控制器接口（当前 main 已接入 uart_ctrl；TX 可用，RX V1 占位）
  logic        uart_req_valid, uart_req_write;
  logic [31:0] uart_req_addr,  uart_req_wdata;
  logic [3:0]  uart_req_wstrb;
  logic [31:0] uart_rdata;

  // SPI 控制器接口（当前 main 已接入 spi_ctrl；V1 为 Mode 0，软件控 CS）
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
  // 宽度 = NUM_INPUTS = 64 位，每一位对应一个输入通道在当前 bit-plane 上的值。
  // 生产者是 DMA，消费者是 cim_array_ctrl。
  // ----------------------------------------------------------
  logic        in_fifo_push, in_fifo_pop;
  logic [NUM_INPUTS-1:0] in_fifo_wdata; // DMA 写入的 64 位输入位图
  logic [NUM_INPUTS-1:0] in_fifo_rdata; // cim_array_ctrl 读出的 64 位输入位图
  logic        in_fifo_empty, in_fifo_full;
  logic        in_fifo_overflow, in_fifo_underflow;  // 错误标志（接 _unused 以抑制 lint）
  logic [$clog2(INPUT_FIFO_DEPTH+1)-1:0] in_fifo_count; // 当前 FIFO 中的有效条目数

  // ----------------------------------------------------------
  // 输出 FIFO 连接信号
  // 宽度 = 4 位 = $clog2(NUM_OUTPUTS=10) 上取整，存放输出类别编号（0~9）。
  // 生产者是 lif_neurons，消费者是 reg_bank / 软件读寄存器动作。
  // ----------------------------------------------------------
  logic        out_fifo_push, out_fifo_pop;
  logic [3:0]  out_fifo_wdata; // LIF 写入的 4-bit 类别标签
  logic [3:0]  out_fifo_rdata; // reg_bank/SW 读出的分类结果
  logic        out_fifo_empty, out_fifo_full;
  logic        out_fifo_overflow, out_fifo_underflow; // 错误标志（接 _unused 以抑制 lint）
  logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] out_fifo_count;

  // ----------------------------------------------------------
  // lint 抑制：将当前未使用的信号 XOR 到一根 wire，避免 EDA 工具报“未使用”警告
  // reg_resp_read_pulse / reg_resp_addr: bus_interconnect 产生，当前版本 reg_bank 未使用
  // in_fifo_overflow/underflow, out_fifo_overflow/underflow: 错误检测信号，
  //   功能仿真中暂不处理（可在 TB assertion 中检查）
  // ----------------------------------------------------------
  wire _unused_top = reg_resp_read_pulse ^ &reg_resp_addr ^
                     in_fifo_overflow ^ in_fifo_underflow ^
                     out_fifo_overflow ^ out_fifo_underflow;

  // ----------------------------------------------------------
  // DMA 与 data_sram 之间的专用只读通路
  // ----------------------------------------------------------
  logic        dma_rd_en;
  logic [31:0] dma_rd_addr;
  logic [31:0] dma_rd_data;

  // ----------------------------------------------------------
  // DMA → weight_sram 写通路（DST_WEIGHT_BUF）
  // DMA → instr_sram 写通路（DST_INSTR_SRAM）
  // ----------------------------------------------------------
  logic        weight_wr_en;
  logic [31:0] weight_wr_addr;
  logic [31:0] weight_wr_data;
  logic [3:0]  weight_wr_strb;

  logic        instr_wr_en;
  logic [31:0] instr_wr_addr;
  logic [31:0] instr_wr_data;
  logic [3:0]  instr_wr_strb;

  // ----------------------------------------------------------
  // SNN 子系统内部连接信号
  // 如果只想抓主线，可以先记住下面这条链：
  //   输入 FIFO → WL/DAC → CIM → ADC → LIF → 输出 FIFO
  // 更细的信号流向如下：
  //   cim_array_ctrl → (wl_bitmap, wl_valid_pulse)
  //     → wl_mux_wrapper → (wl_bitmap_wrapped, wl_valid_pulse_wrapped)
  //       → dac_ctrl → (wl_spike, dac_valid) → cim_macro_blackbox
  // ----------------------------------------------------------

  // wl_bitmap       : 64 位 WL 激活位图（来自 input FIFO，1=该行被激活）
  // wl_valid_pulse  : wl_bitmap 有效脉冲（单拍，cim_array_ctrl 产生）
  logic [NUM_INPUTS-1:0] wl_bitmap;
  logic                  wl_valid_pulse;

  // wl_bitmap_wrapped / wl_valid_pulse_wrapped：
  //   这是经过 wl_mux_wrapper 整理后的版本，主要目的是做时序对齐。
  //   wl_mux_wrapper 会把 64 位 bitmap 分成 8 组、每组 8 位，按时间顺序送出，
  //   从而在引脚有限的情况下驱动 64 条有效字线。
  logic [NUM_INPUTS-1:0] wl_bitmap_wrapped;
  logic                  wl_valid_pulse_wrapped;

  // WL 复用协议信号（已通过 _ext 端口连到 chip_top pad，ENABLE_EXT_CIM_IF=1 时有效）
  // wl_data     : 当前分组的 8-bit WL 数据
  // wl_group_sel: 当前选中的组编号（3-bit，0-7）
  // wl_latch    : WL MUX 锁存使能脉冲
  // wl_mux_busy : WL MUX 当前正在发送（忙标志），cim_array_ctrl 需等待其就绪
  logic [WL_GROUP_WIDTH-1:0] wl_data;
  logic [$clog2(WL_GROUP_COUNT)-1:0] wl_group_sel;
  logic                               wl_latch;
  logic                               wl_mux_busy;

  // wl_spike：dac_ctrl 产生的数字侧 WL 脉冲控制向量（每 bit 对应一条 WL）
  logic [NUM_INPUTS-1:0] wl_spike;

  // DAC 信号
  // dac_valid      : dac_ctrl 发出单拍脉冲，通知 cim_macro 行为模型锁存 wl_spike
  //                  （真实芯片侧由 wl_latch 时序控制，无需 dac_ready 握手）
  // dac_done_pulse : dac_ctrl 完成本次 WL 行激活的完成脉冲（单拍）
  logic                  dac_valid;
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
  // neuron_in_data : 10 路 Scheme B 差分结果（20 通道两两配对后），每路 9-bit 有符号数
  //   维度：[NUM_OUTPUTS-1:0][NEURON_DATA_WIDTH-1:0] = [9:0][8:0]
  //   注意：NUM_OUTPUTS=10（分类数），NEURON_DATA_WIDTH=9（含符号位）
  logic                  neuron_in_valid;
  logic [NUM_OUTPUTS-1:0][NEURON_DATA_WIDTH-1:0] neuron_in_data;

  // 来自 reg_bank 的控制寄存器 / 状态信号
  // 这些信号是“软件可见寄存器”和“SNN 主链路”之间的桥。
  // neuron_threshold: LIF 膜电位阈值（32-bit，默认 THRESHOLD_DEFAULT=2550）
  // timesteps       : 推理时间步数（8-bit，工程默认 10）
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

  // WL MUX 协议信号已通过 wl_data_ext / wl_group_sel_ext / wl_latch_ext
  // 连接到 chip_top pad（ENABLE_EXT_CIM_IF=1 时有效）。
  // wl_mux_busy 供 dbg_wl_stall_cnt 使用。

  // ----------------------------------------------------------
  // ADC 饱和监控（adc_ctrl → reg_bank）
  // adc_sat_high: 单次推理期间高饱和次数（16-bit 饱和计数器）
  // adc_sat_low : 单次推理期间低饱和次数（16-bit 饱和计数器）
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
  // cim_test_mode     : reg_bank 中的测试使能位（SW 写入）
  // cim_test_data_pos : 正通道（ch 0~9）合成 ADC 值（8-bit，SW 写入）
  // cim_test_data_neg : 负通道（ch 10~19）合成 ADC 值（8-bit，SW 写入）
  //   → 令 pos≠neg（如 pos=100, neg=0），Scheme B 差分非零，LIF 可积累 spike
  //   → 这是流片后数字自检的关键：无需真实 RRAM，也能验证 LIF+输出 FIFO 全链路
  //
  // _hw 后缀：cim_macro_blackbox 的原始输出（test mode MUX 之前）
  // _test 后缀：数字侧产生的 fake 延迟响应
  // 无后缀（cim_done/adc_done/bl_data）：MUX 后信号，是实际连接到控制链路的
  // 注：dac_ready 已移除（2026-02-27），模拟侧采用固定时序，无需握手回路
  // ----------------------------------------------------------
  logic                cim_test_mode;
  logic [ADC_BITS-1:0] cim_test_data_pos;
  logic [ADC_BITS-1:0] cim_test_data_neg;
  // 硬件侧（cim_macro_blackbox 原始输出，test mode MUX 前）
  logic                cim_done_hw;
  logic                adc_done_hw;
  logic [ADC_BITS-1:0] bl_data_hw;
  logic                ext_adc_done;
  logic                ext_adc_busy;
  logic [$clog2((ADC_SAMPLE_CYCLES > 0) ? (ADC_SAMPLE_CYCLES + 1) : 2)-1:0] ext_adc_cnt;
  // 测试侧响应信号
  // cim_done_test : test mode 下由计数器产生的 2 拍延迟 done 脉冲
  // adc_done_test : test mode 下由计数器产生的 1 拍延迟 done 脉冲
  // test_cim_cnt  : CIM fake 延迟倒计时计数器（4-bit，初值=1，即 2 拍延迟）
  // test_cim_busy : CIM fake 延迟进行中标志
  // test_adc_cnt  : ADC fake 延迟倒计时计数器（4-bit，初值=0，即 1 拍延迟）
  // test_adc_busy : ADC fake 延迟进行中标志
  logic                cim_done_test;
  logic                adc_done_test;
  logic [3:0]          test_cim_cnt;
  logic                test_cim_busy;
  logic [3:0]          test_adc_cnt;
  logic                test_adc_busy;

  generate
    if (!ENABLE_EXT_CIM_IF) begin : gen_unused_external_cim_if
      wire _unused_external_cim_if = cim_done_ext ^ ^bl_data_ext ^ ext_adc_done;
    end
  endgenerate

  // ----------------------------------------------------------
  // Debug 计数器（16 位饱和计数，仅 rst_n 清零）
  // 它们的作用不是参与功能，而是给软件提供“运行仪表盘”。
  // 这些计数器不受 snn_soft_reset_pulse 影响，避免软复位时丢失诊断信息。
  // 饱和策略：到达 0xFFFF 后保持不再递增（!(&cnt) 表示“还没全 1”）。
  // ----------------------------------------------------------
  logic [15:0] dbg_dma_frame_cnt;  // DMA 向 input FIFO 成功 push 的次数（每次 = 一帧 64-bit bitmap）
  logic [15:0] dbg_cim_cycle_cnt;  // SNN 处于 busy 状态的累计时钟周期数
  logic [15:0] dbg_spike_cnt;      // LIF 向 output FIFO push spike 的次数（每次 = 一个推理结果）
  logic [15:0] dbg_wl_stall_cnt;   // wl_valid_pulse 到来时 wl_mux 仍忙的冲突次数（协议违规计数）

  //======================
  // 总线互联
  // bus_interconnect 是 1-master N-slave 的简化总线结构。
  // 可以把它理解成“前台总机”：
  //   - 看地址，决定这次请求该送去哪个从设备；
  //   - 把读回来的数据再转发回主设备。
  // 当前采用固定 1-cycle 响应模型：主设备发起请求后，下一拍收到响应。
  //======================
  e203_min_wrap u_e203 (
    .clk              (clk),
    .rst_n            (rst_n),
    .inspect_pc       (cpu_inspect_pc),
    .core_wfi         (cpu_core_wfi),
    .mem_icb_cmd_valid(cpu_mem_icb_cmd_valid),
    .mem_icb_cmd_ready(cpu_mem_icb_cmd_ready),
    .mem_icb_cmd_addr (cpu_mem_icb_cmd_addr),
    .mem_icb_cmd_read (cpu_mem_icb_cmd_read),
    .mem_icb_cmd_wdata(cpu_mem_icb_cmd_wdata),
    .mem_icb_cmd_wmask(cpu_mem_icb_cmd_wmask),
    .mem_icb_rsp_valid(cpu_mem_icb_rsp_valid),
    .mem_icb_rsp_ready(cpu_mem_icb_rsp_ready),
    .mem_icb_rsp_err  (cpu_mem_icb_rsp_err),
    .mem_icb_rsp_rdata(cpu_mem_icb_rsp_rdata)
  );

  icb2simple_bridge u_icb2simple (
    .clk            (clk),
    .rst_n          (rst_n),
    .i_icb_cmd_valid(cpu_mem_icb_cmd_valid),
    .i_icb_cmd_ready(cpu_mem_icb_cmd_ready),
    .i_icb_cmd_addr (cpu_mem_icb_cmd_addr),
    .i_icb_cmd_read (cpu_mem_icb_cmd_read),
    .i_icb_cmd_wdata(cpu_mem_icb_cmd_wdata),
    .i_icb_cmd_wmask(cpu_mem_icb_cmd_wmask),
    .i_icb_rsp_valid(cpu_mem_icb_rsp_valid),
    .i_icb_rsp_ready(cpu_mem_icb_rsp_ready),
    .i_icb_rsp_err  (cpu_mem_icb_rsp_err),
    .i_icb_rsp_rdata(cpu_mem_icb_rsp_rdata),
    .m_valid        (cpu_bus_m_valid),
    .m_write        (cpu_bus_m_write),
    .m_addr         (cpu_bus_m_addr),
    .m_wdata        (cpu_bus_m_wdata),
    .m_wstrb        (cpu_bus_m_wstrb),
    .m_ready        (fabric_m_ready),
    .m_rdata        (fabric_m_rdata),
    .m_rvalid       (fabric_m_rvalid)
  );

  bus_interconnect u_bus_interconnect (
    .clk            (clk),
    .rst_n          (rst_n),

    // 主设备侧：默认由 Testbench bus_if 驱动；ENABLE_E203=1 时切换到 E203 bridge
    .m_valid        (fabric_m_valid),
    .m_write        (fabric_m_write),
    .m_addr         (fabric_m_addr),
    .m_wdata        (fabric_m_wdata),
    .m_wstrb        (fabric_m_wstrb),
    .m_ready        (fabric_m_ready),
    .m_rdata        (fabric_m_rdata),
    .m_rvalid       (fabric_m_rvalid),

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
  // 新增 DMA 写端口：dma_engine 使用 DST_INSTR_SRAM 时直接写入
  sram_simple #(.MEM_BYTES(INSTR_SRAM_BYTES)) u_instr_sram (
    .clk         (clk),
    .rst_n       (rst_n),
    .req_valid   (instr_req_valid),
    .req_write   (instr_req_write),
    .req_addr    (instr_req_addr),
    .req_wdata   (instr_req_wdata),
    .req_wstrb   (instr_req_wstrb),
    .rdata       (instr_rdata),
    // DMA 写端口
    .dma_wr_en   (instr_wr_en),
    .dma_wr_addr (instr_wr_addr),
    .dma_wr_data (instr_wr_data),
    .dma_wr_strb (instr_wr_strb)
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
  // 新增 DMA 写端口：dma_engine 使用 DST_WEIGHT_BUF 时直接写入
  sram_simple #(.MEM_BYTES(WEIGHT_SRAM_BYTES)) u_weight_sram (
    .clk         (clk),
    .rst_n       (rst_n),
    .req_valid   (weight_req_valid),
    .req_write   (weight_req_write),
    .req_addr    (weight_req_addr),
    .req_wdata   (weight_req_wdata),
    .req_wstrb   (weight_req_wstrb),
    .rdata       (weight_rdata),
    // DMA 写端口
    .dma_wr_en   (weight_wr_en),
    .dma_wr_addr (weight_wr_addr),
    .dma_wr_data (weight_wr_data),
    .dma_wr_strb (weight_wr_strb)
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
    .clk          (clk),
    .rst_n        (rst_n),
    // 总线寄存器访问（SW 配置 DMA）
    .req_valid    (dma_req_valid),
    .req_write    (dma_req_write),
    .req_addr     (dma_req_addr),
    .req_wdata    (dma_req_wdata),
    .req_wstrb    (dma_req_wstrb),
    .rdata        (dma_rdata),
    // data_sram 端口 B（DMA 专用只读，所有目标共用源）
    .dma_rd_en    (dma_rd_en),
    .dma_rd_addr  (dma_rd_addr),
    .dma_rd_data  (dma_rd_data),
    // input FIFO 写接口（DST_INPUT_FIFO）
    .in_fifo_push (in_fifo_push),
    .in_fifo_wdata(in_fifo_wdata),
    .in_fifo_full (in_fifo_full),
    // weight_sram DMA 写接口（DST_WEIGHT_BUF）
    .weight_wr_en  (weight_wr_en),
    .weight_wr_addr(weight_wr_addr),
    .weight_wr_data(weight_wr_data),
    .weight_wr_strb(weight_wr_strb),
    // instr_sram DMA 写接口（DST_INSTR_SRAM）
    .instr_wr_en   (instr_wr_en),
    .instr_wr_addr (instr_wr_addr),
    .instr_wr_data (instr_wr_data),
    .instr_wr_strb (instr_wr_strb)
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
  //
  // 如果你是从“软件如何控制 SoC”这个角度读顶层，
  // 这里是最值得先看的入口。
  //
  // reg_bank：主控制台
  //   - 存放阈值、timesteps、reset_mode 等配置；
  //   - 接收 SW 发来的 start / soft_reset / test_mode 等控制；
  //   - 把 snn_busy / snn_done / ADC 饱和计数 / debug 计数器映射成可读寄存器。
  //
  // fifo_regs：轻量级状态面板
  //   - 只提供 FIFO 的 count / empty / full 等状态；
  //   - 与 reg_bank 分离，主要是为了地址分区清晰、接口更简单。
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
    .cim_test_mode    (cim_test_mode),      // CIM 测试模式使能（电平）
    .cim_test_data_pos(cim_test_data_pos), // 正通道合成值（ch 0~9）
    .cim_test_data_neg(cim_test_data_neg), // 负通道合成值（ch 10~19）
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
  //
  // 这里是整个项目最核心的数据通路。
  // 一次推理的本质，就是把输入 FIFO 里的位图依次送过：
  //   WL 控制 → DAC → CIM 宏 → ADC 扫描 → LIF 神经元 → 输出 FIFO
  //
  // 下表给的是“单个时间步”的典型节奏示意：
  //   周期 0 : SW 写 START → snn_start_pulse 脉冲
  //   周期 1 : cim_array_ctrl 从 input FIFO pop 64-bit bitmap，置 snn_busy
  //   周期 2 : cim_array_ctrl 发出 wl_bitmap + wl_valid_pulse
  //   周期 3 : wl_mux_wrapper 转发（可能多拍用于时分复用）
  //   周期 4 : dac_ctrl 将 bitmap 转为模拟脉冲，发出 dac_valid
  //   周期 5 : cim_macro_blackbox 接收 spike，发出 cim_done（模拟/fake 延迟）
  //   周期 6 : cim_array_ctrl 发出 adc_kick_pulse → adc_ctrl 开始 20 路扫描
  //   周期 7~26: adc_ctrl 逐列扫描（每列: adc_start → adc_done → 采样 bl_data）
  //   周期 27: adc_ctrl 发出 neuron_in_valid + neuron_in_data[9:0]（10 个 9-bit 差分结果）
  //   周期 28: lif_neurons 更新膜电位，判断阈值，push spike 到 output FIFO
  //   周期 29: cim_array_ctrl 完成当前时间步；若达到 timesteps 则发出 snn_done_pulse
  //======================

  // cim_array_ctrl：SNN 主控 FSM
  // 它相当于“流程调度器”，负责决定系统当前该做哪一步。
  // 状态：ST_IDLE → ST_FETCH（pop FIFO）→ ST_DAC → ST_CIM → ST_ADC → ST_INC → ST_DONE
  // 关注点：
  //   - 它不做具体模拟计算；
  //   - 它负责在正确时刻触发 DAC / CIM / ADC 三段流程；
  //   - 它也负责维护 busy / done / timestep_counter 等全局状态。
  cim_array_ctrl u_cim_ctrl (
    .clk             (clk),
    .rst_n           (rst_n),
    .soft_reset_pulse(snn_soft_reset_pulse), // SW 软复位：FSM 回到 IDLE，不清 debug 计数器
    .start_pulse     (snn_start_pulse),      // SW 启动推理（单拍触发）
    .timesteps       (timesteps),            // 时间步总数（当前工程默认 10，可寄存器配置）
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
    .bitplane_shift  (bitplane_shift)        // 当前比特平面偏移（每帧从 7→0 循环，用于 LIF 加权累加）
  );

  // wl_mux_wrapper：WL 字线时分复用包装器
  // 它解决的问题是：“内部有 64 条 WL，但封装引脚不够，不能 64 根全并行拉出去。”
  // 做法是把 64 位 wl_bitmap 分成 8 组，每组 8 位，按时间顺序送到外部 WL MUX。
  // 因此它的本质不是改数据内容，而是把“并行位图”改成“时分复用协议”。
  // WL MUX 协议信号已通过 wl_*_ext 端口连到 chip_top pad（ENABLE_EXT_CIM_IF=1 时有效）。
  wl_mux_wrapper u_wl_mux_wrapper (
    .clk               (clk),
    .rst_n             (rst_n),
    .wl_bitmap_in      (wl_bitmap),
    .wl_valid_pulse_in (wl_valid_pulse),
    .wl_bitmap_out     (wl_bitmap_wrapped),     // 时序对齐后的 bitmap → dac_ctrl
    .wl_valid_pulse_out(wl_valid_pulse_wrapped), // 时序对齐后的有效脉冲 → dac_ctrl
    .wl_data           (wl_data),               // → chip_top pad (wl_data_ext)
    .wl_group_sel      (wl_group_sel),           // → chip_top pad (wl_group_sel_ext)
    .wl_latch          (wl_latch),               // → chip_top pad (wl_latch_ext)
    .wl_busy           (wl_mux_busy)             // 来自外部 WL MUX（供 dbg_wl_stall_cnt 使用）
  );

  assign wl_data_ext      = wl_data;
  assign wl_group_sel_ext = wl_group_sel;
  assign wl_latch_ext     = wl_latch;
  assign cim_start_ext    = cim_start_pulse;
  assign bl_sel_ext       = bl_sel;

  // dac_ctrl：DAC 控制器（数字 → 模拟 WL 脉冲驱动）
  // 它把“数字位图何时有效”翻译成“模拟侧何时应认为 WL 已经建立完毕”。
  // 功能上可理解为：
  //   1. 锁存 wl_bitmap_wrapped；
  //   2. 产生 wl_spike；
  //   3. 等待固定 DAC 延迟后，给后级一个完成脉冲。
  // 当前采用固定时序，不依赖外部握手。
  dac_ctrl u_dac (
    .clk          (clk),
    .rst_n        (rst_n),
    .wl_bitmap    (wl_bitmap_wrapped),      // 来自 wl_mux_wrapper 的 64-bit bitmap
    .wl_valid_pulse(wl_valid_pulse_wrapped), // bitmap 有效脉冲
    .wl_spike     (wl_spike),               // 输出：每 bit 对应一条 WL 的模拟脉冲驱动信号
    .dac_valid    (dac_valid),              // 输出：单拍脉冲，通知行为模型锁存 wl_spike
    .dac_done_pulse(dac_done_pulse)         // 输出：本次 DAC 操作完成（单拍）
  );

  // cim_macro_blackbox：RRAM CIM 阵列行为模型（黑盒仿真）
  // 你可以把它先理解成“模拟宏的行为代理人”。
  // 它负责在仿真里给出 CIM 完成信号和 BL 采样结果，使数字链路能闭环运行。
  // 注意：这里先接的是 _hw 后缀信号，后面 test mode 会再决定最终使用真实模型还是假响应。
  generate
    if (!ENABLE_EXT_CIM_IF) begin : gen_internal_cim_macro
      cim_macro_blackbox u_macro (
        .clk       (clk),
        .rst_n     (rst_n),
        .wl_spike  (wl_spike),
        .dac_valid (dac_valid),
        .cim_start (cim_start_pulse),
        .cim_done  (cim_done_hw),
        .adc_start (adc_start),
        .adc_done  (adc_done_hw),
        .bl_sel    (bl_sel),
        .bl_data   (bl_data_hw)
      );
    end else begin : gen_external_cim_if
      wire _unused_internal_cim_macro = ^wl_spike ^ dac_valid;
      assign cim_done_hw = cim_done_ext;
      assign bl_data_hw  = bl_data_ext;
      assign adc_done_hw = ext_adc_done;
    end
  endgenerate

  // adc_ctrl：ADC 控制器（Scheme B：数字侧差分减法，20 通道 MUX 扫描）
  // 这是“把 CIM 输出变成神经元输入”的关键模块。
  // 功能可拆成四步：
  //   1. 收到 adc_kick_pulse 后，开始逐列扫描 20 个 BL 列；
  //   2. 每列执行一次 adc_start → adc_done → 采样 bl_data；
  //   3. 前 10 列和后 10 列做 Scheme B 差分，得到 10 路有符号结果；
  //   4. 发出 neuron_in_valid，通知 lif_neurons 本轮输入已就绪。
  // 同时它还统计单次推理中的 ADC 饱和次数，供软件读取诊断。
  adc_ctrl u_adc (
    .clk            (clk),
    .rst_n          (rst_n),
    .sat_count_clear_pulse(snn_start_pulse), // 新推理开始时清零 ADC 饱和累计值
    .adc_kick_pulse (adc_kick_pulse),   // 来自 cim_array_ctrl：开始 ADC 扫描
    .adc_start      (adc_start),        // 输出给 cim_macro_blackbox：单列采样启动
    .adc_done       (adc_done),         // 来自 MUX：单列采样完成（hw 或 test）
    .bl_sel         (bl_sel),           // 输出给 cim_macro_blackbox：当前列编号
    .bl_data        (bl_data),          // 来自 MUX：当前列 ADC 结果（hw 或 test）
    .neuron_in_valid(neuron_in_valid),  // 输出：所有列扫描完成，数据就绪
    .neuron_in_data (neuron_in_data),   // 输出：10 个 9-bit 有符号差分结果
    .adc_sat_high   (adc_sat_high),     // 输出：高饱和计数 → reg_bank
    .adc_sat_low    (adc_sat_low)       // 输出：低饱和计数 → reg_bank
  );

  // lif_neurons：LIF 神经元阵列（10 个输出神经元，对应 MNIST 10 类）
  // 功能：
  //   收到 neuron_in_valid 时，将 neuron_in_data（10x9-bit，已完成 Scheme B 差分）累加到 10 个神经元膜电位
  //   每个子时间步结束后，比较膜电位与 threshold：
  //     若超过阈值 → 产生 spike，根据 reset_mode 复位膜电位（减法或归零）
  //   每次 spike 事件都会把神经元编号 push 到 output FIFO（事件流输出）
  // 关键信号：
  //   bitplane_shift : 比特平面偏移（0~7，对应 8-bit 输入位平面）
  //   threshold      : 来自 reg_bank（32-bit 绝对阈值，默认 2550）
  //   reset_mode     : 0=减法复位（membrane -= threshold），1=归零（membrane=0）
  lif_neurons u_lif (
    .clk            (clk),
    .rst_n          (rst_n),
    .soft_reset_pulse(snn_soft_reset_pulse), // 软复位：清空所有膜电位，回到初始状态
    .neuron_in_valid(neuron_in_valid),       // adc_ctrl 产生：输入数据就绪
    .neuron_in_data (neuron_in_data),        // 10 个 9-bit 有符号差分结果（输入电流）
    .bitplane_shift (bitplane_shift),        // 比特平面偏移（来自 cim_array_ctrl）
    .threshold      (neuron_threshold),      // LIF 阈值（来自 reg_bank）
    .reset_mode     (reset_mode),            // 复位模式（来自 reg_bank）
    .out_fifo_push  (out_fifo_push),         // 推理完成时 push 分类结果
    .out_fifo_wdata (out_fifo_wdata),        // 4-bit 类别编号（0-9）
    .out_fifo_full  (out_fifo_full)          // FIFO 满时不 push（防 overflow）
  );

  //======================
  // CIM Test Mode MUX + 响应生成器
  //
  // 这是“数字链路自检模式”的核心。
  // 设计意图是：即使真实 RRAM 宏暂时不可用，也要能先把数字控制链跑通。
  //
  // 工作方式：
  //   - cim_test_mode=0：走真实行为模型输出（_hw 信号）
  //   - cim_test_mode=1：走数字侧伪造输出（_test 信号）
  //
  // 伪造响应并不是随便给，而是故意保留一个简化但合理的延迟：
  //   - CIM：cim_start_pulse 后 2 拍给 done
  //   - ADC：adc_start 后 1 拍给 done
  // 这样做的目的，是让上游 FSM 和下游时序关系仍然接受真实流程检验。
  //
  // 注：dac_ready MUX 已移除（2026-02-27），dac_ctrl 当前不再依赖外部握手。
  //======================

  // 根据 cim_test_mode 选择信号来源
  assign cim_done  = cim_test_mode ? cim_done_test  : cim_done_hw;  // MUX: CIM 完成
  assign adc_done  = cim_test_mode ? adc_done_test  : adc_done_hw;  // MUX: ADC 完成
  // BL 数据 MUX：test mode 下按通道号分发 pos/neg 合成值
  //   bl_sel < NUM_OUTPUTS(10) → 正通道（ch 0~9）  → 返回 cim_test_data_pos
  //   bl_sel >= NUM_OUTPUTS    → 负通道（ch 10~19） → 返回 cim_test_data_neg
  // 令 pos≠neg（如 pos=100, neg=0）时，Scheme B 差分 = 100，LIF 膜电位可积累 spike
  assign bl_data   = cim_test_mode ?
      (bl_sel < $bits(bl_sel)'(NUM_OUTPUTS) ? cim_test_data_pos : cim_test_data_neg) :
      bl_data_hw;

  // CIM / ADC 假响应延迟生成器（寄存器逻辑）
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

  // External analog-chip path does not return per-channel adc_done over pads.
  // For tapeout intent, synthesize a local fixed-delay done pulse after adc_start.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ext_adc_done <= 1'b0;
      ext_adc_busy <= 1'b0;
      ext_adc_cnt  <= '0;
    end else begin
      ext_adc_done <= 1'b0;
      if (ENABLE_EXT_CIM_IF && !cim_test_mode) begin
        if (adc_start && !ext_adc_busy) begin
          ext_adc_busy <= 1'b1;
          ext_adc_cnt  <= (ADC_SAMPLE_CYCLES > 0) ? ADC_SAMPLE_CYCLES[$bits(ext_adc_cnt)-1:0] : 'd1;
        end else if (ext_adc_busy) begin
          if (ext_adc_cnt == 'd1) begin
            ext_adc_done <= 1'b1;
            ext_adc_busy <= 1'b0;
          end else begin
            ext_adc_cnt <= ext_adc_cnt - 'd1;
          end
        end
      end else begin
        ext_adc_busy <= 1'b0;
        ext_adc_cnt  <= '0;
      end
    end
  end

  //======================
  // Debug 计数器（16 位饱和）
  //
  // 这部分可以看成系统运行时的“黑匣子统计器”。
  // 它们不参与功能决策，只负责记录关键事件，便于 bring-up 和性能观察。
  //
  // 设计规格：
  //   - 仅 rst_n 可清零，snn_soft_reset_pulse 不清零；
  //   - 采用饱和计数，不允许回绕到 0；
  //   - 各计数器独立递增，互不影响。
  //======================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // 上电复位：清零所有 debug 计数器
      dbg_dma_frame_cnt <= 16'h0;
      dbg_cim_cycle_cnt <= 16'h0;
      dbg_spike_cnt     <= 16'h0;
      dbg_wl_stall_cnt  <= 16'h0;
    end else begin
      // DMA frame count：每次成功 push 一份 64 位输入位图到 FIFO 时 +1
      // 它回答的问题是：“DMA 实际向 SNN 喂了多少份输入？”
      if (in_fifo_push && !(&dbg_dma_frame_cnt))
        dbg_dma_frame_cnt <= dbg_dma_frame_cnt + 16'h1;

      // CIM cycle count：snn_busy 为高的每个时钟周期 +1
      // 它回答的问题是：“SNN 总共忙了多少个时钟周期？”
      if (snn_busy && !(&dbg_cim_cycle_cnt))
        dbg_cim_cycle_cnt <= dbg_cim_cycle_cnt + 16'h1;

      // Spike count：每次 LIF 向 output_fifo push 一次结果事件时 +1
      // 它回答的问题是：“输出侧一共产生了多少个 spike / 结果事件？”
      if (out_fifo_push && !(&dbg_spike_cnt))
        dbg_spike_cnt <= dbg_spike_cnt + 16'h1;

      // WL stall count：wl_valid_pulse 到来时 wl_mux 仍忙 → 记一次冲突
      // 正常情况下它应当为 0；如果非零，说明 WL 发送时序需要重新检查。
      if (wl_valid_pulse && wl_mux_busy && !(&dbg_wl_stall_cnt))
        dbg_wl_stall_cnt <= dbg_wl_stall_cnt + 16'h1;
    end
  end

  //======================
  // 外设模块（UART / SPI 已实现；JTAG 仍为占位）
  //
  // 当前阶段 UART 已接入 TX 控制器，SPI 已接入最小可用 Master；JTAG 仍主要用于“保留接口位置”。
  // 保留它们有三个目的：
  //   1. 尽早冻结 pad 数量和引脚分配；
  //   2. 给后续真实外设接入留出稳定接口；
  //   3. 避免顶层 IO 悬空导致 EDA 报警。
  //======================

  // UART TX 控制器（V1：8N1，TX only，RX 占位）
  // 地址范围：ADDR_UART_BASE ~ ADDR_UART_END（见 snn_soc_pkg）
  uart_ctrl u_uart (
    .clk       (clk),
    .rst_n     (rst_n),
    .req_valid (uart_req_valid),
    .req_write (uart_req_write),
    .req_addr  (uart_req_addr),
    .req_wdata (uart_req_wdata),
    .req_wstrb (uart_req_wstrb),
    .rdata     (uart_rdata),    // STATUS[0]=tx_busy, CTRL[15:0]=baud_div
    .uart_rx   (uart_rx),
    .uart_tx   (uart_tx)
  );

  // SPI Master 控制器（V1：Mode 0，8-bit 全双工，软件控 CS）
  // 地址范围：ADDR_SPI_BASE ~ ADDR_SPI_END
  spi_ctrl u_spi (
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

  // JTAG stub：固定输出 tdo=0，不做任何 TAP/旁路处理
  // 无时钟/复位状态机：仅占位并吸收未用输入
  // V2 规划：接入 E203 的 Debug Module（DM）实现真实 JTAG 调试
  jtag_stub u_jtag (
    .jtag_tck (jtag_tck),
    .jtag_tms (jtag_tms),
    .jtag_tdi (jtag_tdi),
    .jtag_tdo (jtag_tdo)
  );
endmodule
