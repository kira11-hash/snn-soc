`timescale 1ns/1ps

module e203_tb;
  import snn_soc_pkg::*;

  localparam integer EXPECTED_OUT_COUNT = 100;
  localparam [31:0] EXPECTED_BOOT_MARK  = 32'hB00710AD;
  localparam [31:0] EXPECTED_SIGNATURE  = 32'h1234_5067;
  localparam [31:0] EXPECTED_DONE_MARK  = 32'hC0DE0002;
  localparam [7:0]  EXPECTED_LAST_UART  = 8'h0A;
  localparam integer MARKER_BASE_WORD   = 32'h0000_3F00 / 4;

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

  integer f;
  integer i;
  integer error_count;
  integer uart_byte_count;
  logic uart_busy_seen;
  logic uart_busy_d;

  // ENABLE_PROGRAM_MODE=1: required for fw/main.c boot-time full-array erase to
  //   actually run (otherwise reg_bank interlock latches prog_start_pending
  //   permanently and blocks CIM_CTRL.START).
  // ENABLE_PROGRAM_WEIGHT_MODEL=0: keep the popcount-based cim_macro_blackbox
  //   so the E203 smoke test still produces non-zero inference output. BRAM
  //   weight model (=1) would be zeroed by the boot erase and give count=0.
  //   Sample-alignment / weighted regressions cover numerical BRAM path.
  snn_soc_top #(.ENABLE_E203(1'b1),
                .ENABLE_PROGRAM_MODE(1'b1),
                .ENABLE_PROGRAM_WEIGHT_MODEL(1'b0)) dut (.*);

  spi_flash_model #(
    .INIT_HEX("../fw/out/flash_image.hex")
  ) u_spi_flash (
    .spi_cs_n(spi_cs_n),
    .spi_sck (spi_sck),
    .spi_mosi(spi_mosi),
    .spi_miso(spi_miso)
  );

  initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
  end

  initial begin
    rst_n    = 1'b0;
    uart_rx  = 1'b1;
    cim_done_ext = 1'b0;
    bl_data_ext = 8'h00;
    jtag_tck = 1'b0;
    jtag_tms = 1'b0;
    jtag_tdi = 1'b0;

    for (i = 0; i < (INSTR_SRAM_BYTES / 4); i = i + 1) begin
      dut.u_instr_sram.mem[i] = 32'h0000_0013;
    end
    for (i = 0; i < (DATA_SRAM_BYTES / 4); i = i + 1) begin
      dut.u_data_sram.mem[i] = 32'h0000_0000;
    end
    for (i = 0; i < (WEIGHT_SRAM_BYTES / 4); i = i + 1) begin
      dut.u_weight_sram.mem[i] = 32'h0000_0000;
    end

    $readmemh("../fw/out/bootloader.hex", dut.u_instr_sram.mem);

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      uart_busy_seen <= 1'b0;
      uart_busy_d    <= 1'b0;
      uart_byte_count <= 0;
    end else begin
      uart_busy_d <= dut.u_uart.tx_busy;
      if (dut.u_uart.tx_busy) begin
        uart_busy_seen <= 1'b1;
      end
      if (!uart_busy_d && dut.u_uart.tx_busy) begin
        uart_byte_count <= uart_byte_count + 1;
        $write("%c", dut.u_uart.txdata_shadow);
      end
    end
  end

  initial begin
    $dumpfile("waves/e203_smoke.vcd");
    $dumpvars(0, e203_tb);
  end

  initial begin
    error_count = 0;

    wait(rst_n === 1'b1);
    repeat (2) @(posedge clk);
    $display("[INFO] E203 minimal-area smoke start");

    begin : wait_boot_mark
      integer boot_polls;
      // Bumped from 300000 → 500000 cycles: fw/main.c grew after adding
      // boot-time full-array erase, SPI flash payload therefore grew too
      // (~1.9 KB with -O2). 500k cycles @ 50 MHz = 10 ms, still generous.
      for (boot_polls = 0; boot_polls < 500000; boot_polls = boot_polls + 1) begin
        @(posedge clk);
        if (dut.u_data_sram.mem[MARKER_BASE_WORD + 0] == EXPECTED_BOOT_MARK) begin
          $display("[INFO] Bootloader load completed after %0d cycles, PC=0x%08h",
                   boot_polls + 1, dut.cpu_inspect_pc);
          disable wait_boot_mark;
        end
      end
      $display("[ERR] Bootloader did not finish SPI load, PC=0x%08h", dut.cpu_inspect_pc);
      error_count = error_count + 1;
    end

    begin : wait_signature
      integer sign_polls;
      for (sign_polls = 0; sign_polls < 200000; sign_polls = sign_polls + 1) begin
        @(posedge clk);
        if (dut.u_data_sram.mem[MARKER_BASE_WORD + 1] == EXPECTED_SIGNATURE) begin
          $display("[INFO] Signature observed after %0d cycles, PC=0x%08h",
                   sign_polls + 1, dut.cpu_inspect_pc);
          disable wait_signature;
        end
      end
      $display("[ERR] Signature write not observed, PC=0x%08h", dut.cpu_inspect_pc);
      error_count = error_count + 1;
    end

    begin : wait_uart_start
      integer uart_polls;
      for (uart_polls = 0; uart_polls < 6000; uart_polls = uart_polls + 1) begin
        @(posedge clk);
        if (uart_busy_seen) begin
          $display("[INFO] UART activity observed, current TXDATA shadow=0x%02h",
                   dut.u_uart.txdata_shadow);
          disable wait_uart_start;
        end
      end
      $display("[ERR] UART activity not completed, PC=0x%08h", dut.cpu_inspect_pc);
      error_count = error_count + 1;
    end

    begin : wait_result_and_done
      integer done_polls;
      for (done_polls = 0; done_polls < 260000; done_polls = done_polls + 1) begin
        @(posedge clk);
        if ((dut.u_data_sram.mem[MARKER_BASE_WORD + 2] == EXPECTED_OUT_COUNT) &&
            (dut.u_data_sram.mem[MARKER_BASE_WORD + 3] == EXPECTED_DONE_MARK)) begin
          $display("[INFO] OUT_FIFO_COUNT=%0d stored by firmware after %0d cycles",
                   dut.u_data_sram.mem[MARKER_BASE_WORD + 2], done_polls + 1);
          disable wait_result_and_done;
        end
      end
      $display("[ERR] Firmware did not complete result/done flow, count=%0d done=0x%08h PC=0x%08h",
               dut.u_data_sram.mem[MARKER_BASE_WORD + 2],
               dut.u_data_sram.mem[MARKER_BASE_WORD + 3],
               dut.cpu_inspect_pc);
      error_count = error_count + 1;
    end

    if (!uart_busy_seen) begin
      $display("[ERR] UART busy never asserted");
      error_count = error_count + 1;
    end
    if (uart_byte_count < 16) begin
      $display("[ERR] UART debug output too short: %0d bytes", uart_byte_count);
      error_count = error_count + 1;
    end
    if (dut.u_uart.txdata_shadow != EXPECTED_LAST_UART) begin
      $display("[ERR] UART TXDATA shadow mismatch: 0x%02h", dut.u_uart.txdata_shadow);
      error_count = error_count + 1;
    end
    if (dut.u_data_sram.mem[MARKER_BASE_WORD + 0] != EXPECTED_BOOT_MARK) begin
      $display("[ERR] Boot marker mismatch: 0x%08h", dut.u_data_sram.mem[MARKER_BASE_WORD + 0]);
      error_count = error_count + 1;
    end
    if (dut.u_data_sram.mem[MARKER_BASE_WORD + 1] != EXPECTED_SIGNATURE) begin
      $display("[ERR] Signature mismatch: 0x%08h", dut.u_data_sram.mem[MARKER_BASE_WORD + 1]);
      error_count = error_count + 1;
    end
    if (dut.u_data_sram.mem[MARKER_BASE_WORD + 2] != EXPECTED_OUT_COUNT) begin
      $display("[ERR] OUT count mismatch: %0d", dut.u_data_sram.mem[MARKER_BASE_WORD + 2]);
      error_count = error_count + 1;
    end
    if (dut.u_data_sram.mem[MARKER_BASE_WORD + 3] != EXPECTED_DONE_MARK) begin
      $display("[ERR] FW done marker mismatch: 0x%08h", dut.u_data_sram.mem[MARKER_BASE_WORD + 3]);
      error_count = error_count + 1;
    end

    if (error_count == 0) begin
      $display("E203_SMOKETEST_PASS");
    end else begin
      $display("E203_SMOKETEST_FAIL errors=%0d", error_count);
      $fatal(1);
    end

    #100;
    $finish;
  end
endmodule
