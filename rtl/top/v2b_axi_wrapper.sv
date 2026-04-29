`timescale 1ns/1ps
// =============================================================================
// 【面试讲解 cheat sheet · v2b_axi_wrapper.sv】 —— 设计者视角
//
// 一、它解决什么问题
//   ZCU102 PS 端 Cortex-A53 走 HPM0_FPD 出来的是 AXI4-Lite。但我的 V2.B
//   accelerator (snn_soc_v2b_top) 内部用的是更简单的 simple_bus（cmd/
//   rsp，1-cycle 响应）。这个 wrapper 就是"协议转换头"——把 PS 的 AXI4-
//   Lite 主端转成 V2.B 的 simple_bus 从端，并把所有 AXI 子通道（AW/W/B/
//   AR/R）的 ready/valid 握手在内部消化掉。
//
//   为什么不直接把 V2.B 改成 AXI4-Lite 从端？
//   答案：解耦。simple_bus 是我自己定的 1-cycle 协议，仿真 / Icarus / 各
//   种 unit TB 都用它，回归集庞大；如果直接接 AXI，所有 TB 都得重写。把
//   "AXI ↔ simple ↔ v2b cmd" 三层分离后，每层都能独立 TB 验，bug 也更好
//   定位（出错时先看 axi2simple，再看 simple2v2btop_adapter，最后看 v2b
//   top 自身）。
//
// 二、面试最容易被深问的 2 个点
//   1) AXI4-Lite 5 通道 + 握手 vs simple_bus 单通道：怎么 wrap？
//      AXI 写需要 AW + W + B 三通道独立 valid/ready 握手，且不规定 AW/W
//      到达顺序；读需要 AR + R 两通道。simple_bus 写一拍完成（cmd_valid +
//      cmd_write + addr/data/wstrb 全在同拍发出），读两拍（cmd 后等
//      rsp_valid）。axi2simple_bridge 的 5-state FSM 把 AW/W 并发到达 →
//      暂存 → 等齐了再送 simple cmd → 等 simple rsp → 给 AXI B/R 响应。
//      关键 trade-off：吞吐降到 2 cycle/transfer（vs AXI 自己流水化最快
//      可以背靠背）；但 ARM HPM0 通常带宽要求很低（MMIO 配置而非 burst
//      数据搬运），换来内核协议的极简，是合算的。
//
//   2) 为什么把 wrapper 的 AXI 端口拆 "AW/W/B/AR/R 5 个通道平铺信号"
//      而不是 SystemVerilog interface？
//      Vivado Block Design 集成时，HDL 模块端口必须是 flat（or 标准
//      SmartConnect interface block），interface 端口 BD 不直接认。所以
//      我在外层暴露 flat 信号，内部 axi2simple_bridge 也用 flat——避免
//      综合器端口推断错误，也方便 Vivado IP packager / xilinx adapter 自
//      动绑定 AXI4-Lite 协议。这是 ASIC 工程师转 FPGA 工程经常踩的坑：
//      纯 RTL 仿真用 interface 很方便，BD 集成必须 flat。
//
// 三、关键设计指标
//   - AXI 时钟域 = PL fabric 50 MHz；与 V2.B 同时钟域。
//   - 写吞吐：2 cycle/transfer（含 simple_bus 一拍）。
//   - 读吞吐：3 cycle/transfer（cmd → rsp_valid 1 拍 + AXI R 通道 1 拍）。
//   - 不支持 AXI burst（4-Lite 协议本身就不支持），所以 firmware 必须用
//     单笔写实现 streaming，足够 V2.B MMIO 配置场景。
//
// 四、Corner case
//   - 窗口外地址由内层 axi2simple_bridge.addr_mapped() 返回 DECERR
//     (s_bresp=2'b11 / s_rresp=2'b11)。AXI master 收到 DECERR 后行为由
//     master 决定（通常异常）。
//   - WSTRB byte mask 必须穿透到 v2b_top 内部（cmd_wstrb 透传）——这是
//     F1 修复的根因。如果在这层 wrapper 里直接 wstrb 全 1 写下去，下面
//     v2b_top 也无法做 byte gate 了。所以 wrapper 不做 wstrb 化简，原样
//     透传。
// =============================================================================

//======================================================================
// 文件名: rtl/top/v2b_axi_wrapper.sv
// 模块名: v2b_axi_wrapper
//
// 【本分支范围】
// 新增于 `feature/v2-arm-fpga-demo`（REV 2 plan §D2）。
// 不修改 `snn_soc_v2b_top` 的 cmd/rsp 合约，只在外层打包。
//
// 【功能概述】
// 把 `snn_soc_v2b_top`（自定义 cmd/rsp 简易总线）包装成 **AXI4-Lite slave**，
// 供 ZCU102 Cortex-A53 PS 经 Zynq UltraScale+ HPM0_FPD 窗口直接 MMIO 访问。
// 内部三段：
//   (1) axi2simple_bridge.sv  — AXI4-Lite slave → bus_simple_if master
//                               （既有模块，回归已覆盖；本分支零改动）
//   (2) simple2v2btop_adapter.sv — bus_simple_if master → v2b_top cmd/rsp slave
//                               （新增，4-state FSM，支持 SBA/SBB +2-cycle read）
//   (3) snn_soc_v2b_top       — V2.B accelerator（零改动）
//
// 【address space contract】
// AXI-Lite master 访问 `ADDR_V2B_BASE..ADDR_V2B_END`（REV 2 proposed
// 0xA000_0000..0xA000_0FFF，Vivado BD Address Editor 最终决定）。窗口外
// 地址由 axi2simple_bridge.addr_mapped() 返回 DECERR。
//
// 【参数透传】
// 完全透传到 snn_soc_v2b_top：`P_ENABLE_TILE_BUF=1`, `P_ADC_BITS=10`。
//======================================================================
module v2b_axi_wrapper #(
  parameter bit P_ENABLE_TILE_BUF = 1'b1,
  parameter int P_ADC_BITS        = 10
) (
  input  logic        clk,
  input  logic        rst_n,

  // ── AXI4-Lite Slave（与 axi2simple_bridge 的端口一一对应，平铺信号）────
  // 写地址通道
  input  logic        s_awvalid,
  output logic        s_awready,
  input  logic [31:0] s_awaddr,
  // 写数据通道
  input  logic        s_wvalid,
  output logic        s_wready,
  input  logic [31:0] s_wdata,
  input  logic [3:0]  s_wstrb,
  // 写响应通道
  output logic        s_bvalid,
  input  logic        s_bready,
  output logic [1:0]  s_bresp,
  // 读地址通道
  input  logic        s_arvalid,
  output logic        s_arready,
  input  logic [31:0] s_araddr,
  // 读数据通道
  output logic        s_rvalid,
  input  logic        s_rready,
  output logic [31:0] s_rdata,
  output logic [1:0]  s_rresp
);

  // ── 内部 bus_simple 线（bridge → adapter）────────────────────────────
  logic        m_valid;
  logic        m_write;
  logic [31:0] m_addr;
  logic [31:0] m_wdata;
  logic [3:0]  m_wstrb;
  logic        m_ready;
  logic [31:0] m_rdata;
  logic        m_rvalid;

  // ── 内部 v2b_top cmd/rsp 线（adapter → v2b_top）──────────────────────
  logic        cmd_valid;
  logic        cmd_ready;
  logic [11:0] cmd_addr;
  logic        cmd_write;
  logic [31:0] cmd_wdata;
  logic [3:0]  cmd_wstrb;
  logic        rsp_valid;
  logic [31:0] rsp_rdata;

  // ── (1) AXI-Lite → bus_simple 桥（既有，不改动）────────────────────
  axi2simple_bridge u_bridge (
    .clk        (clk),
    .rst_n      (rst_n),
    // AXI-Lite slave
    .s_awvalid  (s_awvalid),
    .s_awready  (s_awready),
    .s_awaddr   (s_awaddr),
    .s_wvalid   (s_wvalid),
    .s_wready   (s_wready),
    .s_wdata    (s_wdata),
    .s_wstrb    (s_wstrb),
    .s_bvalid   (s_bvalid),
    .s_bready   (s_bready),
    .s_bresp    (s_bresp),
    .s_arvalid  (s_arvalid),
    .s_arready  (s_arready),
    .s_araddr   (s_araddr),
    .s_rvalid   (s_rvalid),
    .s_rready   (s_rready),
    .s_rdata    (s_rdata),
    .s_rresp    (s_rresp),
    // bus_simple master
    .m_valid    (m_valid),
    .m_write    (m_write),
    .m_addr     (m_addr),
    .m_wdata    (m_wdata),
    .m_wstrb    (m_wstrb),
    .m_ready    (m_ready),
    .m_rdata    (m_rdata),
    .m_rvalid   (m_rvalid)
  );

  // ── (2) bus_simple → v2b_top cmd/rsp 适配（本分支新增）───────────────
  simple2v2btop_adapter u_adp (
    .clk        (clk),
    .rst_n      (rst_n),
    .m_valid    (m_valid),
    .m_write    (m_write),
    .m_addr     (m_addr),
    .m_wdata    (m_wdata),
    .m_wstrb    (m_wstrb),
    .m_ready    (m_ready),
    .m_rdata    (m_rdata),
    .m_rvalid   (m_rvalid),
    .cmd_valid  (cmd_valid),
    .cmd_write  (cmd_write),
    .cmd_addr   (cmd_addr),
    .cmd_wdata  (cmd_wdata),
    .cmd_wstrb  (cmd_wstrb),
    .cmd_ready  (cmd_ready),
    .rsp_valid  (rsp_valid),
    .rsp_rdata  (rsp_rdata)
  );

  // ── (3) V2.B accelerator（零改动） ──────────────────────────────────
  snn_soc_v2b_top #(
    .P_ENABLE_TILE_BUF (P_ENABLE_TILE_BUF),
    .P_ADC_BITS        (P_ADC_BITS)
  ) u_v2b (
    .clk        (clk),
    .rst_n      (rst_n),
    .cmd_valid  (cmd_valid),
    .cmd_ready  (cmd_ready),
    .cmd_addr   (cmd_addr),
    .cmd_write  (cmd_write),
    .cmd_wdata  (cmd_wdata),
    .cmd_wstrb  (cmd_wstrb),
    .rsp_valid  (rsp_valid),
    .rsp_rdata  (rsp_rdata)
  );

endmodule
