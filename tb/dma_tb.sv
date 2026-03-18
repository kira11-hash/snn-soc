`timescale 1ns/1ps
//======================================================================
// 文件名: tb/dma_tb.sv
// 描述: dma_engine 独立烟雾测试（Iter 4 — DMA 多目标扩展）
//
// 测试覆盖：
//   T1 : DST_INPUT_FIFO —— 8 word（4 push × 64-bit），数据完整性校验
//   T2 : DST_WEIGHT_BUF —— 6 word 逐字写入 weight_sram，读回校验
//   T3 : DST_INSTR_SRAM —— 6 word 逐字写入 instr_sram，读回校验
//   T4 : DST_INPUT_FIFO 奇数长度 → ERR（兼容旧行为）
//   T5 : 未对齐地址 → ERR
//   T6 : DONE/ERR W1C 清零
//   T7 : DST_WEIGHT_BUF 奇数长度 → 允许（SRAM 目标不要求偶数）
//   T8 : DST_INPUT_FIFO FIFO 背压：full 时暂停，不丢数据
//   T9 : DMA 进行中写 REG_DST_SEL 被忽略，不得中途切换目标
//   T10: 非法 DST_SEL=2'b11 -> ERR
//
// 通过标准：所有测试输出 [PASS]，最后打印 DMA_SMOKETEST_PASS
//======================================================================
module dma_tb;
  import snn_soc_pkg::*;

  // ── 时钟 / 复位 ──────────────────────────────────────────────────────────
  logic clk;
  initial clk = 0;
  always #10 clk = ~clk; // 50 MHz

  logic rst_n;

  // ── DMA 总线接口 ─────────────────────────────────────────────────────────
  logic        req_valid, req_write;
  logic [31:0] req_addr, req_wdata;
  logic [3:0]  req_wstrb;
  logic [31:0] rdata;

  // ── data_sram 模型（DMA 读源）────────────────────────────────────────────
  localparam int DATA_WORDS = 256;
  logic [31:0] data_mem [0:DATA_WORDS-1];
  logic        dma_rd_en;
  logic [31:0] dma_rd_addr;
  logic [31:0] dma_rd_data;

  // 组合读（与 sram_simple_dp DMA 端口行为一致，截取低 8 位字地址）
  assign dma_rd_data = dma_rd_en ? data_mem[dma_rd_addr[9:2]] : 32'h0;

  // ── input_fifo 接口 ───────────────────────────────────────────────────────
  logic        in_fifo_push;
  logic [NUM_INPUTS-1:0] in_fifo_wdata;
  logic        in_fifo_full;

  localparam int PUSH_LOG_SIZE = 32;
  logic [NUM_INPUTS-1:0] push_log [0:PUSH_LOG_SIZE-1];
  integer push_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      push_cnt <= 0;
    else if (in_fifo_push && (push_cnt < PUSH_LOG_SIZE))
      push_cnt <= push_cnt + 1;
  end
  always_ff @(posedge clk) begin
    if (in_fifo_push && (push_cnt < PUSH_LOG_SIZE))
      push_log[push_cnt] <= in_fifo_wdata;
  end

  // ── weight / instr SRAM DMA 写接口 ───────────────────────────────────────
  logic        weight_wr_en;
  logic [31:0] weight_wr_addr, weight_wr_data;
  logic [3:0]  weight_wr_strb;

  logic        instr_wr_en;
  logic [31:0] instr_wr_addr, instr_wr_data;
  logic [3:0]  instr_wr_strb;

  localparam int SRAM_WORDS = 256;
  logic [31:0] weight_mem [0:SRAM_WORDS-1];
  logic [31:0] instr_mem  [0:SRAM_WORDS-1];

  always_ff @(posedge clk) begin
    if (weight_wr_en) begin
      if (weight_wr_strb[0]) weight_mem[weight_wr_addr[9:2]][7:0]   <= weight_wr_data[7:0];
      if (weight_wr_strb[1]) weight_mem[weight_wr_addr[9:2]][15:8]  <= weight_wr_data[15:8];
      if (weight_wr_strb[2]) weight_mem[weight_wr_addr[9:2]][23:16] <= weight_wr_data[23:16];
      if (weight_wr_strb[3]) weight_mem[weight_wr_addr[9:2]][31:24] <= weight_wr_data[31:24];
    end
    if (instr_wr_en) begin
      if (instr_wr_strb[0]) instr_mem[instr_wr_addr[9:2]][7:0]   <= instr_wr_data[7:0];
      if (instr_wr_strb[1]) instr_mem[instr_wr_addr[9:2]][15:8]  <= instr_wr_data[15:8];
      if (instr_wr_strb[2]) instr_mem[instr_wr_addr[9:2]][23:16] <= instr_wr_data[23:16];
      if (instr_wr_strb[3]) instr_mem[instr_wr_addr[9:2]][31:24] <= instr_wr_data[31:24];
    end
  end

  // ── DUT ──────────────────────────────────────────────────────────────────
  dma_engine u_dma (
    .clk          (clk),
    .rst_n        (rst_n),
    .req_valid    (req_valid),
    .req_write    (req_write),
    .req_addr     (req_addr),
    .req_wdata    (req_wdata),
    .req_wstrb    (req_wstrb),
    .rdata        (rdata),
    .dma_rd_en    (dma_rd_en),
    .dma_rd_addr  (dma_rd_addr),
    .dma_rd_data  (dma_rd_data),
    .in_fifo_push (in_fifo_push),
    .in_fifo_wdata(in_fifo_wdata),
    .in_fifo_full (in_fifo_full),
    .weight_wr_en  (weight_wr_en),
    .weight_wr_addr(weight_wr_addr),
    .weight_wr_data(weight_wr_data),
    .weight_wr_strb(weight_wr_strb),
    .instr_wr_en   (instr_wr_en),
    .instr_wr_addr (instr_wr_addr),
    .instr_wr_data (instr_wr_data),
    .instr_wr_strb (instr_wr_strb)
  );

  // ── 总线偏移常量（dma_engine 以 req_addr[7:0] 解码）─────────────────────
  localparam logic [31:0] REG_SRC_ADDR  = 32'h00;
  localparam logic [31:0] REG_LEN_WORDS = 32'h04;
  localparam logic [31:0] REG_DMA_CTRL  = 32'h08;
  localparam logic [31:0] REG_DST_SEL   = 32'h0C;

  task bus_write(input logic [31:0] addr, input logic [31:0] data);
    @(posedge clk); #1;
    req_valid = 1; req_write = 1;
    req_addr  = addr; req_wdata = data; req_wstrb = 4'hF;
    @(posedge clk); #1;
    req_valid = 0; req_write = 0;
  endtask

  task bus_read(input logic [31:0] addr, output logic [31:0] rd);
    @(posedge clk); #1;
    req_valid = 1; req_write = 0;
    req_addr  = addr; req_wdata = 32'h0; req_wstrb = 4'h0;
    #1;
    rd = rdata;
    @(posedge clk); #1;
    req_valid = 0;
  endtask

  // 等待 BUSY 撤低（bit[3]=0）
  task wait_done(input integer timeout_cycles);
    logic [31:0] ctrl;
    integer i;
    i = 0;
    bus_read(REG_DMA_CTRL, ctrl);
    while (ctrl[3] && (i < timeout_cycles)) begin
      @(posedge clk);
      bus_read(REG_DMA_CTRL, ctrl);
      i = i + 1;
    end
    if (ctrl[3]) begin
      $display("[ERROR] DMA timeout after %0d cycles", timeout_cycles);
      $finish;
    end
  endtask

  // ── 测试计数 ──────────────────────────────────────────────────────────────
  integer pass_cnt, fail_cnt;

  task check(input string name, input logic cond);
    if (cond) begin
      $display("[PASS] %s", name);
      pass_cnt = pass_cnt + 1;
    end else begin
      $display("[FAIL] %s", name);
      fail_cnt = fail_cnt + 1;
    end
  endtask

  // ── 主测试流程 ────────────────────────────────────────────────────────────
  integer i;
  logic [31:0] rd;
  integer prev_push;

  initial begin
    pass_cnt = 0; fail_cnt = 0;
    req_valid = 0; req_write = 0;
    req_addr = 0; req_wdata = 0; req_wstrb = 0;
    in_fifo_full = 0;

    for (i = 0; i < 16; i = i + 1)
      data_mem[i] = 32'hA000_0000 + i;
    for (i = 0; i < SRAM_WORDS; i = i + 1) begin
      weight_mem[i] = 32'h0;
      instr_mem[i]  = 32'h0;
    end

    rst_n = 0;
    repeat(4) @(posedge clk);
    rst_n = 1;
    repeat(2) @(posedge clk);

    // ==================================================================
    // T1: DST_INPUT_FIFO —— 8 words (4 × 64-bit push)
    // ==================================================================
    $display("--- T1: DST_INPUT_FIFO 8-word copy ---");
    bus_write(REG_DST_SEL,   32'h0);          // DST_INPUT_FIFO（默认）
    bus_write(REG_SRC_ADDR,  ADDR_DATA_BASE);
    bus_write(REG_LEN_WORDS, 32'd8);
    bus_write(REG_DMA_CTRL,  32'h1);
    wait_done(100);

    check("T1.push_cnt==4",  push_cnt == 4);
    check("T1.push[0].lo",   push_log[0][31:0]  == data_mem[0]);
    check("T1.push[0].hi",   push_log[0][63:32] == data_mem[1]);
    check("T1.push[3].lo",   push_log[3][31:0]  == data_mem[6]);
    check("T1.push[3].hi",   push_log[3][63:32] == data_mem[7]);
    bus_read(REG_DMA_CTRL, rd);
    check("T1.DONE=1",  rd[1] == 1'b1);
    check("T1.ERR=0",   rd[2] == 1'b0);
    bus_write(REG_DMA_CTRL, 32'h2);

    // ==================================================================
    // T2: DST_WEIGHT_BUF —— 6 words 逐字写入 weight_sram
    // ==================================================================
    $display("--- T2: DST_WEIGHT_BUF 6-word copy ---");
    bus_write(REG_DST_SEL,   32'h1);
    bus_write(REG_SRC_ADDR,  ADDR_DATA_BASE);
    bus_write(REG_LEN_WORDS, 32'd6);
    bus_write(REG_DMA_CTRL,  32'h1);
    wait_done(100);
    repeat(2) @(posedge clk); // extra wait for last write to settle

    check("T2.weight[0]",  weight_mem[0] == data_mem[0]);
    check("T2.weight[1]",  weight_mem[1] == data_mem[1]);
    check("T2.weight[5]",  weight_mem[5] == data_mem[5]);
    bus_read(REG_DMA_CTRL, rd);
    check("T2.DONE=1",     rd[1] == 1'b1);
    check("T2.ERR=0",      rd[2] == 1'b0);
    bus_write(REG_DMA_CTRL, 32'h2);

    // ==================================================================
    // T3: DST_INSTR_SRAM —— 6 words 逐字写入 instr_sram（从 offset 0x10 读）
    // ==================================================================
    $display("--- T3: DST_INSTR_SRAM 6-word copy ---");
    bus_write(REG_DST_SEL,   32'h2);
    bus_write(REG_SRC_ADDR,  ADDR_DATA_BASE + 32'h10); // offset 16B = word[4]
    bus_write(REG_LEN_WORDS, 32'd6);
    bus_write(REG_DMA_CTRL,  32'h1);
    wait_done(100);
    repeat(2) @(posedge clk);

    check("T3.instr[4]",  instr_mem[4] == data_mem[4]);
    check("T3.instr[5]",  instr_mem[5] == data_mem[5]);
    check("T3.instr[9]",  instr_mem[9] == data_mem[9]);
    bus_read(REG_DMA_CTRL, rd);
    check("T3.DONE=1",    rd[1] == 1'b1);
    check("T3.ERR=0",     rd[2] == 1'b0);
    bus_write(REG_DMA_CTRL, 32'h2);

    // ==================================================================
    // T4: DST_INPUT_FIFO 奇数长度 → ERR
    // ==================================================================
    $display("--- T4: INPUT_FIFO odd length -> ERR ---");
    bus_write(REG_DST_SEL,   32'h0);
    bus_write(REG_SRC_ADDR,  ADDR_DATA_BASE);
    bus_write(REG_LEN_WORDS, 32'd5);
    bus_write(REG_DMA_CTRL,  32'h1);
    repeat(4) @(posedge clk);
    bus_read(REG_DMA_CTRL, rd);
    check("T4.ERR=1",   rd[2] == 1'b1);
    check("T4.DONE=1",  rd[1] == 1'b1);
    check("T4.BUSY=0",  rd[3] == 1'b0);
    bus_write(REG_DMA_CTRL, 32'h6);

    // ==================================================================
    // T5: 未对齐地址 → ERR
    // ==================================================================
    $display("--- T5: misaligned address -> ERR ---");
    bus_write(REG_SRC_ADDR,  ADDR_DATA_BASE + 32'h1);
    bus_write(REG_LEN_WORDS, 32'd4);
    bus_write(REG_DMA_CTRL,  32'h1);
    repeat(4) @(posedge clk);
    bus_read(REG_DMA_CTRL, rd);
    check("T5.ERR=1",   rd[2] == 1'b1);
    check("T5.BUSY=0",  rd[3] == 1'b0);
    bus_write(REG_DMA_CTRL, 32'h6);

    // ==================================================================
    // T6: DONE/ERR W1C 清零
    // ==================================================================
    $display("--- T6: W1C clear DONE/ERR ---");
    bus_write(REG_SRC_ADDR,  ADDR_DATA_BASE + 32'h2); // 非对齐
    bus_write(REG_LEN_WORDS, 32'd2);
    bus_write(REG_DMA_CTRL,  32'h1);
    repeat(4) @(posedge clk);
    bus_read(REG_DMA_CTRL, rd);
    check("T6.before.ERR=1", rd[2] == 1'b1);
    bus_write(REG_DMA_CTRL, 32'h6); // W1C DONE+ERR
    repeat(2) @(posedge clk);
    bus_read(REG_DMA_CTRL, rd);
    check("T6.after.ERR=0",  rd[2] == 1'b0);
    check("T6.after.DONE=0", rd[1] == 1'b0);

    // ==================================================================
    // T7: DST_WEIGHT_BUF 奇数长度 → 允许
    // ==================================================================
    $display("--- T7: WEIGHT_BUF odd length -> OK ---");
    weight_mem[10] = 32'h0; weight_mem[11] = 32'h0; weight_mem[12] = 32'h0;
    bus_write(REG_DST_SEL,   32'h1);
    bus_write(REG_SRC_ADDR,  ADDR_DATA_BASE + 32'h28); // offset 0x28 = word[10]
    bus_write(REG_LEN_WORDS, 32'd3);
    bus_write(REG_DMA_CTRL,  32'h1);
    wait_done(100);
    repeat(2) @(posedge clk);
    bus_read(REG_DMA_CTRL, rd);
    check("T7.ERR=0",      rd[2] == 1'b0);
    check("T7.DONE=1",     rd[1] == 1'b1);
    check("T7.weight[10]", weight_mem[10] == data_mem[10]);
    check("T7.weight[12]", weight_mem[12] == data_mem[12]);
    bus_write(REG_DMA_CTRL, 32'h2);

    // ==================================================================
    // T8: DST_INPUT_FIFO FIFO 背压
    // ==================================================================
    $display("--- T8: INPUT_FIFO backpressure ---");
    prev_push = push_cnt;
    in_fifo_full = 1'b1;
    bus_write(REG_DST_SEL,   32'h0);
    bus_write(REG_SRC_ADDR,  ADDR_DATA_BASE);
    bus_write(REG_LEN_WORDS, 32'd4);
    bus_write(REG_DMA_CTRL,  32'h1);
    repeat(12) @(posedge clk);
    bus_read(REG_DMA_CTRL, rd);
    check("T8.still_busy",   rd[3] == 1'b1);
    check("T8.no_push_yet",  push_cnt == prev_push);
    @(posedge clk); #1;
    in_fifo_full = 1'b0;
    wait_done(50);
    check("T8.push_done",   push_cnt == (prev_push + 2));
    bus_read(REG_DMA_CTRL, rd);
    check("T8.DONE=1",      rd[1] == 1'b1);
    bus_write(REG_DMA_CTRL, 32'h2);

    // ==================================================================
    // T9: busy 时写 REG_DST_SEL 应被忽略
    // ==================================================================
    $display("--- T9: DST_SEL write ignored while busy ---");
    weight_mem[8] = 32'h0; weight_mem[9] = 32'h0;
    instr_mem[8]  = 32'h0; instr_mem[9]  = 32'h0;
    bus_write(REG_DST_SEL,   32'h1);                 // 目标先设为 weight
    bus_write(REG_SRC_ADDR,  ADDR_DATA_BASE + 32'h20); // word[8]
    bus_write(REG_LEN_WORDS, 32'd2);
    bus_write(REG_DMA_CTRL,  32'h1);
    @(posedge clk);
    bus_write(REG_DST_SEL,   32'h2);                 // busy 期间尝试切到 instr
    wait_done(100);
    repeat(2) @(posedge clk);
    bus_read(REG_DST_SEL, rd);
    check("T9.dst_sel_kept_weight", rd[1:0] == 2'b01);
    check("T9.weight_written",      weight_mem[8] == data_mem[8] && weight_mem[9] == data_mem[9]);
    check("T9.instr_untouched",     instr_mem[8]  == 32'h0 && instr_mem[9] == 32'h0);
    bus_write(REG_DMA_CTRL, 32'h2);

    // ==================================================================
    // T10: 非法 DST_SEL=2'b11 -> ERR
    // ==================================================================
    $display("--- T10: invalid DST_SEL -> ERR ---");
    bus_write(REG_DST_SEL,   32'h3);
    bus_write(REG_SRC_ADDR,  ADDR_DATA_BASE);
    bus_write(REG_LEN_WORDS, 32'd2);
    bus_write(REG_DMA_CTRL,  32'h1);
    repeat(4) @(posedge clk);
    bus_read(REG_DMA_CTRL, rd);
    check("T10.ERR=1",   rd[2] == 1'b1);
    check("T10.DONE=1",  rd[1] == 1'b1);
    check("T10.BUSY=0",  rd[3] == 1'b0);
    bus_write(REG_DMA_CTRL, 32'h6);

    // ==================================================================
    // 结果汇总
    // ==================================================================
    $display("==============================================");
    $display("[RESULT] Pass: %0d  Fail: %0d", pass_cnt, fail_cnt);
    if (fail_cnt == 0)
      $display("DMA_SMOKETEST_PASS");
    else
      $display("DMA_SMOKETEST_FAIL");
    $display("==============================================");
    $finish;
  end

  initial begin
    #500000;
    $display("[ERROR] Simulation timeout");
    $finish;
  end

endmodule
