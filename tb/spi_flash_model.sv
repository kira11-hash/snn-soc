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
  wire _unused_shift_bits = &{1'b0, cmd_shift[7], addr_shift[23]};

  // Use a 64KB window so READ tests do not quickly wrap on addresses >0x00FF.
  logic [7:0] mem [0:65535];
  integer i;

  initial begin
    for (i = 0; i < 65536; i = i + 1) begin
      mem[i] = i[7:0];
    end
  end

  initial begin
    state       = ST_CMD;
    cmd_shift   = 8'h00;
    in_bit_cnt  = 5'd0;
    addr_shift  = 24'h0;
    addr_ptr    = 16'h0000;
    out_byte    = 8'h00;
    out_bit_idx = 3'd7;
    id_idx      = 2'd0;
  end

  // Mode-0 slave output is purely a function of the current response byte.
  always_comb begin
    if (!spi_cs_n && ((state == ST_ID) || (state == ST_READ))) begin
      spi_miso = out_byte[out_bit_idx];
    end else begin
      spi_miso = 1'b0;
    end
  end

  // Capture MOSI and advance the response stream on the master's sampling edge.
  always_ff @(posedge spi_sck or posedge spi_cs_n) begin
    logic [7:0]  cmd_next;
    logic [23:0] addr_next;

    if (spi_cs_n) begin
      state       <= ST_CMD;
      cmd_shift   <= 8'h00;
      in_bit_cnt  <= 5'd0;
      addr_shift  <= 24'h0;
      addr_ptr    <= 16'h0000;
      out_byte    <= 8'h00;
      out_bit_idx <= 3'd7;
      id_idx      <= 2'd0;
    end else begin
      case (state)
        ST_CMD: begin
          cmd_next   = {cmd_shift[6:0], spi_mosi};
          cmd_shift  <= cmd_next;
          if (in_bit_cnt == 5'd7) begin
            in_bit_cnt <= 5'd0;
            if (cmd_next == 8'h9F) begin
              state       <= ST_ID;
              out_byte    <= 8'hEF;
              out_bit_idx <= 3'd7;
              id_idx      <= 2'd0;
            end else if (cmd_next == 8'h03) begin
              state      <= ST_ADDR;
              addr_shift <= 24'h0;
            end else begin
              state <= ST_IGNORE;
            end
          end else begin
            in_bit_cnt <= in_bit_cnt + 5'd1;
          end
        end

        ST_ADDR: begin
          addr_next  = {addr_shift[22:0], spi_mosi};
          addr_shift <= addr_next;
          if (in_bit_cnt == 5'd23) begin
            addr_ptr    <= addr_next[15:0];
            out_byte    <= mem[addr_next[15:0]];
            out_bit_idx <= 3'd7;
            in_bit_cnt  <= 5'd0;
            state       <= ST_READ;
          end else begin
            in_bit_cnt <= in_bit_cnt + 5'd1;
          end
        end

        ST_ID: begin
          if (out_bit_idx == 3'd0) begin
            out_bit_idx <= 3'd7;
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
            out_bit_idx <= out_bit_idx - 3'd1;
          end
        end

        ST_READ: begin
          if (out_bit_idx == 3'd0) begin
            out_bit_idx <= 3'd7;
            addr_ptr    <= addr_ptr + 16'd1;
            out_byte    <= mem[addr_ptr + 16'd1];
          end else begin
            out_bit_idx <= out_bit_idx - 3'd1;
          end
        end

        default: begin
          // IGNORE keeps returning zero until CS deasserts.
        end
      endcase
    end
  end
endmodule
