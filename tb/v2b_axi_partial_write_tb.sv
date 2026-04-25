`timescale 1ns/1ps
//======================================================================
// tb/v2b_axi_partial_write_tb.sv
//
// F1 regression for feature/v2-arm-fpga-demo-fix-gpt.
//
// Goal:
//   Prove that AXI-Lite WSTRB reaches snn_soc_v2b_top correctly instead of
//   being widened into full-word writes.
//
// Baseline expectation on frozen tag v2-arm-fpga-demo-passed:
//   T1/T2/T3 fail, because snn_soc_v2b_top ignored cmd_wstrb and overwrote the
//   full register/staging word.
//
// Pass criteria on fixed RTL:
//   - read/write registers merge only strobed bytes
//   - staging registers (INPUT_SRAM_ADDR/W0, MAC_W_LOAD_ADDR) preserve
//     untouched bytes
//   - byte1-only write to STREAM_BUF_CTRL does not fire byte0 pulses
//======================================================================
module v2b_axi_partial_write_tb;

  import snn_soc_pkg::*;

  localparam logic [11:0] O_STAGE_CTRL      = 12'h000;
  localparam logic [11:0] O_STAGE_CFG0      = 12'h008;
  localparam logic [11:0] O_STAGE_CFG1      = 12'h00C;
  localparam logic [11:0] O_INPUT_SRAM_ADDR = 12'h020;
  localparam logic [11:0] O_INPUT_SRAM_W0   = 12'h024;
  localparam logic [11:0] O_MAC_W_LOAD_ADDR = 12'h050;
  localparam logic [11:0] O_STREAM_BUF_CTRL = 12'h060;

  function automatic logic [31:0] v2b_addr(input logic [11:0] off);
    v2b_addr = ADDR_V2B_BASE + {20'h0, off};
  endfunction

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        s_awvalid = 1'b0;
  logic        s_awready;
  logic [31:0] s_awaddr  = '0;
  logic        s_wvalid  = 1'b0;
  logic        s_wready;
  logic [31:0] s_wdata   = '0;
  logic [3:0]  s_wstrb   = 4'h0;
  logic        s_bvalid;
  logic        s_bready  = 1'b0;
  logic [1:0]  s_bresp;
  logic        s_arvalid = 1'b0;
  logic        s_arready;
  logic [31:0] s_araddr  = '0;
  logic        s_rvalid;
  logic        s_rready  = 1'b0;
  logic [31:0] s_rdata;
  logic [1:0]  s_rresp;
  logic [31:0] rd_data;

  integer pass_count = 0;
  integer fail_count = 0;
  integer start_pulse_count = 0;
  integer clear_a_count = 0;
  integer clear_b_count = 0;
  integer clear_tile_count = 0;
  integer start_before = 0;
  integer clear_a_before = 0;
  integer clear_b_before = 0;
  integer clear_tile_before = 0;

  v2b_axi_wrapper #(
    .P_ENABLE_TILE_BUF(1'b1),
    .P_ADC_BITS(10)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .s_awvalid(s_awvalid),
    .s_awready(s_awready),
    .s_awaddr(s_awaddr),
    .s_wvalid(s_wvalid),
    .s_wready(s_wready),
    .s_wdata(s_wdata),
    .s_wstrb(s_wstrb),
    .s_bvalid(s_bvalid),
    .s_bready(s_bready),
    .s_bresp(s_bresp),
    .s_arvalid(s_arvalid),
    .s_arready(s_arready),
    .s_araddr(s_araddr),
    .s_rvalid(s_rvalid),
    .s_rready(s_rready),
    .s_rdata(s_rdata),
    .s_rresp(s_rresp)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      start_pulse_count <= 0;
      clear_a_count     <= 0;
      clear_b_count     <= 0;
      clear_tile_count  <= 0;
    end else begin
      if (dut.u_v2b.reg_start_pulse)    start_pulse_count <= start_pulse_count + 1;
      if (dut.u_v2b.reg_buf_clear_a)    clear_a_count     <= clear_a_count + 1;
      if (dut.u_v2b.reg_buf_clear_b)    clear_b_count     <= clear_b_count + 1;
      if (dut.u_v2b.reg_buf_clear_tile) clear_tile_count  <= clear_tile_count + 1;
    end
  end

  task automatic report_check;
    input [255:0] label;
    input cond;
    input [31:0] got;
    input [31:0] exp;
    begin
      if (cond) begin
        $display("[PASS] %0s got=0x%08h", label, got);
        pass_count = pass_count + 1;
      end else begin
        $display("[FAIL] %0s got=0x%08h exp=0x%08h", label, got, exp);
        fail_count = fail_count + 1;
      end
    end
  endtask

  task automatic report_resp;
    input [31:0] addr;
    input [1:0] got;
    input [1:0] exp;
    begin
      if (got === exp) begin
        $display("[PASS] AXI resp addr=0x%08h resp=%0b", addr, got);
        pass_count = pass_count + 1;
      end else begin
        $display("[FAIL] AXI resp addr=0x%08h resp=%0b exp=%0b", addr, got, exp);
        fail_count = fail_count + 1;
      end
    end
  endtask

  task automatic axi_write;
    input [31:0] addr;
    input [31:0] data;
    input [3:0]  strb;
    begin
      @(posedge clk);
      s_awvalid <= 1'b1;
      s_awaddr  <= addr;
      s_wvalid  <= 1'b1;
      s_wdata   <= data;
      s_wstrb   <= strb;
      s_bready  <= 1'b1;
      do @(posedge clk);
      while (!(s_awready && s_wready));
      s_awvalid <= 1'b0;
      s_wvalid  <= 1'b0;
      while (!s_bvalid) @(posedge clk);
      report_resp(addr, s_bresp, 2'b00);
      @(posedge clk);
      s_bready <= 1'b0;
    end
  endtask

  task automatic axi_read;
    input  [31:0] addr;
    output [31:0] data;
    begin
      @(posedge clk);
      s_arvalid <= 1'b1;
      s_araddr  <= addr;
      s_rready  <= 1'b1;
      do @(posedge clk);
      while (!s_arready);
      s_arvalid <= 1'b0;
      while (!s_rvalid) @(posedge clk);
      data = s_rdata;
      report_resp(addr, s_rresp, 2'b00);
      @(posedge clk);
      s_rready <= 1'b0;
    end
  endtask

  initial begin
    $display("[TB] v2b_axi_partial_write_tb start");

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);

    // T1: direct read/write register must merge byte0 only.
    axi_write(v2b_addr(O_STAGE_CFG1), 32'hA1B2_C3D4, 4'hF);
    axi_write(v2b_addr(O_STAGE_CFG1), 32'h0000_00EE, 4'b0001);
    axi_read(v2b_addr(O_STAGE_CFG1), rd_data);
    report_check("T1 CFG1 byte0 merge", rd_data === 32'hA1B2_C3EE, rd_data, 32'hA1B2_C3EE);

    // T2: middle-byte write must preserve untouched bytes.
    axi_write(v2b_addr(O_STAGE_CFG0), 32'h1122_3344, 4'hF);
    axi_write(v2b_addr(O_STAGE_CFG0), 32'h00AA_0000, 4'b0100);
    axi_read(v2b_addr(O_STAGE_CFG0), rd_data);
    report_check("T2 CFG0 byte2 merge", rd_data === 32'h11AA_3344, rd_data, 32'h11AA_3344);

    // T3: staged INPUT_SRAM word must preserve non-strobed bytes.
    axi_write(v2b_addr(O_INPUT_SRAM_W0), 32'hDEAD_BEEF, 4'hF);
    axi_write(v2b_addr(O_INPUT_SRAM_W0), 32'h0000_6600, 4'b0010);
    rd_data = dut.u_v2b.reg_isram_w0;
    report_check("T3 INPUT_SRAM_W0 byte1 merge", rd_data === 32'hDEAD_66EF, rd_data, 32'hDEAD_66EF);

    // T4: narrower INPUT_SRAM_ADDR field must keep old byte0 when only byte1 is strobed.
    axi_write(v2b_addr(O_INPUT_SRAM_ADDR), 32'h0000_005A, 4'hF);
    axi_write(v2b_addr(O_INPUT_SRAM_ADDR), 32'h0000_1200, 4'b0010);
    rd_data = dut.u_v2b.reg_isram_addr;
    report_check("T4 INPUT_SRAM_ADDR keep byte0", rd_data === 32'h0000_005A, rd_data, 32'h0000_005A);

    // T5: MAC_W_LOAD_ADDR must merge i/j bytes independently.
    axi_write(v2b_addr(O_MAC_W_LOAD_ADDR), 32'h0000_0000, 4'hF);
    axi_write(v2b_addr(O_MAC_W_LOAD_ADDR), 32'h0000_0012, 4'b0001);
    axi_write(v2b_addr(O_MAC_W_LOAD_ADDR), 32'h0000_3400, 4'b0010);
    rd_data = {18'h0, dut.u_v2b.reg_w_load_j, dut.u_v2b.reg_w_load_i};
    report_check("T5 MAC_W_LOAD_ADDR byte merge", rd_data === 32'h0000_3412, rd_data, 32'h0000_3412);

    // T6: byte1-only write must not fire byte0 W1P clear pulses.
    clear_a_before    = clear_a_count;
    clear_b_before    = clear_b_count;
    clear_tile_before = clear_tile_count;
    axi_write(v2b_addr(O_STREAM_BUF_CTRL), 32'h0000_0206, 4'b0010);
    @(posedge clk);
    rd_data = {29'h0,
               (clear_tile_count != clear_tile_before),
               (clear_b_count != clear_b_before),
               (clear_a_count != clear_a_before)};
    report_check("T6 STREAM wrong-byte no pulse", rd_data === 32'h0, rd_data, 32'h0);

    // T7: byte0 write still fires the intended pulses.
    clear_a_before    = clear_a_count;
    clear_b_before    = clear_b_count;
    clear_tile_before = clear_tile_count;
    axi_write(v2b_addr(O_STREAM_BUF_CTRL), 32'h0000_0006, 4'b0001);
    @(posedge clk);
    rd_data = {29'h0,
               (clear_tile_count != clear_tile_before),
               (clear_b_count != clear_b_before),
               (clear_a_count != clear_a_before)};
    report_check("T7 STREAM byte0 pulses", rd_data === 32'h0000_0003, rd_data, 32'h0000_0003);

    // T8: byte1-only STAGE_CTRL write must not start anything; byte0 write still can.
    start_before = start_pulse_count;
    axi_write(v2b_addr(O_STAGE_CTRL), 32'h0000_0101, 4'b0010);
    @(posedge clk);
    rd_data = start_pulse_count - start_before;
    report_check("T8 STAGE wrong-byte no start", rd_data === 32'h0, rd_data, 32'h0);

    if (fail_count == 0) begin
      $display("V2B_AXI_PARTIAL_WRITE_TB_PASS");
    end else begin
      $display("V2B_AXI_PARTIAL_WRITE_TB_FAIL (fail_count=%0d)", fail_count);
    end
    $finish;
  end

  initial begin
    #5_000_000;
    $display("V2B_AXI_PARTIAL_WRITE_TB_TIMEOUT");
    $finish;
  end

endmodule
