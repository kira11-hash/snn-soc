`timescale 1ns/1ps
//======================================================================
// tb/v2_e203_soc_compile_tb.sv
//
// Phase A-5 compile smoke: instantiate snn_soc_v2b_e203_top, drive rst_n
// + clk, 跑几个 cycle（不 load 固件，不发推理），确认 elaborate + rst 释放
// 不炸。完整 cosim 在 A-7 里做。
//
// PASS 标志：V2_E203_SOC_COMPILE_PASS
//======================================================================
module v2_e203_soc_compile_tb;

  logic clk;
  logic rst_n;
  logic uart_rx;
  logic uart_tx;

  snn_soc_v2b_e203_top #(
    .INSTR_INIT_FILE("")
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .uart_rx(uart_rx),
    .uart_tx(uart_tx)
  );

  initial clk = 0;
  always #5 clk = ~clk;

  initial begin
    $dumpfile("waves/v2_e203_soc_compile.vcd");
    $dumpvars(0, v2_e203_soc_compile_tb);
  end

  initial begin
    rst_n   = 0;
    uart_rx = 1;
    repeat (8) @(posedge clk);
    rst_n = 1;
    // 跑 500 拍，让 E203 启动、取指（INSTR_SRAM 全 0 = 非法指令，但 TB 不
    // care，只要 simulation 不 hang/死循环即可）
    repeat (500) @(posedge clk);
    $display("V2_E203_SOC_COMPILE_PASS");
    $finish;
  end

  initial begin
    #200000;
    $display("[ERR] compile-smoke global timeout");
    $fatal(1);
  end

endmodule
