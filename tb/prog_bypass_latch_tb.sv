`timescale 1ns/1ps
//==========================================================================
// prog_bypass_latch_tb
//
// Verifies the top-level latch that freezes BYPASS_HANDSHAKE/erase/level at
// prog_start_pulse.  A later CPU write clearing PROG_CTRL must not affect the
// in-flight programming sequence.
//==========================================================================
module prog_bypass_latch_tb;
  import snn_soc_pkg::*;

  logic clk;
  logic rst_n;
  logic uart_rx, uart_tx;
  logic spi_cs_n, spi_sck, spi_mosi, spi_miso;
  logic jtag_tck, jtag_tms, jtag_tdi, jtag_tdo;
  logic [7:0] wl_data_ext;
  logic [2:0] wl_group_sel_ext;
  logic       wl_latch_ext;
  logic       cim_start_ext;
  logic       cim_done_ext;
  logic [4:0] bl_sel_ext;
  logic [7:0] bl_data_ext;
  logic [2:0] prog_op_ext;      // V1 external programming (2026-04-24)
  logic [3:0] prog_level_ext;

  initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
  end

  snn_soc_top #(
    .ENABLE_PROGRAM_MODE(1'b1),
    .ENABLE_PROGRAM_WEIGHT_MODEL(1'b0)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .uart_rx(uart_rx),
    .uart_tx(uart_tx),
    .spi_cs_n(spi_cs_n),
    .spi_sck(spi_sck),
    .spi_mosi(spi_mosi),
    .spi_miso(spi_miso),
    .jtag_tck(jtag_tck),
    .jtag_tms(jtag_tms),
    .jtag_tdi(jtag_tdi),
    .jtag_tdo(jtag_tdo),
    .wl_data_ext(wl_data_ext),
    .wl_group_sel_ext(wl_group_sel_ext),
    .wl_latch_ext(wl_latch_ext),
    .cim_start_ext(cim_start_ext),
    .cim_done_ext(cim_done_ext),
    .bl_sel_ext(bl_sel_ext),
    .bl_data_ext(bl_data_ext),
    .prog_op_ext(prog_op_ext),
    .prog_level_ext(prog_level_ext)
  );

  task automatic bus_idle;
    begin
      dut.bus_if.m_valid = 1'b0;
      dut.bus_if.m_write = 1'b0;
      dut.bus_if.m_addr  = '0;
      dut.bus_if.m_wdata = '0;
      dut.bus_if.m_wstrb = 4'h0;
    end
  endtask

  task automatic bus_write(input [31:0] addr, input [31:0] data);
    begin
      @(posedge clk);
      dut.bus_if.m_valid = 1'b1;
      dut.bus_if.m_write = 1'b1;
      dut.bus_if.m_addr  = addr;
      dut.bus_if.m_wdata = data;
      dut.bus_if.m_wstrb = 4'hF;
      @(posedge clk);
      bus_idle();
    end
  endtask

  initial begin
    rst_n = 1'b0;
    uart_rx = 1'b1;
    spi_miso = 1'b1;
    jtag_tck = 1'b0;
    jtag_tms = 1'b0;
    jtag_tdi = 1'b0;
    cim_done_ext = 1'b0;
    bl_data_ext = 8'h00;
    bus_idle();

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // Program target row/col first.
    bus_write(32'h4000_003C, 32'd5);
    bus_write(32'h4000_0040, 32'd3);

    // START with bypass=1, level=4.
    bus_write(32'h4000_0038, 32'h0000_0049);

    // Wait until the top-level active latch is asserted, then clobber the live
    // PROG_CTRL register while prog_busy is still high.
    wait (dut.gen_prog_ctrl.prog_handshake_bypass_active == 1'b1);
    repeat (3) @(posedge clk);
    bus_write(32'h4000_0038, 32'h0000_0000);

    if (dut.gen_prog_ctrl.prog_handshake_bypass_active !== 1'b1) begin
      $display("[FAIL] bypass active latch cleared too early");
      $fatal(1);
    end

    wait (dut.prog_done_pulse_sig == 1'b1);
    wait (dut.prog_busy == 1'b0);
    repeat (2) @(posedge clk);

    if (dut.gen_prog_ctrl.prog_handshake_bypass_active !== 1'b0) begin
      $display("[FAIL] bypass active latch did not clear after DONE");
      $fatal(1);
    end
    if (!dut.prog_pass || dut.prog_fail) begin
      $display("[FAIL] programming result not PASS after clobber write");
      $fatal(1);
    end

    $display("PROG_BYPASS_LATCH_TB_PASS");
    $finish;
  end

  initial begin
    #5_000_000;
    $display("[FAIL] timeout");
    $fatal(1);
  end
endmodule
