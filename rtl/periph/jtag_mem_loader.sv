`timescale 1ns/1ps
//======================================================================
// 文件名: jtag_mem_loader.sv
// 模块名: jtag_mem_loader
//
// 【功能概述】
// JTAG 救援加载器。实现一个独立的 4-wire JTAG TAP 控制器，
// 提供最小化的存储器读写和 CPU 复位控制功能。
// 用于 SPI boot 失败时的救援场景：通过 JTAG 直接写入 SRAM 并
// 局部复位 CPU 从新程序启动。
//
// 【指令集】
// - IDCODE (4'h1)：返回芯片 ID（0xE203_0001）
// - MEMACC (4'h2)：存储器访问（读/写 instr_sram / data_sram / weight_sram）
// - CPUCTL (4'h3)：CPU 控制（cpu_reset_hold 读写）
// - BYPASS (4'hF)：JTAG 旁路
//
// 【跨时钟域处理】
// JTAG 运行在 jtag_tck 域，系统运行在 clk 域。
// 使用 toggle + 2-FF 同步器进行跨域请求传递。
//
// 【安全限制】
// - 只允许访问 3 块 SRAM（instr/data/weight），不开放 MMIO
// - 未映射地址返回 done=1, err=1, rdata=0
// - 支持 cpu_reset_hold（只复位 CPU 核，不复位 SRAM/外设）
//======================================================================
module jtag_mem_loader (
  input  logic        rst_n,            // 系统复位（不受 cpu_reset_hold 影响）
  input  logic        clk,              // 系统时钟

  // ── JTAG 4-wire 接口（外部 pad）────────────────────────────────────
  input  logic        jtag_tck,          // 测试时钟
  input  logic        jtag_tms,          // 测试模式选择
  input  logic        jtag_tdi,          // 测试数据输入
  output logic        jtag_tdo,          // 测试数据输出

  // ── 存储器访问接口（连接 bus_interconnect）─────────────────────────
  output logic        mem_req_pending,   // 有待处理的存储器请求（仲裁用）
  input  logic        mem_req_grant,     // 仲裁器授权
  output logic        mem_m_valid,       // simple bus 请求有效
  output logic        mem_m_write,       // 1=写，0=读
  output logic [31:0] mem_m_addr,        // 存储器地址
  output logic [3:0]  mem_m_wstrb,       // 字节写使能
  output logic [31:0] mem_m_wdata,       // 写数据
  input  logic        mem_m_ready,       // 写响应
  input  logic        mem_m_rvalid,      // 读数据有效
  input  logic [31:0] mem_m_rdata,       // 读数据

  // ── CPU 控制 ──────────────────────────────────────────────────────
  output logic        cpu_reset_hold     // CPU 局部复位保持（1=CPU 被复位）
);
  import snn_soc_pkg::*;

  // ── JTAG 指令编码 ──────────────────────────────────────────────────
  localparam logic [3:0] IR_IDCODE = 4'h1;   // 读芯片 ID
  localparam logic [3:0] IR_MEMACC = 4'h2;   // 存储器访问（69-bit DR）
  localparam logic [3:0] IR_CPUCTL = 4'h3;   // CPU 控制（2-bit DR）
  localparam logic [3:0] IR_BYPASS = 4'hF;   // 旁路

  localparam logic [31:0] IDCODE_VALUE = 32'hE203_0001;  // 自定义芯片 ID

  // ── DR 位宽定义 ───────────────────────────────────────────────────
  localparam int IR_WIDTH        = 4;         // 指令寄存器位宽
  localparam int IDCODE_DR_WIDTH = 32;        // IDCODE 数据寄存器位宽
  localparam int MEMACC_DR_WIDTH = 69;        // MEMACC DR：{rw[68], addr[67:36], wdata[35:4], status[3:0]}
  localparam int CPUCTL_DR_WIDTH = 2;         // CPUCTL DR：{reserved[1], cpu_reset_hold[0]}
  localparam int DR_WIDTH_MAX    = MEMACC_DR_WIDTH;  // 最大 DR 位宽（用于寄存器声明）

  // ── TAP 状态机（标准 IEEE 1149.1 状态图）────────────────────────────
  typedef enum logic [3:0] {
    TAP_TLR     = 4'd0,   // Test-Logic-Reset（TMS=1 连续 5 拍进入）
    TAP_RTI     = 4'd1,   // Run-Test/Idle
    TAP_SEL_DR  = 4'd2,   // Select-DR-Scan
    TAP_CAP_DR  = 4'd3,   // Capture-DR
    TAP_SHIFT_DR= 4'd4,   // Shift-DR（TDI→DR→TDO 移位）
    TAP_EXIT1_DR= 4'd5,   // Exit1-DR
    TAP_PAUSE_DR= 4'd6,   // Pause-DR
    TAP_EXIT2_DR= 4'd7,   // Exit2-DR
    TAP_UPD_DR  = 4'd8,   // Update-DR（锁存 DR 内容，触发操作）
    TAP_SEL_IR  = 4'd9,   // Select-IR-Scan
    TAP_CAP_IR  = 4'd10,  // Capture-IR
    TAP_SHIFT_IR= 4'd11,  // Shift-IR（TDI→IR→TDO 移位）
    TAP_EXIT1_IR= 4'd12,
    TAP_PAUSE_IR= 4'd13,
    TAP_EXIT2_IR= 4'd14,
    TAP_UPD_IR  = 4'd15
  } tap_state_t;

  // ── 系统时钟域的存储器访问状态机 ────────────────────────────────────
  typedef enum logic [1:0] {
    CLK_IDLE       = 2'd0,  // 空闲，等待跨域请求
    CLK_WAIT_GRANT = 2'd1,  // 等待总线仲裁授权
    CLK_ISSUE      = 2'd2,  // 发出 simple bus 请求
    CLK_WAIT_RSP   = 2'd3   // 等待下游响应
  } clk_state_t;

  tap_state_t tap_state_q;
  logic [IR_WIDTH-1:0] ir_q;
  logic [IR_WIDTH-1:0] ir_shift_q;
  logic [DR_WIDTH_MAX-1:0] dr_shift_q;

  logic        mem_req_write_tck;
  logic [31:0] mem_req_addr_tck;
  logic [3:0]  mem_req_wstrb_tck;
  logic [31:0] mem_req_wdata_tck;
  logic        mem_req_outstanding_tck;
  logic        req_toggle_tck;

  logic        cpuctl_hold_tck;
  logic        cpuctl_toggle_tck;

  (* async_reg = "TRUE" *) logic        rsp_toggle_meta_tck;
  (* async_reg = "TRUE" *) logic        rsp_toggle_sync_tck;
  logic        rsp_toggle_seen_tck;
  logic [2:0]  rst_settle_cnt_tck;   // CDC settling guard：复位释放后 4 拍内抑制边沿检测

  logic [31:0] mem_rsp_rdata_tck;
  logic        mem_rsp_err_tck;
  logic        mem_rsp_done_tck;

  (* async_reg = "TRUE" *) logic        req_toggle_meta_clk;
  (* async_reg = "TRUE" *) logic        req_toggle_sync_clk;
  logic        req_toggle_seen_clk;

  (* async_reg = "TRUE" *) logic        cpuctl_toggle_meta_clk;
  (* async_reg = "TRUE" *) logic        cpuctl_toggle_sync_clk;
  logic        cpuctl_toggle_seen_clk;
  logic [2:0]  rst_settle_cnt_clk;   // CDC settling guard：复位释放后 4 拍内抑制边沿检测

  logic [31:0] mem_rsp_rdata_clk;
  logic        mem_rsp_err_clk;
  logic        mem_rsp_done_clk;
  logic        rsp_toggle_clk;

  logic        mem_req_write_clk;
  logic [31:0] mem_req_addr_clk;
  logic [3:0]  mem_req_wstrb_clk;
  logic [31:0] mem_req_wdata_clk;
  clk_state_t  clk_state_q;

  // CLK-side bus timeout: if bus hangs (no grant or no response) for 1023 cycles,
  // force error+done so the rescue module itself doesn't get permanently stuck.
  localparam int CLK_TIMEOUT_MAX = 1023;
  logic [9:0] clk_timeout_cnt;

  function automatic tap_state_t tap_next(
    input tap_state_t cur,
    input logic       tms
  );
    case (cur)
      TAP_TLR:      if (tms) tap_next = TAP_TLR;      else tap_next = TAP_RTI;
      TAP_RTI:      if (tms) tap_next = TAP_SEL_DR;   else tap_next = TAP_RTI;
      TAP_SEL_DR:   if (tms) tap_next = TAP_SEL_IR;   else tap_next = TAP_CAP_DR;
      TAP_CAP_DR:   if (tms) tap_next = TAP_EXIT1_DR; else tap_next = TAP_SHIFT_DR;
      TAP_SHIFT_DR: if (tms) tap_next = TAP_EXIT1_DR; else tap_next = TAP_SHIFT_DR;
      TAP_EXIT1_DR: if (tms) tap_next = TAP_UPD_DR;   else tap_next = TAP_PAUSE_DR;
      TAP_PAUSE_DR: if (tms) tap_next = TAP_EXIT2_DR; else tap_next = TAP_PAUSE_DR;
      TAP_EXIT2_DR: if (tms) tap_next = TAP_UPD_DR;   else tap_next = TAP_SHIFT_DR;
      TAP_UPD_DR:   if (tms) tap_next = TAP_SEL_DR;   else tap_next = TAP_RTI;
      TAP_SEL_IR:   if (tms) tap_next = TAP_TLR;      else tap_next = TAP_CAP_IR;
      TAP_CAP_IR:   if (tms) tap_next = TAP_EXIT1_IR; else tap_next = TAP_SHIFT_IR;
      TAP_SHIFT_IR: if (tms) tap_next = TAP_EXIT1_IR; else tap_next = TAP_SHIFT_IR;
      TAP_EXIT1_IR: if (tms) tap_next = TAP_UPD_IR;   else tap_next = TAP_PAUSE_IR;
      TAP_PAUSE_IR: if (tms) tap_next = TAP_EXIT2_IR; else tap_next = TAP_PAUSE_IR;
      TAP_EXIT2_IR: if (tms) tap_next = TAP_UPD_IR;   else tap_next = TAP_SHIFT_IR;
      TAP_UPD_IR:   if (tms) tap_next = TAP_SEL_DR;   else tap_next = TAP_RTI;
      default:      tap_next = TAP_TLR;
    endcase
  endfunction

  function automatic logic in_range(
    input logic [31:0] addr,
    input logic [31:0] base,
    input logic [31:0] last
  );
    in_range = (addr >= base) && (addr <= last);
  endfunction

  function automatic logic is_sram_addr(input logic [31:0] addr);
    is_sram_addr =
        in_range(addr, ADDR_INSTR_BASE,  ADDR_INSTR_END)  ||
        in_range(addr, ADDR_DATA_BASE,   ADDR_DATA_END)   ||
        in_range(addr, ADDR_WEIGHT_BASE, ADDR_WEIGHT_END);
  endfunction

  always_ff @(posedge jtag_tck or negedge rst_n) begin
    if (!rst_n) begin
      tap_state_q             <= TAP_TLR;
      ir_q                    <= IR_IDCODE;
      ir_shift_q              <= IR_IDCODE;
      dr_shift_q              <= '0;
      mem_req_write_tck       <= 1'b0;
      mem_req_addr_tck        <= 32'h0;
      mem_req_wstrb_tck       <= 4'h0;
      mem_req_wdata_tck       <= 32'h0;
      mem_req_outstanding_tck <= 1'b0;
      req_toggle_tck          <= 1'b0;
      cpuctl_hold_tck         <= 1'b0;
      cpuctl_toggle_tck       <= 1'b0;
      rsp_toggle_meta_tck     <= 1'b0;
      rsp_toggle_sync_tck     <= 1'b0;
      rsp_toggle_seen_tck     <= 1'b0;
      rst_settle_cnt_tck      <= 3'd0;
      mem_rsp_rdata_tck       <= 32'h0;
      mem_rsp_err_tck         <= 1'b0;
      mem_rsp_done_tck        <= 1'b1;
    end else begin
      rsp_toggle_meta_tck <= rsp_toggle_clk;
      rsp_toggle_sync_tck <= rsp_toggle_meta_tck;

      // CDC settling guard：复位释放后前 4 个 jtag_tck 周期内，
      // 强制 seen 跟踪 sync，防止 2-FF 同步器输出未稳定时产生虚假边沿
      if (rst_settle_cnt_tck < 3'd4) begin
        rst_settle_cnt_tck  <= rst_settle_cnt_tck + 3'd1;
        rsp_toggle_seen_tck <= rsp_toggle_sync_tck;
      end

      if (rsp_toggle_sync_tck != rsp_toggle_seen_tck) begin
        rsp_toggle_seen_tck     <= rsp_toggle_sync_tck;
        mem_req_outstanding_tck <= 1'b0;
        mem_rsp_rdata_tck       <= mem_rsp_rdata_clk;
        mem_rsp_err_tck         <= mem_rsp_err_clk;
        mem_rsp_done_tck        <= mem_rsp_done_clk;
      end

      case (tap_state_q)
        TAP_CAP_IR: begin
          ir_shift_q <= 4'b0001;
        end
        TAP_SHIFT_IR: begin
          ir_shift_q <= {jtag_tdi, ir_shift_q[IR_WIDTH-1:1]};
        end
        TAP_UPD_IR: begin
          ir_q <= ir_shift_q;
        end
        TAP_CAP_DR: begin
          dr_shift_q <= '0;
          case (ir_q)
            IR_IDCODE: begin
              dr_shift_q[IDCODE_DR_WIDTH-1:0] <= IDCODE_VALUE;
            end
            IR_MEMACC: begin
              dr_shift_q[31:0] <= mem_rsp_rdata_tck;
              dr_shift_q[32]   <= mem_rsp_err_tck;
              dr_shift_q[33]   <= mem_rsp_done_tck;
            end
            IR_CPUCTL: begin
              dr_shift_q[0] <= cpuctl_hold_tck;
              dr_shift_q[1] <= 1'b0;
            end
            default: begin
              dr_shift_q[0] <= 1'b0;
            end
          endcase
        end
        TAP_SHIFT_DR: begin
          case (ir_q)
            IR_IDCODE: begin
              dr_shift_q[IDCODE_DR_WIDTH-1:0] <=
                  {jtag_tdi, dr_shift_q[IDCODE_DR_WIDTH-1:1]};
            end
            IR_MEMACC: begin
              dr_shift_q[MEMACC_DR_WIDTH-1:0] <=
                  {jtag_tdi, dr_shift_q[MEMACC_DR_WIDTH-1:1]};
            end
            IR_CPUCTL: begin
              dr_shift_q[CPUCTL_DR_WIDTH-1:0] <=
                  {jtag_tdi, dr_shift_q[CPUCTL_DR_WIDTH-1:1]};
            end
            default: begin
              dr_shift_q[0] <= jtag_tdi;
            end
          endcase
        end
        TAP_UPD_DR: begin
          case (ir_q)
            IR_MEMACC: begin
              if (mem_req_outstanding_tck) begin
                mem_rsp_rdata_tck <= 32'h0;
                mem_rsp_err_tck   <= 1'b1;
                mem_rsp_done_tck  <= 1'b1;
              end else begin
                mem_req_write_tck       <= dr_shift_q[0];
                mem_req_addr_tck        <= dr_shift_q[32:1];
                mem_req_wstrb_tck       <= dr_shift_q[36:33];
                mem_req_wdata_tck       <= dr_shift_q[68:37];
                mem_req_outstanding_tck <= 1'b1;
                mem_rsp_rdata_tck       <= 32'h0;
                mem_rsp_err_tck         <= 1'b0;
                mem_rsp_done_tck        <= 1'b0;
                req_toggle_tck          <= ~req_toggle_tck;
              end
            end
            IR_CPUCTL: begin
              cpuctl_hold_tck   <= dr_shift_q[0];
              cpuctl_toggle_tck <= ~cpuctl_toggle_tck;
            end
            default: begin
            end
          endcase
        end
        default: begin
        end
      endcase

      tap_state_q <= tap_next(tap_state_q, jtag_tms);
    end
  end

  always_ff @(negedge jtag_tck or negedge rst_n) begin
    if (!rst_n) begin
      jtag_tdo <= 1'b0;
    end else begin
      case (tap_state_q)
        TAP_SHIFT_IR: jtag_tdo <= ir_shift_q[0];
        TAP_SHIFT_DR: jtag_tdo <= dr_shift_q[0];
        default:      jtag_tdo <= 1'b0;
      endcase
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      req_toggle_meta_clk   <= 1'b0;
      req_toggle_sync_clk   <= 1'b0;
      req_toggle_seen_clk   <= 1'b0;
      cpuctl_toggle_meta_clk<= 1'b0;
      cpuctl_toggle_sync_clk<= 1'b0;
      cpuctl_toggle_seen_clk<= 1'b0;
      mem_rsp_rdata_clk     <= 32'h0;
      mem_rsp_err_clk       <= 1'b0;
      mem_rsp_done_clk      <= 1'b1;
      rsp_toggle_clk        <= 1'b0;
      mem_req_write_clk     <= 1'b0;
      mem_req_addr_clk      <= 32'h0;
      mem_req_wstrb_clk     <= 4'h0;
      mem_req_wdata_clk     <= 32'h0;
      clk_state_q           <= CLK_IDLE;
      cpu_reset_hold        <= 1'b1;  // 上电后 CPU 保持复位，需 JTAG CPUCTL 显式释放
      clk_timeout_cnt       <= '0;
      rst_settle_cnt_clk    <= 3'd0;
    end else begin
      req_toggle_meta_clk    <= req_toggle_tck;
      req_toggle_sync_clk    <= req_toggle_meta_clk;
      cpuctl_toggle_meta_clk <= cpuctl_toggle_tck;
      cpuctl_toggle_sync_clk <= cpuctl_toggle_meta_clk;

      // CDC settling guard：复位释放后前 4 个 clk 周期内，
      // 强制 seen 跟踪 sync，防止 2-FF 同步器输出未稳定时产生虚假边沿
      if (rst_settle_cnt_clk < 3'd4) begin
        rst_settle_cnt_clk     <= rst_settle_cnt_clk + 3'd1;
        req_toggle_seen_clk    <= req_toggle_sync_clk;
        cpuctl_toggle_seen_clk <= cpuctl_toggle_sync_clk;
      end

      if (cpuctl_toggle_sync_clk != cpuctl_toggle_seen_clk) begin
        cpuctl_toggle_seen_clk <= cpuctl_toggle_sync_clk;
        cpu_reset_hold         <= cpuctl_hold_tck;
      end

      case (clk_state_q)
        CLK_IDLE: begin
          if (req_toggle_sync_clk != req_toggle_seen_clk) begin
            req_toggle_seen_clk <= req_toggle_sync_clk;
            mem_req_write_clk   <= mem_req_write_tck;
            mem_req_addr_clk    <= mem_req_addr_tck;
            mem_req_wstrb_clk   <= mem_req_wstrb_tck;
            mem_req_wdata_clk   <= mem_req_wdata_tck;
            if (!is_sram_addr(mem_req_addr_tck)) begin
              mem_rsp_rdata_clk <= 32'h0;
              mem_rsp_err_clk   <= 1'b1;
              mem_rsp_done_clk  <= 1'b1;
              rsp_toggle_clk    <= ~rsp_toggle_clk;
            end else begin
              clk_state_q <= CLK_WAIT_GRANT;
            end
          end
        end
        CLK_WAIT_GRANT: begin
          if (mem_req_grant) begin
            clk_state_q   <= CLK_ISSUE;
            clk_timeout_cnt <= '0;
          end else if (clk_timeout_cnt == CLK_TIMEOUT_MAX[9:0]) begin
            // Bus grant never came — force error response to unblock JTAG
            mem_rsp_rdata_clk <= 32'h0;
            mem_rsp_err_clk   <= 1'b1;
            mem_rsp_done_clk  <= 1'b1;
            rsp_toggle_clk    <= ~rsp_toggle_clk;
            clk_state_q       <= CLK_IDLE;
            clk_timeout_cnt   <= '0;
          end else begin
            clk_timeout_cnt <= clk_timeout_cnt + 10'd1;
          end
        end
        CLK_ISSUE: begin
          clk_state_q     <= CLK_WAIT_RSP;
          clk_timeout_cnt <= '0;
        end
        CLK_WAIT_RSP: begin
          if ((mem_req_write_clk && mem_m_ready) ||
              (!mem_req_write_clk && mem_m_rvalid)) begin
            mem_rsp_rdata_clk <= mem_req_write_clk ? 32'h0 : mem_m_rdata;
            mem_rsp_err_clk   <= 1'b0;
            mem_rsp_done_clk  <= 1'b1;
            rsp_toggle_clk    <= ~rsp_toggle_clk;
            clk_state_q       <= CLK_IDLE;
            clk_timeout_cnt   <= '0;
          end else if (clk_timeout_cnt == CLK_TIMEOUT_MAX[9:0]) begin
            // Bus response never came — force error response
            mem_rsp_rdata_clk <= 32'h0;
            mem_rsp_err_clk   <= 1'b1;
            mem_rsp_done_clk  <= 1'b1;
            rsp_toggle_clk    <= ~rsp_toggle_clk;
            clk_state_q       <= CLK_IDLE;
            clk_timeout_cnt   <= '0;
          end else begin
            clk_timeout_cnt <= clk_timeout_cnt + 10'd1;
          end
        end
        default: begin
          clk_state_q <= CLK_IDLE;
        end
      endcase
    end
  end

  assign mem_req_pending = (clk_state_q != CLK_IDLE);
  assign mem_m_valid     = (clk_state_q == CLK_ISSUE);
  assign mem_m_write     = mem_req_write_clk;
  assign mem_m_addr      = mem_req_addr_clk;
  assign mem_m_wstrb     = mem_req_wstrb_clk;
  assign mem_m_wdata     = mem_req_wdata_clk;
endmodule
