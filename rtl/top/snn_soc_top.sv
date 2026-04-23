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
//             → [输出 FIFO] → SW 读取 spike_id 事件流并在软件侧统计分类结果
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
  parameter bit ENABLE_E203         = 1'b0,
  parameter bit ENABLE_EXT_CIM_IF   = 1'b0,
  // ENABLE_PROGRAM_MODE: 启用 CIM 编程/擦除/验证通路（2026-04-22 从 v2 移植）。
  // 默认 0：和原 main tapeout 行为完全一致（无编程控制器，推理直连 macro）。
  // =1：实例化 cim_program_ctrl + cim_macro_arbiter，并把 REG_PROG_* 寄存器路径接入。
  parameter bit ENABLE_PROGRAM_MODE = 1'b0,
  // ENABLE_PROGRAM_WEIGHT_MODEL（Q4 fix, 2026-04-22）：选择 cim_macro_blackbox
  // 行为模型——0 用 V1 popcount ADC 公式（与原 main 行为完全一致）；
  //            1 用 BRAM weight_mem + bram_weighted_sum()（编程会真正更新权重）。
  // 默认跟 ENABLE_PROGRAM_MODE 走，但显式拆开便于"只测互锁不测权重"等 ablation 场景。
  parameter bit    ENABLE_PROGRAM_WEIGHT_MODEL = ENABLE_PROGRAM_MODE,
  // INSTR_INIT_FILE: 非空时 u_instr_sram 在上电前从该路径 $readmemh 预加载。
  // 用于 feature/main-fpga-e203 FPGA flow（E203 firmware pre-init）。
  // 留空时行为与原版完全一致（现有所有回归不受影响）。
  parameter        INSTR_INIT_FILE = ""
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

  // JTAG（最小 rescue loader）
  // jtag_*：当前接入独立于 E203 vendor debug module 的 rescue TAP；
  // 仅开放 instr/data/weight SRAM 访问与 CPU 局部 reset hold。
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
  input  logic [7:0]  bl_data_ext,
  // ─── V1 外部编程协议（2026-04-24 冻结，方案 α'，7 new pads） ───
  // 跨芯片 D→A，通知模拟 die 本次 cim_start 脉冲对应什么操作；
  // 在 !prog_busy 时默认 000 (inference)，prog_busy 期间按当前编程阶段编码
  // 000 = inference  (reuse cim_start + wl_data + bl_sel 做 MAC)
  // 001 = erase_cell (按 wl_data + bl_sel 指定单 cell 擦除)
  // 010 = write      (按 wl_data + bl_sel 指定单 cell 写入，目标 prog_level 在 [3:0] 脚上)
  // 011 = verify     (按 wl_data + bl_sel 指定单 cell 读回，模拟侧把结果放 bl_data)
  // 100 = erase_full_array (忽略 wl_data，全阵列擦除)
  // 101..111 = reserved (模拟侧遇到应当作 idle 处理)
  output logic [2:0]  prog_op_ext,
  // 目标电导等级 0~15；仅在 prog_op_ext == 010 (write) 时模拟侧需读取。
  // 其它操作模拟侧应忽略该字段。
  output logic [3:0]  prog_level_ext
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
  logic        tb_bus_m_valid, tb_bus_m_write;
  logic [31:0] tb_bus_m_addr,  tb_bus_m_wdata;
  logic [3:0]  tb_bus_m_wstrb;

  logic        cpu_bus_m_valid, cpu_bus_m_write;
  logic [31:0] cpu_bus_m_addr,  cpu_bus_m_wdata;
  logic [3:0]  cpu_bus_m_wstrb;
  logic        cpu_bus_m_valid_gated;
  logic        cpu_bridge_busy;
  logic        cpu_local_rst_n;
  logic        cpu_reset_hold_req;
  logic        cpu_reset_hold_effective;
  logic        cpu_fabric_m_ready, cpu_fabric_m_rvalid;
  logic [31:0] cpu_fabric_m_rdata;

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

  logic        jtag_req_pending;
  logic        jtag_grant;
  logic        jtag_grant_q;
  logic [7:0]  jtag_wait_cnt;
  logic        jtag_timeout_force;
  logic        jtag_bus_m_valid, jtag_bus_m_write;
  logic [31:0] jtag_bus_m_addr,  jtag_bus_m_wdata;
  logic [3:0]  jtag_bus_m_wstrb;
  logic        jtag_bus_m_ready, jtag_bus_m_rvalid;
  logic [31:0] jtag_bus_m_rdata;

  wire _unused_e203 = ^cpu_inspect_pc ^ cpu_core_wfi;

  assign cpu_reset_hold_effective = cpu_reset_hold_req | jtag_timeout_force;
  assign cpu_local_rst_n          = rst_n & ~cpu_reset_hold_effective;

  assign tb_bus_m_valid = bus_if.m_valid & ~jtag_grant;
  assign tb_bus_m_write = bus_if.m_write;
  assign tb_bus_m_addr  = bus_if.m_addr;
  assign tb_bus_m_wdata = bus_if.m_wdata;
  assign tb_bus_m_wstrb = bus_if.m_wstrb;

  assign cpu_bus_m_valid_gated = cpu_bus_m_valid & ~jtag_grant & ~cpu_reset_hold_effective;

  assign fabric_m_valid = jtag_grant ? jtag_bus_m_valid :
                          (ENABLE_E203 ? cpu_bus_m_valid_gated : tb_bus_m_valid);
  assign fabric_m_write = jtag_grant ? jtag_bus_m_write :
                          (ENABLE_E203 ? cpu_bus_m_write : tb_bus_m_write);
  assign fabric_m_addr  = jtag_grant ? jtag_bus_m_addr :
                          (ENABLE_E203 ? cpu_bus_m_addr : tb_bus_m_addr);
  assign fabric_m_wdata = jtag_grant ? jtag_bus_m_wdata :
                          (ENABLE_E203 ? cpu_bus_m_wdata : tb_bus_m_wdata);
  assign fabric_m_wstrb = jtag_grant ? jtag_bus_m_wstrb :
                          (ENABLE_E203 ? cpu_bus_m_wstrb : tb_bus_m_wstrb);

  assign cpu_fabric_m_ready  = jtag_grant ? 1'b0  : fabric_m_ready;
  assign cpu_fabric_m_rvalid = jtag_grant ? 1'b0  : fabric_m_rvalid;
  assign cpu_fabric_m_rdata  = fabric_m_rdata;

  assign jtag_bus_m_ready  = jtag_grant ? fabric_m_ready  : 1'b0;
  assign jtag_bus_m_rvalid = jtag_grant ? fabric_m_rvalid : 1'b0;
  assign jtag_bus_m_rdata  = fabric_m_rdata;

  assign bus_if.m_ready  = (!ENABLE_E203 && !jtag_grant) ? fabric_m_ready  : 1'b0;
  assign bus_if.m_rdata  = (!ENABLE_E203 && !jtag_grant) ? fabric_m_rdata  : 32'h0;
  assign bus_if.m_rvalid = (!ENABLE_E203 && !jtag_grant) ? fabric_m_rvalid : 1'b0;

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
  logic [3:0]  out_fifo_rdata; // reg_bank/SW 读出的 spike_id 事件（0~9）
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

  // ----------------------------------------------------------
  // CIM 编程 / 仲裁相关信号（2026-04-22 从 v2 移植）
  //
  // prog_*  : reg_bank ↔ cim_program_ctrl 的寄存器控制/状态通道
  // arb_*   : cim_macro_arbiter 输出到 CIM 宏（推理+编程二选一后的 WL/DAC/CIM/ADC）
  // *_sig   : cim_program_ctrl 的 WL/DAC/CIM/ADC 输出（送 arbiter 编程侧）
  // *_en_sig: prog/erase/verify 使能信号（cim_program_ctrl → cim_macro_blackbox）
  //
  // ENABLE_PROGRAM_MODE=0 时：arb_* 直接透传推理信号，prog_* 全部绑 0（下面的 gen_no_prog）。
  // ----------------------------------------------------------
  // 寄存器 → 控制
  logic        prog_start_pulse, prog_erase, prog_full_array;
  logic        prog_handshake_bypass; // silicon bring-up: 绕过 prog_adc_done 握手
  logic [5:0]  prog_row;
  logic [4:0]  prog_col;
  logic [3:0]  prog_level;
  logic [2:0]  prog_retry_limit;
  logic [15:0] prog_pulse_width, prog_erase_width;
  // 控制 → 寄存器（状态回读）
  logic        prog_busy, prog_done_pulse_sig, prog_pass, prog_fail;
  logic [2:0]  prog_retry_count;

  // cim_program_ctrl 的 CIM 侧输出 → arbiter 编程端
  logic [NUM_INPUTS-1:0] prog_wl_spike;
  logic                  prog_dac_valid_sig, prog_cim_start_sig, prog_adc_start_sig;
  logic [$clog2(MAX_BL_SCAN)-1:0] prog_bl_sel_sig;
  logic                  prog_cim_done_sig, prog_adc_done_sig;
  logic [ADC_BITS-1:0]   prog_bl_data_sig;
  logic                  prog_en_sig, erase_en_sig, verify_en_sig;

  // arbiter → 宏（推理/编程二选一后的线）
  logic [NUM_INPUTS-1:0] arb_wl_spike;
  logic                  arb_dac_valid, arb_cim_start, arb_adc_start;
  logic [$clog2(MAX_BL_SCAN)-1:0] arb_bl_sel;
  logic                  arb_cim_done, arb_adc_done;
  logic [ADC_BITS-1:0]   arb_bl_data;

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
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      jtag_grant_q       <= 1'b0;
      jtag_wait_cnt      <= 8'h00;
      jtag_timeout_force <= 1'b0;
    end else begin
      if (!jtag_req_pending) begin
        jtag_grant_q       <= 1'b0;
        jtag_wait_cnt      <= 8'h00;
        jtag_timeout_force <= 1'b0;
      end else begin
        if (!jtag_grant_q && (!cpu_bridge_busy || jtag_timeout_force)) begin
          jtag_grant_q <= 1'b1;
        end

        if (!jtag_grant_q && cpu_bridge_busy && !jtag_timeout_force) begin
          if (jtag_wait_cnt == 8'hFF) begin
            jtag_timeout_force <= 1'b1;
          end else begin
            jtag_wait_cnt <= jtag_wait_cnt + 8'd1;
          end
        end else begin
          jtag_wait_cnt <= 8'h00;
        end
      end
    end
  end

  assign jtag_grant = jtag_grant_q;

  e203_min_wrap u_e203 (
    .clk              (clk),
    .rst_n            (rst_n),
    .cpu_local_rst_n  (cpu_local_rst_n),
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
    .rst_n          (cpu_local_rst_n),
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
    .m_ready        (cpu_fabric_m_ready),
    .m_rdata        (cpu_fabric_m_rdata),
    .m_rvalid       (cpu_fabric_m_rvalid),
    .busy_o         (cpu_bridge_busy)
  );

  jtag_mem_loader u_jtag_loader (
    .rst_n         (rst_n),
    .clk           (clk),
    .jtag_tck      (jtag_tck),
    .jtag_tms      (jtag_tms),
    .jtag_tdi      (jtag_tdi),
    .jtag_tdo      (jtag_tdo),
    .mem_req_pending(jtag_req_pending),
    .mem_req_grant (jtag_grant),
    .mem_m_valid   (jtag_bus_m_valid),
    .mem_m_write   (jtag_bus_m_write),
    .mem_m_addr    (jtag_bus_m_addr),
    .mem_m_wstrb   (jtag_bus_m_wstrb),
    .mem_m_wdata   (jtag_bus_m_wdata),
    .mem_m_ready   (jtag_bus_m_ready),
    .mem_m_rvalid  (jtag_bus_m_rvalid),
    .mem_m_rdata   (jtag_bus_m_rdata),
    .cpu_reset_hold(cpu_reset_hold_req)
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
  sram_simple #(.MEM_BYTES(INSTR_SRAM_BYTES), .INIT_FILE(INSTR_INIT_FILE)) u_instr_sram (
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
  // 两个同步 FIFO：input FIFO（像素 bitmap）和 output FIFO（spike_id 事件流）
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

  // 输出 FIFO：WIDTH=4（spike_id 0-9，4-bit 足够），DEPTH=OUTPUT_FIFO_DEPTH
  // 生产者：lif_neurons（每次神经元发放 spike 时 push 对应神经元编号）
  // 消费者：reg_bank（SW 读取 spike 事件流时 pop，并在软件侧统计直方图）
  fifo_sync #(.WIDTH(4), .DEPTH(OUTPUT_FIFO_DEPTH)) u_output_fifo (
    .clk       (clk),
    .rst_n     (rst_n),
    .push      (out_fifo_push),
    .push_data (out_fifo_wdata),
    .pop       (out_fifo_pop),       // reg_bank 被 SW 读取事件时产生 pop 脉冲
    .rd_data   (out_fifo_rdata),     // SW 读到的 4-bit spike_id
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
    .out_fifo_rdata (out_fifo_rdata),  // SW 读 OUT_FIFO_DATA 时返回当前队头 spike_id
    .out_fifo_count (out_fifo_count),  // 待读取的 spike 事件数量
    // ADC 饱和监控（来自 adc_ctrl，映射到可读寄存器）
    .adc_sat_high   (adc_sat_high),
    .adc_sat_low    (adc_sat_low),
    // Debug 计数器（来自顶层，映射到可读寄存器）
    .dbg_dma_frame_cnt(dbg_dma_frame_cnt),
    .dbg_cim_cycle_cnt(dbg_cim_cycle_cnt),
    .dbg_spike_cnt    (dbg_spike_cnt),
    .dbg_wl_stall_cnt (dbg_wl_stall_cnt),
    // 控制输出（SW 写 reg_bank 后产生的脉冲/电平信号）
    .neuron_threshold(neuron_threshold), // 阈值（32-bit 绝对值，完整位宽生效）
    .timesteps      (timesteps),          // 时间步数
    .reset_mode     (reset_mode),         // LIF 复位模式（0=软, 1=硬）
    .start_pulse    (snn_start_pulse),    // 推理启动脉冲（单拍）
    .soft_reset_pulse(snn_soft_reset_pulse), // 软复位脉冲（单拍）
    .cim_test_mode    (cim_test_mode),      // CIM 测试模式使能（电平）
    .cim_test_data_pos(cim_test_data_pos), // 正通道合成值（ch 0~9）
    .cim_test_data_neg(cim_test_data_neg), // 负通道合成值（ch 10~19）
    .out_fifo_pop   (out_fifo_pop),       // SW 读输出结果时触发 pop（脉冲）
    // CIM 编程寄存器（2026-04-22 移植）
    .prog_start_pulse      (prog_start_pulse),
    .prog_erase            (prog_erase),
    .prog_full_array       (prog_full_array),
    .prog_handshake_bypass (prog_handshake_bypass),
    .prog_row              (prog_row),
    .prog_col         (prog_col),
    .prog_level       (prog_level),
    .prog_retry_limit (prog_retry_limit),
    .prog_pulse_width (prog_pulse_width),
    .prog_erase_width (prog_erase_width),
    .prog_busy        (prog_busy),
    .prog_done_pulse  (prog_done_pulse_sig),
    .prog_pass        (prog_pass),
    .prog_fail        (prog_fail),
    .prog_retry_count (prog_retry_count)
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
    // During programming we feed the one-hot target-row vector (prog_wl_spike,
    // output of cim_program_ctrl via arbiter) through wl_mux_wrapper so the
    // 8×8 TDM wl_data / wl_group_sel / wl_latch pad sequence carries the
    // programming row to the analog die.  Triggered once per prog_busy
    // rising edge; the row stays constant for the entire cell program op,
    // so one TDM burst per op is sufficient.
    .wl_bitmap_in      (prog_busy ? prog_wl_spike : wl_bitmap),
    .wl_valid_pulse_in (prog_busy ? prog_busy_rise : wl_valid_pulse),
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

  // ─── External CIM pad routing for programming (2026-04-24, scheme α' follow-up) ───
  // The three shared carrier pads switch to programming sources when prog_busy=1,
  // so the external analog die sees the programming operation on the pads:
  //
  //   - bl_sel_ext: always = arb_bl_sel. The arbiter transparently forwards
  //     the inference bl_sel when prog_busy=0 and prog_bl_sel when prog_busy=1.
  //
  //   - cim_start_ext (GATE semantics, 2026-04-24 Q1 lock-in):
  //     During programming, cim_start_ext is a LEVEL-held gate that stays
  //     HIGH for the entire "analog interaction" window. The analog die
  //     applies programming voltage (write/erase) or read voltage (verify)
  //     as long as cim_start_ext=1 and withdraws it on the falling edge —
  //     no analog-side self-timing / pulse-width table lookup is required.
  //
  //     Internal gate = prog_dac_valid_sig | verify_en_sig, covering:
  //       - prog_dac_valid_sig : ST_SETUP → ST_PULSE → ST_PULSE_HOLD
  //                              (pulse-width-controlled, selected from
  //                               REG_PROG_PULSE_WIDTH preset or erase_width)
  //       - verify_en_sig      : ST_READBACK → ST_RB_WAIT
  //                              (ADC readback window)
  //     The gate is then delayed by WL_MUX_LATENCY_CYC cycles so that the
  //     wl_data / wl_group_sel / wl_latch TDM burst on the shared WL pads
  //     completes BEFORE the analog macro sees cim_start rise.
  //
  //     During inference (prog_busy=0), cim_start_ext falls back to the
  //     legacy 1-cycle strobe (cim_start_pulse passthrough) — unchanged.
  //
  //     prog_op_ext is stable within each cim_start_ext=1 window. It may
  //     change between windows (e.g. write → verify phase transitions),
  //     but the FSM guarantees the transition only happens while
  //     cim_start_ext=0, so the analog side can safely latch prog_op on
  //     the cim_start_ext rising edge.
  //
  //   - wl_mux_wrapper input bitmap: muxed to prog_wl_spike when prog_busy=1.
  //     wl_mux_wrapper encodes the 64-bit one-hot target row vector into
  //     the 8×8 TDM burst on wl_data / wl_group_sel / wl_latch pads.
  //     Retriggered once at prog_busy rising edge (row stays constant
  //     inside a single programming op, one TDM burst suffices).
  localparam int WL_MUX_LATENCY_CYC = 10;
  logic        prog_busy_q;
  logic        verify_en_sig_dly1;   // 1-cycle delayed verify_en
  logic [WL_MUX_LATENCY_CYC-1:0] prog_gate_shreg;
  // Gate-gap trick (2026-04-24 Q2 lock-in):
  //   prog_gate_active = prog_dac_valid | verify_en_dly
  //   delaying verify_en by 1 cycle forces a 1-cycle gate=0 gap when the FSM
  //   transitions from write/erase pulse (dac_valid=1, verify_en=0) to verify
  //   readback (dac_valid=0, verify_en=1→on next cycle: verify_en_dly=1).
  //   On that gap cycle, prog_op_ext switches from 010/001/100 → 011, so the
  //   analog die can safely re-latch prog_op on the subsequent cim_start_ext
  //   rising edge without risk of mid-window prog_op change.
  wire         prog_gate_active = prog_dac_valid_sig | verify_en_sig_dly1;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prog_busy_q        <= 1'b0;
      verify_en_sig_dly1 <= 1'b0;
      prog_gate_shreg    <= '0;
    end else begin
      prog_busy_q        <= prog_busy;
      verify_en_sig_dly1 <= verify_en_sig;
      prog_gate_shreg    <= {prog_gate_shreg[WL_MUX_LATENCY_CYC-2:0],
                             prog_gate_active};
    end
  end
  wire prog_busy_rise = prog_busy & ~prog_busy_q;

  assign bl_sel_ext    = arb_bl_sel;
  assign cim_start_ext = prog_busy ? prog_gate_shreg[WL_MUX_LATENCY_CYC-1]
                                   : cim_start_pulse;

  // ─── 外部编程 pad 编码器（2026-04-24 V1 方案 α' 冻结 + Q2 pipeline 对齐）────
  // ENABLE_EXT_CIM_IF=1 时生效；把数字侧内部的 prog_en/erase_en/verify_en/
  // prog_full_array 打包成 3-bit 外部 prog_op 编码。
  //
  // 编码映射（与 doc/08_cim_analog_interface.md §4 一致）：
  //   000 = inference   (prog_busy=0)
  //   001 = erase_cell
  //   010 = write       (需读 prog_level)
  //   011 = verify      (读回在 bl_data；pass/fail 由数字侧内部比对)
  //   100 = erase_full_array
  //   101~111 = reserved (模拟侧应当作 idle 处理)
  //
  // Q2 对齐（2026-04-24）：prog_op_raw / prog_level_raw 通过 WL_MUX_LATENCY_CYC
  // 级 shift register 延迟后再输出到 pad，使 pad 上的 prog_op_ext / prog_level_ext
  // 相位与 cim_start_ext 对齐。结果：
  //   · cim_start_ext 上升沿那一拍，pad 上的 prog_op_ext 对应的是 10 拍前的 FSM
  //     内部状态（即 ST_SETUP/PULSE，write 阶段），值稳定。
  //   · cim_start_ext=1 整个窗口期间，prog_op_ext 保持不变（因为内部 10 拍前
  //     的状态在那段时间内都在 write/erase pulse 阶段）。
  //   · cim_start_ext 下降沿那一拍，pad 上的 prog_op_ext 仍然是 write 值，且
  //     1-cycle gate gap 后才切换到 verify 阶段的 prog_op=011。
  // 由此模拟 die 在 cim_start_ext 上升沿 latch prog_op 就足以拿到正确编码。
  //
  // ENABLE_PROGRAM_MODE=0 的分支下 prog_busy/*_sig 都被 tie 0，raw 编码自然落到 000。
  logic [2:0] prog_op_raw;
  logic [3:0] prog_level_raw;
  assign prog_op_raw =
      (prog_busy && verify_en_sig)                         ? 3'b011 :
      (prog_busy && prog_en_sig)                           ? 3'b010 :
      (prog_busy && erase_en_sig && prog_full_array)       ? 3'b100 :
      (prog_busy && erase_en_sig && !prog_full_array)      ? 3'b001 :
      3'b000;
  assign prog_level_raw = prog_level;

  logic [2:0] prog_op_pipe    [WL_MUX_LATENCY_CYC-1:0];
  logic [3:0] prog_level_pipe [WL_MUX_LATENCY_CYC-1:0];
  integer     pp_i;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (pp_i = 0; pp_i < WL_MUX_LATENCY_CYC; pp_i = pp_i + 1) begin
        prog_op_pipe[pp_i]    <= 3'd0;
        prog_level_pipe[pp_i] <= 4'd0;
      end
    end else begin
      prog_op_pipe[0]    <= prog_op_raw;
      prog_level_pipe[0] <= prog_level_raw;
      for (pp_i = 1; pp_i < WL_MUX_LATENCY_CYC; pp_i = pp_i + 1) begin
        prog_op_pipe[pp_i]    <= prog_op_pipe[pp_i-1];
        prog_level_pipe[pp_i] <= prog_level_pipe[pp_i-1];
      end
    end
  end
  assign prog_op_ext    = prog_op_pipe   [WL_MUX_LATENCY_CYC-1];
  assign prog_level_ext = prog_level_pipe[WL_MUX_LATENCY_CYC-1];

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
      // Q4 fix (2026-04-22)：P_USE_BRAM_WEIGHTS 由独立参数
      // ENABLE_PROGRAM_WEIGHT_MODEL 控制，默认跟 ENABLE_PROGRAM_MODE 走。
      // 这样可以独立测试"互锁路径"（ENABLE_PROGRAM_MODE=1, WEIGHT_MODEL=0）
      // 或 "不开编程但用 BRAM 权重做 sample align"（MODE=0, WEIGHT_MODEL=1）。
      cim_macro_blackbox #(
        .P_USE_BRAM_WEIGHTS (ENABLE_PROGRAM_WEIGHT_MODEL)
      ) u_macro (
        .clk       (clk),
        .rst_n     (rst_n),
        .wl_spike  (arb_wl_spike),
        .dac_valid (arb_dac_valid),
        .cim_start (arb_cim_start),
        .cim_done  (cim_done_hw),
        .adc_start (arb_adc_start),
        .adc_done  (adc_done_hw),
        .bl_sel    (arb_bl_sel),
        .bl_data   (bl_data_hw),
        .prog_en   (prog_en_sig),
        .erase_en  (erase_en_sig),
        .verify_en (verify_en_sig)
      );
    end else begin : gen_external_cim_if
      wire _unused_internal_cim_macro = ^wl_spike ^ dac_valid;
      assign cim_done_hw = cim_done_ext;
      assign bl_data_hw  = bl_data_ext;
      assign adc_done_hw = ext_adc_done;
    end
  endgenerate

  // ==================================================================
  // CIM 编程控制器 + 仲裁器（gated by ENABLE_PROGRAM_MODE）
  //   =1 : 实例化 cim_program_ctrl + cim_macro_arbiter；
  //        推理侧 (wl_spike/dac_valid/cim_start_pulse/adc_start/bl_sel) 进 arbiter 的 infer 端口，
  //        编程侧 (prog_*_sig) 进 arbiter 的 prog 端口，
  //        arbiter 输出 (arb_*) 去 cim_macro_blackbox。
  //        arbiter.infer_cim_done/adc_done/bl_data 反向返回推理链路。
  //   =0 : 保持原 main 直连：arb_* <= 推理信号（旁路 arbiter），
  //        prog_* 全部 tie 0。cim_macro_blackbox.prog_en/erase_en/verify_en 也都绑 0，
  //        因此 V1 回归行为完全不变。
  // ==================================================================
  generate
    if (ENABLE_PROGRAM_MODE) begin : gen_prog_ctrl
      // ==================================================================
      // Programming-handshake bypass (silicon bring-up only)
      //
      // 当 PROG_CTRL.BYPASS_HANDSHAKE (bit[3]) = 1 时，绕开 cim_program_ctrl
      // 对 prog_adc_done / prog_bl_data 的等待，让 FSM 在**没有模拟 die**
      // 的情况下也能把编程序列跑完（verify 始终返回 PASS）。
      //
      // BYPASS_HANDSHAKE / erase / level 在 prog_start_pulse 时锁存，保证
      // 软件在 busy 期间误改 PROG_CTRL 不会改变本次 in-flight 操作。
      //
      // 造假策略：
      //   - prog_adc_start_sig 脉冲后，经寄存器路径产生 prog_adc_done_fake
      //     单拍；cim_program_ctrl 在 RB_WAIT 稳定采样到对应 bl_data。
      //   - prog_bl_data_fake = latched_erase ? 0 : latched_level * 16
      //     （落在 cim_program_ctrl ST_VERIFY 的 target_level ±2 窗口内）
      //
      // 注：prog_cim_done 在当前 FSM 设计里不被使用（自计时），无需 MUX。
      //
      // tape-out 后若数字 die 单独上电、模拟 die 未接，CPU 写 PROG_CTRL 置 1
      // 此位即可完整验证编程 FSM 的状态转移而不挂死。
      // ==================================================================
      logic                prog_adc_done_fake;
      logic                prog_adc_fake_busy;
      logic [ADC_BITS-1:0] prog_bl_data_fake;
      logic                prog_handshake_bypass_active;
      logic                prog_bypass_op_erase;
      logic [3:0]          prog_bypass_target_level;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          prog_adc_done_fake <= 1'b0;
          prog_adc_fake_busy <= 1'b0;
          prog_bl_data_fake  <= '0;
          prog_handshake_bypass_active <= 1'b0;
          prog_bypass_op_erase         <= 1'b0;
          prog_bypass_target_level     <= 4'd0;
        end else begin
          prog_adc_done_fake <= 1'b0;

          if (prog_start_pulse) begin
            prog_handshake_bypass_active <= prog_handshake_bypass;
            prog_bypass_op_erase         <= prog_erase;
            prog_bypass_target_level     <= prog_level;
          end else if (prog_done_pulse_sig) begin
            prog_handshake_bypass_active <= 1'b0;
          end

          if (prog_handshake_bypass_active && prog_adc_start_sig && !prog_adc_fake_busy) begin
            prog_adc_fake_busy <= 1'b1;
            // 落在 ST_VERIFY 窗口中心：
            //   erase: readback ≤ 1 → 用 0
            //   write: readback 在 target_level*16 ± 2 → 用 target_level*16
            prog_bl_data_fake  <= prog_bypass_op_erase ? ADC_BITS'(0)
                                             : ADC_BITS'({4'b0, prog_bypass_target_level} * 8'd16);
          end else if (prog_adc_fake_busy) begin
            prog_adc_done_fake <= 1'b1;
            prog_adc_fake_busy <= 1'b0;
          end
        end
      end

      // MUX: bypass 生效时用 fake 信号驱动 cim_program_ctrl
      wire                 prog_adc_done_effective =
          prog_handshake_bypass_active ? prog_adc_done_fake : prog_adc_done_sig;
      wire [ADC_BITS-1:0]  prog_bl_data_effective =
          prog_handshake_bypass_active ? prog_bl_data_fake  : prog_bl_data_sig;

      cim_program_ctrl u_prog_ctrl (
        .clk              (clk),
        .rst_n            (rst_n),
        .prog_start       (prog_start_pulse),
        .prog_erase       (prog_erase),
        .prog_full_array  (prog_full_array),
        .prog_row         (prog_row),
        .prog_col         (prog_col),
        .prog_level       (prog_level),
        .prog_retry_limit (prog_retry_limit),
        .prog_pulse_width (prog_pulse_width),
        .prog_erase_width (prog_erase_width),
        .prog_busy        (prog_busy),
        .prog_done_pulse  (prog_done_pulse_sig),
        .prog_pass        (prog_pass),
        .prog_fail        (prog_fail),
        .prog_retry_count (prog_retry_count),
        .prog_wl_spike    (prog_wl_spike),
        .prog_dac_valid   (prog_dac_valid_sig),
        .prog_cim_start   (prog_cim_start_sig),
        .prog_cim_done    (prog_cim_done_sig),
        .prog_adc_start   (prog_adc_start_sig),
        .prog_adc_done    (prog_adc_done_effective),  // bypass MUX
        .prog_bl_sel      (prog_bl_sel_sig),
        .prog_bl_data     (prog_bl_data_effective),   // bypass MUX
        .prog_en          (prog_en_sig),
        .erase_en         (erase_en_sig),
        .verify_en        (verify_en_sig)
      );

      cim_macro_arbiter u_arb (
        .clk              (clk),
        .rst_n            (rst_n),
        .prog_busy        (prog_busy),
        // 推理侧输入（从 dac_ctrl/cim_array_ctrl/adc_ctrl 拿推理通路）
        .infer_wl_spike   (wl_spike),
        .infer_dac_valid  (dac_valid),
        .infer_cim_start  (cim_start_pulse),
        .infer_adc_start  (adc_start),
        .infer_bl_sel     (bl_sel),
        .infer_cim_done   (arb_cim_done),
        .infer_adc_done   (arb_adc_done),
        .infer_bl_data    (arb_bl_data),
        // 编程侧输入（cim_program_ctrl 输出）
        .prog_wl_spike    (prog_wl_spike),
        .prog_dac_valid   (prog_dac_valid_sig),
        .prog_cim_start   (prog_cim_start_sig),
        .prog_adc_start   (prog_adc_start_sig),
        .prog_bl_sel      (prog_bl_sel_sig),
        .prog_cim_done    (prog_cim_done_sig),
        .prog_adc_done    (prog_adc_done_sig),
        .prog_bl_data     (prog_bl_data_sig),
        // 宏侧输出
        .macro_wl_spike   (arb_wl_spike),
        .macro_dac_valid  (arb_dac_valid),
        .macro_cim_start  (arb_cim_start),
        .macro_adc_start  (arb_adc_start),
        .macro_bl_sel     (arb_bl_sel),
        .macro_cim_done   (cim_done_hw),
        .macro_adc_done   (adc_done_hw),
        .macro_bl_data    (bl_data_hw)
      );
    end else begin : gen_no_prog
      // 推理直连（no arbiter）
      assign arb_wl_spike  = wl_spike;
      assign arb_dac_valid = dac_valid;
      assign arb_cim_start = cim_start_pulse;
      assign arb_adc_start = adc_start;
      assign arb_bl_sel    = bl_sel;
      assign arb_cim_done  = cim_done_hw;
      assign arb_adc_done  = adc_done_hw;
      assign arb_bl_data   = bl_data_hw;
      // 编程状态 tie-off
      assign prog_busy           = 1'b0;
      assign prog_done_pulse_sig = 1'b0;
      assign prog_pass           = 1'b0;
      assign prog_fail           = 1'b0;
      assign prog_retry_count    = 3'd0;
      // 编程使能信号 tie-off（cim_macro_blackbox 端口还在，但永不触发写/擦除）
      assign prog_en_sig         = 1'b0;
      assign erase_en_sig        = 1'b0;
      assign verify_en_sig       = 1'b0;
      // 编程 macro 侧信号不使用，tie off 避免 lint
      assign prog_wl_spike       = '0;
      assign prog_dac_valid_sig  = 1'b0;
      assign prog_cim_start_sig  = 1'b0;
      assign prog_adc_start_sig  = 1'b0;
      assign prog_bl_sel_sig     = '0;
      assign prog_cim_done_sig   = 1'b0;
      assign prog_adc_done_sig   = 1'b0;
      assign prog_bl_data_sig    = '0;
      // 消除未用输入 lint 告警
      wire _unused_prog_inputs = &{1'b0, prog_start_pulse, prog_erase, prog_full_array,
                                   prog_handshake_bypass,
                                   ^prog_row, ^prog_col, ^prog_level, ^prog_retry_limit,
                                   ^prog_pulse_width, ^prog_erase_width};
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
    .out_fifo_push  (out_fifo_push),         // 每次产生 spike 时 push 神经元编号
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
  //
  // 【2026-04-22 MAIN-01 审查修复】cim_done/adc_done/bl_data 的 MUX 源从 `*_hw`
  // 改为 `arb_*`（arbiter 的 infer-side 输出），让 arbiter 的对称屏蔽真正生效：
  //   - ENABLE_PROGRAM_MODE=0：gen_no_prog 中 `arb_* = *_hw` 直连，行为与此前完全等价
  //   - ENABLE_PROGRAM_MODE=1：arbiter 在 prog_busy=1 时把推理侧 done/data 屏蔽为 0，
  //                            防止编程期间 macro 的脉冲被误当成推理完成
  //                            （代价：推理 done/data 多 1 拍延迟，但 cim_array_ctrl
  //                             只需要等 done，不依赖精确 start→done 延迟）
  assign cim_done  = cim_test_mode ? cim_done_test  : arb_cim_done;  // MUX: CIM 完成
  assign adc_done  = cim_test_mode ? adc_done_test  : arb_adc_done;  // MUX: ADC 完成
  // BL 数据 MUX：test mode 下按通道号分发 pos/neg 合成值
  //   bl_sel < NUM_OUTPUTS(10) → 正通道（ch 0~9）  → 返回 cim_test_data_pos
  //   bl_sel >= NUM_OUTPUTS    → 负通道（ch 10~19） → 返回 cim_test_data_neg
  // 令 pos≠neg（如 pos=100, neg=0）时，Scheme B 差分 = 100，LIF 膜电位可积累 spike
  assign bl_data   = cim_test_mode ?
      (bl_sel < $bits(bl_sel)'(NUM_OUTPUTS) ? cim_test_data_pos : cim_test_data_neg) :
      arb_bl_data;

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
  // 外设模块（UART / SPI 已实现；JTAG 为 rescue loader）
  //
  // 当前阶段 UART 已接入 TX 控制器，SPI 已接入最小可用 Master；
  // JTAG 提供最小救援路径，不依赖 OpenOCD/GDB 或 vendor Debug Module。
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

  // JTAG rescue loader：
  // - 4-wire TAP
  // - MEMACC 仅访问三块 SRAM
  // - CPUCTL 只控制 CPU 核与 CPU bridge 的局部 reset hold
  // - 保留 jtag_stub.sv 文件仅用于历史兼容，不再作为主路径
endmodule
