`timescale 1ns/1ps
//======================================================================
// tb/v2b_partial_write_invariant_tb.sv
//
// Permanent regression gate for the WSTRB byte-mask invariant in
// rtl/top/snn_soc_v2b_top.sv.
//
// Origin:
//   feature/v2-arm-fpga-demo audit, GPT F1 (RE-BURN: YES). The full AXI
//   path TB lives at tb/v2b_axi_partial_write_tb.sv on v2-arm-fpga-demo;
//   that TB needs the AXI plumbing stack (axi2simple_bridge,
//   simple2v2btop_adapter, v2b_axi_wrapper). This stripped-down TB drives
//   snn_soc_v2b_top.cmd_* directly so the same byte-mask invariant is
//   guarded on branches that don't carry the AXI stack (v2,
//   feature/v2-fpga-e203, etc).
//
// Invariants tested (must all PASS on a fixed RTL; any FAIL means
// snn_soc_v2b_top regressed back to ignoring cmd_wstrb):
//   T1 STAGE_CTRL byte1-only write must NOT trigger START W1P
//   T2 STAGE_CTRL byte0 write with wdata[0]=1 MUST trigger START W1P
//   T3 STAGE_CFG1 byte-merge keeps untouched bytes
//   T4 STAGE_CFG0 byte-mask preserves the unwritten half-word
//   T5 STREAM_BUF_CTRL byte1-only write does NOT fire byte0 pulses
//   T6 STREAM_BUF_CTRL byte0 write with wdata[1..3]=1 fires the pulses
//
// On the pre-fix RTL (v2-arm-fpga-demo-passed @ 8e51ae27), T1/T3/T4/T5
// fail; on the post-fix RTL all six PASS.
//======================================================================
module v2b_partial_write_invariant_tb;

  import snn_soc_pkg::*;

  // 4 KB window addresses (cmd_addr[11:0])
  localparam logic [11:0] O_STAGE_CTRL      = 12'h000;
  localparam logic [11:0] O_STAGE_CFG0      = 12'h008;
  localparam logic [11:0] O_STAGE_CFG1      = 12'h00C;
  localparam logic [11:0] O_STREAM_BUF_CTRL = 12'h060;
  localparam logic [11:0] O_CONV_MODE_CFG      = 12'h084;
  localparam logic [11:0] O_CONV_CFG_HW        = 12'h088;
  localparam logic [11:0] O_CONV_CFG_C         = 12'h08C;
  localparam logic [11:0] O_CONV_CFG_K_S_P     = 12'h090;
  localparam logic [11:0] O_CONV_CFG_OUT_HW    = 12'h094;
  localparam logic [11:0] O_CONV_CFG_T         = 12'h098;
  localparam logic [11:0] O_CONV_CFG_TILE      = 12'h09C;
  localparam logic [11:0] O_CONV_CFG_FMAP_BASE = 12'h0A0;
  localparam logic [11:0] O_CONV_CFG_OUT_BASE  = 12'h0A4;
  localparam logic [11:0] O_CONV_CTRL          = 12'h0A8;
  localparam logic [11:0] O_CONV_STATUS        = 12'h0AC;
  localparam logic [11:0] O_CONV_FMAP_WR_DATA  = 12'h0B0;
  localparam logic [11:0] O_CONV_FMAP_WR_ADDR  = 12'h0B4;
  localparam logic [11:0] O_CONV_FMAP_WR_CTRL  = 12'h0BC;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // simple_bus directly into snn_soc_v2b_top
  logic        cmd_valid = 1'b0;
  logic        cmd_ready;
  logic [11:0] cmd_addr  = '0;
  logic        cmd_write = 1'b0;
  logic [31:0] cmd_wdata = '0;
  logic [3:0]  cmd_wstrb = 4'h0;
  logic        rsp_valid;
  logic [31:0] rsp_rdata;

  integer pass_count = 0;
  integer fail_count = 0;
  integer start_pulse_count = 0;
  integer clear_a_count = 0;
  integer clear_b_count = 0;
  integer clear_tile_count = 0;
  integer conv_start_count = 0;
  integer conv_abort_count = 0;
  integer conv_weight_ready_count = 0;
  integer conv_fmap_commit_count = 0;

  snn_soc_v2b_top #(
    .P_ENABLE_TILE_BUF(1'b1),
    .P_ADC_BITS(10)
  ) dut (
    .clk        (clk),
    .rst_n      (rst_n),
    .cmd_valid  (cmd_valid),
    .cmd_ready  (cmd_ready),
    .cmd_addr   (cmd_addr),
    .cmd_write  (cmd_write),
    .cmd_wdata  (cmd_wdata),
    .cmd_wstrb  (cmd_wstrb),
    .rsp_valid  (rsp_valid),
    .rsp_rdata  (rsp_rdata)
  );

  // Probe internal pulses to detect spurious W1P firing
  always @(posedge clk) begin
    if (rst_n) begin
      if (dut.reg_start_pulse)        start_pulse_count <= start_pulse_count + 1;
      if (dut.reg_buf_clear_a)        clear_a_count     <= clear_a_count + 1;
      if (dut.reg_buf_clear_b)        clear_b_count     <= clear_b_count + 1;
      if (dut.reg_buf_clear_tile)     clear_tile_count  <= clear_tile_count + 1;
      if (dut.reg_conv_start_pulse)   conv_start_count  <= conv_start_count + 1;
      if (dut.reg_conv_abort_pulse)   conv_abort_count  <= conv_abort_count + 1;
      if (dut.reg_conv_weight_ready_pulse)
        conv_weight_ready_count <= conv_weight_ready_count + 1;
      if (dut.reg_conv_fmap_wr_commit_pulse)
        conv_fmap_commit_count <= conv_fmap_commit_count + 1;
    end
  end

  task automatic do_write(input logic [11:0] addr,
                          input logic [31:0] wdata,
                          input logic [3:0]  wstrb);
    @(posedge clk);
    cmd_valid = 1'b1;
    cmd_write = 1'b1;
    cmd_addr  = addr;
    cmd_wdata = wdata;
    cmd_wstrb = wstrb;
    @(posedge clk);
    while (!cmd_ready) @(posedge clk);
    cmd_valid = 1'b0;
    cmd_write = 1'b0;
    cmd_wstrb = 4'h0;
    @(posedge clk);
  endtask

  task automatic do_read(input logic [11:0] addr,
                         output logic [31:0] data);
    @(posedge clk);
    cmd_valid = 1'b1;
    cmd_write = 1'b0;
    cmd_addr  = addr;
    cmd_wstrb = 4'h0;
    @(posedge clk);
    while (!cmd_ready) @(posedge clk);
    cmd_valid = 1'b0;
    while (!rsp_valid) @(posedge clk);
    data = rsp_rdata;
    @(posedge clk);
  endtask

  task automatic check32(input string tag,
                         input logic [31:0] got,
                         input logic [31:0] exp);
    if (got === exp) begin
      $display("[PASS] %s got=0x%08h", tag, got);
      pass_count = pass_count + 1;
    end else begin
      $display("[FAIL] %s got=0x%08h exp=0x%08h", tag, got, exp);
      fail_count = fail_count + 1;
    end
  endtask

  task automatic check_int(input string tag,
                           input integer got,
                           input integer exp);
    if (got === exp) begin
      $display("[PASS] %s got=%0d", tag, got);
      pass_count = pass_count + 1;
    end else begin
      $display("[FAIL] %s got=%0d exp=%0d", tag, got, exp);
      fail_count = fail_count + 1;
    end
  endtask

  task automatic check_conv_rw_matrix(input string tag,
                                      input logic [11:0] addr);
    logic [31:0] rd;
    begin
      do_write(addr, 32'h11223344, 4'b1111);
      do_write(addr, 32'h000000AA, 4'b0001);
      do_read(addr, rd);
      check32({tag, " byte0 merge"}, rd, 32'h112233AA);

      do_write(addr, 32'h11223344, 4'b1111);
      do_write(addr, 32'h0000BB00, 4'b0010);
      do_read(addr, rd);
      check32({tag, " byte1 merge"}, rd, 32'h1122BB44);

      do_write(addr, 32'h11223344, 4'b1111);
      do_write(addr, 32'h00CC0000, 4'b0100);
      do_read(addr, rd);
      check32({tag, " byte2 merge"}, rd, 32'h11CC3344);

      do_write(addr, 32'h11223344, 4'b1111);
      do_write(addr, 32'hDD000000, 4'b1000);
      do_read(addr, rd);
      check32({tag, " byte3 merge"}, rd, 32'hDD223344);
    end
  endtask

  function automatic integer get_conv_pulse_count(input integer kind);
    begin
      case (kind)
        0: get_conv_pulse_count = conv_start_count;
        1: get_conv_pulse_count = conv_abort_count;
        2: get_conv_pulse_count = conv_weight_ready_count;
        default: get_conv_pulse_count = 0;
      endcase
    end
  endfunction

  task automatic reset_conv_pulse_count(input integer kind);
    begin
      case (kind)
        0: conv_start_count = 0;
        1: conv_abort_count = 0;
        2: conv_weight_ready_count = 0;
        default: ;
      endcase
    end
  endtask

  task automatic check_conv_ctrl_w1p(input string tag,
                                     input logic [31:0] bit_mask,
                                     input integer kind);
    begin
      reset_conv_pulse_count(kind);
      do_write(O_CONV_CTRL, bit_mask, 4'b0010);
      repeat (3) @(posedge clk);
      check_int({tag, " byte1 no pulse"}, get_conv_pulse_count(kind), 0);
      reset_conv_pulse_count(kind);
      do_write(O_CONV_CTRL, bit_mask, 4'b0100);
      repeat (3) @(posedge clk);
      check_int({tag, " byte2 no pulse"}, get_conv_pulse_count(kind), 0);
      reset_conv_pulse_count(kind);
      do_write(O_CONV_CTRL, bit_mask, 4'b1000);
      repeat (3) @(posedge clk);
      check_int({tag, " byte3 no pulse"}, get_conv_pulse_count(kind), 0);
      reset_conv_pulse_count(kind);
      do_write(O_CONV_CTRL, bit_mask, 4'b0001);
      repeat (3) @(posedge clk);
      check_int({tag, " byte0 fires"}, get_conv_pulse_count(kind), 1);
    end
  endtask

  initial begin
    $display("[INFO] v2b_partial_write_invariant_tb start");
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // Seed CFG1 with a known full-word
    do_write(O_STAGE_CFG1, 32'hAABBCCDD, 4'b1111);

    // ─── T1 STAGE_CTRL byte1-only write must NOT trigger START ─────
    // wstrb=4'b0010, wdata[0]=1. Pre-fix RTL ignored wstrb -> START fires.
    // Post-fix gate by cmd_wstrb[0] -> no pulse.
    start_pulse_count = 0;
    do_write(O_STAGE_CTRL, 32'h0000_0001, 4'b0010);
    repeat (3) @(posedge clk);
    check_int("T1 STAGE_CTRL byte1-only must not fire START",
              start_pulse_count, 0);

    // ─── T2 STAGE_CTRL byte0 write with wdata[0]=1 MUST trigger ────
    start_pulse_count = 0;
    do_write(O_STAGE_CTRL, 32'h0000_0001, 4'b0001);
    repeat (3) @(posedge clk);
    check_int("T2 STAGE_CTRL byte0 START W1P fires",
              start_pulse_count, 1);

    // ─── T3 STAGE_CFG1 byte-merge keeps untouched bytes ───────────
    // Re-seed then partial-write byte0 only.
    do_write(O_STAGE_CFG1, 32'hAABBCCDD, 4'b1111);
    do_write(O_STAGE_CFG1, 32'h0000_00EE, 4'b0001);
    begin : t3_check
      logic [31:0] rd;
      do_read(O_STAGE_CFG1, rd);
      check32("T3 CFG1 byte0 merge keeps high bytes",
              rd, 32'hAABBCCEE);
    end

    // ─── T4 STAGE_CFG0 byte-mask preserves unwritten half-word ────
    do_write(O_STAGE_CFG0, 32'h11223344, 4'b1111);
    do_write(O_STAGE_CFG0, 32'h00AA0000, 4'b0100);
    begin : t4_check
      logic [31:0] rd;
      do_read(O_STAGE_CFG0, rd);
      check32("T4 CFG0 byte2 merge keeps low/high bytes",
              rd, 32'h11AA3344);
    end

    // ─── T5 STREAM_BUF_CTRL byte1-only must NOT fire byte0 pulses ─
    clear_a_count = 0;
    clear_b_count = 0;
    clear_tile_count = 0;
    // wdata[3:1]=111 but wstrb says only byte1 is being written
    do_write(O_STREAM_BUF_CTRL, 32'h0000_000E, 4'b0010);
    repeat (3) @(posedge clk);
    check_int("T5 STREAM byte1-only no clear_a", clear_a_count, 0);
    check_int("T5 STREAM byte1-only no clear_b", clear_b_count, 0);
    check_int("T5 STREAM byte1-only no clear_tile", clear_tile_count, 0);

    // ─── T6 STREAM_BUF_CTRL byte0 write fires pulses ──────────────
    clear_a_count = 0;
    clear_b_count = 0;
    clear_tile_count = 0;
    do_write(O_STREAM_BUF_CTRL, 32'h0000_000E, 4'b0001);
    repeat (3) @(posedge clk);
    check_int("T6 STREAM byte0 wdata[1] fires clear_a", clear_a_count, 1);
    check_int("T6 STREAM byte0 wdata[2] fires clear_b", clear_b_count, 1);
    check_int("T6 STREAM byte0 wdata[3] fires clear_tile", clear_tile_count, 1);

    // ─── T7 CONV ordinary RW registers: 10 offsets × 4 strobes ─────
    check_conv_rw_matrix("T7 CONV_CFG_HW",        O_CONV_CFG_HW);
    check_conv_rw_matrix("T7 CONV_CFG_C",         O_CONV_CFG_C);
    check_conv_rw_matrix("T7 CONV_CFG_OUT_HW",    O_CONV_CFG_OUT_HW);
    check_conv_rw_matrix("T7 CONV_CFG_TILE",      O_CONV_CFG_TILE);
    check_conv_rw_matrix("T7 CONV_CFG_FMAP_BASE", O_CONV_CFG_FMAP_BASE);
    check_conv_rw_matrix("T7 CONV_CFG_OUT_BASE",  O_CONV_CFG_OUT_BASE);
    check_conv_rw_matrix("T7 CONV_FMAP_WR_DATA",  O_CONV_FMAP_WR_DATA);
    check_conv_rw_matrix("T7 CONV_FMAP_WR_ADDR",  O_CONV_FMAP_WR_ADDR);

    do_write(O_CONV_CFG_K_S_P, 32'h11223344, 4'b1111);
    do_write(O_CONV_CFG_K_S_P, 32'h000000AA, 4'b0001);
    begin : t7_ksp_b0 logic [31:0] rd; do_read(O_CONV_CFG_K_S_P, rd);
      check32("T7 CONV_CFG_K_S_P byte0 merge", rd, 32'h000003AA); end
    do_write(O_CONV_CFG_K_S_P, 32'h11223344, 4'b1111);
    do_write(O_CONV_CFG_K_S_P, 32'h0000BB00, 4'b0010);
    begin : t7_ksp_b1 logic [31:0] rd; do_read(O_CONV_CFG_K_S_P, rd);
      check32("T7 CONV_CFG_K_S_P byte1 merge", rd, 32'h00000B44); end
    do_write(O_CONV_CFG_K_S_P, 32'h11223344, 4'b1111);
    do_write(O_CONV_CFG_K_S_P, 32'h00CC0000, 4'b0100);
    begin : t7_ksp_b2 logic [31:0] rd; do_read(O_CONV_CFG_K_S_P, rd);
      check32("T7 CONV_CFG_K_S_P byte2 ignored", rd, 32'h00000344); end
    do_write(O_CONV_CFG_K_S_P, 32'h11223344, 4'b1111);
    do_write(O_CONV_CFG_K_S_P, 32'hDD000000, 4'b1000);
    begin : t7_ksp_b3 logic [31:0] rd; do_read(O_CONV_CFG_K_S_P, rd);
      check32("T7 CONV_CFG_K_S_P byte3 ignored", rd, 32'h00000344); end

    do_write(O_CONV_CFG_T, 32'h11223344, 4'b1111);
    do_write(O_CONV_CFG_T, 32'h000000AA, 4'b0001);
    begin : t7_t_b0 logic [31:0] rd; do_read(O_CONV_CFG_T, rd);
      check32("T7 CONV_CFG_T byte0 merge", rd, 32'h000033AA); end
    do_write(O_CONV_CFG_T, 32'h11223344, 4'b1111);
    do_write(O_CONV_CFG_T, 32'h0000BB00, 4'b0010);
    begin : t7_t_b1 logic [31:0] rd; do_read(O_CONV_CFG_T, rd);
      check32("T7 CONV_CFG_T byte1 merge", rd, 32'h0000BB44); end
    do_write(O_CONV_CFG_T, 32'h11223344, 4'b1111);
    do_write(O_CONV_CFG_T, 32'h00CC0000, 4'b0100);
    begin : t7_t_b2 logic [31:0] rd; do_read(O_CONV_CFG_T, rd);
      check32("T7 CONV_CFG_T byte2 ignored", rd, 32'h00003344); end
    do_write(O_CONV_CFG_T, 32'h11223344, 4'b1111);
    do_write(O_CONV_CFG_T, 32'hDD000000, 4'b1000);
    begin : t7_t_b3 logic [31:0] rd; do_read(O_CONV_CFG_T, rd);
      check32("T7 CONV_CFG_T byte3 ignored", rd, 32'h00003344); end

    // ─── T8 CONV_MODE_CFG byte mask updates only byte0 fields ──────
    do_write(O_CONV_MODE_CFG, 32'h0000_0000, 4'b1111);
    do_write(O_CONV_MODE_CFG, 32'h0000_000F, 4'b0010);
    begin : t8a
      logic [31:0] rd;
      do_read(O_CONV_MODE_CFG, rd);
      check32("T8 MODE byte1 no low-bit pollution", rd, 32'h0000_0000);
    end
    do_write(O_CONV_MODE_CFG, 32'h0000_000F, 4'b0001);
    begin : t8b
      logic [31:0] rd;
      do_read(O_CONV_MODE_CFG, rd);
      check32("T8 MODE byte0 updates low fields", rd, 32'h0000_000F);
    end

    // ─── T9 CONV_CTRL W1P: START/ABORT/WEIGHT_READY byte0 only ────
    check_conv_ctrl_w1p("T9 CONV_CTRL.START", 32'h0000_0001, 0);
    check_conv_ctrl_w1p("T9 CONV_CTRL.ABORT", 32'h0000_0002, 1);
    check_conv_ctrl_w1p("T9 CONV_CTRL.WEIGHT_READY", 32'h0000_0004,
                        2);

    // ─── T10 CONV_FMAP_WR_CTRL WR_COMMIT byte0 only ───────────────
    conv_fmap_commit_count = 0;
    do_write(O_CONV_FMAP_WR_CTRL, 32'h0000_0001, 4'b0010);
    repeat (3) @(posedge clk);
    check_int("T10 FMAP_WR_CTRL byte1 no commit", conv_fmap_commit_count, 0);
    conv_fmap_commit_count = 0;
    do_write(O_CONV_FMAP_WR_CTRL, 32'h0000_0001, 4'b0001);
    repeat (3) @(posedge clk);
    check_int("T10 FMAP_WR_CTRL byte0 commit fires", conv_fmap_commit_count, 1);

    // ─── T11 CONV_STATUS DONE W1C byte0 only ──────────────────────
    do_write(O_CONV_FMAP_WR_ADDR, 32'h0001_0000, 4'b1111);
    do_write(O_CONV_FMAP_WR_CTRL, 32'h0000_0001, 4'b0001);
    repeat (20) @(posedge clk);
    do_write(O_CONV_STATUS, 32'h0000_0002, 4'b0010);
    repeat (3) @(posedge clk);
    begin : t11b
      logic [31:0] rd;
      do_read(O_CONV_STATUS, rd);
      check32("T11 STATUS byte1 write does not clear DONE", rd & 32'h2, 32'h2);
    end
    do_write(O_CONV_STATUS, 32'h0000_0002, 4'b0001);
    repeat (3) @(posedge clk);
    begin : t11c
      logic [31:0] rd;
      do_read(O_CONV_STATUS, rd);
      check32("T11 STATUS byte0 W1C clears DONE", rd & 32'h2, 32'h0);
    end

    // ─── Result ────────────────────────────────────────────────────
    repeat (5) @(posedge clk);
    $display("");
    $display("=== Results: %0d PASS, %0d FAIL ===", pass_count, fail_count);
    if (fail_count == 0) begin
      $display("V2B_PARTIAL_WRITE_INVARIANT_TB_PASS");
    end else begin
      $display("V2B_PARTIAL_WRITE_INVARIANT_TB_FAIL (fail_count=%0d)", fail_count);
    end
    $finish;
  end

  initial begin
    #200000;
    $display("[ERROR] timeout");
    $display("V2B_PARTIAL_WRITE_INVARIANT_TB_FAIL (timeout)");
    $finish;
  end

endmodule
