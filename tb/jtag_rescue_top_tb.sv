`timescale 1ns/1ps

module jtag_rescue_top_tb;
  import snn_soc_pkg::*;

  localparam logic [3:0] IR_IDCODE = 4'h1;
  localparam logic [3:0] IR_MEMACC = 4'h2;
  localparam logic [3:0] IR_CPUCTL = 4'h3;
  localparam logic [31:0] IDCODE_VALUE = 32'hE203_0001;
  localparam logic [31:0] JTAG_MAGIC = 32'h4A54_4147;
  localparam logic [31:0] WEIGHT_TEST_WORD = 32'h1357_9BDF;
  localparam int UART_EXPECT_LEN = 15;
  localparam int MEMACC_IDLE_FAST = 64;
  localparam int MEMACC_IDLE_SLOW = 2048;

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

  logic uart_busy_d;
  integer uart_byte_count;
  logic [7:0] uart_bytes [0:63];
  logic [31:0] rescue_imem [0:(INSTR_SRAM_BYTES/4)-1];
  integer pass_count;

  snn_soc_top #(.ENABLE_E203(1'b1)) dut (.*);

  initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
  end

  function automatic logic [68:0] pack_memacc(
    input logic        write,
    input logic [31:0] addr,
    input logic [3:0]  wstrb,
    input logic [31:0] wdata
  );
    begin
      pack_memacc = '0;
      pack_memacc[0]     = write;
      pack_memacc[32:1]  = addr;
      pack_memacc[36:33] = wstrb;
      pack_memacc[68:37] = wdata;
    end
  endfunction

  task automatic fail_now(input string label);
    begin
      $display("[FAIL] %s", label);
      $fatal(1);
    end
  endtask

  task automatic expect_u32(
    input logic [31:0] got,
    input logic [31:0] exp,
    input string       label
  );
    begin
      if (got !== exp) begin
        $display("[FAIL] %s got=0x%08h exp=0x%08h", label, got, exp);
        $fatal(1);
      end
      pass_count = pass_count + 1;
      $display("[PASS] %s = 0x%08h", label, got);
    end
  endtask

  task automatic expect_bit(
    input logic got,
    input logic exp,
    input string label
  );
    begin
      if (got !== exp) begin
        $display("[FAIL] %s got=%0b exp=%0b", label, got, exp);
        $fatal(1);
      end
      pass_count = pass_count + 1;
      $display("[PASS] %s = %0b", label, got);
    end
  endtask

  task automatic jtag_step(
    input  logic tms_i,
    input  logic tdi_i,
    output logic tdo_o
  );
    begin
      jtag_tms = tms_i;
      jtag_tdi = tdi_i;
      #2;
      jtag_tck = 1'b1;
      #2;
      tdo_o = jtag_tdo;
      jtag_tck = 1'b0;
      #2;
    end
  endtask

  task automatic jtag_run_idle(input integer cycles);
    integer i;
    logic dummy;
    begin
      for (i = 0; i < cycles; i = i + 1) begin
        jtag_step(1'b0, 1'b0, dummy);
      end
    end
  endtask

  task automatic jtag_tap_reset;
    integer i;
    logic dummy;
    begin
      for (i = 0; i < 6; i = i + 1) begin
        jtag_step(1'b1, 1'b0, dummy);
      end
      jtag_step(1'b0, 1'b0, dummy);
    end
  endtask

  task automatic jtag_shift_ir(input logic [3:0] ir);
    integer i;
    logic dummy;
    begin
      jtag_step(1'b1, 1'b0, dummy);
      jtag_step(1'b1, 1'b0, dummy);
      jtag_step(1'b0, 1'b0, dummy);
      jtag_step(1'b0, 1'b0, dummy);
      for (i = 0; i < 4; i = i + 1) begin
        jtag_step((i == 3), ir[i], dummy);
      end
      jtag_step(1'b1, 1'b0, dummy);
      jtag_step(1'b0, 1'b0, dummy);
    end
  endtask

  task automatic jtag_shift_dr(
    input  integer       nbits,
    input  logic [68:0]  tx,
    output logic [68:0]  rx
  );
    integer i;
    logic tdo_bit;
    begin
      rx = '0;
      jtag_step(1'b1, 1'b0, tdo_bit);
      jtag_step(1'b0, 1'b0, tdo_bit);
      jtag_step(1'b0, 1'b0, tdo_bit);
      for (i = 0; i < nbits; i = i + 1) begin
        jtag_step((i == (nbits - 1)), tx[i], tdo_bit);
        rx[i] = tdo_bit;
      end
      jtag_step(1'b1, 1'b0, tdo_bit);
      jtag_step(1'b0, 1'b0, tdo_bit);
    end
  endtask

  task automatic memacc_scan(
    input logic        write,
    input logic [31:0] addr,
    input logic [3:0]  wstrb,
    input logic [31:0] wdata,
    output logic [68:0] rsp
  );
    begin
      jtag_shift_ir(IR_MEMACC);
      jtag_shift_dr(69, pack_memacc(write, addr, wstrb, wdata), rsp);
    end
  endtask

  task automatic memacc_issue(
    input logic        write,
    input logic [31:0] addr,
    input logic [3:0]  wstrb,
    input logic [31:0] wdata
  );
    logic [68:0] dummy;
    begin
      memacc_scan(write, addr, wstrb, wdata, dummy);
    end
  endtask

  task automatic memacc_finish_wait(
    input  integer      idle_cycles,
    output logic [31:0] rdata,
    output logic        err,
    output logic        done
  );
    logic [68:0] rsp;
    begin
      jtag_run_idle(idle_cycles);
      memacc_scan(1'b0, ADDR_REG_BASE, 4'h0, 32'h0, rsp);
      rdata = rsp[31:0];
      err   = rsp[32];
      done  = rsp[33];
      if (!done) begin
        fail_now("MEMACC response timeout");
      end
      jtag_run_idle(idle_cycles);
    end
  endtask

  task automatic memacc_do_wait(
    input  integer      idle_cycles,
    input  logic        write,
    input  logic [31:0] addr,
    input  logic [3:0]  wstrb,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        err
  );
    logic done;
    begin
      memacc_issue(write, addr, wstrb, wdata);
      memacc_finish_wait(idle_cycles, rdata, err, done);
    end
  endtask

  task automatic memacc_do(
    input  logic        write,
    input  logic [31:0] addr,
    input  logic [3:0]  wstrb,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        err
  );
    begin
      memacc_do_wait(MEMACC_IDLE_FAST, write, addr, wstrb, wdata, rdata, err);
    end
  endtask

  task automatic cpuctl_write(input logic hold);
    logic [68:0] payload;
    logic [68:0] dummy;
    begin
      payload = '0;
      payload[0] = hold;
      jtag_shift_ir(IR_CPUCTL);
      jtag_shift_dr(2, payload, dummy);
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic cpuctl_scan(
    input  logic writeback_hold,
    output logic hold
  );
    logic [68:0] payload;
    logic [68:0] rsp;
    begin
      payload = '0;
      payload[0] = writeback_hold;
      jtag_shift_ir(IR_CPUCTL);
      jtag_shift_dr(2, payload, rsp);
      hold = rsp[0];
    end
  endtask

  task automatic load_rescue_program;
    integer fd;
    integer code;
    integer rescue_words;
    integer idx;
    logic [31:0] rdata;
    logic        err;
    begin
      fd = $fopen("../fw/out/jtag_rescue_words.txt", "r");
      if (fd == 0) begin
        fail_now("open jtag_rescue_words.txt");
      end
      code = $fscanf(fd, "%d", rescue_words);
      $fclose(fd);
      if ((code != 1) || (rescue_words <= 0) || (rescue_words > (INSTR_SRAM_BYTES/4))) begin
        fail_now("parse rescue firmware word count");
      end

      $readmemh("../fw/out/jtag_rescue_imem.hex", rescue_imem, 0, rescue_words - 1);

      for (idx = 0; idx < rescue_words; idx = idx + 1) begin
        memacc_do(1'b1, ADDR_INSTR_BASE + (idx * 4), 4'hF, rescue_imem[idx], rdata, err);
        if (err) begin
          $display("[FAIL] IMEM writeback err at word %0d addr=0x%08h", idx, ADDR_INSTR_BASE + (idx * 4));
          $fatal(1);
        end
      end

      for (idx = 0; idx < rescue_words; idx = idx + 1) begin
        memacc_do(1'b0, ADDR_INSTR_BASE + (idx * 4), 4'h0, 32'h0, rdata, err);
        if (err) begin
          $display("[FAIL] IMEM readback err at word %0d addr=0x%08h", idx, ADDR_INSTR_BASE + (idx * 4));
          $fatal(1);
        end
        if (rdata !== rescue_imem[idx]) begin
          $display("[FAIL] IMEM readback mismatch idx=%0d got=0x%08h exp=0x%08h",
                   idx, rdata, rescue_imem[idx]);
          $fatal(1);
        end
      end

      pass_count = pass_count + 1;
      $display("[PASS] Rescue IMEM load/readback words=%0d", rescue_words);
    end
  endtask

  task automatic expect_uart_message;
    integer poll;
    reg [8*UART_EXPECT_LEN-1:0] expected;
    integer idx;
    begin
      expected = "JTAG RESCUE OK\n";
      begin : wait_uart
        for (poll = 0; poll < 200000; poll = poll + 1) begin
          @(posedge clk);
          if (uart_byte_count >= UART_EXPECT_LEN) begin
            disable wait_uart;
          end
        end
      end
      if (uart_byte_count < UART_EXPECT_LEN) begin
        $display("[FAIL] UART message timeout count=%0d", uart_byte_count);
        $fatal(1);
      end
      for (idx = 0; idx < UART_EXPECT_LEN; idx = idx + 1) begin
        if (uart_bytes[idx] !== expected[8*(UART_EXPECT_LEN-idx)-1 -: 8]) begin
          $display("[FAIL] UART byte %0d got=0x%02h exp=0x%02h",
                   idx, uart_bytes[idx], expected[8*(UART_EXPECT_LEN-idx)-1 -: 8]);
          $fatal(1);
        end
      end
      pass_count = pass_count + 1;
      $display("[PASS] Rescue UART message captured");
    end
  endtask

  initial begin
    integer idx;
    for (idx = 0; idx < (INSTR_SRAM_BYTES / 4); idx = idx + 1) begin
      dut.u_instr_sram.mem[idx] = 32'h0000_0013;
      rescue_imem[idx] = 32'h0000_0000;
    end
    for (idx = 0; idx < (DATA_SRAM_BYTES / 4); idx = idx + 1) begin
      dut.u_data_sram.mem[idx] = 32'h0000_0000;
    end
    for (idx = 0; idx < (WEIGHT_SRAM_BYTES / 4); idx = idx + 1) begin
      dut.u_weight_sram.mem[idx] = 32'h0000_0000;
    end

    rst_n = 1'b0;
    uart_rx = 1'b1;
    spi_miso = 1'b0;
    jtag_tck = 1'b0;
    jtag_tms = 1'b0;
    jtag_tdi = 1'b0;
    cim_done_ext = 1'b0;
    bl_data_ext = 8'h00;
    uart_busy_d = 1'b0;
    uart_byte_count = 0;
    pass_count = 0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      uart_busy_d <= 1'b0;
      uart_byte_count <= 0;
    end else begin
      uart_busy_d <= dut.u_uart.tx_busy;
      if (!uart_busy_d && dut.u_uart.tx_busy) begin
        uart_bytes[uart_byte_count] <= dut.u_uart.txdata_shadow;
        uart_byte_count <= uart_byte_count + 1;
      end
    end
  end

  initial begin
    logic [68:0] dr_rsp;
    logic [31:0] rdata;
    logic        err;
    logic        done;
    logic        hold;
    integer      poll;

    $dumpfile("waves/jtag_rescue_top.vcd");
    $dumpvars(0, jtag_rescue_top_tb);

    wait(rst_n === 1'b1);
    repeat (2) @(posedge clk);
    $display("[INFO] jtag_rescue_top system test start");

    jtag_tap_reset();
    jtag_shift_ir(IR_IDCODE);
    jtag_shift_dr(32, '0, dr_rsp);
    expect_u32(dr_rsp[31:0], IDCODE_VALUE, "IDCODE");

    cpuctl_write(1'b1);
    cpuctl_scan(1'b1, hold);
    expect_bit(hold, 1'b1, "CPUCTL.hold_readback");
    expect_bit(dut.cpu_reset_hold_effective, 1'b1, "CPU.reset_hold_effective");

    load_rescue_program();

    memacc_do(1'b1, ADDR_DATA_BASE, 4'hF, JTAG_MAGIC, rdata, err);
    expect_bit(err, 1'b0, "DMEM.magic_write_err");
    memacc_do(1'b0, ADDR_DATA_BASE, 4'h0, 32'h0, rdata, err);
    expect_bit(err, 1'b0, "DMEM.magic_read_err");
    expect_u32(rdata, JTAG_MAGIC, "DMEM.magic_readback");

    cpuctl_write(1'b0);
    cpuctl_scan(1'b0, hold);
    expect_bit(hold, 1'b0, "CPUCTL.release_readback");
    repeat (8) @(posedge clk);
    expect_bit(dut.cpu_reset_hold_effective, 1'b0, "CPU.reset_hold_released");

    expect_uart_message();

    memacc_do_wait(MEMACC_IDLE_SLOW, 1'b1, ADDR_WEIGHT_BASE + 32'h8, 4'hF, WEIGHT_TEST_WORD, rdata, err);
    expect_bit(err, 1'b0, "WEIGHT.live_write_err");
    memacc_do_wait(MEMACC_IDLE_SLOW, 1'b0, ADDR_WEIGHT_BASE + 32'h8, 4'h0, 32'h0, rdata, err);
    expect_bit(err, 1'b0, "WEIGHT.live_read_err");
    expect_u32(rdata, WEIGHT_TEST_WORD, "WEIGHT.live_readback");

    force dut.cpu_bridge_busy = 1'b1;
    memacc_issue(1'b0, ADDR_DATA_BASE, 4'h0, 32'h0);
    repeat (32) @(posedge clk);
    expect_bit(dut.jtag_grant, 1'b0, "Timeout.grant_blocked_pre_timeout");

    begin : wait_timeout
      for (poll = 0; poll < 400; poll = poll + 1) begin
        @(posedge clk);
        if (dut.jtag_timeout_force) begin
          disable wait_timeout;
        end
      end
      fail_now("Timeout.force not asserted");
    end

    expect_bit(dut.jtag_timeout_force, 1'b1, "Timeout.force_asserted");
    expect_bit(dut.cpu_reset_hold_effective, 1'b1, "Timeout.cpu_reset_hold_effective");
    expect_bit(dut.cpu_local_rst_n, 1'b0, "Timeout.cpu_local_rst_low");

    release dut.cpu_bridge_busy;

    begin : wait_busy_clear
      for (poll = 0; poll < 32; poll = poll + 1) begin
        @(posedge clk);
        if (!dut.cpu_bridge_busy) begin
          disable wait_busy_clear;
        end
      end
      fail_now("CPU bridge busy did not clear after timeout release");
    end

    memacc_finish_wait(MEMACC_IDLE_SLOW, rdata, err, done);
    expect_bit(done, 1'b1, "Timeout.read_done");
    expect_bit(err, 1'b0, "Timeout.read_err");
    expect_u32(rdata, JTAG_MAGIC, "Timeout.read_rdata");

    repeat (8) @(posedge clk);
    expect_bit(dut.jtag_timeout_force, 1'b0, "Timeout.force_cleared");
    expect_bit(dut.cpu_reset_hold_effective, 1'b0, "Timeout.cpu_released");

    $display("[RESULT] PASS=%0d", pass_count);
    $display("JTAG_RESCUE_TOP_PASS");
    #100;
    $finish;
  end
endmodule
