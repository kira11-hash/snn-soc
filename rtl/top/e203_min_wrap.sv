`timescale 1ns/1ps
`ifdef SOC_ENABLE_E203_VENDOR
`include "e203_defines.v"
`endif
//======================================================================
// 文件名: e203_min_wrap.sv
// 模块名: e203_min_wrap
//
// 【功能概述】
// 蜂鸟 E203 RISC-V CPU 核的最小化封装。
// 将 E203 vendor IP 的复杂接口（PPI、CLINT、FIO 等多个 ICB 端口）
// 归并到单一的 mem_icb 端口，由下游 icb2simple_bridge 转换为
// simple bus 协议。
//
// 【编译开关】
// - SOC_ENABLE_E203_VENDOR：启用真实 E203 IP 实例化
//   - 无此宏时：使用行为模型（仿真用最小 CPU 替身）
//
// 【CPU 复位】
// core_rst_n = rst_n & cpu_local_rst_n
// - rst_n：全局系统复位
// - cpu_local_rst_n：CPU 局部复位（由 JTAG cpu_reset_hold 控制）
// 局部复位只影响 CPU 核，不影响 SRAM/DMA/外设
//======================================================================
module e203_min_wrap (
  input  logic        clk,              // 系统时钟
  input  logic        rst_n,            // 全局复位
  input  logic        cpu_local_rst_n,  // CPU 局部复位（JTAG 控制）
  output logic [31:0] inspect_pc,       // 当前 PC（调试观察用）
  output logic        core_wfi,         // CPU 进入 WFI（等待中断）

  // ── ICB 主机端口（连接 icb2simple_bridge）──────────────────────────
  output logic        mem_icb_cmd_valid,   // 命令有效
  input  logic        mem_icb_cmd_ready,   // 命令就绪
  output logic [31:0] mem_icb_cmd_addr,    // 命令地址
  output logic        mem_icb_cmd_read,    // 1=读，0=写
  output logic [31:0] mem_icb_cmd_wdata,   // 写数据
  output logic [3:0]  mem_icb_cmd_wmask,   // 字节写使能
  input  logic        mem_icb_rsp_valid,   // 响应有效
  output logic        mem_icb_rsp_ready,   // 响应就绪
  input  logic        mem_icb_rsp_err,     // 响应错误
  input  logic [31:0] mem_icb_rsp_rdata    // 响应读数据
);
  // CPU 实际复位 = 全局复位 AND 局部复位
  // cpu_local_rst_n 由 JTAG rescue 的 cpu_reset_hold 控制，
  // 允许在不影响 SRAM/DMA/外设的情况下单独复位 CPU 核
  wire core_rst_n = rst_n & cpu_local_rst_n;

  // ═══════════════════════════════════════════════════════════════════════
  // 真实 E203 IP 实例化路径（需 SOC_ENABLE_E203_VENDOR 编译宏）
  //
  // E203 核有 5 个 ICB 主端口，按地址空间分区：
  //   mem_icb   : 主存储空间（0x0000_0000 ~ 0x7FFF_FFFF）→ 本 SoC 实际使用
  //   ppi_icb   : Private Peripheral 空间               → 未使用，接 err_slave
  //   clint_icb : Core-Local Interrupt Timer 空间        → 未使用，接 err_slave
  //   plic_icb  : Platform-Level Interrupt 空间          → 未使用，接 err_slave
  //   fio_icb   : Fast IO 空间                           → 未使用，接 err_slave
  //
  // 未使用的 4 个端口全部接到 icb_err_slave，确保 CPU 误访问时
  // 不会死锁，而是收到 bus error 进入异常处理。
  // ═══════════════════════════════════════════════════════════════════════
