`timescale 1ns/1ps
//======================================================================
// tb/stream_buffer_v2_tb.sv
//
// 单元 TB：stream_buffer_v2 round-trip 读写 + clear_all
// 结构和 input_stream_sram_tb 类似，但 WIDTH = V2B_MAX_OUT_NEURONS.
//======================================================================
module stream_buffer_v2_tb;

  import snn_soc_pkg::*;

  localparam int DEPTH = V2B_MAX_TIMESTEPS;        // 256
  localparam int WIDTH = V2B_MAX_OUT_NEURONS;      // 128
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

  always #5 clk = ~clk;

  stream_buffer_v2 #(.P_DEPTH(DEPTH), .P_WIDTH(WIDTH)) dut (
    .clk(clk), .rst_n(rst_n),
    .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
    .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data),
    .clear_all(clear_all)
  );

  int errors = 0;

  task automatic do_write(input [ADDR_W-1:0] a, input [WIDTH-1:0] d);
    @(posedge clk);
    wr_en <= 1; wr_addr <= a; wr_data <= d;
    @(posedge clk);
    wr_en <= 0;
  endtask

  task automatic do_read(input [ADDR_W-1:0] a, output [WIDTH-1:0] d);
    @(posedge clk);
    rd_en <= 1; rd_addr <= a;
    @(posedge clk);
    rd_en <= 0;
    @(posedge clk);
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

  logic [WIDTH-1:0] p0 = {WIDTH{1'b0}};
  logic [WIDTH-1:0] p1 = {WIDTH{1'b1}};
  logic [WIDTH-1:0] pa;
  logic [WIDTH-1:0] pb;
  logic [WIDTH-1:0] got;

  initial begin
    for (int i = 0; i < WIDTH; i++) pa[i] = i[1] ^ i[0]; // mixed pattern
    for (int i = 0; i < WIDTH; i++) pb[i] = i[2];        // longer stride

    $display("[TB] stream_buffer_v2_tb start DEPTH=%0d WIDTH=%0d", DEPTH, WIDTH);

    rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);

    do_read(0, got);          check_eq(got, p0, "reset row0 = 0");
    do_read(7, got);           check_eq(got, p0, "reset row7 = 0");

    do_write(0, pa);
    do_write(7, pb);
    do_write(DEPTH-1, p1);

    do_read(0, got);          check_eq(got, pa, "row0 pa round-trip");
    do_read(7, got);          check_eq(got, pb, "row7 pb round-trip");
    do_read(DEPTH-1, got);    check_eq(got, p1, "row[T-1] all-ones");

    clear_all <= 1; @(posedge clk); clear_all <= 0; @(posedge clk);
    do_read(0, got);          check_eq(got, p0, "after clear row0 = 0");
    do_read(7, got);          check_eq(got, p0, "after clear row7 = 0");
    do_read(DEPTH-1, got);    check_eq(got, p0, "after clear row[T-1] = 0");

    if (errors == 0) $display("STREAM_BUFFER_V2_TB_PASS");
    else             $display("STREAM_BUFFER_V2_TB_FAIL (errors=%0d)", errors);
    $finish;
  end

  initial begin #50000; $display("STREAM_BUFFER_V2_TB_TIMEOUT"); $finish; end

endmodule
