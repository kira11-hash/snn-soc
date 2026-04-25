// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/top/chip_top.sv
// Purpose: Tapeout-intent chip-level wrapper around snn_soc_top for pad-facing signal routing.
// Role in system: Freezes package-facing logic ports now, while keeping room for future pad cell insertion and physical constraints.
// Current status: Tapeout-intent digital wrapper; the canonical pad source of truth lives in doc/15_asic_pad_map.md.
// Scope note: This file models only signal-facing ports. Power pads and 3 ESD-reserved pads are documented, not instantiated here.
// Remaining tapeout work is pad-cell-library specific: IO cell instantiation, ESD options, drive-strength config, and final package constraints.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: chip_top.sv
// 描述: 芯片 pad 级顶层包装层（tapeout-intent 逻辑版）
//
// 【这个文件的作用】
//   在 snn_soc_top 外面再包一层"pad-facing wrapper"，负责：
//     1. 把 snn_soc_top 的 _ext 端口连到对应 pad
//     2. 为后续插入 pad cell（IO 驱动/ESD 保护）预留位置
//     3. 保证任何 pad 级改动不往 snn_soc_top 内核渗漏
//
// 【当前状态】
//   - pad 端口已冻结（端口名/方向/位宽与 doc/15_asic_pad_map.md 一致）
//   - 还没实例化工艺相关的 pad cell（这是流片前的最后一步）
//
// 【pad 预算】
//   数字芯片 1mm × 2mm，72 pad（50um pitch）
//   当前 V2 baseline：53 pad 已用（44 signal + 6 power + 3 ESD），19 pad 富余
//   权威来源：doc/15_asic_pad_map.md
//
// 【流片前待完成】（claude-fix F8：明确标记为 P&R / signoff 硬 blocker）
//   a) pad cell 实例化（替换裸 port）              ← P&R 启动前必须落地
//   b) ESD 保护 / drive strength / 电平配置收敛    ← 同 a)；流片前 STA/DRC 必过
//   c) package / pad-ring / IO 约束收敛            ← 同 a)；packaging 启动前必过
//   说明：上述 3 项不是建议项，是流片签核（DRC/LVS/STA）启动的硬前置条件；
//        在工艺 PDK / pad library 接入之前，本 wrapper 不能进 P&R。
//        跟踪文档：doc/19_phase_d_synthesis_readiness.md（如未列入需补登）。
//        本 fix 仅注释升级，不动接口/不动逻辑；alpha-passed bitstream 不变。
//======================================================================
module chip_top (
  // ── 基础时钟复位（Pad 01-02）────────────────────────────────────────
  input  logic clk_pad,       // 系统参考时钟（外部晶振，目标 50MHz）
  input  logic rst_n_pad,     // 全局复位（低有效，上电后释放）

  // ── 常规外设（Pad 03-12）───────────────────────────────────────────
  input  logic uart_rx_pad,   // UART 接收（V1 保留，未实现 RX 逻辑）
  output logic uart_tx_pad,   // UART 发送（8N1 帧格式，空闲高电平）
  output logic spi_cs_n_pad,  // SPI 片选（低有效，软件控制）
  output logic spi_sck_pad,   // SPI 时钟（Mode 0，空闲低）
  output logic spi_mosi_pad,  // SPI 主出从入
  input  logic spi_miso_pad,  // SPI 主入从出
  input  logic jtag_tck_pad,  // JTAG 测试时钟（与 sys_clk 异步）
  input  logic jtag_tms_pad,  // JTAG 模式选择
  input  logic jtag_tdi_pad,  // JTAG 数据输入
  output logic jtag_tdo_pad,  // JTAG 数据输出

  // ── 模拟芯片互联（Pad 19-50）——通过 PCB 连接外部 CIM 模拟芯片 ────
  //   V1 baseline: Pad 19-45（25 signal）
  //   V2 新增:     Pad 46-47 (bl_sel[5:6]) + Pad 48-50 (prog_en/erase_en/verify_en)
  //   Pad 51-53:   ESD reserved
  //   权威真源：doc/15_asic_pad_map.md
  output logic [7:0] wl_data_pad,       // WL 时分复用数据（8 位，接模拟 WL 锁存器）
  output logic [2:0] wl_group_sel_pad,  // WL 组选择（3 位，选择 8 组之一）
  output logic       wl_latch_pad,      // WL 锁存脉冲（上升沿锁存当前 wl_data）
  output logic       cim_start_pad,     // CIM 计算启动脉冲（触发模拟侧 MAC + ADC）
  input  logic       cim_done_pad,      // CIM 计算完成（模拟侧返回，表示 ADC 数据就绪）
  output logic [$clog2(snn_soc_pkg::MAX_BL_SCAN)-1:0] bl_sel_pad, // BL 读回通道选择（V2 扩宽至 7-bit 支持多层扫描）
  input  logic [7:0] bl_data_pad,       // BL 读回数据（8-bit ADC 结果）
  // V2 编程/擦除/验证使能（告知模拟侧当前操作模式）
  output logic       prog_en_pad,       // 编程使能（SET 操作时高）
  output logic       erase_en_pad,      // 擦除使能（RESET 操作时高）
  output logic       verify_en_pad      // 验证使能（读回时高）
);
  // ── 核心 SoC 实例化（流片目标配置） ─────────────────────────────────
  // ENABLE_E203=1          : 带 RISC-V CPU（固件执行层）
  // ENABLE_EXT_CIM_IF=1    : 数字芯片通过 pad 连接外部模拟 CIM 芯片（不是同 die）
  // ENABLE_PROGRAM_MODE=1  : 带 V2 编程控制器（CPU 可通过固件给 RRAM 编程）
  //
  // 【为什么没有 ENABLE_MULTI_LAYER？】
  //   它是 `snn_soc_pkg.sv` 里的 package 参数，不能通过 module 实例化传入。
  //   流片版默认 = 0，不带硬件 layer_sequencer。
  //   V2 时间多层由 CPU 固件逐层调 CIM_CTRL.START 实现（固件驱动），
  //   不依赖硬件自动化。layer_sequencer 路径仅在仿真回归里用
  //   `+define+SIM_MULTI_LAYER` 开关启用。
  // ────────────────────────────────────────────────────────────────────
  snn_soc_top #(
    .ENABLE_E203(1'b1),
    .ENABLE_EXT_CIM_IF(1'b1),
    .ENABLE_PROGRAM_MODE(1'b1)
  ) u_soc_core (
    .clk      (clk_pad),
    .rst_n    (rst_n_pad),
    .uart_rx  (uart_rx_pad),
    .uart_tx  (uart_tx_pad),
    .spi_cs_n (spi_cs_n_pad),
    .spi_sck  (spi_sck_pad),
    .spi_mosi (spi_mosi_pad),
    .spi_miso (spi_miso_pad),
    .jtag_tck (jtag_tck_pad),
    .jtag_tms (jtag_tms_pad),
    .jtag_tdi (jtag_tdi_pad),
    .jtag_tdo (jtag_tdo_pad),
    .wl_data_ext      (wl_data_pad),
    .wl_group_sel_ext (wl_group_sel_pad),
    .wl_latch_ext     (wl_latch_pad),
    .cim_start_ext    (cim_start_pad),
    .cim_done_ext     (cim_done_pad),
    .bl_sel_ext       (bl_sel_pad),
    .bl_data_ext      (bl_data_pad),
    .prog_en_ext      (prog_en_pad),
    .erase_en_ext     (erase_en_pad),
    .verify_en_ext    (verify_en_pad)
  );
endmodule

