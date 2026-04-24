`timescale 1ns/1ps
//======================================================================
// 文件名: tb/v2_e203_encoder_parity_tb.sv
//
// Phase A-7 encoder-parity TB (skeleton-level)：验证 CPU ↔ TB RPC 握手
// 协议能跑通（TB 写 ENCODER_SAMPLE_REQ → FW 读 → FW 写 DONE → TB 轮询）。
//
// 完整 bit-exact 对齐 Python sample_XX_wl_stream.hex 是 Phase A-8 任务
// （FW 里需要实现 v2b_encode_pixel_even_rate）。本 gate 只验证协议本身
// + marker flow + sample-by-sample handshake，不校验 stream 数据。
//
// 【测试流程】
//   1. 加载 v2_e203_encoder.hex 到 INSTR_SRAM
//   2. rst 释放，等 BOOT_MARK (0xB0070001)
//   3. 对 k = 0..4：
//        TB hierarchical 写 dut.u_data_sram.mem[ENCODER_SAMPLE_REQ >> 2] = k
//        等 dut.u_data_sram.mem[ENCODER_SAMPLE_DONE >> 2] == k
//   4. TB 写 REQ = 0xFF（终结）
//   5. 等 ENCODER_DONE_MARK (0x31C0D001)
//
// PASS tag: V2_E203_ENCODER_PARITY_PASS
//======================================================================
module v2_e203_encoder_parity_tb;

  logic clk;
  logic rst_n;
  logic uart_rx;
  logic uart_tx;

  snn_soc_v2b_e203_top #(.INSTR_INIT_FILE("")) dut (
    .clk(clk), .rst_n(rst_n),
    .uart_rx(uart_rx),
    .uart_tx(uart_tx)
  );

  initial clk = 0;
  always #5 clk = ~clk;

  initial begin
    $readmemh("../fw/v2_e203_smoke/out/v2_e203_encoder.hex", dut.u_instr_sram.mem);
  end

  // DMEM word-offset helpers (addr - 0x00010000) >> 2
  localparam int WADDR_BOOT_MARK      = (32'h00011F00 - 32'h00010000) >> 2;
  localparam int WADDR_ENCODER_DONE   = (32'h00011F08 - 32'h00010000) >> 2;
  localparam int WADDR_BUF_PTR_0      = (32'h00011F0C - 32'h00010000) >> 2;
  localparam int WADDR_BUF_PTR_1      = (32'h00011F10 - 32'h00010000) >> 2;
  localparam int WADDR_BUF_PTR_2      = (32'h00011F14 - 32'h00010000) >> 2;
  localparam int WADDR_SAMPLE_REQ     = (32'h00011E00 - 32'h00010000) >> 2;
  localparam int WADDR_SAMPLE_DONE    = (32'h00011E04 - 32'h00010000) >> 2;

  localparam logic [31:0] V2E203_BOOT_MARK         = 32'hB0070001;
  localparam logic [31:0] V2E203_ENCODER_DONE_MARK = 32'h31C0D001;
  localparam logic [31:0] REQ_IDLE                 = 32'hFFFFFFFF;
  localparam logic [31:0] REQ_ALL_DONE             = 32'h000000FF;
  localparam logic [31:0] EXP_BUF_PTR_0            = 32'h00010800;  /* ENCODER_STREAM_BASE */
  localparam logic [31:0] EXP_BUF_PTR_1            = 32'h00011E00;  /* SAMPLE_REQ addr */
  localparam logic [31:0] EXP_BUF_PTR_2            = 32'h00011E04;  /* SAMPLE_DONE addr */

  int errors;

  initial begin
    $dumpfile("waves/v2_e203_encoder_parity.vcd");
    $dumpvars(0, v2_e203_encoder_parity_tb);
  end

  task automatic wait_dmem(input int word_offset, input logic [31:0] exp_val,
                          input int max_cycles, input string tag);
    int p;
    bit done;
    begin
      p = 0;
      done = 1'b0;
      while (!done) begin
        @(posedge clk);
        p++;
        if (dut.u_data_sram.mem[word_offset] == exp_val) begin
          $display("[INFO] %s observed after %0d cycles", tag, p);
          done = 1'b1;
        end else if (p > max_cycles) begin
          $display("[ERR] %s not observed in %0d cycles, got 0x%08h",
                   tag, max_cycles, dut.u_data_sram.mem[word_offset]);
          errors++;
          done = 1'b1;
        end
      end
    end
  endtask

  initial begin
    errors  = 0;
    rst_n   = 0;
    uart_rx = 1;
    repeat (8) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    $display("[INFO] encoder-parity TB start");

    /* 1. 等 BOOT_MARK */
    wait_dmem(WADDR_BOOT_MARK, V2E203_BOOT_MARK, 2000, "BOOT_MARK");

    /* 2. 校验 BUFFER_PTR */
    if (dut.u_data_sram.mem[WADDR_BUF_PTR_0] !== EXP_BUF_PTR_0) begin
      $display("[ERR] BUFFER_PTR_0 = 0x%08h (exp 0x%08h)",
               dut.u_data_sram.mem[WADDR_BUF_PTR_0], EXP_BUF_PTR_0);
      errors++;
    end
    if (dut.u_data_sram.mem[WADDR_BUF_PTR_1] !== EXP_BUF_PTR_1) begin
      $display("[ERR] BUFFER_PTR_1 = 0x%08h (exp 0x%08h)",
               dut.u_data_sram.mem[WADDR_BUF_PTR_1], EXP_BUF_PTR_1);
      errors++;
    end
    if (dut.u_data_sram.mem[WADDR_BUF_PTR_2] !== EXP_BUF_PTR_2) begin
      $display("[ERR] BUFFER_PTR_2 = 0x%08h (exp 0x%08h)",
               dut.u_data_sram.mem[WADDR_BUF_PTR_2], EXP_BUF_PTR_2);
      errors++;
    end

    /* 3. 等 FW 把 SAMPLE_REQ_ADDR 初始化成 IDLE (0xFFFFFFFF) 再开始握手 */
    wait_dmem(WADDR_SAMPLE_REQ, REQ_IDLE, 2000, "SAMPLE_REQ init to IDLE");

    /* 4. 5 轮 RPC (k = 0..4) */
    for (int k = 0; k < 5; k++) begin
      /* TB writes REQ = k directly via hierarchical reference */
      dut.u_data_sram.mem[WADDR_SAMPLE_REQ] = k;
      /* Wait FW to set DONE = k */
      wait_dmem(WADDR_SAMPLE_DONE, k, 5000,
                $sformatf("SAMPLE_DONE == %0d", k));
      /* Wait FW to clear REQ back to IDLE (it does so after echoing DONE) */
      wait_dmem(WADDR_SAMPLE_REQ, REQ_IDLE, 1000,
                $sformatf("SAMPLE_REQ cleared after k=%0d", k));
    end

    /* 5. Send terminator and wait ENCODER_DONE_MARK */
    dut.u_data_sram.mem[WADDR_SAMPLE_REQ] = REQ_ALL_DONE;
    wait_dmem(WADDR_ENCODER_DONE, V2E203_ENCODER_DONE_MARK, 5000, "ENCODER_DONE_MARK");

    repeat (20) @(posedge clk);
    if (errors == 0) begin
      $display("V2_E203_ENCODER_PARITY_PASS");
    end else begin
      $display("V2_E203_ENCODER_PARITY_FAIL errors=%0d", errors);
      $fatal(1);
    end
    $finish;
  end

  initial begin
    #5000000;
    $display("[ERR] global timeout"); $fatal(1);
  end

endmodule
