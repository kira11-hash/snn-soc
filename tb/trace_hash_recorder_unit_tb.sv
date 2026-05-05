// -----------------------------------------------------------------------------
// 自动文档头：本文件的可读性说明（仅注释说明，不改变任何逻辑）
// 文件路径：tb/trace_hash_recorder_unit_tb.sv
// 作用：M1 trace-hash recorder 单元 testbench。
// 系统角色：Phase 1 Day Mon = SMOKE 范围（reset + clear + sidecar-no-op 三条）；
//           Day Tue 扩成 6 sub-tests (enable/disable / clear / single-write /
//           overflow stop / layer-id propagation / buf_sel mux)。
// 行为性质：纯仿真 TB，不上 board。
// 项目规则：本 TB Day Mon 只验"模块能稳定 elaborate 且 reset/clear 行为正确"，
//           不验 hash compute；Day Tue hash 主逻辑落地后再扩。
// 集成提示：本 TB 不要混进任何 stage_engine_v2 / snn_soc_v2b_top 实例化；
//           只测 trace_hash_recorder 单点。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: trace_hash_recorder_unit_tb.sv
// 模块名: trace_hash_recorder_unit_tb
//
// Day Mon SMOKE 范围 (3 sub-tests):
//   SMOKE_1: reset clears all status (log_count=0 / overflow=0 / layer_id_fault=0)
//   SMOKE_2: cfg_recorder_clear W1P clears status (BRAM intentionally NOT cleared)
//   SMOKE_3: with cfg_recorder_en=0 and spike_commit_valid pulses, log_count
//            stays 0 and no sticky goes high (sidecar isolation)
//
// Day Tue 扩展 (full 6 sub-tests):
//   T_1: enable/disable toggle 边界
//   T_2: single-write -> log_count=1, hash_mem[0] populated
//   T_3: clear after writes -> log_count=0, BRAM not cleared
//   T_4: overflow at log_count=P_LOG_DEPTH -> reject + sticky
//   T_5: layer_id propagation -> meta layer_id matches input
//   T_6: buf_sel A vs B mux -> meta buf_sel bit reflects pulse source
//======================================================================

module trace_hash_recorder_unit_tb;

  import trace_hash_recorder_pkg::*;

  // ──────────────────────────────────────────────────────────────────────────
  // Test-bench parameters (smaller than production for faster smoke)
  // ──────────────────────────────────────────────────────────────────────────
  localparam int TB_P_N_OUT     = 128;
  localparam int TB_P_T_MAX     = 256;
  localparam int TB_P_LAYER_MAX = 8;
  localparam int TB_P_LOG_DEPTH = 64;   // small smoke depth; production uses 2048

  // ──────────────────────────────────────────────────────────────────────────
  // DUT IO
  // ──────────────────────────────────────────────────────────────────────────
  logic                                        clk;
  logic                                        rst_n;

  logic                                        cfg_recorder_en;
  logic                                        cfg_recorder_clear;

  logic                                        spike_commit_valid;
  logic [TB_P_N_OUT-1:0]                       spike_commit_data;
  logic [$clog2(TB_P_T_MAX)-1:0]               spike_commit_t_idx;
  logic                                        spike_commit_buf_sel;
  logic [$clog2(TB_P_LAYER_MAX)-1:0]           spike_commit_layer_id;

  logic [TRACE_HASH_LOG_COUNT_W-1:0]           log_count;
  logic                                        log_overflow;
  logic                                        layer_id_fault;

  logic                                        rd_en;
  logic [$clog2(TB_P_LOG_DEPTH)-1:0]           rd_addr;
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
  always #5 clk = ~clk;  // 100 MHz nominal

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

  initial begin
    errors = 0;

    // Initialize all inputs
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

    // ─── SMOKE_1: reset clears all status ──────────────────────────────────
    tick(2);
    rst_n = 1'b1;
    tick(1);
    check(log_count == '0,        "SMOKE_1: log_count should be 0 after reset");
    check(log_overflow == 1'b0,   "SMOKE_1: log_overflow should be 0 after reset");
    check(layer_id_fault == 1'b0, "SMOKE_1: layer_id_fault should be 0 after reset");
    $display("SMOKE_1 PASS: reset clears all status");

    // ─── SMOKE_3: sidecar isolation (en=0, drive valid pulses, expect no-op) ─
    cfg_recorder_en       = 1'b0;
    spike_commit_data     = 128'h11223344_55667788_99AABBCC_DDEEFF00;
    spike_commit_t_idx    = 8'h05;
    spike_commit_buf_sel  = 1'b1;
    spike_commit_layer_id = 3'd2;
    repeat (8) begin
      spike_commit_valid = 1'b1;
      tick(1);
      spike_commit_valid = 1'b0;
      tick(1);
    end
    check(log_count == '0,        "SMOKE_3: log_count must remain 0 when en=0");
    check(log_overflow == 1'b0,   "SMOKE_3: log_overflow must remain 0 when en=0");
    check(layer_id_fault == 1'b0, "SMOKE_3: layer_id_fault must remain 0 when en=0");
    $display("SMOKE_3 PASS: cfg_recorder_en=0 honored as full sidecar (Day Mon contract)");

    // ─── SMOKE_2: clear pulse clears status ─────────────────────────────────
    // Day Mon body is empty so log_count is already 0. We still drive
    // cfg_recorder_clear to make sure the clear path itself is wired.
    cfg_recorder_clear = 1'b1;
    tick(1);
    cfg_recorder_clear = 1'b0;
    tick(1);
    check(log_count == '0,        "SMOKE_2: log_count should be 0 after clear");
    check(log_overflow == 1'b0,   "SMOKE_2: log_overflow should be 0 after clear");
    check(layer_id_fault == 1'b0, "SMOKE_2: layer_id_fault should be 0 after clear");
    $display("SMOKE_2 PASS: cfg_recorder_clear path wired (Day Mon)");

    // ─── Read-port stub returns 0 (Day Mon contract) ───────────────────────
    rd_en   = 1'b1;
    rd_addr = 6'd3;
    tick(2);
    rd_en   = 1'b0;
    check(rd_data == 32'h0,                          "Day Mon: rd_data stub must be 0");
    check(rd_meta == {TRACE_HASH_META_PACKED_W{1'b0}}, "Day Mon: rd_meta stub must be 0");
    $display("Day-Mon stub: rd_data + rd_meta return 0 as documented");

    // ─── Done ──────────────────────────────────────────────────────────────
    if (errors == 0) begin
      $display("=========================================");
      $display("TRACE_HASH_RECORDER_UNIT_TB_PASS (Day Mon smoke)");
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
    #20000;
    $display("WATCHDOG: TB exceeded 20 us, killing");
    $finish;
  end

endmodule
