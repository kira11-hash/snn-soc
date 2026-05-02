`timescale 1ns/1ps
//======================================================================
// tb/fmap_sram_v2_unit_tb.sv
//
// fmap_sram_v2 unit smoke TB — 覆盖 ping-pong 双 bank 的 read/write
// 基本契约。LeNet-5 cosim 已经端到端验证过完整路径；本 TB 的目的是
// 在端口/FSM 改动后能快速发现回归（不依赖跑全网络 cosim）。
//
// 覆盖的 invariant：
//   T1  写 bank A，读 bank A 拿到原值（bank_sel_pp=0）
//   T2  写 bank B，读 bank B 拿到原值（bank_sel_pp=1）
//   T3  bank_sel_pp 切换，读到的是正确的 bank
//   T4  byte-strobe 写入：wr_strb=4'b0001 仅改 byte0
//   T5  OOB 写：wr_word_addr >= P_BANK_WORDS 触发 addr_oob，且不污染 bank
//   T6  OOB 读：返回 32'h0
//
// 用 P_BANK_KIB=4（小 bank：1024 words）压缩仿真时间。
//======================================================================
module fmap_sram_v2_unit_tb;

  import snn_soc_pkg::*;

  localparam int P_BANK_KIB   = 4;
  localparam int P_BANK_WORDS = (P_BANK_KIB * 1024) / 4;  // 1024
  localparam int P_ADDR_W     = $clog2(P_BANK_WORDS);     // 10

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        bank_sel_pp = 1'b0;
  logic        rd_en = 1'b0;
  logic [31:0] rd_word_addr = '0;
  logic [31:0] rd_data;
  logic        wr_en = 1'b0;
  logic        wr_bank_sel = 1'b0;
  logic [31:0] wr_word_addr = '0;
  logic [31:0] wr_data = '0;
  logic [3:0]  wr_strb = 4'h0;
  logic        addr_oob;

  fmap_sram_v2 #(
    .P_BANK_KIB  (P_BANK_KIB),
    .P_BANK_WORDS(P_BANK_WORDS),
    .P_ADDR_W    (P_ADDR_W)
  ) dut (
    .clk         (clk),
    .rst_n       (rst_n),
    .bank_sel_pp (bank_sel_pp),
    .rd_en       (rd_en),
    .rd_word_addr(rd_word_addr),
    .rd_data     (rd_data),
    .wr_en       (wr_en),
    .wr_bank_sel (wr_bank_sel),
    .wr_word_addr(wr_word_addr),
    .wr_data     (wr_data),
    .wr_strb     (wr_strb),
    .addr_oob    (addr_oob)
  );

  integer pass_count = 0;
  integer fail_count = 0;
  integer addr_oob_count = 0;

  always @(posedge clk) begin
    if (rst_n && addr_oob) addr_oob_count <= addr_oob_count + 1;
  end

  task automatic do_write(input logic [31:0] addr,
                          input logic [31:0] data,
                          input logic [3:0]  strb,
                          input logic        bank);
    @(posedge clk);
    wr_en        <= 1'b1;
    wr_bank_sel  <= bank;
    wr_word_addr <= addr;
    wr_data      <= data;
    wr_strb      <= strb;
    @(posedge clk);
    wr_en   <= 1'b0;
    wr_strb <= 4'h0;
  endtask

  task automatic do_read(input logic [31:0] addr,
                         input logic        bank_pp,
                         output logic [31:0] data);
    @(posedge clk);
    rd_en        <= 1'b1;
    rd_word_addr <= addr;
    bank_sel_pp  <= bank_pp;
    @(posedge clk);
    rd_en <= 1'b0;
    @(posedge clk);  // 1-cycle latency before rd_data is valid
    data = rd_data;
  endtask

  task automatic check32(input string tag,
                         input logic [31:0] got,
                         input logic [31:0] exp);
    if (got === exp) begin
      $display("[PASS] %s got=0x%08h", tag, got);
      pass_count = pass_count + 1;
    end else begin
      $display("[FAIL] %s got=0x%08h exp=0x%08h", tag, got, exp);
      fail_count = fail_count + 1;
    end
  endtask

  task automatic check_int(input string tag,
                           input integer got,
                           input integer exp);
    if (got === exp) begin
      $display("[PASS] %s got=%0d exp=%0d", tag, got, exp);
      pass_count = pass_count + 1;
    end else begin
      $display("[FAIL] %s got=%0d exp=%0d", tag, got, exp);
      fail_count = fail_count + 1;
    end
  endtask

  initial begin
    logic [31:0] rd;
    $display("[INFO] fmap_sram_v2_unit_tb start (P_BANK_WORDS=%0d)", P_BANK_WORDS);
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // ── T1: bank A round-trip ──
    do_write(32'd16, 32'hAABB_CCDD, 4'b1111, 1'b0);
    do_read (32'd16, 1'b0, rd);
    check32("T1 bankA addr16 round-trip", rd, 32'hAABB_CCDD);

    // ── T2: bank B round-trip ──
    do_write(32'd32, 32'h1122_3344, 4'b1111, 1'b1);
    do_read (32'd32, 1'b1, rd);
    check32("T2 bankB addr32 round-trip", rd, 32'h1122_3344);

    // ── T3: bank_sel_pp toggle reads correct bank ──
    do_write(32'd64, 32'hDEAD_BEEF, 4'b1111, 1'b0);
    do_write(32'd64, 32'hCAFE_BABE, 4'b1111, 1'b1);
    do_read (32'd64, 1'b0, rd);
    check32("T3a bank_sel_pp=0 reads bankA at addr64", rd, 32'hDEAD_BEEF);
    do_read (32'd64, 1'b1, rd);
    check32("T3b bank_sel_pp=1 reads bankB at addr64", rd, 32'hCAFE_BABE);

    // ── T4: byte-strobe write ──
    do_write(32'd128, 32'hAABB_CCDD, 4'b1111, 1'b0);  // seed full word
    do_write(32'd128, 32'h0000_0011, 4'b0001, 1'b0);  // only byte0
    do_read (32'd128, 1'b0, rd);
    check32("T4 byte-strobe wr_strb=0001 changes only byte0",
            rd, 32'hAABB_CC11);

    // ── T5: OOB write triggers addr_oob and does NOT pollute bank ──
    // 先 seed addr 200 一个 sentinel，再尝试 OOB write，再读 200 应保留 sentinel
    do_write(32'd200, 32'hAA55_AA55, 4'b1111, 1'b0);
    addr_oob_count = 0;
    do_write(32'(P_BANK_WORDS + 5), 32'hBADC_0DE0, 4'b1111, 1'b0);
    repeat (2) @(posedge clk);
    check_int("T5 OOB write asserts addr_oob", addr_oob_count, 1);
    do_read (32'd200, 1'b0, rd);
    check32("T5 OOB write does not pollute previously-written addr",
            rd, 32'hAA55_AA55);

    // ── T6: OOB read returns 0 ──
    do_read (32'(P_BANK_WORDS + 1), 1'b0, rd);
    check32("T6 OOB read returns 32'h0", rd, 32'h0);

    repeat (5) @(posedge clk);
    $display("");
    $display("=== Results: %0d PASS, %0d FAIL ===", pass_count, fail_count);
    if (fail_count == 0)
      $display("FMAP_SRAM_V2_UNIT_TB_PASS");
    else
      $display("FMAP_SRAM_V2_UNIT_TB_FAIL");
    $finish;
  end

  initial begin
    #200000;
    $display("[ERROR] timeout");
    $display("FMAP_SRAM_V2_UNIT_TB_FAIL (timeout)");
    $finish;
  end

endmodule
