// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/bus/bus_simple_if.sv
// Purpose: Defines the project's lightweight request/response bus interface used by the MVP SoC.
// Role in system: Connects one master (testbench now, E203 bridge later) to bus_interconnect and simple slaves.
// Key channels: m_* is master->fabric request, s_* is fabric->master response.
// Protocol style: Single outstanding transaction, valid/ready style, no burst support.
// Why this file matters: It is the reference contract reused by reg bank, DMA, SRAM, and peripheral stubs.
// Upgrade note: AXI-Lite migration can bridge to this interface to preserve slave modules during V1->V2 transition.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: bus_simple_if.sv
// 接口名: bus_simple_if
//
// 【功能概述】
// 项目简化 memory-mapped 总线接口定义。
// 使用 SystemVerilog interface + modport 机制，使主从端口方向由
// 编译器静态检查，避免手动连线时的方向错误。
//
// 【协议规范】
// ┌────────────────────────────────────────────────────────────────────┐
// │ 请求阶段（主机发起）：                                              │
// │   m_valid  = 1，同时驱动 m_write / m_addr / m_wdata / m_wstrb     │
// │                                                                    │
// │ 响应阶段（总线/从机响应，固定 1 拍延迟）：                          │
// │   写事务：下一拍 m_ready = 1（确认写完成）                          │
// │   读事务：下一拍 m_rvalid = 1，m_rdata 携带读回数据                 │
// │                                                                    │
// │ 约束：                                                             │
// │   - 单笔未完成事务（no pipelining）：m_ready/m_rvalid 后才能发下一笔│
// │   - 只支持 32-bit 对齐访问（m_addr[1:0] 应为 00）                  │
// │   - m_wstrb[3:0] 指定字节写使能（1=写该字节）                       │
// └────────────────────────────────────────────────────────────────────┘
//
// 【modport 说明】
//   master modport：主机（CPU / DMA / TB）使用，输出请求，输入响应
//   slave  modport：从机（SRAM / 寄存器 / 外设）使用，输入请求，输出响应
//
// 【信号名前缀约定】
//   m_ 前缀表示"memory-mapped bus"信号，非"master"的缩写
//
// 【升级路径】
// V2：若接入 E203 AXI-Lite 主机，在 chip_top 加 AXI-Lite→bus_simple 适配桥
//======================================================================
interface bus_simple_if (input logic clk);
  /* verilator lint_off UNDRIVEN */
  /* verilator lint_off UNUSEDSIGNAL */

  // ── 请求通道（主机→总线→从机）──────────────────────────────────────────
  logic        m_valid;   // 请求有效（高电平表示本拍有读/写请求）
  logic        m_write;   // 请求类型：1=写，0=读
  logic [31:0] m_addr;    // 字节地址（由总线/从机取低位做 word 寻址）
  logic [31:0] m_wdata;   // 写数据（m_write=1 时有效）
  logic [3:0]  m_wstrb;   // 字节写使能（bit[i]=1 表示写 m_wdata[8i+7:8i]）

  // ── 响应通道（从机→总线→主机）──────────────────────────────────────────
  logic        m_ready;   // 写完成握手（1=写事务被接受；下一拍置 1）
  logic [31:0] m_rdata;   // 读数据（m_rvalid=1 的当拍有效）
  logic        m_rvalid;  // 读数据有效（1=m_rdata 携带有效读结果；下一拍置 1）

  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on UNDRIVEN */

  // clk 本体不参与任何接口逻辑，通过哑线"使用"，消除 lint 告警
  // （clk 透传到 modport，供时序约束工具识别接口时钟域）
  wire _unused_clk = clk;

  // ── modport 定义 ──────────────────────────────────────────────────────────

  // 主机端口视图（CPU / DMA / Testbench 使用）
  // 主机：驱动请求信号，采样响应信号
  modport master (
    input  clk,       // 接口时钟（主机参考时钟域）
    output m_valid,   // 主机发起请求
    output m_write,   // 主机指定读/写
    output m_addr,    // 主机提供地址
    output m_wdata,   // 主机提供写数据
    output m_wstrb,   // 主机指定字节使能
    input  m_ready,   // 主机等待写完成
    input  m_rdata,   // 主机采样读数据
    input  m_rvalid   // 主机等待读有效
  );

  // 从机端口视图（SRAM / 寄存器 / 外设 stub 使用）
  // 从机：采样请求信号，驱动响应信号
  modport slave (
    input  clk,       // 接口时钟（从机参考时钟域）
    input  m_valid,   // 从机收到请求
    input  m_write,   // 从机判断读/写类型
    input  m_addr,    // 从机读取地址
    input  m_wdata,   // 从机读取写数据
    input  m_wstrb,   // 从机读取字节使能
    output m_ready,   // 从机确认写完成
    output m_rdata,   // 从机返回读数据
    output m_rvalid   // 从机指示读数据有效
  );
endinterface
