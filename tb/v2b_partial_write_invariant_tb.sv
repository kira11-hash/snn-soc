`timescale 1ns/1ps
//======================================================================
// tb/v2b_partial_write_invariant_tb.sv
//
// Permanent regression gate for the WSTRB byte-mask invariant in
// rtl/top/snn_soc_v2b_top.sv.
//
// Origin:
//   feature/v2-arm-fpga-demo audit, GPT F1 (RE-BURN: YES). The full AXI
//   path TB lives at tb/v2b_axi_partial_write_tb.sv and proves PS-facing
//   WSTRB propagation through v2b_axi_wrapper. This stripped-down TB drives
//   snn_soc_v2b_top.cmd_* directly so the core W1P/W1C byte-mask invariant
//   remains guarded independently of any wrapper or bus-stack changes.
//
// Invariants tested (must all PASS on a fixed RTL; any FAIL means
// snn_soc_v2b_top regressed back to ignoring cmd_wstrb):
//   T1 STAGE_CTRL byte1-only write must NOT trigger START W1P
//   T2 STAGE_CTRL byte0 write with wdata[0]=1 MUST trigger START W1P
//   T3 STAGE_CFG1 byte-merge keeps untouched bytes
//   T4 STAGE_CFG0 byte-mask preserves the unwritten half-word
//   T5 STREAM_BUF_CTRL byte1-only write does NOT fire byte0 pulses
//   T6 STREAM_BUF_CTRL byte0 write with wdata[1..3]=1 fires the pulses
//   T7 STAGE_CTRL byte1-only write must NOT clear DONE W1C
//   T8 STAGE_CTRL byte0 write with wdata[7]=1 MUST clear DONE W1C
//
// B2 扩展（2026-05-02）：CONV register byte-mask 守口（覆盖 0x084-0x0BC 段）
//   T9  CONV_CTRL byte1-only 不得触发 START / ABORT / WEIGHT_READY W1P
//   T10 CONV_CTRL byte0 wdata[0]=1 触发 reg_conv_start_pulse
//   T11 CONV_CTRL byte0 wdata[1]=1 触发 reg_conv_abort_pulse
//   T12 CONV_CTRL byte0 wdata[2]=1 触发 reg_conv_weight_ready_pulse
//   T13 CONV_STATUS byte1-only wdata[1]=1 不得清 DONE W1C
//   T14 CONV_STATUS byte0 wdata[1]=1 触发 reg_conv_done_clear_pulse
//   T15 CONV_FMAP_WR_CTRL byte1-only wdata[0]=1 不得触发 commit pulse
//   T16 CONV_FMAP_WR_CTRL byte0 wdata[0]=1 触发 reg_conv_fmap_wr_commit_pulse
//   T17 CONV_MODE_CFG byte0 部分写保留高位 byte
//   T18 CONV_CFG_HW byte slice merge 保留高半字
//   T19 CONV_CFG_C byte slice merge 保留低半字
//   T20 CONV_CFG_K_S_P byte slice merge
//   T21 CONV_CFG_OUT_HW byte slice merge
//   T22 CONV_CFG_T byte slice merge
//   T23 CONV_CFG_TILE byte slice merge
//   T24 CONV_CFG_FMAP_BASE byte slice merge
//   T25 CONV_CFG_OUT_BASE byte slice merge
//   T26 CONV_FMAP_WR_DATA byte slice merge
//   T27 CONV_FMAP_WR_ADDR byte slice merge
//   T28 CONV_FMAP_WR_CTRL 同拍写 AUTO_INC+COMMIT 时，本次 commit 后地址必须 +1
//   T29 CONV_FMAP_WR_CTRL 同拍清 AUTO_INC+COMMIT 时，本次 commit 后地址不得 +1
//
// On the pre-fix RTL (v2-arm-fpga-demo-passed @ 8e51ae27), T1/T3/T4/T5
// fail; on the post-fix RTL all invariant checks PASS. The B2 cases above
// must also PASS — any FAIL means the CONV register decode lost its
// apply_wstrb() guard or W1P/W1C bits stopped honoring wstrb[0].
//======================================================================
module v2b_partial_write_invariant_tb;

  import snn_soc_pkg::*;

  // 4 KB window addresses (cmd_addr[11:0])
  localparam logic [11:0] O_STAGE_CTRL      = 12'h000;
  localparam logic [11:0] O_STAGE_CFG0      = 12'h008;
  localparam logic [11:0] O_STAGE_CFG1      = 12'h00C;
  localparam logic [11:0] O_STREAM_BUF_CTRL = 12'h060;
  // B2 扩展：CONV 段（与 snn_soc_v2b_top.sv 的 A_CONV_* localparam 同步）
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
  // M1 trace-hash recorder offsets (Day Wed integration; 8 writable +
  // 2 RO smoke pattern per Codex Day Tue review prereq #3)
  localparam logic [11:0] O_TRACE_HASH_CTRL        = 12'h068;
  localparam logic [11:0] O_TRACE_HASH_LOG_COUNT   = 12'h06C;
  localparam logic [11:0] O_TRACE_HASH_LOG_RD_ADDR = 12'h070;
  localparam logic [11:0] O_TRACE_HASH_LOG_RD_DATA = 12'h074;
  localparam logic [11:0] O_TRACE_HASH_LOG_RD_META = 12'h078;

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
  // B2 扩展：CONV W1P / W1C pulse 监视
  integer conv_start_pulse_count = 0;
  integer conv_abort_pulse_count = 0;
  integer conv_weight_ready_pulse_count = 0;
  integer conv_done_clear_pulse_count = 0;
  integer conv_fmap_wr_commit_pulse_count = 0;
  // M1 W1P pulse counters
  integer recorder_clear_pulse_count   = 0;
  integer recorder_rd_en_pulse_count   = 0;

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

  // Probe internal pulses to detect spurious W1P firing.
  always @(posedge clk) begin
    if (rst_n) begin
      if (dut.reg_start_pulse)    start_pulse_count <= start_pulse_count + 1;
      if (dut.reg_buf_clear_a)    clear_a_count     <= clear_a_count + 1;
      if (dut.reg_buf_clear_b)    clear_b_count     <= clear_b_count + 1;
      if (dut.reg_buf_clear_tile) clear_tile_count  <= clear_tile_count + 1;
      if (dut.reg_conv_start_pulse)
        conv_start_pulse_count        <= conv_start_pulse_count + 1;
      if (dut.reg_conv_abort_pulse)
        conv_abort_pulse_count        <= conv_abort_pulse_count + 1;
      if (dut.reg_conv_weight_ready_pulse)
        conv_weight_ready_pulse_count <= conv_weight_ready_pulse_count + 1;
      if (dut.reg_conv_done_clear_pulse)
        conv_done_clear_pulse_count   <= conv_done_clear_pulse_count + 1;
      if (dut.reg_conv_fmap_wr_commit_pulse)
        conv_fmap_wr_commit_pulse_count <= conv_fmap_wr_commit_pulse_count + 1;
      // M1 W1P pulses
      if (dut.reg_recorder_clear_pulse)
        recorder_clear_pulse_count <= recorder_clear_pulse_count + 1;
      if (dut.reg_recorder_rd_en_pulse)
        recorder_rd_en_pulse_count <= recorder_rd_en_pulse_count + 1;
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

  initial begin
    $display("[INFO] v2b_partial_write_invariant_tb start");
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // Seed CFG1 with a known full-word.
    do_write(O_STAGE_CFG1, 32'hAABBCCDD, 4'b1111);

    // T1: STAGE_CTRL byte1-only write must NOT trigger START.
    start_pulse_count = 0;
    do_write(O_STAGE_CTRL, 32'h0000_0001, 4'b0010);
    repeat (3) @(posedge clk);
    check_int("T1 STAGE_CTRL byte1-only must not fire START",
              start_pulse_count, 0);

    // T2: STAGE_CTRL byte0 write with wdata[0]=1 MUST trigger.
    start_pulse_count = 0;
    do_write(O_STAGE_CTRL, 32'h0000_0001, 4'b0001);
    repeat (3) @(posedge clk);
    check_int("T2 STAGE_CTRL byte0 START W1P fires",
              start_pulse_count, 1);

    // T3: STAGE_CFG1 byte-merge keeps untouched bytes.
    do_write(O_STAGE_CFG1, 32'hAABBCCDD, 4'b1111);
    do_write(O_STAGE_CFG1, 32'h0000_00EE, 4'b0001);
    begin : t3_check
      logic [31:0] rd;
      do_read(O_STAGE_CFG1, rd);
      check32("T3 CFG1 byte0 merge keeps high bytes",
              rd, 32'hAABBCCEE);
    end

    // T4: STAGE_CFG0 byte-mask preserves unwritten half-word.
    do_write(O_STAGE_CFG0, 32'h11223344, 4'b1111);
    do_write(O_STAGE_CFG0, 32'h00AA0000, 4'b0100);
    begin : t4_check
      logic [31:0] rd;
      do_read(O_STAGE_CFG0, rd);
      check32("T4 CFG0 byte2 merge keeps low/high bytes",
              rd, 32'h11AA3344);
    end

    // T5: STREAM_BUF_CTRL byte1-only must NOT fire byte0 pulses.
    clear_a_count = 0;
    clear_b_count = 0;
    clear_tile_count = 0;
    do_write(O_STREAM_BUF_CTRL, 32'h0000_000E, 4'b0010);
    repeat (3) @(posedge clk);
    check_int("T5 STREAM byte1-only no clear_a", clear_a_count, 0);
    check_int("T5 STREAM byte1-only no clear_b", clear_b_count, 0);
    check_int("T5 STREAM byte1-only no clear_tile", clear_tile_count, 0);

    // T6: STREAM_BUF_CTRL byte0 write fires pulses.
    clear_a_count = 0;
    clear_b_count = 0;
    clear_tile_count = 0;
    do_write(O_STREAM_BUF_CTRL, 32'h0000_000E, 4'b0001);
    repeat (3) @(posedge clk);
    check_int("T6 STREAM byte0 wdata[1] fires clear_a", clear_a_count, 1);
    check_int("T6 STREAM byte0 wdata[2] fires clear_b", clear_b_count, 1);
    check_int("T6 STREAM byte0 wdata[3] fires clear_tile", clear_tile_count, 1);

    // T7/T8: STAGE_CTRL DONE W1C must obey byte0 wstrb.
    dut.done_sticky = 1'b1;
    repeat (1) @(posedge clk);
    do_write(O_STAGE_CTRL, 32'h0000_0080, 4'b0010);
    begin : t7_check
      logic [31:0] rd;
      do_read(O_STAGE_CTRL, rd);
      check32("T7 STAGE_CTRL byte1-only must not clear DONE",
              rd & 32'h0000_0080, 32'h0000_0080);
    end

    do_write(O_STAGE_CTRL, 32'h0000_0080, 4'b0001);
    begin : t8_check
      logic [31:0] rd;
      do_read(O_STAGE_CTRL, rd);
      check32("T8 STAGE_CTRL byte0 DONE W1C clears",
              rd & 32'h0000_0080, 32'h0000_0000);
    end

    //========================================================================
    // B2 扩展（2026-05-02）：CONV register byte-mask 守口
    //========================================================================

    // ── T9: CONV_CTRL byte1-only 不得触发任何 W1P pulse ──
    conv_start_pulse_count        = 0;
    conv_abort_pulse_count        = 0;
    conv_weight_ready_pulse_count = 0;
    do_write(O_CONV_CTRL, 32'h0000_0007, 4'b0010);
    repeat (3) @(posedge clk);
    check_int("T9 CONV_CTRL byte1-only no START",
              conv_start_pulse_count, 0);
    check_int("T9 CONV_CTRL byte1-only no ABORT",
              conv_abort_pulse_count, 0);
    check_int("T9 CONV_CTRL byte1-only no WEIGHT_READY",
              conv_weight_ready_pulse_count, 0);

    // ── T10: CONV_CTRL byte0 wdata[0]=1 触发 START ──
    conv_start_pulse_count = 0;
    do_write(O_CONV_CTRL, 32'h0000_0001, 4'b0001);
    repeat (3) @(posedge clk);
    check_int("T10 CONV_CTRL byte0 wdata[0] fires START",
              conv_start_pulse_count, 1);

    // ── T11: CONV_CTRL byte0 wdata[1]=1 触发 ABORT ──
    conv_abort_pulse_count = 0;
    do_write(O_CONV_CTRL, 32'h0000_0002, 4'b0001);
    repeat (3) @(posedge clk);
    check_int("T11 CONV_CTRL byte0 wdata[1] fires ABORT",
              conv_abort_pulse_count, 1);

    // ── T12: CONV_CTRL byte0 wdata[2]=1 触发 WEIGHT_READY ──
    conv_weight_ready_pulse_count = 0;
    do_write(O_CONV_CTRL, 32'h0000_0004, 4'b0001);
    repeat (3) @(posedge clk);
    check_int("T12 CONV_CTRL byte0 wdata[2] fires WEIGHT_READY",
              conv_weight_ready_pulse_count, 1);

    // ── T13: CONV_STATUS byte1-only 不得触发 DONE_CLEAR ──
    conv_done_clear_pulse_count = 0;
    do_write(O_CONV_STATUS, 32'h0000_0002, 4'b0010);
    repeat (3) @(posedge clk);
    check_int("T13 CONV_STATUS byte1-only no DONE_CLEAR",
              conv_done_clear_pulse_count, 0);

    // ── T14: CONV_STATUS byte0 wdata[1]=1 触发 DONE_CLEAR ──
    conv_done_clear_pulse_count = 0;
    do_write(O_CONV_STATUS, 32'h0000_0002, 4'b0001);
    repeat (3) @(posedge clk);
    check_int("T14 CONV_STATUS byte0 wdata[1] fires DONE_CLEAR",
              conv_done_clear_pulse_count, 1);

    // ── T15: CONV_FMAP_WR_CTRL byte1-only 不得触发 commit pulse ──
    conv_fmap_wr_commit_pulse_count = 0;
    do_write(O_CONV_FMAP_WR_CTRL, 32'h0000_0001, 4'b0010);
    repeat (3) @(posedge clk);
    check_int("T15 CONV_FMAP_WR_CTRL byte1-only no commit",
              conv_fmap_wr_commit_pulse_count, 0);

    // ── T16: CONV_FMAP_WR_CTRL byte0 wdata[0]=1 触发 commit ──
    conv_fmap_wr_commit_pulse_count = 0;
    do_write(O_CONV_FMAP_WR_CTRL, 32'h0000_0001, 4'b0001);
    repeat (3) @(posedge clk);
    check_int("T16 CONV_FMAP_WR_CTRL byte0 wdata[0] fires commit",
              conv_fmap_wr_commit_pulse_count, 1);

    // ── T17: CONV_MODE_CFG byte0 部分写保留高位 byte ──
    do_write(O_CONV_MODE_CFG, 32'h0000_000F, 4'b0001);  // seed: all 4 bits set
    do_write(O_CONV_MODE_CFG, 32'hFF00_0000, 4'b1000);  // 写 byte3 (会被 28'h0 mask 掉)
    begin : t17_check
      logic [31:0] rd;
      do_read(O_CONV_MODE_CFG, rd);
      // RTL 把 reg_conv_mode/flatten/pp_sel/timeout_en 拼回 [3:0]，高位是 28'h0
      check32("T17 CONV_MODE_CFG byte3 write masked off (high reads as 0)",
              rd, 32'h0000_000F);
    end

    // ── T18: CONV_CFG_HW byte slice merge 保留高半字 ──
    do_write(O_CONV_CFG_HW, 32'hAABB1122, 4'b1111);
    do_write(O_CONV_CFG_HW, 32'h0000_0033, 4'b0001);
    begin : t18_check
      logic [31:0] rd;
      do_read(O_CONV_CFG_HW, rd);
      check32("T18 CONV_CFG_HW byte0 merge keeps high 24 bits",
              rd, 32'hAABB1133);
    end

    // ── T19: CONV_CFG_C byte slice merge 保留低半字 ──
    do_write(O_CONV_CFG_C, 32'hCCDD3344, 4'b1111);
    do_write(O_CONV_CFG_C, 32'hEE00_0000, 4'b1000);
    begin : t19_check
      logic [31:0] rd;
      do_read(O_CONV_CFG_C, rd);
      check32("T19 CONV_CFG_C byte3 merge keeps low 24 bits",
              rd, 32'hEEDD3344);
    end

    // ── T20: CONV_CFG_K_S_P byte slice merge ──
    do_write(O_CONV_CFG_K_S_P, 32'h0000_0FFF, 4'b1111);  // K=F, stride=F, pad=F
    do_write(O_CONV_CFG_K_S_P, 32'h0000_0007, 4'b0001);  // 仅低 byte 改成 K=7,stride=0,pad=0
    begin : t20_check
      logic [31:0] rd;
      do_read(O_CONV_CFG_K_S_P, rd);
      // RTL 仅保留 [3:0]K [7:4]stride [11:8]pad（其余 20'h0 mask）
      check32("T20 CONV_CFG_K_S_P byte0 merge keeps pad in byte1",
              rd, 32'h0000_0F07);
    end

    // ── T21: CONV_CFG_OUT_HW byte slice merge ──
    do_write(O_CONV_CFG_OUT_HW, 32'h1234_5678, 4'b1111);
    do_write(O_CONV_CFG_OUT_HW, 32'h0000_0099, 4'b0001);
    begin : t21_check
      logic [31:0] rd;
      do_read(O_CONV_CFG_OUT_HW, rd);
      check32("T21 CONV_CFG_OUT_HW byte0 merge",
              rd, 32'h1234_5699);
    end

    // ── T22: CONV_CFG_T byte slice merge ──
    do_write(O_CONV_CFG_T, 32'h0000_ABCD, 4'b1111);
    do_write(O_CONV_CFG_T, 32'h0000_00EF, 4'b0001);
    begin : t22_check
      logic [31:0] rd;
      do_read(O_CONV_CFG_T, rd);
      // RTL 高 16 bit hard-zero
      check32("T22 CONV_CFG_T byte0 merge keeps low byte of T",
              rd, 32'h0000_ABEF);
    end

    // ── T23: CONV_CFG_TILE byte slice merge ──
    do_write(O_CONV_CFG_TILE, 32'hAAAA_BBBB, 4'b1111);
    do_write(O_CONV_CFG_TILE, 32'h00CC_0000, 4'b0100);
    begin : t23_check
      logic [31:0] rd;
      do_read(O_CONV_CFG_TILE, rd);
      check32("T23 CONV_CFG_TILE byte2 merge",
              rd, 32'hAACC_BBBB);
    end

    // ── T24: CONV_CFG_FMAP_BASE byte slice merge ──
    do_write(O_CONV_CFG_FMAP_BASE, 32'h1111_2222, 4'b1111);
    do_write(O_CONV_CFG_FMAP_BASE, 32'h0000_3300, 4'b0010);
    begin : t24_check
      logic [31:0] rd;
      do_read(O_CONV_CFG_FMAP_BASE, rd);
      check32("T24 CONV_CFG_FMAP_BASE byte1 merge",
              rd, 32'h1111_3322);
    end

    // ── T25: CONV_CFG_OUT_BASE byte slice merge ──
    do_write(O_CONV_CFG_OUT_BASE, 32'h3333_4444, 4'b1111);
    do_write(O_CONV_CFG_OUT_BASE, 32'h5500_0000, 4'b1000);
    begin : t25_check
      logic [31:0] rd;
      do_read(O_CONV_CFG_OUT_BASE, rd);
      check32("T25 CONV_CFG_OUT_BASE byte3 merge",
              rd, 32'h5533_4444);
    end

    // ── T26: CONV_FMAP_WR_DATA byte slice merge ──
    do_write(O_CONV_FMAP_WR_DATA, 32'hDEAD_BEEF, 4'b1111);
    do_write(O_CONV_FMAP_WR_DATA, 32'h0000_0011, 4'b0001);
    begin : t26_check
      logic [31:0] rd;
      do_read(O_CONV_FMAP_WR_DATA, rd);
      check32("T26 CONV_FMAP_WR_DATA byte0 merge",
              rd, 32'hDEAD_BE11);
    end

    // ── T27: CONV_FMAP_WR_ADDR byte slice merge ──
    do_write(O_CONV_FMAP_WR_ADDR, 32'h7777_8888, 4'b1111);
    do_write(O_CONV_FMAP_WR_ADDR, 32'h00AA_0000, 4'b0100);
    begin : t27_check
      logic [31:0] rd;
      do_read(O_CONV_FMAP_WR_ADDR, rd);
      check32("T27 CONV_FMAP_WR_ADDR byte2 merge",
              rd, 32'h77AA_8888);
    end

    // ── T28: 同拍写 AUTO_INC+COMMIT，本次 commit 后地址必须自增 ──
    do_write(O_CONV_FMAP_WR_ADDR, 32'h0000_0010, 4'b1111);
    do_write(O_CONV_FMAP_WR_CTRL, 32'h0000_0003, 4'b0001);
    repeat (3) @(posedge clk);
    check32("T28 CONV_FMAP_WR_CTRL auto_inc+commit same write increments",
            dut.reg_conv_fmap_wr_addr, 32'h0000_0011);

    // ── T29: 同拍清 AUTO_INC+COMMIT，本次 commit 后地址不得自增 ──
    do_write(O_CONV_FMAP_WR_ADDR, 32'h0000_0020, 4'b1111);
    do_write(O_CONV_FMAP_WR_CTRL, 32'h0000_0003, 4'b0001);  // seed auto_inc=1
    repeat (3) @(posedge clk);
    do_write(O_CONV_FMAP_WR_ADDR, 32'h0000_0030, 4'b1111);
    do_write(O_CONV_FMAP_WR_CTRL, 32'h0000_0001, 4'b0001);  // write bit1=0 + commit
    repeat (3) @(posedge clk);
    check32("T29 CONV_FMAP_WR_CTRL clear auto_inc+commit same write stays put",
            dut.reg_conv_fmap_wr_addr, 32'h0000_0030);

    // ────────────────────────────────────────────────────────────────────
    // M1 trace-hash recorder CSR sub-tests (8 writable + 2 RO smoke)
    // Codex Day Tue review prereq #3: avoid the old 5x4 sprawl.
    // ────────────────────────────────────────────────────────────────────
    // Snapshot M1 W1P counters before any M1 write so each test asserts
    // pulse-count delta cleanly.
    begin
      integer base_clear, base_rd_en;
      logic [31:0] read_back;

      // -------- 4 writes on TRACE_HASH_CTRL (0x068) --------
      // T30: byte0 wstrb=0001 ENABLE bit toggle (bit[0]=1 sets enable)
      base_clear = recorder_clear_pulse_count;
      do_write(O_TRACE_HASH_CTRL, 32'h0000_0001, 4'b0001);
      repeat (2) @(posedge clk);
      check32("T30 TRACE_HASH_CTRL byte0 ENABLE bit set",
              {31'h0, dut.reg_recorder_en}, 32'h0000_0001);
      check_int("T30b TRACE_HASH_CTRL byte0 ENABLE write must NOT pulse CLEAR",
                recorder_clear_pulse_count, base_clear);

      // T31: byte0 wstrb=0001 CLEAR_W1P pulse (bit[1]=1 fires CLEAR pulse)
      base_clear = recorder_clear_pulse_count;
      do_write(O_TRACE_HASH_CTRL, 32'h0000_0002, 4'b0001);
      repeat (2) @(posedge clk);
      check_int("T31 TRACE_HASH_CTRL byte0 wdata[1]=1 fires CLEAR_W1P (delta=1)",
                recorder_clear_pulse_count - base_clear, 1);

      // T32: byte1 wstrb=0010 LAYER_ID write [10:8] (bits 0x0500 -> layer=5)
      // Existing layer_id from earlier writes is irrelevant; we just
      // verify the write lands and CLEAR pulse does NOT spuriously fire.
      base_clear = recorder_clear_pulse_count;
      do_write(O_TRACE_HASH_CTRL, 32'h0000_0500, 4'b0010);
      repeat (2) @(posedge clk);
      check32("T32 TRACE_HASH_CTRL byte1 LAYER_ID=5 latched",
              {29'h0, dut.reg_recorder_layer_id}, 32'h0000_0005);
      check_int("T32b TRACE_HASH_CTRL byte1 must NOT pulse CLEAR",
                recorder_clear_pulse_count, base_clear);

      // T33: wrong-byte CLEAR write (byte1-only, wdata[1]=1 in low byte
      // is gated away because wstrb[0]=0). CLEAR pulse must NOT fire.
      base_clear = recorder_clear_pulse_count;
      do_write(O_TRACE_HASH_CTRL, 32'h0000_0002, 4'b0010);  // bit1 NOT in active byte
      repeat (2) @(posedge clk);
      check_int("T33 TRACE_HASH_CTRL byte1-only with wdata[1]=1 must NOT fire CLEAR",
                recorder_clear_pulse_count, base_clear);

      // -------- 4 writes on TRACE_HASH_LOG_RD_ADDR (0x070) --------
      // T34: full word wstrb=1111, address = 0x123 (within 11-bit field).
      // rd_en must pulse exactly once on the WRITE.
      base_rd_en = recorder_rd_en_pulse_count;
      do_write(O_TRACE_HASH_LOG_RD_ADDR, 32'h0000_0123, 4'b1111);
      repeat (2) @(posedge clk);
      check32("T34 TRACE_HASH_LOG_RD_ADDR full-word write latched",
              {21'h0, dut.reg_recorder_rd_addr}, 32'h0000_0123);
      check_int("T34b TRACE_HASH_LOG_RD_ADDR write pulses rd_en exactly once",
                recorder_rd_en_pulse_count - base_rd_en, 1);

      // T35: byte0-only wstrb=0001 modifies low 8 bits, preserves high bits.
      // Pre-state was 0x123 from T34; byte0=0xAB merges to 0x1AB (high byte 0x1 preserved).
      base_rd_en = recorder_rd_en_pulse_count;
      do_write(O_TRACE_HASH_LOG_RD_ADDR, 32'h0000_00AB, 4'b0001);
      repeat (2) @(posedge clk);
      check32("T35 TRACE_HASH_LOG_RD_ADDR byte0-only merge keeps high byte (0x1AB)",
              {21'h0, dut.reg_recorder_rd_addr}, 32'h0000_01AB);
      check_int("T35b TRACE_HASH_LOG_RD_ADDR byte0-only also pulses rd_en",
                recorder_rd_en_pulse_count - base_rd_en, 1);

      // T36: byte1-only wstrb=0010 modifies bits [10:8], preserves low byte.
      // Pre-state 0x1AB; byte1=0x07 (writes bits [10:8]=0b111=7) -> 0x7AB.
      base_rd_en = recorder_rd_en_pulse_count;
      do_write(O_TRACE_HASH_LOG_RD_ADDR, 32'h0000_0700, 4'b0010);
      repeat (2) @(posedge clk);
      check32("T36 TRACE_HASH_LOG_RD_ADDR byte1-only merge keeps low byte (0x7AB)",
              {21'h0, dut.reg_recorder_rd_addr}, 32'h0000_07AB);
      check_int("T36b TRACE_HASH_LOG_RD_ADDR byte1-only also pulses rd_en",
                recorder_rd_en_pulse_count - base_rd_en, 1);

      // T37: cross-byte merge wstrb=0011 (both low bytes), writes 0x000.
      base_rd_en = recorder_rd_en_pulse_count;
      do_write(O_TRACE_HASH_LOG_RD_ADDR, 32'h0000_0000, 4'b0011);
      repeat (2) @(posedge clk);
      check32("T37 TRACE_HASH_LOG_RD_ADDR cross-byte wstrb=0011 clears 11-bit field",
              {21'h0, dut.reg_recorder_rd_addr}, 32'h0000_0000);
      check_int("T37b TRACE_HASH_LOG_RD_ADDR cross-byte write pulses rd_en once",
                recorder_rd_en_pulse_count - base_rd_en, 1);

      // -------- 2 RO smoke (writes ignored, reads sane) --------
      // T38: write to LOG_COUNT (0x06C) is RO; recorder_log_count read from
      // module is 0 because cfg_recorder_en=0 prevented any write so far.
      // Importantly, the write must NOT crash decode and must NOT mutate
      // recorder_log_count or other M1 state.
      base_clear = recorder_clear_pulse_count;
      base_rd_en = recorder_rd_en_pulse_count;
      do_write(O_TRACE_HASH_LOG_COUNT, 32'hFFFF_FFFF, 4'b1111);
      repeat (2) @(posedge clk);
      do_read(O_TRACE_HASH_LOG_COUNT, read_back);
      check32("T38 TRACE_HASH_LOG_COUNT is RO: write ignored, read returns log_count",
              read_back,
              {{(32-trace_hash_recorder_pkg::TRACE_HASH_LOG_COUNT_W){1'b0}},
               dut.recorder_log_count});
      check_int("T38b TRACE_HASH_LOG_COUNT write must NOT pulse CLEAR/rd_en",
                (recorder_clear_pulse_count - base_clear) +
                (recorder_rd_en_pulse_count - base_rd_en), 0);

      // T39: write to LOG_RD_META (0x078) is RO; high bits [31:16] must be
      // zero per Codex prereq #2; readback is the 16-bit metadata sign-extended.
      do_read(O_TRACE_HASH_LOG_RD_META, read_back);
      check32("T39 TRACE_HASH_LOG_RD_META RO read: high [31:16] zero-extended",
              read_back[31:16], 16'h0000);
    end

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
