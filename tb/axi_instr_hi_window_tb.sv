`timescale 1ns/1ps

module axi_instr_hi_window_tb;
  logic clk, rst_n;
  logic s_awvalid, s_awready;
  logic [31:0] s_awaddr;
  logic s_wvalid, s_wready;
  logic [31:0] s_wdata;
  logic [3:0]  s_wstrb;
  logic s_bvalid, s_bready;
  logic [1:0] s_bresp;
  logic s_arvalid, s_arready;
  logic [31:0] s_araddr;
  logic s_rvalid, s_rready;
  logic [31:0] s_rdata;
  logic [1:0] s_rresp;
  logic m_valid, m_write;
  logic [31:0] m_addr, m_wdata;
  logic [3:0]  m_wstrb;
  logic m_ready, m_rvalid;
  logic [31:0] m_rdata;

  axi2simple_bridge dut (
    .clk, .rst_n,
    .s_awvalid, .s_awready, .s_awaddr,
    .s_wvalid, .s_wready, .s_wdata, .s_wstrb,
    .s_bvalid, .s_bready, .s_bresp,
    .s_arvalid, .s_arready, .s_araddr,
    .s_rvalid, .s_rready, .s_rdata, .s_rresp,
    .m_valid, .m_write, .m_addr, .m_wdata, .m_wstrb,
    .m_ready, .m_rdata, .m_rvalid
  );

  initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    s_awvalid = 0; s_awaddr = 0;
    s_wvalid = 0; s_wdata = 0; s_wstrb = 0;
    s_bready = 1;
    s_arvalid = 0; s_araddr = 0;
    s_rready = 1;
    m_ready = 0; m_rvalid = 0; m_rdata = 0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // High INSTR window must be accepted.
    @(posedge clk);
    s_arvalid <= 1'b1;
    s_araddr  <= 32'h0000_4FFC;
    @(posedge clk);
    if (!m_valid || m_write || m_addr != 32'h0000_4FFC) begin
      $display("[FAIL] high-window AXI read not forwarded");
      $fatal(1);
    end
    s_arvalid <= 1'b0;
    m_rdata   <= 32'hA5A5_4FFC;
    m_rvalid  <= 1'b1;
    @(posedge clk);
    m_rvalid <= 1'b0;
    @(posedge clk);
    if (!s_rvalid || s_rresp != 2'b00 || s_rdata != 32'hA5A5_4FFC) begin
      $display("[FAIL] high-window AXI response mismatch");
      $fatal(1);
    end
    @(posedge clk);

    // 0x5000 is still outside the union window and must DECERR.
    s_arvalid <= 1'b1;
    s_araddr  <= 32'h0000_5000;
    @(posedge clk);
    s_arvalid <= 1'b0;
    @(posedge clk);
    if (!s_rvalid || s_rresp != 2'b11 || s_rdata != 32'h0) begin
      $display("[FAIL] out-of-window AXI DECERR mismatch");
      $fatal(1);
    end

    $display("AXI_INSTR_HI_WINDOW_TB_PASS");
    $finish;
  end
endmodule
