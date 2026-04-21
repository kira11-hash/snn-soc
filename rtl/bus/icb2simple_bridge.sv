`timescale 1ns/1ps
//======================================================================
// 文件名: icb2simple_bridge.sv
// 模块名: icb2simple_bridge
//
// 【功能概述】
// E203 RISC-V CPU 的 ICB（Internal Chip Bus）协议到内部 simple bus
// 的协议桥接器。将 ICB 的 cmd/rsp 握手转换为 simple bus 的
// valid/ready/rvalid 握手。
//
// 【状态机】
// IDLE → WAIT → RSP → IDLE
// - IDLE：等待 ICB cmd，检查地址合法性
// - WAIT：转发到 simple bus，等待下游响应
// - RSP ：将响应返回给 ICB 主机
//
// 【地址检查】
// - SRAM 地址（instr_sram / data_sram / weight_sram）：允许任意对齐
// - MMIO 地址（reg_bank / DMA / UART / SPI / FIFO）：必须 4B 对齐
// - 未映射地址：返回 err=1, rdata=0
//
// 【CPU 局部复位】
// cpu_reset_hold 复位 CPU 核和本桥接器，但不复位下游 SRAM/外设。
// busy_o 输出用于 JTAG rescue 判断 CPU 是否正在占用总线。
//======================================================================
module icb2simple_bridge (
  input  logic        clk,              // 系统时钟
  input  logic        rst_n,            // 异步低有效复位（CPU 局部复位时也会拉低）

  // ── ICB 主机侧（连接 E203 CPU）────────────────────────────────────
  input  logic        i_icb_cmd_valid,   // 命令有效
  output logic        i_icb_cmd_ready,   // 命令就绪（桥空闲时拉高）
  input  logic [31:0] i_icb_cmd_addr,    // 命令地址
  input  logic        i_icb_cmd_read,    // 1=读，0=写
  input  logic [31:0] i_icb_cmd_wdata,   // 写数据
  input  logic [3:0]  i_icb_cmd_wmask,   // 字节写使能
  output logic        i_icb_rsp_valid,   // 响应有效
  input  logic        i_icb_rsp_ready,   // 响应就绪（CPU 接收确认）
  output logic        i_icb_rsp_err,     // 响应错误标志
  output logic [31:0] i_icb_rsp_rdata,   // 响应读数据

  // ── simple bus 从机侧（连接 bus_interconnect）─────────────────────
  output logic        m_valid,           // 请求有效
  output logic        m_write,           // 1=写，0=读
  output logic [31:0] m_addr,            // 地址
  output logic [31:0] m_wdata,           // 写数据
  output logic [3:0]  m_wstrb,           // 字节写使能
  input  logic        m_ready,           // 写响应（下游接受写请求）
  input  logic [31:0] m_rdata,           // 读数据
  input  logic        m_rvalid,          // 读响应有效

  output logic        busy_o             // 桥忙标志（JTAG rescue 用于超时判断）
);
  import snn_soc_pkg::*;

  // ── 状态机定义 ────────────────────────────────────────────────────
  typedef enum logic [1:0] {
    ST_IDLE = 2'd0,  // 空闲，等待 ICB 命令
    ST_WAIT = 2'd1,  // 等待 simple bus 响应
    ST_RSP  = 2'd2   // 返回响应给 ICB 主机
  } state_t;

  state_t      state_q;
  logic        pending_read_q;    // 当前事务是读操作
  logic        rsp_err_q;         // 锁存的错误标志
  logic [31:0] rsp_rdata_q;       // 锁存的读数据

  // ── 地址合法性检查函数 ────────────────────────────────────────────
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic in_range(
    input logic [31:0] addr,
    input logic [31:0] base,
    input logic [31:0] last
  );
    in_range = (addr >= base) && (addr <= last);
  endfunction

  // 检查是否为 SRAM 地址（instr / data / weight）
  function automatic logic is_sram_addr(input logic [31:0] addr);
    is_sram_addr =
        in_range(addr, ADDR_INSTR_BASE,  ADDR_INSTR_END)  ||
        in_range(addr, ADDR_DATA_BASE,   ADDR_DATA_END)   ||
        in_range(addr, ADDR_WEIGHT_BASE, ADDR_WEIGHT_END);
  endfunction

  // 检查是否为 MMIO 地址（reg_bank / DMA / UART / SPI / FIFO）
  function automatic logic is_mmio_addr(input logic [31:0] addr);
    is_mmio_addr =
        in_range(addr, ADDR_REG_BASE,  ADDR_REG_END)  ||
        in_range(addr, ADDR_DMA_BASE,  ADDR_DMA_END)  ||
        in_range(addr, ADDR_UART_BASE, ADDR_UART_END) ||
        in_range(addr, ADDR_SPI_BASE,  ADDR_SPI_END)  ||
        in_range(addr, ADDR_FIFO_BASE, ADDR_FIFO_END);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ── 组合逻辑：地址判断 ────────────────────────────────────────────
  wire cmd_is_sram  = is_sram_addr(i_icb_cmd_addr);  // SRAM 地址
  wire cmd_is_mmio  = is_mmio_addr(i_icb_cmd_addr);  // MMIO 地址
  wire cmd_mapped   = cmd_is_sram || cmd_is_mmio;     // 有效映射地址
  wire cmd_aligned  = (i_icb_cmd_addr[1:0] == 2'b00); // 4B 对齐
  // 非法条件：未映射 或 MMIO 未对齐
  wire cmd_illegal  = !cmd_mapped || (cmd_is_mmio && !cmd_aligned);
  wire cmd_fire     = i_icb_cmd_valid && i_icb_cmd_ready;
  // 响应握手：读等 rvalid，写等 ready
  wire bus_rsp_fire = pending_read_q ? m_rvalid : m_ready;

  // ── 状态机 ────────────────────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q        <= ST_IDLE;
      pending_read_q <= 1'b0;
      rsp_err_q      <= 1'b0;
      rsp_rdata_q    <= 32'h0;
    end else begin
      case (state_q)
        // 空闲：接收 ICB 命令
        ST_IDLE: begin
          if (cmd_fire) begin
            rsp_rdata_q <= 32'h0;
            if (cmd_illegal) begin
              // 非法地址：直接返回错误，不转发到 simple bus
              rsp_err_q      <= 1'b1;
              pending_read_q <= 1'b0;
              state_q        <= ST_RSP;
            end else begin
              rsp_err_q      <= 1'b0;
              pending_read_q <= i_icb_cmd_read;
              state_q        <= ST_WAIT;
            end
          end
        end
        // 等待 simple bus 响应
        ST_WAIT: begin
          if (bus_rsp_fire) begin
            rsp_err_q   <= 1'b0;
            rsp_rdata_q <= pending_read_q ? m_rdata : 32'h0;
            state_q     <= ST_RSP;
          end
        end
        // 返回响应给 ICB 主机
        ST_RSP: begin
          if (i_icb_rsp_ready) begin
            state_q <= ST_IDLE;
          end
        end
        default: begin
          state_q <= ST_IDLE;
        end
      endcase
    end
  end

  // ── 组合输出 ──────────────────────────────────────────────────────
  always_comb begin
    i_icb_cmd_ready = (state_q == ST_IDLE);      // 桥空闲时可接收命令
    i_icb_rsp_valid = (state_q == ST_RSP);       // RSP 状态时输出响应
    i_icb_rsp_err   = rsp_err_q;
    i_icb_rsp_rdata = rsp_rdata_q;
    busy_o          = rst_n && (state_q != ST_IDLE);  // 桥忙标志

    // simple bus 请求：仅在 IDLE 且命令合法时转发
    m_valid = (state_q == ST_IDLE) && i_icb_cmd_valid && !cmd_illegal;
    m_write = !i_icb_cmd_read;
    m_addr  = i_icb_cmd_addr;
    m_wdata = i_icb_cmd_wdata;
    m_wstrb = i_icb_cmd_wmask;
  end
endmodule
