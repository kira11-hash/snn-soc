`timescale 1ns/1ps
//======================================================================
// tb/input_stream_sram_tb.sv
//
// 单元 TB：input_stream_sram round-trip 读写 + clear_all + 边界地址
// 目标：Icarus 快速 smoke（无 SVA 依赖）。
//======================================================================
module input_stream_sram_tb;

  import snn_soc_pkg::*;

  localparam int DEPTH = V2B_MAX_TIMESTEPS;
  localparam int WIDTH = V2B_NUM_INPUTS;
  localparam int ADDR_W = $clog2(DEPTH);

  logic clk = 0;
  logic rst_n = 0;
  logic wr_en = 0;
  logic [ADDR_W-1:0] wr_addr = '0;
  logic [WIDTH-1:0] wr_data = '0;
  logic rd_en = 0;
  logic [ADDR_W-1:0] rd_addr = '0;
  logic [WIDTH-1:0] rd_data;
  logic clear_all = 0;

  always #5 clk = ~clk;  // 100 MHz

  input_stream_sram #(.P_DEPTH(DEPTH), .P_WIDTH(WIDTH)) dut (
    .clk(clk), .rst_n(rst_n),
    .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
    .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data),
    .clear_all(clear_all)
  );

  int errors = 0;

  task automatic do_write(input [ADDR_W-1:0] a, input [WIDTH-1:0] d);
    @(posedge clk);
    wr_en   <= 1;
    wr_addr <= a;
    wr_data <= d;
    @(posedge clk);
    wr_en <= 0;
  endtask

  task automatic do_read(input [ADDR_W-1:0] a, output [WIDTH-1:0] d);
    @(posedge clk);
    rd_en   <= 1;
    rd_addr <= a;
    @(posedge clk);
    rd_en <= 0;
    @(posedge clk);  // rd_data valid one cycle after rd_en
    d = rd_data;
  endtask

  task automatic check_eq(input [WIDTH-1:0] got, input [WIDTH-1:0] exp,
                          input string label);
    if (got !== exp) begin
      $display("[FAIL] %s: got=%h exp=%h", label, got, exp);
      errors++;
    end else begin
      $display("[PASS] %s", label);
    end
  endtask

  logic [WIDTH-1:0] pattern_0 = {WIDTH{1'b0}};
  logic [WIDTH-1:0] pattern_1 = {WIDTH{1'b1}};
  logic [WIDTH-1:0] pattern_a;
  logic [WIDTH-1:0] pattern_b;
  logic [WIDTH-1:0] got;

  initial begin
    // deterministic patterns
    for (int i = 0; i < WIDTH; i++) pattern_a[i] = i[0];         // 0x55..
    for (int i = 0; i < WIDTH; i++) pattern_b[i] = ~i[0];        // 0xAA..

    $display("[TB] input_stream_sram_tb start DEPTH=%0d WIDTH=%0d", DEPTH, WIDTH);

    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // After reset: every row must be zero
    do_read(0, got);   check_eq(got, pattern_0, "reset row0 = 0");
    do_read(DEPTH-1, got); check_eq(got, pattern_0, "reset row[T-1] = 0");

    // Write + read back patterns
    do_write(0, pattern_a);
    do_write(1, pattern_b);
    do_write(DEPTH-1, pattern_1);

    do_read(0, got);        check_eq(got, pattern_a, "row0 pattern_a round-trip");
    do_read(1, got);        check_eq(got, pattern_b, "row1 pattern_b round-trip");
    do_read(DEPTH-1, got);  check_eq(got, pattern_1, "row[T-1] all-ones");

    // clear_all must wipe everything back to 0
    @(posedge clk);
    clear_all <= 1;
    @(posedge clk);
    clear_all <= 0;
    @(posedge clk);
    do_read(0, got);        check_eq(got, pattern_0, "after clear_all row0 = 0");
    do_read(1, got);        check_eq(got, pattern_0, "after clear_all row1 = 0");
    do_read(DEPTH-1, got);  check_eq(got, pattern_0, "after clear_all row[T-1] = 0");

    if (errors == 0) $display("INPUT_STREAM_SRAM_TB_PASS");
    else             $display("INPUT_STREAM_SRAM_TB_FAIL (errors=%0d)", errors);
    $finish;
  end

  initial begin
    #50000;
    $display("INPUT_STREAM_SRAM_TB_TIMEOUT");
    $finish;
  end

endmodule
