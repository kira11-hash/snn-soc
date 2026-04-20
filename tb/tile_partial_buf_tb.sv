`timescale 1ns/1ps
//======================================================================
// tb/tile_partial_buf_tb.sv
//
// 单元 TB：tile_partial_buf 累加 / 清零 / 随机 (t,j) 读写正确性。
// 目标：Icarus 无 SVA 快速 smoke。
//======================================================================
module tile_partial_buf_tb;

  import snn_soc_pkg::*;

  localparam int DEPTH = V2B_MAX_TIMESTEPS;    // 256
  localparam int WIDTH = V2B_MAX_OUT_NEURONS;  // 128
  localparam int CELL  = V2B_PARTIAL_WIDTH;    // 14
  localparam int T_AW = $clog2(DEPTH);
  localparam int J_AW = $clog2(WIDTH);

  logic clk = 0;
  logic rst_n = 0;
  logic clear_all = 0;
  logic acc_en = 0;
  logic [T_AW-1:0] wr_t = '0;
  logic [J_AW-1:0] wr_j = '0;
  logic signed [CELL-1:0] wr_diff = '0;
  logic rd_en = 0;
  logic [T_AW-1:0] rd_t = '0;
  logic [J_AW-1:0] rd_j = '0;
  logic signed [CELL-1:0] rd_data;

  always #5 clk = ~clk;

  tile_partial_buf #(.P_DEPTH(DEPTH), .P_WIDTH(WIDTH), .P_CELL(CELL)) dut (
    .clk(clk), .rst_n(rst_n), .clear_all(clear_all),
    .acc_en(acc_en), .wr_t(wr_t), .wr_j(wr_j), .wr_diff(wr_diff),
    .rd_en(rd_en), .rd_t(rd_t), .rd_j(rd_j), .rd_data(rd_data)
  );

  int errors = 0;

  task automatic do_acc(input [T_AW-1:0] t, input [J_AW-1:0] j,
                        input signed [CELL-1:0] d);
    @(posedge clk);
    acc_en <= 1; wr_t <= t; wr_j <= j; wr_diff <= d;
    @(posedge clk);
    acc_en <= 0;
  endtask

  task automatic do_read(input [T_AW-1:0] t, input [J_AW-1:0] j,
                         output signed [CELL-1:0] d);
    @(posedge clk);
    rd_en <= 1; rd_t <= t; rd_j <= j;
    @(posedge clk);
    rd_en <= 0;
    @(posedge clk);
    d = rd_data;
  endtask

  task automatic check_signed(input signed [CELL-1:0] got,
                              input signed [CELL-1:0] exp,
                              input string label);
    if (got !== exp) begin
      $display("[FAIL] %s: got=%0d exp=%0d", label, got, exp);
      errors++;
    end else begin
      $display("[PASS] %s (= %0d)", label, got);
    end
  endtask

  logic signed [CELL-1:0] got;

  initial begin
    $display("[TB] tile_partial_buf_tb start DEPTH=%0d WIDTH=%0d CELL=%0d",
             DEPTH, WIDTH, CELL);

    rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);

    // Reset initial
    do_read(0, 0, got);               check_signed(got, 0, "reset (0,0)");
    do_read(DEPTH-1, WIDTH-1, got);   check_signed(got, 0, "reset (T-1,N-1)");

    // Single accumulate
    do_acc(5, 3, 100);
    do_read(5, 3, got);               check_signed(got, 100, "acc(5,3,+100)");

    // Multi-tile style: same (t, j), three tiles accumulate
    do_acc(7, 2, 50);
    do_acc(7, 2, -30);
    do_acc(7, 2, 120);
    do_read(7, 2, got);               check_signed(got, 140, "tile-acc sum = 50-30+120");

    // Negative saturation within 14-bit (max |val| ≈ 2^13 = 8192)
    do_acc(10, 0, -8000);
    do_read(10, 0, got);              check_signed(got, -8000, "acc -8000 (signed)");

    // Different (t, j) cells independent
    do_acc(0, 0, 1);
    do_acc(0, 1, 2);
    do_acc(1, 0, 3);
    do_read(0, 0, got);               check_signed(got, 1, "cell (0,0) = 1");
    do_read(0, 1, got);               check_signed(got, 2, "cell (0,1) = 2");
    do_read(1, 0, got);               check_signed(got, 3, "cell (1,0) = 3");

    // clear_all wipes everything
    @(posedge clk); clear_all <= 1; @(posedge clk); clear_all <= 0; @(posedge clk);
    do_read(5, 3, got);               check_signed(got, 0, "after clear (5,3)");
    do_read(7, 2, got);               check_signed(got, 0, "after clear (7,2)");
    do_read(0, 0, got);               check_signed(got, 0, "after clear (0,0)");

    // After clear, fresh accumulate works
    do_acc(100, 50, 7);
    do_read(100, 50, got);            check_signed(got, 7, "post-clear acc(100,50,7)");

    if (errors == 0) $display("TILE_PARTIAL_BUF_TB_PASS");
    else             $display("TILE_PARTIAL_BUF_TB_FAIL (errors=%0d)", errors);
    $finish;
  end

  initial begin #200000; $display("TILE_PARTIAL_BUF_TB_TIMEOUT"); $finish; end

endmodule
