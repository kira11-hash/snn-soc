`timescale 1ns/1ps
//======================================================================
// 文件名: rtl/bus/icb2simple_bridge_v2b.sv
// 模块名: icb2simple_bridge_v2b
//
// 【本分支范围】
//   新增于 `feature/v2-fpga-e203` (Phase A-2)。不进 `main` / `v2`。
//   V1 `rtl/bus/icb2simple_bridge.sv` 一字不改；本文件是该 bridge 的
//   V2B variant，只改 **地址白名单**。
//
// 【功能】
//   E203 `mem_icb` (ICB) → simple_bus master。3-state FSM（IDLE → WAIT → RSP）。
//   非法地址直接在 IDLE 拦截、返回 `rsp_err=1`，**不发 m_valid 给 fabric**。
//
// 【白名单（V2B-only，对应 feature/v2-fpga-e203 的 4 段地址）】
//   SRAM-like（允许非 4B 对齐）：
//     INSTR : ADDR_V2E203_INSTR_BASE..ADDR_V2E203_INSTR_END (0x0000_0000..0x0000_FFFF, 64 KB)
//     DATA  : ADDR_V2E203_DATA_BASE ..ADDR_V2E203_DATA_END  (0x0001_0000..0x0001_1FFF,  8 KB)
//   MMIO（必须 4B 对齐；非对齐 → ICB error）：
//     UART  : ADDR_V2E203_UART_BASE ..ADDR_V2E203_UART_END  (0x0002_0000..0x0002_00FF)
//     V2B   : ADDR_V2B_BASE         ..ADDR_V2B_END          (0xA000_0000..0xA000_0FFF,  4 KB)
//
// 【**删掉**的 V1 白名单（绝不放行）】
//   REG_BANK (0x4000_0000)、DMA (0x4000_0100)、SPI (0x4000_0300)、
//   FIFO (0x4000_0400)。这些地址在本支线**不可访问**；若 E203 固件误访问，
//   必须在 bridge 前端 `rsp_err=1`，不能进 fabric（fabric miss 是最后内部
//   防线）。这是 plan v11 R11：V1 MMIO 低 12-bit 别名进 V2B 的根因修掉。
//
// 【与 V1 原文件的关系】
//   FSM、响应回路、busy_o 语义全部一致（沿用已 tape-out 验证过的结构）；
//   仅两个 `is_sram_addr` / `is_mmio_addr` 函数体不同。其余逻辑 1:1 对照
//   `rtl/bus/icb2simple_bridge.sv`。
//
// 【Icarus 等价 checker（不依赖 VCS assert）】
//   TB 里外挂一条 "illegal addr never leaks m_valid" 的 watchdog：
//   对非法地址发 ICB cmd 后，整个事务期间 `m_valid` 必须恒为 0。
//======================================================================
module icb2simple_bridge_v2b (
  input  logic        clk,
  input  logic        rst_n,

  // ── ICB 主机侧（来自 e203_min_wrap.mem_icb）─────────────────────────
  input  logic        i_icb_cmd_valid,
  output logic        i_icb_cmd_ready,
  input  logic [31:0] i_icb_cmd_addr,
  input  logic        i_icb_cmd_read,
  input  logic [31:0] i_icb_cmd_wdata,
  input  logic [3:0]  i_icb_cmd_wmask,
  output logic        i_icb_rsp_valid,
  input  logic        i_icb_rsp_ready,
  output logic        i_icb_rsp_err,
  output logic [31:0] i_icb_rsp_rdata,

  // ── simple_bus 从机侧（接 bus_interconnect_v2_e203）──────────────────
  output logic        m_valid,
  output logic        m_write,
  output logic [31:0] m_addr,
  output logic [31:0] m_wdata,
  output logic [3:0]  m_wstrb,
  input  logic        m_ready,
  input  logic [31:0] m_rdata,
  input  logic        m_rvalid,

  output logic        busy_o
);
  import snn_soc_pkg::*;

  // ── 状态机 ────────────────────────────────────────────────────────
  typedef enum logic [1:0] {
    ST_IDLE = 2'd0,
    ST_WAIT = 2'd1,
    ST_RSP  = 2'd2
  } state_t;

  state_t      state_q;
  logic        pending_read_q;
  logic        rsp_err_q;
  logic [31:0] rsp_rdata_q;

  // ── 地址白名单（V2B-only）─────────────────────────────────────────
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic in_range(
    input logic [31:0] addr,
    input logic [31:0] base,
    input logic [31:0] last
  );
    in_range = (addr >= base) && (addr <= last);
  endfunction

  // SRAM-like：允许任何字节对齐（V1-style）
  function automatic logic is_sram_addr(input logic [31:0] addr);
    is_sram_addr =
        in_range(addr, ADDR_V2E203_INSTR_BASE, ADDR_V2E203_INSTR_END) ||
        in_range(addr, ADDR_V2E203_DATA_BASE,  ADDR_V2E203_DATA_END);
  endfunction

  // MMIO-like：必须 4B 对齐
  function automatic logic is_mmio_addr(input logic [31:0] addr);
    is_mmio_addr =
        in_range(addr, ADDR_V2E203_UART_BASE, ADDR_V2E203_UART_END) ||
        in_range(addr, ADDR_V2B_BASE,         ADDR_V2B_END);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  wire cmd_is_sram  = is_sram_addr(i_icb_cmd_addr);
  wire cmd_is_mmio  = is_mmio_addr(i_icb_cmd_addr);
  wire cmd_mapped   = cmd_is_sram || cmd_is_mmio;
  // Current V2E203 MMIO registers are 32-bit wide. If V2B later exposes
  // 64-bit MMIO registers, this alignment rule must be tightened.
  wire cmd_aligned  = (i_icb_cmd_addr[1:0] == 2'b00);
  // 非法：未命中白名单 或 MMIO 未 4B 对齐
  wire cmd_illegal  = !cmd_mapped || (cmd_is_mmio && !cmd_aligned);
  wire cmd_fire     = i_icb_cmd_valid && i_icb_cmd_ready;
  wire bus_rsp_fire = pending_read_q ? m_rvalid : m_ready;

  // ── FSM ───────────────────────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q        <= ST_IDLE;
      pending_read_q <= 1'b0;
      rsp_err_q      <= 1'b0;
      rsp_rdata_q    <= 32'h0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (cmd_fire) begin
            rsp_rdata_q <= 32'h0;
            if (cmd_illegal) begin
              // 非法地址：直接 rsp_err，不进 ST_WAIT → 永不拉 m_valid
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
        ST_WAIT: begin
          if (bus_rsp_fire) begin
            rsp_err_q   <= 1'b0;
            rsp_rdata_q <= pending_read_q ? m_rdata : 32'h0;
            state_q     <= ST_RSP;
          end
        end
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
    i_icb_cmd_ready = (state_q == ST_IDLE);
    i_icb_rsp_valid = (state_q == ST_RSP);
    i_icb_rsp_err   = rsp_err_q;
    i_icb_rsp_rdata = rsp_rdata_q;
    busy_o          = rst_n && (state_q != ST_IDLE);

    // 仅在 IDLE 且命令合法时才发 m_valid 给 fabric
    m_valid = (state_q == ST_IDLE) && i_icb_cmd_valid && !cmd_illegal;
    m_write = !i_icb_cmd_read;
    m_addr  = i_icb_cmd_addr;
    m_wdata = i_icb_cmd_wdata;
    m_wstrb = i_icb_cmd_wmask;
  end
endmodule
