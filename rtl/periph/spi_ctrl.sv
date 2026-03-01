`timescale 1ns/1ps
// ============================================================================
// File   : rtl/periph/spi_ctrl.sv
// Purpose: SPI master controller (Mode 0, 8-bit full-duplex transfers)
// Notes  : Bus interface is kept compatible with spi_stub for drop-in replace.
// ============================================================================
module spi_ctrl (
  input  logic        clk,
  input  logic        rst_n,

  // simple memory-mapped request interface
  input  logic        req_valid,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  output logic [31:0] rdata,

  // SPI pins
  output logic        spi_cs_n,
  output logic        spi_sck,
  output logic        spi_mosi,
  input  logic        spi_miso
);
  localparam logic [7:0] REG_CTRL   = 8'h00;
  localparam logic [7:0] REG_STATUS = 8'h04;
  localparam logic [7:0] REG_TXDATA = 8'h08;
  localparam logic [7:0] REG_RXDATA = 8'h0C;

  localparam logic [1:0] ST_IDLE  = 2'd0;
  localparam logic [1:0] ST_SHIFT = 2'd1;
  localparam logic [1:0] ST_DONE  = 2'd2;

  logic [31:0] ctrl_reg;
  logic [7:0]  tx_shadow;
  logic [7:0]  rx_shadow;

  logic [1:0]  state;
  logic [7:0]  div_cnt;
  logic [7:0]  div_limit;
  logic [2:0]  bit_idx;
  logic [7:0]  tx_shift;
  logic [7:0]  rx_shift;
  logic        sck_int;
  logic        mosi_int;
  logic        busy;
  logic        rx_valid;

  wire write_en = req_valid && req_write;
  wire read_en  = req_valid && !req_write;
  wire [7:0] addr_offset = req_addr[7:0];
  wire spi_en = ctrl_reg[0];
  wire [2:0] clk_div_sel = ctrl_reg[3:1];
  wire cs_force = ctrl_reg[8];
  // Safety clamp: if software enables SPI with clk_div=0, force clk_div=2 (12.5MHz @ 100MHz sys_clk).
  // This avoids accidentally driving 50MHz SCK on boards/flash parts that are not margin-tested yet.
  wire [31:0] ctrl_write_data = (req_wdata[0] && (req_wdata[3:1] == 3'd0))
                              ? {req_wdata[31:4], 3'd2, req_wdata[0]}
                              : req_wdata;

  // req_wstrb is intentionally ignored in this V1 peripheral.
  wire _unused = &{1'b0, req_wstrb, req_addr[31:8]};

  // clk_div mapping: 0..7 -> divide by 2/4/8/16/32/64/128/256.
  always_comb begin
    case (clk_div_sel)
      3'd0: div_limit = 8'd0;
      3'd1: div_limit = 8'd1;
      3'd2: div_limit = 8'd3;
      3'd3: div_limit = 8'd7;
      3'd4: div_limit = 8'd15;
      3'd5: div_limit = 8'd31;
      3'd6: div_limit = 8'd63;
      default: div_limit = 8'd127;
    endcase
  end

  // CS is software-driven. SCK/MOSI are active only while busy.
  assign spi_cs_n = cs_force ? 1'b0 : 1'b1;
  assign spi_sck  = busy ? sck_int  : 1'b0;
  assign spi_mosi = busy ? mosi_int : 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl_reg   <= 32'h0;
      tx_shadow  <= 8'h00;
      rx_shadow  <= 8'h00;
      state      <= ST_IDLE;
      div_cnt    <= 8'h00;
      bit_idx    <= 3'd0;
      tx_shift   <= 8'h00;
      rx_shift   <= 8'h00;
      sck_int    <= 1'b0;
      mosi_int   <= 1'b0;
      busy       <= 1'b0;
      rx_valid   <= 1'b0;
    end else begin
      // Reading RXDATA consumes rx_valid.
      if (read_en && (addr_offset == REG_RXDATA)) begin
        rx_valid <= 1'b0;
      end

      // CTRL is software writable at all times.
      if (write_en && (addr_offset == REG_CTRL)) begin
        ctrl_reg <= ctrl_write_data;
      end

      case (state)
        ST_IDLE: begin
          busy    <= 1'b0;
          sck_int <= 1'b0;
          div_cnt <= 8'h00;

          // TXDATA write starts one 8-bit full-duplex transaction.
          if (write_en && (addr_offset == REG_TXDATA) && spi_en) begin
            tx_shadow <= req_wdata[7:0];
            tx_shift  <= req_wdata[7:0];
            rx_shift  <= 8'h00;
            bit_idx   <= 3'd0;
            mosi_int  <= req_wdata[7];
            busy      <= 1'b1;
            rx_valid  <= 1'b0;
            state     <= ST_SHIFT;
          end
        end

        ST_SHIFT: begin
          if (div_cnt == div_limit) begin
            div_cnt <= 8'h00;

            if (sck_int == 1'b0) begin
              // Rising edge: sample MISO (Mode 0, CPHA=0).
              sck_int <= 1'b1;
              if (bit_idx == 3'd7) begin
                rx_shadow <= {rx_shift[6:0], spi_miso};
                rx_valid  <= 1'b1;
                state     <= ST_DONE;
              end else begin
                rx_shift <= {rx_shift[6:0], spi_miso};
                bit_idx  <= bit_idx + 3'd1;
              end
            end else begin
              // Falling edge: launch next MOSI bit.
              sck_int  <= 1'b0;
              tx_shift <= {tx_shift[6:0], 1'b0};
              mosi_int <= tx_shift[6];
            end
          end else begin
            div_cnt <= div_cnt + 8'd1;
          end
        end

        ST_DONE: begin
          // Keep done state for one cycle, then return to idle.
          sck_int <= 1'b0;
          busy    <= 1'b0;
          state   <= ST_IDLE;
        end

        default: begin
          state <= ST_IDLE;
        end
      endcase
    end
  end

  always_comb begin
    rdata = 32'h0;
    case (addr_offset)
      REG_CTRL:   rdata = ctrl_reg;
      REG_STATUS: rdata = {30'h0, rx_valid, busy};
      REG_TXDATA: rdata = {24'h0, tx_shadow};
      REG_RXDATA: rdata = {24'h0, rx_shadow};
      default:    rdata = 32'h0;
    endcase
  end
endmodule
