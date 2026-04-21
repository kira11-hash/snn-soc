// -----------------------------------------------------------------------------
// multilayer_scan_ext_tb.sv — ADC 扩展扫描验证 TB
//
// 【为什么需要这个 TB？】
//   V2 改动之一是把 ADC 扫描从"固定 20 路"扩展成"可配最多 128 路"，
//   为后续 64→32→16→10 四层网络做准备（每层扫描的列数不同）。
//
//   但原有的 multilayer_tb.sv 两层都配 bl_cnt=20，相当于还是 V1 的 20 路，
//   根本没有验证"扩展扫描"这件事真的能工作。
//
//   Codex 审查 v2 的 D2-003 finding 指出这个覆盖盲区：
//   "MULTILAYER_SMOKE_PASS 只证明多层调度能跑 V1 路径，不能证明 bl_cnt>20 可用。"
//
//   本 TB 就是专门补这个覆盖点。
//
// 【测试思路】
//   1. 配置单层 + 扫描通道数 = 64 / 128
//   2. 启动一次推理
//   3. 全程观察 adc_ctrl 内部的 bl_sel 信号（层级引用）
//   4. 推理完成后检查 bl_sel 是否真的数到了 bl_cnt-1
//
//   为什么只查"bl_sel 是否数到"而不查差分结果？
//   - 当前行为模型（cim_macro_blackbox.sv）只有 20 列权重，
//     bl_sel > 20 时 MUX 返回 0，差分值没有意义
//   - 真正的差分验证留给 Phase V2.A 的 multilayer_sample_align_tb（用真实权重）
//   - 本 TB 的目标只是证明"硬件能跑到 bl_sel=127 不卡死"
//
// 【两个测试点】
//   T1：bl_cnt=64  → 预期 bl_sel 最大观察到 63（差分 half_count = 32）
//   T2：bl_cnt=128 → 预期 bl_sel 最大观察到 127（差分 half_count = 64）
//
// 【通过标准】
//   所有 assert 通过 + 没有 timeout → 打印 "MULTILAYER_SCAN_EXT_PASS"
//
// 【运行方法】
//   cd sim && bash run_multilayer_scan_ext.sh
//
// 【依赖】
//   +define+SIM_MULTI_LAYER（让 snn_soc_pkg 启用 ENABLE_MULTI_LAYER=1）
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
module multilayer_scan_ext_tb;
  import snn_soc_pkg::*;

  localparam [31:0] REG_THRESHOLD = ADDR_REG_BASE + 32'h00;
  localparam [31:0] REG_CIM_CTRL  = ADDR_REG_BASE + 32'h14;
  localparam [31:0] REG_OUT_COUNT = ADDR_REG_BASE + 32'h20;
  localparam [31:0] REG_CIM_TEST  = ADDR_REG_BASE + 32'h2C;
  localparam [31:0] REG_ML_CTRL   = ADDR_REG_BASE + 32'h48;
  localparam [31:0] DMA_SRC_ADDR  = ADDR_DMA_BASE + 32'h00;
  localparam [31:0] DMA_LEN_WORDS = ADDR_DMA_BASE + 32'h04;
  localparam [31:0] DMA_CTRL      = ADDR_DMA_BASE + 32'h08;
  localparam [31:0] DMA_DST_SEL   = ADDR_DMA_BASE + 32'h0C;

  logic clk, rst_n;
  initial clk = 0;
  always #5 clk = ~clk;

  logic uart_rx, uart_tx;
  logic spi_cs_n, spi_sck, spi_mosi, spi_miso;
  logic jtag_tck, jtag_tms, jtag_tdi, jtag_tdo;
  logic [7:0] wl_data_ext;
  logic [2:0] wl_group_sel_ext;
  logic       wl_latch_ext;
  logic       cim_start_ext;
  logic       cim_done_ext;
  logic [$clog2(snn_soc_pkg::MAX_BL_SCAN)-1:0] bl_sel_ext;
  logic [7:0] bl_data_ext;
  logic       prog_en_ext, erase_en_ext, verify_en_ext;

  integer error_count;
  reg [31:0] rd;
  integer timeout_cnt;

  assign uart_rx     = 1'b1;
  assign spi_miso    = 1'b0;
  assign jtag_tck    = 1'b0;
  assign jtag_tms    = 1'b0;
  assign jtag_tdi    = 1'b0;
  assign cim_done_ext = 1'b0;
  assign bl_data_ext  = 8'h0;

  snn_soc_top dut (.*);

  // ── bl_sel 最大值观察（层级引用 adc_ctrl 实例） ──
  logic [$clog2(snn_soc_pkg::MAX_BL_SCAN)-1:0] bl_sel_max_observed;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      bl_sel_max_observed <= '0;
    else if (dut.u_adc.bl_sel > bl_sel_max_observed)
      bl_sel_max_observed <= dut.u_adc.bl_sel;
  end

  task automatic bus_write;
    input [31:0] addr;
    input [31:0] data;
    begin
      @(negedge clk);
      dut.bus_if.m_valid = 1'b1;
      dut.bus_if.m_write = 1'b1;
      dut.bus_if.m_addr  = addr;
      dut.bus_if.m_wdata = data;
      dut.bus_if.m_wstrb = 4'hF;
      @(posedge clk); @(posedge clk);
      @(negedge clk);
      dut.bus_if.m_valid = 1'b0;
      dut.bus_if.m_write = 1'b0;
    end
  endtask

  task automatic bus_read;
    input  [31:0] addr;
    output [31:0] data;
    begin
      @(negedge clk);
      dut.bus_if.m_valid = 1'b1;
      dut.bus_if.m_write = 1'b0;
      dut.bus_if.m_addr  = addr;
      dut.bus_if.m_wstrb = 4'hF;
      @(posedge clk); @(posedge clk);
      data = dut.bus_if.m_rdata;
      @(negedge clk);
      dut.bus_if.m_valid = 1'b0;
    end
  endtask

  task automatic configure_single_layer;
    input integer bl_count;
    input integer neuron_count;
    begin
      // ML_CTRL: num_layers=0 (single layer), enable[8]=1
      bus_write(REG_ML_CTRL, 32'h0000_0100);

      // Layer 0: wl_off=0, wl_cnt=64, bl_off=0, bl_cnt=<parameter>
      bus_write(ADDR_REG_BASE + 32'h50, {bl_count[7:0], 8'd0, 8'd64, 8'd0});
      // Layer 0 timing: timesteps=2, use_bitplane=1
      bus_write(ADDR_REG_BASE + 32'h54, {23'd0, 1'b1, 8'd2});
      // Layer 0 threshold
      bus_write(ADDR_REG_BASE + 32'h58, 32'd2550);
      // Layer 0 neuron count
      bus_write(ADDR_REG_BASE + 32'h5C, neuron_count);
    end
  endtask

  task automatic run_one_inference;
    input integer dma_words;
    begin
      // Load DMA data (uniform pattern)
      for (integer i = 0; i < dma_words; i = i + 1) begin
        bus_write(32'h0001_0000 + i*4, 32'hFFFF_FFFF);
      end
      bus_write(DMA_SRC_ADDR,  32'h0001_0000);
      bus_write(DMA_DST_SEL,   32'h0000_0000);
      bus_write(DMA_LEN_WORDS, dma_words);
      bus_write(DMA_CTRL,      32'h0000_0001);

      rd = 0; timeout_cnt = 0;
      while (!rd[1] && timeout_cnt < 2000) begin
        bus_read(DMA_CTRL, rd);
        timeout_cnt = timeout_cnt + 1;
      end
      if (!rd[1]) begin $display("[FAIL] DMA timeout"); error_count = error_count + 1; end

      // Start inference
      bus_write(REG_CIM_CTRL, 32'h0000_0001);

      rd = 0; timeout_cnt = 0;
      while (!rd[7] && timeout_cnt < 40000) begin
        bus_read(REG_CIM_CTRL, rd);
        timeout_cnt = timeout_cnt + 1;
      end
      if (!rd[7]) begin
        $display("[FAIL] Inference timeout after %0d polls", timeout_cnt);
        error_count = error_count + 1;
      end
    end
  endtask

  task automatic clear_state;
    begin
      // Soft reset to clear membrane / FIFO / counters
      bus_write(REG_CIM_CTRL, 32'h0000_0082);  // SOFT_RESET=1 + DONE=1 (W1C)
      repeat (20) @(posedge clk);
    end
  endtask

  initial begin
    $dumpfile("waves/multilayer_scan_ext.vcd");
    $dumpvars(0, multilayer_scan_ext_tb);

    $display("[INFO] Multilayer scan-extension TB start");
    $display("[INFO] ENABLE_MULTI_LAYER=%0d MAX_BL_SCAN=%0d",
             ENABLE_MULTI_LAYER, MAX_BL_SCAN);

    if (ENABLE_MULTI_LAYER != 1) begin
      $display("[FAIL] ENABLE_MULTI_LAYER!=1, need +define+SIM_MULTI_LAYER");
      $finish;
    end

    error_count = 0;
    rst_n = 0;
    repeat (20) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    // Enable CIM test mode to bypass real weights
    bus_write(REG_CIM_TEST, 32'h0000_6401);

    // =====================================================================
    // T1: bl_cnt = 64
    // =====================================================================
    $display("----- T1: bl_cnt=64, expect bl_sel_max_observed = 63 -----");
    // D2-008: 清零 bl_sel_max_observed 时避开 posedge clk，防止与 always_ff 竞争
    @(negedge clk);
    bl_sel_max_observed = '0;
    configure_single_layer(64, 32);
    run_one_inference(160);
    $display("[T1] bl_sel_max_observed = %0d (expect 63)", bl_sel_max_observed);
    if (bl_sel_max_observed != 7'd63) begin
      $display("[FAIL] T1 bl_sel never reached 63");
      error_count = error_count + 1;
    end
    // D3-003 补强：验证差分逻辑在扩展扫描下仍然产生合理结果
    // test_mode 配置：pos=100（bl_sel<10）, neg=0（bl_sel>=10）
    // 期望 raw[0..9]=100, raw[10..63]=0
    // 对 bl_cnt=64, half=32：diff[i] = raw[i] - raw[i+32]
    //   i=5: 100 - 0 = 100（符合预期）
    //   i=15: 0 - 0 = 0（合理）
    if (int'(dut.u_adc.raw_data[5]) != 8'd100) begin
      $display("[FAIL] T1 raw_data[5]=%0d (expect 100, test_mode pos)", dut.u_adc.raw_data[5]);
      error_count = error_count + 1;
    end
    if (int'(dut.u_adc.raw_data[31]) != 8'd0) begin
      $display("[FAIL] T1 raw_data[31]=%0d (expect 0, test_mode neg)", dut.u_adc.raw_data[31]);
      error_count = error_count + 1;
    end
    clear_state();

    // =====================================================================
    // T2: bl_cnt = 128
    // =====================================================================
    $display("----- T2: bl_cnt=128, expect bl_sel_max_observed = 127 -----");
    @(negedge clk);
    bl_sel_max_observed = '0;
    configure_single_layer(128, 64);
    run_one_inference(160);
    $display("[T2] bl_sel_max_observed = %0d (expect 127)", bl_sel_max_observed);
    if (bl_sel_max_observed != 7'd127) begin
      $display("[FAIL] T2 bl_sel never reached 127");
      error_count = error_count + 1;
    end
    // D3-003 补强：bl_cnt=128 时 raw_data 高索引（>= 64）被更新证据
    //   raw[63] 和 raw[127] 都应存在，test_mode 下都是 neg=0
    if (int'(dut.u_adc.raw_data[63]) != 8'd0) begin
      $display("[FAIL] T2 raw_data[63]=%0d (expect 0)", dut.u_adc.raw_data[63]);
      error_count = error_count + 1;
    end
    if (int'(dut.u_adc.raw_data[127]) != 8'd0) begin
      $display("[FAIL] T2 raw_data[127]=%0d (expect 0)", dut.u_adc.raw_data[127]);
      error_count = error_count + 1;
    end
    // 同时验证 neuron_in_data_wide 的差分路径确实被驱动
    // 对 bl_cnt=128, half=64，diff[5] = raw[5] - raw[69]
    //   raw[5]=100（pos 列），raw[69]=0（neg 列），diff=100 = 9'b0_0110_0100
    if ($signed(dut.u_adc.neuron_in_data_wide[5]) != 9'sd100) begin
      $display("[FAIL] T2 neuron_in_data_wide[5]=%0d (expect 100)",
               $signed(dut.u_adc.neuron_in_data_wide[5]));
      error_count = error_count + 1;
    end

    // =====================================================================
    // Final result
    // =====================================================================
    if (error_count == 0) begin
      $display("MULTILAYER_SCAN_EXT_PASS");
    end else begin
      $display("[FAIL] MULTILAYER_SCAN_EXT_FAIL errors=%0d", error_count);
    end

    repeat (10) @(posedge clk);
    $finish;
  end

  initial begin
    #200_000_000;
    $display("[FAIL] Global timeout at 200ms");
    $finish;
  end

endmodule
