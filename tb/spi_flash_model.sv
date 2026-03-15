`timescale 1ns/1ps
// ============================================================================
// File   : tb/spi_flash_model.sv
// Purpose: Minimal SPI flash behavioral model for spi_ctrl unit test.
// Support: RDID (0x9F), READ (0x03 + 24-bit address)
// Mode   : SPI Mode 0 (CPOL=0, CPHA=0)
// ============================================================================
module spi_flash_model (
  input  logic spi_cs_n,
  input  logic spi_sck,
  input  logic spi_mosi,
  output logic spi_miso
);
  localparam logic [2:0] ST_CMD    = 3'd0;
  localparam logic [2:0] ST_ADDR   = 3'd1;
  localparam logic [2:0] ST_ID     = 3'd2;
  localparam logic [2:0] ST_READ   = 3'd3;
  localparam logic [2:0] ST_IGNORE = 3'd4;

  logic [2:0]  state;
  logic [7:0]  cmd_shift;
  logic [4:0]  in_bit_cnt;
  logic [23:0] addr_shift;
  logic [15:0] addr_ptr;
  logic [7:0]  out_byte;
  logic [2:0]  out_bit_idx;
  logic [1:0]  id_idx;

  // Use a 64KB window so READ tests do not quickly wrap on addresses >0x00FF.
  logic [7:0] mem [0:65535];
  integer i;

  initial begin
    for (i = 0; i < 65536; i = i + 1) begin
      mem[i] = i[7:0];
    end
  end

  always @(negedge spi_cs_n) begin
    state      <= ST_CMD;
    cmd_shift  <= 8'h00;
    in_bit_cnt <= 5'd0;
    addr_shift <= 24'h0;
    addr_ptr   <= 16'h0000;
    out_byte   <= 8'h00;
    out_bit_idx <= 3'd7;
    id_idx     <= 2'd0;
    spi_miso   <= 1'b0;
  end

  always @(posedge spi_cs_n) begin
    spi_miso <= 1'b0;
    state    <= ST_CMD;
  end

  // Capture master MOSI on rising edge.
  always @(posedge spi_sck) begin
    if (!spi_cs_n) begin
      case (state)
        ST_CMD: begin
          cmd_shift <= {cmd_shift[6:0], spi_mosi};
          if (in_bit_cnt == 5'd7) begin
            if ({cmd_shift[6:0], spi_mosi} == 8'h9F) begin
              state       <= ST_ID;
              out_byte    <= 8'hEF;
              out_bit_idx <= 3'd7;
              id_idx      <= 2'd0;
            end else if ({cmd_shift[6:0], spi_mosi} == 8'h03) begin
              state      <= ST_ADDR;
              addr_shift <= 24'h0;
              in_bit_cnt <= 5'd0;
            end else begin
              state <= ST_IGNORE;
            end
          end else begin
            in_bit_cnt <= in_bit_cnt + 5'd1;
          end
        end

        ST_ADDR: begin
          addr_shift <= {addr_shift[22:0], spi_mosi};
          if (in_bit_cnt == 5'd23) begin
            // READ uses 24-bit address, model implements lower 16-bit window.
            addr_ptr    <= {addr_shift[14:0], spi_mosi};
            out_byte    <= mem[{addr_shift[14:0], spi_mosi}];
            out_bit_idx <= 3'd7;
            state       <= ST_READ;
          end else begin
            in_bit_cnt <= in_bit_cnt + 5'd1;
          end
        end

        default: begin
          // ID/READ/IGNORE do not consume MOSI command bits.
        end
      endcase
    end
  end

  // Drive MISO on falling edge so data is stable before next rising sample.
  always @(negedge spi_sck) begin
    if (!spi_cs_n) begin
      case (state)
        ST_ID, ST_READ: begin
          spi_miso <= out_byte[out_bit_idx];
          if (out_bit_idx == 3'd0) begin
            out_bit_idx <= 3'd7;
            if (state == ST_ID) begin
              if (id_idx == 2'd0) begin
                out_byte <= 8'h40;
                id_idx   <= 2'd1;
              end else if (id_idx == 2'd1) begin
                out_byte <= 8'h16;
                id_idx   <= 2'd2;
              end else begin
                out_byte <= 8'h00;
              end
            end else begin
              addr_ptr <= addr_ptr + 16'd1;
              out_byte <= mem[addr_ptr + 16'd1];
            end
          end else begin
            out_bit_idx <= out_bit_idx - 3'd1;
          end
        end

        default: begin
          spi_miso <= 1'b0;
        end
      endcase
    end else begin
      spi_miso <= 1'b0;
    end
  end
endmodule
