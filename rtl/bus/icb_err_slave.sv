`timescale 1ns/1ps
//======================================================================
// 文件名: icb_err_slave.sv
// 模块名: icb_err_slave
//
// 【功能概述】
// ICB 总线错误从机（Error Slave）。
// 对任何发到本模块的 ICB 事务，无条件返回 bus error 响应（rsp_err=1）。
//
// 【存在意义】
// 蜂鸟 E203 RISC-V 核有 4 个 ICB 主端口（PPI / CLINT / PLIC / FIO），
// 但本 SoC 只使用 mem_icb 统一路由到 bus_interconnect。
// 其余 3 个端口必须有合法的 ICB 响应端，否则 CPU 访问这些地址空间时
// 总线会永久挂死（cmd_ready 永远不拉高）。
// 本模块就是这些未使用 ICB 端口的"黑洞"：接受请求、返回错误、不做任何操作。
//
// 【使用位置（e203_min_wrap.sv）】
//   u_ppi_err   : 挂在 PPI ICB 端口（外设中断控制器地址空间）
//   u_clint_err : 挂在 CLINT ICB 端口（核心本地中断控制器地址空间）
//   u_plic_err  : 挂在 PLIC ICB 端口（平台级中断控制器地址空间）
//   u_fio_err   : 挂在 FIO ICB 端口（快速 IO 地址空间）
//
// 【FSM 时序】
//   ST_IDLE → 收到 cmd_valid → ST_RSP → rsp_ready 握手完成 → ST_IDLE
//   整个事务 2 拍完成（1 拍接受命令 + 1 拍返回错误响应）
//
// 【安全考量】
//   CPU 固件若误访问 PPI/CLINT/PLIC/FIO 地址，不会死锁，
//   而是触发 bus error → E203 可进入异常处理（trap）。
//======================================================================
module icb_err_slave (
  input  logic        clk,              // 系统时钟
  input  logic        rst_n,            // 异步低有效复位

  // ── ICB 命令通道（来自 E203 CPU）──────────────────────────────────────
  input  logic        i_icb_cmd_valid,  // 命令有效（CPU 发起读或写）
  output logic        i_icb_cmd_ready,  // 命令就绪（本模块在 IDLE 时接受）
  input  logic [31:0] i_icb_cmd_addr,   // 命令地址（本模块不使用，直接忽略）
  input  logic        i_icb_cmd_read,   // 读/写标志（本模块不区分，统一返回错误）
  input  logic [31:0] i_icb_cmd_wdata,  // 写数据（本模块不使用）
  input  logic [3:0]  i_icb_cmd_wmask,  // 字节写使能（本模块不使用）

  // ── ICB 响应通道（返回给 E203 CPU）────────────────────────────────────
  output logic        i_icb_rsp_valid,  // 响应有效（在 ST_RSP 时置 1）
  input  logic        i_icb_rsp_ready,  // 响应就绪（CPU 确认收到响应）
  output logic        i_icb_rsp_err,    // 响应错误标志（固定为 1 = bus error）
  output logic [31:0] i_icb_rsp_rdata   // 响应读数据（固定为 0，无意义）
);
  // ── FSM 状态定义 ──────────────────────────────────────────────────────
  typedef enum logic {
    ST_IDLE,  // 空闲：等待命令，cmd_ready=1 表示可接受新请求
    ST_RSP    // 响应：持有 rsp_valid=1 + rsp_err=1，等待 CPU 的 rsp_ready 握手
  } state_t;

  state_t state_q;

  // lint 友好：所有命令载荷信号不参与任何逻辑，通过哑线消除告警
  wire _unused = &{1'b0, i_icb_cmd_addr, i_icb_cmd_read, i_icb_cmd_wdata, i_icb_cmd_wmask};

  // ── FSM 时序逻辑 ──────────────────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
    end else begin
      case (state_q)
        // ST_IDLE：收到任意 ICB 命令，立即转入 ST_RSP 准备返回错误
        ST_IDLE: begin
          if (i_icb_cmd_valid) begin
            state_q <= ST_RSP;
          end
        end
        // ST_RSP：等待 CPU 确认（rsp_ready=1），握手完成后回到 IDLE
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

  // ── 输出逻辑（纯组合）────────────────────────────────────────────────
  always_comb begin
    i_icb_cmd_ready = (state_q == ST_IDLE);  // IDLE 时接受新命令
    i_icb_rsp_valid = (state_q == ST_RSP);   // RSP 时持有响应有效
    i_icb_rsp_err   = 1'b1;                  // 永远返回 bus error
    i_icb_rsp_rdata = 32'h0;                 // 读数据无意义，填 0
  end
endmodule
