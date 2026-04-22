// ============================================================================
// rtl/top/v2b_axi_wrapper_bd.v
//
// Plain-Verilog BD-friendly shim around the SystemVerilog `v2b_axi_wrapper`.
//
// Vivado's `create_bd_cell -type module -reference` rejects SystemVerilog as
// the top file (filemgmt 56-195 error). But internally it happily elaborates
// .sv deps below a .v top. So this file:
//   - declares the same ports as `v2b_axi_wrapper` but using plain Verilog
//     nets + parameters
//   - carries the Xilinx X_INTERFACE_INFO attributes that make the BD
//     module reference automatically infer an AXI-Lite slave interface
//     named `s_axi` (so `apply_bd_automation -rule xilinx.com:bd_rule:axi4`
//     / `connect_bd_intf_net` can target it without touching individual
//     awvalid/awready/... signals).
//   - instantiates `v2b_axi_wrapper` 1:1 (no logic here)
//
// Simulation side (Icarus / VCS) still uses `v2b_axi_wrapper.sv` directly via
// the existing filelists — this .v file is Phase C0 (Vivado BD) only.
//
// Keep port order + names exactly matching `v2b_axi_wrapper.sv` to avoid
// any confusion.
// ============================================================================

`timescale 1ns/1ps

module v2b_axi_wrapper_bd #(
    parameter P_ENABLE_TILE_BUF = 1'b1,
    parameter P_ADC_BITS        = 10
) (
    // Omit FREQ_HZ: the PS pl_clk0 emits ~99.99 MHz (not exactly 100M) due to
    // PLL granularity; forcing FREQ_HZ=100000000 triggers a BD validate
    // mismatch. Letting Vivado auto-propagate from pl_clk0 is the standard
    // Xilinx pattern.
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET rst_n" *)
    input  wire        clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        rst_n,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *) input  wire        s_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *) output wire        s_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR"  *) input  wire [31:0] s_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID"  *) input  wire        s_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY"  *) output wire        s_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA"   *) input  wire [31:0] s_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB"   *) input  wire [3:0]  s_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID"  *) output wire        s_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY"  *) input  wire        s_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP"   *) output wire [1:0]  s_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *) input  wire        s_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *) output wire        s_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR"  *) input  wire [31:0] s_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID"  *) output wire        s_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY"  *) input  wire        s_rready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA"   *) output wire [31:0] s_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP"   *) output wire [1:0]  s_rresp
);

    v2b_axi_wrapper #(
        .P_ENABLE_TILE_BUF (P_ENABLE_TILE_BUF),
        .P_ADC_BITS        (P_ADC_BITS)
    ) u_wrapper (
        .clk       (clk),
        .rst_n     (rst_n),
        .s_awvalid (s_awvalid),
        .s_awready (s_awready),
        .s_awaddr  (s_awaddr),
        .s_wvalid  (s_wvalid),
        .s_wready  (s_wready),
        .s_wdata   (s_wdata),
        .s_wstrb   (s_wstrb),
        .s_bvalid  (s_bvalid),
        .s_bready  (s_bready),
        .s_bresp   (s_bresp),
        .s_arvalid (s_arvalid),
        .s_arready (s_arready),
        .s_araddr  (s_araddr),
        .s_rvalid  (s_rvalid),
        .s_rready  (s_rready),
        .s_rdata   (s_rdata),
        .s_rresp   (s_rresp)
    );

endmodule
