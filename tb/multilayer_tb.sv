`timescale 1ns/1ps
module multilayer_tb;
  import snn_soc_pkg::*;

  localparam [31:0] REG_THRESHOLD = ADDR_REG_BASE + 32'h00;
  localparam [31:0] REG_CIM_CTRL  = ADDR_REG_BASE + 32'h14;
  localparam [31:0] REG_OUT_COUNT = ADDR_REG_BASE + 32'h20;
  localparam [31:0] REG_CIM_TEST  = ADDR_REG_BASE + 32'h2C;
  localparam [31:0] REG_ML_CTRL   = ADDR_REG_BASE + 32'h48;
  localparam [31:0] DMA_SRC_ADDR  = ADDR_DMA_BASE + 32'h00;
  localparam [31:0] DMA_LEN_WORDS = ADDR_DMA_BASE + 32'h04;
  localparam [31:0] DMA_CTRL      = ADDR_DMA_BASE + 32'h08;
  localparam [31:0] DMA_DST_SEL   = ADDR_DMA_BASE + 32'h0C;

  logic clk, rst_n;
  initial clk = 0;
  always #5 clk = ~clk;

  logic uart_rx, uart_tx;
  logic spi_cs_n, spi_sck, spi_mosi, spi_miso;
  logic jtag_tck, jtag_tms, jtag_tdi, jtag_tdo;
  logic [7:0] wl_data_ext;
  logic [2:0] wl_group_sel_ext;
  logic       wl_latch_ext;
  logic       cim_start_ext;
  logic       cim_done_ext;
  logic [$clog2(snn_soc_pkg::MAX_BL_SCAN)-1:0] bl_sel_ext;
  logic [7:0] bl_data_ext;
  logic       prog_en_ext, erase_en_ext, verify_en_ext;

  integer error_count;
  reg [31:0] rd;

  assign uart_rx     = 1'b1;
  assign spi_miso    = 1'b0;
  assign jtag_tck    = 1'b0;
  assign jtag_tms    = 1'b0;
  assign jtag_tdi    = 1'b0;
  assign cim_done_ext = 1'b0;
  assign bl_data_ext  = 8'h0;

  snn_soc_top dut (.*);

  task automatic bus_write;
    input [31:0] addr;
    input [31:0] data;
    begin
      @(negedge clk);
      dut.bus_if.m_valid = 1'b1;
      dut.bus_if.m_write = 1'b1;
      dut.bus_if.m_addr  = addr;
      dut.bus_if.m_wdata = data;
      dut.bus_if.m_wstrb = 4'hF;
      @(posedge clk); @(posedge clk);
      @(negedge clk);
      dut.bus_if.m_valid = 1'b0;
      dut.bus_if.m_write = 1'b0;
    end
  endtask

  task automatic bus_read;
    input  [31:0] addr;
    output [31:0] data;
    begin
      @(negedge clk);
      dut.bus_if.m_valid = 1'b1;
      dut.bus_if.m_write = 1'b0;
      dut.bus_if.m_addr  = addr;
      dut.bus_if.m_wstrb = 4'hF;
      @(posedge clk); @(posedge clk);
      data = dut.bus_if.m_rdata;
      @(negedge clk);
      dut.bus_if.m_valid = 1'b0;
    end
  endtask

  integer timeout_cnt;

  initial begin
    $dumpfile("waves/multilayer.vcd");
    $dumpvars(0, multilayer_tb);

    $display("[INFO] Multilayer smoke test start");
    $display("[INFO] ENABLE_MULTI_LAYER=%0d", ENABLE_MULTI_LAYER);

    if (ENABLE_MULTI_LAYER != 1) begin
      $display("[FAIL] ENABLE_MULTI_LAYER!=1, need +define+SIM_MULTI_LAYER");
      $finish;
    end

    error_count = 0;
    rst_n = 0;
    repeat (20) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    // ── Enable CIM test mode (pos=100, neg=0 → diff=100) ──
    bus_write(REG_CIM_TEST, 32'h0000_6401);

    // ── Configure 2-layer: Layer0 (64in→10out), Layer1 (10in→10out) ──
    // REG_ML_CTRL: num_layers=1 (means 2 layers 0-indexed), enable[8]=1
    bus_write(REG_ML_CTRL, 32'h0000_0101);

    // Layer 0: wl_off=0, wl_cnt=64, bl_off=0, bl_cnt=20
    bus_write(ADDR_REG_BASE + 32'h50, {8'd20, 8'd0, 8'd64, 8'd0});
    // Layer 0 timing: timesteps=10, use_bitplane=1
    bus_write(ADDR_REG_BASE + 32'h54, {23'd0, 1'b1, 8'd10});
    // Layer 0 threshold
    bus_write(ADDR_REG_BASE + 32'h58, 32'd2550);
    // Layer 0 neuron count
    bus_write(ADDR_REG_BASE + 32'h5C, 32'd10);

    // Layer 1: wl_off=0, wl_cnt=10, bl_off=0, bl_cnt=20
    bus_write(ADDR_REG_BASE + 32'h60, {8'd20, 8'd0, 8'd10, 8'd0});
    // Layer 1 timing: timesteps=1, use_bitplane=0 (binary)
    bus_write(ADDR_REG_BASE + 32'h64, {23'd0, 1'b0, 8'd1});
    // Layer 1 threshold
    bus_write(ADDR_REG_BASE + 32'h68, 32'd100);
    // Layer 1 neuron count
    bus_write(ADDR_REG_BASE + 32'h6C, 32'd10);

    // ── Load DMA data: 160 words → 80 FIFO entries (10 frames × 8 bitplanes) ──
    // Write test pattern to data SRAM (base = 0x0001_0000)
    // DMA packs 2×32-bit words into 1×64-bit FIFO entry, so need 160 words for 80 entries
    for (integer i = 0; i < 160; i = i + 1) begin
      bus_write(32'h0001_0000 + i*4, 32'hFFFF_FFFF);
    end

    // DMA: data_sram → input_fifo
    bus_write(DMA_SRC_ADDR,  32'h0001_0000);
    bus_write(DMA_DST_SEL,   32'h0000_0000);
    bus_write(DMA_LEN_WORDS, 32'd160);
    bus_write(DMA_CTRL,      32'h0000_0001);

    // Wait DMA done
    rd = 0; timeout_cnt = 0;
    while (!rd[1] && timeout_cnt < 500) begin
      bus_read(DMA_CTRL, rd);
      timeout_cnt = timeout_cnt + 1;
    end
    if (!rd[1]) begin $display("[FAIL] DMA timeout"); $finish; end
    $display("[INFO] DMA done after %0d polls", timeout_cnt);

    // ── Start inference ──
    bus_write(REG_CIM_CTRL, 32'h0000_0001);

    // Wait inference done
    rd = 0; timeout_cnt = 0;
    while (!rd[7] && timeout_cnt < 20000) begin
      bus_read(REG_CIM_CTRL, rd);
      timeout_cnt = timeout_cnt + 1;
    end
    if (!rd[7]) begin
      $display("[FAIL] Inference timeout after %0d polls", timeout_cnt);
      $finish;
    end
    $display("[INFO] Inference done after %0d polls", timeout_cnt);

    // Check output FIFO
    bus_read(REG_OUT_COUNT, rd);
    $display("[INFO] OUT_FIFO_COUNT=%0d", rd);

    if (rd > 0) begin
      $display("MULTILAYER_SMOKE_PASS");
    end else begin
      $display("[FAIL] OUT_FIFO_COUNT=0 — no spikes produced");
      error_count = error_count + 1;
    end

    repeat (10) @(posedge clk);
    $finish;
  end

  initial begin
    #200_000_000;
    $display("[FAIL] Global timeout at 200ms");
    $finish;
  end

endmodule
