`timescale 1ns/1ps

// =============================================================================
// Step 3.4: Python↔RTL 数值对齐 TB
//
// 功能：加载正式样本集的 bit-plane hex，逐个跑 RTL 推理，
//       自动对比 RTL 输出类别与 Python 预测类别，报告 PASS/FAIL。
//
// 输入文件（由 export_expected_spike_ids.py 生成，放在仿真运行目录）：
//   - all_samples.hex       : N×80 行 64-bit hex，所有样本 bit-plane 合并
//   - expected_classes.hex  : N 行，每行一个 Python predicted_class（用于 RTL 等价性对齐）
//
// 正式默认口径：100 样本（MNIST test split，每类前 10 个，class-major 顺序）
// 调试口径：可通过 +SAMPLE_COUNT=<n> 只跑前 n 个样本
// 通过标准：100/100 样本匹配时输出 SAMPLE_ALIGN_PASS
// =============================================================================

module top_tb_sample_align;
  import snn_soc_pkg::*;

  // ── 样本参数 ──
  localparam int DEFAULT_SAMPLE_COUNT = 100;
  localparam int MAX_SAMPLE_COUNT     = 256;
  localparam int PLANES_PER_SAMPLE    = TIMESTEPS_DEFAULT * PIXEL_BITS;       // 10 * 8 = 80
  localparam int TOTAL_PLANES_MAX     = MAX_SAMPLE_COUNT * PLANES_PER_SAMPLE; // 256 * 80

  // ── 寄存器地址 ──
  localparam [31:0] REG_THRESHOLD = ADDR_REG_BASE + 32'h00;
  localparam [31:0] REG_TIMESTEPS = ADDR_REG_BASE + 32'h04;
  localparam [31:0] REG_CIM_CTRL  = ADDR_REG_BASE + 32'h14;
  localparam [31:0] REG_OUT_DATA  = ADDR_REG_BASE + 32'h1C;
  localparam [31:0] REG_OUT_COUNT = ADDR_REG_BASE + 32'h20;
  localparam [31:0] REG_CIM_TEST  = ADDR_REG_BASE + 32'h2C;

  localparam [31:0] DMA_SRC_ADDR  = ADDR_DMA_BASE + 32'h00;
  localparam [31:0] DMA_LEN_WORDS = ADDR_DMA_BASE + 32'h04;
  localparam [31:0] DMA_CTRL      = ADDR_DMA_BASE + 32'h08;

  // ── 时钟与复位 ──
  logic clk;
  logic rst_n;

  // ── 外设端口（空置） ──
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
  logic [2:0] prog_op_ext;      // V1 external programming (2026-04-24)
  logic [3:0] prog_level_ext;

  /* verilator lint_off UNUSEDSIGNAL */
  logic        ext_bus_enable;
  logic        ext_bus_m_valid;
  logic        ext_bus_m_write;
  logic [31:0] ext_bus_m_addr;
  logic [31:0] ext_bus_m_wdata;
  logic [3:0]  ext_bus_m_wstrb;
  logic        ext_bus_m_ready;
  logic [31:0] ext_bus_m_rdata;
  logic        ext_bus_m_rvalid;
  /* verilator lint_on UNUSEDSIGNAL */

  // ── 控制变量 ──
  integer error_count;
  integer sample_errors;
  integer poll_i;
  integer plane_i;
  integer spike_i;
  integer sample_i;
  integer sample_count;
  integer out_fifo_count;
  integer threshold_cfg;
  reg [31:0] rd;
  reg dma_done_seen;
  reg cim_done_seen;
  reg [63:0] plane_vec;

  // ── spike 统计（每样本 10 个 neuron 的计数） ──
  integer spike_histogram [0:NUM_OUTPUTS-1];
  integer rtl_predicted;
  integer max_spikes;
  integer neuron_j;

  // ── 预加载数据 ──
  reg [63:0] all_planes [0:TOTAL_PLANES_MAX-1];
  // expected_classes 存的是 Python predicted_class，不是真实标签。
  reg [3:0]  expected_classes [0:MAX_SAMPLE_COUNT-1];

  // ── DUT 实例化 ──
  snn_soc_top dut (.*);

  // ── 总线读写 task ──
  /* verilator lint_off UNUSEDSIGNAL */
  task automatic bus_write;
    input [31:0] addr;
    input [31:0] data;
    input [3:0]  wstrb;
    begin
      @(negedge clk);
      dut.bus_if.m_valid = 1'b1;
      dut.bus_if.m_write = 1'b1;
      dut.bus_if.m_addr  = addr;
      dut.bus_if.m_wdata = data;
      dut.bus_if.m_wstrb = wstrb;

      @(posedge clk);
      @(posedge clk);
      if (dut.bus_if.m_ready !== 1'b1) begin
        $display("[ERR] bus_write timeout addr=0x%08h data=0x%08h", addr, data);
        error_count = error_count + 1;
      end

      @(negedge clk);
      dut.bus_if.m_valid = 1'b0;
      dut.bus_if.m_write = 1'b0;
      dut.bus_if.m_addr  = 32'h0;
      dut.bus_if.m_wdata = 32'h0;
      dut.bus_if.m_wstrb = 4'h0;
    end
  endtask

  task automatic bus_read;
    input [31:0] addr;
    output [31:0] data;
    begin
      @(negedge clk);
      dut.bus_if.m_valid = 1'b1;
      dut.bus_if.m_write = 1'b0;
      dut.bus_if.m_addr  = addr;
      dut.bus_if.m_wdata = 32'h0;
      dut.bus_if.m_wstrb = 4'h0;

      @(posedge clk);
      @(posedge clk);
      data = dut.bus_if.m_rdata;
      if (dut.bus_if.m_rvalid !== 1'b1) begin
        $display("[ERR] bus_read timeout addr=0x%08h", addr);
        error_count = error_count + 1;
      end

      @(negedge clk);
      dut.bus_if.m_valid = 1'b0;
      dut.bus_if.m_write = 1'b0;
      dut.bus_if.m_addr  = 32'h0;
      dut.bus_if.m_wdata = 32'h0;
      dut.bus_if.m_wstrb = 4'h0;
    end
  endtask
  /* verilator lint_on UNUSEDSIGNAL */

  // ── 时钟（50MHz = 20ns 周期） ──
  initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
  end

  // ── 复位 ──
  initial begin
    rst_n = 1'b0;
    uart_rx = 1'b1;
    spi_miso = 1'b0;
    cim_done_ext = 1'b0;
    bl_data_ext = 8'h00;
    jtag_tck = 1'b0;
    jtag_tms = 1'b0;
    jtag_tdi = 1'b0;
    ext_bus_enable  = 1'b0;
    ext_bus_m_valid = 1'b0;
    ext_bus_m_write = 1'b0;
    ext_bus_m_addr  = 32'h0;
    ext_bus_m_wdata = 32'h0;
    ext_bus_m_wstrb = 4'h0;

    dut.bus_if.m_valid = 1'b0;
    dut.bus_if.m_write = 1'b0;
    dut.bus_if.m_addr  = 32'h0;
    dut.bus_if.m_wdata = 32'h0;
    dut.bus_if.m_wstrb = 4'h0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end

  // ── 波形 ──
`ifdef VCS
  initial begin
    $fsdbDumpfile("waves/snn_soc_sample_align.fsdb");
    $fsdbDumpvars(0, top_tb_sample_align);
  end