`ifdef SOC_ENABLE_E203_VENDOR
  // ── PPI ICB 端口信号（Private Peripheral Interface）────────────────────
  logic        ppi_icb_cmd_valid;
  logic        ppi_icb_cmd_ready;
  logic [31:0] ppi_icb_cmd_addr;
  logic        ppi_icb_cmd_read;
  logic [31:0] ppi_icb_cmd_wdata;
  logic [3:0]  ppi_icb_cmd_wmask;
  logic        ppi_icb_rsp_valid;
  logic        ppi_icb_rsp_ready;
  logic        ppi_icb_rsp_err;
  logic [31:0] ppi_icb_rsp_rdata;

  // ── CLINT ICB 端口信号（Core-Local Interrupt Timer）────────────────────
  logic        clint_icb_cmd_valid;
  logic        clint_icb_cmd_ready;
  logic [31:0] clint_icb_cmd_addr;
  logic        clint_icb_cmd_read;
  logic [31:0] clint_icb_cmd_wdata;
  logic [3:0]  clint_icb_cmd_wmask;
  logic        clint_icb_rsp_valid;
  logic        clint_icb_rsp_ready;
  logic        clint_icb_rsp_err;
  logic [31:0] clint_icb_rsp_rdata;

  // ── PLIC ICB 端口信号（Platform-Level Interrupt Controller）────────────
  logic        plic_icb_cmd_valid;
  logic        plic_icb_cmd_ready;
  logic [31:0] plic_icb_cmd_addr;
  logic        plic_icb_cmd_read;
  logic [31:0] plic_icb_cmd_wdata;
  logic [3:0]  plic_icb_cmd_wmask;
  logic        plic_icb_rsp_valid;
  logic        plic_icb_rsp_ready;
  logic        plic_icb_rsp_err;
  logic [31:0] plic_icb_rsp_rdata;

  // ── FIO ICB 端口信号（Fast IO）───────────────────────────────────────
  logic        fio_icb_cmd_valid;
  logic        fio_icb_cmd_ready;
  logic [31:0] fio_icb_cmd_addr;
  logic        fio_icb_cmd_read;
  logic [31:0] fio_icb_cmd_wdata;
  logic [3:0]  fio_icb_cmd_wmask;
  logic        fio_icb_rsp_valid;
  logic        fio_icb_rsp_ready;
  logic        fio_icb_rsp_err;
  logic [31:0] fio_icb_rsp_rdata;

  // ── E203 内部调试/中断信号（本 SoC 未使用，仅为接口兼容保留）────────
  logic        inspect_dbg_irq;
  logic        inspect_mem_cmd_valid;
  logic        inspect_mem_cmd_ready;
  logic        inspect_mem_rsp_valid;
  logic        inspect_mem_rsp_ready;
  logic        inspect_core_clk;
  logic        core_csr_clk;
  logic        tm_stop;
  logic        dbg_irq_r;
  logic [31:0] cmt_dpc;
  logic        cmt_dpc_ena;
  logic [2:0]  cmt_dcause;
  logic        cmt_dcause_ena;
  logic        wr_dcsr_ena;
  logic        wr_dpc_ena;
  logic        wr_dscratch_ena;
  logic [31:0] wr_csr_nxt;

  // lint 友好：以上调试信号全部未使用，通过哑线消除告警
  wire _unused = &{1'b0,
                   inspect_dbg_irq,
                   inspect_mem_cmd_valid,
                   inspect_mem_cmd_ready,
                   inspect_mem_rsp_valid,
                   inspect_mem_rsp_ready,
                   inspect_core_clk,
                   core_csr_clk,
                   tm_stop,
                   dbg_irq_r,
                   cmt_dpc,
                   cmt_dpc_ena,
                   cmt_dcause,
                   cmt_dcause_ena,
                   wr_dcsr_ena,
                   wr_dpc_ena,
                   wr_dscratch_ena,
                   wr_csr_nxt};

  // ── E203 CPU 核实例化 ──────────────────────────────────────────────────
  // pc_rtvec = 0x0000_0000：CPU 复位后从指令 SRAM 起始地址取指
  // 调试相关端口（dbg_*）全部接常量 0（无外部调试器接入时的安全默认值）
  // 中断端口（ext_irq_a / sft_irq_a / tmr_irq_a）接 0（V1 无中断源）
  // test_mode = 0：正常运行模式（非 DFT 扫描模式）
  e203_cpu_top u_e203_cpu_top (
    .inspect_pc           (inspect_pc),
    .inspect_dbg_irq      (inspect_dbg_irq),
    .inspect_mem_cmd_valid(inspect_mem_cmd_valid),
    .inspect_mem_cmd_ready(inspect_mem_cmd_ready),
    .inspect_mem_rsp_valid(inspect_mem_rsp_valid),
    .inspect_mem_rsp_ready(inspect_mem_rsp_ready),
    .inspect_core_clk     (inspect_core_clk),
    .core_csr_clk         (core_csr_clk),
    .core_wfi             (core_wfi),
    .tm_stop              (tm_stop),
    .pc_rtvec             (32'h0000_0000),
    .dbg_irq_r            (dbg_irq_r),
    .cmt_dpc              (cmt_dpc),
    .cmt_dpc_ena          (cmt_dpc_ena),
    .cmt_dcause           (cmt_dcause),
    .cmt_dcause_ena       (cmt_dcause_ena),
    .wr_dcsr_ena          (wr_dcsr_ena),
    .wr_dpc_ena           (wr_dpc_ena),
    .wr_dscratch_ena      (wr_dscratch_ena),
    .wr_csr_nxt           (wr_csr_nxt),
    .dcsr_r               (32'h0),
    .dpc_r                (32'h0),
    .dscratch_r           (32'h0),
    .dbg_mode             (1'b0),
    .dbg_halt_r           (1'b0),
    .dbg_step_r           (1'b0),
    .dbg_ebreakm_r        (1'b0),
    .dbg_stopcycle        (1'b0),
    .dbg_irq_a            (1'b0),
    .core_mhartid         (1'b0),
    .ext_irq_a            (1'b0),
    .sft_irq_a            (1'b0),
    .tmr_irq_a            (1'b0),
    .tcm_sd               (1'b0),
    .tcm_ds               (1'b0),
`ifdef E203_HAS_ITCM_EXTITF
    .ext2itcm_icb_cmd_valid(1'b0),
    .ext2itcm_icb_cmd_ready(),
    .ext2itcm_icb_cmd_addr ({`E203_ITCM_ADDR_WIDTH{1'b0}}),
    .ext2itcm_icb_cmd_read (1'b0),
    .ext2itcm_icb_cmd_wdata({`E203_XLEN{1'b0}}),
    .ext2itcm_icb_cmd_wmask({`E203_XLEN_MW{1'b0}}),
    .ext2itcm_icb_rsp_valid(),
    .ext2itcm_icb_rsp_ready(1'b1),
    .ext2itcm_icb_rsp_err  (),
    .ext2itcm_icb_rsp_rdata(),
`endif
`ifdef E203_HAS_DTCM_EXTITF
    .ext2dtcm_icb_cmd_valid(1'b0),
    .ext2dtcm_icb_cmd_ready(),
    .ext2dtcm_icb_cmd_addr ({`E203_DTCM_ADDR_WIDTH{1'b0}}),
    .ext2dtcm_icb_cmd_read (1'b0),
    .ext2dtcm_icb_cmd_wdata({`E203_XLEN{1'b0}}),
    .ext2dtcm_icb_cmd_wmask({`E203_XLEN_MW{1'b0}}),
    .ext2dtcm_icb_rsp_valid(),
    .ext2dtcm_icb_rsp_ready(1'b1),
    .ext2dtcm_icb_rsp_err  (),
    .ext2dtcm_icb_rsp_rdata(),
`endif
    .ppi_icb_cmd_valid    (ppi_icb_cmd_valid),
    .ppi_icb_cmd_ready    (ppi_icb_cmd_ready),
    .ppi_icb_cmd_addr     (ppi_icb_cmd_addr),
    .ppi_icb_cmd_read     (ppi_icb_cmd_read),
    .ppi_icb_cmd_wdata    (ppi_icb_cmd_wdata),
    .ppi_icb_cmd_wmask    (ppi_icb_cmd_wmask),
    .ppi_icb_rsp_valid    (ppi_icb_rsp_valid),
    .ppi_icb_rsp_ready    (ppi_icb_rsp_ready),
    .ppi_icb_rsp_err      (ppi_icb_rsp_err),
    .ppi_icb_rsp_rdata    (ppi_icb_rsp_rdata),
    .clint_icb_cmd_valid  (clint_icb_cmd_valid),
    .clint_icb_cmd_ready  (clint_icb_cmd_ready),
    .clint_icb_cmd_addr   (clint_icb_cmd_addr),
    .clint_icb_cmd_read   (clint_icb_cmd_read),
    .clint_icb_cmd_wdata  (clint_icb_cmd_wdata),
    .clint_icb_cmd_wmask  (clint_icb_cmd_wmask),
    .clint_icb_rsp_valid  (clint_icb_rsp_valid),
    .clint_icb_rsp_ready  (clint_icb_rsp_ready),
    .clint_icb_rsp_err    (clint_icb_rsp_err),
    .clint_icb_rsp_rdata  (clint_icb_rsp_rdata),
    .plic_icb_cmd_valid   (plic_icb_cmd_valid),
    .plic_icb_cmd_ready   (plic_icb_cmd_ready),
    .plic_icb_cmd_addr    (plic_icb_cmd_addr),
    .plic_icb_cmd_read    (plic_icb_cmd_read),
    .plic_icb_cmd_wdata   (plic_icb_cmd_wdata),
    .plic_icb_cmd_wmask   (plic_icb_cmd_wmask),
    .plic_icb_rsp_valid   (plic_icb_rsp_valid),
    .plic_icb_rsp_ready   (plic_icb_rsp_ready),
    .plic_icb_rsp_err     (plic_icb_rsp_err),
    .plic_icb_rsp_rdata   (plic_icb_rsp_rdata),
    .fio_icb_cmd_valid    (fio_icb_cmd_valid),
    .fio_icb_cmd_ready    (fio_icb_cmd_ready),
    .fio_icb_cmd_addr     (fio_icb_cmd_addr),
    .fio_icb_cmd_read     (fio_icb_cmd_read),
    .fio_icb_cmd_wdata    (fio_icb_cmd_wdata),
    .fio_icb_cmd_wmask    (fio_icb_cmd_wmask),
    .fio_icb_rsp_valid    (fio_icb_rsp_valid),
    .fio_icb_rsp_ready    (fio_icb_rsp_ready),
    .fio_icb_rsp_err      (fio_icb_rsp_err),
    .fio_icb_rsp_rdata    (fio_icb_rsp_rdata),
    .mem_icb_cmd_valid    (mem_icb_cmd_valid),
    .mem_icb_cmd_ready    (mem_icb_cmd_ready),
    .mem_icb_cmd_addr     (mem_icb_cmd_addr),
    .mem_icb_cmd_read     (mem_icb_cmd_read),
    .mem_icb_cmd_wdata    (mem_icb_cmd_wdata),
    .mem_icb_cmd_wmask    (mem_icb_cmd_wmask),
    .mem_icb_rsp_valid    (mem_icb_rsp_valid),
    .mem_icb_rsp_ready    (mem_icb_rsp_ready),
    .mem_icb_rsp_err      (mem_icb_rsp_err),
    .mem_icb_rsp_rdata    (mem_icb_rsp_rdata),
    .test_mode            (1'b0),
    .clk                  (clk),
    .rst_n                (core_rst_n)
  );

  // ── 未使用 ICB 端口 → 错误从机 ──────────────────────────────────────
  // 以下 4 个 icb_err_slave 实例确保 CPU 误访问未映射地址空间时
  // 能收到 bus error 而非总线死锁（详见 icb_err_slave.sv 注释）
  icb_err_slave u_ppi_err (
    .clk            (clk),
    .rst_n          (rst_n),
    .i_icb_cmd_valid(ppi_icb_cmd_valid),
    .i_icb_cmd_ready(ppi_icb_cmd_ready),
    .i_icb_cmd_addr (ppi_icb_cmd_addr),
    .i_icb_cmd_read (ppi_icb_cmd_read),
    .i_icb_cmd_wdata(ppi_icb_cmd_wdata),
    .i_icb_cmd_wmask(ppi_icb_cmd_wmask),
    .i_icb_rsp_valid(ppi_icb_rsp_valid),
    .i_icb_rsp_ready(ppi_icb_rsp_ready),
    .i_icb_rsp_err  (ppi_icb_rsp_err),
    .i_icb_rsp_rdata(ppi_icb_rsp_rdata)
  );

  icb_err_slave u_clint_err (
    .clk            (clk),
    .rst_n          (rst_n),
    .i_icb_cmd_valid(clint_icb_cmd_valid),
    .i_icb_cmd_ready(clint_icb_cmd_ready),
    .i_icb_cmd_addr (clint_icb_cmd_addr),
    .i_icb_cmd_read (clint_icb_cmd_read),
    .i_icb_cmd_wdata(clint_icb_cmd_wdata),
    .i_icb_cmd_wmask(clint_icb_cmd_wmask),
    .i_icb_rsp_valid(clint_icb_rsp_valid),
    .i_icb_rsp_ready(clint_icb_rsp_ready),
    .i_icb_rsp_err  (clint_icb_rsp_err),
    .i_icb_rsp_rdata(clint_icb_rsp_rdata)
  );

  icb_err_slave u_plic_err (
    .clk            (clk),
    .rst_n          (rst_n),
    .i_icb_cmd_valid(plic_icb_cmd_valid),
    .i_icb_cmd_ready(plic_icb_cmd_ready),
    .i_icb_cmd_addr (plic_icb_cmd_addr),
    .i_icb_cmd_read (plic_icb_cmd_read),
    .i_icb_cmd_wdata(plic_icb_cmd_wdata),
    .i_icb_cmd_wmask(plic_icb_cmd_wmask),
    .i_icb_rsp_valid(plic_icb_rsp_valid),
    .i_icb_rsp_ready(plic_icb_rsp_ready),
    .i_icb_rsp_err  (plic_icb_rsp_err),
    .i_icb_rsp_rdata(plic_icb_rsp_rdata)
  );

  icb_err_slave u_fio_err (
    .clk            (clk),
    .rst_n          (rst_n),
    .i_icb_cmd_valid(fio_icb_cmd_valid),
    .i_icb_cmd_ready(fio_icb_cmd_ready),
    .i_icb_cmd_addr (fio_icb_cmd_addr),
    .i_icb_cmd_read (fio_icb_cmd_read),
    .i_icb_cmd_wdata(fio_icb_cmd_wdata),
    .i_icb_cmd_wmask(fio_icb_cmd_wmask),
    .i_icb_rsp_valid(fio_icb_rsp_valid),
    .i_icb_rsp_ready(fio_icb_rsp_ready),
    .i_icb_rsp_err  (fio_icb_rsp_err),
    .i_icb_rsp_rdata(fio_icb_rsp_rdata)
  );
  // ═══════════════════════════════════════════════════════════════════════
  // 无 E203 IP 时的行为模型（仿真用空 CPU 替身）
  // 所有输出接常量 0，mem_icb 不产生任何事务，
  // 适用于不需要 CPU 参与的仿真场景（如纯 SNN 推理路径测试）
  // ═══════════════════════════════════════════════════════════════════════
`else
  wire _unused_vendor_stub = &{1'b0,
                               clk,
                               rst_n,
                               cpu_local_rst_n,
                               mem_icb_cmd_ready,
                               mem_icb_rsp_valid,
                               mem_icb_rsp_err,
                               mem_icb_rsp_rdata};

  assign inspect_pc        = 32'h0;
  assign core_wfi          = 1'b0;
  assign mem_icb_cmd_valid = 1'b0;
  assign mem_icb_cmd_addr  = 32'h0;
  assign mem_icb_cmd_read  = 1'b0;
  assign mem_icb_cmd_wdata = 32'h0;
  assign mem_icb_cmd_wmask = 4'h0;
  assign mem_icb_rsp_ready = 1'b0;
`endif
endmodule
