`timescale 1ns/1ps

module top_tb_adc_sat_counter;
  import snn_soc_pkg::*;

  localparam [31:0] REG_THRESHOLD     = ADDR_REG_BASE + 32'h00;
  localparam [31:0] REG_TIMESTEPS     = ADDR_REG_BASE + 32'h04;
  localparam [31:0] REG_CIM_CTRL      = ADDR_REG_BASE + 32'h14;
  localparam [31:0] REG_ADC_SAT_COUNT = ADDR_REG_BASE + 32'h28;
  localparam [31:0] REG_CIM_TEST      = ADDR_REG_BASE + 32'h2C;

  localparam [31:0] DMA_SRC_ADDR      = ADDR_DMA_BASE + 32'h00;
  localparam [31:0] DMA_LEN_WORDS     = ADDR_DMA_BASE + 32'h04;
  localparam [31:0] DMA_CTRL          = ADDR_DMA_BASE + 32'h08;

  localparam int FIRST_TIMESTEPS    = 2;
  localparam int SECOND_TIMESTEPS   = 1;
  localparam int SAT_PER_TIMESTEP   = PIXEL_BITS * NUM_OUTPUTS;
  localparam int EXPECT_FIRST_COUNT = FIRST_TIMESTEPS * SAT_PER_TIMESTEP;
  localparam int EXPECT_NEXT_COUNT  = SECOND_TIMESTEPS * SAT_PER_TIMESTEP;

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
  reg [31:0] rd;
  reg dma_done_seen;
  reg cim_done_seen;

  snn_soc_top dut (.*);

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

  task automatic wait_dma_done;
    integer poll_i;
    begin : dma_poll
      dma_done_seen = 1'b0;
      for (poll_i = 0; poll_i < 3000; poll_i = poll_i + 1) begin
        bus_read(DMA_CTRL, rd);
        if (rd[1]) begin
          dma_done_seen = 1'b1;
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
  endtask

  task automatic wait_cim_done;
    integer poll_i;
    begin : cim_poll
      cim_done_seen = 1'b0;
      for (poll_i = 0; poll_i < 60000; poll_i = poll_i + 1) begin
        bus_read(REG_CIM_CTRL, rd);
        if (rd[7]) begin
          cim_done_seen = 1'b1;
          disable cim_poll;
        end
      end
    end
    if (!cim_done_seen) begin
      $display("[ERR] CIM done not observed");
      error_count = error_count + 1;
    end
  endtask

  task automatic load_frames;
    input integer frames;
    integer frame_i;
    integer bit_i;
    begin
      for (frame_i = 0; frame_i < frames; frame_i = frame_i + 1) begin
        for (bit_i = 0; bit_i < PIXEL_BITS; bit_i = bit_i + 1) begin
          bus_write(ADDR_DATA_BASE + (frame_i * PIXEL_BITS * 8) + (bit_i * 8) + 32'h0,
                    32'hFFFF_FFFF, 4'hF);
          bus_write(ADDR_DATA_BASE + (frame_i * PIXEL_BITS * 8) + (bit_i * 8) + 32'h4,
                    32'h0000_0000, 4'hF);
        end
      end
    end
  endtask

  task automatic run_inference;
    input integer frames;
    begin
      bus_write(REG_TIMESTEPS, frames, 4'h1);
      load_frames(frames);
      bus_write(DMA_SRC_ADDR, ADDR_DATA_BASE, 4'hF);
      bus_write(DMA_LEN_WORDS, frames * PIXEL_BITS * 2, 4'hF);
      bus_write(DMA_CTRL, 32'h0000_0001, 4'h1);
      wait_dma_done();
      bus_write(REG_CIM_CTRL, 32'h0000_0001, 4'h1);
      wait_cim_done();
    end
  endtask

  task automatic check_adc_sat;
    input integer expected_high;
    input integer expected_low;
    begin
      bus_read(REG_ADC_SAT_COUNT, rd);
      if (rd[15:0] !== expected_high[15:0]) begin
        $display("[ERR] sat_high mismatch exp=%0d got=%0d", expected_high, rd[15:0]);
        error_count = error_count + 1;
      end
      if (rd[31:16] !== expected_low[15:0]) begin
        $display("[ERR] sat_low mismatch exp=%0d got=%0d", expected_low, rd[31:16]);
        error_count = error_count + 1;
      end
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

  initial begin
    $dumpfile("waves/adc_sat_counter.vcd");
    $dumpvars(0, top_tb_adc_sat_counter);
  end

  initial begin
    error_count = 0;
    rd = 32'h0;
    dma_done_seen = 1'b0;
    cim_done_seen = 1'b0;

    wait (rst_n === 1'b1);
    repeat (2) @(posedge clk);

    $display("[INFO] ADC saturation counter regression start");

    bus_write(REG_THRESHOLD, THRESHOLD_DEFAULT, 4'hF);
    bus_write(REG_CIM_TEST, 32'h0000_FF01, 4'hF);

    run_inference(FIRST_TIMESTEPS);
    check_adc_sat(EXPECT_FIRST_COUNT, EXPECT_FIRST_COUNT);

    bus_write(DMA_CTRL, 32'h0000_0002, 4'h1);
    bus_write(REG_CIM_CTRL, 32'h0000_0080, 4'h1);

    run_inference(SECOND_TIMESTEPS);
    check_adc_sat(EXPECT_NEXT_COUNT, EXPECT_NEXT_COUNT);

    if (error_count == 0) begin
      $display("ADC_SAT_COUNTER_PASS");
    end else begin
      $display("ADC_SAT_COUNTER_FAIL errors=%0d", error_count);
    end

    repeat (10) @(posedge clk);
    $finish;
  end
endmodule
