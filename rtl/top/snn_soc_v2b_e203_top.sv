`timescale 1ns/1ps
//======================================================================
// 文件名: rtl/top/snn_soc_v2b_e203_top.sv
// 模块名: snn_soc_v2b_e203_top
//
// 【本分支范围】
//   新增于 `feature/v2-fpga-e203` (Phase A-5)。不进 `main` / `v2`。
//   SoC core 顶层（纯 RTL，不含 MMCM/IBUFDS/LED），供板级 wrapper
//   `snn_soc_v2b_e203_fpga_top` 实例化。
//
// 【集成 stack】
//   e203_min_wrap           (mem_icb master)
//       ↓
//   icb2simple_bridge_v2b   (A-2，白名单只放行 V2E203 4 段 + V2B)
//       ↓
//   bus_interconnect_v2_e203 (A-1，INSTR/DATA/UART 1-cycle + V2B wait-state)
//       ├─ sram_simple × 2  (IMEM 64 KB @ 0x0000_0000 / DMEM 8 KB @ 0x0001_0000)
//       ├─ uart_ctrl        (@ 0x0200_0000)
//       └─ simple2v2btop_adapter (A-3，0 字拷入)
//              ↓ cmd/rsp
//         snn_soc_v2b_top   (V2.B streamed-rate accelerator)
//
// 【参数纪律】只使用 V2E203_* 和 V2B_* 常量；严格不读 V1 的 INSTR_SRAM_BYTES/
//   DATA_SRAM_BYTES/ADDR_INSTR_BASE/ADDR_DATA_BASE/ADDR_REG_BASE/ADDR_UART_BASE。
//
// 【ENABLE_E203 / SOC_ENABLE_E203_VENDOR】
//   功能仿真必须定义 `+define+SOC_ENABLE_E203_VENDOR+FPGA_SOURCE`（见
//   sim/sim_v2_e203.f）。不定义时 e203_min_wrap 使用 stub 分支（mem_icb
//   全 0），co-sim 会失败；不支持。
//======================================================================
module snn_soc_v2b_e203_top #(
  // 固件 hex 预加载（Phase B synth 用 $readmemh 传入；功能仿真时留空，TB
  // 通过分层引用加载）
  parameter string INSTR_INIT_FILE = ""
) (
  input  logic clk,
  input  logic rst_n,

  // UART 物理接口（由板级 wrapper 引出到 CP2108）
  input  logic uart_rx,
  output logic uart_tx
);
  import snn_soc_pkg::*;

  // ================================================================
  // E203 core wrap
  // ================================================================
  logic [31:0] inspect_pc;       // 供 TB / debug，不接板
  logic        core_wfi;

  logic        cpu_mem_icb_cmd_valid;
  logic        cpu_mem_icb_cmd_ready;
  logic [31:0] cpu_mem_icb_cmd_addr;
  logic        cpu_mem_icb_cmd_read;
  logic [31:0] cpu_mem_icb_cmd_wdata;
  logic [3:0]  cpu_mem_icb_cmd_wmask;
  logic        cpu_mem_icb_rsp_valid;
  logic        cpu_mem_icb_rsp_ready;
  logic        cpu_mem_icb_rsp_err;
  logic [31:0] cpu_mem_icb_rsp_rdata;

  e203_min_wrap u_e203 (
    .clk(clk),
    .rst_n(rst_n),
    .cpu_local_rst_n(1'b1),
    .inspect_pc(inspect_pc),
    .core_wfi(core_wfi),
    .mem_icb_cmd_valid(cpu_mem_icb_cmd_valid),
    .mem_icb_cmd_ready(cpu_mem_icb_cmd_ready),
    .mem_icb_cmd_addr (cpu_mem_icb_cmd_addr),
    .mem_icb_cmd_read (cpu_mem_icb_cmd_read),
    .mem_icb_cmd_wdata(cpu_mem_icb_cmd_wdata),
    .mem_icb_cmd_wmask(cpu_mem_icb_cmd_wmask),
    .mem_icb_rsp_valid(cpu_mem_icb_rsp_valid),
    .mem_icb_rsp_ready(cpu_mem_icb_rsp_ready),
    .mem_icb_rsp_err  (cpu_mem_icb_rsp_err),
    .mem_icb_rsp_rdata(cpu_mem_icb_rsp_rdata)
  );

  // ================================================================
  // ICB → simple_bus bridge (V2B variant, 白名单过滤)
  // ================================================================
  logic        br_m_valid;
  logic        br_m_write;
  logic [31:0] br_m_addr;
  logic [31:0] br_m_wdata;
  logic [3:0]  br_m_wstrb;
  logic        br_m_ready;
  logic [31:0] br_m_rdata;
  logic        br_m_rvalid;
  logic        br_busy;

  icb2simple_bridge_v2b u_bridge (
    .clk(clk), .rst_n(rst_n),
    .i_icb_cmd_valid(cpu_mem_icb_cmd_valid),
    .i_icb_cmd_ready(cpu_mem_icb_cmd_ready),
    .i_icb_cmd_addr (cpu_mem_icb_cmd_addr),
    .i_icb_cmd_read (cpu_mem_icb_cmd_read),
    .i_icb_cmd_wdata(cpu_mem_icb_cmd_wdata),
    .i_icb_cmd_wmask(cpu_mem_icb_cmd_wmask),
    .i_icb_rsp_valid(cpu_mem_icb_rsp_valid),
    .i_icb_rsp_ready(cpu_mem_icb_rsp_ready),
    .i_icb_rsp_err  (cpu_mem_icb_rsp_err),
    .i_icb_rsp_rdata(cpu_mem_icb_rsp_rdata),
    .m_valid(br_m_valid), .m_write(br_m_write), .m_addr(br_m_addr),
    .m_wdata(br_m_wdata), .m_wstrb(br_m_wstrb),
    .m_ready(br_m_ready), .m_rdata(br_m_rdata), .m_rvalid(br_m_rvalid),
    .busy_o(br_busy)
  );

  // ================================================================
  // Bus interconnect (V2E203 specific, 4 slave)
  // ================================================================
  logic        instr_req_valid, instr_req_write;
  logic [31:0] instr_req_addr,  instr_req_wdata;
  logic [3:0]  instr_req_wstrb;
  logic [31:0] instr_rdata;

  logic        data_req_valid, data_req_write;
  logic [31:0] data_req_addr,  data_req_wdata;
  logic [3:0]  data_req_wstrb;
  logic [31:0] data_rdata;

  logic        uart_req_valid, uart_req_write;
  logic [31:0] uart_req_addr,  uart_req_wdata;
  logic [3:0]  uart_req_wstrb;
  logic [31:0] uart_rdata;

  logic        v2b_m_valid, v2b_m_write;
  logic [31:0] v2b_m_addr,  v2b_m_wdata;
  logic [3:0]  v2b_m_wstrb;
  logic        v2b_m_ready, v2b_m_rvalid;
  logic [31:0] v2b_m_rdata;

  bus_interconnect_v2_e203 u_fabric (
    .clk(clk), .rst_n(rst_n),
    .m_valid(br_m_valid), .m_write(br_m_write), .m_addr(br_m_addr),
    .m_wdata(br_m_wdata), .m_wstrb(br_m_wstrb),
    .m_ready(br_m_ready), .m_rdata(br_m_rdata), .m_rvalid(br_m_rvalid),
    .instr_req_valid(instr_req_valid), .instr_req_write(instr_req_write),
    .instr_req_addr(instr_req_addr),   .instr_req_wdata(instr_req_wdata),
    .instr_req_wstrb(instr_req_wstrb), .instr_rdata(instr_rdata),
    .data_req_valid(data_req_valid),   .data_req_write(data_req_write),
    .data_req_addr(data_req_addr),     .data_req_wdata(data_req_wdata),
    .data_req_wstrb(data_req_wstrb),   .data_rdata(data_rdata),
    .uart_req_valid(uart_req_valid),   .uart_req_write(uart_req_write),
    .uart_req_addr(uart_req_addr),     .uart_req_wdata(uart_req_wdata),
    .uart_req_wstrb(uart_req_wstrb),   .uart_rdata(uart_rdata),
    .v2b_m_valid(v2b_m_valid), .v2b_m_write(v2b_m_write),
    .v2b_m_addr(v2b_m_addr),   .v2b_m_wdata(v2b_m_wdata),
    .v2b_m_wstrb(v2b_m_wstrb),
    .v2b_m_ready(v2b_m_ready), .v2b_m_rdata(v2b_m_rdata),
    .v2b_m_rvalid(v2b_m_rvalid)
  );

  // ================================================================
  // INSTR_SRAM (64 KB @ 0x0000_0000)
  // Synth 时通过 $readmemh(INSTR_INIT_FILE, mem) 预加载；功能仿真 TB
  // 用分层引用 `u_instr_sram.mem` 直接预装。
  // ================================================================
  sram_simple #(.MEM_BYTES(int'(V2E203_INSTR_BYTES))) u_instr_sram (
    .clk(clk), .rst_n(rst_n),
    .req_valid(instr_req_valid),
    .req_write(instr_req_write),
    .req_addr (instr_req_addr),
    .req_wdata(instr_req_wdata),
    .req_wstrb(instr_req_wstrb),
    .rdata    (instr_rdata),
    .dma_wr_en(1'b0), .dma_wr_addr(32'h0), .dma_wr_data(32'h0), .dma_wr_strb(4'h0)
  );

  // Synth-time $readmemh preload hook（FPGA_SOURCE 下生效，功能仿真也会跑
  // 但 INSTR_INIT_FILE="" 时跳过 $readmemh，由 TB hierarchical load）
  initial begin
    if (INSTR_INIT_FILE != "") begin
      $readmemh(INSTR_INIT_FILE, u_instr_sram.mem);
    end
  end

  // ================================================================
  // DATA_SRAM (8 KB @ 0x0001_0000)
  // ================================================================
  sram_simple #(.MEM_BYTES(int'(V2E203_DATA_BYTES))) u_data_sram (
    .clk(clk), .rst_n(rst_n),
    .req_valid(data_req_valid),
    .req_write(data_req_write),
    .req_addr (data_req_addr),
    .req_wdata(data_req_wdata),
    .req_wstrb(data_req_wstrb),
    .rdata    (data_rdata),
    .dma_wr_en(1'b0), .dma_wr_addr(32'h0), .dma_wr_data(32'h0), .dma_wr_strb(4'h0)
  );

  // ================================================================
  // UART (@ 0x0200_0000)
  // ================================================================
  uart_ctrl u_uart (
    .clk(clk), .rst_n(rst_n),
    .req_valid(uart_req_valid),
    .req_write(uart_req_write),
    .req_addr (uart_req_addr),
    .req_wdata(uart_req_wdata),
    .req_wstrb(uart_req_wstrb),
    .rdata    (uart_rdata),
    .uart_rx  (uart_rx),
    .uart_tx  (uart_tx)
  );

  // ================================================================
  // V2B adapter + snn_soc_v2b_top
  // ================================================================
  logic        v2b_cmd_valid, v2b_cmd_write;
  logic [11:0] v2b_cmd_addr;
  logic [31:0] v2b_cmd_wdata;
  logic [3:0]  v2b_cmd_wstrb;
  logic        v2b_cmd_ready;
  logic        v2b_rsp_valid;
  logic [31:0] v2b_rsp_rdata;

  simple2v2btop_adapter u_adapter (
    .clk(clk), .rst_n(rst_n),
    .m_valid(v2b_m_valid), .m_write(v2b_m_write), .m_addr(v2b_m_addr),
    .m_wdata(v2b_m_wdata), .m_wstrb(v2b_m_wstrb),
    .m_ready(v2b_m_ready), .m_rdata(v2b_m_rdata), .m_rvalid(v2b_m_rvalid),
    .cmd_valid(v2b_cmd_valid), .cmd_write(v2b_cmd_write),
    .cmd_addr (v2b_cmd_addr),
    .cmd_wdata(v2b_cmd_wdata), .cmd_wstrb(v2b_cmd_wstrb),
    .cmd_ready(v2b_cmd_ready),
    .rsp_valid(v2b_rsp_valid), .rsp_rdata(v2b_rsp_rdata)
  );

  snn_soc_v2b_top u_v2b (
    .clk(clk), .rst_n(rst_n),
    .cmd_valid(v2b_cmd_valid), .cmd_ready(v2b_cmd_ready),
    .cmd_addr (v2b_cmd_addr),  .cmd_write(v2b_cmd_write),
    .cmd_wdata(v2b_cmd_wdata), .cmd_wstrb(v2b_cmd_wstrb),
    .rsp_valid(v2b_rsp_valid), .rsp_rdata(v2b_rsp_rdata)
  );

  // ================================================================
  // Lint unused
  // ================================================================
  wire _unused_soc = &{1'b0, inspect_pc, core_wfi, br_busy};

endmodule
