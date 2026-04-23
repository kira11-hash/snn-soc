`timescale 1ns/1ps
//==========================================================================
// prog_pad_encoder_tb
//
// Verifies that the external programming sideband pads exported by
// snn_soc_top (`prog_op_ext` / `prog_level_ext`) match the actual internal
// programming phases driven by cim_program_ctrl:
//   - erase cell      -> 3'b001
//   - write cell      -> 3'b010
//   - verify readback -> 3'b011
//   - erase full      -> 3'b100
//==========================================================================
module prog_pad_encoder_tb;
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
  logic [2:0] prog_op_ext;
  logic [3:0] prog_level_ext;

  logic seen_erase_cell, seen_write, seen_verify, seen_erase_full;

  initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
  end

  snn_soc_top #(
    .ENABLE_PROGRAM_MODE(1'b1),
    .ENABLE_PROGRAM_WEIGHT_MODEL(1'b1)
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

  task automatic wait_prog_done;
    begin
      wait (dut.prog_done_pulse_sig == 1'b1);
      wait (dut.prog_busy == 1'b0);
      repeat (2) @(posedge clk);
    end
  endtask

  function automatic [2:0] expected_prog_op;
    begin
      expected_prog_op =
          (dut.prog_busy && dut.verify_en_sig)                    ? 3'b011 :
          (dut.prog_busy && dut.prog_en_sig)                      ? 3'b010 :
          (dut.prog_busy && dut.erase_en_sig && dut.prog_full_array)  ? 3'b100 :
          (dut.prog_busy && dut.erase_en_sig && !dut.prog_full_array) ? 3'b001 :
          3'b000;
    end
  endfunction

  always @(posedge clk) begin
    if (!rst_n) begin
      seen_erase_cell <= 1'b0;
      seen_write      <= 1'b0;
      seen_verify     <= 1'b0;
      seen_erase_full <= 1'b0;
    end else begin
      if (prog_op_ext !== expected_prog_op()) begin
        $display("[FAIL] prog_op_ext mismatch: got=%b exp=%b busy=%0b prog_en=%0b erase_en=%0b verify_en=%0b full=%0b",
                 prog_op_ext, expected_prog_op(), dut.prog_busy, dut.prog_en_sig,
                 dut.erase_en_sig, dut.verify_en_sig, dut.prog_full_array);
        $fatal(1);
      end
      if (prog_level_ext !== dut.prog_level) begin
        $display("[FAIL] prog_level_ext mismatch: got=%0d exp=%0d",
                 prog_level_ext, dut.prog_level);
        $fatal(1);
      end
      if (prog_op_ext == 3'b001) seen_erase_cell <= 1'b1;
      if (prog_op_ext == 3'b010) seen_write      <= 1'b1;
      if (prog_op_ext == 3'b011) seen_verify     <= 1'b1;
      if (prog_op_ext == 3'b100) seen_erase_full <= 1'b1;
      if (prog_op_ext[2] && prog_op_ext[1]) begin
        $display("[FAIL] reserved prog_op_ext encoding observed: %b", prog_op_ext);
        $fatal(1);
      end
    end
  end

  initial begin
    rst_n        = 1'b0;
    uart_rx      = 1'b1;
    spi_miso     = 1'b1;
    jtag_tck     = 1'b0;
    jtag_tms     = 1'b0;
    jtag_tdi     = 1'b0;
    cim_done_ext = 1'b0;
    bl_data_ext  = 8'h00;
    bus_idle();
    seen_erase_cell = 1'b0;
    seen_write      = 1'b0;
    seen_verify     = 1'b0;
    seen_erase_full = 1'b0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    bus_write(32'h4000_003C, 32'd5); // row
    bus_write(32'h4000_0040, 32'd3); // col

    // write cell, level=4
    bus_write(32'h4000_0038, 32'h0000_0041);
    wait_prog_done();

    // erase cell
    bus_write(32'h4000_0038, 32'h0000_0003);
    wait_prog_done();

    // erase full array
    bus_write(32'h4000_0038, 32'h0000_0007);
    wait_prog_done();

    if (!seen_write || !seen_verify || !seen_erase_cell || !seen_erase_full) begin
      $display("[FAIL] missing op coverage: write=%0b verify=%0b erase_cell=%0b erase_full=%0b",
               seen_write, seen_verify, seen_erase_cell, seen_erase_full);
      $fatal(1);
    end

    $display("PROG_PAD_ENCODER_TB_PASS");
    $finish;
  end

  initial begin
    #8_000_000;
    $display("[FAIL] timeout");
    $fatal(1);
  end
endmodule
