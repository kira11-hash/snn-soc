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
  logic [2:0] prog_op_ext;      // V1 external programming (2026-04-24)
  logic [3:0] prog_level_ext;

  // FW-C1 fix（2026-05-02 audit follow-up）：
  // 旧版用 snn_soc_top + default ENABLE_BOOT_ROM=0，把 silicon_bringup.hex 装到
  // instr_sram@0x0；这与流片 chip_top 配置（ENABLE_BOOT_ROM=1，物理 INSTR_SRAM
  // 基址 0x1000）完全失配。FW B1 fix 已让 silicon_bringup.elf 链到 0x1000
  // （link_app.ld），现在改 dut 为 chip_top + ENABLE_BOOT_ROM=1，并用一个
  // stub boot_rom hex（首字节 jal x0,+0x1000，跳过 SPI flash boot 流程直接落到
  // INSTR_SRAM）让 CPU 在 PC=0x1000 处执行 silicon_bringup —— 与硅片真实路径
  // 一致。
  //
  // ⚠ 注意：stub ROM 不验证 SPI flash boot 路径（boot_rom_main.c 的
  // magic header validation / SPI command pump）。完整 Day-2 硅片路径
  // 由 chip_top_rom_smoke_tb / chip_top_rom_hi_smoke_tb 覆盖，这里只验证
  // silicon_bringup 在 PC=0x1000 启动 + UART 抓 PASS marker。
  chip_top #(
    .BOOT_ROM_INIT_FILE("../tb/silicon_bringup_stub_rom.hex")
  ) dut (
    .clk_pad          (clk),
    .rst_n_pad        (rst_n),
    .uart_rx_pad      (uart_rx),
    .uart_tx_pad      (uart_tx),
    .spi_cs_n_pad     (spi_cs_n),
    .spi_sck_pad      (spi_sck),
    .spi_mosi_pad     (spi_mosi),
    .spi_miso_pad     (spi_miso),
    .jtag_tck_pad     (jtag_tck),
    .jtag_tms_pad     (jtag_tms),
    .jtag_tdi_pad     (jtag_tdi),
    .jtag_tdo_pad     (jtag_tdo),
    .wl_data_pad      (wl_data_ext),
    .wl_group_sel_pad (wl_group_sel_ext),
    .wl_latch_pad     (wl_latch_ext),
    .cim_start_pad    (cim_start_ext),
    .cim_done_pad     (cim_done_ext),
    .bl_sel_pad       (bl_sel_ext),
    .bl_data_pad      (bl_data_ext),
    .prog_op_pad      (prog_op_ext),
    .prog_level_pad   (prog_level_ext)
  );

  // SPI flash 不被 stub ROM 路径触发（jal x0,+0x1000 直接跳过 SPI boot）；
  // 但 spi_miso 必须有定义否则会是 X 传播。
  assign spi_miso = 1'b1;

  // 注：firmware preload（$readmemh）由下面 main initial 块统一处理，
  // 与 NOP-fill / data_sram / weight_sram clear 在同一时序节点。

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

  // Monitor the path into the reg_bank-level bus master seen by u_uart.
  // FW-C1 fix: 现在 dut 是 chip_top，u_uart 在 dut.u_soc_core.u_uart。
  always @(posedge clk) begin
    new_byte <= 1'b0;
    if (rst_n && dut.u_soc_core.u_uart.req_valid && dut.u_soc_core.u_uart.req_write
        && (dut.u_soc_core.u_uart.req_addr[7:0] == 8'h00)
        && !dut.u_soc_core.u_uart.tx_busy) begin
      if (char_count < 2047) begin
        char_buf[char_count] = byte'(dut.u_soc_core.u_uart.req_wdata[7:0]);
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
    // FW-C1 fix: 现在通过 chip_top 实例，hierarchy 是 dut.u_soc_core.u_*
    for (i = 0; i < (INSTR_SRAM_BYTES / 4); i = i + 1) begin
      dut.u_soc_core.u_instr_sram.mem[i] = 32'h0000_0013;
    end
    for (i = 0; i < (DATA_SRAM_BYTES / 4); i = i + 1) begin
      dut.u_soc_core.u_data_sram.mem[i] = 32'h0000_0000;
    end
    for (i = 0; i < (WEIGHT_SRAM_BYTES / 4); i = i + 1) begin
      dut.u_soc_core.u_weight_sram.mem[i] = 32'h0000_0000;
    end

    // 注：silicon_bringup.hex 现在按 link_app.ld（origin=0x1000）链接，
    // 但 instr_sram 的 mem 数组索引仍从 0 开始（基址映射在 SoC 总线层处理），
    // 所以 $readmemh 直接装到 mem[0..N]（与硅片 boot_rom 跳到 0x1000 后
    // CPU 取指 instr_sram[0] 的物理对应一致）。
    $readmemh("../fw/silicon_bringup/out/silicon_bringup.hex", dut.u_soc_core.u_instr_sram.mem);

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
