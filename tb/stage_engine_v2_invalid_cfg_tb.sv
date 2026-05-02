`timescale 1ns/1ps
//======================================================================
// tb/stage_engine_v2_invalid_cfg_tb.sv
//
// BLOCK-V2-01 regression (2026-04-22 GPT dual-line audit).
//
// 【复现的漏洞】
// 旧版 stage_engine_v2 的 S_IDLE 只看 start_pulse 就跳 S_SETUP，对应的
// sequential 验证块虽置 err_code + done_pulse 但 state 仍进 S_SETUP，
// FSM 带着非法 cfg_in_dim/out_dim/t_count=0 跑，卡在 MS_ACCUM：
//   - busy=0（因为没进 valid 分支置位）
//   - done_sticky=1（GPT 报告场景）
//   - mac_busy=1, mac_state=2
// 对外看像 stage 空闲，实际内部 MAC 悬挂不可重入。
//
// 【修复】
// `next_state` 加 `config_ok` 组合门控：非法配置时 next_state 维持 S_IDLE，
// 只 emit err_code + done_pulse；busy 不置位；mac_start 不发。
//
// 【本 TB 覆盖的 reject case】
//   T1: cfg_in_dim = 0            → ERR_DIM_OUT_OF_RANGE
//   T2: cfg_out_dim = 0           → ERR_DIM_OUT_OF_RANGE
//   T3: cfg_t_count = 0           → ERR_DIM_OUT_OF_RANGE
//   T4: cfg_in_dim > P_N_IN       → ERR_DIM_OUT_OF_RANGE
//   T5: cfg_out_dim > P_N_OUT     → ERR_DIM_OUT_OF_RANGE
//   T6: cfg_t_count > P_T_MAX     → ERR_DIM_OUT_OF_RANGE
//   T7: cfg_input_src == cfg_output_dst (非 OUTPUT_FIFO) → ERR_SRC_DST_CONFLICT
//   T8: 合法配置（regression）    → ERR_OK, busy=1, 正常跑完
//
// 【每条 case 检查】
//   (a) done_pulse 触发 1 拍
//   (b) err_code == 期望码
//   (c) busy 在拒绝情况下从未 pulse 高（用计数器监控）
//   (d) mac_start 在拒绝情况下从未被置高
//   (e) FSM 回到 S_IDLE，后续合法配置还能正常启动（非卡死）
//======================================================================
module stage_engine_v2_invalid_cfg_tb;

  import snn_soc_pkg::*;

  localparam int T_MAX = V2B_MAX_TIMESTEPS;
  localparam int N_IN  = V2B_NUM_INPUTS;
  localparam int N_OUT = V2B_MAX_OUT_NEURONS;
  localparam int PW    = V2B_PARTIAL_WIDTH;
  localparam int T_AW  = $clog2(T_MAX);
  localparam int J_AW  = $clog2(N_OUT);

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // DUT control
  logic start_pulse = 0;
  logic busy, done_pulse;
  logic [7:0] err_code;
  logic [T_AW-1:0] dbg_t;
  logic [15:0] cfg_in_dim, cfg_out_dim;
  logic [31:0] cfg_threshold, cfg_sum_max;
  logic [V2B_BUF_SEL_W-1:0] cfg_input_src;
  logic [1:0]               cfg_output_dst;
  logic        cfg_tile_mode, cfg_is_tile_final, cfg_preserve_membrane;
  logic [15:0] cfg_t_count;
  // E2 fix（2026-05-02）：cfg_conv_mode/cfg_flatten_mode 显式驱动，T9 reject case
  // 需要把 cfg_conv_mode=0 + cfg_input_src=PATCH 组合送进 DUT。
  logic        cfg_conv_mode, cfg_flatten_mode;

  // Buffers (stubbed to minimal behavior; we only care about FSM reject)
  logic isr_rd_en;
  logic [T_AW-1:0] isr_rd_addr;
  logic [N_IN-1:0] isr_rd_data = '0;
  logic sbA_wr_en, sbB_wr_en;
  logic [T_AW-1:0] sbA_wr_addr, sbB_wr_addr;
  logic [N_OUT-1:0] sbA_wr_data, sbB_wr_data;
  logic sbA_rd_en, sbB_rd_en;
  logic [T_AW-1:0] sbA_rd_addr, sbB_rd_addr;
  logic [N_OUT-1:0] sbA_rd_data = '0, sbB_rd_data = '0;

  logic tpb_clear_all, tpb_acc_en;
  logic [T_AW-1:0] tpb_wr_t, tpb_rd_t;
  logic [J_AW-1:0] tpb_wr_j, tpb_rd_j;
  logic signed [PW-1:0] tpb_wr_diff;
  logic tpb_rd_en;
  logic signed [PW-1:0] tpb_rd_data = '0;

  // MAC stubbed
  logic                       mac_start, mac_busy = 0, mac_done = 0;
  logic [N_IN-1:0]            mac_wl_mask;
  logic [15:0]                mac_cfg_in_dim, mac_cfg_out_dim;
  logic [31:0]                mac_cfg_sum_max;
  logic [J_AW-1:0]            mac_diff_rd_j;
  logic signed [PW-1:0]       mac_diff_rd_data = '0;

  stage_engine_v2 u_se (
    .clk(clk), .rst_n(rst_n),
    .start_pulse(start_pulse), .busy(busy), .done_pulse(done_pulse),
    .err_code(err_code), .debug_t_idx(dbg_t),
    .cfg_in_dim(cfg_in_dim), .cfg_out_dim(cfg_out_dim),
    .cfg_threshold(cfg_threshold), .cfg_sum_max(cfg_sum_max),
    .cfg_input_src(cfg_input_src), .cfg_output_dst(cfg_output_dst),
    .cfg_tile_mode(cfg_tile_mode), .cfg_is_tile_final(cfg_is_tile_final),
    .cfg_preserve_membrane(cfg_preserve_membrane), .cfg_t_count(cfg_t_count),
    .cfg_conv_mode(cfg_conv_mode), .cfg_flatten_mode(cfg_flatten_mode),
    .isr_rd_en(isr_rd_en), .isr_rd_addr(isr_rd_addr), .isr_rd_data(isr_rd_data),
    .sbA_wr_en(sbA_wr_en), .sbA_wr_addr(sbA_wr_addr), .sbA_wr_data(sbA_wr_data),
    .sbB_wr_en(sbB_wr_en), .sbB_wr_addr(sbB_wr_addr), .sbB_wr_data(sbB_wr_data),
    .sbA_rd_en(sbA_rd_en), .sbA_rd_addr(sbA_rd_addr), .sbA_rd_data(sbA_rd_data),
    .sbB_rd_en(sbB_rd_en), .sbB_rd_addr(sbB_rd_addr), .sbB_rd_data(sbB_rd_data),
    .tpb_clear_all(tpb_clear_all), .tpb_acc_en(tpb_acc_en),
    .tpb_wr_t(tpb_wr_t), .tpb_wr_j(tpb_wr_j), .tpb_wr_diff(tpb_wr_diff),
    .tpb_rd_en(tpb_rd_en), .tpb_rd_t(tpb_rd_t), .tpb_rd_j(tpb_rd_j),
    .tpb_rd_data(tpb_rd_data),
    .mac_start(mac_start), .mac_done(mac_done), .mac_busy(mac_busy),
    .mac_wl_mask(mac_wl_mask), .mac_cfg_in_dim(mac_cfg_in_dim),
    .mac_cfg_out_dim(mac_cfg_out_dim), .mac_cfg_sum_max(mac_cfg_sum_max),
    .mac_diff_rd_j(mac_diff_rd_j), .mac_diff_rd_data(mac_diff_rd_data)
  );

  // ── Monitor: busy-ever / mac_start-ever over a given window ──────
  int busy_ever, mac_start_ever;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      busy_ever      <= 0;
      mac_start_ever <= 0;
    end else begin
      if (busy)      busy_ever      <= busy_ever + 1;
      if (mac_start) mac_start_ever <= mac_start_ever + 1;
    end
  end

  task automatic clear_monitor;
    begin
      busy_ever      = 0;
      mac_start_ever = 0;
    end
  endtask

  // ── Helpers ──────────────────────────────────────────────────────
  task automatic set_base_cfg;
    begin
      cfg_in_dim            = 16'd4;
      cfg_out_dim           = 16'd2;
      cfg_threshold         = 32'd40;
      cfg_sum_max           = 32'd60;
      cfg_input_src         = V2B_BUF_SEL_INPUT_SRAM;
      cfg_output_dst        = V2B_BUF_SEL_STREAM_A;
      cfg_tile_mode         = 1'b0;
      cfg_is_tile_final     = 1'b1;
      cfg_preserve_membrane = 1'b0;
      cfg_t_count           = 16'd4;
      cfg_conv_mode         = 1'b0;
      cfg_flatten_mode      = 1'b0;
    end
  endtask

  task automatic pulse_start;
    begin
      @(posedge clk);
      start_pulse <= 1;
      @(posedge clk);
      start_pulse <= 0;
    end
  endtask

  // Wait up to N cycles for done_pulse. Returns 1 if seen.
  // (Icarus doesn't support `break`; use disable on a named block instead.)
  task automatic wait_done(output bit saw, input int timeout);
    int i;
    begin : wd_body
      saw = 0;
      for (i = 0; i < timeout; i++) begin
        @(posedge clk);
        if (done_pulse) begin
          saw = 1;
          disable wd_body;
        end
      end
    end
  endtask

  int pass_count = 0, fail_count = 0;

  task automatic check_reject(input [255:0] label,
                              input [7:0] exp_err);
    bit saw;
    bit local_fail;
    begin : check_body
      local_fail = 0;
      clear_monitor();
      pulse_start();
      wait_done(saw, 30);
      if (!saw) begin
        $display("[FAIL] %0s: done_pulse never fired", label);
        fail_count++;
        local_fail = 1;
        disable check_body;
      end
      if (err_code !== exp_err) begin
        $display("[FAIL] %0s: err_code=0x%02h expected 0x%02h",
                 label, err_code, exp_err);
        fail_count++;
        local_fail = 1;
        disable check_body;
      end
      // Allow an extra cycle for counters to settle
      @(posedge clk);
      if (busy_ever != 0) begin
        $display("[FAIL] %0s: busy was asserted %0d cycle(s) (must be 0)",
                 label, busy_ever);
        fail_count++;
        local_fail = 1;
        disable check_body;
      end
      if (mac_start_ever != 0) begin
        $display("[FAIL] %0s: mac_start was asserted %0d cycle(s) (must be 0)",
                 label, mac_start_ever);
        fail_count++;
        local_fail = 1;
        disable check_body;
      end
      $display("[PASS] %0s (err=0x%02h, no busy, no mac_start)", label, err_code);
      pass_count++;
    end
  endtask

  initial begin
    $display("[TB] stage_engine_v2 invalid-config reject regression start");

    set_base_cfg();
    rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);

    // ── T1: cfg_in_dim = 0 ──
    set_base_cfg();
    cfg_in_dim = 16'd0;
    check_reject("T1 cfg_in_dim=0", V2B_STAGE_ERR_DIM_OUT_OF_RANGE);

    // ── T2: cfg_out_dim = 0 ──
    set_base_cfg();
    cfg_out_dim = 16'd0;
    check_reject("T2 cfg_out_dim=0", V2B_STAGE_ERR_DIM_OUT_OF_RANGE);

    // ── T3: cfg_t_count = 0 ──
    set_base_cfg();
    cfg_t_count = 16'd0;
    check_reject("T3 cfg_t_count=0", V2B_STAGE_ERR_DIM_OUT_OF_RANGE);

    // ── T4: cfg_in_dim > P_N_IN ──
    set_base_cfg();
    cfg_in_dim = 16'(N_IN + 1);
    check_reject("T4 cfg_in_dim>P_N_IN", V2B_STAGE_ERR_DIM_OUT_OF_RANGE);

    // ── T5: cfg_out_dim > P_N_OUT ──
    set_base_cfg();
    cfg_out_dim = 16'(N_OUT + 1);
    check_reject("T5 cfg_out_dim>P_N_OUT", V2B_STAGE_ERR_DIM_OUT_OF_RANGE);

    // ── T6: cfg_t_count > P_T_MAX ──
    set_base_cfg();
    cfg_t_count = 16'(T_MAX + 1);
    check_reject("T6 cfg_t_count>P_T_MAX", V2B_STAGE_ERR_DIM_OUT_OF_RANGE);

    // ── T7: src==dst conflict (both STREAM_A, which is not OUTPUT_FIFO) ──
    set_base_cfg();
    cfg_input_src  = V2B_BUF_SEL_STREAM_A;
    cfg_output_dst = V2B_BUF_SEL_STREAM_A;
    check_reject("T7 src==dst==STREAM_A", V2B_STAGE_ERR_SRC_DST_CONFLICT);

    // ── T9 (E2 fix, 2026-05-02): PATCH_UNROLLER + cfg_conv_mode=0 必须 reject ──
    // 旧版守口只检查 cfg_input_src 在编码范围内，不强制 cfg_conv_mode 一致性；
    // 这种组合下 dyn_wl_req_valid 永远拉不起来，FSM 进 S_DYN_WAIT 静默挂死。
    set_base_cfg();
    cfg_input_src  = V2B_BUF_SEL_PATCH_UNROLLER;
    cfg_conv_mode  = 1'b0;
    check_reject("T9 PATCH_UNROLLER+conv_mode=0",
                 V2B_STAGE_ERR_DYN_SRC_NEEDS_CONV_MODE);

    // ── T10 (E2 fix, 2026-05-02): FMAP_FLATTEN + cfg_conv_mode=0 必须 reject ──
    set_base_cfg();
    cfg_input_src  = V2B_BUF_SEL_FMAP_FLATTEN;
    cfg_conv_mode  = 1'b0;
    check_reject("T10 FMAP_FLATTEN+conv_mode=0",
                 V2B_STAGE_ERR_DYN_SRC_NEEDS_CONV_MODE);

    // ── T8: Valid config AFTER all rejects must still work (non-wedge proof) ──
    // If the bug were still present, prior rejects would have entered S_SETUP
    // and left the FSM in a non-IDLE state; a subsequent valid START would
    // collide. Here we expect FSM to be healthy and busy to pulse exactly
    // as in a fresh reset.
    begin
      bit saw;
      set_base_cfg();
      clear_monitor();
      pulse_start();
      // Valid config: wait for busy to go high (might take a cycle or two)
      @(posedge clk); @(posedge clk);
      if (busy_ever == 0) begin
        $display("[FAIL] T8 valid-after-rejects: busy never asserted -> FSM wedged");
        fail_count++;
      end else begin
        // Let it finish. MAC stub never fires mac_done so stage will hang
        // in S_MAC_RUN — that's fine, we only need to confirm it entered
        // a non-IDLE state (busy=1). FSM recovery after reject is proven.
        $display("[PASS] T8 valid-after-rejects (busy asserted, FSM recovered)");
        pass_count++;
      end
    end

    $display("");
    $display("=== Results: %0d PASS, %0d FAIL ===", pass_count, fail_count);
    if (fail_count == 0)
      $display("STAGE_ENGINE_V2_INVALID_CFG_TB_PASS");
    else
      $display("STAGE_ENGINE_V2_INVALID_CFG_TB_FAIL");
    $finish;
  end

  initial begin
    #2_000_000;
    $display("[FAIL] Global timeout");
    $finish;
  end
endmodule
