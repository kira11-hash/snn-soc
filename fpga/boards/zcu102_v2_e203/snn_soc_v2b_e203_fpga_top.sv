`timescale 1ns/1ps
//=============================================================================
// fpga/boards/zcu102_v2_e203/snn_soc_v2b_e203_fpga_top.sv
//
// ZCU102 board wrapper for feature/v2-fpga-e203.
//   USER_SI570 300 MHz differential clock -> MMCM -> 50 MHz SoC clock
//   btn_rst / MMCM lock -> async assert, 2-FF synchronized release
//   CP2108 J83 Interface 2 UART -> V2E203 firmware console
//
// SoC core is rtl/top/snn_soc_v2b_e203_top.sv. This wrapper deliberately
// contains only board-level clock/reset/IO glue.
//=============================================================================
module snn_soc_v2b_e203_fpga_top #(
  parameter string INSTR_INIT_FILE = ""
) (
  input  logic sys_clk_p,
  input  logic sys_clk_n,
  input  logic btn_rst,

  output logic uart_txd,
  input  logic uart_rxd,

  output logic [3:0] led
);

  // ---------------------------------------------------------------------------
  // Clock: ZCU102 USER_SI570 300 MHz differential -> 50 MHz fabric clock.
  // VCO = 300 MHz * 4 = 1200 MHz, CLKOUT0 = 1200 / 24 = 50 MHz.
  // ---------------------------------------------------------------------------
  logic sys_clk_ibuf;
  logic clk_fb;
  logic clk_50m_raw;
  logic clk_50m;
  logic mmcm_locked;

  IBUFDS #(
    .DIFF_TERM    ("TRUE"),
    .IBUF_LOW_PWR ("FALSE")
  ) u_ibufds (
    .O  (sys_clk_ibuf),
    .I  (sys_clk_p),
    .IB (sys_clk_n)
  );

  MMCME4_ADV #(
    .BANDWIDTH          ("OPTIMIZED"),
    .CLKFBOUT_MULT_F    (4.0),
    .CLKFBOUT_PHASE     (0.0),
    .CLKIN1_PERIOD      (3.333),
    .CLKOUT0_DIVIDE_F   (24.0),
    .CLKOUT0_DUTY_CYCLE (0.5),
    .CLKOUT0_PHASE      (0.0),
    .DIVCLK_DIVIDE      (1)
  ) u_mmcm (
    .CLKIN1       (sys_clk_ibuf),
    .CLKIN2       (1'b0),
    .CLKINSEL     (1'b1),
    .CLKFBIN      (clk_fb),
    .CLKFBOUT     (clk_fb),
    .CLKFBOUTB    (),
    .CLKOUT0      (clk_50m_raw),
    .CLKOUT0B     (),
    .CLKOUT1      (), .CLKOUT1B (),
    .CLKOUT2      (), .CLKOUT2B (),
    .CLKOUT3      (), .CLKOUT3B (),
    .CLKOUT4      (),
    .CLKOUT5      (),
    .CLKOUT6      (),
    .LOCKED       (mmcm_locked),
    .PWRDWN       (1'b0),
    .RST          (btn_rst),
    .DADDR        (7'd0),
    .DCLK         (1'b0),
    .DEN          (1'b0),
    .DWE          (1'b0),
    .DI           (16'd0),
    .DO           (),
    .DRDY         (),
    .PSCLK        (1'b0),
    .PSEN         (1'b0),
    .PSINCDEC     (1'b0),
    .PSDONE       (),
    .CDDCREQ      (1'b0),
    .CDDCDONE     (),
    .CLKINSTOPPED (),
    .CLKFBSTOPPED ()
  );

  BUFG u_bufg (
    .I(clk_50m_raw),
    .O(clk_50m)
  );

  // ---------------------------------------------------------------------------
  // Reset: assert asynchronously on button or unlocked MMCM, release sync.
  // ---------------------------------------------------------------------------
  logic rst_n_raw;
  logic [1:0] rst_sync;
  logic rst_n;

  assign rst_n_raw = mmcm_locked & ~btn_rst;

  always_ff @(posedge clk_50m or negedge rst_n_raw) begin
    if (!rst_n_raw) rst_sync <= 2'b00;
    else            rst_sync <= {rst_sync[0], 1'b1};
  end
  assign rst_n = rst_sync[1];

  // ---------------------------------------------------------------------------
  // V2E203 SoC core.
  // ---------------------------------------------------------------------------
  snn_soc_v2b_e203_top #(
    .INSTR_INIT_FILE(INSTR_INIT_FILE)
  ) u_soc (
    .clk    (clk_50m),
    .rst_n  (rst_n),
    .uart_rx(uart_rxd),
    .uart_tx(uart_txd)
  );

  // ---------------------------------------------------------------------------
  // LEDs: heartbeat / lock / reset released / UART TX activity hint.
  // ---------------------------------------------------------------------------
  logic [25:0] heartbeat_cnt;
  logic uart_txd_q;

  always_ff @(posedge clk_50m or negedge rst_n) begin
    if (!rst_n) begin
      heartbeat_cnt <= '0;
      uart_txd_q    <= 1'b1;
    end else begin
      heartbeat_cnt <= heartbeat_cnt + 1'b1;
      uart_txd_q    <= uart_txd;
    end
  end

  assign led[0] = heartbeat_cnt[25];
  assign led[1] = mmcm_locked;
  assign led[2] = rst_n;
  assign led[3] = uart_txd_q ^ uart_txd;

endmodule
