`timescale 1ns/1ps
// ============================================================================
// File   : tb/spi_tb.sv
// Purpose: Unit smoke test for spi_ctrl + spi_flash_model
// Coverage:
//   T1: CTRL write/readback
//   T1b: CTRL safety clamp (spi_en=1, clk_div=0 -> force clk_div=2)
//   T2: RDID (0x9F) -> EF 40 16
//   T3: READ (0x03 @ 0x000010) -> 10 11 12 13
//   T4: STATUS.rx_valid clears after RXDATA read
// Pass token:
//   SPI_SMOKETEST_PASS
// ============================================================================
module spi_tb;
  logic clk = 1'b0;
  logic rst_n;
  always #5 clk = ~clk; // 100 MHz

  // simple bus request
  logic        req_valid;
  logic        req_write;
  logic [31:0] req_addr;
  logic [31:0] req_wdata;
  logic [3:0]  req_wstrb;
  logic [31:0] rdata;

  // SPI wires
  logic spi_cs_n;
  logic spi_sck;
  logic spi_mosi;
  logic spi_miso;

  integer pass_cnt;
  integer fail_cnt;

  localparam logic [31:0] REG_CTRL   = 32'h0000_0000;
  localparam logic [31:0] REG_STATUS = 32'h0000_0004;
  localparam logic [31:0] REG_TXDATA = 32'h0000_0008;
  localparam logic [31:0] REG_RXDATA = 32'h0000_000C;

  localparam logic [31:0] CTRL_BASE    = 32'h0000_0005; // spi_en=1, clk_div=2
  localparam logic [31:0] CTRL_CS_LOW  = 32'h0000_0105; // cs_force=1
  localparam logic [31:0] CTRL_CS_HIGH = 32'h0000_0005; // cs_force=0

  spi_ctrl u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid(req_valid),
    .req_write(req_write),
    .req_addr(req_addr),
    .req_wdata(req_wdata),
    .req_wstrb(req_wstrb),
    .rdata(rdata),
    .spi_cs_n(spi_cs_n),
    .spi_sck(spi_sck),
    .spi_mosi(spi_mosi),
    .spi_miso(spi_miso)
  );

  spi_flash_model u_flash (
    .spi_cs_n(spi_cs_n),
    .spi_sck(spi_sck),
    .spi_mosi(spi_mosi),
    .spi_miso(spi_miso)
  );

  task bus_write;
    input [31:0] addr;
    input [31:0] data;
    begin
      @(posedge clk);
      req_valid <= 1'b1;
      req_write <= 1'b1;
      req_addr  <= addr;
      req_wdata <= data;
      req_wstrb <= 4'hF;
      @(posedge clk);
      req_valid <= 1'b0;
      req_write <= 1'b0;
      req_addr  <= 32'h0;
      req_wdata <= 32'h0;
      req_wstrb <= 4'h0;
    end
  endtask

  task bus_read;
    input  [31:0] addr;
    output [31:0] data;
    begin
      @(posedge clk);
      req_valid <= 1'b1;
      req_write <= 1'b0;
      req_addr  <= addr;
      req_wdata <= 32'h0;
      req_wstrb <= 4'h0;
      @(posedge clk);
      data = rdata;
      req_valid <= 1'b0;
      req_addr  <= 32'h0;
    end
  endtask

  task check32;
    input [31:0] got;
    input [31:0] exp;
    input [127:0] label;
    begin
      if (got === exp) begin
        pass_cnt = pass_cnt + 1;
        $display("[PASS] %0s got=0x%08X", label, got);
      end else begin
        fail_cnt = fail_cnt + 1;
        $display("[FAIL] %0s got=0x%08X exp=0x%08X", label, got, exp);
      end
    end
  endtask

  task spi_xfer;
    input  [7:0] tx_byte;
    output [7:0] rx_byte;
    integer t;
    reg [31:0] st;
    reg done;
    reg saw_busy;
    begin
      rx_byte = 8'h00;
      done = 1'b0;
      saw_busy = 1'b0;

      bus_write(REG_TXDATA, {24'h0, tx_byte});

      for (t = 0; t < 400; t = t + 1) begin
        if (!done) begin
          bus_read(REG_STATUS, st);
          if (st[0]) saw_busy = 1'b1;
          if (!st[0] && st[1]) begin
            bus_read(REG_RXDATA, st);
            rx_byte = st[7:0];
            done = 1'b1;

            // RXDATA read should consume rx_valid.
            bus_read(REG_STATUS, st);
            if (st[1] !== 1'b0) begin
              fail_cnt = fail_cnt + 1;
              $display("[FAIL] rx_valid not cleared after RXDATA read");
            end
          end
        end
      end

      if (!done) begin
        fail_cnt = fail_cnt + 1;
        $display("[FAIL] spi_xfer timeout tx=0x%02X", tx_byte);
      end
      if (!saw_busy) begin
        fail_cnt = fail_cnt + 1;
        $display("[FAIL] busy never asserted tx=0x%02X", tx_byte);
      end
    end
  endtask

  initial begin
    reg [31:0] rd;
    reg [7:0] rx;
    reg [7:0] id0, id1, id2;
    reg [7:0] d0, d1, d2, d3;

    pass_cnt = 0;
    fail_cnt = 0;
    rst_n    = 1'b0;

    req_valid = 1'b0;
    req_write = 1'b0;
    req_addr  = 32'h0;
    req_wdata = 32'h0;
    req_wstrb = 4'h0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    $display("[INFO] SPI smoke test start");

    // T1: CTRL write/readback.
    bus_write(REG_CTRL, CTRL_BASE);
    bus_read(REG_CTRL, rd);
    check32(rd, CTRL_BASE, "T1 CTRL");

    // T1b: Safety clamp check. clk_div=0 with spi_en=1 is clamped to clk_div=2.
    bus_write(REG_CTRL, 32'h0000_0001);
    bus_read(REG_CTRL, rd);
    check32(rd, CTRL_BASE, "T1b CLAMP");

    // T2: RDID sequence.
    bus_write(REG_CTRL, CTRL_CS_LOW);
    spi_xfer(8'h9F, rx);   // command byte, received byte ignored
    spi_xfer(8'h00, id0);
    spi_xfer(8'h00, id1);
    spi_xfer(8'h00, id2);
    bus_write(REG_CTRL, CTRL_CS_HIGH);
    check32({24'h0, id0}, 32'h000000EF, "T2 RDID byte0");
    check32({24'h0, id1}, 32'h00000040, "T2 RDID byte1");
    check32({24'h0, id2}, 32'h00000016, "T2 RDID byte2");

    // T3: READ sequence from address 0x000010.
    bus_write(REG_CTRL, CTRL_CS_LOW);
    spi_xfer(8'h03, rx);   // READ cmd
    spi_xfer(8'h00, rx);   // addr[23:16]
    spi_xfer(8'h00, rx);   // addr[15:8]
    spi_xfer(8'h10, rx);   // addr[7:0]
    spi_xfer(8'h00, d0);   // data[0]
    spi_xfer(8'h00, d1);   // data[1]
    spi_xfer(8'h00, d2);   // data[2]
    spi_xfer(8'h00, d3);   // data[3]
    bus_write(REG_CTRL, CTRL_CS_HIGH);
    check32({24'h0, d0}, 32'h00000010, "T3 READ byte0");
    check32({24'h0, d1}, 32'h00000011, "T3 READ byte1");
    check32({24'h0, d2}, 32'h00000012, "T3 READ byte2");
    check32({24'h0, d3}, 32'h00000013, "T3 READ byte3");

    $display("PASS=%0d FAIL=%0d", pass_cnt, fail_cnt);
    if (fail_cnt == 0) begin
      $display("SPI_SMOKETEST_PASS");
    end else begin
      $display("SPI_SMOKETEST_FAIL");
    end

    #50;
    $finish;
  end

  initial begin
    #2000000;
    $display("[ERROR] Timeout");
    $finish;
  end
endmodule

