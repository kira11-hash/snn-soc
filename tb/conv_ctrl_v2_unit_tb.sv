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
//   T4 illegal config (C_out > V2B_MAX_OUT_NEURONS) → done + err=ERR_BAD_COUT
//   T5 valid config → busy=1, FSM 进 S_WAIT_WEIGHT，weight_req 拉起
//   T6 weight_ready_pulse 后 weight_req 清零
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

  logic stage_done_pulse = 1'b0;
  logic [7:0] stage_err_code = '0;
  logic spike_out_valid = 1'b0;
  logic [8:0] spike_out_timestep = '0;
  logic [V2B_MAX_OUT_NEURONS-1:0] spike_out_vec = '0;

  logic fmap_wr_en, fmap_wr_bank_sel;
  logic [31:0] fmap_wr_word_addr, fmap_wr_data;
  logic [3:0] fmap_wr_strb;

  conv_ctrl_v2 dut (
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

    // ── T4: C_out > V2B_MAX_OUT_NEURONS → ERR_BAD_COUT ──
    cfg_C_out <= 16'(V2B_MAX_OUT_NEURONS + 1);
    pulse_start();
    wait_for_done(ok, 50);
    if (!ok) begin
      $display("[FAIL] T4 done_sticky never high after illegal C_out");
      fail_count = fail_count + 1;
    end else begin
      check_int("T4 ERR_BAD_COUT", err_code, 6);  // ERR_BAD_COUT
    end
    clear_done();
    cfg_C_out <= 16'd8;

    // ── T5: 合法配置 → busy + weight_req ──
    pulse_start();
    wait_for_weight_req(ok, 50);
    if (!ok) begin
      $display("[FAIL] T5 weight_req never asserted");
      fail_count = fail_count + 1;
    end else begin
      $display("[PASS] T5 weight_req asserted on first tile");
      pass_count = pass_count + 1;
      check_int("T5 busy=1 during S_WAIT_WEIGHT", busy, 1);
      check_int("T5 err_code=0 on valid cfg", err_code, 0);
    end

    // ── T6: weight_ready_pulse → weight_req cleared ──
    @(posedge clk);
    weight_ready_pulse <= 1'b1;
    @(posedge clk);
    weight_ready_pulse <= 1'b0;
    repeat (5) @(posedge clk);
    if (weight_req !== 1'b0) begin
      $display("[FAIL] T6 weight_req still high after weight_ready_pulse");
      fail_count = fail_count + 1;
    end else begin
      $display("[PASS] T6 weight_req cleared after weight_ready_pulse");
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