`else
  initial begin
    $dumpfile("waves/sample_align.vcd");
    $dumpvars(0, top_tb_sample_align);
  end
`endif

  // ── 加载预生成数据 ──
  initial begin
    $readmemh("all_samples.hex", all_planes);
    $readmemh("expected_classes.hex", expected_classes);
  end

  // ── 主测试流程 ──
  initial begin
    error_count = 0;
    sample_errors = 0;
    sample_count = DEFAULT_SAMPLE_COUNT;
    threshold_cfg = THRESHOLD_RATIO_DEFAULT * ((1 << PIXEL_BITS) - 1) * TIMESTEPS_DEFAULT;

    if ($value$plusargs("SAMPLE_COUNT=%d", sample_count)) begin
      if (sample_count <= 0) sample_count = DEFAULT_SAMPLE_COUNT;
      if (sample_count > MAX_SAMPLE_COUNT) begin
        $display("[WARN] SAMPLE_COUNT=%0d exceeds MAX_SAMPLE_COUNT=%0d, clamp to max",
                 sample_count, MAX_SAMPLE_COUNT);
        sample_count = MAX_SAMPLE_COUNT;
      end
    end

    wait (rst_n === 1'b1);
    repeat (2) @(posedge clk);

    $display("=============================================================");
    $display("[ALIGN] Step 3.4 Sample Alignment TB Start");
    $display("[ALIGN] SAMPLES=%0d TIMESTEPS=%0d THRESHOLD=%0d",
             sample_count, TIMESTEPS_DEFAULT, threshold_cfg);
    $display("=============================================================");

    // ── 全局配置（只需设一次） ──
    bus_write(REG_TIMESTEPS, TIMESTEPS_DEFAULT, 4'h1);
    bus_write(REG_THRESHOLD, threshold_cfg, 4'hF);
    bus_write(REG_CIM_TEST, 32'h0000_0000, 4'hF);  // test_mode=0，使用真实权重

    // ── 逐样本推理 ──
    for (sample_i = 0; sample_i < sample_count; sample_i = sample_i + 1) begin

      $display("-------------------------------------------------------------");
      $display("[ALIGN] Sample %0d: expected_python_class=%0d",
               sample_i, expected_classes[sample_i]);

      // ── 1) 软复位 + 清除 sticky flags ──
      // CIM_CTRL: bit[7]=DONE W1C + bit[1]=SOFT_RESET W1P
      bus_write(REG_CIM_CTRL, 32'h0000_0082, 4'h1);
      // DMA_CTRL: bit[1]=DONE W1C
      bus_write(DMA_CTRL, 32'h0000_0002, 4'h1);
      repeat (4) @(posedge clk);  // 等待 soft reset 生效

      // ── 2) 写 bit-plane 数据到 data SRAM ──
      for (plane_i = 0; plane_i < PLANES_PER_SAMPLE; plane_i = plane_i + 1) begin
        plane_vec = all_planes[sample_i * PLANES_PER_SAMPLE + plane_i];
        bus_write(ADDR_DATA_BASE + (plane_i * 8),     plane_vec[31:0],  4'hF);
        bus_write(ADDR_DATA_BASE + (plane_i * 8) + 4, plane_vec[63:32], 4'hF);
      end

      // ── 3) 启动 DMA 传输 ──
      bus_write(DMA_SRC_ADDR, ADDR_DATA_BASE, 4'hF);
      bus_write(DMA_LEN_WORDS, PLANES_PER_SAMPLE * 2, 4'hF);  // 80*2=160 words
      bus_write(DMA_CTRL, 32'h0000_0001, 4'h1);  // START

      // ── 4) 等待 DMA 完成 ──
      dma_done_seen = 1'b0;
      begin : dma_poll
        for (poll_i = 0; poll_i < 5000; poll_i = poll_i + 1) begin
          bus_read(DMA_CTRL, rd);
          if (rd[1]) begin
            dma_done_seen = 1'b1;
            disable dma_poll;
          end
        end
      end
      if (!dma_done_seen) begin
        $display("[ERR] Sample %0d: DMA done timeout", sample_i);
        error_count = error_count + 1;
      end

      // ── 5) 启动 CIM 推理 ──
      bus_write(REG_CIM_CTRL, 32'h0000_0001, 4'h1);  // START

      // ── 6) 等待 CIM 完成 ──
      cim_done_seen = 1'b0;
      begin : cim_poll
        for (poll_i = 0; poll_i < 200000; poll_i = poll_i + 1) begin
          bus_read(REG_CIM_CTRL, rd);
          if (rd[7]) begin
            cim_done_seen = 1'b1;
            disable cim_poll;
          end
        end
      end
      if (!cim_done_seen) begin
        $display("[ERR] Sample %0d: CIM done timeout", sample_i);
        error_count = error_count + 1;
      end

      // ── 7) 读取 output FIFO：spike 统计 ──
      bus_read(REG_OUT_COUNT, rd);
      out_fifo_count = rd;
      $display("[ALIGN] Sample %0d: OUT_FIFO_COUNT=%0d", sample_i, out_fifo_count);

      // 清零 spike 直方图
      for (neuron_j = 0; neuron_j < NUM_OUTPUTS; neuron_j = neuron_j + 1) begin
        spike_histogram[neuron_j] = 0;
      end

      // 逐个读取 spike 并统计
      for (spike_i = 0; spike_i < out_fifo_count; spike_i = spike_i + 1) begin
        bus_read(REG_OUT_DATA, rd);
        if (rd[3:0] < NUM_OUTPUTS) begin
          spike_histogram[rd[3:0]] = spike_histogram[rd[3:0]] + 1;
        end
      end

      // 打印 spike 直方图
      $write("[ALIGN] Sample %0d: spikes=[", sample_i);
      for (neuron_j = 0; neuron_j < NUM_OUTPUTS; neuron_j = neuron_j + 1) begin
        if (neuron_j > 0) $write(", ");
        $write("%0d", spike_histogram[neuron_j]);
      end
      $display("]");

      // ── 8) 计算 argmax（RTL predicted class） ──
      rtl_predicted = 0;
      max_spikes = spike_histogram[0];
      for (neuron_j = 1; neuron_j < NUM_OUTPUTS; neuron_j = neuron_j + 1) begin
        if (spike_histogram[neuron_j] > max_spikes) begin
          max_spikes = spike_histogram[neuron_j];
          rtl_predicted = neuron_j;
        end
      end

      // ── 9) 对比 ──
      if (rtl_predicted == expected_classes[sample_i]) begin
        $display("[ALIGN] Sample %0d: PASS (predicted=%0d expected=%0d)",
                 sample_i, rtl_predicted, expected_classes[sample_i]);
      end else begin
        $display("[ALIGN] Sample %0d: FAIL (predicted=%0d expected=%0d)",
                 sample_i, rtl_predicted, expected_classes[sample_i]);
        sample_errors = sample_errors + 1;
      end
    end

    // ── 最终报告 ──
    $display("=============================================================");
    if (sample_errors == 0 && error_count == 0) begin
      $display("SAMPLE_ALIGN_PASS (%0d/%0d samples matched)",
               sample_count, sample_count);
    end else begin
      $display("SAMPLE_ALIGN_FAIL (matched=%0d/%0d, bus_errors=%0d)",
               sample_count - sample_errors, sample_count, error_count);
    end
    $display("=============================================================");

    repeat (10) @(posedge clk);
    $finish;
  end

  wire _unused_tb = uart_tx ^ spi_cs_n ^ spi_sck ^ spi_mosi ^ jtag_tdo;

  // TB-C-01 fix（2026-05-02 audit）：global watchdog，超时打 FAIL marker。
  // sample_align 是开闸点（doc/09 §4.4），100 sample × ~500us = ~50 ms sim time。
  // 给 100 ms 余量，让真 RTL livelock 能在 1 minute 内退出 + CI 报错。
  initial begin
    #100_000_000;  // 100 ms sim time
    $display("[FAIL] SAMPLE_ALIGN global timeout (100ms sim)");
    $display("SAMPLE_ALIGN_FAIL (global timeout)");
    $finish;
  end
endmodule
