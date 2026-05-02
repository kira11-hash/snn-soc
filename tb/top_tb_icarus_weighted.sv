`timescale 1ns/1ps

module top_tb_icarus_weighted;
  import snn_soc_pkg::*;

  localparam [31:0] REG_THRESHOLD = ADDR_REG_BASE + 32'h00;
  localparam [31:0] REG_TIMESTEPS = ADDR_REG_BASE + 32'h04;
  localparam [31:0] REG_CIM_CTRL  = ADDR_REG_BASE + 32'h14;
  localparam [31:0] REG_OUT_DATA  = ADDR_REG_BASE + 32'h1C;
  localparam [31:0] REG_OUT_COUNT = ADDR_REG_BASE + 32'h20;
  localparam [31:0] REG_CIM_TEST  = ADDR_REG_BASE + 32'h2C;

  localparam [31:0] DMA_SRC_ADDR  = ADDR_DMA_BASE + 32'h00;
  localparam [31:0] DMA_LEN_WORDS = ADDR_DMA_BASE + 32'h04;
  localparam [31:0] DMA_CTRL      = ADDR_DMA_BASE + 32'h08;

  logic clk;
  logic rst_n;

  logic uart_rx;
  logic uart_tx;
  logic spi_cs_n;
  logic spi_sck;
  logic spi_mosi;
  logic spi_miso;
  logic jtag_tck;
  logic jtag_tms;
  logic jtag_tdi;
  logic jtag_tdo;
  logic [7:0] wl_data_ext;
  logic [2:0] wl_group_sel_ext;
  logic       wl_latch_ext;
  logic       cim_start_ext;
  logic       cim_done_ext;
  logic [4:0] bl_sel_ext;
  logic [7:0] bl_data_ext;
  logic [2:0] prog_op_ext;      // V1 external programming (2026-04-24)
  logic [3:0] prog_level_ext;

  // Keep branch-compatibility ports for wildcard binding across old/new tops.
  // They are intentionally idle on main and would otherwise trip lint-only noise.
  /* verilator lint_off UNUSEDSIGNAL */
  logic        ext_bus_enable;
  logic        ext_bus_m_valid;
  logic        ext_bus_m_write;
  logic [31:0] ext_bus_m_addr;
  logic [31:0] ext_bus_m_wdata;
  logic [3:0]  ext_bus_m_wstrb;
  logic        ext_bus_m_ready;
  logic [31:0] ext_bus_m_rdata;
  logic        ext_bus_m_rvalid;
  /* verilator lint_on UNUSEDSIGNAL */

  integer error_count;
  integer poll_i;
  integer bit_i;
  integer frame_i;
  integer timesteps_cfg;
  integer threshold_cfg;
  integer fail_on_zero_spike;
  integer out_fifo_count;
  reg [31:0] rd;
  reg dma_done_seen;
  reg cim_done_seen;
  reg [63:0] pattern_cross;
  reg [63:0] plane_vec;

  snn_soc_top dut (.*);

  /* verilator lint_off UNUSEDSIGNAL */
  task automatic bus_write;
    input [31:0] addr;
    input [31:0] data;
    input [3:0]  wstrb;
    begin
      @(negedge clk);
      dut.bus_if.m_valid = 1'b1;
      dut.bus_if.m_write = 1'b1;
      dut.bus_if.m_addr  = addr;
      dut.bus_if.m_wdata = data;
      dut.bus_if.m_wstrb = wstrb;

      @(posedge clk);
      @(posedge clk);
      if (dut.bus_if.m_ready !== 1'b1) begin
        $display("[ERR] bus_write timeout addr=0x%08h data=0x%08h", addr, data);
        error_count = error_count + 1;
      end

      @(negedge clk);
      dut.bus_if.m_valid = 1'b0;
      dut.bus_if.m_write = 1'b0;
      dut.bus_if.m_addr  = 32'h0;
      dut.bus_if.m_wdata = 32'h0;
      dut.bus_if.m_wstrb = 4'h0;
    end
  endtask

  task automatic bus_read;
    input [31:0] addr;
    output [31:0] data;
    begin
      @(negedge clk);
      dut.bus_if.m_valid = 1'b1;
      dut.bus_if.m_write = 1'b0;
      dut.bus_if.m_addr  = addr;
      dut.bus_if.m_wdata = 32'h0;
      dut.bus_if.m_wstrb = 4'h0;

      @(posedge clk);
      @(posedge clk);
      data = dut.bus_if.m_rdata;
      if (dut.bus_if.m_rvalid !== 1'b1) begin
        $display("[ERR] bus_read timeout addr=0x%08h", addr);
        error_count = error_count + 1;
      end

      @(negedge clk);
      dut.bus_if.m_valid = 1'b0;
      dut.bus_if.m_write = 1'b0;
      dut.bus_if.m_addr  = 32'h0;
      dut.bus_if.m_wdata = 32'h0;
      dut.bus_if.m_wstrb = 4'h0;
    end
  endtask
  /* verilator lint_on UNUSEDSIGNAL */

  initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    uart_rx = 1'b1;
    spi_miso = 1'b0;
    cim_done_ext = 1'b0;
    bl_data_ext = 8'h00;
    jtag_tck = 1'b0;
    jtag_tms = 1'b0;
    jtag_tdi = 1'b0;
    ext_bus_enable  = 1'b0;
    ext_bus_m_valid = 1'b0;
    ext_bus_m_write = 1'b0;
    ext_bus_m_addr  = 32'h0;
    ext_bus_m_wdata = 32'h0;
    ext_bus_m_wstrb = 4'h0;

    dut.bus_if.m_valid = 1'b0;
    dut.bus_if.m_write = 1'b0;
    dut.bus_if.m_addr  = 32'h0;
    dut.bus_if.m_wdata = 32'h0;
    dut.bus_if.m_wstrb = 4'h0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end

`ifdef VCS
  initial begin
    $fsdbDumpfile("waves/snn_soc_weighted.fsdb");
    $fsdbDumpvars(0, top_tb_icarus_weighted);
  end
