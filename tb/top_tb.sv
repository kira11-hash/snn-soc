`timescale 1ns/1ps
//======================================================================
// 文件名: top_tb.sv
// 描述: SNN SoC 顶层 Testbench。
//       完整流程：配置寄存器 -> 写入 data_sram -> DMA -> 推理 -> 读取输出。
//       生成 FSDB 波形供 Verdi 使用。
//======================================================================
module top_tb;
  import snn_soc_pkg::*;
  import tb_bus_pkg::*;

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

  // 时钟
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
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

  // FSDB 波形
  initial begin
    $fsdbDumpfile("waves/snn_soc.fsdb");
    $fsdbDumpvars(0, top_tb);
  end

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
    logic [NUM_INPUTS-1:0] wl_vec [0:4];

    // 预置 5 个 timestep 的输入图案（7x7）
    wl_vec[0] = 49'b0000000_0011100_0011100_1111111_0011100_0011100_0000000;
    wl_vec[1] = 49'b1000001_0100010_0010100_0001000_0010100_0100010_1000001;
    wl_vec[2] = 49'b1000000_0100000_0010000_0001000_0000100_0000010_0000001;
    wl_vec[3] = 49'b1010101_0101010_1010101_0101010_1010101_0101010_1010101;
    wl_vec[4] = 49'b1111111_1000001_1000001_1000001_1000001_1000001_1111111;

    // 等待复位释放
    wait (rst_n == 1'b1);
    @(posedge clk);

    // 1) 配置阈值与时步
    bus_write32(bus_vif, 32'h4000_0000, 32'd200, 4'h3); // THRESHOLD
    bus_write32(bus_vif, 32'h4000_0004, 32'd5,   4'h1); // TIMESTEPS

    // 2) 写入 data_sram（按 DMA 打包格式：2 word / timestep）
    for (int t = 0; t < 5; t = t + 1) begin
      word0 = wl_vec[t][31:0];
      word1 = {15'h0, wl_vec[t][48:32]};
      bus_write32(bus_vif, 32'h0001_0000 + t*8,     word0, 4'hF);
      bus_write32(bus_vif, 32'h0001_0000 + t*8 + 4, word1, 4'hF);
    end

    // 3) 启动 DMA
    bus_write32(bus_vif, 32'h4000_0100, 32'h0001_0000, 4'hF); // DMA_SRC_ADDR
    bus_write32(bus_vif, 32'h4000_0104, 32'd10,        4'hF); // DMA_LEN_WORDS
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
