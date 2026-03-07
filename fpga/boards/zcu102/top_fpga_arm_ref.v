`timescale 1ns/1ps

// Verilog wrapper for BD module reference.
// Vivado BD module-reference flow may reject SystemVerilog top files directly.
// This wrapper keeps a Verilog top while instantiating top_fpga_arm (SystemVerilog).
module top_fpga_arm_ref (
  input  wire        s_axi_aclk,
  input  wire        s_axi_aresetn,

  input  wire [31:0] s_axi_awaddr,
  input  wire [2:0]  s_axi_awprot,
  input  wire        s_axi_awvalid,
  output wire        s_axi_awready,

  input  wire [31:0] s_axi_wdata,
  input  wire [3:0]  s_axi_wstrb,
  input  wire        s_axi_wvalid,
  output wire        s_axi_wready,

  output wire [1:0]  s_axi_bresp,
  output wire        s_axi_bvalid,
  input  wire        s_axi_bready,

  input  wire [31:0] s_axi_araddr,
  input  wire [2:0]  s_axi_arprot,
  input  wire        s_axi_arvalid,
  output wire        s_axi_arready,

  output wire [31:0] s_axi_rdata,
  output wire [1:0]  s_axi_rresp,
  output wire        s_axi_rvalid,
  input  wire        s_axi_rready,

  input  wire        uart_rxd,
  output wire        uart_txd,
  output wire        spi_cs_n,
  output wire        spi_sck,
  output wire        spi_mosi,
  input  wire        spi_miso,
  output wire [3:0]  led
);

  top_fpga_arm u_top_fpga_arm (
    .s_axi_aclk    (s_axi_aclk),
    .s_axi_aresetn (s_axi_aresetn),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awprot  (s_axi_awprot),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arprot  (s_axi_arprot),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .uart_rxd      (uart_rxd),
    .uart_txd      (uart_txd),
    .spi_cs_n      (spi_cs_n),
    .spi_sck       (spi_sck),
    .spi_mosi      (spi_mosi),
    .spi_miso      (spi_miso),
    .led           (led)
  );

endmodule
