`timescale 1ns/1ps
//======================================================================
// fmap_sram_v2.sv
//
// V2.B CONV feature-map SRAM: ping-pong A/B banks, 32-bit word interface.
// Physical fmap streams follow the frozen 32-bit padded layout; bit-level
// extraction/insertion is owned by readers/packers, not this SRAM primitive.
//======================================================================
module fmap_sram_v2
  import snn_soc_pkg::*;
#(
  parameter int P_BANK_KIB   = V2B_CONV_FMAP_BANK_KIB,
  parameter int P_BANK_WORDS = (P_BANK_KIB * 1024) / 4,
  parameter int P_ADDR_W     = $clog2(P_BANK_WORDS)
) (
  input  logic clk,
  input  logic rst_n,

  // 0: read bank A, 1: read bank B. Write bank is explicitly selected.
  input  logic        bank_sel_pp,

  input  logic        rd_en,
  input  logic [31:0] rd_word_addr,
  output logic [31:0] rd_data,

  input  logic        wr_en,
  input  logic        wr_bank_sel,
  input  logic [31:0] wr_word_addr,
  input  logic [31:0] wr_data,
  input  logic [3:0]  wr_strb,
  output logic        addr_oob
);

  logic wr_in_range;
  logic rd_in_range;
  logic [P_ADDR_W-1:0] wr_addr_idx;
  logic [P_ADDR_W-1:0] rd_addr_idx;

  assign wr_in_range = (wr_word_addr < P_BANK_WORDS);
  assign rd_in_range = (rd_word_addr < P_BANK_WORDS);
  assign addr_oob    = wr_en && !wr_in_range;
  assign wr_addr_idx = wr_word_addr[P_ADDR_W-1:0];
  assign rd_addr_idx = rd_word_addr[P_ADDR_W-1:0];

`ifdef SYNTHESIS
  logic [31:0] rd_data_a;
  logic [31:0] rd_data_b;
  logic        rd_bank_q;
  logic        rd_oob_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_bank_q <= 1'b0;
      rd_oob_q  <= 1'b1;
    end else if (rd_en) begin
      rd_bank_q <= bank_sel_pp;
      rd_oob_q  <= !rd_in_range;
    end
  end

  assign rd_data = rd_oob_q ? 32'h0 : (rd_bank_q ? rd_data_b : rd_data_a);

  // Synthesis-only BRAM implementation. Plain RTL arrays for these large
  // banks were inferred as LUTRAM by Vivado 2022.2, so use XPM to keep the
  // FPGA implementation aligned with the frozen BRAM resource model.
  xpm_memory_sdpram #(
    .ADDR_WIDTH_A(P_ADDR_W),
    .ADDR_WIDTH_B(P_ADDR_W),
    .AUTO_SLEEP_TIME(0),
    .BYTE_WRITE_WIDTH_A(8),
    .CASCADE_HEIGHT(0),
    .CLOCKING_MODE("common_clock"),
    .ECC_MODE("no_ecc"),
    .MEMORY_INIT_FILE("none"),
    .MEMORY_INIT_PARAM("0"),
    .MEMORY_OPTIMIZATION("true"),
    .MEMORY_PRIMITIVE("block"),
    .MEMORY_SIZE(P_BANK_WORDS * 32),
    .MESSAGE_CONTROL(0),
    .READ_DATA_WIDTH_B(32),
    .READ_LATENCY_B(1),
    .READ_RESET_VALUE_B("0"),
    .RST_MODE_A("SYNC"),
    .RST_MODE_B("SYNC"),
    .SIM_ASSERT_CHK(0),
    .USE_EMBEDDED_CONSTRAINT(0),
    .USE_MEM_INIT(0),
    .WAKEUP_TIME("disable_sleep"),
    .WRITE_DATA_WIDTH_A(32),
    .WRITE_MODE_B("read_first")
  ) u_bank_a_xpm (
    .clka(clk),
    .ena(wr_en && wr_in_range && !wr_bank_sel),
    .wea((wr_en && wr_in_range && !wr_bank_sel) ? wr_strb : 4'b0000),
    .addra(wr_addr_idx),
    .dina(wr_data),
    .injectdbiterra(1'b0),
    .injectsbiterra(1'b0),
    .clkb(clk),
    .enb(rd_en && rd_in_range && !bank_sel_pp),
    .addrb(rd_addr_idx),
    .doutb(rd_data_a),
    .regceb(1'b1),
    .rstb(!rst_n),
    .sleep(1'b0),
    .dbiterrb(),
    .sbiterrb()
  );

  xpm_memory_sdpram #(
    .ADDR_WIDTH_A(P_ADDR_W),
    .ADDR_WIDTH_B(P_ADDR_W),
    .AUTO_SLEEP_TIME(0),
    .BYTE_WRITE_WIDTH_A(8),
    .CASCADE_HEIGHT(0),
    .CLOCKING_MODE("common_clock"),
    .ECC_MODE("no_ecc"),
    .MEMORY_INIT_FILE("none"),
    .MEMORY_INIT_PARAM("0"),
    .MEMORY_OPTIMIZATION("true"),
    .MEMORY_PRIMITIVE("block"),
    .MEMORY_SIZE(P_BANK_WORDS * 32),
    .MESSAGE_CONTROL(0),
    .READ_DATA_WIDTH_B(32),
    .READ_LATENCY_B(1),
    .READ_RESET_VALUE_B("0"),
    .RST_MODE_A("SYNC"),
    .RST_MODE_B("SYNC"),
    .SIM_ASSERT_CHK(0),
    .USE_EMBEDDED_CONSTRAINT(0),
    .USE_MEM_INIT(0),
    .WAKEUP_TIME("disable_sleep"),
    .WRITE_DATA_WIDTH_A(32),
    .WRITE_MODE_B("read_first")
  ) u_bank_b_xpm (
    .clka(clk),
    .ena(wr_en && wr_in_range && wr_bank_sel),
    .wea((wr_en && wr_in_range && wr_bank_sel) ? wr_strb : 4'b0000),
    .addra(wr_addr_idx),
    .dina(wr_data),
    .injectdbiterra(1'b0),
    .injectsbiterra(1'b0),
    .clkb(clk),
    .enb(rd_en && rd_in_range && bank_sel_pp),
    .addrb(rd_addr_idx),
    .doutb(rd_data_b),
    .regceb(1'b1),
    .rstb(!rst_n),
    .sleep(1'b0),
    .dbiterrb(),
    .sbiterrb()
  );

`else
  (* ram_style = "block" *) logic [31:0] bank_a [0:P_BANK_WORDS-1];
  (* ram_style = "block" *) logic [31:0] bank_b [0:P_BANK_WORDS-1];

  always_ff @(posedge clk) begin
    if (wr_en && wr_in_range) begin
      if (!wr_bank_sel) begin
        if (wr_strb[0]) bank_a[wr_addr_idx][7:0]   <= wr_data[7:0];
        if (wr_strb[1]) bank_a[wr_addr_idx][15:8]  <= wr_data[15:8];
        if (wr_strb[2]) bank_a[wr_addr_idx][23:16] <= wr_data[23:16];
        if (wr_strb[3]) bank_a[wr_addr_idx][31:24] <= wr_data[31:24];
      end else begin
        if (wr_strb[0]) bank_b[wr_addr_idx][7:0]   <= wr_data[7:0];
        if (wr_strb[1]) bank_b[wr_addr_idx][15:8]  <= wr_data[15:8];
        if (wr_strb[2]) bank_b[wr_addr_idx][23:16] <= wr_data[23:16];
        if (wr_strb[3]) bank_b[wr_addr_idx][31:24] <= wr_data[31:24];
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_data <= 32'h0;
    end else if (rd_en) begin
      if (!rd_in_range) begin
        rd_data <= 32'h0;
      end else if (!bank_sel_pp) begin
        rd_data <= bank_a[rd_addr_idx];
      end else begin
        rd_data <= bank_b[rd_addr_idx];
      end
    end
  end
`endif

`ifndef SYNTHESIS
`ifdef VCS
  // SVA_FMAP_WR_OOB_NO_WRITE is structurally implemented by wr_in_range
  // gating all bank writes. These assertions document the intended guard.
  property SVA_FMAP_WORD_ADDR_IN_RANGE;
    @(posedge clk) disable iff (!rst_n)
      rd_en |-> (rd_word_addr < P_BANK_WORDS);
  endproperty
  assert property (SVA_FMAP_WORD_ADDR_IN_RANGE);

  property SVA_FMAP_NO_CROSS_BANK_WRITE_A;
    @(posedge clk) disable iff (!rst_n)
      (wr_en && wr_in_range && !wr_bank_sel) |-> $stable(bank_b[wr_addr_idx]);
  endproperty
  assert property (SVA_FMAP_NO_CROSS_BANK_WRITE_A);
`endif
`endif

endmodule
