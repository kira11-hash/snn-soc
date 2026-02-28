`timescale 1ns/1ps

module top_tb_icarus_light;
  import snn_soc_pkg::*;

  localparam [31:0] REG_THRESHOLD = ADDR_REG_BASE + 32'h00;
  localparam [31:0] REG_TIMESTEPS = ADDR_REG_BASE + 32'h04;
  localparam [31:0] REG_CIM_CTRL  = ADDR_REG_BASE + 32'h14;
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

  integer error_count;
  integer i;
  integer f;
  reg [31:0] rd;
  reg dma_done_seen;
  reg cim_done_seen;

  snn_soc_top dut (
    .clk      (clk),
    .rst_n    (rst_n),
    .uart_rx  (uart_rx),
    .uart_tx  (uart_tx),
    .spi_cs_n (spi_cs_n),
    .spi_sck  (spi_sck),
    .spi_mosi (spi_mosi),
    .spi_miso (spi_miso),
    .jtag_tck (jtag_tck),
    .jtag_tms (jtag_tms),
    .jtag_tdi (jtag_tdi),
    .jtag_tdo (jtag_tdo)
  );

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

      @(posedge clk);
      @(posedge clk);
      if (dut.bus_if.m_ready !== 1'b1) begin
        $display("[ERR] bus_write timeout addr=0x%08h data=0x%08h t=%0t", addr, data, $time);
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
        $display("[ERR] bus_read timeout addr=0x%08h t=%0t", addr, $time);
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

  initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    uart_rx = 1'b1;
    spi_miso = 1'b0;
    jtag_tck = 1'b0;
    jtag_tms = 1'b0;
    jtag_tdi = 1'b0;

    dut.bus_if.m_valid = 1'b0;
    dut.bus_if.m_write = 1'b0;
    dut.bus_if.m_addr  = 32'h0;
    dut.bus_if.m_wdata = 32'h0;
    dut.bus_if.m_wstrb = 4'h0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end

  initial begin
    $dumpfile("waves/icarus_light.vcd");
    $dumpvars(0, top_tb_icarus_light);
  end

  initial begin
    error_count = 0;
    dma_done_seen = 1'b0;
    cim_done_seen = 1'b0;
    rd = 32'h0;

    wait(rst_n === 1'b1);
    repeat (2) @(posedge clk);

    $display("[INFO] Icarus light smoke test start");

    // Keep pattern deterministic; run full T=10 smoke path.
    bus_write(REG_TIMESTEPS, 32'd10);
    bus_write(REG_THRESHOLD, 32'd10200);
    bus_write(REG_CIM_TEST, 32'h0000_0000);

    // 10 frames * 8 bit-planes * 2 words per bit-plane = 160 words.
    for (f = 0; f < 10; f = f + 1) begin
      for (i = 0; i < PIXEL_BITS; i = i + 1) begin
        bus_write(ADDR_DATA_BASE + (f * PIXEL_BITS * 8) + (i * 8) + 32'h0, 32'h0000_00FF >> i);
        bus_write(ADDR_DATA_BASE + (f * PIXEL_BITS * 8) + (i * 8) + 32'h4, 32'h0000_0000);
      end
    end

    bus_write(DMA_SRC_ADDR, ADDR_DATA_BASE);
    bus_write(DMA_LEN_WORDS, 32'd160);
    bus_write(DMA_CTRL, 32'h0000_0001);

    begin : dma_poll
      for (i = 0; i < 1200; i = i + 1) begin
        bus_read(DMA_CTRL, rd);
        if (rd[1]) begin
          dma_done_seen = 1'b1;
          $display("[INFO] DMA done after %0d polls, DMA_CTRL=0x%08h", i + 1, rd);
          disable dma_poll;
        end
      end
    end

    if (!dma_done_seen) begin
      $display("[ERR] DMA done not observed");
      error_count = error_count + 1;
    end
    if (rd[2]) begin
      $display("[ERR] DMA error bit set, DMA_CTRL=0x%08h", rd);
      error_count = error_count + 1;
    end

    bus_write(REG_CIM_CTRL, 32'h0000_0001);

    begin : cim_poll
      for (i = 0; i < 60000; i = i + 1) begin
        bus_read(REG_CIM_CTRL, rd);
        if (rd[7]) begin
          cim_done_seen = 1'b1;
          $display("[INFO] CIM done after %0d polls, CIM_CTRL=0x%08h", i + 1, rd);
          disable cim_poll;
        end
      end
    end

    if (!cim_done_seen) begin
      $display("[ERR] CIM done not observed");
      error_count = error_count + 1;
    end

    bus_read(REG_OUT_COUNT, rd);
    $display("[INFO] OUT_FIFO_COUNT=0x%08h (%0d)", rd, rd);

    if (error_count == 0) begin
      $display("LIGHT_SMOKETEST_PASS");
    end else begin
      $display("LIGHT_SMOKETEST_FAIL errors=%0d", error_count);
    end

    repeat (10) @(posedge clk);
    $finish;
  end

  wire _unused_tb = uart_tx ^ spi_cs_n ^ spi_sck ^ spi_mosi ^ jtag_tdo;

endmodule
