`timescale 1ns/1ps

module e203_min_wrap (
  input  logic        clk,
  input  logic        rst_n,
  output logic [31:0] inspect_pc,
  output logic        core_wfi,
  output logic        mem_icb_cmd_valid,
  input  logic        mem_icb_cmd_ready,
  output logic [31:0] mem_icb_cmd_addr,
  output logic        mem_icb_cmd_read,
  output logic [31:0] mem_icb_cmd_wdata,
  output logic [3:0]  mem_icb_cmd_wmask,
  input  logic        mem_icb_rsp_valid,
  output logic        mem_icb_rsp_ready,
  input  logic        mem_icb_rsp_err,
  input  logic [31:0] mem_icb_rsp_rdata
);
`ifdef SOC_ENABLE_E203_VENDOR
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
    .rst_n                (rst_n)
  );

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
`else
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
