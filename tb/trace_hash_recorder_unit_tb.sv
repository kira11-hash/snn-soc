// -----------------------------------------------------------------------------
// 自动文档头：本文件的可读性说明（仅注释说明，不改变任何逻辑）
// 文件路径：tb/trace_hash_recorder_unit_tb.sv
// 作用：M1 trace-hash recorder 单元 testbench（Day Tue 完整 6 sub-tests 版）。
// 系统角色：Phase 1 Day Tue 落地后强制门禁；smoke + 6 sub-tests 全 PASS 才允许
//           Day Wed 实例化进 snn_soc_v2b_top.sv。
// 行为性质：纯仿真 TB，不上 board。
// 项目规则：6 sub-tests 严格按 design doc §8 定义；不私自加 sub-test。
// 集成提示：本 TB 不要混进任何 stage_engine_v2 / snn_soc_v2b_top 实例化；
//           只测 trace_hash_recorder 单点。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: trace_hash_recorder_unit_tb.sv
// 模块名: trace_hash_recorder_unit_tb
//
// Day Tue 完整 6 sub-tests + smoke warm-up:
//   WARMUP   : reset clears all status
//   T1       : enable/disable toggle 边界 (en=0 valid pulse 无效, en=1 valid pulse 写入)
//   T2       : clear after writes -> log_count=0, sticky 清, BRAM 不清
//   T3       : single-write -> hash_mem[0] = crc32_reference(input)
//   T4       : overflow stop -> 写满 P_LOG_DEPTH 条后 log_overflow=1, 后续 reject
//   T5       : layer-id propagation -> meta layer_id = 输入 layer_id
//   T5b      : layer-id drift fault -> 同一 stage 内变 layer_id 抬 layer_id_fault
//   T6       : buf_sel mux -> meta buf_sel bit 反映输入 buf_sel
//======================================================================

