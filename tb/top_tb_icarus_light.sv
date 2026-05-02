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
  localparam integer EXPECTED_OUT_COUNT_DEFAULT = 100;

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

  // Optional external bus override ports exist on some branches.
  // Lint-only mode treats these compatibility placeholders as unused
  // on main, so scope the warning suppression to this branch-compat block.
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
  integer i;
  integer f;
  integer expected_out_count;
  integer plusarg_value;
  reg check_out_count;
  reg [31:0] rd;
  reg dma_done_seen;
  reg cim_done_seen;

  snn_soc_top dut (.*);

  // Lint-only mode does not attribute hierarchical bus_if pokes back to task
  // formals, so suppress the resulting false-positive unused warnings.
  /* verilator lint_off UNUSEDSIGNAL */
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

  task automatic bus_write_masked;
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
        $display("[ERR] bus_write_masked timeout addr=0x%08h data=0x%08h wstrb=0x%0h t=%0t",
                 addr, data, wstrb, $time);
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

  initial begin
    $dumpfile("waves/icarus_light.vcd");
    $dumpvars(0, top_tb_icarus_light);
  end

  initial begin
    error_count = 0;
    dma_done_seen = 1'b0;
    cim_done_seen = 1'b0;
    expected_out_count = EXPECTED_OUT_COUNT_DEFAULT;
    check_out_count = 1'b1;
    plusarg_value = 0;
    rd = 32'h0;

    wait(rst_n === 1'b1);
    repeat (2) @(posedge clk);

    if ($value$plusargs("EXPECTED_OUT_COUNT=%d", plusarg_value)) begin
      expected_out_count = plusarg_value;
    end
    if ($value$plusargs("CHECK_OUT_COUNT=%d", plusarg_value)) begin
      check_out_count = (plusarg_value != 0);
    end

    $display("[INFO] Icarus light smoke test start");
    $display("[INFO] Config: EXPECTED_OUT_COUNT=%0d CHECK_OUT_COUNT=%0d",
             expected_out_count, check_out_count);

    // Keep pattern deterministic; run current default T=10 smoke path.
    bus_write(REG_TIMESTEPS, TIMESTEPS_DEFAULT);
    bus_write(REG_THRESHOLD, THRESHOLD_DEFAULT);
    bus_write(REG_CIM_TEST, 32'h0000_0000);

    // TIMESTEPS_DEFAULT frames * 8 bit-planes * 2 words per bit-plane.
    for (f = 0; f < TIMESTEPS_DEFAULT; f = f + 1) begin
      for (i = 0; i < PIXEL_BITS; i = i + 1) begin
        bus_write(ADDR_DATA_BASE + (f * PIXEL_BITS * 8) + (i * 8) + 32'h0, 32'h0000_00FF >> i);
        bus_write(ADDR_DATA_BASE + (f * PIXEL_BITS * 8) + (i * 8) + 32'h4, 32'h0000_0000);
      end
    end

    bus_write(DMA_SRC_ADDR, ADDR_DATA_BASE);
    bus_write(DMA_LEN_WORDS, TIMESTEPS_DEFAULT * PIXEL_BITS * 2);
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

    // W1P/W1C must only be effective when byte0 is selected.
    bus_write_masked(DMA_CTRL, 32'h0000_0001, 4'b0010); // masked START
    bus_read(DMA_CTRL, rd);
    if (!rd[1]) begin
      $display("[ERR] DMA done cleared by non-byte0 write, DMA_CTRL=0x%08h", rd);
      error_count = error_count + 1;
    end
    if (rd[3]) begin
      $display("[ERR] DMA busy set by masked START, DMA_CTRL=0x%08h", rd);
      error_count = error_count + 1;
    end

    bus_write_masked(DMA_CTRL, 32'h0000_0002, 4'b0001); // clear DONE (W1C)
    bus_read(DMA_CTRL, rd);
    if (rd[1]) begin
      $display("[ERR] DMA done W1C clear failed, DMA_CTRL=0x%08h", rd);
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

    bus_write_masked(REG_CIM_CTRL, 32'h0000_0080, 4'b0010); // masked DONE W1C
    bus_read(REG_CIM_CTRL, rd);
    if (!rd[7]) begin
      $display("[ERR] CIM done cleared by non-byte0 write, CIM_CTRL=0x%08h", rd);
      error_count = error_count + 1;
    end

    bus_write_masked(REG_CIM_CTRL, 32'h0000_0080, 4'b0001); // clear DONE (W1C)
    bus_read(REG_CIM_CTRL, rd);
    if (rd[7]) begin
      $display("[ERR] CIM done W1C clear failed, CIM_CTRL=0x%08h", rd);
      error_count = error_count + 1;
    end

    bus_read(REG_OUT_COUNT, rd);
    $display("[INFO] OUT_FIFO_COUNT=0x%08h (%0d)", rd, rd);
    if (check_out_count) begin
      if (rd !== expected_out_count) begin
        $display("[ERR] OUT_FIFO_COUNT mismatch got=%0d expected=%0d", rd, expected_out_count);
        error_count = error_count + 1;
      end
    end

    if (error_count == 0) begin
      $display("LIGHT_SMOKETEST_PASS");
    end else begin
      $display("LIGHT_SMOKETEST_FAIL errors=%0d", error_count);
    end

    repeat (10) @(posedge clk);
    $finish;
  end

  wire _unused_tb = uart_tx ^ spi_cs_n ^ spi_sck ^ spi_mosi ^ jtag_tdo;

  // TB-C-01 fix（2026-05-02 audit）：global watchdog，超时打 FAIL marker。
  // 旧版无 timeout，RTL livelock 时 CI 会 hang。light smoke 应当几百 us 内完成。
  initial begin
    #5_000_000;  // 5 ms sim time
    $display("[FAIL] LIGHT_SMOKETEST global timeout (5ms sim)");
    $display("LIGHT_SMOKETEST_FAIL (global timeout)");
    $finish;
  end

endmodule
