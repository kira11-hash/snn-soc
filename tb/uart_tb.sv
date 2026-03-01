`timescale 1ns/1ps
//======================================================================
// 文件名: tb/uart_tb.sv
// 模块名: uart_tb
//
// 【功能概述】
// uart_ctrl 独立烟雾测试台（Standalone Smoke Testbench）。
// 直接驱动 bus_simple slave 接口（req_*），无需 bus_interconnect，
// 监控 uart_tx 引脚，按 8N1 协议解码字节后与期望值比对。
//
// 【测试列表】
//   T1: 写 CTRL（baud_div=8），读回验证
//   T2: 发送 0x55（01010101），解码验证
//   T3: 发送 0xA5（10100101），解码验证
//   T4: 发送 0xFF，解码验证
//   T5: 发送 0x00，解码验证
//   T6: 发送时读 STATUS.tx_busy=1，发送后验证 tx_busy=0
//   T7: 发送忙时再写 TXDATA（应忽略），之后发正常字节
//
// 【通过标准】
//   所有 [PASS] 无 [FAIL] → 最终输出 UART_SMOKETEST_PASS
//
// 【Icarus 兼容性】
//   - 模块端口使用平铺 logic，不使用 interface modport
//   - 循环变量用 integer 声明
//   - 任务声明为非自动（non-automatic）
//   - SVA 断言在 `ifdef VCS 内
//======================================================================

