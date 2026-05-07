`timescale 1ns/1ps
//======================================================================
// tb/lif_per_layer_schedule_unit_tb.sv
//
// H1-full unit TB for the LIF per-layer schedule mux that lives at
// the top of `rtl/top/snn_soc_v2b_top.sv`. Per
// `essay/h1_full_design_2026_05_07.md` §3.2, 5 sub-tests:
//
//   1. GLOBAL_MODE=1 default + STAGE_CFG1=0x100 → effective threshold
//      observed at u_se input == 0x100; LUT must NOT be sampled.
//   2. With 8 LUT slots written to distinct values, GLOBAL_MODE=1 →
//      effective threshold still tracks STAGE_CFG1, not the LUT.
//   3. GLOBAL_MODE=0 + LIF_LAYER_IDX=3 → effective threshold == LUT[3].
//   4. GLOBAL_MODE=0 + slot N reset_mode=1 (hard) → membrane writeback
//      after fire == '0 (not mem + diff − thr).
//   5. Toggle GLOBAL_MODE 1→0→1 mid-test → last-write-wins on the
//      effective-threshold mux output.
//
// Round-3 footnote (essay/h1_full_design_2026_05_07.md §9.4): an
// earlier draft included a 6th sub-test fault-injecting
// `lif_layer_idx = 3'd7+1`. That negative test was dropped because a
// 3-bit signal cannot represent 8; SVA-2 still stands as
// belt-and-suspenders defense-in-depth (real protection is the CSR
// width + the byte-mask invariant TB write-decode coverage).
//
// Pass sentinel: LIF_PER_LAYER_SCHEDULE_UNIT_TB_PASS
//======================================================================
module lif_per_layer_schedule_unit_tb;

  import snn_soc_pkg::*;

  // ── DUT bus offsets (mirror snn_soc_v2b_top localparams) ────────────
  localparam logic [11:0] O_STAGE_CTRL       = 12'h000;
  localparam logic [11:0] O_STAGE_STATUS     = 12'h004;
  localparam logic [11:0] O_STAGE_CFG0       = 12'h008;
  localparam logic [11:0] O_STAGE_CFG1       = 12'h00C;
  localparam logic [11:0] O_STAGE_CFG2       = 12'h010;
  localparam logic [11:0] O_STAGE_CFG3       = 12'h014;
  localparam logic [11:0] O_STAGE_CFG5       = 12'h01C;
  localparam logic [11:0] O_INPUT_SRAM_ADDR  = 12'h020;
  localparam logic [11:0] O_INPUT_SRAM_W0    = 12'h024;
  localparam logic [11:0] O_INPUT_SRAM_W1    = 12'h028;
  localparam logic [11:0] O_INPUT_SRAM_W2    = 12'h02C;
  localparam logic [11:0] O_INPUT_SRAM_W3    = 12'h030;
  localparam logic [11:0] O_INPUT_SRAM_W4    = 12'h034;
  localparam logic [11:0] O_INPUT_SRAM_W5    = 12'h038;
  localparam logic [11:0] O_INPUT_SRAM_W6    = 12'h03C;
  localparam logic [11:0] O_INPUT_SRAM_W7    = 12'h040;
  localparam logic [11:0] O_INPUT_SRAM_CTRL  = 12'h044;
  localparam logic [11:0] O_MAC_W_LOAD_ADDR  = 12'h050;
  localparam logic [11:0] O_MAC_W_LOAD_DATA  = 12'h054;
  localparam logic [11:0] O_MAC_W_LOAD_CTRL  = 12'h058;

  localparam logic [11:0] O_LIF_GLOBAL_MODE  = 12'h0C0;
  localparam logic [11:0] O_LIF_LAYER0_CFG   = 12'h0C4;
  localparam logic [11:0] O_LIF_LAYER1_CFG   = 12'h0C8;
  localparam logic [11:0] O_LIF_LAYER2_CFG   = 12'h0CC;
  localparam logic [11:0] O_LIF_LAYER3_CFG   = 12'h0D0;
  localparam logic [11:0] O_LIF_LAYER4_CFG   = 12'h0D4;
  localparam logic [11:0] O_LIF_LAYER5_CFG   = 12'h0D8;
  localparam logic [11:0] O_LIF_LAYER6_CFG   = 12'h0DC;
  localparam logic [11:0] O_LIF_LAYER7_CFG   = 12'h0E0;
  localparam logic [11:0] O_LIF_LAYER_IDX    = 12'h0E4;

  // ── Clock / reset / bus signals ─────────────────────────────────────
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        cmd_valid = 1'b0;
  logic        cmd_ready;
  logic [11:0] cmd_addr  = '0;
  logic        cmd_write = 1'b0;
  logic [31:0] cmd_wdata = '0;
  logic [3:0]  cmd_wstrb = 4'h0;
  logic        rsp_valid;
  logic [31:0] rsp_rdata;

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

  integer pass_count = 0;
  integer fail_count = 0;

  // ── Bus helpers ─────────────────────────────────────────────────────
  task automatic bus_write(input logic [11:0] addr,
                           input logic [31:0] wdata,
                           input logic [3:0]  wstrb = 4'b1111);
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

  task automatic bus_read(input  logic [11:0] addr,
                          output logic [31:0] data);
    @(posedge clk);
    cmd_valid = 1'b1;
    cmd_write = 1'b0;
    cmd_addr  = addr;
    cmd_wstrb = 4'h0;
    @(posedge clk);
    while (!cmd_ready) @(posedge clk);
    cmd_valid = 1'b0;
    @(posedge clk);
    @(posedge clk);
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

  task automatic check_membrane_zero(input string tag,
                                     input logic signed [V2B_PARTIAL_WIDTH-1:0] got);
    if (got === '0) begin
      $display("[PASS] %s got=0", tag);
      pass_count = pass_count + 1;
    end else begin
      $display("[FAIL] %s got=%0d exp=0", tag, got);
      fail_count = fail_count + 1;
    end
  endtask

  // Wait until STAGE_STATUS.BUSY clears.
  task automatic wait_stage_done;
    int g;
    logic [31:0] sts;
    begin
      g = 0;
      sts = 32'h1;
      while (sts[0] && g < 200000) begin
        bus_read(O_STAGE_STATUS, sts);
        g = g + 1;
      end
      if (sts[0]) begin
        $display("[FAIL] stage BUSY never clears after %0d polls", g);
        fail_count = fail_count + 1;
      end
    end
  endtask

  // ── Sub-test 4 helpers: set up + run a 4-input × 1-output × T=2 stage
  //   that fires at t=1 with sum_max = V2B_NUM_INPUTS*15 (default policy).
  task automatic load_unit_weights;
    int j;
    begin
      j = 0;
      for (int i = 0; i < 4; i++) begin
        // MAC_W_LOAD_ADDR layout: [I_AW-1:0]=i, [8 +: J_AW]=j
        bus_write(O_MAC_W_LOAD_ADDR, (j << 8) | i);
        // pos=1, neg=0 -> diff contribution = 1 per active input
        bus_write(O_MAC_W_LOAD_DATA, 32'h0000_0001);
        bus_write(O_MAC_W_LOAD_CTRL, 32'h0000_0001);
      end
    end
  endtask

  task automatic load_unit_input_row(input int t, input logic [255:0] wl);
    begin
      bus_write(O_INPUT_SRAM_ADDR, t);
      bus_write(O_INPUT_SRAM_W0, wl[ 31:  0]);
      bus_write(O_INPUT_SRAM_W1, wl[ 63: 32]);
      bus_write(O_INPUT_SRAM_W2, wl[ 95: 64]);
      bus_write(O_INPUT_SRAM_W3, wl[127: 96]);
      bus_write(O_INPUT_SRAM_W4, wl[159:128]);
      bus_write(O_INPUT_SRAM_W5, wl[191:160]);
      bus_write(O_INPUT_SRAM_W6, wl[223:192]);
      bus_write(O_INPUT_SRAM_W7, wl[255:224]);
      bus_write(O_INPUT_SRAM_CTRL, 32'h0000_0001);
    end
  endtask

  // Run a stage with cfg (in_dim=4, out_dim=1, T=2, threshold=THR,
  //   sum_max=4 → adc_scale_fast(4,4)=1023). With wl_mask=4'b1111 and
  //   weights pos=1/neg=0, diff per timestep is (clipped to PARTIAL
  //   range; PARTIAL_W=14 so PARTIAL_MAX=8191, 1023 fits cleanly).
  //   Soft path: m=0 → 1023 (no fire), 1023+1023=2046 → fire,
  //              soft post = 2046−1500 = 546.
  //   Hard path: m=0 → 1023, 2046 → fire, hard post = 0.
  task automatic run_unit_stage(input logic [31:0] threshold);
    logic [31:0] cfg3_val;
    begin
      bus_write(O_STAGE_CFG0, {16'd1, 16'd4});      // out_dim=1, in_dim=4
      bus_write(O_STAGE_CFG1, threshold);            // shadow only when GLOBAL_MODE=1
      bus_write(O_STAGE_CFG2, 32'd4);                // sum_max = 4
      cfg3_val = 32'h0;
      cfg3_val[V2B_BUF_SEL_W-1:0] = V2B_BUF_SEL_INPUT_SRAM;
      cfg3_val[9:8]              = 2'd1;             // OUTPUT_DST = STREAM_A
      cfg3_val[17]               = 1'b1;             // IS_TILE_FINAL
      bus_write(O_STAGE_CFG3, cfg3_val);
      bus_write(O_STAGE_CFG5, 32'd2);                // T_COUNT = 2
      bus_write(O_STAGE_CTRL, 32'h0000_0001);        // START W1P
      wait_stage_done();
      bus_write(O_STAGE_CTRL, 32'h0000_0080);        // clear DONE W1C
    end
  endtask

  // ── Test sequence ───────────────────────────────────────────────────
  initial begin
    logic [31:0] read_back;
    logic [255:0] wl_full4;
    logic signed [V2B_PARTIAL_WIDTH-1:0] mem_after_hard;

    $display("[INFO] lif_per_layer_schedule_unit_tb start");
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    //==================================================================
    // Sub-test 1 — GLOBAL_MODE=1 default + STAGE_CFG1=0x100
    //   → se_cfg_threshold == 0x100 (FC arm of the historical mux);
    //     LUT slots untouched, so they read 0x0 and must NOT influence
    //     the effective threshold.
    //==================================================================
    bus_write(O_STAGE_CFG1, 32'h0000_0100);
    repeat (3) @(posedge clk);
    check32("ST1 GLOBAL_MODE=1 default uses STAGE_CFG1 (0x100)",
            dut.se_cfg_threshold, 32'h0000_0100);

    //==================================================================
    // Sub-test 2 — fill all 8 LUT slots with distinct values, keep
    //   GLOBAL_MODE=1; effective threshold must still be STAGE_CFG1.
    //==================================================================
    bus_write(O_LIF_LAYER0_CFG, 32'h0000_00AA);  // threshold=0xAA, reset=0
    bus_write(O_LIF_LAYER1_CFG, 32'h0000_00BB);
    bus_write(O_LIF_LAYER2_CFG, 32'h0000_00CC);
    bus_write(O_LIF_LAYER3_CFG, 32'h0000_00DD);
    bus_write(O_LIF_LAYER4_CFG, 32'h0000_00EE);
    bus_write(O_LIF_LAYER5_CFG, 32'h0000_00FF);
    bus_write(O_LIF_LAYER6_CFG, 32'h0000_0011);
    bus_write(O_LIF_LAYER7_CFG, 32'h0000_0022);
    repeat (3) @(posedge clk);
    check32("ST2 LUT slots filled, GLOBAL_MODE=1 still uses STAGE_CFG1",
            dut.se_cfg_threshold, 32'h0000_0100);

    //==================================================================
    // Sub-test 3 — GLOBAL_MODE=0 + LIF_LAYER_IDX=3 → effective
    //   threshold tracks LUT[3].threshold (= 0xDD from sub-test 2).
    //==================================================================
    bus_write(O_LIF_LAYER_IDX,   32'h0000_0003);
    bus_write(O_LIF_GLOBAL_MODE, 32'h0000_0000);
    repeat (3) @(posedge clk);
    check32("ST3 GLOBAL_MODE=0 + LAYER_IDX=3 sources LUT[3]=0xDD",
            dut.se_cfg_threshold, 32'h0000_00DD);

    //==================================================================
    // Sub-test 4 — GLOBAL_MODE=0 + slot N reset_mode=1 (hard) →
    //   membrane writeback after fire == '0.
    //
    //   Plan: layer 0 with threshold=1500, reset_mode=1.
    //         in_dim=4, out_dim=1, T=2, sum_max=4 → diff=1023 per
    //         timestep. m: 0 → 1023 (no fire) → 1023+1023=2046 (fire,
    //         hard reset → 0). Final dut.u_se.membrane[0] must == 0.
    //==================================================================
    bus_write(O_LIF_LAYER0_CFG, 32'h0001_05DC);  // threshold=0x5DC=1500, reset_mode=1
    bus_write(O_LIF_LAYER_IDX,  32'h0000_0000);  // index slot 0
    // GLOBAL_MODE already 0 from sub-test 3.

    load_unit_weights();
    wl_full4 = '0;
    wl_full4[3:0] = 4'b1111;
    load_unit_input_row(0, wl_full4);
    load_unit_input_row(1, wl_full4);

    run_unit_stage(32'h0000_0001);    // STAGE_CFG1 ignored (GLOBAL=0)

    mem_after_hard = dut.u_se.membrane[0];
    check_membrane_zero(
      "ST4 GLOBAL_MODE=0 + reset_mode=1 (hard) -> membrane[0] == 0",
      mem_after_hard);

    //==================================================================
    // Sub-test 5 — toggle GLOBAL_MODE 1→0→1, verify last-write-wins
    //   on the effective-threshold mux output.
    //==================================================================
    // Anchor a known STAGE_CFG1 value distinct from any LUT slot.
    bus_write(O_STAGE_CFG1, 32'h0000_0500);
    // Start GLOBAL_MODE=1: effective should be STAGE_CFG1 = 0x500.
    bus_write(O_LIF_GLOBAL_MODE, 32'h0000_0001);
    repeat (3) @(posedge clk);
    if (dut.se_cfg_threshold !== 32'h0000_0500) begin
      $display("[FAIL] ST5 pre-toggle expected 0x500 got 0x%08h",
               dut.se_cfg_threshold);
      fail_count = fail_count + 1;
    end
    // Toggle to GLOBAL_MODE=0: LIF_LAYER_IDX still 0 → LUT[0]=0xAA
    // (slot 0 was last set to 0xAA in sub-test 2; reset_mode bit was
    // cleared by ST3 LUT 0xAA write but then re-set by ST4's 0x000105DC.
    // To keep this sub-test clean, restore slot 0 to 0xAA below.)
    bus_write(O_LIF_LAYER0_CFG, 32'h0000_00AA);
    repeat (2) @(posedge clk);
    bus_write(O_LIF_GLOBAL_MODE, 32'h0000_0000);
    repeat (3) @(posedge clk);
    if (dut.se_cfg_threshold !== 32'h0000_00AA) begin
      $display("[FAIL] ST5 mid-toggle expected 0xAA got 0x%08h",
               dut.se_cfg_threshold);
      fail_count = fail_count + 1;
    end
    // Toggle back to GLOBAL_MODE=1: effective should restore to 0x500.
    bus_write(O_LIF_GLOBAL_MODE, 32'h0000_0001);
    repeat (3) @(posedge clk);
    check32("ST5 toggle 1->0->1: last-write-wins, eff=STAGE_CFG1 (0x500)",
            dut.se_cfg_threshold, 32'h0000_0500);

    repeat (5) @(posedge clk);
    $display("");
    $display("=== Results: %0d PASS, %0d FAIL ===", pass_count, fail_count);
    if (fail_count == 0)
      $display("LIF_PER_LAYER_SCHEDULE_UNIT_TB_PASS");
    else
      $display("LIF_PER_LAYER_SCHEDULE_UNIT_TB_FAIL (fail_count=%0d)",
               fail_count);
    $finish;
  end

  initial begin
    #500000;
    $display("[ERROR] timeout");
    $display("LIF_PER_LAYER_SCHEDULE_UNIT_TB_FAIL (timeout)");
    $finish;
  end

endmodule
