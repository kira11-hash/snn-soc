`timescale 1ns/1ps
//======================================================================
// 文件名: rtl/bus/axi_lite_if.sv
// 接口名: axi_lite_if
//
// 【功能概述】
// AXI4-Lite 总线接口定义。
// 用于 E203 RISC-V CPU 与 SNN SoC 内部简单总线之间的桥接协议。
// 桥接模块：axi2simple_bridge.sv（AXI-Lite slave → bus_simple master）
//
// 【AXI4-Lite 通道说明】
// ┌──────────────────────────────────────────────────────────────────┐
// │ 写事务（Write Transaction）：                                     │
// │   AW 通道：Master 发送写地址（AWVALID/AWREADY 握手）              │
// │   W  通道：Master 发送写数据+字节使能（WVALID/WREADY 握手）       │
// │   B  通道：Slave 返回写响应（BVALID/BREADY 握手）                 │
// │                                                                  │
// │ 读事务（Read Transaction）：                                      │
// │   AR 通道：Master 发送读地址（ARVALID/ARREADY 握手）              │
// │   R  通道：Slave 返回读数据（RVALID/RREADY 握手）                 │
// └──────────────────────────────────────────────────────────────────┘
//
// 【V1 简化约定】
// - 无 burst（AXI-Lite 本身不支持 burst）
// - 无 ID（AXI-Lite 无 transaction ID）
// - AWPROT / ARPROT 在 V1 中被忽略（无访问控制）
// - 桥接层要求 AW 和 W 同时有效时才接受写事务（简化握手）
//
// 【升级路径】
// V2：E203 CPU AXI-Lite master port → 本接口 slave modport → axi2simple_bridge
//======================================================================

interface axi_lite_if (
  input logic clk,
  input logic rst_n
);

  // ── 写地址通道（Write Address Channel）─────────────────────────────────
  logic        AWVALID;  // Master 发起写地址有效
  logic        AWREADY;  // Slave 准备好接收写地址
  logic [31:0] AWADDR;   // 写目标字节地址（32-bit）
  logic [2:0]  AWPROT;   // 保护类型（V1 忽略，接 0）

  // ── 写数据通道（Write Data Channel）────────────────────────────────────
  logic        WVALID;   // Master 写数据有效
  logic        WREADY;   // Slave 准备好接收写数据
  logic [31:0] WDATA;    // 32-bit 写数据
  logic [3:0]  WSTRB;    // 字节写使能（bit[i]=1 → 写 WDATA[8i+7:8i]）

  // ── 写响应通道（Write Response Channel）────────────────────────────────
  logic        BVALID;   // Slave 写响应有效
  logic        BREADY;   // Master 准备好接收写响应
  logic [1:0]  BRESP;    // 响应码：2'b00=OKAY，2'b10=SLVERR

  // ── 读地址通道（Read Address Channel）──────────────────────────────────
  logic        ARVALID;  // Master 发起读地址有效
  logic        ARREADY;  // Slave 准备好接收读地址
  logic [31:0] ARADDR;   // 读目标字节地址（32-bit）
  logic [2:0]  ARPROT;   // 保护类型（V1 忽略，接 0）

  // ── 读数据通道（Read Data Channel）─────────────────────────────────────
  logic        RVALID;   // Slave 读数据有效
  logic        RREADY;   // Master 准备好接收读数据
  logic [31:0] RDATA;    // 32-bit 读返回数据
  logic [1:0]  RRESP;    // 响应码：2'b00=OKAY

  // ── Master modport（CPU / Testbench BFM 使用）──────────────────────────
  // Master 驱动 AW/W/AR/BREADY/RREADY，采样 AWREADY/WREADY/B/R
  modport master (
    input  clk, rst_n,
    output AWVALID, AWADDR, AWPROT,  // 写地址：master 发出
    input  AWREADY,                  // 写地址：slave 应答
    output WVALID, WDATA, WSTRB,     // 写数据：master 发出
    input  WREADY,                   // 写数据：slave 应答
    input  BVALID, BRESP,            // 写响应：slave 发出
    output BREADY,                   // 写响应：master 应答
    output ARVALID, ARADDR, ARPROT,  // 读地址：master 发出
    input  ARREADY,                  // 读地址：slave 应答
    input  RVALID, RDATA, RRESP,     // 读数据：slave 发出
    output RREADY                    // 读数据：master 应答
  );

  // ── Slave modport（axi2simple_bridge 使用）─────────────────────────────
  // Slave 采样 AW/W/AR，驱动 AWREADY/WREADY/B/R/ARREADY
  modport slave (
    input  clk, rst_n,
    input  AWVALID, AWADDR, AWPROT,
    output AWREADY,
    input  WVALID, WDATA, WSTRB,
    output WREADY,
    output BVALID, BRESP,
    input  BREADY,
    input  ARVALID, ARADDR, ARPROT,
    output ARREADY,
    output RVALID, RDATA, RRESP,
    input  RREADY
  );

endinterface