module trace_hash_recorder_unit_tb;

  import trace_hash_recorder_pkg::*;

  // ──────────────────────────────────────────────────────────────────────────
  // Test-bench parameters (smaller than production for faster smoke)
  // ──────────────────────────────────────────────────────────────────────────
  localparam int TB_P_N_OUT     = 128;
  localparam int TB_P_T_MAX     = 256;
  localparam int TB_P_LAYER_MAX = 8;
  localparam int TB_P_LOG_DEPTH = 16;   // 小到能触 overflow 同时 sim 跑得快

  // Derived widths
  localparam int TB_LAYER_ID_W   = $clog2(TB_P_LAYER_MAX);  // 3
  localparam int TB_T_IDX_W      = $clog2(TB_P_T_MAX);      // 8
  localparam int TB_LOG_ADDR_W   = $clog2(TB_P_LOG_DEPTH);  // 4
  localparam int TB_HASH_INPUT_W = TB_LAYER_ID_W + 1 + TB_T_IDX_W + TB_P_N_OUT;  // 140
  localparam logic [31:0] TB_T3_HASH_GOLDEN = 32'hE7D7_E2D3;

  // ──────────────────────────────────────────────────────────────────────────
  // DUT IO
  // ──────────────────────────────────────────────────────────────────────────
  logic                                        clk;
  logic                                        rst_n;

  logic                                        cfg_recorder_en;
  logic                                        cfg_recorder_clear;

  logic                                        spike_commit_valid;
  logic [TB_P_N_OUT-1:0]                       spike_commit_data;
  logic [TB_T_IDX_W-1:0]                       spike_commit_t_idx;
  logic                                        spike_commit_buf_sel;
  logic [TB_LAYER_ID_W-1:0]                    spike_commit_layer_id;

  logic [TRACE_HASH_LOG_COUNT_W-1:0]           log_count;
  logic                                        log_overflow;
  logic                                        layer_id_fault;

  logic                                        rd_en;
  logic [TB_LOG_ADDR_W-1:0]                    rd_addr;
  logic [31:0]                                 rd_data;
  logic [TRACE_HASH_META_PACKED_W-1:0]         rd_meta;

  trace_hash_recorder #(
    .P_N_OUT     (TB_P_N_OUT),
    .P_T_MAX     (TB_P_T_MAX),
    .P_LAYER_MAX (TB_P_LAYER_MAX),
    .P_LOG_DEPTH (TB_P_LOG_DEPTH)
  ) u_dut (
    .clk(clk), .rst_n(rst_n),
    .cfg_recorder_en   (cfg_recorder_en),
    .cfg_recorder_clear(cfg_recorder_clear),
    .spike_commit_valid (spike_commit_valid),
    .spike_commit_data  (spike_commit_data),
    .spike_commit_t_idx (spike_commit_t_idx),
    .spike_commit_buf_sel(spike_commit_buf_sel),
    .spike_commit_layer_id(spike_commit_layer_id),
    .log_count   (log_count),
    .log_overflow(log_overflow),
    .layer_id_fault(layer_id_fault),
    .rd_en   (rd_en),
    .rd_addr (rd_addr),
    .rd_data (rd_data),
    .rd_meta (rd_meta)
  );

  // ──────────────────────────────────────────────────────────────────────────
  // Clock
  // ──────────────────────────────────────────────────────────────────────────
  initial clk = 1'b0;
  always #5 clk = ~clk;  // 100 MHz

  // ──────────────────────────────────────────────────────────────────────────
  // Software CRC-32 reference (independent of DUT — implements the same
  // reflected algorithm so we catch any DUT regression in CRC arithmetic)
  // ──────────────────────────────────────────────────────────────────────────
  function automatic logic [31:0] crc32_ref(input logic [TB_HASH_INPUT_W-1:0] data);
    logic [31:0] crc;
    logic        feedback;
    begin
      crc = 32'hFFFFFFFF;
      for (int i = 0; i < TB_HASH_INPUT_W; i++) begin
        feedback = crc[0] ^ data[i];
        crc      = (crc >> 1) ^ (feedback ? 32'hEDB88320 : 32'h0);
      end
      crc32_ref = crc ^ 32'hFFFFFFFF;
    end
  endfunction

  // Helper: assemble the 140-bit hash input from individual fields
  function automatic logic [TB_HASH_INPUT_W-1:0] pack_hash_input(
      input logic [TB_LAYER_ID_W-1:0] layer_id,
      input logic                      buf_sel,
      input logic [TB_T_IDX_W-1:0]    t_idx,
      input logic [TB_P_N_OUT-1:0]    data
  );
    pack_hash_input = {layer_id, buf_sel, t_idx, data};
  endfunction

  // Helper: pack meta the same way DUT does
  function automatic logic [TRACE_HASH_META_PACKED_W-1:0] pack_meta(
      input logic [TB_LAYER_ID_W-1:0] layer_id,
      input logic                      buf_sel,
      input logic [TB_T_IDX_W-1:0]    t_idx
  );
    pack_meta = { {(TRACE_HASH_META_PACKED_W - 1 - TB_LAYER_ID_W - TB_T_IDX_W){1'b0}},
                  buf_sel, layer_id, t_idx };
  endfunction

  // ──────────────────────────────────────────────────────────────────────────
  // Test driver
  // ──────────────────────────────────────────────────────────────────────────
  int errors;
  task automatic check(input logic cond, input string msg);
    if (!cond) begin
      $display("FAIL [%0t]: %s", $time, msg);
      errors++;
    end
  endtask

  task automatic tick(input int n = 1);
    repeat (n) @(posedge clk);
  endtask

  // Drive a single spike_commit pulse with the supplied fields.
  task automatic drive_commit(
      input logic [TB_LAYER_ID_W-1:0] layer_id,
      input logic                      buf_sel,
      input logic [TB_T_IDX_W-1:0]    t_idx,
      input logic [TB_P_N_OUT-1:0]    data
  );
    spike_commit_layer_id = layer_id;
    spike_commit_buf_sel  = buf_sel;
    spike_commit_t_idx    = t_idx;
    spike_commit_data     = data;
    spike_commit_valid    = 1'b1;
    @(posedge clk);
    spike_commit_valid    = 1'b0;
    @(posedge clk);
  endtask

  // Issue a recorder-side read pulse on rd_addr=A, then sample rd_data /
  // rd_meta on the cycle after. This models the internal recorder contract
  // that Day Wed will trigger from the CSR write-to-RD_ADDR path.
  task automatic do_read(
      input  logic [TB_LOG_ADDR_W-1:0] addr,
      output logic [31:0]              hash_out,
      output logic [TRACE_HASH_META_PACKED_W-1:0] meta_out
  );
    rd_addr = addr;
    rd_en   = 1'b1;
    @(posedge clk);
    rd_en   = 1'b0;
    @(posedge clk);  // latency-1: rd_data_q updated
    hash_out = rd_data;
    meta_out = rd_meta;
  endtask

  task automatic do_clear;
    cfg_recorder_clear = 1'b1;
    @(posedge clk);
    cfg_recorder_clear = 1'b0;
    @(posedge clk);
  endtask

  initial begin
    errors = 0;

    // Initialize
    rst_n                  = 1'b0;
    cfg_recorder_en        = 1'b0;
    cfg_recorder_clear     = 1'b0;
    spike_commit_valid     = 1'b0;
    spike_commit_data      = '0;
    spike_commit_t_idx     = '0;
    spike_commit_buf_sel   = 1'b0;
    spike_commit_layer_id  = '0;
    rd_en                  = 1'b0;
    rd_addr                = '0;

    // ─── WARMUP: reset clears all status ────────────────────────────────────
    tick(2);
    rst_n = 1'b1;
    tick(1);
    check(log_count == '0,        "WARMUP: log_count should be 0 after reset");
    check(log_overflow == 1'b0,   "WARMUP: log_overflow should be 0 after reset");
    check(layer_id_fault == 1'b0, "WARMUP: layer_id_fault should be 0 after reset");
    $display("WARMUP PASS: reset clears all status");

    // ─── T1: enable/disable toggle ──────────────────────────────────────────
    // Phase A: en=0 + spike pulse → no write
    cfg_recorder_en = 1'b0;
    drive_commit(3'd1, 1'b0, 8'd0, 128'hDEAD_BEEF_CAFE_BABE_1122_3344_5566_7788);
    check(log_count == 0, "T1A: en=0 valid pulse must not advance log_count");

    // Phase B: en=1 + spike pulse → log_count == 1
    cfg_recorder_en = 1'b1;
    drive_commit(3'd1, 1'b0, 8'd0, 128'hDEAD_BEEF_CAFE_BABE_1122_3344_5566_7788);
    check(log_count == 1, "T1B: en=1 valid pulse must advance log_count to 1");

    // Phase C: en flips back to 0, drive again → no further advance
    cfg_recorder_en = 1'b0;
    drive_commit(3'd2, 1'b1, 8'd1, 128'hAAAA_BBBB_CCCC_DDDD_EEEE_FFFF_0000_1111);
    check(log_count == 1, "T1C: en=0 must keep log_count at previous value");
    $display("T1 PASS: enable/disable boundary respected");

    // ─── T3: single-write hash correctness (we already have entry 0 from T1B) ─
    // Read back entry 0 and compare to crc32_ref of the same input.
    begin
      logic [31:0]                       hash_got;
      logic [31:0]                       hash_expected;
      logic [TRACE_HASH_META_PACKED_W-1:0] meta_got;
      logic [TRACE_HASH_META_PACKED_W-1:0] meta_expected;
      logic [TB_HASH_INPUT_W-1:0]        ref_input;
      ref_input     = pack_hash_input(3'd1, 1'b0, 8'd0,
                                      128'hDEAD_BEEF_CAFE_BABE_1122_3344_5566_7788);
      hash_expected = crc32_ref(ref_input);
      meta_expected = pack_meta(3'd1, 1'b0, 8'd0);
      do_read(4'd0, hash_got, meta_got);
      check(hash_expected == TB_T3_HASH_GOLDEN,
            $sformatf("T3: crc32_ref drifted from offline golden 0x%08h (got 0x%08h)",
                      TB_T3_HASH_GOLDEN, hash_expected));
      check(hash_got == TB_T3_HASH_GOLDEN,
            $sformatf("T3: DUT hash_mem[0] = 0x%08h, offline golden = 0x%08h",
                      hash_got, TB_T3_HASH_GOLDEN));
      check(hash_got == hash_expected,
            $sformatf("T3: hash_mem[0] = 0x%08h, expected 0x%08h",
                      hash_got, hash_expected));
      check(meta_got == meta_expected,
            $sformatf("T3: meta_mem[0] = 0x%04h, expected 0x%04h",
                      meta_got, meta_expected));
      $display("T3 PASS: single-write hash + meta match crc32_ref");
    end

    // ─── T2: clear after writes ─────────────────────────────────────────────
    // Recorder currently has 1 entry. Drive 2 more entries with en=1, then clear.
    cfg_recorder_en = 1'b1;
    drive_commit(3'd1, 1'b0, 8'd1, 128'h1111_2222_3333_4444_5555_6666_7777_8888);
    drive_commit(3'd1, 1'b0, 8'd2, 128'h9999_AAAA_BBBB_CCCC_DDDD_EEEE_FFFF_0000);
    check(log_count == 3, "T2: log_count should be 3 before clear");

    do_clear();
    check(log_count == 0,        "T2: log_count must reset to 0 after clear");
    check(log_overflow == 1'b0,  "T2: log_overflow must reset to 0 after clear");
    check(layer_id_fault == 1'b0,"T2: layer_id_fault must reset to 0 after clear");

    // BRAM not cleared: re-read entry 0; should still match T3 expectation
    begin
      logic [31:0]                       hash_got;
      logic [31:0]                       hash_expected;
      logic [TRACE_HASH_META_PACKED_W-1:0] meta_got;
      logic [TB_HASH_INPUT_W-1:0]        ref_input;
      ref_input     = pack_hash_input(3'd1, 1'b0, 8'd0,
                                      128'hDEAD_BEEF_CAFE_BABE_1122_3344_5566_7788);
      hash_expected = crc32_ref(ref_input);
      do_read(4'd0, hash_got, meta_got);
      check(hash_got == hash_expected,
            "T2: BRAM must NOT be cleared by cfg_recorder_clear (entry 0 must survive)");
      $display("T2 PASS: clear resets counters but leaves BRAM intact");
    end

    // ─── T4: overflow stop ──────────────────────────────────────────────────
    // After T2 clear, log_count=0. Drive P_LOG_DEPTH=16 commits, expect
    // log_overflow to assert on the 16th. Then drive one more, expect reject.
    do_clear();
    cfg_recorder_en = 1'b1;
    for (int i = 0; i < TB_P_LOG_DEPTH; i++) begin
      drive_commit(3'd0, 1'b0, TB_T_IDX_W'(i),
                   {{(TB_P_N_OUT-32){1'b0}}, 32'hAA000000} | {{(TB_P_N_OUT-8){1'b0}}, 8'(i)});
    end
    check(log_count == TRACE_HASH_LOG_COUNT_W'(TB_P_LOG_DEPTH),
          $sformatf("T4: log_count should be %0d after %0d writes",
                    TB_P_LOG_DEPTH, TB_P_LOG_DEPTH));
    check(log_overflow == 1'b1,
          "T4: log_overflow must be high after writing P_LOG_DEPTH entries");

    // One more commit: must be rejected (log_count stays the same)
    drive_commit(3'd0, 1'b0, 8'd99, 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF);
    check(log_count == TRACE_HASH_LOG_COUNT_W'(TB_P_LOG_DEPTH),
          "T4: extra commit after overflow must be rejected");
    check(log_overflow == 1'b1,        "T4: log_overflow must remain set after reject");
    $display("T4 PASS: overflow stops further writes and is sticky");

    // ─── T5: layer-id propagation + drift fault ──────────────────────────────
    do_clear();
    cfg_recorder_en = 1'b1;
    // Two commits with layer_id=4 — drift detector should NOT trigger
    drive_commit(3'd4, 1'b0, 8'd0, 128'h1234_5678_9ABC_DEF0_FEDC_BA98_7654_3210);
    drive_commit(3'd4, 1'b1, 8'd1, 128'h0FED_CBA9_8765_4321_0123_4567_89AB_CDEF);
    check(layer_id_fault == 1'b0,
          "T5: layer_id_fault must NOT trigger when layer_id is constant");

    // Read meta of entry 0; should encode layer_id=4
    begin
      logic [31:0]                       hash_got;
      logic [TRACE_HASH_META_PACKED_W-1:0] meta_got;
      logic [TRACE_HASH_META_PACKED_W-1:0] meta_expected;
      meta_expected = pack_meta(3'd4, 1'b0, 8'd0);
      do_read(4'd0, hash_got, meta_got);
      check(meta_got == meta_expected,
            $sformatf("T5: meta layer_id propagation: got 0x%04h, expected 0x%04h",
                      meta_got, meta_expected));
    end
    $display("T5 PASS: layer_id propagation correct, no false drift fault");

    // ─── T5b: layer-id drift fault ──────────────────────────────────────────
    // Now drive a third commit with a DIFFERENT layer_id → drift fault sticky
    drive_commit(3'd6, 1'b0, 8'd2, 128'hFEEDFACEFEEDFACE_FEEDFACEFEEDFACE);
    check(layer_id_fault == 1'b1,
          "T5b: layer_id_fault must trigger when layer_id changes mid-stage");

    // Clear should reset the fault sticky
    do_clear();
    check(layer_id_fault == 1'b0,
          "T5b: layer_id_fault must clear after cfg_recorder_clear");

    // Disable -> re-enable starts a fresh layer-id lock window even without
    // a second clear, so a new stage can latch a different layer_id cleanly.
    cfg_recorder_en = 1'b1;
    drive_commit(3'd1, 1'b0, 8'd0, 128'h0011_2233_4455_6677_8899_AABB_CCDD_EEFF);
    cfg_recorder_en = 1'b0;
    tick(1);
    cfg_recorder_en = 1'b1;
    drive_commit(3'd6, 1'b0, 8'd1, 128'hFFEE_DDCC_BBAA_9988_7766_5544_3322_1100);
    check(layer_id_fault == 1'b0,
          "T5b: disable->enable must reopen the layer-id lock window");
    $display("T5b PASS: layer-id drift detector triggers + clears properly");

    // ─── T6: buf_sel mux ────────────────────────────────────────────────────
    do_clear();
    cfg_recorder_en = 1'b1;
    // Entry 0: buf_sel=0
    drive_commit(3'd2, 1'b0, 8'd5, 128'hABCDEF01_23456789_ABCDEF01_23456789);
    // Entry 1: buf_sel=1
    drive_commit(3'd2, 1'b1, 8'd5, 128'hABCDEF01_23456789_ABCDEF01_23456789);

    begin
      logic [31:0]                       hash0, hash1;
      logic [TRACE_HASH_META_PACKED_W-1:0] meta0, meta1;
      logic [TRACE_HASH_META_PACKED_W-1:0] meta0_expected, meta1_expected;
      meta0_expected = pack_meta(3'd2, 1'b0, 8'd5);
      meta1_expected = pack_meta(3'd2, 1'b1, 8'd5);
      do_read(4'd0, hash0, meta0);
      do_read(4'd1, hash1, meta1);
      check(meta0 == meta0_expected, "T6: meta[0] buf_sel bit must be 0");
      check(meta1 == meta1_expected, "T6: meta[1] buf_sel bit must be 1");
      // Also: same data + same layer + same t but different buf_sel → different hash
      check(hash0 != hash1, "T6: hash must differ between buf_sel=0 and buf_sel=1");
      $display("T6 PASS: buf_sel propagates to meta and into the hash domain");
    end

    // ─── Done ──────────────────────────────────────────────────────────────
    if (errors == 0) begin
      $display("=========================================");
      $display("TRACE_HASH_RECORDER_UNIT_TB_PASS (Day Tue full 6 sub-tests + warmup)");
      $display("=========================================");
    end else begin
      $display("=========================================");
      $display("TRACE_HASH_RECORDER_UNIT_TB FAIL (errors=%0d)", errors);
      $display("=========================================");
    end
    $finish;
  end

  // Watchdog
  initial begin
    #50000;
    $display("WATCHDOG: TB exceeded 50 us, killing");
    $finish;
  end

endmodule
