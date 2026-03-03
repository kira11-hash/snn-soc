`timescale 1ns/1ps

// Board-level FPGA wrapper with autonomous bringup bus master.
module top_fpga (
  input  logic sys_clk_p,
  input  logic sys_clk_n,
  input  logic btn_rst,

  input  logic uart_rxd,
  output logic uart_txd,

  output logic [3:0] led,

  output logic spi_cs_n,
  output logic spi_sck,
  output logic spi_mosi,
  input  logic spi_miso
);
  import snn_soc_pkg::*;

  // ---------------------------------------------------------------------------
  // Clocking: USER_SI570 differential clock -> MMCM -> 50 MHz system clock
  // ---------------------------------------------------------------------------
  logic sys_clk_ibuf;
  logic clk_50m;
  logic mmcm_locked;
  logic clk_mmcm_out;
  logic clk_fb;

  IBUFDS #(
    .DIFF_TERM    ("TRUE"),
    .IBUF_LOW_PWR ("FALSE")
  ) u_ibufds (
    .O  (sys_clk_ibuf),
    .I  (sys_clk_p),
    .IB (sys_clk_n)
  );

  MMCME4_ADV #(
    .CLKIN1_PERIOD    (3.333),
    .CLKFBOUT_MULT_F  (4.0),
    .CLKOUT0_DIVIDE_F (24.0),
    .DIVCLK_DIVIDE    (1)
  ) u_mmcm (
    .CLKIN1        (sys_clk_ibuf),
    .CLKIN2        (1'b0),
    .CLKINSEL      (1'b1),
    .CLKFBIN       (clk_fb),
    .CLKFBOUT      (clk_fb),
    .CLKOUT0       (clk_mmcm_out),
    .LOCKED        (mmcm_locked),
    .PWRDWN        (1'b0),
    .RST           (btn_rst),
    .CLKOUT1       (),
    .CLKOUT2       (),
    .CLKOUT3       (),
    .CLKOUT4       (),
    .CLKOUT5       (),
    .CLKOUT6       (),
    .CLKFBOUTB     (),
    .CLKOUT0B      (),
    .CLKOUT1B      (),
    .CLKOUT2B      (),
    .CLKOUT3B      (),
    .DADDR         (7'd0),
    .DCLK          (1'b0),
    .DEN           (1'b0),
    .DWE           (1'b0),
    .DI            (16'd0),
    .DO            (),
    .DRDY          (),
    .PSCLK         (1'b0),
    .PSEN          (1'b0),
    .PSINCDEC      (1'b0),
    .PSDONE        (),
    .CDDCREQ       (1'b0),
    .CDDCDONE      (),
    .CLKINSTOPPED  (),
    .CLKFBSTOPPED  ()
  );

  BUFG u_bufg (
    .O (clk_50m),
    .I (clk_mmcm_out)
  );

  // ---------------------------------------------------------------------------
  // Reset sync: async assert, sync release
  // ---------------------------------------------------------------------------
  logic rst_n_raw;
  logic [1:0] rst_sync;
  logic rst_n;

  assign rst_n_raw = mmcm_locked & ~btn_rst;

  always_ff @(posedge clk_50m or negedge rst_n_raw) begin
    if (!rst_n_raw) begin
      rst_sync <= 2'b00;
    end else begin
      rst_sync <= {rst_sync[0], 1'b1};
    end
  end

  assign rst_n = rst_sync[1];

  // ---------------------------------------------------------------------------
  // External simple bus master wires injected into snn_soc_top
  // ---------------------------------------------------------------------------
  logic        ext_bus_m_valid;
  logic        ext_bus_m_write;
  logic [31:0] ext_bus_m_addr;
  logic [31:0] ext_bus_m_wdata;
  logic [3:0]  ext_bus_m_wstrb;
  logic        ext_bus_m_ready;
  logic [31:0] ext_bus_m_rdata;
  logic        ext_bus_m_rvalid;

  // ---------------------------------------------------------------------------
  // SoC core
  // ---------------------------------------------------------------------------
  logic soc_uart_tx;

  snn_soc_top u_soc (
    .clk             (clk_50m),
    .rst_n           (rst_n),
    .uart_rx         (uart_rxd),
    .uart_tx         (soc_uart_tx),
    .spi_cs_n        (spi_cs_n),
    .spi_sck         (spi_sck),
    .spi_mosi        (spi_mosi),
    .spi_miso        (spi_miso),
    .jtag_tck        (1'b0),
    .jtag_tms        (1'b0),
    .jtag_tdi        (1'b0),
    .jtag_tdo        (),
    .ext_bus_enable  (1'b1),
    .ext_bus_m_valid (ext_bus_m_valid),
    .ext_bus_m_write (ext_bus_m_write),
    .ext_bus_m_addr  (ext_bus_m_addr),
    .ext_bus_m_wdata (ext_bus_m_wdata),
    .ext_bus_m_wstrb (ext_bus_m_wstrb),
    .ext_bus_m_ready (ext_bus_m_ready),
    .ext_bus_m_rdata (ext_bus_m_rdata),
    .ext_bus_m_rvalid(ext_bus_m_rvalid)
  );

  assign uart_txd = soc_uart_tx;

  // ---------------------------------------------------------------------------
  // Bringup sequence parameters
  // ---------------------------------------------------------------------------
  localparam [31:0] REG_THRESHOLD = ADDR_REG_BASE + 32'h00;
  localparam [31:0] REG_TIMESTEPS = ADDR_REG_BASE + 32'h04;
  localparam [31:0] REG_CIM_CTRL  = ADDR_REG_BASE + 32'h14;
  localparam [31:0] REG_OUT_COUNT = ADDR_REG_BASE + 32'h20;
  localparam [31:0] REG_CIM_TEST  = ADDR_REG_BASE + 32'h2C;

  localparam [31:0] DMA_SRC_ADDR  = ADDR_DMA_BASE + 32'h00;
  localparam [31:0] DMA_LEN_WORDS = ADDR_DMA_BASE + 32'h04;
  localparam [31:0] DMA_CTRL      = ADDR_DMA_BASE + 32'h08;

  localparam int TXN_TIMEOUT_CYCLES = 8'd64;
  localparam int DMA_POLL_LIMIT     = 16'd1200;
  localparam int CIM_POLL_LIMIT     = 16'd60000;

  // ---------------------------------------------------------------------------
  // Transaction engine: issues one bus request and waits for response
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    TXN_IDLE,
    TXN_REQ,
    TXN_WAIT
  } txn_state_t;

  txn_state_t txn_state;

  logic        txn_start;
  logic        txn_start_write;
  logic [31:0] txn_start_addr;
  logic [31:0] txn_start_wdata;

  logic        txn_busy;
  logic        txn_done;
  logic        txn_error;
  logic [31:0] txn_rdata;

  logic        txn_write_q;
  logic [31:0] txn_addr_q;
  logic [31:0] txn_wdata_q;
  logic [7:0]  txn_timeout_q;

  assign txn_busy = (txn_state != TXN_IDLE);

  always_ff @(posedge clk_50m or negedge rst_n) begin
    if (!rst_n) begin
      txn_state      <= TXN_IDLE;
      txn_done       <= 1'b0;
      txn_error      <= 1'b0;
      txn_rdata      <= 32'h0;
      txn_write_q    <= 1'b0;
      txn_addr_q     <= 32'h0;
      txn_wdata_q    <= 32'h0;
      txn_timeout_q  <= 8'h0;
      ext_bus_m_valid<= 1'b0;
      ext_bus_m_write<= 1'b0;
      ext_bus_m_addr <= 32'h0;
      ext_bus_m_wdata<= 32'h0;
      ext_bus_m_wstrb<= 4'h0;
    end else begin
      txn_done <= 1'b0;

      case (txn_state)
        TXN_IDLE: begin
          ext_bus_m_valid <= 1'b0;
          ext_bus_m_write <= 1'b0;
          ext_bus_m_wstrb <= 4'h0;
          txn_error       <= 1'b0;
          if (txn_start) begin
            txn_write_q     <= txn_start_write;
            txn_addr_q      <= txn_start_addr;
            txn_wdata_q     <= txn_start_wdata;
            txn_timeout_q   <= TXN_TIMEOUT_CYCLES[7:0];
            ext_bus_m_valid <= 1'b1;
            ext_bus_m_write <= txn_start_write;
            ext_bus_m_addr  <= txn_start_addr;
            ext_bus_m_wdata <= txn_start_wdata;
            ext_bus_m_wstrb <= txn_start_write ? 4'hF : 4'h0;
            txn_state       <= TXN_REQ;
          end
        end

        TXN_REQ: begin
          // Hold request for exactly one cycle; bus_interconnect samples then
          // returns ready/rvalid one cycle later.
          ext_bus_m_valid <= 1'b0;
          txn_state       <= TXN_WAIT;
        end

        TXN_WAIT: begin
          if ((txn_write_q && ext_bus_m_ready) || (!txn_write_q && ext_bus_m_rvalid)) begin
            txn_done   <= 1'b1;
            txn_error  <= 1'b0;
            txn_rdata  <= ext_bus_m_rdata;
            txn_state  <= TXN_IDLE;
          end else if (txn_timeout_q == 0) begin
            txn_done   <= 1'b1;
            txn_error  <= 1'b1;
            txn_rdata  <= 32'h0;
            txn_state  <= TXN_IDLE;
          end else begin
            txn_timeout_q <= txn_timeout_q - 1'b1;
          end
        end

        default: begin
          txn_state <= TXN_IDLE;
        end
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Bringup FSM: write config/data, start DMA, start CIM, check OUT count
  // ---------------------------------------------------------------------------
  typedef enum logic [5:0] {
    BR_WAIT_RESET,
    BR_WR_TIMESTEPS_ISSUE,
    BR_WR_TIMESTEPS_WAIT,
    BR_WR_THRESHOLD_ISSUE,
    BR_WR_THRESHOLD_WAIT,
    BR_WR_CIM_TEST_ISSUE,
    BR_WR_CIM_TEST_WAIT,
    BR_DATA_ISSUE,
    BR_DATA_WAIT,
    BR_DMA_SRC_ISSUE,
    BR_DMA_SRC_WAIT,
    BR_DMA_LEN_ISSUE,
    BR_DMA_LEN_WAIT,
    BR_DMA_START_ISSUE,
    BR_DMA_START_WAIT,
    BR_DMA_POLL_ISSUE,
    BR_DMA_POLL_WAIT,
    BR_CIM_START_ISSUE,
    BR_CIM_START_WAIT,
    BR_CIM_POLL_ISSUE,
    BR_CIM_POLL_WAIT,
    BR_OUTCNT_ISSUE,
    BR_OUTCNT_WAIT,
    BR_PASS,
    BR_FAIL
  } bringup_state_t;

  bringup_state_t br_state;

  logic [1:0]  wr_frame_idx;
  logic [2:0]  wr_plane_idx;
  logic        wr_word_sel;
  logic [15:0] dma_poll_cnt;
  logic [15:0] cim_poll_cnt;
  logic [31:0] out_fifo_count;
  logic [7:0]  fail_code;

  logic bringup_busy;
  logic bringup_pass;
  logic bringup_fail;

  always_comb begin
    txn_start       = 1'b0;
    txn_start_write = 1'b0;
    txn_start_addr  = 32'h0;
    txn_start_wdata = 32'h0;

    case (br_state)
      BR_WR_TIMESTEPS_ISSUE: begin
        if (!txn_busy) begin
          txn_start       = 1'b1;
          txn_start_write = 1'b1;
          txn_start_addr  = REG_TIMESTEPS;
          txn_start_wdata = 32'd3;
        end
      end

      BR_WR_THRESHOLD_ISSUE: begin
        if (!txn_busy) begin
          txn_start       = 1'b1;
          txn_start_write = 1'b1;
          txn_start_addr  = REG_THRESHOLD;
          txn_start_wdata = 32'd3060;
        end
      end

      BR_WR_CIM_TEST_ISSUE: begin
        if (!txn_busy) begin
          txn_start       = 1'b1;
          txn_start_write = 1'b1;
          txn_start_addr  = REG_CIM_TEST;
          txn_start_wdata = 32'h0000_0000;
        end
      end

      BR_DATA_ISSUE: begin
        if (!txn_busy) begin
          txn_start       = 1'b1;
          txn_start_write = 1'b1;
          txn_start_addr  = ADDR_DATA_BASE +
                            ({30'd0, wr_frame_idx} << 6) +
                            ({29'd0, wr_plane_idx} << 3) +
                            (wr_word_sel ? 32'd4 : 32'd0);
          txn_start_wdata = wr_word_sel ? 32'h0000_0000 : (32'h0000_00FF >> wr_plane_idx);
        end
      end

      BR_DMA_SRC_ISSUE: begin
        if (!txn_busy) begin
          txn_start       = 1'b1;
          txn_start_write = 1'b1;
          txn_start_addr  = DMA_SRC_ADDR;
          txn_start_wdata = ADDR_DATA_BASE;
        end
      end

      BR_DMA_LEN_ISSUE: begin
        if (!txn_busy) begin
          txn_start       = 1'b1;
          txn_start_write = 1'b1;
          txn_start_addr  = DMA_LEN_WORDS;
          txn_start_wdata = 32'd48;
        end
      end

      BR_DMA_START_ISSUE: begin
        if (!txn_busy) begin
          txn_start       = 1'b1;
          txn_start_write = 1'b1;
          txn_start_addr  = DMA_CTRL;
          txn_start_wdata = 32'h0000_0001;
        end
      end

      BR_DMA_POLL_ISSUE: begin
        if (!txn_busy) begin
          txn_start       = 1'b1;
          txn_start_write = 1'b0;
          txn_start_addr  = DMA_CTRL;
        end
      end

      BR_CIM_START_ISSUE: begin
        if (!txn_busy) begin
          txn_start       = 1'b1;
          txn_start_write = 1'b1;
          txn_start_addr  = REG_CIM_CTRL;
          txn_start_wdata = 32'h0000_0001;
        end
      end

      BR_CIM_POLL_ISSUE: begin
        if (!txn_busy) begin
          txn_start       = 1'b1;
          txn_start_write = 1'b0;
          txn_start_addr  = REG_CIM_CTRL;
        end
      end

      BR_OUTCNT_ISSUE: begin
        if (!txn_busy) begin
          txn_start       = 1'b1;
          txn_start_write = 1'b0;
          txn_start_addr  = REG_OUT_COUNT;
        end
      end

      default: begin
      end
    endcase
  end

  always_ff @(posedge clk_50m or negedge rst_n) begin
    if (!rst_n) begin
      br_state      <= BR_WAIT_RESET;
      wr_frame_idx  <= 2'd0;
      wr_plane_idx  <= 3'd0;
      wr_word_sel   <= 1'b0;
      dma_poll_cnt  <= 16'd0;
      cim_poll_cnt  <= 16'd0;
      out_fifo_count<= 32'd0;
      fail_code     <= 8'h00;
      bringup_busy  <= 1'b0;
      bringup_pass  <= 1'b0;
      bringup_fail  <= 1'b0;
    end else begin
      case (br_state)
        BR_WAIT_RESET: begin
          bringup_busy <= 1'b1;
          bringup_pass <= 1'b0;
          bringup_fail <= 1'b0;
          fail_code    <= 8'h00;
          br_state     <= BR_WR_TIMESTEPS_ISSUE;
        end

        BR_WR_TIMESTEPS_ISSUE: if (txn_start) br_state <= BR_WR_TIMESTEPS_WAIT;
        BR_WR_TIMESTEPS_WAIT: begin
          if (txn_done) begin
            if (txn_error) begin
              fail_code <= 8'h01;
              br_state  <= BR_FAIL;
            end else begin
              br_state <= BR_WR_THRESHOLD_ISSUE;
            end
          end
        end

        BR_WR_THRESHOLD_ISSUE: if (txn_start) br_state <= BR_WR_THRESHOLD_WAIT;
        BR_WR_THRESHOLD_WAIT: begin
          if (txn_done) begin
            if (txn_error) begin
              fail_code <= 8'h02;
              br_state  <= BR_FAIL;
            end else begin
              br_state <= BR_WR_CIM_TEST_ISSUE;
            end
          end
        end

        BR_WR_CIM_TEST_ISSUE: if (txn_start) br_state <= BR_WR_CIM_TEST_WAIT;
        BR_WR_CIM_TEST_WAIT: begin
          if (txn_done) begin
            if (txn_error) begin
              fail_code <= 8'h03;
              br_state  <= BR_FAIL;
            end else begin
              wr_frame_idx <= 2'd0;
              wr_plane_idx <= 3'd0;
              wr_word_sel  <= 1'b0;
              br_state     <= BR_DATA_ISSUE;
            end
          end
        end

        BR_DATA_ISSUE: if (txn_start) br_state <= BR_DATA_WAIT;
        BR_DATA_WAIT: begin
          if (txn_done) begin
            if (txn_error) begin
              fail_code <= 8'h10;
              br_state  <= BR_FAIL;
            end else if (!wr_word_sel) begin
              wr_word_sel <= 1'b1;
              br_state    <= BR_DATA_ISSUE;
            end else begin
              wr_word_sel <= 1'b0;
              if (wr_plane_idx == 3'd7) begin
                wr_plane_idx <= 3'd0;
                if (wr_frame_idx == 2'd2) begin
                  br_state <= BR_DMA_SRC_ISSUE;
                end else begin
                  wr_frame_idx <= wr_frame_idx + 1'b1;
                  br_state     <= BR_DATA_ISSUE;
                end
              end else begin
                wr_plane_idx <= wr_plane_idx + 1'b1;
                br_state     <= BR_DATA_ISSUE;
              end
            end
          end
        end

        BR_DMA_SRC_ISSUE: if (txn_start) br_state <= BR_DMA_SRC_WAIT;
        BR_DMA_SRC_WAIT: begin
          if (txn_done) begin
            if (txn_error) begin
              fail_code <= 8'h11;
              br_state  <= BR_FAIL;
            end else begin
              br_state <= BR_DMA_LEN_ISSUE;
            end
          end
        end

        BR_DMA_LEN_ISSUE: if (txn_start) br_state <= BR_DMA_LEN_WAIT;
        BR_DMA_LEN_WAIT: begin
          if (txn_done) begin
            if (txn_error) begin
              fail_code <= 8'h12;
              br_state  <= BR_FAIL;
            end else begin
              br_state <= BR_DMA_START_ISSUE;
            end
          end
        end

        BR_DMA_START_ISSUE: if (txn_start) br_state <= BR_DMA_START_WAIT;
        BR_DMA_START_WAIT: begin
          if (txn_done) begin
            if (txn_error) begin
              fail_code <= 8'h13;
              br_state  <= BR_FAIL;
            end else begin
              dma_poll_cnt <= 16'd0;
              br_state     <= BR_DMA_POLL_ISSUE;
            end
          end
        end

        BR_DMA_POLL_ISSUE: if (txn_start) br_state <= BR_DMA_POLL_WAIT;
        BR_DMA_POLL_WAIT: begin
          if (txn_done) begin
            if (txn_error) begin
              fail_code <= 8'h14;
              br_state  <= BR_FAIL;
            end else if (txn_rdata[2]) begin
              // DMA error bit
              fail_code <= 8'h15;
              br_state  <= BR_FAIL;
            end else if (txn_rdata[1]) begin
              // DMA done
              br_state <= BR_CIM_START_ISSUE;
            end else if (dma_poll_cnt >= DMA_POLL_LIMIT) begin
              fail_code <= 8'h16;
              br_state  <= BR_FAIL;
            end else begin
              dma_poll_cnt <= dma_poll_cnt + 1'b1;
              br_state     <= BR_DMA_POLL_ISSUE;
            end
          end
        end

        BR_CIM_START_ISSUE: if (txn_start) br_state <= BR_CIM_START_WAIT;
        BR_CIM_START_WAIT: begin
          if (txn_done) begin
            if (txn_error) begin
              fail_code <= 8'h20;
              br_state  <= BR_FAIL;
            end else begin
              cim_poll_cnt <= 16'd0;
              br_state     <= BR_CIM_POLL_ISSUE;
            end
          end
        end

        BR_CIM_POLL_ISSUE: if (txn_start) br_state <= BR_CIM_POLL_WAIT;
        BR_CIM_POLL_WAIT: begin
          if (txn_done) begin
            if (txn_error) begin
              fail_code <= 8'h21;
              br_state  <= BR_FAIL;
            end else if (txn_rdata[7]) begin
              // CIM done
              br_state <= BR_OUTCNT_ISSUE;
            end else if (cim_poll_cnt >= CIM_POLL_LIMIT) begin
              fail_code <= 8'h22;
              br_state  <= BR_FAIL;
            end else begin
              cim_poll_cnt <= cim_poll_cnt + 1'b1;
              br_state     <= BR_CIM_POLL_ISSUE;
            end
          end
        end

        BR_OUTCNT_ISSUE: if (txn_start) br_state <= BR_OUTCNT_WAIT;
        BR_OUTCNT_WAIT: begin
          if (txn_done) begin
            if (txn_error) begin
              fail_code <= 8'h30;
              br_state  <= BR_FAIL;
            end else begin
              out_fifo_count <= txn_rdata;
              if (txn_rdata != 32'd0) begin
                br_state <= BR_PASS;
              end else begin
                fail_code <= 8'h31;
                br_state  <= BR_FAIL;
              end
            end
          end
        end

        BR_PASS: begin
          bringup_busy <= 1'b0;
          bringup_pass <= 1'b1;
          bringup_fail <= 1'b0;
          br_state     <= BR_PASS;
        end

        BR_FAIL: begin
          bringup_busy <= 1'b0;
          bringup_pass <= 1'b0;
          bringup_fail <= 1'b1;
          br_state     <= BR_FAIL;
        end

        default: begin
          fail_code <= 8'hFF;
          br_state  <= BR_FAIL;
        end
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // LEDs
  //   led[0]: heartbeat
  //   led[1]: MMCM lock
  //   led[2]: bringup busy/fail
  //   led[3]: bringup pass
  // ---------------------------------------------------------------------------
  logic [25:0] heartbeat_cnt;

  always_ff @(posedge clk_50m or negedge rst_n) begin
    if (!rst_n)
      heartbeat_cnt <= '0;
    else
      heartbeat_cnt <= heartbeat_cnt + 1'b1;
  end

  assign led[0] = heartbeat_cnt[25];
  assign led[1] = mmcm_locked;
  assign led[2] = bringup_busy | bringup_fail;
  assign led[3] = bringup_pass;

  wire _unused_top_fpga = ^fail_code ^ ^out_fifo_count;

endmodule
