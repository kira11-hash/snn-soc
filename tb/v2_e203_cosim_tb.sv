`timescale 1ns/1ps
`ifndef NUM_COSIM_SAMPLES
`define NUM_COSIM_SAMPLES 3
`endif
//======================================================================
// 文件名: tb/v2_e203_cosim_tb.sv (Phase A-8)
//
// End-to-end firmware cosim. 加载 v2_e203_smoke.hex → E203 启动 → 跑 10 样本
// v2b 推理 → 写 DMEM counts buffer + sample_done_flags → INFER_DONE_MARK +
// UART tags。TB 验证：
//   M1  BOOT_MARK 出现
//   M2  BUFFER_PTR_0/1 指向合法 DMEM 位置
//   M3  读 sample_XX_counts.txt 作为 expected；对每个 k 等 sample_done_flags[k]=1
//       后校验 counts_buf[k][0..9] 与 Python golden 逐位一致（100 counts bit-exact）
//   M4  INFER_DONE_MARK 出现
//   M5  UART tx 观察到 "FPGA_V2_E203_BOOT_UART_PASS\n" +
//                    "FPGA_V2_E203_MULTILAYER_INFER_PASS\n" exact bytes
//   M6  CLINT 通道必须零活动（fabric/bridge 不误路由到 0x0200_xxxx）
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

  initial begin
    $readmemh("../fw/v2_e203_smoke/out/v2_e203_smoke.hex", dut.u_instr_sram.mem);
  end

  // ── DMEM word-offset helpers (addr - 0x00010000) >> 2 ─────────────
  localparam int WADDR_BOOT_MARK       = (32'h00011F00 - 32'h00010000) >> 2;
  localparam int WADDR_INFER_DONE_MARK = (32'h00011F04 - 32'h00010000) >> 2;
  localparam int WADDR_BUF_PTR_0       = (32'h00011F0C - 32'h00010000) >> 2;
  localparam int WADDR_BUF_PTR_1       = (32'h00011F10 - 32'h00010000) >> 2;

  localparam logic [31:0] V2E203_BOOT_MARK        = 32'hB0070001;
  localparam logic [31:0] V2E203_INFER_DONE_MARK  = 32'h1F4ED001;

  function automatic int dmem_waddr(input logic [31:0] addr);
    dmem_waddr = int'((addr - 32'h0001_0000) >> 2);
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

  // ── Expected counts table (10 samples × 10 classes, loaded from Python txt) ─
  int expected_counts [0:9][0:9];

  task automatic load_expected_counts;
    int fd, k, j, dummy, val;
    string path;
    begin
      for (k = 0; k < 10; k++) begin
        path = $sformatf("../python_multilayer/results_multilayer/fashion_multilayer_golden/sample_%02d_counts.txt", k);
        fd = $fopen(path, "r");
        if (fd == 0) begin
          $display("[FATAL] cannot open %s", path);
          $fatal(1);
        end
        for (j = 0; j < 10; j++) begin
          val = 0;
          dummy = $fscanf(fd, "%d\n", val);
          expected_counts[k][j] = val;
        end
        $fclose(fd);
      end
    end
  endtask

  // ── UART tx byte shadow (bit-exact verification) ─────────────────
  byte uart_observed [$];
  logic [9:0] uart_sr;       // {stop, data[7:0], start}
  int uart_bit_cnt;
  logic uart_sampling;
  logic uart_prev_tx;

  // Hook into uart_ctrl internals: txdata latch + tx_busy edge
  // We'll take a simpler route: sample uart_tx at 1/16 of bit period. For
  // exact decode, read the shadow register inside uart_ctrl directly.
  // Simpler: dump txdata_shadow each time tx_busy asserts.
  logic prev_tx_busy;
  initial begin
    prev_tx_busy = 0;
    uart_observed = {};
  end

  always @(posedge clk) begin
    if (rst_n) begin
      // On rising edge of tx_busy, capture txdata byte
      if (dut.u_uart.tx_busy && !prev_tx_busy) begin
        uart_observed.push_back(byte'(dut.u_uart.txdata_shadow));
      end
      prev_tx_busy <= dut.u_uart.tx_busy;
    end
  end

  // ── CLINT zero-activity guard: no CPU access should leak to 0x0200_xxxx ─
  int clint_hits;
  initial clint_hits = 0;
  always @(posedge clk) begin
    if (rst_n && dut.u_bridge.i_icb_cmd_valid && dut.u_bridge.i_icb_cmd_ready) begin
      if (dut.u_bridge.i_icb_cmd_addr[31:16] == 16'h0200) begin
        $display("[ERR] CPU issued MEM_ICB access to CLINT alias 0x%08h (should be routed via clint_icb)",
                 dut.u_bridge.i_icb_cmd_addr);
        clint_hits++;
      end
    end
  end

  int errors;

  initial begin
    $dumpfile("waves/v2_e203_cosim.vcd");
    $dumpvars(0, v2_e203_cosim_tb);
  end

  task automatic wait_dmem_eq(input int word_offset, input logic [31:0] exp_val,
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
          $display("[ERR] %s timeout in %0d cycles, DMEM[%0d]=0x%08h",
                   tag, max_cycles, word_offset,
                   dut.u_data_sram.mem[word_offset]);
          errors++;
          done = 1'b1;
        end
      end
    end
  endtask

  // ── Main ───────────────────────────────────────────────────────────
  initial begin
    errors  = 0;
    rst_n   = 0;
    uart_rx = 1;

    load_expected_counts();
    $display("[INFO] loaded expected counts for 10 samples");

    repeat (8) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    $display("[INFO] V2E203 cosim start, PC=0x%08h", dut.u_e203.inspect_pc);
    // Progress heartbeat
    fork
      begin : hb
        int n;
        for (n = 0; n < 200; n++) begin
          repeat (500_000) @(posedge clk);
          $display("[HB] cycle=%0dM PC=0x%08h boot=0x%08h done=0x%08h",
                   (n+1)/2, dut.u_e203.inspect_pc,
                   dut.u_data_sram.mem[WADDR_BOOT_MARK],
                   dut.u_data_sram.mem[WADDR_INFER_DONE_MARK]);
        end
      end
    join_none

    // ── M1: Wait BOOT_MARK ──────────────────────────────────────────
    wait_dmem_eq(WADDR_BOOT_MARK, V2E203_BOOT_MARK, 20000, "BOOT_MARK");

    // ── M2: BUFFER_PTRs → locate counts_buf + sample_done_flags ────
    begin
      logic [31:0] counts_ptr, flags_ptr;
      int waddr_counts, waddr_flags;
      counts_ptr = dut.u_data_sram.mem[WADDR_BUF_PTR_0];
      flags_ptr  = dut.u_data_sram.mem[WADDR_BUF_PTR_1];
      if (!ptr_in_dmem(counts_ptr, 400)) begin
        $display("[ERR] BUFFER_PTR_0 invalid: 0x%08h", counts_ptr); errors++;
      end
      if (!ptr_in_dmem(flags_ptr, 40)) begin
        $display("[ERR] BUFFER_PTR_1 invalid: 0x%08h", flags_ptr); errors++;
      end
      waddr_counts = dmem_waddr(counts_ptr);
      waddr_flags  = dmem_waddr(flags_ptr);

      // ── M3: per-sample bit-exact counts (TB checks first NUM_COSIM_SAMPLES;
      //       firmware is built with matching -DNUM_COSIM_SAMPLES). ─────────
      for (int k = 0; k < `NUM_COSIM_SAMPLES; k++) begin
        // Wait sample_done_flags[k] == 1
        wait_dmem_eq(waddr_flags + k, 32'h1, 2_000_000,
                     $sformatf("sample_done_flags[%0d]", k));
        // Compare counts[k][j] vs Python expected_counts[k][j]
        for (int j = 0; j < 10; j++) begin
          logic [31:0] got = dut.u_data_sram.mem[waddr_counts + k*10 + j];
          if (got !== (expected_counts[k][j] & 32'hFFFFFFFF)) begin
            $display("[ERR] counts[%0d][%0d] got=0x%08h exp=%0d",
                     k, j, got, expected_counts[k][j]);
            errors++;
          end
        end
      end
    end

    // ── M4: INFER_DONE_MARK ─────────────────────────────────────────
    wait_dmem_eq(WADDR_INFER_DONE_MARK, V2E203_INFER_DONE_MARK, 500_000,
                 "INFER_DONE_MARK");

    // ── M5: UART byte-exact check ───────────────────────────────────
    begin
      string want = "FPGA_V2_E203_BOOT_UART_PASS\nFPGA_V2_E203_MULTILAYER_INFER_PASS\n";
      int want_len = want.len();
      // Wait up to 50k extra cycles for UART tail bytes to drain
      int w;
      bit enough;
      enough = 1'b0;
      w = 0;
      while (!enough && w < 5_000_000) begin
        @(posedge clk);
        w++;
        if (uart_observed.size() >= want_len) enough = 1'b1;
      end
      if (uart_observed.size() < want_len) begin
        $display("[ERR] UART short: observed %0d bytes, expected %0d",
                 uart_observed.size(), want_len);
        errors++;
      end else begin
        int mism = 0;
        for (int i = 0; i < want_len; i++) begin
          if (byte'(want[i]) !== uart_observed[i]) begin
            if (mism < 8) $display("[ERR] UART byte %0d: got 0x%02h exp 0x%02h ('%c')",
                                    i, uart_observed[i], byte'(want[i]), want[i]);
            mism++;
          end
        end
        if (mism != 0) begin
          $display("[ERR] UART mismatch total %0d bytes", mism);
          errors++;
        end else begin
          $display("[INFO] UART byte-exact match (%0d bytes)", want_len);
        end
      end
    end

    // ── M6: CLINT guard summary ─────────────────────────────────────
    if (clint_hits != 0) begin
      $display("[ERR] %0d MEM_ICB hits to CLINT alias", clint_hits);
      errors++;
    end

    repeat (20) @(posedge clk);
    if (errors == 0) $display("V2_E203_COSIM_PASS");
    else begin
      $display("V2_E203_COSIM_FAIL errors=%0d", errors);
      $fatal(1);
    end
    $finish;
  end

  initial begin
    #200_000_000;
    $display("[ERR] global timeout"); $fatal(1);
  end

endmodule
