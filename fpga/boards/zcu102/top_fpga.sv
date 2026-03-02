`timescale 1ns/1ps
//======================================================================
// 文件名: top_fpga.sv
// 描述: ZCU102 板级顶层 wrapper
//
// 功能:
//   1. 时钟生成: 板载差分时钟 → MMCM → 50MHz 系统时钟
//   2. 复位同步: 异步按钮复位 → 2-FF 同步器
//   3. SoC 实例化: snn_soc_top（核心数字逻辑，不改）
//   4. LED 状态指示: busy/done/heartbeat
//   5. UART 引出至 PMOD
//
// 注意: 此文件仅在 FPGA 分支使用，不影响 ASIC 主线 RTL
//======================================================================
module top_fpga (
  // ZCU102 板载差分时钟 (USER_SI570, 300MHz default)
  input  logic sys_clk_p,
  input  logic sys_clk_n,

  // 按钮复位 (GPIO_SW_C, active-high on ZCU102)
  input  logic btn_rst,

  // UART (via PMOD J55 or USB-UART bridge)
  input  logic uart_rxd,
  output logic uart_txd,

  // LED status indicators (active-high on ZCU102)
  output logic [3:0] led,

  // SPI (optional, via PMOD)
  output logic spi_cs_n,
  output logic spi_sck,
  output logic spi_mosi,
  input  logic spi_miso
);

  // -----------------------------------------------------------------------
  // Clock generation: MMCM (300MHz diff → 50MHz single-ended)
  // For Vivado: use Clocking Wizard IP or MMCME4_ADV primitive
  // This is a simple behavioral model; replace with IP in actual build
  // -----------------------------------------------------------------------
  logic sys_clk_ibuf;
  logic clk_50m;
  logic mmcm_locked;

  // Differential input buffer
  IBUFDS #(
    .DIFF_TERM ("TRUE"),
    .IBUF_LOW_PWR ("FALSE")
  ) u_ibufds (
    .O  (sys_clk_ibuf),
    .I  (sys_clk_p),
    .IB (sys_clk_n)
  );

  // MMCM: 300MHz → 50MHz (multiply by 10, divide by 60)
  // In practice, use Vivado Clocking Wizard IP
  // For now, instantiate MMCME4_ADV with specific parameters
  logic clk_mmcm_out;
  logic clk_fb;

  MMCME4_ADV #(
    .CLKIN1_PERIOD    (3.333),    // 300 MHz = 3.333 ns
    .CLKFBOUT_MULT_F  (4.0),     // VCO = 300 × 4 = 1200 MHz
    .CLKOUT0_DIVIDE_F (24.0),    // 1200 / 24 = 50 MHz
    .DIVCLK_DIVIDE    (1)
  ) u_mmcm (
    .CLKIN1     (sys_clk_ibuf),
    .CLKIN2     (1'b0),
    .CLKINSEL   (1'b1),
    .CLKFBIN    (clk_fb),
    .CLKFBOUT   (clk_fb),
    .CLKOUT0    (clk_mmcm_out),
    .LOCKED     (mmcm_locked),
    .PWRDWN     (1'b0),
    .RST        (btn_rst),
    // Unused outputs
    .CLKOUT1    (),
    .CLKOUT2    (),
    .CLKOUT3    (),
    .CLKOUT4    (),
    .CLKOUT5    (),
    .CLKOUT6    (),
    .CLKFBOUTB  (),
    .CLKOUT0B   (),
    .CLKOUT1B   (),
    .CLKOUT2B   (),
    .CLKOUT3B   (),
    // Dynamic reconfiguration (unused)
    .DADDR      (7'd0),
    .DCLK       (1'b0),
    .DEN        (1'b0),
    .DWE        (1'b0),
    .DI         (16'd0),
    .DO         (),
    .DRDY       (),
    // Phase shift (unused)
    .PSCLK      (1'b0),
    .PSEN       (1'b0),
    .PSINCDEC   (1'b0),
    .PSDONE     (),
    .CDDCREQ    (1'b0),
    .CDDCDONE   (),
    .CLKINSTOPPED (),
    .CLKFBSTOPPED ()
  );

  // Global clock buffer
  BUFG u_bufg (
    .O (clk_50m),
    .I (clk_mmcm_out)
  );

  // -----------------------------------------------------------------------
  // Reset synchronizer (async assert, sync release)
  // btn_rst is active-high on ZCU102; we need active-low rst_n
  // Also wait for MMCM lock
  // -----------------------------------------------------------------------
  logic rst_n_raw;
  logic [1:0] rst_sync;

  assign rst_n_raw = mmcm_locked & ~btn_rst;

  always_ff @(posedge clk_50m or negedge rst_n_raw) begin
    if (!rst_n_raw) begin
      rst_sync <= 2'b00;
    end else begin
      rst_sync <= {rst_sync[0], 1'b1};
    end
  end

  logic rst_n;
  assign rst_n = rst_sync[1];

  // -----------------------------------------------------------------------
  // SNN SoC core instantiation
  // -----------------------------------------------------------------------
  logic soc_uart_tx;

  snn_soc_top u_soc (
    .clk      (clk_50m),
    .rst_n    (rst_n),
    .uart_rx  (uart_rxd),
    .uart_tx  (soc_uart_tx),
    .spi_cs_n (spi_cs_n),
    .spi_sck  (spi_sck),
    .spi_mosi (spi_mosi),
    .spi_miso (spi_miso),
    .jtag_tck (1'b0),
    .jtag_tms (1'b0),
    .jtag_tdi (1'b0),
    .jtag_tdo ()        // JTAG not used on FPGA
  );

  assign uart_txd = soc_uart_tx;

  // -----------------------------------------------------------------------
  // LED indicators
  // -----------------------------------------------------------------------
  // Heartbeat counter (blink LED[0] at ~1 Hz)
  logic [25:0] heartbeat_cnt;
  always_ff @(posedge clk_50m or negedge rst_n) begin
    if (!rst_n)
      heartbeat_cnt <= '0;
    else
      heartbeat_cnt <= heartbeat_cnt + 1'b1;
  end

  assign led[0] = heartbeat_cnt[25];  // ~1 Hz heartbeat
  assign led[1] = mmcm_locked;        // MMCM lock status
  assign led[2] = rst_n;              // Reset released
  assign led[3] = 1'b0;               // Reserved (can connect to SoC busy/done)

endmodule
