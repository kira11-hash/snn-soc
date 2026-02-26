// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/mem/sram_simple.sv
// Purpose: Minimal single-port SRAM behavioral model for memory-mapped storage.
// Role in system: Used for instruction/data/weight storage in the SoC (each instantiated separately).
// Behavior summary: Byte-write capable word-addressed memory with combinational read and synchronous write.
// Modeling intent: Functional simulation model, not a foundry SRAM macro timing model.
// Portability note: Keeps interface stable so later macro replacement only changes wrapper implementation.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: sram_simple.sv
// 模块名: sram_simple
//
// 【功能概述】
// 简化单端口 SRAM 行为模型，用于 SoC 中的指令/数据/权重存储。
// 总线接口与 bus_simple_if 协议对齐：固定 1 拍响应。
//
// 【实例化情况（snn_soc_top.sv）】
//   u_instr_sram   : 指令存储  @ 0x0000_0000，16KB
//   u_data_sram    : 数据存储  @ 0x0001_0000，16KB
//   （weight_sram 使用 sram_simple_dp，因为 DMA 需要并发读）
//
// 【读/写时序】
//   ┌─────┬──────────────┬────────────────────────────────────────┐
//   │类型  │ 时序         │ 说明                                    │
//   ├─────┼──────────────┼────────────────────────────────────────┤
//   │ 读  │ 组合（0 拍） │ rdata = mem[word_addr]，同拍有效        │
//   │     │              │ bus_interconnect 在下一拍注册后返回主机  │
//   ├─────┼──────────────┼────────────────────────────────────────┤
//   │ 写  │ 同步（1 拍） │ posedge clk 时按 req_wstrb 逐字节写入  │
//   └─────┴──────────────┴────────────────────────────────────────┘
//
// 【地址映射】
//   req_addr[ADDR_BITS+1:2] → word_addr（以字为单位，32-bit 对齐）
//   req_addr[1:0] = 2'b00（对齐假设，高位由 bus_interconnect 路由）
//   例：16KB（4096 words）→ ADDR_BITS = $clog2(4096) = 12
//       word_addr = req_addr[13:2]（12 位）
//
// 【字节写使能（req_wstrb）】
//   bit[0] → mem[addr][7:0]   (最低字节，小端第 0 字节)
//   bit[1] → mem[addr][15:8]
//   bit[2] → mem[addr][23:16]
//   bit[3] → mem[addr][31:24] (最高字节，小端第 3 字节)
//
// 【注意：无复位】
//   SRAM 不做上电复位（与真实 SRAM macro 行为一致）。
//   rst_n 端口保留以备将来用途，当前通过 _unused 链接以消除 lint 告警。
//
// 【升级路径】
// ASIC：替换为工艺库提供的 SRAM macro（如 TSMC TS6N65LP），
//       保持端口接口不变，只换内部实现
//======================================================================
module sram_simple #(
  // 存储容量（字节数），必须是 4 的倍数（按 32-bit word 组织）
  // 默认 16KB = 4096 words
  parameter int MEM_BYTES = 16384
) (
  input  logic        clk,       // 系统时钟（写操作在上升沿执行）
  input  logic        rst_n,     // 复位（当前未使用，保留端口；见"注意：无复位"）

  // ── 总线接口（简化 memory-mapped 协议）────────────────────────────────
  input  logic        req_valid,  // 请求有效（当拍有读或写操作）
  input  logic        req_write,  // 1=写，0=读
  input  logic [31:0] req_addr,   // 字节地址（[ADDR_BITS+1:2] 提取 word index）
  input  logic [31:0] req_wdata,  // 写数据（32-bit，按 wstrb 选择字节写入）
  input  logic [3:0]  req_wstrb,  // 字节写使能（4 位，每位对应一字节）
  output logic [31:0] rdata       // 读数据（组合输出，与 req_addr 同拍有效）
);
  // ── 参数派生 ──────────────────────────────────────────────────────────────
  localparam int WORDS     = MEM_BYTES / 4;           // word 数量（每 word 32-bit）
  localparam int ADDR_BITS = $clog2(WORDS);           // word 地址位宽（例：4096 words → 12 位）

  // ── 存储阵列 ──────────────────────────────────────────────────────────────
  // 仿真中为 reg 数组；ASIC 综合后替换为 SRAM macro instance
  logic [31:0] mem [0:WORDS-1];

  // ── word 地址提取 ─────────────────────────────────────────────────────────
  // 字节地址转 word 地址：右移 2 位（除以 4），取 ADDR_BITS 位
  // 位域 [ADDR_BITS+1:2] 等价于 req_addr >> 2 的低 ADDR_BITS 位
  wire [ADDR_BITS-1:0] word_addr = req_addr[ADDR_BITS+1:2];

  // lint 友好：rst_n 当前无逻辑（SRAM 无复位），req_addr 高/低位未用于 word_addr
  // req_wdata 和 req_wstrb 在综合中确实被使用（always_ff 中），
  // 此处收入哑线只是消除某些 linter 对"变量未完全使用"的告警
  wire _unused = &{1'b0, rst_n, req_addr, req_wdata, req_wstrb};

  // ── 组合读（零延迟）──────────────────────────────────────────────────────
  // rdata 直接从 mem 数组组合读出，与 req_addr 同拍有效。
  // bus_interconnect 会将 rdata 注册一拍后返回主机（总体效果：1-cycle read latency）
  assign rdata = mem[word_addr];

  // ── 同步写（字节使能）────────────────────────────────────────────────────
  // 仅在 req_valid && req_write 时执行写操作，每拍最多写一个 word。
  // 逐字节写使能确保 C 语言的 char/short/int 写操作正确。
  always_ff @(posedge clk) begin
    if (req_valid && req_write) begin
      if (req_wstrb[0]) mem[word_addr][7:0]   <= req_wdata[7:0];   // 字节 0（最低字节）
      if (req_wstrb[1]) mem[word_addr][15:8]  <= req_wdata[15:8];  // 字节 1
      if (req_wstrb[2]) mem[word_addr][23:16] <= req_wdata[23:16]; // 字节 2
      if (req_wstrb[3]) mem[word_addr][31:24] <= req_wdata[31:24]; // 字节 3（最高字节）
    end
  end
endmodule
