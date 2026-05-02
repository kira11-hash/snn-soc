`timescale 1ns/1ps

// ─────────────────────────────────────────────────────────────────────────────
// boot_erase_e2e_tb
//
// 【背景】2026-04-25 MAJOR-#7 修复（独立审查 finding）：
//   tb/e203_tb.sv 用 ENABLE_PROGRAM_WEIGHT_MODEL=0（popcount 模式）跑 boot erase，
//   即便 boot full-array erase 真的"擦"了权重，对推理结果也没有可观察影响 →
//   测试只验证 FSM 走完，**不验证擦除真的清空了 weight_mem**。
//
//   本 TB 用 ENABLE_PROGRAM_WEIGHT_MODEL=1，强制把 weight_mem seed 成非零值，
//   走 PROG_CTRL.START（ERASE+FULL_ARRAY）→ wait DONE → 直接通过层级引用读
//   weight_mem 验证全部清零。这是端到端 dataflow 验证：
//
//   reg_bank.PROG_CTRL.START → cim_program_ctrl FSM → cim_macro_arbiter →
//   cim_macro_blackbox (P_USE_BRAM_WEIGHTS=1) → weight_mem 清零
//
// 【为什么不直接走 fw/main.c】
//   fw/main.c 的 boot_full_array_erase 已经在 e203_tb 跑过；本 TB 关注的是
//   "下游真的擦了"这一段，所以用 reg_bank 直接 bus_write 即可，不引入 SPI flash
//   bootloader / E203 等无关复杂度。
//
// ─────────────────────────────────────────────────────────────────────────────
module boot_erase_e2e_tb;
  import snn_soc_pkg::*;

  // ── DUT 接口 ─────────────────────────────────────────────────────────────
  logic clk;
  logic rst_n;
  logic uart_rx, uart_tx;
  logic spi_cs_n, spi_sck, spi_mosi, spi_miso;
  logic jtag_tck, jtag_tms, jtag_tdi, jtag_tdo;
  logic [7:0] wl_data_ext;
  logic [2:0] wl_group_sel_ext;
  logic       wl_latch_ext;
  logic       cim_start_ext;
  logic       cim_done_ext;
  logic [4:0] bl_sel_ext;
  logic [7:0] bl_data_ext;
  logic [2:0] prog_op_ext;
  logic [3:0] prog_level_ext;

  // 关键参数：BRAM weight model + 全编程链路
  snn_soc_top #(
    .ENABLE_E203                 (1'b0),    // TB 直接驱动 bus_if
    .ENABLE_EXT_CIM_IF           (1'b0),    // 内部 macro，不走 _ext pad
    .ENABLE_PROGRAM_MODE         (1'b1),
    .ENABLE_PROGRAM_WEIGHT_MODEL (1'b1)     // 关键：用 BRAM 权重，erase 才有可观察影响
  ) dut (.*);

  // ── Clock + reset ────────────────────────────────────────────────────────
  initial clk = 1'b0;
  always #10 clk = ~clk;     // 50 MHz

  // External pad-side signals not in use here (ENABLE_EXT_CIM_IF=0 内部走 macro)
  initial begin
    cim_done_ext = 1'b0;
    bl_data_ext  = 8'h0;
    uart_rx      = 1'b1;
    spi_miso     = 1'b0;
    jtag_tck     = 1'b0;
    jtag_tms     = 1'b0;
    jtag_tdi     = 1'b0;
  end

  // ── Bus 简单 master 任务（驱动 dut.bus_if）──────────────────────────────
  task bus_write(input [31:0] addr, input [31:0] data, input [3:0] strb);
    begin
      @(posedge clk);
      dut.bus_if.m_valid <= 1'b1;
      dut.bus_if.m_write <= 1'b1;
      dut.bus_if.m_addr  <= addr;
      dut.bus_if.m_wdata <= data;
      dut.bus_if.m_wstrb <= strb;
      @(posedge clk);
      dut.bus_if.m_valid <= 1'b0;
      dut.bus_if.m_write <= 1'b0;
      dut.bus_if.m_addr  <= 32'h0;
      dut.bus_if.m_wdata <= 32'h0;
      dut.bus_if.m_wstrb <= 4'h0;
    end
  endtask

  task bus_read(input [31:0] addr, output [31:0] data);
    begin
      @(posedge clk);
      dut.bus_if.m_valid <= 1'b1;
      dut.bus_if.m_write <= 1'b0;
      dut.bus_if.m_addr  <= addr;
      dut.bus_if.m_wstrb <= 4'h0;
      @(posedge clk);
      dut.bus_if.m_valid <= 1'b0;
      dut.bus_if.m_addr  <= 32'h0;
      // 等 1 拍让 bus_interconnect 寄存 + 1 拍 rvalid
      @(posedge clk);
      data = dut.bus_if.m_rdata;
    end
  endtask

  // ── 测试入口 ─────────────────────────────────────────────────────────────
  int unsigned non_zero_before, non_zero_after;
  logic [31:0] prog_status_v;
  logic [31:0] prog_pc;
  int unsigned r, c;
  int unsigned timeout_cnt;
  int unsigned poll_max;

  initial begin
    // 上电复位
    rst_n = 1'b0;
    dut.bus_if.m_valid <= 1'b0;
    dut.bus_if.m_write <= 1'b0;
    dut.bus_if.m_addr  <= 32'h0;
    dut.bus_if.m_wdata <= 32'h0;
    dut.bus_if.m_wstrb <= 4'h0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);
    $display("[INFO] boot_erase_e2e_tb start");

    // ── Step 1: 校验 PROG_FSM_PRESENT bit ─────────────────────────────────
    bus_read(32'h4000_0044, prog_status_v);
    if ((prog_status_v & 32'h0000_0040) == 0) begin
      $display("[FAIL] PROG_FSM_PRESENT bit should be 1 (ENABLE_PROGRAM_MODE=1)");
      $finish;
    end
    $display("[PASS] PROG_STATUS[6]=PROG_FSM_PRESENT=1, status=0x%08h", prog_status_v);

    // ── Step 2: 强制 seed weight_mem 成非零 ───────────────────────────────
    // 直接用层级引用（仅 TB，不影响综合）。所有 cell 设成中等值 0x40 = 64。
    for (r = 0; r < NUM_INPUTS; r = r + 1) begin
      for (c = 0; c < ADC_CHANNELS; c = c + 1) begin
        dut.gen_internal_cim_macro.u_macro.weight_mem[r][c] = 8'h40;
      end
    end
    @(posedge clk);

    // 校验 seed 成功
    non_zero_before = 0;
    for (r = 0; r < NUM_INPUTS; r = r + 1) begin
      for (c = 0; c < ADC_CHANNELS; c = c + 1) begin
        if (dut.gen_internal_cim_macro.u_macro.weight_mem[r][c] != 8'h00) begin
          non_zero_before = non_zero_before + 1;
        end
      end
    end
    if (non_zero_before != NUM_INPUTS * ADC_CHANNELS) begin
      $display("[FAIL] seed phase: only %0d/%0d cells non-zero",
               non_zero_before, NUM_INPUTS * ADC_CHANNELS);
      $finish;
    end
    $display("[PASS] seed: %0d/%0d cells = 0x40 (expected non-zero before erase)",
             non_zero_before, NUM_INPUTS * ADC_CHANNELS);

    // ── Step 3: 触发 boot full-array erase via PROG_CTRL ───────────────────
    // PROG_CTRL = ERASE | FULL_ARRAY | START，BYPASS=0（用真实 macro 路径）
    // RETRY_LIMIT 在低字节 byte0 之外，整字写默认 4'hF strb 会清掉 — 但 erase
    // 是 fire-and-forget 的，无需 retry，本 TB 不关心 retry_limit 副作用。
    bus_write(32'h4000_0044, 32'h0000_0080, 4'h1); // 先清旧 DONE sticky (W1C)
    bus_write(32'h4000_0038, 32'h0000_0007, 4'hF); // ERASE | FULL_ARRAY | START

    // ── Step 4: 等 PROG_STATUS.DONE up ────────────────────────────────────
    // 1ms erase pulse @ 50MHz = 50000 cycles，再加几千 cycle 流水裕量
    poll_max = 100000;
    timeout_cnt = 0;
    begin : wait_done
      forever begin
        bus_read(32'h4000_0044, prog_status_v);
        if (prog_status_v & 32'h0000_0080) begin
          $display("[INFO] PROG_STATUS DONE up after %0d polls, status=0x%08h",
                   timeout_cnt, prog_status_v);
          if (prog_status_v & 32'h0000_0004) begin
            $display("[FAIL] PROG_STATUS.FAIL set after erase (status=0x%08h)", prog_status_v);
            $finish;
          end
          if ((prog_status_v & 32'h0000_0002) == 0) begin
            $display("[FAIL] PROG_STATUS.PASS not set after erase (status=0x%08h)", prog_status_v);
            $finish;
          end
          disable wait_done;
        end
        timeout_cnt = timeout_cnt + 1;
        if (timeout_cnt > poll_max) begin
          $display("[FAIL] PROG_STATUS DONE timeout after %0d polls", poll_max);
          $finish;
        end
      end
    end

    // ── Step 5: 验证 weight_mem 全部被擦回 0 ───────────────────────────────
    non_zero_after = 0;
    for (r = 0; r < NUM_INPUTS; r = r + 1) begin
      for (c = 0; c < ADC_CHANNELS; c = c + 1) begin
        if (dut.gen_internal_cim_macro.u_macro.weight_mem[r][c] != 8'h00) begin
          non_zero_after = non_zero_after + 1;
        end
      end
    end
    if (non_zero_after != 0) begin
      $display("[FAIL] erase incomplete: %0d/%0d cells still non-zero",
               non_zero_after, NUM_INPUTS * ADC_CHANNELS);
      // 输出第一个非零 cell 位置帮助定位
      begin : print_first
        for (r = 0; r < NUM_INPUTS; r = r + 1) begin
          for (c = 0; c < ADC_CHANNELS; c = c + 1) begin
            if (dut.gen_internal_cim_macro.u_macro.weight_mem[r][c] != 8'h00) begin
              $display("       e.g. weight_mem[%0d][%0d] = 0x%02h",
                       r, c, dut.gen_internal_cim_macro.u_macro.weight_mem[r][c]);
              disable print_first;
            end
          end
        end
      end
      $finish;
    end
    $display("[PASS] erase complete: all %0d cells = 0x00 after boot full-array erase",
             NUM_INPUTS * ADC_CHANNELS);

    $display("BOOT_ERASE_E2E_TB_PASS");
    $finish;
  end

  // 全局超时
  initial begin
    #20_000_000; // 20 ms sim time
    // BLOCKER B-03 fix（2026-05-02 audit）：补协议化 FAIL marker。
    $display("[FAIL] Global timeout (20ms sim)");
    $display("BOOT_ERASE_E2E_TB_FAIL (global timeout)");
    $finish;
  end
endmodule
