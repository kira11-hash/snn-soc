`timescale 1ns/1ps
//======================================================================
// 文件名: bus_simple_if.sv
// 描述: 简化的 memory-mapped bus 接口定义。
//       仅支持单笔 32-bit 读写 + byte strobe。
//       约定固定 1-cycle 响应：
//         - 写请求：下一拍 m_ready=1
//         - 读请求：下一拍 m_rvalid=1 且 m_rdata 有效
//======================================================================
interface bus_simple_if (input logic clk);
  /* verilator lint_off UNDRIVEN */
  /* verilator lint_off UNUSEDSIGNAL */
  logic        m_valid;
  logic        m_write;
  logic [31:0] m_addr;
  logic [31:0] m_wdata;
  logic [3:0]  m_wstrb;
  logic        m_ready;
  logic [31:0] m_rdata;
  logic        m_rvalid;
  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on UNDRIVEN */

  // 标记未使用输入（lint 友好）
  wire _unused_clk = clk;

  modport master (
    input  clk,
    output m_valid,
    output m_write,
    output m_addr,
    output m_wdata,
    output m_wstrb,
    input  m_ready,
    input  m_rdata,
    input  m_rvalid
  );

  modport slave (
    input  clk,
    input  m_valid,
    input  m_write,
    input  m_addr,
    input  m_wdata,
    input  m_wstrb,
    output m_ready,
    output m_rdata,
    output m_rvalid
  );
endinterface
