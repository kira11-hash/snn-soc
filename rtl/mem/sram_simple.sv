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
//   u_weight_sram  : 权重存储  @ 0x0003_0000，16KB
//   （DMA 并发读只发生在 data_sram，因此只有 data_sram 使用 sram_simple_dp）
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
  parameter int    MEM_BYTES  = 16384,
  // INIT_FILE: 非空时在仿真或 Vivado FPGA 综合时用 $readmemh 预加载内容。
  // 仅用于 FPGA BRAM init（feature/main-fpga-e203）；留空时行为与原版完全一致。
  parameter        INIT_FILE  = ""
) (
  input  logic        clk,       // 系统时钟（写操作在上升沿执行）
  input  logic        rst_n,     // 复位（当前未使用，保留端口；见"注意：无复位"）

  // ── 总线接口（简化 memory-mapped 协议）────────────────────────────────
  input  logic        req_valid,  // 请求有效（当拍有读或写操作）
  input  logic        req_write,  // 1=写，0=读
  input  logic [31:0] req_addr,   // 字节地址（[ADDR_BITS+1:2] 提取 word index）
  input  logic [31:0] req_wdata,  // 写数据（32-bit，按 wstrb 选择字节写入）
  input  logic [3:0]  req_wstrb,  // 字节写使能（4 位，每位对应一字节）
  output logic [31:0] rdata,      // 读数据（组合输出，与 req_addr 同拍有效）

  // ── DMA 写端口（Port B）──────────────────────────────────────────────
  // 用于 dma_engine 将 data_sram 内容直接复制到 weight_sram / instr_sram。
  // 优先级：DMA 写覆盖同拍总线写（两者在 V1 中互斥，不冲突）。
  // 连接方式：不需要此端口时，顶层将 dma_wr_en=0，其余置 0。
  input  logic        dma_wr_en,    // DMA 写使能（单拍有效）
  input  logic [31:0] dma_wr_addr,  // DMA 字节地址（SRAM 内部偏移）
  input  logic [31:0] dma_wr_data,  // DMA 写数据（32-bit）
  input  logic [3:0]  dma_wr_strb   // DMA 字节写使能（4 位）
);
  // ── 参数派生 ──────────────────────────────────────────────────────────────
  localparam int WORDS     = MEM_BYTES / 4;           // word 数量（每 word 32-bit）
  localparam int ADDR_BITS = $clog2(WORDS);           // word 地址位宽（例：4096 words → 12 位）

  // ── 存储阵列 ──────────────────────────────────────────────────────────────
  // 仿真中为 reg 数组；ASIC 综合后替换为 SRAM macro instance
  logic [31:0] mem [0:WORDS-1];

  // ── word 地址提取 ─────────────────────────────────────────────────────────
  // 字节地址转 word 地址：右移 2 位（除以 4），取 ADDR_BITS 位
  wire [ADDR_BITS-1:0] word_addr     = req_addr[ADDR_BITS+1:2];
  wire [ADDR_BITS-1:0] dma_word_addr = dma_wr_addr[ADDR_BITS+1:2];

  // lint 友好：rst_n 当前无逻辑，req/dma 高/低位多余部分通过哑线消除告警
  wire _unused = &{1'b0, rst_n, req_addr, req_wdata, req_wstrb,
                   dma_wr_addr, dma_wr_data, dma_wr_strb};

  // BRAM pre-init (FPGA only): Vivado recognises $readmemh in initial blocks
  // and uses the file to set BRAM INIT_xx attributes at synthesis time.
  // Simulation: same effect — useful for E203 FPGA smoke firmware pre-load.
  initial begin
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  // ── 组合读（零延迟）──────────────────────────────────────────────────────
  assign rdata = mem[word_addr];

  // ── 同步写（字节使能）────────────────────────────────────────────────────
  // 总线写和 DMA 写均在同一 always_ff 中处理。
  // DMA 写在后，同拍冲突时 DMA 覆盖总线写（V1 中两者互斥，不会同时发生）。
  always_ff @(posedge clk) begin
    // 总线写
    if (req_valid && req_write) begin
      if (req_wstrb[0]) mem[word_addr][7:0]   <= req_wdata[7:0];
      if (req_wstrb[1]) mem[word_addr][15:8]  <= req_wdata[15:8];
      if (req_wstrb[2]) mem[word_addr][23:16] <= req_wdata[23:16];
      if (req_wstrb[3]) mem[word_addr][31:24] <= req_wdata[31:24];
    end
    // DMA 写（DMA 复制路径：dma_engine → instr_sram / weight_sram）
    if (dma_wr_en) begin
      if (dma_wr_strb[0]) mem[dma_word_addr][7:0]   <= dma_wr_data[7:0];
      if (dma_wr_strb[1]) mem[dma_word_addr][15:8]  <= dma_wr_data[15:8];
      if (dma_wr_strb[2]) mem[dma_word_addr][23:16] <= dma_wr_data[23:16];
      if (dma_wr_strb[3]) mem[dma_word_addr][31:24] <= dma_wr_data[31:24];
    end
  end
endmodule
