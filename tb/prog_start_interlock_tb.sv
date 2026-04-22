`timescale 1ns/1ps
//======================================================================
// prog_start_interlock_tb
//
// 【背景】2026-04-22 GPT review Q2 发现 back-to-back START race：
//   - CPU 在 cycle N 写 CIM_CTRL.START=1 → start_pulse <= 1
//   - cycle N+1 start_pulse visible，但 snn_busy 要下一拍才拉高
//   - 若 CPU 此拍写 PROG_CTRL.START=1，!snn_busy 仍为真 → prog_start_pulse 也置 1
//   - 结果：两条 FSM 同时启动，违反单路径独占 CIM 宏的约定
//
// 【本 TB 验证】三重互锁（busy + pending + start_pulse）是否能封堵该 race：
//   T1  : 正常独立写 CIM_CTRL.START，只有 start_pulse 发 1 拍，prog_start_pulse 全 0
//   T2  : 正常独立写 PROG_CTRL.START，只有 prog_start_pulse 发 1 拍
//   T3★ : back-to-back 写 CIM_CTRL.START（N）→ PROG_CTRL.START（N+1），
//         应只有 start_pulse 发 1 拍，prog_start_pulse 不能发
//   T4★ : 反向 back-to-back：PROG_CTRL.START（N）→ CIM_CTRL.START（N+1）
//   T5  : busy 期间写另一路 START，应被旧互锁屏蔽（等价回归）
//   T6  : busy 撤下来但 pending 仍高（FSM 慢 busy）时，应被 pending 屏蔽
//
// 【为什么是 reg_bank 级 TB】
// race 的根源就在 reg_bank 内部（start 信号发出 → downstream busy 拉起的 1 拍延迟）；
// 用 reg_bank 级 TB 最能隔离被测逻辑，不引入 cim_array_ctrl / cim_program_ctrl 的
// 额外时序变量。busy 和 done_pulse 由本 TB 模拟控制。
//======================================================================
module prog_start_interlock_tb;
  import snn_soc_pkg::*;

  logic clk;
  logic rst_n;
  logic req_valid;
  logic req_write;
  logic [31:0] req_addr;
  logic [31:0] req_wdata;
  logic [3:0]  req_wstrb;
  logic [31:0] rdata;

  logic [31:0] neuron_threshold;
  logic [7:0]  timesteps;
  logic        reset_mode;
  logic        start_pulse;
  logic        soft_reset_pulse;
  logic        cim_test_mode;
  logic [ADC_BITS-1:0] cim_test_data_pos;
  logic [ADC_BITS-1:0] cim_test_data_neg;
  logic        out_fifo_pop;
  logic [3:0]  out_fifo_rdata_zero;
  logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] out_fifo_count_zero;

  logic        prog_start_pulse;
  logic        prog_erase;
  logic        prog_full_array;
  logic [5:0]  prog_row;
  logic [4:0]  prog_col;
  logic [3:0]  prog_level;
  logic [2:0]  prog_retry_limit;
  logic [15:0] prog_pulse_width;
  logic [15:0] prog_erase_width;

  // 本 TB 模拟下游 busy/done 行为
  logic        snn_busy_stim;
  logic        snn_done_stim;
  logic        prog_busy_stim;
  logic        prog_done_stim;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  reg_bank dut (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid(req_valid),
    .req_write(req_write),
    .req_addr(req_addr),
    .req_wdata(req_wdata),
    .req_wstrb(req_wstrb),
    .rdata(rdata),
    .snn_busy(snn_busy_stim),
    .snn_done_pulse(snn_done_stim),
    .timestep_counter(8'd0),
    .in_fifo_empty(1'b1),
    .in_fifo_full(1'b0),
    .out_fifo_empty(1'b1),
    .out_fifo_full(1'b0),
    .out_fifo_rdata(out_fifo_rdata_zero),
    .out_fifo_count(out_fifo_count_zero),
    .adc_sat_high(16'd0),
    .adc_sat_low(16'd0),
    .dbg_dma_frame_cnt(16'd0),
    .dbg_cim_cycle_cnt(16'd0),
    .dbg_spike_cnt(16'd0),
    .dbg_wl_stall_cnt(16'd0),
    .neuron_threshold(neuron_threshold),
    .timesteps(timesteps),
    .reset_mode(reset_mode),
    .start_pulse(start_pulse),
    .soft_reset_pulse(soft_reset_pulse),
    .cim_test_mode(cim_test_mode),
    .cim_test_data_pos(cim_test_data_pos),
    .cim_test_data_neg(cim_test_data_neg),
    .out_fifo_pop(out_fifo_pop),
    .prog_start_pulse(prog_start_pulse),
    .prog_erase(prog_erase),
    .prog_full_array(prog_full_array),
    .prog_row(prog_row),
    .prog_col(prog_col),
    .prog_level(prog_level),
    .prog_retry_limit(prog_retry_limit),
    .prog_pulse_width(prog_pulse_width),
    .prog_erase_width(prog_erase_width),
    .prog_busy(prog_busy_stim),
    .prog_done_pulse(prog_done_stim),
    .prog_pass(1'b0),
    .prog_fail(1'b0),
    .prog_retry_count(3'd0)
  );

  int pass_count;
  int fail_count;

  // 计数器：记录 start_pulse / prog_start_pulse 发出次数（单拍脉冲累加）
  int start_pulse_fired;
  int prog_start_pulse_fired;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      start_pulse_fired      <= 0;
      prog_start_pulse_fired <= 0;
    end else begin
      if (start_pulse)      start_pulse_fired      <= start_pulse_fired + 1;
      if (prog_start_pulse) prog_start_pulse_fired <= prog_start_pulse_fired + 1;
    end
  end

  task clear_counters;
    begin
      start_pulse_fired      = 0;
      prog_start_pulse_fired = 0;
    end
  endtask

  // 单拍写（不自动 de-assert 到 IDLE，直接连续驱动）
  task bus_write_onecycle(input [7:0] addr, input [31:0] data, input [3:0] strb);
    begin
      req_valid <= 1'b1;
      req_write <= 1'b1;
      req_addr  <= {24'h0, addr};
      req_wdata <= data;
      req_wstrb <= strb;
    end
  endtask

  task bus_idle;
    begin
      req_valid <= 1'b0;
      req_write <= 1'b0;
      req_addr  <= 32'h0;
      req_wdata <= 32'h0;
      req_wstrb <= 4'h0;
    end
  endtask

  task do_reset;
    begin
      rst_n = 1'b0;
      bus_idle;
      snn_busy_stim  = 1'b0;
      snn_done_stim  = 1'b0;
      prog_busy_stim = 1'b0;
      prog_done_stim = 1'b0;
      out_fifo_rdata_zero = '0;
      out_fifo_count_zero = '0;
      repeat (4) @(posedge clk);
      rst_n = 1'b1;
      repeat (2) @(posedge clk);
      clear_counters;
    end
  endtask

  initial begin
    pass_count = 0;
    fail_count = 0;

    // ── T1: 独立写 CIM_CTRL.START ───────────────────────────────
    $display("--- T1: Standalone CIM_CTRL.START ---");
    do_reset;
    @(posedge clk);
    bus_write_onecycle(8'h14, 32'h0000_0001, 4'hF); // CIM_CTRL.START
    @(posedge clk);
    bus_idle;
    repeat (3) @(posedge clk);
    if (start_pulse_fired == 1 && prog_start_pulse_fired == 0) begin
      $display("[PASS] T1: start_pulse=%0d prog_start_pulse=%0d",
               start_pulse_fired, prog_start_pulse_fired);
      pass_count++;
    end else begin
      $display("[FAIL] T1: expected start=1 prog=0, got start=%0d prog=%0d",
               start_pulse_fired, prog_start_pulse_fired);
      fail_count++;
    end

    // ── T2: 独立写 PROG_CTRL.START ──────────────────────────────
    $display("--- T2: Standalone PROG_CTRL.START ---");
    do_reset;
    @(posedge clk);
    bus_write_onecycle(8'h38, 32'h0000_0051, 4'hF); // PROG_CTRL: START=1, LEVEL=5
    @(posedge clk);
    bus_idle;
    repeat (3) @(posedge clk);
    if (start_pulse_fired == 0 && prog_start_pulse_fired == 1) begin
      $display("[PASS] T2: start_pulse=%0d prog_start_pulse=%0d",
               start_pulse_fired, prog_start_pulse_fired);
      pass_count++;
    end else begin
      $display("[FAIL] T2: expected start=0 prog=1, got start=%0d prog=%0d",
               start_pulse_fired, prog_start_pulse_fired);
      fail_count++;
    end

    // ── T3★: back-to-back CIM.START (cycle N) → PROG.START (cycle N+1) ──
    // Race: snn_busy 此时仍为 0（下游 FSM 还没转 busy），旧代码会放行 prog_start_pulse。
    // 三重互锁应封堵：!start_pulse 检查在 cycle N+1 看到 start_pulse=1 阻止。
    $display("--- T3: BACK-TO-BACK CIM.START -> PROG.START (Q2 race) ---");
    do_reset;
    @(posedge clk);
    bus_write_onecycle(8'h14, 32'h0000_0001, 4'hF); // CIM_CTRL.START (cycle N)
    @(posedge clk);
    // cycle N+1: start_pulse 已 visible，snn_busy_stim 人为保持 0（模拟 race）
    bus_write_onecycle(8'h38, 32'h0000_0051, 4'hF); // PROG_CTRL.START (cycle N+1)
    @(posedge clk);
    bus_idle;
    repeat (5) @(posedge clk);
    if (start_pulse_fired == 1 && prog_start_pulse_fired == 0) begin
      $display("[PASS] T3: back-to-back race blocked (start=%0d prog=%0d)",
               start_pulse_fired, prog_start_pulse_fired);
      pass_count++;
    end else begin
      $display("[FAIL] T3: RACE LEAK! start=%0d prog=%0d (expected 1, 0)",
               start_pulse_fired, prog_start_pulse_fired);
      fail_count++;
    end

    // ── T4★: 反向 back-to-back PROG.START (N) → CIM.START (N+1) ───
    $display("--- T4: BACK-TO-BACK PROG.START -> CIM.START (reverse) ---");
    do_reset;
    @(posedge clk);
    bus_write_onecycle(8'h38, 32'h0000_0051, 4'hF); // PROG_CTRL.START
    @(posedge clk);
    // prog_busy 此刻为 0（人为）；旧代码会让 start_pulse 也发出
    bus_write_onecycle(8'h14, 32'h0000_0001, 4'hF); // CIM_CTRL.START
    @(posedge clk);
    bus_idle;
    repeat (5) @(posedge clk);
    if (start_pulse_fired == 0 && prog_start_pulse_fired == 1) begin
      $display("[PASS] T4: reverse race blocked (start=%0d prog=%0d)",
               start_pulse_fired, prog_start_pulse_fired);
      pass_count++;
    end else begin
      $display("[FAIL] T4: RACE LEAK! start=%0d prog=%0d (expected 0, 1)",
               start_pulse_fired, prog_start_pulse_fired);
      fail_count++;
    end

    // ── T5: busy 期间写另一路 START 必须被屏蔽（回归已有互锁）──
    //   让 snn_busy 先稳定 2 拍再做 write，避免 TB 初始化阶段的瞬态 race
    //   （T5 只测稳态互锁，不测 back-to-back race；后者由 T3/T4 覆盖）。
    $display("--- T5: While snn_busy=1 (stable), PROG.START must be blocked ---");
    do_reset;
    snn_busy_stim = 1'b1;
    repeat (2) @(posedge clk);
    bus_write_onecycle(8'h38, 32'h0000_0051, 4'hF);
    @(posedge clk);
    bus_idle;
    @(posedge clk);
    snn_busy_stim = 1'b0;
    repeat (3) @(posedge clk);
    if (prog_start_pulse_fired == 0) begin
      $display("[PASS] T5");
      pass_count++;
    end else begin
      $display("[FAIL] T5: PROG fired (%0d) during snn_busy", prog_start_pulse_fired);
      fail_count++;
    end

    // ── T6: busy 尚未升起但 pending 已经高（FSM 慢 busy）时，
    //        再次写同路径 START 不应重复 fire（同侧再启动保护）。
    //        测试：写 CIM.START → cycle N+1 snn_busy_stim 仍 0 → 再写 CIM.START
    //        第二次由于 snn_start_pending=1 不重置 start_pulse（但 start_pulse
    //        本身由上一拍 NBA 清零，允许再次写；实际现象是再发一拍 start_pulse）。
    //        这里只检查 pending 的反向作用：PROG.START 在 pending 期间也被屏蔽。
    $display("--- T6: pending-only guard (snn_busy not yet up, prog.START blocked) ---");
    do_reset;
    @(posedge clk);
    bus_write_onecycle(8'h14, 32'h0000_0001, 4'hF); // CIM.START @ N
    @(posedge clk); bus_idle;
    // 保持 snn_busy_stim=0 故意不让 downstream FSM 升 busy
    repeat (3) @(posedge clk); // start_pulse 已单拍发完 → snn_start_pending=1
    clear_counters;
    bus_write_onecycle(8'h38, 32'h0000_0051, 4'hF); // 现在尝试 PROG.START
    @(posedge clk);
    bus_idle;
    repeat (3) @(posedge clk);
    if (prog_start_pulse_fired == 0) begin
      $display("[PASS] T6: pending guard blocked PROG.START");
      pass_count++;
    end else begin
      $display("[FAIL] T6: pending guard leak, prog fired %0d times",
               prog_start_pulse_fired);
      fail_count++;
    end

    // ── Summary ───────────────────────────────────────────────
    $display("");
    $display("=== Results: %0d PASS, %0d FAIL ===", pass_count, fail_count);
    if (fail_count == 0)
      $display("PROG_START_INTERLOCK_TB_PASS");
    else
      $display("PROG_START_INTERLOCK_TB_FAIL");
    $finish;
  end

  initial begin
    #2_000_000;
    $display("[FAIL] Global timeout");
    $finish;
  end
endmodule
