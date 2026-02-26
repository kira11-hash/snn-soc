// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/reg/fifo_regs.sv
// Purpose: Read-only register view for FIFO occupancy/debug counters exposed on the bus.
// Role in system: Lets software/testbench observe buffering state without peeking internal signals directly.
// Behavior summary: Maps FIFO counts/status into memory-mapped registers; no heavy control logic here.
// Design intent: Keep observability logic separate from reg_bank to reduce coupling and simplify updates.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: fifo_regs.sv
// 模块名: fifo_regs
//
// 【功能概述】
// FIFO 状态寄存器窗口（只读）。地址基址：0x4000_0400。
// 将 input_fifo 和 output_fifo 的计数与空满状态映射为
// memory-mapped 寄存器，供固件轮询或中断服务读取。
//
// 【设计特点】
// - 纯组合逻辑（无时钟/复位）：FIFO 状态直接组合输出，读数据实时反映当前状态
// - 只读：所有写操作被 _unused 链捕获并忽略，不产生任何副作用
// - 无存储元素：不是真正的"寄存器"，而是状态信号的组合映射窗口
//
// 【寄存器映射】（offset 相对于 FIFO 基地址 0x4000_0400）
//   0x00: REG_IN_COUNT  - Input FIFO 当前深度计数（$clog2(DEPTH+1) 位，零扩展）
//   0x04: REG_OUT_COUNT - Output FIFO 当前深度计数（$clog2(DEPTH+1) 位，零扩展）
//   0x08: REG_STATUS    - FIFO 空满状态聚合
//           bit[0] = in_fifo_empty   (1=输入 FIFO 空，DMA 需继续填充)
//           bit[1] = in_fifo_full    (1=输入 FIFO 满，DMA 不应继续写入)
//           bit[2] = out_fifo_empty  (1=输出 FIFO 空，无推理结果可读)
//           bit[3] = out_fifo_full   (1=输出 FIFO 满，需及时读出结果)
//
// 【使用场景】
// 固件轮询 REG_STATUS：
//   while (REG_STATUS & 0x4) { /* out_fifo_empty, wait */ }
//   class_id = REG_OUT_DATA; // 从 reg_bank.REG_OUT_DATA 读结果
//======================================================================
module fifo_regs (
  // ── 总线接口（只读，所有写操作忽略）─────────────────────────────────────
  // 注意：本模块无时钟/复位端口，因为是纯组合逻辑
  input  logic        req_valid,   // 请求有效（组合使用，此模块不做区分）
  input  logic        req_write,   // 写请求标志（组合使用，此模块不做区分）
  input  logic [31:0] req_addr,    // 字节地址（取低8位做 offset 索引）
  input  logic [31:0] req_wdata,   // 写数据（只读模块，此信号被忽略）
  input  logic [3:0]  req_wstrb,   // 字节写使能（只读模块，被忽略）
  output logic [31:0] rdata,       // 读返回数据（组合输出，实时反映 FIFO 状态）

  // ── 来自 fifo_sync 实例的 FIFO 状态信号 ──────────────────────────────────
  // 计数宽度由 FIFO 深度决定（$clog2(DEPTH+1) 位）
  // INPUT_FIFO_DEPTH=256  → $clog2(257) = 9 位 → in_fifo_count[8:0]
  // OUTPUT_FIFO_DEPTH=256 → $clog2(257) = 9 位 → out_fifo_count[8:0]
  input  logic [$clog2(snn_soc_pkg::INPUT_FIFO_DEPTH+1)-1:0]  in_fifo_count,  // 输入 FIFO 当前元素数
  input  logic [$clog2(snn_soc_pkg::OUTPUT_FIFO_DEPTH+1)-1:0] out_fifo_count, // 输出 FIFO 当前元素数
  input  logic in_fifo_empty,    // 输入 FIFO 空标志（count==0 时置 1）
  input  logic in_fifo_full,     // 输入 FIFO 满标志（count==DEPTH 时置 1）
  input  logic out_fifo_empty,   // 输出 FIFO 空标志
  input  logic out_fifo_full     // 输出 FIFO 满标志
);
  // ── offset 定义 ──────────────────────────────────────────────────────────
  localparam logic [7:0] REG_IN_COUNT  = 8'h00; // 输入 FIFO 深度
  localparam logic [7:0] REG_OUT_COUNT = 8'h04; // 输出 FIFO 深度
  localparam logic [7:0] REG_STATUS    = 8'h08; // 空满状态聚合

  // 地址低8位作为模块内 offset
  wire [7:0] addr_offset = req_addr[7:0];

  // lint 友好：req_valid、req_write、高地址位、写数据/使能均不使用
  // （只读模块，不需要区分读/写，不处理写操作）
  wire _unused = &{1'b0, req_valid, req_write, req_addr[31:8], req_wdata, req_wstrb};

  // ── 只读寄存器映射（纯组合）──────────────────────────────────────────────
  // 写入任何地址均被忽略；读取直接返回当前 FIFO 状态值。
  // 零扩展：计数值位宽 < 32，高位填 0 确保读数正确。
  always_comb begin
    rdata = 32'h0; // 默认：未命中地址或无效 offset 返回 0
    case (addr_offset)
      // INPUT FIFO 计数：$clog2(256+1)=9 位，高 23 位填 0
      REG_IN_COUNT:  rdata = {{(32-$clog2(snn_soc_pkg::INPUT_FIFO_DEPTH+1)){1'b0}}, in_fifo_count};

      // OUTPUT FIFO 计数：$clog2(256+1)=9 位，高 23 位填 0
      REG_OUT_COUNT: rdata = {{(32-$clog2(snn_soc_pkg::OUTPUT_FIFO_DEPTH+1)){1'b0}}, out_fifo_count};

      // FIFO 空满状态聚合（位域）
      REG_STATUS: begin
        rdata[0] = in_fifo_empty;   // bit0: 输入 FIFO 空（1=推理数据未准备好）
        rdata[1] = in_fifo_full;    // bit1: 输入 FIFO 满（1=暂停写入）
        rdata[2] = out_fifo_empty;  // bit2: 输出 FIFO 空（1=无推理结果）
        rdata[3] = out_fifo_full;   // bit3: 输出 FIFO 满（1=及时读出）
        // [31:4] 保持 0（未来扩展位）
      end

      default: rdata = 32'h0; // 未定义 offset
    endcase
  end
endmodule
