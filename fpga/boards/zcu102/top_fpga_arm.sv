`timescale 1ns/1ps

// Board-level top for Step3 (PS ARM control path).
// Purpose:
//   - Expose AXI4-Lite slave ports to Zynq PS
//   - Convert AXI-Lite transactions to simple bus via axi2simple_bridge
//   - Drive snn_soc_top through ext_bus_* master pins
//
// Notes:
//   - This top is separate from top_fpga.sv (FSM auto-bringup baseline).
//   - It is intended for Vivado Block Design + PS integration.
module top_fpga_arm #(
  // PS-visible address windows (can be changed in BD address editor).
  parameter logic [31:0] PS_REG_BASE        = 32'hA000_0000,
  parameter logic [31:0] PS_DMA_BASE        = 32'hA000_0100,
  parameter logic [31:0] PS_DATA_BASE       = 32'hA001_0000,
  parameter logic [31:0] PS_DATA_SIZE_BYTES = 32'h0000_4000
) (
  // AXI clock/reset from PS
  input  logic        s_axi_aclk,
  input  logic        s_axi_aresetn,

  // AXI4-Lite slave: write address channel
  input  logic [31:0] s_axi_awaddr,
  input  logic [2:0]  s_axi_awprot,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,

  // AXI4-Lite slave: write data channel
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,

  // AXI4-Lite slave: write response channel
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,

  // AXI4-Lite slave: read address channel
  input  logic [31:0] s_axi_araddr,
  input  logic [2:0]  s_axi_arprot,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,

  // AXI4-Lite slave: read data channel
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,

  // Optional external pins kept for bringup visibility.
  input  logic        uart_rxd,
  output logic        uart_txd,
  output logic        spi_cs_n,
  output logic        spi_sck,
  output logic        spi_mosi,
  input  logic        spi_miso,
  output logic [3:0]  led
);
  import snn_soc_pkg::*;

  logic rst_n;
  assign rst_n = s_axi_aresetn;

  // Map PS AXI window to SoC internal global addresses.
  function automatic logic [31:0] map_ps_addr(input logic [31:0] ps_addr);
    logic [31:0] rel;
    begin
      if ((ps_addr >= PS_REG_BASE) && (ps_addr < (PS_REG_BASE + 32'h0000_0100))) begin
        rel         = ps_addr - PS_REG_BASE;
        map_ps_addr = ADDR_REG_BASE + rel;
      end else if ((ps_addr >= PS_DMA_BASE) && (ps_addr < (PS_DMA_BASE + 32'h0000_0100))) begin
        rel         = ps_addr - PS_DMA_BASE;
        map_ps_addr = ADDR_DMA_BASE + rel;
      end else if ((ps_addr >= PS_DATA_BASE) && (ps_addr < (PS_DATA_BASE + PS_DATA_SIZE_BYTES))) begin
        rel         = ps_addr - PS_DATA_BASE;
        map_ps_addr = ADDR_DATA_BASE + rel;
      end else begin
        // Pass-through for debug/extension regions.
        map_ps_addr = ps_addr;
      end
    end
  endfunction

  logic [31:0] awaddr_soc;
  logic [31:0] araddr_soc;
  assign awaddr_soc = map_ps_addr(s_axi_awaddr);
  assign araddr_soc = map_ps_addr(s_axi_araddr);

  // Bridge output (simple bus master toward snn_soc_top.ext_bus_*).
  logic        ext_bus_m_valid;
  logic        ext_bus_m_write;
  logic [31:0] ext_bus_m_addr;
  logic [31:0] ext_bus_m_wdata;
  logic [3:0]  ext_bus_m_wstrb;
  logic        ext_bus_m_ready;
  logic [31:0] ext_bus_m_rdata;
  logic        ext_bus_m_rvalid;

  axi2simple_bridge u_axi2simple_bridge (
    .clk       (s_axi_aclk),
    .rst_n     (rst_n),

    .s_awvalid (s_axi_awvalid),
    .s_awready (s_axi_awready),
    .s_awaddr  (awaddr_soc),

    .s_wvalid  (s_axi_wvalid),
    .s_wready  (s_axi_wready),
    .s_wdata   (s_axi_wdata),
    .s_wstrb   (s_axi_wstrb),

    .s_bvalid  (s_axi_bvalid),
    .s_bready  (s_axi_bready),
    .s_bresp   (s_axi_bresp),

    .s_arvalid (s_axi_arvalid),
    .s_arready (s_axi_arready),
    .s_araddr  (araddr_soc),

    .s_rvalid  (s_axi_rvalid),
    .s_rready  (s_axi_rready),
    .s_rdata   (s_axi_rdata),
    .s_rresp   (s_axi_rresp),

    .m_valid   (ext_bus_m_valid),
    .m_write   (ext_bus_m_write),
    .m_addr    (ext_bus_m_addr),
    .m_wdata   (ext_bus_m_wdata),
    .m_wstrb   (ext_bus_m_wstrb),
    .m_ready   (ext_bus_m_ready),
    .m_rdata   (ext_bus_m_rdata),
    .m_rvalid  (ext_bus_m_rvalid)
  );

  snn_soc_top u_soc (
    .clk             (s_axi_aclk),
    .rst_n           (rst_n),
    .uart_rx         (uart_rxd),
    .uart_tx         (uart_txd),
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

  // Quick board-level visibility.
  logic [25:0] heartbeat_cnt;
  always_ff @(posedge s_axi_aclk or negedge rst_n) begin
    if (!rst_n)
      heartbeat_cnt <= '0;
    else
      heartbeat_cnt <= heartbeat_cnt + 1'b1;
  end

  assign led[0] = heartbeat_cnt[25];
  assign led[1] = rst_n;
  assign led[2] = s_axi_awvalid | s_axi_wvalid | s_axi_arvalid;
  assign led[3] = ext_bus_m_ready | ext_bus_m_rvalid;

  // Keep AXI prot visible for future policy checks; currently unused.
  wire _unused_top_fpga_arm = ^s_axi_awprot ^ ^s_axi_arprot;

endmodule
