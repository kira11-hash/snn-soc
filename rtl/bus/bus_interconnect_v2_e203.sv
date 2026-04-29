`timescale 1ns/1ps
// =============================================================================
// 【面试讲解 cheat sheet · bus_interconnect_v2_e203.sv】 —— 设计者视角
//
// 一、它是 v2-fpga-e203 三层桥的"第二层"
//   位置：icb2simple_bridge_v2b → 本模块 → {INSTR_SRAM / DATA_SRAM / UART /
//   V2B adapter}。它把 simple_bus master 的请求按地址分发到 4 个 slave，
//   并把响应 mux 回去。
//
// 二、面试最容易被深问的 2 个点
//   1) 为什么不复用 V1 的 bus_interconnect.sv？
//      V1 fabric 是严格 1-cycle 风格（所有 slave 在 req 寄存后当拍返回
//      rdata + m_ready/m_rvalid）。INSTR/DATA/UART 这种 SRAM-like slave
//      没问题，但 V2B 的 simple2v2btop_adapter 读路径需要固定 2 拍
//      （ADP_RD_WAIT → ADP_RD_DONE 才拉 m_rvalid），跟 V1 协议不兼容。
//      解决：fabric 内部分两种风格——
//      - V1-like slave：本地仿照 V1 fabric 的 cmd 寄存 + 当拍 rdata 返回；
//      - V2B 路径：透传 m_valid 到 adapter（组合路径），等 adapter 自己
//        返回 m_ready (写 1 拍) / m_rvalid (读 2 拍)。
//      这样既不动 V1 fabric（保住 V1 已 tape-out 验证过的代码），又支持
//      V2.B 的多拍响应。
//
//   2) 怎么保证两条路径不会同拍冲突？
//      靠 master (icb2simple_bridge_v2b) 的 "single outstanding" 纪律：
//      ICB bridge 一次只发一笔事务，必须等 m_ready/m_rvalid 才发下一笔。
//      所以 fabric 侧"V1-like 事务 (req_valid_q=1) 与 V2B 事务
//      (v2b_inflight_q=1)" 是天然互斥的——同一拍最多只有一种事务在飞，
//      响应 mux 只需要按当前 inflight flag 选源即可，不需要复杂仲裁。
//      这个简化 fabric 设计的关键依赖：master 是 single-outstanding。
//      如果未来加 multi-outstanding，必须引入 transaction ID + 响应队列。
//
// 三、关键设计指标
//   - INSTR/DATA/UART 路径：1 cycle 写、2 cycle 读（含 cmd 寄存 1 拍）。
//   - V2B 路径：1 cycle 写、3 cycle 读（adapter 自身 2 拍 + fabric 透传）。
//   - 4 段地址窗口由 snn_soc_pkg.sv 的 ADDR_V2E203_* / ADDR_V2B_* 定义；
//     地址窗口外 → decode miss（fabric 不响应，由 master timeout 兜底）。
//
// 四、Corner case
//   - decode miss 行为：本 fabric 不主动报错，假定上游 icb2simple_bridge_v2b
//     已经在白名单拦截。fabric miss 是最后一道兜底——如果 bridge 白名单
//     没拦住（设计错误），事务在 fabric 这里"消失"，master 看不到响应，
//     最终由 ICB master 端 timeout 报 hang。这是设计纵深（defense in
//     depth）：bridge 是主防线，fabric 是兜底，TB watchdog 是第三道。
//   - 写 wstrb 透传到 V1-like slave：SRAM 实现要尊重 wstrb byte mask，
//     fabric 不做组合化简——这是和 v2-arm WSTRB fix 同样的 lesson，对
//     simple_bus master 也成立。
//   - V2B path 的 m_addr 是完整 32-bit，adapter 内部自己截 m_addr[11:0]
//     做 cmd_addr，fabric 不做偏移转换。这条是为了让 fabric 重写其他
//     V2B 模块时端口不变。
// =============================================================================

//======================================================================
// 文件名: rtl/bus/bus_interconnect_v2_e203.sv
// 模块名: bus_interconnect_v2_e203
//
// 【本分支范围】
//   新增于 `feature/v2-fpga-e203` (Phase A-1)。不进 `main` / `v2`。
//   V1 `bus_interconnect.sv` 一字不改（它是固定 1-cycle / 不支持 wait-state）。
//
// 【为什么新写，不复用 V1 `bus_interconnect`】
//   V1 fabric 假设所有 slave 都在 req 寄存后**当拍**返回 rdata + m_ready/
//   m_rvalid，是严格 "cycle 0 发 m_valid / cycle 1 收响应" 风格。
//   V2.B 的 `simple2v2btop_adapter` 读路径需要固定 2 拍（ADP_RD_WAIT→
//   ADP_RD_DONE 才拉 m_rvalid），与 V1 固定 1-cycle 不兼容。
//   本模块给 INSTR/DATA/UART 三个 V1-like slave 沿用 1-cycle 风格，
//   给 V2B adapter 单独走 wait-state 透传。
//
// 【地址窗口（来自 snn_soc_pkg.sv）】
//   INSTR  : ADDR_V2E203_INSTR_BASE..ADDR_V2E203_INSTR_END (0x0000_0000..0x0000_FFFF, 64 KB)
//   DATA   : ADDR_V2E203_DATA_BASE ..ADDR_V2E203_DATA_END  (0x0001_0000..0x0001_1FFF,  8 KB)
//   UART   : ADDR_V2E203_UART_BASE ..ADDR_V2E203_UART_END  (0x0002_0000..0x0002_00FF)
//   V2B    : ADDR_V2B_BASE         ..ADDR_V2B_END          (0xA000_0000..0xA000_0FFF,  4 KB)
//   其他地址 → decode miss，不产生 m_ready/m_rvalid。合法性应由
//   icb2simple_bridge_v2b 白名单提前拦截并返回 ICB error；fabric 这里只
//   作为内部防线，避免误触发任一 slave。
//
// 【协议 & 延迟】
//   - master (bus_simple_if style): single outstanding，m_valid 单拍发起，
//     等 m_ready (写) 或 m_rvalid (读) 返回后才能发下一笔。
//   - V1-like slave (INSTR/DATA/UART)：1-cycle 延迟（cycle 0 m_valid → cycle 1 rdata + m_ready/m_rvalid）
//   - V2B 路径：透传 m_valid 到 adapter（组合路径），等 adapter 返回。
//       write: adapter 在 cycle 1 拉 m_ready（fabric 直接转发给 master）
//       read:  adapter 在 cycle 2 拉 m_rvalid + m_rdata
//
// 【single outstanding 纪律】
//   V1-like 事务（req_valid_q=1 那拍）和 V2B 事务（v2b_inflight_q=1 期间）
//   互斥。因为 master (`icb2simple_bridge_v2b`) 是 single outstanding，
//   只会在收到 m_ready/m_rvalid 后才发下一笔，所以 fabric 侧不需要反压，
//   但需要保证响应 mux 不会同拍两条路径都拉 m_ready/m_rvalid。
//======================================================================
module bus_interconnect_v2_e203 (
  input  logic        clk,
  input  logic        rst_n,

  // ── Master（来自 icb2simple_bridge_v2b）────────────────────────────
  input  logic        m_valid,
  input  logic        m_write,
  input  logic [31:0] m_addr,
  input  logic [31:0] m_wdata,
  input  logic [3:0]  m_wstrb,
  output logic        m_ready,
  output logic [31:0] m_rdata,
  output logic        m_rvalid,

  // ── Slave: INSTR_SRAM（V1-like，固定 1-cycle）─────────────────────
  output logic        instr_req_valid,
  output logic        instr_req_write,
  output logic [31:0] instr_req_addr,   // 本地偏移
  output logic [31:0] instr_req_wdata,
  output logic [3:0]  instr_req_wstrb,
  input  logic [31:0] instr_rdata,

  // ── Slave: DATA_SRAM（V1-like）────────────────────────────────────
  output logic        data_req_valid,
  output logic        data_req_write,
  output logic [31:0] data_req_addr,
  output logic [31:0] data_req_wdata,
  output logic [3:0]  data_req_wstrb,
  input  logic [31:0] data_rdata,

  // ── Slave: UART（V1-like）─────────────────────────────────────────
  output logic        uart_req_valid,
  output logic        uart_req_write,
  output logic [31:0] uart_req_addr,
  output logic [31:0] uart_req_wdata,
  output logic [3:0]  uart_req_wstrb,
  input  logic [31:0] uart_rdata,

  // ── Slave: V2B adapter（wait-state, 透传 master 信号）──────────────
  // adapter 内部截 m_addr[11:0] 做 cmd_addr，fabric 不做偏移转换。
  output logic        v2b_m_valid,
  output logic        v2b_m_write,
  output logic [31:0] v2b_m_addr,
  output logic [31:0] v2b_m_wdata,
  output logic [3:0]  v2b_m_wstrb,
  input  logic        v2b_m_ready,
  input  logic [31:0] v2b_m_rdata,
  input  logic        v2b_m_rvalid
);
  import snn_soc_pkg::*;

  // ── 地址译码（组合，基于 **未寄存** 的 m_addr，用于决定透传 vs 寄存）──
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic in_range(
    input logic [31:0] addr,
    input logic [31:0] base,
    input logic [31:0] last
  );
    in_range = (addr >= base) && (addr <= last);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  wire is_instr_m = in_range(m_addr, ADDR_V2E203_INSTR_BASE, ADDR_V2E203_INSTR_END);
  wire is_data_m  = in_range(m_addr, ADDR_V2E203_DATA_BASE,  ADDR_V2E203_DATA_END);
  wire is_uart_m  = in_range(m_addr, ADDR_V2E203_UART_BASE,  ADDR_V2E203_UART_END);
  wire is_v2b_m   = in_range(m_addr, ADDR_V2B_BASE,          ADDR_V2B_END);

  // ── V2B 路径：m_valid 组合透传（adapter ADP_IDLE 同拍采样）─────────
  assign v2b_m_valid = m_valid && is_v2b_m;
  assign v2b_m_write = m_write;
  assign v2b_m_addr  = m_addr;   // adapter 自己截低 12 位
  assign v2b_m_wdata = m_wdata;
  assign v2b_m_wstrb = m_wstrb;

  // ── V1-like 路径：req 寄存一拍 ─────────────────────────────────────
  logic        req_valid_q;
  logic        req_write_q;
  logic [31:0] req_addr_q;
  logic [31:0] req_wdata_q;
  logic [3:0]  req_wstrb_q;
  logic        req_is_instr_q;
  logic        req_is_data_q;
  logic        req_is_uart_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      req_valid_q    <= 1'b0;
      req_write_q    <= 1'b0;
      req_addr_q     <= 32'h0;
      req_wdata_q    <= 32'h0;
      req_wstrb_q    <= 4'h0;
      req_is_instr_q <= 1'b0;
      req_is_data_q  <= 1'b0;
      req_is_uart_q  <= 1'b0;
    end else begin
      // 仅在 V1-like 命中时寄存；V2B 和 miss 都不进这条路径
      req_valid_q <= m_valid && (is_instr_m || is_data_m || is_uart_m);
      if (m_valid && (is_instr_m || is_data_m || is_uart_m)) begin
        req_write_q    <= m_write;
        req_addr_q     <= m_addr;
        req_wdata_q    <= m_wdata;
        req_wstrb_q    <= m_wstrb;
        req_is_instr_q <= is_instr_m;
        req_is_data_q  <= is_data_m;
        req_is_uart_q  <= is_uart_m;
      end
    end
  end

  // ── V1-like slave 请求分发（当拍）──────────────────────────────────
  assign instr_req_valid = req_valid_q && req_is_instr_q;
  assign data_req_valid  = req_valid_q && req_is_data_q;
  assign uart_req_valid  = req_valid_q && req_is_uart_q;

  assign instr_req_write = req_write_q;
  assign data_req_write  = req_write_q;
  assign uart_req_write  = req_write_q;

  assign instr_req_addr  = req_addr_q - ADDR_V2E203_INSTR_BASE;
  assign data_req_addr   = req_addr_q - ADDR_V2E203_DATA_BASE;
  assign uart_req_addr   = req_addr_q - ADDR_V2E203_UART_BASE;

  assign instr_req_wdata = req_wdata_q;
  assign data_req_wdata  = req_wdata_q;
  assign uart_req_wdata  = req_wdata_q;

  assign instr_req_wstrb = req_wstrb_q;
  assign data_req_wstrb  = req_wstrb_q;
  assign uart_req_wstrb  = req_wstrb_q;

  // ── 响应合并：V1-like 1-cycle 后拉 + V2B 等 adapter ─────────────────
  wire [31:0] v1_rdata = req_is_instr_q ? instr_rdata
                       : req_is_data_q  ? data_rdata
                       : req_is_uart_q  ? uart_rdata
                       : 32'h0;

  wire v1_ready  = req_valid_q &&  req_write_q;
  wire v1_rvalid = req_valid_q && !req_write_q;

  // single outstanding 纪律保证 V1-like 和 V2B 不会同拍都拉
  assign m_ready  = v1_ready  | v2b_m_ready;
  assign m_rvalid = v1_rvalid | v2b_m_rvalid;
  // 读数据 MUX：V2B rvalid 时选 v2b_m_rdata，否则走 V1 path
  assign m_rdata  = v2b_m_rvalid ? v2b_m_rdata : v1_rdata;

`ifndef SYNTHESIS
`ifdef VCS
  // V1-like 和 V2B 路径不应同拍都拉 m_ready 或 m_rvalid
  property no_double_ready;
    @(posedge clk) disable iff (!rst_n)
      !(v1_ready && v2b_m_ready);
  endproperty
  a_no_dbl_rd: assert property (no_double_ready)
    else $error("[bus_interconnect_v2_e203] v1_ready && v2b_m_ready same cycle");

  property no_double_rvalid;
    @(posedge clk) disable iff (!rst_n)
      !(v1_rvalid && v2b_m_rvalid);
  endproperty
  a_no_dbl_rv: assert property (no_double_rvalid)
    else $error("[bus_interconnect_v2_e203] v1_rvalid && v2b_m_rvalid same cycle");

  // m_ready 和 m_rvalid 互斥（写不返回 rdata，读不 ack）
  property no_ready_and_rvalid;
    @(posedge clk) disable iff (!rst_n)
      !(m_ready && m_rvalid);
  endproperty
  a_no_rd_rv: assert property (no_ready_and_rvalid)
    else $error("[bus_interconnect_v2_e203] m_ready && m_rvalid same cycle");
`endif
`endif

endmodule