module uart_tb;

  // ── 时钟和复位 ────────────────────────────────────────────────────────────
  logic clk, rst_n;
  initial clk = 0;
  always #5 clk = ~clk;   // 100MHz，周期 10ns

  // ── DUT 信号 ──────────────────────────────────────────────────────────────
  logic        req_valid;
  logic        req_write;
  logic [31:0] req_addr;
  logic [31:0] req_wdata;
  logic [3:0]  req_wstrb;
  logic [31:0] rdata;
  logic        uart_rx;
  logic        uart_tx;

  // DUT：uart_ctrl
  uart_ctrl dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .req_valid (req_valid),
    .req_write (req_write),
    .req_addr  (req_addr),
    .req_wdata (req_wdata),
    .req_wstrb (req_wstrb),
    .rdata     (rdata),
    .uart_rx   (uart_rx),
    .uart_tx   (uart_tx)
  );

  // ── UART 基地址（与 snn_soc_pkg 一致）────────────────────────────────────
  localparam logic [31:0] UART_BASE = 32'h4000_0200;

  // ── 寄存器 offset ─────────────────────────────────────────────────────────
  localparam logic [3:0] REG_TXDATA = 4'h0;
  localparam logic [3:0] REG_STATUS = 4'h4;
  localparam logic [3:0] REG_CTRL   = 4'h8;

  // ── 通过/失败计数器 ───────────────────────────────────────────────────────
  integer pass_cnt, fail_cnt;

  // ── 总线写任务 ────────────────────────────────────────────────────────────
  // 向 DUT 发起一次写请求（单拍有效脉冲）
  task bus_write;
    input [3:0]  offset;
    input [31:0] data;
    begin
      @(posedge clk);
      #1;
      req_valid = 1'b1;
      req_write = 1'b1;
      req_addr  = UART_BASE | {28'h0, offset};
      req_wdata = data;
      req_wstrb = 4'hF;
      @(posedge clk);
      #1;
      req_valid = 1'b0;
      req_write = 1'b0;
    end
  endtask

  // ── 总线读任务 ────────────────────────────────────────────────────────────
  // 向 DUT 发起一次读请求（单拍有效脉冲），返回当拍 rdata（组合读）
  // 注：uart_ctrl.rdata 是组合输出，req_valid 当拍即有效
  task bus_read;
    input  [3:0]  offset;
    output [31:0] data;
    begin
      @(posedge clk);
      #1;
      req_valid = 1'b1;
      req_write = 1'b0;
      req_addr  = UART_BASE | {28'h0, offset};
      req_wdata = 32'h0;
      req_wstrb = 4'h0;
      // 等半拍让组合逻辑稳定，再采样 rdata
      #4;
      data = rdata;
      @(posedge clk);
      #1;
      req_valid = 1'b0;
    end
  endtask

  // ── 检查任务 ──────────────────────────────────────────────────────────────
  task check;
    input [31:0] got;
    input [31:0] exp;
    input [63:0] label;  // 8字符标签（packed ASCII）
    begin
      if (got === exp) begin
        $display("[PASS] %s: got=0x%08X", label, got);
        pass_cnt = pass_cnt + 1;
      end else begin
        $display("[FAIL] %s: got=0x%08X  exp=0x%08X", label, got, exp);
        fail_cnt = fail_cnt + 1;
      end
    end
  endtask

  // ── UART TX 解码任务 ──────────────────────────────────────────────────────
  // 等待起始位下沿，然后按 baud_div 采样 8 个数据位（在每位中点采样）
  // 返回解码字节
  // baud_clk：每个 baud 周期的时钟数（= baud_div_reg 的值）
  integer baud_clk;
  task uart_decode;
    output [7:0] byte_out;
    integer i;
    begin
      // 等待起始位（uart_tx 下降沿）
      @(negedge uart_tx);
      // 等半个 baud，到达起始位中点，再检测一次确认是起始位（防毛刺）
      repeat (baud_clk / 2) @(posedge clk);
      if (uart_tx !== 1'b0) begin
        $display("[WARN] uart_decode: start bit sample failed (uart_tx=%b)", uart_tx);
      end
      // 逐位采样 D0~D7，在每位中点采样（从起始位中点到下一位中点 = 1 baud）
      byte_out = 8'h0;
      for (i = 0; i < 8; i = i + 1) begin
        repeat (baud_clk) @(posedge clk);      // 等 1 个 baud（到达数据位中点）
        byte_out[i] = uart_tx;                 // LSB 先发，逐位填入
      end
      // 采样停止位（可选校验）
      repeat (baud_clk) @(posedge clk);
      if (uart_tx !== 1'b1) begin
        $display("[WARN] uart_decode: stop bit not high (uart_tx=%b)", uart_tx);
        fail_cnt = fail_cnt + 1;
      end
    end
  endtask

  // ── 发送+解码+校验辅助任务 ────────────────────────────────────────────────
  task send_and_check;
    input [7:0] byte_to_send;
    reg [7:0]   decoded;
    reg [31:0]  rd;
    begin
      // 启动解码任务（后台等待起始位）——用 fork/join 并发
      fork
        begin
          bus_write(REG_TXDATA, {24'h0, byte_to_send});
        end
        begin
          uart_decode(decoded);
        end
      join
      // 等发送完成（tx_busy 归 0）
      begin : wait_idle
        integer timeout;
        timeout = 0;
        while (1) begin
          bus_read(REG_STATUS, rd);
          if (rd[0] == 1'b0) disable wait_idle;
          if (timeout > 20000) begin
            $display("[FAIL] send_and_check: tx_busy timeout");
            fail_cnt = fail_cnt + 1;
            disable wait_idle;
          end
          timeout = timeout + 1;
          @(posedge clk);
        end
      end
    end
  endtask

  // ── 看门狗定时器 ──────────────────────────────────────────────────────────
  initial begin
    #2_000_000;
    $display("[TIMEOUT] Simulation exceeded 2ms - force exit");
    $finish;
  end

  // ── 主测试序列 ────────────────────────────────────────────────────────────
  integer rd_val;
  reg [7:0] decoded_byte;
  reg [31:0] rd_data;

  initial begin
    // 初始化
    pass_cnt  = 0;
    fail_cnt  = 0;
    rst_n     = 0;
    req_valid = 0;
    req_write = 0;
    req_addr  = 0;
    req_wdata = 0;
    req_wstrb = 0;
    uart_rx   = 1;
    baud_clk  = 8;   // 仿真用小分频值

    // 复位释放
    repeat (4) @(posedge clk);
    #1; rst_n = 1;
    repeat (2) @(posedge clk);

    $display("============================================================");
    $display("[INFO] UART TX Smoke Test Start");
    $display("============================================================");

    // ──────────────────────────────────────────────────────────────────────
    // T1: 写 CTRL（baud_div=8），读回验证
    // ──────────────────────────────────────────────────────────────────────
    $display("[T1] CTRL baud_div write/read");
    bus_write(REG_CTRL, 32'd8);    // 设置 baud_div=8（仿真加速）
    bus_read (REG_CTRL, rd_data);
    check(rd_data, 32'd8, "T1_CTRL ");

    // ──────────────────────────────────────────────────────────────────────
    // T2: 发送 0x55，解码验证（交替 01 模式）
    // ──────────────────────────────────────────────────────────────────────
    $display("[T2] Send 0x55");
    fork
      bus_write(REG_TXDATA, 32'h55);
      uart_decode(decoded_byte);
    join
    check({24'h0, decoded_byte}, 32'h55, "T2_0x55 ");
    // 等发送完成
    repeat (20) @(posedge clk);

    // ──────────────────────────────────────────────────────────────────────
    // T3: 发送 0xA5，解码验证
    // ──────────────────────────────────────────────────────────────────────
    $display("[T3] Send 0xA5");
    fork
      bus_write(REG_TXDATA, 32'hA5);
      uart_decode(decoded_byte);
    join
    check({24'h0, decoded_byte}, 32'hA5, "T3_0xA5 ");
    repeat (20) @(posedge clk);

    // ──────────────────────────────────────────────────────────────────────
    // T4: 发送 0xFF（全1），解码验证
    // ──────────────────────────────────────────────────────────────────────
    $display("[T4] Send 0xFF");
    fork
      bus_write(REG_TXDATA, 32'hFF);
      uart_decode(decoded_byte);
    join
    check({24'h0, decoded_byte}, 32'hFF, "T4_0xFF ");
    repeat (20) @(posedge clk);

    // ──────────────────────────────────────────────────────────────────────
    // T5: 发送 0x00（全0），解码验证
    // ──────────────────────────────────────────────────────────────────────
    $display("[T5] Send 0x00");
    fork
      bus_write(REG_TXDATA, 32'h00);
      uart_decode(decoded_byte);
    join
    check({24'h0, decoded_byte}, 32'h00, "T5_0x00 ");
    repeat (20) @(posedge clk);

    // ──────────────────────────────────────────────────────────────────────
    // T6: 发送中读 STATUS.tx_busy，确认忙时为1、发完后为0
    // ──────────────────────────────────────────────────────────────────────
    $display("[T6] STATUS.tx_busy check");
    bus_write(REG_TXDATA, 32'hAA);   // 触发发送
    // 紧跟一拍读 STATUS
    @(posedge clk); #1;
    req_valid = 1; req_write = 0;
    req_addr  = UART_BASE | 32'h4;
    #4; rd_data = rdata;
    @(posedge clk); #1; req_valid = 0;
    check(rd_data[0], 1'b1, "T6_BUSY ");  // 应为 busy

    // 等发送完毕：baud_div=8，10 bit * 8 clk = 80 clk
    repeat (120) @(posedge clk);
    bus_read(REG_STATUS, rd_data);
    check(rd_data[0], 1'b0, "T6_IDLE ");  // 应为 idle
    // 消耗掉这帧 uart_tx 上的数据（已发完，无需 decode）

    // ──────────────────────────────────────────────────────────────────────
    // T7: 忙时写 TXDATA 应被忽略；等空闲后再正常发送 0x3C
    // ──────────────────────────────────────────────────────────────────────
    $display("[T7] Busy-ignore + normal send 0x3C");
    // 发送一个 0xBB
    bus_write(REG_TXDATA, 32'hBB);
    // 立即（仍在发送中）再写 0x3C（应被忽略）
    @(posedge clk); #1;
    req_valid = 1; req_write = 1;
    req_addr  = UART_BASE | 32'h0;
    req_wdata = 32'h3C;
    req_wstrb = 4'hF;
    @(posedge clk); #1;
    req_valid = 0; req_write = 0;

    // 等 0xBB 发完
    repeat (120) @(posedge clk);

    // 再等空闲，然后发 0x3C（干净发送）
    repeat (5) @(posedge clk);
    $display("[T7b] Send 0x3C cleanly after idle");
    fork
      bus_write(REG_TXDATA, 32'h3C);
      uart_decode(decoded_byte);
    join
    check({24'h0, decoded_byte}, 32'h3C, "T7_0x3C ");
    repeat (20) @(posedge clk);

    // ──────────────────────────────────────────────────────────────────────
    // 结果汇总
    // ──────────────────────────────────────────────────────────────────────
    $display("============================================================");
    $display("[RESULT] PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
    if (fail_cnt == 0)
      $display("UART_SMOKETEST_PASS");
    else
      $display("UART_SMOKETEST_FAIL");
    $display("============================================================");
    $finish;
  end

  // ── SVA 断言（VCS 专用）──────────────────────────────────────────────────
  `ifndef SYNTHESIS
  `ifdef VCS
    // TX 线在空闲状态必须为高（Mark）
    property p_tx_idle_high;
      @(posedge clk) disable iff (!rst_n)
      (dut.tx_state == 2'd0) |-> uart_tx;
    endproperty
    a_tx_idle_high: assert property (p_tx_idle_high)
      else $error("[UART_TB] uart_tx not high in IDLE (state=%0d)", dut.tx_state);

    // tx_busy 在 IDLE 状态必须为 0
    property p_busy_in_idle;
      @(posedge clk) disable iff (!rst_n)
      (dut.tx_state == 2'd0) |-> !dut.tx_busy;
    endproperty
    a_busy_in_idle: assert property (p_busy_in_idle)
      else $error("[UART_TB] tx_busy asserted in IDLE state");
  `endif
  `endif

endmodule
