`timescale 1ns/1ps
//======================================================================
// 文件名: rtl/top/v2b_arm_demo_top.sv
// 模块名: v2b_arm_demo_top
//
// 【本分支范围】
// `feature/v2-arm-fpga-demo` evidence branch（REV 2 plan §A 产出）。
// Vivado OOC（out-of-context）综合 sanity 顶。BD 里 Zynq PS 会调用本模块
// （或它的 IP-packaged 版本）作为 AXI-Lite slave。
//
// 本文件**只**做端口 re-expose，无额外逻辑。保持 `v2b_axi_wrapper` 的干净
// AXI4-Lite slave 面，利于 Vivado IP Packager 抽取。
//======================================================================
module v2b_arm_demo_top #(
  parameter bit P_ENABLE_TILE_BUF = 1'b1,
  parameter int P_ADC_BITS        = 10
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        s_awvalid,
  output logic        s_awready,
  input  logic [31:0] s_awaddr,
  input  logic        s_wvalid,
  output logic        s_wready,
  input  logic [31:0] s_wdata,
  input  logic [3:0]  s_wstrb,
  output logic        s_bvalid,
  input  logic        s_bready,
  output logic [1:0]  s_bresp,
  input  logic        s_arvalid,
  output logic        s_arready,
  input  logic [31:0] s_araddr,
  output logic        s_rvalid,
  input  logic        s_rready,
  output logic [31:0] s_rdata,
  output logic [1:0]  s_rresp
);

  // ── Async-assert / sync-release reset (2026-05-03 added，pre-tape-out fix) ──
  //
  //  rst_n 来自 Zynq PS（PS_RST 派生）。PS reset 网络相对干净，但为与 main
  //  路径风格一致 + best-practice，本 wrapper 也加 reset_sync。
  //  影响：u_wrapper.rst_n 比之前晚 2 个 clk 释放；功能不变；FPGA 重烧后
  //  以 fresh UART evidence 为准。详见 rtl/sys/reset_sync.sv 头注释。
  //
  //  V2 path 使用 behavioral CIM，没有 external async cim_done 信号需要 sync。
  logic rst_n_sync;
  reset_sync #(.STAGES(2)) u_reset_sync (
    .clk         (clk),
    .rst_n_async (rst_n),
    .rst_n_sync  (rst_n_sync)
  );

  v2b_axi_wrapper #(
    .P_ENABLE_TILE_BUF (P_ENABLE_TILE_BUF),
    .P_ADC_BITS        (P_ADC_BITS)
  ) u_wrapper (
    .clk        (clk),
    .rst_n      (rst_n_sync),
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
    .s_rresp    (s_rresp)
  );

endmodule