`else
  initial begin
    $dumpfile("waves/icarus_weighted.vcd");
    $dumpvars(0, top_tb_icarus_weighted);
  end
`endif

  initial begin
    error_count = 0;
    dma_done_seen = 1'b0;
    cim_done_seen = 1'b0;
    timesteps_cfg = TIMESTEPS_DEFAULT;
    threshold_cfg = THRESHOLD_RATIO_DEFAULT * ((1 << PIXEL_BITS) - 1) * TIMESTEPS_DEFAULT;
    fail_on_zero_spike = 0;
    rd = 32'h0;

    pattern_cross = 64'b00000000_00011000_00011000_01111110_01111110_00011000_00011000_00000000;

    wait (rst_n === 1'b1);
    repeat (2) @(posedge clk);

    if ($value$plusargs("TIMESTEPS=%d", timesteps_cfg)) begin
      timesteps_cfg = timesteps_cfg;
    end
    if (!$value$plusargs("THRESHOLD=%d", threshold_cfg)) begin
      threshold_cfg = THRESHOLD_RATIO_DEFAULT * ((1 << PIXEL_BITS) - 1) * timesteps_cfg;
    end
    if ($value$plusargs("FAIL_ON_ZERO_SPIKE=%d", fail_on_zero_spike)) begin
      fail_on_zero_spike = fail_on_zero_spike;
    end

    $display("[INFO] Weighted Icarus source-level simulation start");
    $display("[INFO] Config: TIMESTEPS=%0d THRESHOLD=%0d FAIL_ON_ZERO_SPIKE=%0d",
             timesteps_cfg, threshold_cfg, fail_on_zero_spike);

    bus_write(REG_TIMESTEPS, timesteps_cfg, 4'h1);
    bus_write(REG_THRESHOLD, threshold_cfg, 4'hF);
    bus_write(REG_CIM_TEST, 32'h0000_0000, 4'hF);

    for (frame_i = 0; frame_i < timesteps_cfg; frame_i = frame_i + 1) begin
      for (bit_i = 0; bit_i < PIXEL_BITS; bit_i = bit_i + 1) begin
        plane_vec = pattern_cross;
        bus_write(ADDR_DATA_BASE + (frame_i * PIXEL_BITS * 8) + (bit_i * 8) + 32'h0, plane_vec[31:0], 4'hF);
        bus_write(ADDR_DATA_BASE + (frame_i * PIXEL_BITS * 8) + (bit_i * 8) + 32'h4, plane_vec[63:32], 4'hF);
      end
    end

    bus_write(DMA_SRC_ADDR, ADDR_DATA_BASE, 4'hF);
    bus_write(DMA_LEN_WORDS, timesteps_cfg * PIXEL_BITS * 2, 4'hF);
    bus_write(DMA_CTRL, 32'h0000_0001, 4'h1);

    begin : dma_poll
      for (poll_i = 0; poll_i < 3000; poll_i = poll_i + 1) begin
        bus_read(DMA_CTRL, rd);
        if (rd[1]) begin
          dma_done_seen = 1'b1;
          $display("[INFO] DMA done after %0d polls", poll_i + 1);
          disable dma_poll;
        end
      end
    end

    if (!dma_done_seen) begin
      $display("[ERR] DMA done not observed");
      error_count = error_count + 1;
    end

    bus_write(REG_CIM_CTRL, 32'h0000_0001, 4'h1);

    begin : cim_poll
      for (poll_i = 0; poll_i < 120000; poll_i = poll_i + 1) begin
        bus_read(REG_CIM_CTRL, rd);
        if (rd[7]) begin
          cim_done_seen = 1'b1;
          $display("[INFO] CIM done after %0d polls", poll_i + 1);
          disable cim_poll;
        end
      end
    end

    if (!cim_done_seen) begin
      $display("[ERR] CIM done not observed");
      error_count = error_count + 1;
    end

    bus_read(REG_OUT_COUNT, rd);
    out_fifo_count = rd;
    $display("[INFO] OUT_FIFO_COUNT=%0d", out_fifo_count);

    for (poll_i = 0; poll_i < out_fifo_count; poll_i = poll_i + 1) begin
      bus_read(REG_OUT_DATA, rd);
      $display("[INFO] spike_id[%0d]=%0d", poll_i, rd[3:0]);
    end

    if ((out_fifo_count == 0) && (fail_on_zero_spike != 0)) begin
      $display("[ERR] zero spike observed while FAIL_ON_ZERO_SPIKE=1");
      error_count = error_count + 1;
    end

    if (error_count == 0) begin
      $display("WEIGHTED_SIM_PASS");
    end else begin
      $display("WEIGHTED_SIM_FAIL errors=%0d", error_count);
    end

    repeat (10) @(posedge clk);
    $finish;
  end

  wire _unused_tb = uart_tx ^ spi_cs_n ^ spi_sck ^ spi_mosi ^ jtag_tdo;

  // TB-C-01 fix（2026-05-02 audit）：global watchdog，超时打 FAIL marker。
  initial begin
    #20_000_000;  // 20 ms sim time（weighted 跑 T 拍 + UART trace 较慢）
    $display("[FAIL] WEIGHTED_SIM global timeout (20ms sim)");
    $display("WEIGHTED_SIM_FAIL (global timeout)");
    $finish;
  end
endmodule
