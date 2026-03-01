`timescale 1ns/1ps
//======================================================================
// 文件名: tb/axi_bridge_tb.sv
// 用途:   axi2simple_bridge + bus_interconnect 端到端测试
//
// 【测试架构】
//   Testbench BFM（平铺 AXI-Lite 信号）
//        ↓
//   axi2simple_bridge（DUT：协议转换）
//        ↓
//   bus_interconnect（地址译码 + 路由）
//        ↓
//   test_regs[]（8 个 32-bit 寄存器，挂在 ADDR_REG_BASE）
//
// 【测试项】
//   T1: 写 reg[0]，读回验证（DEAD_BEEF）
//   T2: 写 reg[1]，读回验证（CAFE_1234）
//   T3: 写 reg[4]，读回验证（类 REG_THRESHOLD 地址）
//   T4: reg[0] 持久性验证（T2 后再读 reg[0] 不变）
//   T5: 字节写使能验证（wstrb=4'b0001，只改 byte0）
//   T6: AXI-Lite 错拍写（AW 先到）
//   T7: AXI-Lite 错拍写（W 先到）
//
// 【通过标准】
//   所有 $display("[PASS]") 无 "[FAIL]"，最终打印 AXI_BRIDGE_SMOKETEST_PASS
//
// 【Icarus 兼容性】
//   不使用 automatic task（顺序执行无需）
//   不使用 interface modport（BFM 用平铺信号）
//   for 循环使用 integer 计数变量
//======================================================================

module axi_bridge_tb;
  import snn_soc_pkg::*;

  // ── 时钟与复位 ────────────────────────────────────────────────────────────
  logic clk = 1'b0;
  logic rst_n;
  always #10 clk = ~clk;  // 50 MHz

  // ── AXI-Lite 平铺信号（BFM → bridge）──────────────────────────────────
  // 写地址通道
  logic        s_awvalid, s_awready;
  logic [31:0] s_awaddr;
  // 写数据通道
  logic        s_wvalid, s_wready;
  logic [31:0] s_wdata;
  logic [3:0]  s_wstrb;
  // 写响应通道
  logic        s_bvalid, s_bready;
  logic [1:0]  s_bresp;
  // 读地址通道
  logic        s_arvalid, s_arready;
  logic [31:0] s_araddr;
  // 读数据通道
  logic        s_rvalid, s_rready;
  logic [31:0] s_rdata;
  logic [1:0]  s_rresp;

  // ── bus_simple 信号（bridge → interconnect）──────────────────────────────
  logic        m_valid, m_write, m_ready, m_rvalid;
  logic [31:0] m_addr, m_wdata_bus, m_rdata;
  logic [3:0]  m_wstrb_bus;

  // ── bus_interconnect → 各从机信号 ────────────────────────────────────────
  logic        instr_req_valid, instr_req_write;
  logic [31:0] instr_req_addr, instr_req_wdata, instr_rdata;
  logic [3:0]  instr_req_wstrb;

  logic        data_req_valid, data_req_write;
  logic [31:0] data_req_addr, data_req_wdata, data_rdata;
  logic [3:0]  data_req_wstrb;

  logic        weight_req_valid, weight_req_write;
  logic [31:0] weight_req_addr, weight_req_wdata, weight_rdata;
  logic [3:0]  weight_req_wstrb;

  // reg slave（测试目标）
  logic        reg_req_valid, reg_req_write, reg_resp_read_pulse;
  logic [31:0] reg_req_addr, reg_req_wdata, reg_rdata, reg_resp_addr;
  logic [3:0]  reg_req_wstrb;

  logic        dma_req_valid, dma_req_write;
  logic [31:0] dma_req_addr, dma_req_wdata, dma_rdata;
  logic [3:0]  dma_req_wstrb;

  logic        uart_req_valid, uart_req_write;
  logic [31:0] uart_req_addr, uart_req_wdata, uart_rdata;
  logic [3:0]  uart_req_wstrb;

  logic        spi_req_valid, spi_req_write;
  logic [31:0] spi_req_addr, spi_req_wdata, spi_rdata;
  logic [3:0]  spi_req_wstrb;

  logic        fifo_req_valid, fifo_req_write;
  logic [31:0] fifo_req_addr, fifo_req_wdata, fifo_rdata;
  logic [3:0]  fifo_req_wstrb;

  // ── DUT: AXI-Lite → simple bus 桥 ───────────────────────────────────────
  axi2simple_bridge u_bridge (
    .clk(clk), .rst_n(rst_n),
    .s_awvalid(s_awvalid), .s_awready(s_awready), .s_awaddr(s_awaddr),
    .s_wvalid(s_wvalid),   .s_wready(s_wready),
    .s_wdata(s_wdata),     .s_wstrb(s_wstrb),
    .s_bvalid(s_bvalid),   .s_bready(s_bready),   .s_bresp(s_bresp),
    .s_arvalid(s_arvalid), .s_arready(s_arready), .s_araddr(s_araddr),
    .s_rvalid(s_rvalid),   .s_rready(s_rready),
    .s_rdata(s_rdata),     .s_rresp(s_rresp),
    .m_valid(m_valid),     .m_write(m_write),      .m_addr(m_addr),
    .m_wdata(m_wdata_bus), .m_wstrb(m_wstrb_bus),
    .m_ready(m_ready),     .m_rdata(m_rdata),      .m_rvalid(m_rvalid)
  );

  // ── 总线互联 ──────────────────────────────────────────────────────────────
  bus_interconnect u_ic (
    .clk(clk), .rst_n(rst_n),
    .m_valid(m_valid),   .m_write(m_write),   .m_addr(m_addr),
    .m_wdata(m_wdata_bus), .m_wstrb(m_wstrb_bus),
    .m_ready(m_ready),   .m_rdata(m_rdata),   .m_rvalid(m_rvalid),
    .instr_req_valid(instr_req_valid), .instr_req_write(instr_req_write),
    .instr_req_addr(instr_req_addr),   .instr_req_wdata(instr_req_wdata),
    .instr_req_wstrb(instr_req_wstrb), .instr_rdata(instr_rdata),
    .data_req_valid(data_req_valid),   .data_req_write(data_req_write),
    .data_req_addr(data_req_addr),     .data_req_wdata(data_req_wdata),
    .data_req_wstrb(data_req_wstrb),   .data_rdata(data_rdata),
    .weight_req_valid(weight_req_valid), .weight_req_write(weight_req_write),
    .weight_req_addr(weight_req_addr),   .weight_req_wdata(weight_req_wdata),
    .weight_req_wstrb(weight_req_wstrb), .weight_rdata(weight_rdata),
    .reg_req_valid(reg_req_valid),     .reg_req_write(reg_req_write),
    .reg_req_addr(reg_req_addr),       .reg_req_wdata(reg_req_wdata),
    .reg_req_wstrb(reg_req_wstrb),     .reg_rdata(reg_rdata),
    .reg_resp_read_pulse(reg_resp_read_pulse), .reg_resp_addr(reg_resp_addr),
    .dma_req_valid(dma_req_valid),     .dma_req_write(dma_req_write),
    .dma_req_addr(dma_req_addr),       .dma_req_wdata(dma_req_wdata),
    .dma_req_wstrb(dma_req_wstrb),     .dma_rdata(dma_rdata),
    .uart_req_valid(uart_req_valid),   .uart_req_write(uart_req_write),
    .uart_req_addr(uart_req_addr),     .uart_req_wdata(uart_req_wdata),
    .uart_req_wstrb(uart_req_wstrb),   .uart_rdata(uart_rdata),
    .spi_req_valid(spi_req_valid),     .spi_req_write(spi_req_write),
    .spi_req_addr(spi_req_addr),       .spi_req_wdata(spi_req_wdata),
    .spi_req_wstrb(spi_req_wstrb),     .spi_rdata(spi_rdata),
    .fifo_req_valid(fifo_req_valid),   .fifo_req_write(fifo_req_write),
    .fifo_req_addr(fifo_req_addr),     .fifo_req_wdata(fifo_req_wdata),
    .fifo_req_wstrb(fifo_req_wstrb),   .fifo_rdata(fifo_rdata)
  );

  // ── 未使用从机：rdata 恒 0 ───────────────────────────────────────────────
  assign instr_rdata  = 32'h0;
  assign data_rdata   = 32'h0;
  assign weight_rdata = 32'h0;
  assign dma_rdata    = 32'h0;
  assign uart_rdata   = 32'h0;
  assign spi_rdata    = 32'h0;
  assign fifo_rdata   = 32'h0;

  // ── 测试寄存器堆（8 × 32-bit，挂载于 ADDR_REG_BASE）────────────────────
  // reg_req_addr[4:2] = word index（0~7），支持字节写使能
  logic [31:0] test_regs [0:7];
  integer      idx;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (idx = 0; idx < 8; idx = idx + 1) test_regs[idx] <= 32'h0;
    end else if (reg_req_valid && reg_req_write) begin
      if (reg_req_wstrb[0]) test_regs[reg_req_addr[4:2]][7:0]   <= reg_req_wdata[7:0];
      if (reg_req_wstrb[1]) test_regs[reg_req_addr[4:2]][15:8]  <= reg_req_wdata[15:8];
      if (reg_req_wstrb[2]) test_regs[reg_req_addr[4:2]][23:16] <= reg_req_wdata[23:16];
      if (reg_req_wstrb[3]) test_regs[reg_req_addr[4:2]][31:24] <= reg_req_wdata[31:24];
    end
  end

  // 组合读：当 reg_req_valid 有效时返回对应寄存器值
  assign reg_rdata = reg_req_valid ? test_regs[reg_req_addr[4:2]] : 32'h0;

  // ── 测试计数 ──────────────────────────────────────────────────────────────
  integer pass_cnt;
  integer fail_cnt;
  logic [31:0] rd_data;

  // ── AXI-Lite BFM tasks ───────────────────────────────────────────────────
  //
  // axi_write：
  //   同时驱动 AW + W 通道，等待 AWREADY/WREADY，再等待 B 通道响应。
  //
  // axi_read：
  //   驱动 AR 通道，等待 ARREADY，再等待 R 通道数据（s_rready 常态为 1）。
  //
  // 时序说明：
  //   在 posedge 之后 #1 再采样/驱动，避免 0-delay 竞争。
  //   READY 可能是组合脉冲，故先“看到 READY”，再过一个上升沿完成握手。
  // ──────────────────────────────────────────────────────────────────────────

  task axi_write;
    input [31:0] addr;
    input [31:0] data;
    input [3:0]  strb;
    begin
      @(posedge clk); #1;
      s_awvalid = 1'b1; s_awaddr = addr;
      s_wvalid  = 1'b1; s_wdata  = data; s_wstrb = strb;
      while (!(s_awready && s_wready)) begin @(posedge clk); #1; end
      // READY 已观测到，下一拍完成握手后拉低 valid
      @(posedge clk); #1;
      s_awvalid = 1'b0;
      s_wvalid  = 1'b0;
      while (!s_bvalid) begin @(posedge clk); #1; end
      @(posedge clk); #1;
    end
  endtask

  task axi_read;
    input  [31:0] addr;
    output [31:0] data;
    begin
      @(posedge clk); #1;
      s_arvalid = 1'b1; s_araddr = addr;
      while (!s_arready) begin @(posedge clk); #1; end
      @(posedge clk); #1;
      s_arvalid = 1'b0;
      while (!s_rvalid) begin @(posedge clk); #1; end
      data = s_rdata;
      @(posedge clk); #1;
    end
  endtask

  // AXI-Lite 标准允许 AW/W 错拍：先发 AW 再发 W
  task axi_write_aw_first;
    input [31:0] addr;
    input [31:0] data;
    input [3:0]  strb;
    begin
      @(posedge clk); #1;
      s_awvalid = 1'b1; s_awaddr = addr;
      while (!s_awready) begin @(posedge clk); #1; end
      @(posedge clk); #1;
      s_awvalid = 1'b0;

      @(posedge clk); #1;
      s_wvalid  = 1'b1; s_wdata = data; s_wstrb = strb;
      while (!s_wready) begin @(posedge clk); #1; end
      @(posedge clk); #1;
      s_wvalid = 1'b0;

      while (!s_bvalid) begin @(posedge clk); #1; end
      @(posedge clk); #1;
    end
  endtask

  // AXI-Lite 标准允许 AW/W 错拍：先发 W 再发 AW
  task axi_write_w_first;
    input [31:0] addr;
    input [31:0] data;
    input [3:0]  strb;
    begin
      @(posedge clk); #1;
      s_wvalid  = 1'b1; s_wdata = data; s_wstrb = strb;
      while (!s_wready) begin @(posedge clk); #1; end
      @(posedge clk); #1;
      s_wvalid = 1'b0;

      @(posedge clk); #1;
      s_awvalid = 1'b1; s_awaddr = addr;
      while (!s_awready) begin @(posedge clk); #1; end
      @(posedge clk); #1;
      s_awvalid = 1'b0;

      while (!s_bvalid) begin @(posedge clk); #1; end
      @(posedge clk); #1;
    end
  endtask

  // ── 主测试序列 ────────────────────────────────────────────────────────────
  initial begin
    pass_cnt  = 0;
    fail_cnt  = 0;
    // AXI-Lite 空闲状态初始化
    s_awvalid = 1'b0; s_awaddr  = 32'h0;
    s_wvalid  = 1'b0; s_wdata   = 32'h0; s_wstrb  = 4'h0;
    s_bready  = 1'b1;  // 始终接受写响应
    s_arvalid = 1'b0; s_araddr  = 32'h0;
    s_rready  = 1'b1;  // 始终接受读数据

    // 复位序列
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    $display("[INFO] === AXI-Lite Bridge Smoke Test Start ===");
    $display("[INFO] ADDR_REG_BASE = 0x%08X", ADDR_REG_BASE);

    // ── T1: 写 reg[0]（offset 0x00），读回验证 ───────────────────────────
    axi_write(ADDR_REG_BASE + 32'h00, 32'hDEAD_BEEF, 4'hF);
    axi_read (ADDR_REG_BASE + 32'h00, rd_data);
    if (rd_data === 32'hDEAD_BEEF) begin
      $display("[PASS] T1 reg[0] write/readback : 0x%08X", rd_data);
      pass_cnt = pass_cnt + 1;
    end else begin
      $display("[FAIL] T1 reg[0] : got=0x%08X exp=0xDEADBEEF", rd_data);
      fail_cnt = fail_cnt + 1;
    end

    // ── T2: 写 reg[1]（offset 0x04），读回验证 ───────────────────────────
    axi_write(ADDR_REG_BASE + 32'h04, 32'hCAFE_1234, 4'hF);
    axi_read (ADDR_REG_BASE + 32'h04, rd_data);
    if (rd_data === 32'hCAFE_1234) begin
      $display("[PASS] T2 reg[1] write/readback : 0x%08X", rd_data);
      pass_cnt = pass_cnt + 1;
    end else begin
      $display("[FAIL] T2 reg[1] : got=0x%08X exp=0xCAFE1234", rd_data);
      fail_cnt = fail_cnt + 1;
    end

    // ── T3: 写 reg[4]（offset 0x10，类 THRESHOLD 地址），读回验证 ─────────
    axi_write(ADDR_REG_BASE + 32'h10, 32'h0000_27D8, 4'hF);  // 10200 = 0x27D8
    axi_read (ADDR_REG_BASE + 32'h10, rd_data);
    if (rd_data === 32'h0000_27D8) begin
      $display("[PASS] T3 reg[4] THRESHOLD addr : 0x%08X (=%0d)", rd_data, rd_data);
      pass_cnt = pass_cnt + 1;
    end else begin
      $display("[FAIL] T3 reg[4] : got=0x%08X exp=0x000027D8", rd_data);
      fail_cnt = fail_cnt + 1;
    end

    // ── T4: reg[0] 持久性（T2/T3 写入后 reg[0] 不受影响）────────────────
    axi_read(ADDR_REG_BASE + 32'h00, rd_data);
    if (rd_data === 32'hDEAD_BEEF) begin
      $display("[PASS] T4 reg[0] persistence    : 0x%08X", rd_data);
      pass_cnt = pass_cnt + 1;
    end else begin
      $display("[FAIL] T4 reg[0] persistence: got=0x%08X exp=0xDEADBEEF", rd_data);
      fail_cnt = fail_cnt + 1;
    end

    // ── T5: 字节写使能（wstrb=4'b0001，只改 byte0）──────────────────────
    // 先全写 0xFFFF_FFFF，再只写 byte0 = 0xAB
    axi_write(ADDR_REG_BASE + 32'h08, 32'hFFFF_FFFF, 4'hF);
    axi_write(ADDR_REG_BASE + 32'h08, 32'h0000_00AB, 4'b0001);
    axi_read (ADDR_REG_BASE + 32'h08, rd_data);
    if (rd_data === 32'hFFFF_FFAB) begin
      $display("[PASS] T5 byte-strobe wstrb=0001: 0x%08X", rd_data);
      pass_cnt = pass_cnt + 1;
    end else begin
      $display("[FAIL] T5 byte-strobe: got=0x%08X exp=0xFFFFFFAB", rd_data);
      fail_cnt = fail_cnt + 1;
    end

    // ── T6: AW/W 错拍（AW 先到）───────────────────────────────────────────
    axi_write_aw_first(ADDR_REG_BASE + 32'h0C, 32'h1234_5678, 4'hF);
    axi_read          (ADDR_REG_BASE + 32'h0C, rd_data);
    if (rd_data === 32'h1234_5678) begin
      $display("[PASS] T6 skew write (AW first) : 0x%08X", rd_data);
      pass_cnt = pass_cnt + 1;
    end else begin
      $display("[FAIL] T6 skew write (AW first): got=0x%08X exp=0x12345678", rd_data);
      fail_cnt = fail_cnt + 1;
    end

    // ── T7: AW/W 错拍（W 先到）────────────────────────────────────────────
    axi_write_w_first(ADDR_REG_BASE + 32'h14, 32'h89AB_CDEF, 4'hF);
    axi_read         (ADDR_REG_BASE + 32'h14, rd_data);
    if (rd_data === 32'h89AB_CDEF) begin
      $display("[PASS] T7 skew write (W first)  : 0x%08X", rd_data);
      pass_cnt = pass_cnt + 1;
    end else begin
      $display("[FAIL] T7 skew write (W first): got=0x%08X exp=0x89ABCDEF", rd_data);
      fail_cnt = fail_cnt + 1;
    end

    // ── 汇总 ─────────────────────────────────────────────────────────────
    $display("");
    $display("========== AXI Bridge Test Summary ==========");
    $display("PASS: %0d  FAIL: %0d", pass_cnt, fail_cnt);
    if (fail_cnt == 0)
      $display("AXI_BRIDGE_SMOKETEST_PASS");
    else
      $display("AXI_BRIDGE_SMOKETEST_FAIL");
    $display("=============================================");

    repeat (4) @(posedge clk);
    $finish;
  end

  // ── 超时 Watchdog ────────────────────────────────────────────────────────
  initial begin
    #500_000;
    $display("[ERROR] Timeout! Simulation hung - check FSM/handshake");
    $finish;
  end

endmodule
