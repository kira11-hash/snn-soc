`timescale 1ns/1ps
//======================================================================
// 文件名: tb/v2_e203_cosim_tb.sv
//
// Phase A-7 cosim：full-top + DMEM marker 协议 + PC check。
// 加载 fw/v2_e203_smoke/out/v2_e203_smoke.hex 到 INSTR_SRAM，让 E203
// 自启动，验证固件按约定顺序写 marker + BUFFER_PTR + UART 输出。
//
// 【当前 A-6 骨架固件行为】
//   Step 1-5: init → clear counts/flags → write BUFFER_PTR_0/1 → BOOT_MARK
//             → print "FPGA_V2_E203_BOOT_UART_PASS\n"
//   TODO(A-8): 10-sample inference loop
//   Step 7-9: INFER_DONE_MARK → print "FPGA_V2_E203_MULTILAYER_INFER_PASS\n" → spin
//
// 【检查项】（TB-side）
//   M1  BOOT_MARK (0xB0070001) 出现在 DMEM[0x11F00/4] within N cycles
//   M2  BUFFER_PTR_0/1 are runtime linker-symbol addresses in DMEM
//   M3  INFER_DONE_MARK (0x1F4ED001) 出现
//   M4  UART TX MMIO writes exact boot/done strings
//   M5  最终 PC 停在 spin loop（非初始值、不是 illegal-instr trap）
//
// Bit-exact 100-count 检查是 Phase A-8 任务（固件补完 v2b_scheduler 调用后），
// 本 gate 不检查 counts 值（skeleton 未推理）。
//
// PASS tag: V2_E203_COSIM_PASS
//======================================================================
module v2_e203_cosim_tb;

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

  // ── INSTR_SRAM hex preload（分层引用，不经 SoC top 的 $readmemh hook）──
  initial begin
    $readmemh("../fw/v2_e203_smoke/out/v2_e203_smoke.hex", dut.u_instr_sram.mem);
  end

  // ── UART TX byte sniffer ───────────────────────────────────────────
  localparam int UART_EXPECT_LEN = 65;
  int uart_byte_count;
  int uart_errors;
  logic uart_busy_seen;
  logic clint_cmd_seen;

  function automatic logic [7:0] expected_uart_byte(input int idx);
    begin
      expected_uart_byte = 8'h00;
      case (idx)
       0: expected_uart_byte = 8'h46;
       1: expected_uart_byte = 8'h50;
       2: expected_uart_byte = 8'h47;
       3: expected_uart_byte = 8'h41;
       4: expected_uart_byte = 8'h5F;
       5: expected_uart_byte = 8'h56;
       6: expected_uart_byte = 8'h32;
       7: expected_uart_byte = 8'h5F;
       8: expected_uart_byte = 8'h45;
       9: expected_uart_byte = 8'h32;
      10: expected_uart_byte = 8'h30;
      11: expected_uart_byte = 8'h33;
      12: expected_uart_byte = 8'h5F;
      13: expected_uart_byte = 8'h42;
      14: expected_uart_byte = 8'h4F;
      15: expected_uart_byte = 8'h4F;
      16: expected_uart_byte = 8'h54;
      17: expected_uart_byte = 8'h5F;
      18: expected_uart_byte = 8'h55;
      19: expected_uart_byte = 8'h41;
      20: expected_uart_byte = 8'h52;
      21: expected_uart_byte = 8'h54;
      22: expected_uart_byte = 8'h5F;
      23: expected_uart_byte = 8'h50;
      24: expected_uart_byte = 8'h41;
      25: expected_uart_byte = 8'h53;
      26: expected_uart_byte = 8'h53;
      27: expected_uart_byte = 8'h0D;
      28: expected_uart_byte = 8'h0A;
      29: expected_uart_byte = 8'h46;
      30: expected_uart_byte = 8'h50;
      31: expected_uart_byte = 8'h47;
      32: expected_uart_byte = 8'h41;
      33: expected_uart_byte = 8'h5F;
      34: expected_uart_byte = 8'h56;
      35: expected_uart_byte = 8'h32;
      36: expected_uart_byte = 8'h5F;
      37: expected_uart_byte = 8'h45;
      38: expected_uart_byte = 8'h32;
      39: expected_uart_byte = 8'h30;
      40: expected_uart_byte = 8'h33;
      41: expected_uart_byte = 8'h5F;
      42: expected_uart_byte = 8'h4D;
      43: expected_uart_byte = 8'h55;
      44: expected_uart_byte = 8'h4C;
      45: expected_uart_byte = 8'h54;
      46: expected_uart_byte = 8'h49;
      47: expected_uart_byte = 8'h4C;
      48: expected_uart_byte = 8'h41;
      49: expected_uart_byte = 8'h59;
      50: expected_uart_byte = 8'h45;
      51: expected_uart_byte = 8'h52;
      52: expected_uart_byte = 8'h5F;
      53: expected_uart_byte = 8'h49;
      54: expected_uart_byte = 8'h4E;
      55: expected_uart_byte = 8'h46;
      56: expected_uart_byte = 8'h45;
      57: expected_uart_byte = 8'h52;
      58: expected_uart_byte = 8'h5F;
      59: expected_uart_byte = 8'h50;
      60: expected_uart_byte = 8'h41;
      61: expected_uart_byte = 8'h53;
      62: expected_uart_byte = 8'h53;
      63: expected_uart_byte = 8'h0D;
      64: expected_uart_byte = 8'h0A;
      default: expected_uart_byte = 8'h00;
      endcase
    end
  endfunction

  function automatic int dmem_waddr(input logic [31:0] addr);
    begin
      dmem_waddr = (addr - 32'h0001_0000) >> 2;
    end
  endfunction

  function automatic logic ptr_in_dmem(input logic [31:0] ptr, input int bytes);
    logic [31:0] last;
    begin
      last = ptr + bytes - 1;
      ptr_in_dmem = (ptr[1:0] == 2'b00)
                  && (ptr >= 32'h0001_0000)
                  && (last < 32'h0001_1F00);
    end
  endfunction

  always @(posedge clk) begin
    if (dut.u_uart.tx_busy) uart_busy_seen <= 1'b1;
    if (rst_n && dut.u_e203.clint_icb_cmd_valid) begin
      clint_cmd_seen <= 1'b1;
    end
    if (rst_n && dut.uart_req_valid && dut.uart_req_write && (dut.uart_req_addr[7:0] == 8'h00)) begin
      if (uart_byte_count < UART_EXPECT_LEN) begin
        if (dut.uart_req_wdata[7:0] !== expected_uart_byte(uart_byte_count)) begin
          $display("[ERR] UART byte[%0d] got 0x%02h exp 0x%02h",
                   uart_byte_count, dut.uart_req_wdata[7:0],
                   expected_uart_byte(uart_byte_count));
          uart_errors++;
        end
      end else begin
        $display("[ERR] unexpected extra UART byte 0x%02h", dut.uart_req_wdata[7:0]);
        uart_errors++;
      end
      uart_byte_count++;
    end
  end

  // ── DMEM marker addresses (word-offset into u_data_sram.mem) ────────
  // sram_simple 内部 mem[] 按 word 索引，word_addr = (global_addr - 0x00010000) >> 2
  localparam int WADDR_BOOT_MARK       = (32'h00011F00 - 32'h00010000) >> 2; // = 0x7C0
  localparam int WADDR_INFER_DONE_MARK = (32'h00011F04 - 32'h00010000) >> 2; // = 0x7C1
  localparam int WADDR_ENCODER_DONE    = (32'h00011F08 - 32'h00010000) >> 2; // = 0x7C2
  localparam int WADDR_BUF_PTR_0       = (32'h00011F0C - 32'h00010000) >> 2; // = 0x7C3
  localparam int WADDR_BUF_PTR_1       = (32'h00011F10 - 32'h00010000) >> 2; // = 0x7C4

  localparam logic [31:0] V2E203_BOOT_MARK        = 32'hB0070001;
  localparam logic [31:0] V2E203_INFER_DONE_MARK  = 32'h1F4ED001;

  int errors;

  initial begin
    $dumpfile("waves/v2_e203_cosim.vcd");
    $dumpvars(0, v2_e203_cosim_tb);
  end

  initial begin
    errors          = 0;
    rst_n           = 0;
    uart_rx         = 1;
    uart_byte_count = 0;
    uart_errors     = 0;
    uart_busy_seen  = 0;
    clint_cmd_seen  = 0;
    repeat (8) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    $display("[INFO] V2E203 cosim start, PC=0x%08h", dut.u_e203.inspect_pc);


    // ── M1: Wait BOOT_MARK ──────────────────────────────────────────
    begin : wait_boot
      int p;
      for (p = 0; p < 200000; p++) begin
        @(posedge clk);
        if (dut.u_data_sram.mem[WADDR_BOOT_MARK] == V2E203_BOOT_MARK) begin
          $display("[INFO] BOOT_MARK observed after %0d cycles, PC=0x%08h",
                   p + 1, dut.u_e203.inspect_pc);
          disable wait_boot;
        end
      end
      $display("[ERR] BOOT_MARK (0x%08h) not written within 200k cycles, DMEM[%0d]=0x%08h PC=0x%08h",
               V2E203_BOOT_MARK, WADDR_BOOT_MARK,
               dut.u_data_sram.mem[WADDR_BOOT_MARK], dut.u_e203.inspect_pc);
      errors++;
    end

    // ── M2: Check runtime BUFFER_PTRs from linker symbols ───────────
    begin
      logic [31:0] counts_ptr;
      logic [31:0] flags_ptr;
      counts_ptr = dut.u_data_sram.mem[WADDR_BUF_PTR_0];
      flags_ptr  = dut.u_data_sram.mem[WADDR_BUF_PTR_1];

      if (!ptr_in_dmem(counts_ptr, 400)) begin
        $display("[ERR] BUFFER_PTR_0 invalid: 0x%08h", counts_ptr);
        errors++;
      end
      if (!ptr_in_dmem(flags_ptr, 40)) begin
        $display("[ERR] BUFFER_PTR_1 invalid: 0x%08h", flags_ptr);
        errors++;
      end
      if (ptr_in_dmem(counts_ptr, 400) && ptr_in_dmem(flags_ptr, 40)) begin
        if (dut.u_data_sram.mem[dmem_waddr(counts_ptr)] !== 32'h0 ||
            dut.u_data_sram.mem[dmem_waddr(counts_ptr) + 99] !== 32'h0) begin
          $display("[ERR] smoke counts buffer was not cleared");
          errors++;
        end
        if (dut.u_data_sram.mem[dmem_waddr(flags_ptr)] !== 32'h0 ||
            dut.u_data_sram.mem[dmem_waddr(flags_ptr) + 9] !== 32'h0) begin
          $display("[ERR] sample_done_flags buffer was not cleared");
          errors++;
        end
      end
    end

    // ── M3: Wait INFER_DONE_MARK ────────────────────────────────────
    begin : wait_done
      int p;
      for (p = 0; p < 800000; p++) begin
        @(posedge clk);
        if (dut.u_data_sram.mem[WADDR_INFER_DONE_MARK] == V2E203_INFER_DONE_MARK) begin
          $display("[INFO] INFER_DONE_MARK observed after %0d cycles", p + 1);
          disable wait_done;
        end
      end
      $display("[ERR] INFER_DONE_MARK not observed PC=0x%08h DMEM=0x%08h",
               dut.u_e203.inspect_pc, dut.u_data_sram.mem[WADDR_INFER_DONE_MARK]);
      errors++;
    end

    // ── M4: UART tags + CLINT leak check ────────────────────────────
    begin : wait_uart
      int p;
      for (p = 0; p < 800000; p++) begin
        @(posedge clk);
        if (uart_byte_count >= UART_EXPECT_LEN) begin
          disable wait_uart;
        end
      end
      $display("[ERR] UART expected %0d bytes, got %0d", UART_EXPECT_LEN, uart_byte_count);
      errors++;
    end
    if (!uart_busy_seen) begin
      $display("[ERR] UART TX never became busy");
      errors++;
    end
    if (uart_errors != 0) begin
      $display("[ERR] UART byte mismatches: %0d", uart_errors);
      errors += uart_errors;
    end
    if (clint_cmd_seen) begin
      $display("[ERR] E203 CLINT port saw a command; UART address is not mem_icb-reachable");
      errors++;
    end

    // ── M5: PC sanity — 最后跑到 spin loop (非 PC=0 也非 trap vector) ─
    // 简单检查 PC != 0 且 PC 已进入 text 段（<64 KB）
    repeat (100) @(posedge clk);
    if (dut.u_e203.inspect_pc == 32'h0) begin
      $display("[ERR] PC=0 at end — CPU never started"); errors++;
    end else if (dut.u_e203.inspect_pc >= 32'h10000) begin
      $display("[ERR] PC=0x%08h out of IMEM range", dut.u_e203.inspect_pc); errors++;
    end

    // ── Summary ──────────────────────────────────────────────────────
    repeat (20) @(posedge clk);
    if (errors == 0) begin
      $display("V2_E203_COSIM_PASS");
    end else begin
      $display("V2_E203_COSIM_FAIL errors=%0d", errors);
      $fatal(1);
    end
    $finish;
  end

  initial begin
    #10000000;
    $display("[ERR] global timeout at 10 ms"); $fatal(1);
  end

endmodule
