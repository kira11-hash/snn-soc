`timescale 1ns/1ps

module chip_top_hi_tb;
  import snn_soc_pkg::*;

  localparam integer MARKER_BASE_WORD   = 32'h0000_3F00 / 4;
  localparam [31:0] EXPECTED_BOOT_MARK  = 32'hB00710AD;
  localparam [31:0] EXPECTED_SIGNATURE  = 32'h1234_5067;
  localparam [31:0] EXPECTED_RESULT     = 32'h0000_4800;
  localparam [31:0] EXPECTED_DONE_MARK  = 32'hC0DE0002;

  logic clk_pad;
  logic rst_n_pad;
  logic uart_rx_pad;
  logic uart_tx_pad;
  logic spi_cs_n_pad;
  logic spi_sck_pad;
  logic spi_mosi_pad;
  logic spi_miso_pad;
  logic jtag_tck_pad;
  logic jtag_tms_pad;
  logic jtag_tdi_pad;
  logic jtag_tdo_pad;
  logic [7:0] wl_data_pad;
  logic [2:0] wl_group_sel_pad;
  logic       wl_latch_pad;
  logic       cim_start_pad;
  logic       cim_done_pad;
  logic [4:0] bl_sel_pad;
  logic [7:0] bl_data_pad;

  integer i;
  integer error_count;
  integer uart_byte_count;
  logic   uart_busy_d;

  chip_top #(
    .BOOT_ROM_INIT_FILE("../fw/boot_rom/out/boot_rom.hex")
  ) dut (
    .clk_pad(clk_pad),
    .rst_n_pad(rst_n_pad),
    .uart_rx_pad(uart_rx_pad),
    .uart_tx_pad(uart_tx_pad),
    .spi_cs_n_pad(spi_cs_n_pad),
    .spi_sck_pad(spi_sck_pad),
    .spi_mosi_pad(spi_mosi_pad),
    .spi_miso_pad(spi_miso_pad),
    .jtag_tck_pad(jtag_tck_pad),
    .jtag_tms_pad(jtag_tms_pad),
    .jtag_tdi_pad(jtag_tdi_pad),
    .jtag_tdo_pad(jtag_tdo_pad),
    .wl_data_pad(wl_data_pad),
    .wl_group_sel_pad(wl_group_sel_pad),
    .wl_latch_pad(wl_latch_pad),
    .cim_start_pad(cim_start_pad),
    .cim_done_pad(cim_done_pad),
    .bl_sel_pad(bl_sel_pad),
    .bl_data_pad(bl_data_pad)
  );

  spi_flash_model #(
    .INIT_HEX("../fw/boot_rom/out/rom_hi_smoke_flash.hex")
  ) u_spi_flash (
    .spi_cs_n(spi_cs_n_pad),
    .spi_sck (spi_sck_pad),
    .spi_mosi(spi_mosi_pad),
    .spi_miso(spi_miso_pad)
  );

  initial begin
    clk_pad = 1'b0;
    forever #10 clk_pad = ~clk_pad;
  end

  initial begin
    rst_n_pad   = 1'b0;
    uart_rx_pad = 1'b1;
    jtag_tck_pad = 1'b0;
    jtag_tms_pad = 1'b0;
    jtag_tdi_pad = 1'b0;
    cim_done_pad = 1'b0;
    bl_data_pad  = 8'h00;

    for (i = 0; i < (INSTR_SRAM_BYTES / 4); i = i + 1) begin
      dut.u_soc_core.u_instr_sram.mem[i] = 32'h0000_0013;
    end
    for (i = 0; i < (DATA_SRAM_BYTES / 4); i = i + 1) begin
      dut.u_soc_core.u_data_sram.mem[i] = 32'h0000_0000;
    end
    for (i = 0; i < (WEIGHT_SRAM_BYTES / 4); i = i + 1) begin
      dut.u_soc_core.u_weight_sram.mem[i] = 32'h0000_0000;
    end

    repeat (10) @(posedge clk_pad);
    rst_n_pad = 1'b1;
  end

  always @(posedge clk_pad or negedge rst_n_pad) begin
    if (!rst_n_pad) begin
      uart_busy_d <= 1'b0;
      uart_byte_count <= 0;
    end else begin
      uart_busy_d <= dut.u_soc_core.u_uart.tx_busy;
      if (!uart_busy_d && dut.u_soc_core.u_uart.tx_busy) begin
        uart_byte_count <= uart_byte_count + 1;
        $write("%c", dut.u_soc_core.u_uart.txdata_shadow);
      end
    end
  end

  initial begin
    $dumpfile("waves/chip_top_rom_hi_smoke.vcd");
    $dumpvars(0, chip_top_hi_tb);
  end

  initial begin
    error_count = 0;
    wait(rst_n_pad === 1'b1);
    repeat (2) @(posedge clk_pad);
    $display("[INFO] chip_top high ROM smoke start");

    begin : wait_boot
      integer polls;
      for (polls = 0; polls < 600000; polls = polls + 1) begin
        @(posedge clk_pad);
        if (dut.u_soc_core.u_data_sram.mem[MARKER_BASE_WORD + 0] == EXPECTED_BOOT_MARK) begin
          $display("[INFO] boot ROM loaded high app after %0d cycles", polls + 1);
          disable wait_boot;
        end
      end
      $display("[ERR] boot ROM did not load high app, marker=0x%08h",
               dut.u_soc_core.u_data_sram.mem[MARKER_BASE_WORD + 0]);
      error_count = error_count + 1;
    end

    begin : wait_app
      integer polls;
      for (polls = 0; polls < 250000; polls = polls + 1) begin
        @(posedge clk_pad);
        if (dut.u_soc_core.u_data_sram.mem[MARKER_BASE_WORD + 3] == EXPECTED_DONE_MARK) begin
          $display("[INFO] high ROM app completed after %0d cycles", polls + 1);
          disable wait_app;
        end
      end
      $display("[ERR] high ROM app did not complete, done=0x%08h",
               dut.u_soc_core.u_data_sram.mem[MARKER_BASE_WORD + 3]);
      error_count = error_count + 1;
    end

    if (dut.u_soc_core.u_data_sram.mem[MARKER_BASE_WORD + 0] != EXPECTED_BOOT_MARK) error_count++;
    if (dut.u_soc_core.u_data_sram.mem[MARKER_BASE_WORD + 1] != EXPECTED_SIGNATURE) error_count++;
    if (dut.u_soc_core.u_data_sram.mem[MARKER_BASE_WORD + 2] != EXPECTED_RESULT) error_count++;
    if (dut.u_soc_core.u_data_sram.mem[MARKER_BASE_WORD + 3] != EXPECTED_DONE_MARK) error_count++;
    if (uart_byte_count < 16) error_count++;

    if (error_count == 0) begin
      $display("CHIP_TOP_ROM_HI_SMOKE_PASS");
    end else begin
      $display("CHIP_TOP_ROM_HI_SMOKE_FAIL errors=%0d", error_count);
      $fatal(1);
    end
    $finish;
  end
endmodule
