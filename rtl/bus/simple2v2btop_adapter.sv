`timescale 1ns/1ps
//======================================================================
// 文件名: rtl/bus/simple2v2btop_adapter.sv
// 模块名: simple2v2btop_adapter
//
// 【本分支范围】
// 新增于 `feature/v2-arm-fpga-demo`（REV 2 plan §D2）。
// 不修改任何现有 parity 合约文件，不进入 main。
//
// 【功能概述】
// 在 `axi2simple_bridge`（bus_simple_if master 输出）和 `snn_soc_v2b_top`
// 的自定义 cmd/rsp 总线之间做协议适配。
//
// 【v2b_top 读时序真相（rtl/top/snn_soc_v2b_top.sv:422-466）】
//   `rsp_valid <= cmd_valid`：rsp_valid 永远 N+1 拉起，直接 registered。
//   `rsp_rdata <= read_mux`（registered 一拍）：
//     - 直接寄存器（CFG*/STATUS/...）：read_mux 在 N 已经正确（cmd_addr 驱动）。
//       rsp_rdata @ N+1 正确，且因为 cmd_addr 保持，@ N+2 仍然正确。
//     - 间接 SBA/SBB (0x400/0x800)：read_mux 在 N 默认为 0（cmd_read_sb*_q
//       还没 register）；N+1 cmd_read_sb*_q=1 → read_mux=sbX_rd_data；N+1 的
//       rsp_rdata(next cycle) 锁存正确值。**但 N+2 的 active region 采样前，
//       cmd_read_sb*_q 会回落成 0**（因为 cmd_valid=0 时 cmd_read_sb*=0），
//       所以 rsp_rdata 在 N+2 (active-before-NBA) 依然是正确的最后一拍，
//       N+3 就被覆写成 0 了。
//   → 结论：rsp_rdata 在 **N+2 的 active region** 采样最稳定 —— 既覆盖直接
//     寄存器（N+1 就对且保持），又覆盖 SBA/SBB（N+1 的 NBA 写入，N+2 active
//     采到，N+3 才被覆盖）。
//
// 【关键细节：cmd_addr 必须"粘住"】
//   `read_mux` 是组合逻辑，case on cmd_addr。如果 cmd_addr 在读事务中途被
//   adapter 清零，`read_mux` 就会跳回 default 分支 → rsp_rdata 被覆写为
//   意外值。现有 tb/fw_cosim_resident_14x14_tb.sv 的 bus_read 其实就是
//   「驱动 cmd_addr<=addr，只在下一拍把 cmd_valid<=0 but **cmd_addr 不变**」
//   这份 adapter 通过把 m_addr/m_write/m_wdata/m_wstrb 在 ADP_IDLE 落拍那一
//   拍 latch 成 `q_*` 寄存器，随后几个等待拍都用 `q_*` 驱动 cmd_*，保持
//   cmd_addr 稳定。
//
// 【Adapter 4-state FSM】
//   ADP_IDLE (N):     m_valid=1 → cmd_valid=1 用 live m_* 信号；
//                     同拍 latch q_*；→ ADP_WR_ACK 或 ADP_RD_WAIT
//   ADP_WR_ACK (N+1): m_ready=1，完成写握手；→ ADP_IDLE
//   ADP_RD_WAIT (N+1): cmd_valid=0, cmd_addr=q_addr（粘住）；→ ADP_RD_DONE
//   ADP_RD_DONE (N+2): m_rvalid=1, m_rdata=rsp_rdata（这一拍 active-before-NBA
//                     正是 N+1 NBA 刚写入的正确值）；→ ADP_IDLE
//
//   读总 adapter 侧延迟 = 2 cycle（N 发请求，N+2 m_rvalid）
//   写总 adapter 侧延迟 = 1 cycle（N 发请求，N+1 m_ready）
//   bridge 侧再加 1 cycle 到 AXI B/R 响应。
//
// 【地址窗口】bridge 的 addr_mapped() 已保证 `m_addr` 在 ADDR_V2B_BASE/END 内；
// adapter 直接取低 12 bit 给 v2b_top 的 cmd_addr。
//======================================================================
module simple2v2btop_adapter (
  input  logic        clk,
  input  logic        rst_n,

  // ── Slave side: 来自 axi2simple_bridge ──────────────────────────────
  input  logic        m_valid,
  input  logic        m_write,
  input  logic [31:0] m_addr,
  input  logic [31:0] m_wdata,
  input  logic [3:0]  m_wstrb,
  output logic        m_ready,
  output logic [31:0] m_rdata,
  output logic        m_rvalid,

  // ── Master side: snn_soc_v2b_top cmd/rsp ────────────────────────────
  output logic        cmd_valid,
  output logic        cmd_write,
  output logic [11:0] cmd_addr,
  output logic [31:0] cmd_wdata,
  output logic [3:0]  cmd_wstrb,
  input  logic        cmd_ready,
  input  logic        rsp_valid,
  input  logic [31:0] rsp_rdata
);

  // silence unused lint — we rely on fixed-latency sequencing instead of
  // cmd_ready / rsp_valid handshake (v2b_top is always-ready, rsp_valid is
  // registered cmd_valid which is unreliable for SBA/SBB window).
  wire _unused_cmd_ready = cmd_ready;
  wire _unused_rsp_valid = rsp_valid;

  typedef enum logic [1:0] {
    ADP_IDLE    = 2'd0,
    ADP_WR_ACK  = 2'd1,
    ADP_RD_WAIT = 2'd2,
    ADP_RD_DONE = 2'd3
  } adp_state_t;

  adp_state_t state, next_state;

  // Latched cmd_* (captured at posedge when ADP_IDLE && m_valid) so that
  // cmd_addr / cmd_write / cmd_wdata / cmd_wstrb stay stable through the
  // whole transaction. Without this, v2b_top's combinational read_mux
  // snaps back to default and rsp_rdata gets overwritten.
  logic        q_write;
  logic [11:0] q_addr;
  logic [31:0] q_wdata;
  logic [3:0]  q_wstrb;

  // ── Combinational outputs ────────────────────────────────────────────
  // 用 `always @*` 而不是 `always_comb`，规避 Icarus 对 always_comb 中常量
  // 位选的严格检查（`m_addr[11:0]` 在 always_comb 会报 "constant selects"）。
  logic [11:0] addr_low;
  assign addr_low = m_addr[11:0];

  always @* begin
    // Defaults (non-IDLE): drive cmd_* from latched q_* so cmd_addr stays.
    m_ready   = 1'b0;
    m_rvalid  = 1'b0;
    cmd_valid = 1'b0;
    cmd_write = q_write;
    cmd_addr  = q_addr;
    cmd_wdata = q_wdata;
    cmd_wstrb = q_wstrb;

    case (state)
      ADP_IDLE: begin
        if (m_valid) begin
          // During the IDLE cycle with m_valid, q_* has not yet been latched
          // via NBA (only takes effect next posedge). Drive cmd_* from the
          // live m_* signals so v2b_top samples the right address/data.
          cmd_valid = 1'b1;
          cmd_write = m_write;
          cmd_addr  = addr_low;
          cmd_wdata = m_wdata;
          cmd_wstrb = m_wstrb;
        end
      end
      ADP_WR_ACK:  m_ready  = 1'b1;
      ADP_RD_WAIT: ;  // hold cmd_addr via q_addr, wait 1 cycle
      ADP_RD_DONE: m_rvalid = 1'b1;
      default: ;
    endcase
  end

  // m_rdata 在 ADP_RD_DONE 状态直接透传 rsp_rdata。此拍 active-before-NBA
  // 采样到的正是 v2b_top 在 N+1 刚 latch 进去的正确 read_mux。
  assign m_rdata = rsp_rdata;

  // ── Next-state ───────────────────────────────────────────────────────
  always @* begin
    next_state = state;
    case (state)
      ADP_IDLE: begin
        if (m_valid) begin
          if (m_write) next_state = ADP_WR_ACK;
          else         next_state = ADP_RD_WAIT;
        end
      end
      ADP_WR_ACK:  next_state = ADP_IDLE;
      ADP_RD_WAIT: next_state = ADP_RD_DONE;
      ADP_RD_DONE: next_state = ADP_IDLE;
      default:     next_state = ADP_IDLE;
    endcase
  end

  // ── Sequential ──────────────────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state   <= ADP_IDLE;
      q_write <= 1'b0;
      q_addr  <= 12'd0;
      q_wdata <= 32'd0;
      q_wstrb <= 4'd0;
    end else begin
      state <= next_state;
      if (state == ADP_IDLE && m_valid) begin
        q_write <= m_write;
        q_addr  <= addr_low;
        q_wdata <= m_wdata;
        q_wstrb <= m_wstrb;
      end
    end
  end

  // ── Simulation assertions (VCS only) ────────────────────────────────
`ifndef SYNTHESIS
`ifdef VCS
  property no_simultaneous_ready_rvalid;
    @(posedge clk) disable iff (!rst_n)
      !(m_ready && m_rvalid);
  endproperty
  a_exclusive: assert property (no_simultaneous_ready_rvalid)
    else $error("[simple2v2btop_adapter] m_ready && m_rvalid same cycle");
`endif
`endif

endmodule
