`timescale 1ns/1ps
//======================================================================
// 文件名: top_tb.sv
// 描述: SNN SoC 顶层 Testbench。
//       完整流程：配置寄存器 -> 写入 data_sram -> DMA -> 推理 -> 读取输出。
//       生成 FSDB 波形供 Verdi 使用。
//       适配 V1 参数：NUM_INPUTS=64, ADC_BITS=8, T=1, Scheme B。
//======================================================================
module top_tb;
  import snn_soc_pkg::*;
  import tb_bus_pkg::*;

  localparam int BITPLANE_W = $clog2(PIXEL_BITS);
  localparam logic [BITPLANE_W-1:0] BITPLANE_MAX = BITPLANE_W'(PIXEL_BITS-1);

  logic clk;
  logic rst_n;

  // stub 端口
  logic uart_rx;
  logic uart_tx;
  logic spi_cs_n;
  logic spi_sck;
  logic spi_mosi;
  logic spi_miso;
  logic jtag_tck;
  logic jtag_tms;
  logic jtag_tdi;
  logic jtag_tdo;

  snn_soc_top dut (
    .clk      (clk),
    .rst_n    (rst_n),
    .uart_rx  (uart_rx),
    .uart_tx  (uart_tx),
    .spi_cs_n (spi_cs_n),
    .spi_sck  (spi_sck),
    .spi_mosi (spi_mosi),
    .spi_miso (spi_miso),
    .jtag_tck (jtag_tck),
    .jtag_tms (jtag_tms),
    .jtag_tdi (jtag_tdi),
    .jtag_tdo (jtag_tdo)
  );

  // 时钟：50MHz（周期20ns）
  initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;  // 半周期10ns -> 完整周期20ns = 50MHz
  end

  // 复位
  initial begin
    rst_n   = 1'b0;
    uart_rx = 1'b1;
    spi_miso= 1'b0;
    jtag_tck= 1'b0;
    jtag_tms= 1'b0;
    jtag_tdi= 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end

  // 标记未使用的 stub 输出，避免 lint 报警
  wire _unused_tb = uart_tx ^ spi_cs_n ^ spi_sck ^ spi_mosi ^ jtag_tdo;

  // FSDB 波形（仅 VCS/Verdi 使用；Verilator 下屏蔽）
`ifndef VERILATOR
  initial begin
    $fsdbDumpfile("waves/snn_soc.fsdb");
    $fsdbDumpvars(0, top_tb);
  end
`endif

  // 监控 ADC 输出（用于 Smoke Test 验证）
  initial begin
    fork
      // 监控 bl_sel 变化
      forever begin
        @(posedge clk);
        if (dut.u_adc.state != 0) begin  // 不在 IDLE 状态时
          $display("[%0t] ADC: state=%0d, bl_sel=%0d, neuron_in_valid=%0b, bitplane_shift=%0d",
                   $time, dut.u_adc.state, dut.u_adc.bl_sel, dut.u_adc.neuron_in_valid, dut.u_cim_ctrl.bitplane_shift);
        end
      end

      // 监控 neuron_in_data 输出（Scheme B 有符号差分）
      forever begin
        @(posedge clk);
        if (dut.u_adc.neuron_in_valid) begin
          $display("========================================");
          $display("[%0t] ADC Output Valid! neuron_in_data (signed diff):", $time);
          for (int i = 0; i < NUM_OUTPUTS; i++) begin
            $display("  [%0d] = %0d (9'h%03X)",
                     i, $signed(dut.u_adc.neuron_in_data[i]), dut.u_adc.neuron_in_data[i]);
          end
          $display("========================================");
        end
      end
    join_none
  end

`ifndef SYNTHESIS
  // 关键断言：有效拍输出不应包含 X，bitplane_shift 应合法
  /* verilator lint_off SYNCASYNCNET */
  always @(posedge clk) begin
    if (rst_n) begin
      /* verilator lint_off CMPCONST */
      assert (dut.u_cim_ctrl.bitplane_shift <= BITPLANE_MAX)
        else $fatal(1, "[TB] bitplane_shift 越界: %0d", dut.u_cim_ctrl.bitplane_shift);
      /* verilator lint_on CMPCONST */
      if (dut.u_adc.neuron_in_valid) begin
        for (int i = 0; i < NUM_OUTPUTS; i++) begin
          assert (!$isunknown(dut.u_adc.neuron_in_data[i]))
            else $error("[TB] neuron_in_data[%0d] 含 X", i);
        end
      end
    end
  end
  /* verilator lint_on SYNCASYNCNET */
