`timescale 1ns/1ps
//======================================================================
// 文件名: rtl/bus/axi2simple_bridge.sv
// 模块名: axi2simple_bridge
//
// 【功能概述】
// AXI4-Lite slave → bus_simple master 协议转换桥。
// 接收来自 CPU（E203）或 Testbench BFM 的 AXI4-Lite 事务，
// 转换为 bus_simple_if 协议后驱动 bus_interconnect 的主机端口。
//
// 【接口说明】
//   左侧：AXI4-Lite slave（平铺信号，s_* 前缀，兼容 Icarus/VCS）
//   右侧：bus_simple master（m_* 前缀，连接 bus_interconnect）
//
// 【时序特性】
//   bus_simple_if 固定 1-cycle 延迟：
//     Cycle N  : m_valid=1，发起请求
//     Cycle N+1: m_ready=1（写）或 m_rvalid=1（读），响应到来
//   AXI-Lite 总事务延迟（从请求发出到 B/R 响应）= 2 个时钟周期
//
// 【FSM 状态说明】
//   ST_IDLE    : 等待 AXI-Lite 事务（写：AW/W 可错拍；读：无写半事务时接收 AR）
//   ST_WR_PEND : 写请求已发至 simple bus，等待 m_ready（固定 1 拍）
//   ST_WR_RSP  : m_ready 收到，保持 BVALID=1，等待 master BREADY
//   ST_RD_PEND : 读请求已发至 simple bus，等待 m_rvalid（固定 1 拍）
//   ST_RD_RSP  : m_rvalid 收到，保持 RVALID=1，等待 master RREADY
//
// 【写事务时序（写优先，支持 AW/W 错拍）】
//   - 若 AW 和 W 同拍到达：当拍发 m_valid，后续与原方案一致
//   - 若 AW/W 错拍到达：先缓存先到的一侧，另一侧到达后再发 m_valid
//   Cycle N  : IDLE，写地址/写数据均齐备 → m_valid=1（组合）
//   Cycle N+1: ST_WR_PEND，m_ready=1 → state→ST_WR_RSP
//   Cycle N+2: ST_WR_RSP，BVALID=1，BREADY=1 → state→ST_IDLE
//
// 【读事务时序】
//   Cycle N  : IDLE，ARVALID=1 且无写半事务挂起 → m_valid=1（组合），ARREADY=1
//   Cycle N+1: ST_RD_PEND，m_rvalid=1 → rdata_reg=m_rdata，state→ST_RD_RSP
//   Cycle N+2: ST_RD_RSP，RVALID=1，RREADY=1 → state→ST_IDLE
//
// 【升级路径】
//   V2：将本模块端口从平铺信号改为 axi_lite_if.slave modport，
//       并在 snn_soc_top.sv 顶层暴露 AXI-Lite slave 端口供 E203 接入。
//======================================================================

module axi2simple_bridge (
  input  logic        clk,
  input  logic        rst_n,

  // ── AXI4-Lite Slave 侧（平铺信号，s_ 前缀）──────────────────────────────
  // 写地址通道
  input  logic        s_awvalid,  // Master 写地址有效
  output logic        s_awready,  // Slave（本模块）接受写地址
  input  logic [31:0] s_awaddr,   // 写目标地址

  // 写数据通道
  input  logic        s_wvalid,   // Master 写数据有效
  output logic        s_wready,   // Slave 接受写数据
  input  logic [31:0] s_wdata,    // 写数据
  input  logic [3:0]  s_wstrb,    // 字节写使能

  // 写响应通道
  output logic        s_bvalid,   // Slave 写响应有效
  input  logic        s_bready,   // Master 接受写响应
  output logic [1:0]  s_bresp,    // 响应码（2'b00=OKAY）

  // 读地址通道
  input  logic        s_arvalid,  // Master 读地址有效
  output logic        s_arready,  // Slave 接受读地址
  input  logic [31:0] s_araddr,   // 读目标地址

  // 读数据通道
  output logic        s_rvalid,   // Slave 读数据有效
  input  logic        s_rready,   // Master 接受读数据
  output logic [31:0] s_rdata,    // 读返回数据
  output logic [1:0]  s_rresp,    // 响应码（2'b00=OKAY）

  // ── bus_simple Master 侧（m_ 前缀，连接 bus_interconnect）────────────────
  output logic        m_valid,    // 请求有效（高=本拍有读/写请求）
  output logic        m_write,    // 请求类型：1=写，0=读
  output logic [31:0] m_addr,     // 目标字节地址（全局地址）
  output logic [31:0] m_wdata,    // 写数据（m_write=1 时有效）
  output logic [3:0]  m_wstrb,    // 字节写使能
  input  logic        m_ready,    // 写完成（m_valid 后固定 1 拍）
  input  logic [31:0] m_rdata,    // 读返回数据
  input  logic        m_rvalid    // 读数据有效（m_valid 后固定 1 拍）
);

  // ── FSM 状态定义 ──────────────────────────────────────────────────────────
  typedef enum logic [2:0] {
    ST_IDLE    = 3'd0,
    ST_WR_PEND = 3'd1,
    ST_WR_RSP  = 3'd2,
    ST_RD_PEND = 3'd3,
    ST_RD_RSP  = 3'd4
  } state_t;

  state_t      state;
  logic [31:0] rdata_reg;  // 暂存 simple bus 的读数据（m_rvalid 拍捕获）

  // ── 写地址/写数据 1-entry 暂存（支持 AW/W 错拍）──────────────────────────
  logic        aw_pending, w_pending;
  logic [31:0] awaddr_pending, wdata_pending;
  logic [3:0]  wstrb_pending;

  // ── 握手与请求发起条件（组合逻辑）────────────────────────────────────────
  logic        aw_hs, w_hs, ar_hs;
  logic        wr_aw_have, wr_w_have;
  logic        fire_wr, fire_rd;
  logic [31:0] wr_addr_eff, wr_data_eff;
  logic [3:0]  wr_wstrb_eff;

  // 仅在 IDLE 才接受新的 AXI-Lite 地址/数据通道请求
  assign s_awready = (state == ST_IDLE) && !aw_pending;
  assign s_wready  = (state == ST_IDLE) && !w_pending;
  // 读通道仅在“没有任何写半事务挂起”时开放，保证写优先且避免乱序
  assign s_arready = (state == ST_IDLE) && !aw_pending && !w_pending && !s_awvalid && !s_wvalid;

  assign aw_hs = s_awvalid && s_awready;
  assign w_hs  = s_wvalid  && s_wready;
  assign ar_hs = s_arvalid && s_arready;

  // 写请求可发起条件：地址与数据都已齐备（来自 pending 或本拍握手）
  assign wr_aw_have = aw_pending || aw_hs;
  assign wr_w_have  = w_pending  || w_hs;
  assign fire_wr    = (state == ST_IDLE) && wr_aw_have && wr_w_have;
  assign fire_rd    = ar_hs;

  // 发起写请求时使用“有效地址/数据”（优先用 pending，其次用本拍 AXI 输入）
  assign wr_addr_eff  = aw_pending ? awaddr_pending : s_awaddr;
  assign wr_data_eff  = w_pending  ? wdata_pending  : s_wdata;
  assign wr_wstrb_eff = w_pending  ? wstrb_pending  : s_wstrb;

  // ── bus_simple 主机输出（组合逻辑）──────────────────────────────────────
  // m_valid 在请求发起同一拍驱动（cycle N），
  // bus_interconnect 寄存一拍后在 cycle N+1 产生 m_ready/m_rvalid
  assign m_valid = fire_wr || fire_rd;
  assign m_write = fire_wr;
  assign m_addr  = fire_wr ? wr_addr_eff : s_araddr;
  assign m_wdata = wr_data_eff;
  assign m_wstrb = fire_wr ? wr_wstrb_eff : 4'b0;

  // ── AXI-Lite 响应通道（组合，从状态机输出）──────────────────────────────
  assign s_bvalid = (state == ST_WR_RSP);
  assign s_bresp  = 2'b00;  // OKAY（V1 不产生错误响应）
  assign s_rvalid = (state == ST_RD_RSP);
  assign s_rdata  = rdata_reg;
  assign s_rresp  = 2'b00;  // OKAY

  // ── FSM 状态寄存器 ────────────────────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= ST_IDLE;
      rdata_reg <= 32'h0;
      aw_pending <= 1'b0;
      w_pending  <= 1'b0;
      awaddr_pending <= 32'h0;
      wdata_pending  <= 32'h0;
      wstrb_pending  <= 4'h0;
    end else begin
      case (state)
        //----------------------------------------------------------------
        // ST_IDLE：等待事务
        //   写：AW/W 可同拍或错拍；两者齐备后发 simple bus 请求，转 ST_WR_PEND
        //   读：仅在无写半事务挂起时接收 AR，转 ST_RD_PEND
        //----------------------------------------------------------------
        ST_IDLE: begin
          // 先缓存“半个写事务”（地址或数据）
          if (aw_hs && !fire_wr) begin
            aw_pending     <= 1'b1;
            awaddr_pending <= s_awaddr;
          end
          if (w_hs && !fire_wr) begin
            w_pending     <= 1'b1;
            wdata_pending <= s_wdata;
            wstrb_pending <= s_wstrb;
          end

          // 写优先：地址+数据齐备即可发起 simple bus 写请求
          if (fire_wr) begin
            state      <= ST_WR_PEND;
            aw_pending <= 1'b0;  // 当前写事务已消耗地址
            w_pending  <= 1'b0;  // 当前写事务已消耗数据
          end else if (fire_rd) begin
            state <= ST_RD_PEND;
          end
        end

        //----------------------------------------------------------------
        // ST_WR_PEND：simple bus 写请求已发（cycle N），等待 m_ready（cycle N+1）
        //   bus_interconnect 固定 1-cycle 延迟，m_ready 应在本状态第一拍到来
        //----------------------------------------------------------------
        ST_WR_PEND: begin
          if (m_ready) state <= ST_WR_RSP;
        end

        //----------------------------------------------------------------
        // ST_WR_RSP：m_ready 收到，BVALID=1，等待 master BREADY
        //----------------------------------------------------------------
        ST_WR_RSP: begin
          if (s_bready) state <= ST_IDLE;
        end

        //----------------------------------------------------------------
        // ST_RD_PEND：simple bus 读请求已发（cycle N），等待 m_rvalid（cycle N+1）
        //   m_rvalid 到来时同步捕获 m_rdata 到 rdata_reg
        //----------------------------------------------------------------
        ST_RD_PEND: begin
          if (m_rvalid) begin
            rdata_reg <= m_rdata;
            state     <= ST_RD_RSP;
          end
        end

        //----------------------------------------------------------------
        // ST_RD_RSP：m_rvalid 收到，RVALID=1，等待 master RREADY
        //----------------------------------------------------------------
        ST_RD_RSP: begin
          if (s_rready) state <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

  // ── 仿真断言（仅 VCS，Icarus 用 -gno-assertions 跳过）──────────────────
  `ifndef SYNTHESIS
  `ifdef VCS
    // m_ready 只能在 ST_WR_PEND 状态出现
    property p_ready_in_wr_pend;
      @(posedge clk) disable iff (!rst_n)
      m_ready |-> (state == ST_WR_PEND);
    endproperty
    a_ready_in_wr_pend: assert property (p_ready_in_wr_pend)
      else $error("[AXI_BRIDGE] m_ready asserted outside ST_WR_PEND (state=%0d)", state);

    // m_rvalid 只能在 ST_RD_PEND 状态出现
    property p_rvalid_in_rd_pend;
      @(posedge clk) disable iff (!rst_n)
      m_rvalid |-> (state == ST_RD_PEND);
    endproperty
    a_rvalid_in_rd_pend: assert property (p_rvalid_in_rd_pend)
      else $error("[AXI_BRIDGE] m_rvalid asserted outside ST_RD_PEND (state=%0d)", state);

    // BVALID 只在 ST_WR_RSP 拉高
    property p_bvalid_in_wr_rsp;
      @(posedge clk) disable iff (!rst_n)
      s_bvalid |-> (state == ST_WR_RSP);
    endproperty
    a_bvalid_in_wr_rsp: assert property (p_bvalid_in_wr_rsp)
      else $error("[AXI_BRIDGE] BVALID unexpected (state=%0d)", state);

    // RVALID 只在 ST_RD_RSP 拉高
    property p_rvalid_in_rd_rsp;
      @(posedge clk) disable iff (!rst_n)
      s_rvalid |-> (state == ST_RD_RSP);
    endproperty
    a_rvalid_in_rd_rsp: assert property (p_rvalid_in_rd_rsp)
      else $error("[AXI_BRIDGE] RVALID unexpected (state=%0d)", state);
  `endif
  `endif

endmodule
