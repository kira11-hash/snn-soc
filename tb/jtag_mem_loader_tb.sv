`timescale 1ns/1ps

module jtag_mem_loader_tb;
  import snn_soc_pkg::*;

  localparam logic [3:0] IR_IDCODE = 4'h1;
  localparam logic [3:0] IR_MEMACC = 4'h2;
  localparam logic [3:0] IR_CPUCTL = 4'h3;
  localparam logic [31:0] IDCODE_VALUE = 32'hE203_0001;

  logic rst_n;
  logic clk;
  logic jtag_tck;
  logic jtag_tms;
  logic jtag_tdi;
  logic jtag_tdo;

  logic        mem_req_pending;
  logic        mem_req_grant;
  logic        mem_m_valid;
  logic        mem_m_write;
  logic [31:0] mem_m_addr;
  logic [3:0]  mem_m_wstrb;
  logic [31:0] mem_m_wdata;
  logic        mem_m_ready;
  logic        mem_m_rvalid;
  logic [31:0] mem_m_rdata;
  logic        cpu_reset_hold;

  logic [31:0] instr_mem [0:63];
  logic [31:0] data_mem  [0:63];
  logic [31:0] weight_mem[0:63];
  logic        rsp_valid_q;
  logic        rsp_write_q;
  logic [31:0] rsp_rdata_q;
  integer      pass_count;

  jtag_mem_loader dut (
    .rst_n         (rst_n),
    .clk           (clk),
    .jtag_tck      (jtag_tck),
    .jtag_tms      (jtag_tms),
    .jtag_tdi      (jtag_tdi),
    .jtag_tdo      (jtag_tdo),
    .mem_req_pending(mem_req_pending),
    .mem_req_grant (mem_req_grant),
    .mem_m_valid   (mem_m_valid),
    .mem_m_write   (mem_m_write),
    .mem_m_addr    (mem_m_addr),
    .mem_m_wstrb   (mem_m_wstrb),
    .mem_m_wdata   (mem_m_wdata),
    .mem_m_ready   (mem_m_ready),
    .mem_m_rvalid  (mem_m_rvalid),
    .mem_m_rdata   (mem_m_rdata),
    .cpu_reset_hold(cpu_reset_hold)
  );

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
      pack_memacc[0]    = write;
      pack_memacc[32:1] = addr;
      pack_memacc[36:33]= wstrb;
      pack_memacc[68:37]= wdata;
    end
  endfunction

  function automatic logic [31:0] mem_read_word(input logic [31:0] addr);
    integer idx;
    begin
      if ((addr >= ADDR_INSTR_BASE) && (addr <= ADDR_INSTR_END)) begin
        idx = (addr - ADDR_INSTR_BASE) >> 2;
        mem_read_word = instr_mem[idx];
      end else if ((addr >= ADDR_DATA_BASE) && (addr <= ADDR_DATA_END)) begin
        idx = (addr - ADDR_DATA_BASE) >> 2;
        mem_read_word = data_mem[idx];
      end else if ((addr >= ADDR_WEIGHT_BASE) && (addr <= ADDR_WEIGHT_END)) begin
        idx = (addr - ADDR_WEIGHT_BASE) >> 2;
        mem_read_word = weight_mem[idx];
      end else begin
        mem_read_word = 32'h0;
      end
    end
  endfunction

  task automatic mem_write_word(
    input logic [31:0] addr,
    input logic [31:0] wdata,
    input logic [3:0]  wstrb
  );
    integer idx;
    begin
      if ((addr >= ADDR_INSTR_BASE) && (addr <= ADDR_INSTR_END)) begin
        idx = (addr - ADDR_INSTR_BASE) >> 2;
        if (wstrb[0]) instr_mem[idx][7:0]   = wdata[7:0];
        if (wstrb[1]) instr_mem[idx][15:8]  = wdata[15:8];
        if (wstrb[2]) instr_mem[idx][23:16] = wdata[23:16];
        if (wstrb[3]) instr_mem[idx][31:24] = wdata[31:24];
      end else if ((addr >= ADDR_DATA_BASE) && (addr <= ADDR_DATA_END)) begin
        idx = (addr - ADDR_DATA_BASE) >> 2;
        if (wstrb[0]) data_mem[idx][7:0]   = wdata[7:0];
        if (wstrb[1]) data_mem[idx][15:8]  = wdata[15:8];
        if (wstrb[2]) data_mem[idx][23:16] = wdata[23:16];
        if (wstrb[3]) data_mem[idx][31:24] = wdata[31:24];
      end else if ((addr >= ADDR_WEIGHT_BASE) && (addr <= ADDR_WEIGHT_END)) begin
        idx = (addr - ADDR_WEIGHT_BASE) >> 2;
        if (wstrb[0]) weight_mem[idx][7:0]   = wdata[7:0];
        if (wstrb[1]) weight_mem[idx][15:8]  = wdata[15:8];
        if (wstrb[2]) weight_mem[idx][23:16] = wdata[23:16];
        if (wstrb[3]) weight_mem[idx][31:24] = wdata[31:24];
      end
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

  task automatic jtag_run_idle(input integer cycles);
    integer i;
    logic dummy;
    begin
      for (i = 0; i < cycles; i = i + 1) begin
        jtag_step(1'b0, 1'b0, dummy);
      end
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

  task automatic memacc_do(
    input  logic        write,
    input  logic [31:0] addr,
    input  logic [3:0]  wstrb,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        err
  );
    logic done;
    logic [68:0] rsp;
    begin
      memacc_issue(write, addr, wstrb, wdata);
      jtag_run_idle(32);
      memacc_scan(1'b0, ADDR_REG_BASE, 4'h0, 32'h0, rsp);
      rdata = rsp[31:0];
      err   = rsp[32];
      done  = rsp[33];
      if (!done) begin
        $display("[FAIL] memacc timeout addr=0x%08h", addr);
        $fatal(1);
      end
      jtag_run_idle(32);
    end
  endtask

  task automatic cpuctl_write(input logic hold);
    logic [68:0] dummy;
    logic [68:0] payload;
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

  initial begin
    integer idx;
    for (idx = 0; idx < 64; idx = idx + 1) begin
      instr_mem[idx]  = 32'h0;
      data_mem[idx]   = 32'h0;
      weight_mem[idx] = 32'h0;
    end
    rst_n         = 1'b0;
    jtag_tck      = 1'b0;
    jtag_tms      = 1'b0;
    jtag_tdi      = 1'b0;
    mem_req_grant = 1'b1;
    mem_m_ready   = 1'b0;
    mem_m_rvalid  = 1'b0;
    mem_m_rdata   = 32'h0;
    pass_count    = 0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rsp_valid_q <= 1'b0;
      rsp_write_q <= 1'b0;
      rsp_rdata_q <= 32'h0;
      mem_m_ready <= 1'b0;
      mem_m_rvalid<= 1'b0;
      mem_m_rdata <= 32'h0;
    end else begin
      mem_m_ready  <= rsp_valid_q && rsp_write_q;
      mem_m_rvalid <= rsp_valid_q && !rsp_write_q;
      mem_m_rdata  <= rsp_valid_q && !rsp_write_q ? rsp_rdata_q : 32'h0;
      rsp_valid_q  <= 1'b0;

      if (mem_m_valid && mem_req_grant) begin
        rsp_valid_q <= 1'b1;
        rsp_write_q <= mem_m_write;
        if (mem_m_write) begin
          mem_write_word(mem_m_addr, mem_m_wdata, mem_m_wstrb);
          rsp_rdata_q <= 32'h0;
        end else begin
          rsp_rdata_q <= mem_read_word(mem_m_addr);
        end
      end
    end
  end

  initial begin : test_main
    logic [68:0] dr_rsp;
    logic [31:0] rdata;
    logic        err;
    logic        hold;
    logic        done;

    wait(rst_n === 1'b1);
    repeat (2) @(posedge clk);
    $display("[INFO] jtag_mem_loader unit test start");

    jtag_tap_reset();
    jtag_shift_ir(IR_IDCODE);
    jtag_shift_dr(32, '0, dr_rsp);
    expect_u32(dr_rsp[31:0], IDCODE_VALUE, "IDCODE");

    cpuctl_write(1'b1);
    cpuctl_scan(1'b1, hold);
    expect_bit(hold, 1'b1, "CPUCTL.readback_hold");
    expect_bit(cpu_reset_hold, 1'b1, "CPUCTL.cpu_reset_hold_high");
    cpuctl_write(1'b0);
    cpuctl_scan(1'b0, hold);
    expect_bit(hold, 1'b0, "CPUCTL.readback_release");
    expect_bit(cpu_reset_hold, 1'b0, "CPUCTL.cpu_reset_hold_low");

    memacc_do(1'b1, ADDR_INSTR_BASE + 32'h0, 4'hF, 32'h1234_5678, rdata, err);
    expect_bit(err, 1'b0, "IMEM.write_err");
    memacc_do(1'b0, ADDR_INSTR_BASE + 32'h0, 4'h0, 32'h0, rdata, err);
    expect_bit(err, 1'b0, "IMEM.read_err");
    expect_u32(rdata, 32'h1234_5678, "IMEM.readback");

    memacc_do(1'b1, ADDR_DATA_BASE + 32'h0, 4'b0001, 32'h0000_00AA, rdata, err);
    expect_bit(err, 1'b0, "DMEM.byte_write_err");
    memacc_do(1'b0, ADDR_DATA_BASE + 32'h0, 4'h0, 32'h0, rdata, err);
    expect_u32(rdata, 32'h0000_00AA, "DMEM.byte_readback");

    memacc_do(1'b1, ADDR_DATA_BASE + 32'h0, 4'b0011, 32'h0000_CCDD, rdata, err);
    expect_bit(err, 1'b0, "DMEM.half_write_err");
    memacc_do(1'b0, ADDR_DATA_BASE + 32'h0, 4'h0, 32'h0, rdata, err);
    expect_u32(rdata, 32'h0000_CCDD, "DMEM.half_readback");

    memacc_do(1'b1, ADDR_DATA_BASE + 32'h0, 4'b1100, 32'hA5A5_0000, rdata, err);
    expect_bit(err, 1'b0, "DMEM.upper_half_write_err");
    memacc_do(1'b0, ADDR_DATA_BASE + 32'h0, 4'h0, 32'h0, rdata, err);
    expect_u32(rdata, 32'hA5A5_CCDD, "DMEM.merge_readback");

    memacc_do(1'b1, ADDR_WEIGHT_BASE + 32'h4, 4'hF, 32'hDEAD_BEEF, rdata, err);
    expect_bit(err, 1'b0, "WEIGHT.write_err");
    memacc_do(1'b0, ADDR_WEIGHT_BASE + 32'h4, 4'h0, 32'h0, rdata, err);
    expect_u32(rdata, 32'hDEAD_BEEF, "WEIGHT.readback");

    memacc_do(1'b0, ADDR_REG_BASE, 4'h0, 32'h0, rdata, err);
    expect_bit(err, 1'b1, "MMIO.err");
    expect_u32(rdata, 32'h0, "MMIO.rdata_zero");

    mem_req_grant = 1'b0;
    memacc_issue(1'b0, ADDR_DATA_BASE + 32'h4, 4'h0, 32'h0);
    repeat (4) @(posedge clk);
    expect_bit(mem_req_pending, 1'b1, "Pending_while_ungranted");
    memacc_issue(1'b0, ADDR_DATA_BASE + 32'h8, 4'h0, 32'h0);
    jtag_run_idle(8);
    memacc_scan(1'b0, ADDR_REG_BASE, 4'h0, 32'h0, dr_rsp);
    rdata = dr_rsp[31:0];
    err   = dr_rsp[32];
    done  = dr_rsp[33];
    expect_bit(done, 1'b1, "Outstanding.done");
    expect_bit(err, 1'b1, "Outstanding.err");

    mem_req_grant = 1'b1;
    jtag_run_idle(32);
    memacc_scan(1'b0, ADDR_REG_BASE, 4'h0, 32'h0, dr_rsp);
    rdata = dr_rsp[31:0];
    err   = dr_rsp[32];
    done  = dr_rsp[33];
    expect_bit(done, 1'b1, "Pending_first_req_done");
    expect_bit(err, 1'b0, "Pending_first_req_err");
    expect_u32(rdata, 32'h0, "Pending_first_req_rdata");
    jtag_run_idle(32);

    $display("[RESULT] PASS=%0d", pass_count);
    $display("JTAG_MEM_LOADER_PASS");
    #50;
    $finish;
  end
endmodule
