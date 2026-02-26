// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/periph/uart_stub.sv
// Purpose: UART placeholder module with register interface but no real serial protocol implementation yet.
// Role in system: Reserves bus map/addressing and lets software/testbench integrate before UART controller is implemented.
// Behavior summary: Returns deterministic status/data placeholders so top-level compiles and bus paths are exercised.
// Upgrade path: Replace with uart_ctrl.sv in V1 full system while preserving register map compatibility where possible.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: uart_stub.sv
// 模块名: uart_stub
//
// 【功能概述】
// UART 串口外设占位模块（stub）。V1 阶段不实现真实串口协议，
// 但提供完整的寄存器接口，使总线访问不报错、固件可正常编译。
// 地址空间：0x4000_0200 ~ 0x4000_02FF（256B，由 bus_interconnect 路由）
//
// 【寄存器映射】（offset 相对于 UART 基地址 0x4000_0200）
//   0x00: REG_TXDATA - 发送数据（可读写；stub 不真正发送到 TX 线）
//   0x04: REG_RXDATA - 接收数据（只读；stub 固定返回 0，无真实接收）
//   0x08: REG_STATUS - 状态（可读；stub 固定为 0，表示空闲）
//   0x0C: REG_CTRL   - 控制（可读写；软件可配置，stub 保存但不处理）
//
// 【物理接口行为（stub）】
//   uart_tx = 1：串口空闲高电平（UART 协议规定，线路空闲时为高）
//   uart_rx：输入，stub 完全忽略
//
// 【升级路径】
// V2：替换为真实 UART 控制器，实现 8N1 帧格式、波特率分频、TX/RX FIFO
//======================================================================
module uart_stub (
  // ── 时钟和复位 ────────────────────────────────────────────────────────────
  input  logic        clk,        // 系统时钟（所有寄存器在上升沿更新）
  input  logic        rst_n,      // 异步低有效复位（复位时所有寄存器清零）

  // ── 总线接口（简化 memory-mapped 协议，来自 bus_interconnect）──────────
  // bus_interconnect 已完成地址解码，此处 req_addr 是完整地址（非 offset）
  input  logic        req_valid,  // 请求有效脉冲（当拍采样地址/数据）
  input  logic        req_write,  // 1=写请求，0=读请求
  input  logic [31:0] req_addr,   // 请求字节地址（低8位用作寄存器 offset）
  input  logic [31:0] req_wdata,  // 写数据（32位，stub 不区分字节写使能）
  input  logic [3:0]  req_wstrb,  // 字节写使能（stub 整字写，wstrb 忽略）
  output logic [31:0] rdata,      // 读返回数据（组合输出，bus_interconnect 注册1拍后返回主机）

  // ── UART 物理接口 ─────────────────────────────────────────────────────────
  input  logic        uart_rx,    // 串口接收线（stub 忽略，通过 _unused 链消除告警）
  output logic        uart_tx     // 串口发送线（stub 固定高电平 = 线路空闲）
);
  // ── 寄存器 offset 定义 ────────────────────────────────────────────────────
  // 取 req_addr[7:0] 作为 offset，覆盖 256B 地址空间内的所有寄存器
  localparam logic [7:0] REG_TXDATA = 8'h00; // 发送数据寄存器
  localparam logic [7:0] REG_RXDATA = 8'h04; // 接收数据寄存器（只读）
  localparam logic [7:0] REG_STATUS = 8'h08; // 状态寄存器（只读）
  localparam logic [7:0] REG_CTRL   = 8'h0C; // 控制寄存器（可读写）

  // ── 内部寄存器（stub 维持软件可见状态，不驱动任何物理协议）──────────────
  logic [31:0] txdata_reg;  // 发送数据影子寄存器：软件写入后可读回
  logic [31:0] ctrl_reg;    // 控制寄存器影子：保存软件配置（波特率等）
  logic [31:0] status_reg;  // 状态寄存器：stub 始终为 0（空闲，无错误）

  // ── 地址 offset 提取 ──────────────────────────────────────────────────────
  // [31:8] 已由 bus_interconnect 用于选中本模块，低8位是模块内部 offset
  wire [7:0] addr_offset = req_addr[7:0];

  // 写使能：一拍有效（valid 且 write）
  wire write_en = req_valid && req_write;

  // lint 友好：req_addr 高位、req_wstrb（整字写）、uart_rx 均未使用，收入哑线
  wire _unused = &{1'b0, req_addr[31:8], req_wstrb, uart_rx};

  // ── UART TX 固定空闲电平 ──────────────────────────────────────────────────
  // UART 协议：线路空闲时为高电平（Mark 状态）。
  // 起始位为低电平（Space），stub 不发送，故固定高电平。
  assign uart_tx = 1'b1;

  // ── 寄存器写逻辑（同步时序）───────────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // 异步复位：所有寄存器清零
      txdata_reg <= 32'h0;
      ctrl_reg   <= 32'h0;
      status_reg <= 32'h0;
    end else begin
      if (write_en) begin
        case (addr_offset)
          REG_TXDATA: txdata_reg <= req_wdata; // 软件写发送数据（stub 不真正发送）
          REG_CTRL:   ctrl_reg   <= req_wdata; // 软件配置控制位（stub 保存但不处理）
          default: begin
            // REG_STATUS 和 REG_RXDATA 为只读；其他 offset 写入忽略
          end
        endcase
      end
    end
  end

  // ── 读数据多路选择（纯组合逻辑）──────────────────────────────────────────
  // bus_interconnect 会在下一个时钟沿注册 rdata 后返回主机，
  // 所以此处是组合逻辑（无寄存器延迟），时序由总线协议保证。
  always_comb begin
    rdata = 32'h0; // 默认：未命中地址返回 0
    case (addr_offset)
      REG_TXDATA: rdata = txdata_reg;  // 读回上次软件写入的发送数据
      REG_RXDATA: rdata = 32'h0;       // stub：无真实串口接收，始终返回 0
      REG_STATUS: rdata = status_reg;  // stub：状态固定为 0（空闲）
      REG_CTRL:   rdata = ctrl_reg;    // 读回控制寄存器
      default:    rdata = 32'h0;       // 未定义 offset 返回 0
    endcase
  end
endmodule
