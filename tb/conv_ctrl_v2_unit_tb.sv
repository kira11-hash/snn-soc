`timescale 1ns/1ps
//======================================================================
// tb/conv_ctrl_v2_unit_tb.sv
//
// conv_ctrl_v2 unit smoke TB — 验证配置校验和 WAIT_WEIGHT 握手的核心
// contract。完整 spatial loop / fmap writeback / 多 tile chain 由
// LeNet-5 cosim 端到端覆盖；本 TB 关注：
//
//   T1 reset 后 busy=0, done=0, err=0
//   T2 illegal config (T_count=0) → done + err=ERR_BAD_T
//   T3 illegal config (KKC > V2B_CONV_MAX_KKC) → done + err=ERR_ILLEGAL_KKC
//   T4 illegal config (tile_count / last_tile_valid_count mismatch) → ERR_TILE_CFG_MISMATCH
//   T5 illegal config (stride=0) → ERR_BAD_GEOMETRY
//   T6 illegal config (fmap base 越界) → ERR_FMAP_OOB
//   T7 illegal config (C_out > V2B_MAX_OUT_NEURONS) → ERR_BAD_COUT
//   T8 valid config → busy=1, FSM 进 S_WAIT_WEIGHT，weight_req 拉起
//   T9 运行中 firmware 误发 fmap preload commit → ERR_FMAP_WRITE_WHILE_BUSY
//   T10 weight_ready 长时间不来且 timeout_en=1 → ERR_WEIGHT_TIMEOUT
//   T11 idle 态 firmware 写越界 fmap 地址再 commit → ERR_FMAP_WR_OOB
//   T12 valid config → busy=1, FSM 进 S_WAIT_WEIGHT，weight_req 再次拉起
//   T13 weight_ready_pulse 后 weight_req 清零
//
// 不覆盖（由 LeNet-5 cosim 兜底）：完整 spatial loop / fmap writeback /
// 多 tile chain / spike packer / fmap auto-inc 时序
//======================================================================
module conv_ctrl_v2_unit_tb;

  import snn_soc_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // CFG inputs（默认合法 K=3 stride=1 pad=1 H=W=4 C_in=4 C_out=8 T=4 single tile）
  logic        cfg_conv_mode = 1'b1;
  logic        cfg_flatten_mode = 1'b0;
  logic        cfg_pp_sel = 1'b0;
  logic        cfg_weight_timeout_en = 1'b0;
  logic [15:0] cfg_H = 16'd4;
  logic [15:0] cfg_W = 16'd4;
  logic [15:0] cfg_C_in = 16'd4;
  logic [15:0] cfg_C_out = 16'd8;
  logic [3:0]  cfg_K = 4'd3;
  logic [3:0]  cfg_stride = 4'd1;
  logic [3:0]  cfg_pad = 4'd1;
  logic [15:0] cfg_out_H = 16'd4;
  logic [15:0] cfg_out_W = 16'd4;
  logic [15:0] cfg_T_count = 16'd4;
  logic [15:0] cfg_tile_count = 16'd1;
  logic [15:0] cfg_last_tile_valid_count = 16'd36;  // K*K*C_in = 3*3*4 = 36
  logic [31:0] cfg_fmap_base_word = '0;
  logic [31:0] cfg_out_base_word = 32'd1024;
  logic [31:0] cfg_threshold = 32'd40;
  logic [31:0] cfg_sum_max = 32'd60;

  logic start_pulse = 1'b0;
  logic abort_pulse = 1'b0;
  logic weight_ready_pulse = 1'b0;
  logic done_clear_pulse = 1'b0;
  logic fmap_wr_commit_pulse = 1'b0;
  logic [31:0] fmap_wr_addr = '0;

  logic busy, done_sticky, weight_req;
  logic [7:0] cur_h, cur_w, cur_tile;
  logic [3:0] err_code;
  logic [31:0] perf_cycles;

  logic patch_ctx_valid;
  logic [7:0] patch_ctx_h, patch_ctx_w;
  logic [15:0] patch_ctx_tile_idx;
  logic [3:0] patch_cfg_K, patch_cfg_stride, patch_cfg_pad;
  logic [15:0] patch_cfg_C_in, patch_cfg_H, patch_cfg_W;
  logic [31:0] patch_cfg_fmap_base_word;
  logic [3:0] patch_cfg_stream_words;

  logic flat_ctx_valid;
  logic [15:0] flat_tile_idx, flat_cfg_H, flat_cfg_W, flat_cfg_C;
  logic [31:0] flat_cfg_fmap_base_word;
  logic [3:0] flat_cfg_stream_words;

  logic stage_start_pulse;
  logic [15:0] stage_cfg_in_dim, stage_cfg_out_dim;
  logic [31:0] stage_cfg_threshold, stage_cfg_sum_max;
  logic [V2B_BUF_SEL_W-1:0] stage_cfg_input_src;
  logic [1:0] stage_cfg_output_dst;
  logic stage_cfg_tile_mode, stage_cfg_is_tile_final, stage_cfg_preserve_membrane;
  logic [15:0] stage_cfg_t_count;
  logic stage_clear_tile_buf;
  logic stage_clear_busy = 1'b0;

  logic stage_done_pulse = 1'b0;
  logic [7:0] stage_err_code = '0;
  logic spike_out_valid = 1'b0;
  logic [8:0] spike_out_timestep = '0;
  logic [V2B_MAX_OUT_NEURONS-1:0] spike_out_vec = '0;

  logic fmap_wr_en, fmap_wr_bank_sel;
  logic [31:0] fmap_wr_word_addr, fmap_wr_data;
  logic [3:0] fmap_wr_strb;

  localparam int BANK_WORDS = (V2B_CONV_FMAP_BANK_KIB * 1024) / 4;

  conv_ctrl_v2 #(
    .P_WEIGHT_TIMEOUT_CYCLES(8)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .cfg_conv_mode(cfg_conv_mode), .cfg_flatten_mode(cfg_flatten_mode),
    .cfg_pp_sel(cfg_pp_sel), .cfg_weight_timeout_en(cfg_weight_timeout_en),
    .cfg_H(cfg_H), .cfg_W(cfg_W), .cfg_C_in(cfg_C_in), .cfg_C_out(cfg_C_out),
    .cfg_K(cfg_K), .cfg_stride(cfg_stride), .cfg_pad(cfg_pad),
    .cfg_out_H(cfg_out_H), .cfg_out_W(cfg_out_W), .cfg_T_count(cfg_T_count),
    .cfg_tile_count(cfg_tile_count),
    .cfg_last_tile_valid_count(cfg_last_tile_valid_count),
    .cfg_fmap_base_word(cfg_fmap_base_word),
    .cfg_out_base_word(cfg_out_base_word),
    .cfg_threshold(cfg_threshold), .cfg_sum_max(cfg_sum_max),
    .start_pulse(start_pulse), .abort_pulse(abort_pulse),
    .weight_ready_pulse(weight_ready_pulse),
    .done_clear_pulse(done_clear_pulse),
    .fmap_wr_commit_pulse(fmap_wr_commit_pulse), .fmap_wr_addr(fmap_wr_addr),
    .busy(busy), .done_sticky(done_sticky), .weight_req(weight_req),
    .current_pixel_h(cur_h), .current_pixel_w(cur_w),
    .current_tile_idx(cur_tile),
    .err_code(err_code), .perf_cycles(perf_cycles),
    .patch_ctx_valid(patch_ctx_valid),
    .patch_ctx_h(patch_ctx_h), .patch_ctx_w(patch_ctx_w),
    .patch_ctx_tile_idx(patch_ctx_tile_idx),
    .patch_cfg_K(patch_cfg_K), .patch_cfg_stride(patch_cfg_stride),
    .patch_cfg_pad(patch_cfg_pad),
    .patch_cfg_C_in(patch_cfg_C_in),
    .patch_cfg_H(patch_cfg_H), .patch_cfg_W(patch_cfg_W),
    .patch_cfg_fmap_base_word(patch_cfg_fmap_base_word),
    .patch_cfg_stream_words(patch_cfg_stream_words),
    .flat_ctx_valid(flat_ctx_valid), .flat_tile_idx(flat_tile_idx),
    .flat_cfg_H(flat_cfg_H), .flat_cfg_W(flat_cfg_W), .flat_cfg_C(flat_cfg_C),
    .flat_cfg_fmap_base_word(flat_cfg_fmap_base_word),
    .flat_cfg_stream_words(flat_cfg_stream_words),
    .stage_start_pulse(stage_start_pulse),
    .stage_cfg_in_dim(stage_cfg_in_dim),
    .stage_cfg_out_dim(stage_cfg_out_dim),
    .stage_cfg_threshold(stage_cfg_threshold),
    .stage_cfg_sum_max(stage_cfg_sum_max),
    .stage_cfg_input_src(stage_cfg_input_src),
    .stage_cfg_output_dst(stage_cfg_output_dst),
    .stage_cfg_tile_mode(stage_cfg_tile_mode),
    .stage_cfg_is_tile_final(stage_cfg_is_tile_final),
    .stage_cfg_preserve_membrane(stage_cfg_preserve_membrane),
    .stage_cfg_t_count(stage_cfg_t_count),
    .stage_clear_tile_buf(stage_clear_tile_buf),
    .stage_clear_busy(stage_clear_busy),
    .stage_done_pulse(stage_done_pulse), .stage_err_code(stage_err_code),
    .spike_out_valid(spike_out_valid),
    .spike_out_timestep(spike_out_timestep),
    .spike_out_vec(spike_out_vec),
    .fmap_wr_en(fmap_wr_en), .fmap_wr_bank_sel(fmap_wr_bank_sel),
    .fmap_wr_word_addr(fmap_wr_word_addr),
    .fmap_wr_data(fmap_wr_data), .fmap_wr_strb(fmap_wr_strb)
  );

  integer pass_count = 0;
  integer fail_count = 0;

  task automatic check_int(input string tag, input integer got, input integer exp);
    if (got === exp) begin
      $display("[PASS] %s got=%0d exp=%0d", tag, got, exp);
      pass_count = pass_count + 1;
    end else begin
      $display("[FAIL] %s got=%0d exp=%0d", tag, got, exp);
      fail_count = fail_count + 1;
    end
  endtask

  task automatic pulse_start;
    @(posedge clk);
    start_pulse <= 1'b1;
    @(posedge clk);
    start_pulse <= 1'b0;
  endtask

  task automatic wait_for_done(output bit ok, input int max_cycles);
    int i;
    begin : body
      ok = 0;
      for (i = 0; i < max_cycles; i++) begin
        @(posedge clk);
        if (done_sticky) begin ok = 1; disable body; end
      end
    end
  endtask

  task automatic wait_for_weight_req(output bit ok, input int max_cycles);
    int i;
    begin : body
      ok = 0;
      for (i = 0; i < max_cycles; i++) begin
        @(posedge clk);
        if (weight_req) begin ok = 1; disable body; end
      end
    end
  endtask

  task automatic clear_done;
    @(posedge clk);
    done_clear_pulse <= 1'b1;
    @(posedge clk);
    done_clear_pulse <= 1'b0;
  endtask

  task automatic pulse_abort;
    @(posedge clk);
    abort_pulse <= 1'b1;
    @(posedge clk);
    abort_pulse <= 1'b0;
  endtask

  task automatic pulse_fmap_commit(input [31:0] addr_word);
    fmap_wr_addr <= addr_word;
    @(posedge clk);
    fmap_wr_commit_pulse <= 1'b1;
    @(posedge clk);
    fmap_wr_commit_pulse <= 1'b0;
  endtask

  initial begin
    bit ok;
    $display("[INFO] conv_ctrl_v2_unit_tb start");
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // ── T1: 复位后状态 ──
    check_int("T1 busy=0 after reset", busy, 0);
    check_int("T1 done_sticky=0 after reset", done_sticky, 0);
    check_int("T1 err_code=0 after reset", err_code, 0);

    // ── T2: T_count=0 → ERR_BAD_T ──
    cfg_T_count <= 16'd0;
    pulse_start();
    wait_for_done(ok, 50);
    if (!ok) begin
      $display("[FAIL] T2 done_sticky never high after T=0");
      fail_count = fail_count + 1;
    end else begin
      check_int("T2 ERR_BAD_T (T_count=0)", err_code, 5);  // ERR_BAD_T = 4'd5
    end
    clear_done();
    cfg_T_count <= 16'd4;  // restore

    // ── T3: K*K*C_in > 1152 → ERR_ILLEGAL_KKC ──
    // K=5 C_in=128 → 5*5*128 = 3200 > V2B_CONV_MAX_KKC=1152
    cfg_K        <= 4'd5;
    cfg_C_in     <= 16'd128;
    cfg_last_tile_valid_count <= 16'd200;  // 任意（守口先撞 KKC）
    pulse_start();
    wait_for_done(ok, 50);
    if (!ok) begin
      $display("[FAIL] T3 done_sticky never high after illegal KKC");
      fail_count = fail_count + 1;
    end else begin
      check_int("T3 ERR_ILLEGAL_KKC (K=5,C_in=128)", err_code, 1);  // ERR_ILLEGAL_KKC
    end
    clear_done();
    cfg_K        <= 4'd3;
    cfg_C_in     <= 16'd4;
    cfg_last_tile_valid_count <= 16'd36;

    // ── T4: tile_count mismatch → ERR_TILE_CFG_MISMATCH ──
    cfg_tile_count <= 16'd2;
    pulse_start();
    wait_for_done(ok, 50);
    if (!ok) begin
      $display("[FAIL] T4 done_sticky never high after tile mismatch");
      fail_count = fail_count + 1;
    end else begin
      check_int("T4 ERR_TILE_CFG_MISMATCH", err_code, 2);
    end
    clear_done();
    cfg_tile_count <= 16'd1;

    // ── T5: stride=0 → ERR_BAD_GEOMETRY ──
    cfg_stride <= 4'd0;
    pulse_start();
    wait_for_done(ok, 50);
    if (!ok) begin
      $display("[FAIL] T5 done_sticky never high after bad geometry");
      fail_count = fail_count + 1;
    end else begin
      check_int("T5 ERR_BAD_GEOMETRY (stride=0)", err_code, 3);
    end
    clear_done();
    cfg_stride <= 4'd1;

    // ── T6: fmap base 越界 → ERR_FMAP_OOB ──
    cfg_fmap_base_word <= BANK_WORDS - 32'd32;
    pulse_start();
    wait_for_done(ok, 50);
    if (!ok) begin
      $display("[FAIL] T6 done_sticky never high after fmap OOB");
      fail_count = fail_count + 1;
    end else begin
      check_int("T6 ERR_FMAP_OOB", err_code, 4);
    end
    clear_done();
    cfg_fmap_base_word <= 32'd0;

    // ── T7: C_out > V2B_MAX_OUT_NEURONS → ERR_BAD_COUT ──
    cfg_C_out <= 16'(V2B_MAX_OUT_NEURONS + 1);
    pulse_start();
    wait_for_done(ok, 50);
    if (!ok) begin
      $display("[FAIL] T7 done_sticky never high after illegal C_out");
      fail_count = fail_count + 1;
    end else begin
      check_int("T7 ERR_BAD_COUT", err_code, 6);  // ERR_BAD_COUT
    end
    clear_done();
    cfg_C_out <= 16'd8;

    // ── T8: 合法配置 → busy + weight_req ──
    pulse_start();
    wait_for_weight_req(ok, 50);
    if (!ok) begin
      $display("[FAIL] T8 weight_req never asserted");
      fail_count = fail_count + 1;
    end else begin
      $display("[PASS] T8 weight_req asserted on first tile");
      pass_count = pass_count + 1;
      check_int("T8 busy=1 during S_WAIT_WEIGHT", busy, 1);
      check_int("T8 err_code=0 on valid cfg", err_code, 0);
    end

    // ── T9: busy 时 firmware preload commit → ERR_FMAP_WRITE_WHILE_BUSY ──
    pulse_fmap_commit(32'd0);
    wait_for_done(ok, 10);
    if (!ok) begin
      $display("[FAIL] T9 done_sticky never high after busy fmap write");
      fail_count = fail_count + 1;
    end else begin
      check_int("T9 ERR_FMAP_WRITE_WHILE_BUSY", err_code, 7);
    end
    pulse_abort();
    repeat (4) @(posedge clk);
    clear_done();

    // ── T10: timeout_en=1 且 weight_ready 不来 → ERR_WEIGHT_TIMEOUT ──
    cfg_weight_timeout_en <= 1'b1;
    pulse_start();
    wait_for_done(ok, 40);
    if (!ok) begin
      $display("[FAIL] T10 done_sticky never high after weight timeout");
      fail_count = fail_count + 1;
    end else begin
      check_int("T10 ERR_WEIGHT_TIMEOUT", err_code, 8);
    end
    clear_done();
    cfg_weight_timeout_en <= 1'b0;

    // ── T11: idle 态写越界 fmap 地址再 commit → ERR_FMAP_WR_OOB ──
    pulse_fmap_commit(BANK_WORDS);
    wait_for_done(ok, 10);
    if (!ok) begin
      $display("[FAIL] T11 done_sticky never high after fmap write OOB");
      fail_count = fail_count + 1;
    end else begin
      check_int("T11 ERR_FMAP_WR_OOB", err_code, 9);
    end
    clear_done();
    fmap_wr_addr <= '0;

    // ── T12: 合法配置 → busy + weight_req（二次启动，证明 FSM 恢复） ──
    pulse_start();
    wait_for_weight_req(ok, 50);
    if (!ok) begin
      $display("[FAIL] T12 weight_req never asserted on rerun");
      fail_count = fail_count + 1;
    end else begin
      $display("[PASS] T12 weight_req asserted again after prior errors");
      pass_count = pass_count + 1;
      check_int("T12 busy=1 during S_WAIT_WEIGHT", busy, 1);
      check_int("T12 err_code=0 on valid rerun", err_code, 0);
    end

    // ── T13: weight_ready_pulse → weight_req cleared ──
    @(posedge clk);
    weight_ready_pulse <= 1'b1;
    @(posedge clk);
    weight_ready_pulse <= 1'b0;
    repeat (5) @(posedge clk);
    if (weight_req !== 1'b0) begin
      $display("[FAIL] T13 weight_req still high after weight_ready_pulse");
      fail_count = fail_count + 1;
    end else begin
      $display("[PASS] T13 weight_req cleared after weight_ready_pulse");
      pass_count = pass_count + 1;
    end

    // 最后 abort 复位 FSM
    @(posedge clk);
    abort_pulse <= 1'b1;
    @(posedge clk);
    abort_pulse <= 1'b0;

    repeat (10) @(posedge clk);
    $display("");
    $display("=== Results: %0d PASS, %0d FAIL ===", pass_count, fail_count);
    if (fail_count == 0)
      $display("CONV_CTRL_V2_UNIT_TB_PASS");
    else
      $display("CONV_CTRL_V2_UNIT_TB_FAIL");
    $finish;
  end

  initial begin
    #500000;
    $display("[ERROR] timeout");
    $display("CONV_CTRL_V2_UNIT_TB_FAIL (timeout)");
    $finish;
  end

endmodule
