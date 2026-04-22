`timescale 1ns/1ps
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
