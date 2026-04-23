`timescale 1ns/1ps
//===========================================================================
// tb/silicon_bringup_tb.sv
//
// Exercises fw/silicon_bringup/out/silicon_bringup.hex end-to-end:
//   1. pre-load silicon_bringup.hex into u_instr_sram via $readmemh
//   2. release reset, let E203 run the self-test firmware
//   3. snoop UART TXDATA writes on the bus and append to a char buffer
//   4. search buffer for "SILICON_BRINGUP_DIGITAL_PASS"
//
// Passes when that string appears; fails on any explicit
// "SILICON_BRINGUP_DIGITAL_FAIL_*" tag or on timeout.
//
// Firmware must be built with UART_BAUD_DIV_OVERRIDE=4 for sim speed
// (bit-accurate UART TX timing is NOT tested here; only the CPU-side
// byte-stream through the register write path).
//===========================================================================

module silicon_bringup_tb;
  import snn_soc_pkg::*;

  // DUT I/O
  logic clk;
  logic rst_n;
  logic uart_rx;
  logic uart_tx;
  logic spi_cs_n;
  logic spi_sck;
  logic spi_mosi;
  logic spi_miso;
  logic jtag_tck, jtag_tms, jtag_tdi, jtag_tdo;
  logic [7:0] wl_data_ext;
  logic [2:0] wl_group_sel_ext;
  logic       wl_latch_ext;
  logic       cim_start_ext;
  logic       cim_done_ext;
  logic [4:0] bl_sel_ext;
  logic [7:0] bl_data_ext;

  snn_soc_top #(
    .ENABLE_E203         (1'b1),
    .ENABLE_PROGRAM_MODE (1'b1),
    .ENABLE_PROGRAM_WEIGHT_MODEL (1'b1)
  ) dut (.*);

  // Minimal SPI-flash stub (not exercised by silicon_bringup; kept for signals)
  assign spi_miso = 1'b1;

  // Clock
  initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;  // 50 MHz
  end

  // ------------------------------------------------------------------
  // UART byte snoop: watch the CPU's bus writes to UART.REG_TXDATA
  // ------------------------------------------------------------------
  // uart_ctrl sits at UART_BASE = 0x4000_0200; REG_TXDATA offset 0x00
  localparam [31:0] UART_TXDATA_ADDR = 32'h4000_0200;

  // Character buffer + simple substring matcher
  byte    char_buf [0:2047];
  integer char_count = 0;
  integer error_count = 0;
  logic   pass_seen  = 1'b0;
  logic   fail_seen  = 1'b0;
  logic   new_byte   = 1'b0;  // set for one cycle when a byte is appended

  // Monitor the path into the reg_bank-level bus master seen by
  // u_uart.  u_uart req_valid / req_write / req_addr / req_wdata
  // are driven from bus_interconnect in snn_soc_top.
  always @(posedge clk) begin
    new_byte <= 1'b0;
    if (rst_n && dut.u_uart.req_valid && dut.u_uart.req_write
        && (dut.u_uart.req_addr[7:0] == 8'h00)
        && !dut.u_uart.tx_busy) begin
      if (char_count < 2047) begin
        char_buf[char_count] = byte'(dut.u_uart.req_wdata[7:0]);
        char_count          += 1;
        new_byte            <= 1'b1;
        $write("%c", char_buf[char_count - 1]);  // live echo
      end
    end
  end

  // Substring search over char_buf (simple O(N*M); Icarus-compatible:
  //   no break, no bare return from function).
  function automatic logic find_substr(input string needle);
    integer i, j, n, m;
    logic   mismatch;
    logic   done;
    begin
      n = char_count;
      m = needle.len();
      find_substr = 1'b0;
      done        = 1'b0;
      if (m == 0 || n < m) done = 1'b1;
      for (i = 0; i <= n - m; i++) begin
        if (!done) begin
          mismatch = 1'b0;
          for (j = 0; j < m; j++) begin
            if (!mismatch && char_buf[i + j] != byte'(needle[j])) begin
              mismatch = 1'b1;
            end
          end
          if (!mismatch) begin
            find_substr = 1'b1;
            done        = 1'b1;
          end
        end
      end
    end
  endfunction

  task automatic print_uart_tail();
    integer i, start;
    begin
      start = (char_count > 512) ? char_count - 512 : 0;
      $write("[UART capture, last %0d bytes]\n", char_count - start);
      for (i = start; i < char_count; i++) begin
        $write("%c", char_buf[i]);
      end
      $display("");
    end
  endtask

  // ------------------------------------------------------------------
  // Reset + firmware pre-load + main flow
  // ------------------------------------------------------------------
  integer i;
  integer poll;
  initial begin
    $dumpfile("waves/silicon_bringup.vcd");
    $dumpvars(0, silicon_bringup_tb);

    rst_n        = 1'b0;
    uart_rx      = 1'b1;
    cim_done_ext = 1'b0;
    bl_data_ext  = 8'h00;
    jtag_tck     = 1'b0;
    jtag_tms     = 1'b0;
    jtag_tdi     = 1'b0;

    // C1 boundary regression: shorter buffer than needle must be a clean miss,
    // not an accidental match or out-of-range char_buf access.
    char_count = 5;
    char_buf[0] = "H";
    char_buf[1] = "E";
    char_buf[2] = "L";
    char_buf[3] = "L";
    char_buf[4] = "O";
    if (find_substr("HELLO_WORLD")) begin
      $display("[ERR] find_substr matched with char_count < needle length");
      $fatal(1);
    end
    char_count = 0;

    // NOP-fill then overlay firmware
    for (i = 0; i < (INSTR_SRAM_BYTES / 4); i = i + 1) begin
      dut.u_instr_sram.mem[i] = 32'h0000_0013;
    end
    for (i = 0; i < (DATA_SRAM_BYTES / 4); i = i + 1) begin
      dut.u_data_sram.mem[i] = 32'h0000_0000;
    end
    for (i = 0; i < (WEIGHT_SRAM_BYTES / 4); i = i + 1) begin
      dut.u_weight_sram.mem[i] = 32'h0000_0000;
    end

    $readmemh("../fw/silicon_bringup/out/silicon_bringup.hex", dut.u_instr_sram.mem);

    repeat (10) @(posedge clk);
    rst_n = 1'b1;

    $display("[INFO] silicon_bringup_tb start");

    // Main polling loop: check for PASS / FAIL substrings with time bound.
    // Silicon bring-up runs a full inference + two prog FSM cycles →
    // budget ~15M cycles = 300 ms @ 50MHz; at 20ns/cycle that's 300 ms sim time.
    // Only run the substring search when a new byte is appended — the
    // search itself is O(N*M) and would swamp per-cycle simulation time.
    begin : poll_loop
      for (poll = 0; poll < 15_000_000; poll = poll + 1) begin
        @(posedge clk);
        if (new_byte) begin
          if (!pass_seen && find_substr("SILICON_BRINGUP_DIGITAL_PASS")) begin
            pass_seen = 1'b1;
          end
          if (!fail_seen && find_substr("SILICON_BRINGUP_DIGITAL_FAIL")) begin
            fail_seen = 1'b1;
          end
        end
        if (pass_seen || fail_seen) disable poll_loop;
      end
    end

    // Allow a few more cycles for trailing output
    repeat (200) @(posedge clk);

    if (pass_seen && !fail_seen) begin
      print_uart_tail();
      $display("SILICON_BRINGUP_TB_PASS");
      $finish;
    end else begin
      print_uart_tail();
      if (fail_seen) begin
        $display("[ERR] silicon_bringup reported FAIL");
      end else begin
        $display("[ERR] silicon_bringup timeout without PASS tag");
      end
      $display("SILICON_BRINGUP_TB_FAIL");
      $fatal(1);
    end
  end

endmodule
