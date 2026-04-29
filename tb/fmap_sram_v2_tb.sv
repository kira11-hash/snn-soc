`timescale 1ns/1ps
//======================================================================
// fmap_sram_v2_tb.sv
//
// Unit TB for the V2.B CONV ping-pong fmap SRAM.
//======================================================================
module fmap_sram_v2_tb;

  import snn_soc_pkg::*;

  localparam int BANK_WORDS = (V2B_CONV_FMAP_BANK_KIB * 1024) / 4;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic bank_sel_pp = 0;
  logic rd_en = 0;
  logic [31:0] rd_word_addr = 0;
  logic [31:0] rd_data;
  logic wr_en = 0;
  logic wr_bank_sel = 0;
  logic [31:0] wr_word_addr = 0;
  logic [31:0] wr_data = 0;
  logic [3:0] wr_strb = 0;
  logic addr_oob;

  int errors = 0;

  fmap_sram_v2 dut (
    .clk(clk), .rst_n(rst_n), .bank_sel_pp(bank_sel_pp),
    .rd_en(rd_en), .rd_word_addr(rd_word_addr), .rd_data(rd_data),
    .wr_en(wr_en), .wr_bank_sel(wr_bank_sel), .wr_word_addr(wr_word_addr),
    .wr_data(wr_data), .wr_strb(wr_strb), .addr_oob(addr_oob)
  );

  task automatic write_word(input bit bank, input [31:0] addr,
                            input [31:0] data, input [3:0] strb);
    begin
      @(negedge clk);
      wr_en = 1'b1;
      wr_bank_sel = bank;
      wr_word_addr = addr;
      wr_data = data;
      wr_strb = strb;
      @(posedge clk);
      @(negedge clk);
      wr_en = 1'b0;
      wr_word_addr = '0;
      wr_data = '0;
      wr_strb = '0;
    end
  endtask

  task automatic read_word(input bit bank, input [31:0] addr,
                           output logic [31:0] data);
    begin
      @(negedge clk);
      bank_sel_pp = bank;
      rd_en = 1'b1;
      rd_word_addr = addr;
      @(posedge clk);
      @(negedge clk);
      data = rd_data;
      rd_en = 1'b0;
      rd_word_addr = '0;
    end
  endtask

  task automatic expect_word(input logic [31:0] got,
                             input logic [31:0] exp,
                             input string label);
    begin
      if (got !== exp) begin
        $display("[FAIL] %s got=%08x exp=%08x", label, got, exp);
        errors++;
      end else begin
        $display("[PASS] %s = %08x", label, got);
      end
    end
  endtask

  logic [31:0] got;

  initial begin
    $display("[TB] fmap_sram_v2_tb start bank_words=%0d", BANK_WORDS);
    rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    write_word(1'b0, 32'd0, 32'h1234_5678, 4'hf);
    write_word(1'b0, 32'd7, 32'h89ab_cdef, 4'hf);
    read_word(1'b0, 32'd0, got);
    expect_word(got, 32'h1234_5678, "bank A addr0");
    read_word(1'b0, 32'd7, got);
    expect_word(got, 32'h89ab_cdef, "bank A addr7");

    write_word(1'b1, 32'd0, 32'hcafe_babe, 4'hf);
    read_word(1'b0, 32'd0, got);
    expect_word(got, 32'h1234_5678, "ping-pong A unchanged");
    read_word(1'b1, 32'd0, got);
    expect_word(got, 32'hcafe_babe, "ping-pong B addr0");

    write_word(1'b0, 32'd11, 32'h1122_3344, 4'hf);
    write_word(1'b0, 32'd11, 32'haaaa_aa00, 4'b0010);
    read_word(1'b0, 32'd11, got);
    expect_word(got, 32'h1122_aa44, "byte mask strb[1]");
    write_word(1'b0, 32'd11, 32'hbb00_0000, 4'b1000);
    read_word(1'b0, 32'd11, got);
    expect_word(got, 32'hbb22_aa44, "byte mask strb[3]");

    write_word(1'b1, 32'd3, 32'h5555_aaaa, 4'hf);
    @(negedge clk);
    wr_en = 1'b1;
    wr_bank_sel = 1'b1;
    wr_word_addr = BANK_WORDS[31:0];
    wr_data = 32'hdead_beef;
    wr_strb = 4'hf;
    #1;
    if (!addr_oob) begin
      $display("[FAIL] addr_oob did not assert for addr=%0d", BANK_WORDS);
      errors++;
    end else begin
      $display("[PASS] addr_oob asserted for addr=%0d", BANK_WORDS);
    end
    @(posedge clk);
    @(negedge clk);
    wr_en = 1'b0;
    wr_word_addr = '0;
    wr_data = '0;
    wr_strb = '0;
    read_word(1'b1, 32'd3, got);
    expect_word(got, 32'h5555_aaaa, "OOB write does not corrupt bank B");

    if (errors == 0) $display("FMAP_SRAM_V2_TB_PASS");
    else             $display("FMAP_SRAM_V2_TB_FAIL errors=%0d", errors);
    $finish;
  end

  initial begin
    #5_000_000;
    $display("FMAP_SRAM_V2_TB_TIMEOUT");
    $finish;
  end

endmodule