`endif

  // bus 虚接口句柄
  virtual bus_simple_if bus_vif;

  initial begin
    bus_vif = dut.bus_if;
    bus_vif.m_valid = 1'b0;
    bus_vif.m_write = 1'b0;
    bus_vif.m_addr  = 32'h0;
    bus_vif.m_wdata = 32'h0;
    bus_vif.m_wstrb = 4'h0;
  end

  // 测试流程
  initial begin
    logic [31:0] rd;
    logic [31:0] word0;
    logic [31:0] word1;
    logic [NUM_INPUTS-1:0] wl_vec [0:1];
    logic [7:0] pixel_val [0:1][0:NUM_INPUTS-1];
    logic [7:0] frame_amp [0:1];
    int frames = 1;  // V1 默认 T=1
    int write_idx;
    logic [NUM_INPUTS-1:0] plane_vec;

    // 8x8 patterns (used to build 8-bit pixels)
    // Pattern 0: 中心十字（8x8）
    wl_vec[0] = 64'b00000000_00011000_00011000_01111110_01111110_00011000_00011000_00000000;
    // Pattern 1: 对角线 X（备用，frames=1 时不使用）
    wl_vec[1] = 64'b10000001_01000010_00100100_00011000_00011000_00100100_01000010_10000001;

    // Per-frame amplitude (8-bit)
    frame_amp[0] = 8'hFF; // all bits set
    frame_amp[1] = 8'h80; // MSB only

    for (int t = 0; t < 2; t = t + 1) begin
      for (int p = 0; p < NUM_INPUTS; p = p + 1) begin
        pixel_val[t][p] = wl_vec[t][p] ? frame_amp[t] : 8'h00;
      end
    end

    // 等待复位释放
    wait (rst_n == 1'b1);
    @(posedge clk);

    // 1) 配置阈值与时步
    bus_write32(bus_vif, 32'h4000_0000, THRESHOLD_DEFAULT, 4'hF); // THRESHOLD
    bus_write32(bus_vif, 32'h4000_0004, frames,   4'h1); // TIMESTEPS

    // 读回 THRESHOLD_RATIO 验证默认值
    bus_read32(bus_vif, 32'h4000_0024, rd);
    $display("[TB] THRESHOLD_RATIO = %0d (expected %0d)", rd[7:0], THRESHOLD_RATIO_DEFAULT);

    // 2) Write data_sram as bit-planes (MSB->LSB). Each plane is 64 bits = 2 words.
    write_idx = 0;
    for (int t = 0; t < frames; t = t + 1) begin
      for (int b = PIXEL_BITS-1; b >= 0; b = b - 1) begin
        for (int p = 0; p < NUM_INPUTS; p = p + 1) begin
          plane_vec[p] = pixel_val[t][p][b];
        end
        word0 = plane_vec[31:0];
        word1 = plane_vec[63:32];
        bus_write32(bus_vif, 32'h0001_0000 + write_idx*8,     word0, 4'hF);
        bus_write32(bus_vif, 32'h0001_0000 + write_idx*8 + 4, word1, 4'hF);
        write_idx++;
      end
    end

    // 3) Start DMA
    bus_write32(bus_vif, 32'h4000_0100, 32'h0001_0000, 4'hF); // DMA_SRC_ADDR
    bus_write32(bus_vif, 32'h4000_0104, frames*PIXEL_BITS*2, 4'hF); // DMA_LEN_WORDS = frames*PIXEL_BITS*2
    bus_write32(bus_vif, 32'h4000_0108, 32'h1,         4'h1); // DMA_CTRL.START

    // 轮询 DMA DONE
    do begin
      bus_read32(bus_vif, 32'h4000_0108, rd);
    end while (rd[1] == 1'b0);

    // 4) 启动 CIM 推理
    bus_write32(bus_vif, 32'h4000_0014, 32'h1, 4'h1); // CIM_CTRL.START

    // 轮询 CIM DONE（bit7）
    do begin
      bus_read32(bus_vif, 32'h4000_0014, rd);
    end while (rd[7] == 1'b0);

    // 4b) 读取 ADC 饱和计数（诊断）
    bus_read32(bus_vif, 32'h4000_0028, rd);
    $display("[TB] ADC_SAT_COUNT = 0x%08X (sat_high=%0d, sat_low=%0d)",
             rd, rd[15:0], rd[31:16]);

    // 4c) 读取 Debug 计数器
    bus_read32(bus_vif, 32'h4000_0030, rd); // DBG_CNT_0
    $display("[TB] DBG_CNT_0 = 0x%08X (dma_frame=%0d, cim_cycle=%0d)",
             rd, rd[15:0], rd[31:16]);
    bus_read32(bus_vif, 32'h4000_0034, rd); // DBG_CNT_1
    $display("[TB] DBG_CNT_1 = 0x%08X (spike=%0d, wl_stall=%0d)",
             rd, rd[15:0], rd[31:16]);

    // 4d) 读取 CIM_TEST 寄存器（默认值应为 0）
    bus_read32(bus_vif, 32'h4000_002C, rd);
    $display("[TB] CIM_TEST = 0x%08X (test_mode=%0b, test_data=0x%02X)",
             rd, rd[0], rd[15:8]);

    // 5) 读取 output_fifo
    bus_read32(bus_vif, 32'h4000_0020, rd); // OUT_FIFO_COUNT
    $display("[TB] OUT_FIFO_COUNT = %0d", rd);

    for (int k = 0; k < rd; k = k + 1) begin
      bus_read32(bus_vif, 32'h4000_001C, word0); // OUT_FIFO_DATA
      $display("[TB] spike_id[%0d] = %0d", k, word0[3:0]);
    end

    // 结束仿真
    #100;
    $display("[TB] Simulation finished.");
    $finish;
  end
endmodule
