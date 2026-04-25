`timescale 1ns/1ps

module jtag_instr_hi_window_tb;
  import snn_soc_pkg::*;

  localparam logic [3:0] IR_MEMACC = 4'h2;

  logic rst_n, clk;
  logic jtag_tck, jtag_tms, jtag_tdi, jtag_tdo;
  logic mem_req_pending, mem_req_grant;
  logic mem_m_valid, mem_m_write;
  logic [31:0] mem_m_addr, mem_m_wdata;
  logic [3:0]  mem_m_wstrb;
  logic mem_m_ready, mem_m_rvalid;
  logic [31:0] mem_m_rdata;
  logic cpu_reset_hold;

  logic [31:0] stored_word;

  // ENABLE_BOOT_ROM=1：测试 boot-rom-shifted INSTR layout，桥应放行 0x1000..0x4FFF
  jtag_mem_loader #(.ENABLE_BOOT_ROM(1'b1)) dut (
    .rst_n, .clk,
    .jtag_tck, .jtag_tms, .jtag_tdi, .jtag_tdo,
    .mem_req_pending, .mem_req_grant,
    .mem_m_valid, .mem_m_write, .mem_m_addr, .mem_m_wstrb, .mem_m_wdata,
    .mem_m_ready, .mem_m_rvalid, .mem_m_rdata,
    .cpu_reset_hold
  );

  initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_req_grant <= 1'b0;
      mem_m_ready   <= 1'b0;
      mem_m_rvalid  <= 1'b0;
      mem_m_rdata   <= 32'h0;
      stored_word   <= 32'h0;
    end else begin
      mem_req_grant <= mem_req_pending;
      mem_m_ready   <= 1'b0;
      mem_m_rvalid  <= 1'b0;
      if (mem_m_valid) begin
        if (mem_m_write) begin
          stored_word <= mem_m_wdata;
          mem_m_ready <= 1'b1;
        end else begin
          mem_m_rdata  <= stored_word;
          mem_m_rvalid <= 1'b1;
        end
      end
    end
  end

  task automatic jtag_step(input logic tms_i, input logic tdi_i, output logic tdo_o);
    begin
      jtag_tms = tms_i;
      jtag_tdi = tdi_i;
      #2; jtag_tck = 1'b1;
      #2; tdo_o = jtag_tdo;
      jtag_tck = 1'b0;
      #2;
    end
  endtask

  task automatic jtag_tap_reset;
    integer i;
    logic dummy;
    begin
      for (i = 0; i < 6; i++) jtag_step(1'b1, 1'b0, dummy);
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
      for (i = 0; i < 4; i++) begin
        jtag_step((i == 3), ir[i], dummy);
      end
      jtag_step(1'b1, 1'b0, dummy);
      jtag_step(1'b0, 1'b0, dummy);
    end
  endtask

  task automatic jtag_shift_dr(
    input integer nbits,
    input logic [68:0] tx,
    output logic [68:0] rx
  );
    integer i;
    logic tdo_bit;
    begin
      rx = '0;
      jtag_step(1'b1, 1'b0, tdo_bit);
      jtag_step(1'b0, 1'b0, tdo_bit);
      jtag_step(1'b0, 1'b0, tdo_bit);
      for (i = 0; i < nbits; i++) begin
        jtag_step((i == nbits-1), tx[i], tdo_bit);
        rx[i] = tdo_bit;
      end
      jtag_step(1'b1, 1'b0, tdo_bit);
      jtag_step(1'b0, 1'b0, tdo_bit);
    end
  endtask

  function automatic logic [68:0] pack_memacc(
    input logic write,
    input logic [31:0] addr,
    input logic [3:0] wstrb,
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

  task automatic memacc_do(
    input logic write,
    input logic [31:0] addr,
    input logic [3:0] wstrb,
    input logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic err
  );
    logic [68:0] rsp;
    integer i;
    begin
      jtag_shift_ir(IR_MEMACC);
      jtag_shift_dr(69, pack_memacc(write, addr, wstrb, wdata), rsp);
      for (i = 0; i < 128; i++) begin
        jtag_step(1'b0, 1'b0, rsp[0]);
      end
      jtag_shift_ir(IR_MEMACC);
      jtag_shift_dr(69, pack_memacc(1'b0, ADDR_REG_BASE, 4'h0, 32'h0), rsp);
      rdata = rsp[31:0];
      err   = rsp[32];
      if (!rsp[33]) begin
        $display("[FAIL] MEMACC timeout");
        $fatal(1);
      end
    end
  endtask

  initial begin
    logic [31:0] rdata;
    logic err;
    rst_n = 1'b0;
    jtag_tck = 1'b0;
    jtag_tms = 1'b0;
    jtag_tdi = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    jtag_tap_reset();

    memacc_do(1'b1, 32'h0000_4FFC, 4'hF, 32'hCAFE_BEEF, rdata, err);
    if (err) begin
      $display("[FAIL] high-window JTAG write rejected");
      $fatal(1);
    end
    memacc_do(1'b0, 32'h0000_4FFC, 4'h0, 32'h0, rdata, err);
    if (err || rdata !== 32'hCAFE_BEEF) begin
      $display("[FAIL] high-window JTAG readback mismatch got=0x%08h err=%0b", rdata, err);
      $fatal(1);
    end

    memacc_do(1'b0, 32'h0000_5000, 4'h0, 32'h0, rdata, err);
    if (!err) begin
      $display("[FAIL] out-of-window JTAG access should fail");
      $fatal(1);
    end

    $display("JTAG_INSTR_HI_WINDOW_TB_PASS");
    $finish;
  end
endmodule
