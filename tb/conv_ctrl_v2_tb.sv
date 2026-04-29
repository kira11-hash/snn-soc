`timescale 1ns/1ps
module conv_ctrl_v2_tb;
  import snn_soc_pkg::*;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic cfg_conv_mode, cfg_flatten_mode, cfg_pp_sel, cfg_weight_timeout_en;
  logic [15:0] cfg_H, cfg_W, cfg_C_in, cfg_C_out, cfg_out_H, cfg_out_W;
  logic [3:0] cfg_K, cfg_stride, cfg_pad;
  logic [15:0] cfg_T_count, cfg_tile_count, cfg_last_tile_valid_count;
  logic [31:0] cfg_fmap_base_word, cfg_out_base_word, cfg_threshold, cfg_sum_max;
  logic start_pulse, abort_pulse, weight_ready_pulse, done_clear_pulse;
  logic fmap_wr_commit_pulse;
  logic [31:0] fmap_wr_addr;

  logic busy, done_sticky, weight_req;
  logic [7:0] current_pixel_h, current_pixel_w, current_tile_idx;
  logic [3:0] err_code;
  logic [31:0] perf_cycles;

  logic patch_ctx_valid;
  logic [7:0] patch_ctx_h, patch_ctx_w;
  logic [15:0] patch_ctx_tile_idx;
  logic [3:0] patch_cfg_K, patch_cfg_stride, patch_cfg_pad, patch_cfg_stream_words;
  logic [15:0] patch_cfg_C_in, patch_cfg_H, patch_cfg_W;
  logic [31:0] patch_cfg_fmap_base_word;
  logic flat_ctx_valid;
  logic [15:0] flat_tile_idx, flat_cfg_H, flat_cfg_W, flat_cfg_C;
  logic [31:0] flat_cfg_fmap_base_word;
  logic [3:0] flat_cfg_stream_words;

  logic stage_start_pulse;
  logic [15:0] stage_cfg_in_dim, stage_cfg_out_dim, stage_cfg_t_count;
  logic [31:0] stage_cfg_threshold, stage_cfg_sum_max;
  logic [V2B_BUF_SEL_W-1:0] stage_cfg_input_src;
  logic [1:0] stage_cfg_output_dst;
  logic stage_cfg_tile_mode, stage_cfg_is_tile_final, stage_cfg_preserve_membrane;
  logic stage_clear_tile_buf;
  logic stage_done_pulse;
  logic [7:0] stage_err_code;
  logic spike_out_valid;
  logic [8:0] spike_out_timestep;
  logic [V2B_MAX_OUT_NEURONS-1:0] spike_out_vec;
  logic fmap_wr_en, fmap_wr_bank_sel;
  logic [31:0] fmap_wr_word_addr, fmap_wr_data;
  logic [3:0] fmap_wr_strb;

  int errors = 0;
  int stage_start_count = 0;

  conv_ctrl_v2 #(.P_WEIGHT_TIMEOUT_CYCLES(8)) dut (
    .clk(clk), .rst_n(rst_n),
    .cfg_conv_mode(cfg_conv_mode), .cfg_flatten_mode(cfg_flatten_mode),
    .cfg_pp_sel(cfg_pp_sel), .cfg_weight_timeout_en(cfg_weight_timeout_en),
    .cfg_H(cfg_H), .cfg_W(cfg_W), .cfg_C_in(cfg_C_in), .cfg_C_out(cfg_C_out),
    .cfg_K(cfg_K), .cfg_stride(cfg_stride), .cfg_pad(cfg_pad),
    .cfg_out_H(cfg_out_H), .cfg_out_W(cfg_out_W), .cfg_T_count(cfg_T_count),
    .cfg_tile_count(cfg_tile_count), .cfg_last_tile_valid_count(cfg_last_tile_valid_count),
    .cfg_fmap_base_word(cfg_fmap_base_word), .cfg_out_base_word(cfg_out_base_word),
    .cfg_threshold(cfg_threshold), .cfg_sum_max(cfg_sum_max),
    .start_pulse(start_pulse), .abort_pulse(abort_pulse),
    .weight_ready_pulse(weight_ready_pulse), .done_clear_pulse(done_clear_pulse),
    .fmap_wr_commit_pulse(fmap_wr_commit_pulse), .fmap_wr_addr(fmap_wr_addr),
    .busy(busy), .done_sticky(done_sticky), .weight_req(weight_req),
    .current_pixel_h(current_pixel_h), .current_pixel_w(current_pixel_w),
    .current_tile_idx(current_tile_idx), .err_code(err_code), .perf_cycles(perf_cycles),
    .patch_ctx_valid(patch_ctx_valid), .patch_ctx_h(patch_ctx_h), .patch_ctx_w(patch_ctx_w),
    .patch_ctx_tile_idx(patch_ctx_tile_idx), .patch_cfg_K(patch_cfg_K),
    .patch_cfg_stride(patch_cfg_stride), .patch_cfg_pad(patch_cfg_pad),
    .patch_cfg_C_in(patch_cfg_C_in), .patch_cfg_H(patch_cfg_H), .patch_cfg_W(patch_cfg_W),
    .patch_cfg_fmap_base_word(patch_cfg_fmap_base_word),
    .patch_cfg_stream_words(patch_cfg_stream_words),
    .flat_ctx_valid(flat_ctx_valid), .flat_tile_idx(flat_tile_idx),
    .flat_cfg_H(flat_cfg_H), .flat_cfg_W(flat_cfg_W), .flat_cfg_C(flat_cfg_C),
    .flat_cfg_fmap_base_word(flat_cfg_fmap_base_word),
    .flat_cfg_stream_words(flat_cfg_stream_words),
    .stage_start_pulse(stage_start_pulse), .stage_cfg_in_dim(stage_cfg_in_dim),
    .stage_cfg_out_dim(stage_cfg_out_dim), .stage_cfg_threshold(stage_cfg_threshold),
    .stage_cfg_sum_max(stage_cfg_sum_max), .stage_cfg_input_src(stage_cfg_input_src),
    .stage_cfg_output_dst(stage_cfg_output_dst), .stage_cfg_tile_mode(stage_cfg_tile_mode),
    .stage_cfg_is_tile_final(stage_cfg_is_tile_final),
    .stage_cfg_preserve_membrane(stage_cfg_preserve_membrane),
    .stage_cfg_t_count(stage_cfg_t_count), .stage_clear_tile_buf(stage_clear_tile_buf),
    .stage_done_pulse(stage_done_pulse), .stage_err_code(stage_err_code),
    .spike_out_valid(spike_out_valid), .spike_out_timestep(spike_out_timestep),
    .spike_out_vec(spike_out_vec),
    .fmap_wr_en(fmap_wr_en), .fmap_wr_bank_sel(fmap_wr_bank_sel),
    .fmap_wr_word_addr(fmap_wr_word_addr), .fmap_wr_data(fmap_wr_data),
    .fmap_wr_strb(fmap_wr_strb)
  );

  always @(posedge clk) begin
    if (rst_n && stage_start_pulse) stage_start_count <= stage_start_count + 1;
  end

  task automatic set_base_cfg;
    begin
      cfg_conv_mode = 1'b1;
      cfg_flatten_mode = 1'b0;
      cfg_pp_sel = 1'b0;
      cfg_weight_timeout_en = 1'b0;
      cfg_H = 16'd8; cfg_W = 16'd8; cfg_C_in = 16'd4; cfg_C_out = 16'd8;
      cfg_K = 4'd3; cfg_stride = 4'd1; cfg_pad = 4'd1;
      cfg_out_H = 16'd8; cfg_out_W = 16'd8;
      cfg_T_count = 16'd10;
      cfg_tile_count = 16'd1;
      cfg_last_tile_valid_count = 16'd36;
      cfg_fmap_base_word = 32'd0;
      cfg_out_base_word = 32'd0;
      cfg_threshold = 32'd4;
      cfg_sum_max = V2B_ADC_MAX;
      fmap_wr_addr = 32'd0;
    end
  endtask

  task automatic pulse_start;
    begin
      @(posedge clk); start_pulse <= 1'b1;
      @(posedge clk); start_pulse <= 1'b0;
    end
  endtask

  task automatic clear_done;
    begin
      @(posedge clk); done_clear_pulse <= 1'b1;
      @(posedge clk); done_clear_pulse <= 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic expect_done_err(input string tag, input [3:0] exp);
    int guard;
    begin
      pulse_start();
      guard = 0;
      while (!done_sticky && guard < 1000) begin @(posedge clk); guard++; end
      if (!done_sticky || err_code !== exp) begin
        $display("[FAIL] %s err got=%0d exp=%0d done=%0d", tag, err_code, exp, done_sticky);
        errors++;
      end else begin
        $display("[PASS] %s err=%0d", tag, err_code);
      end
      clear_done();
    end
  endtask

  initial begin
    start_pulse = 0; abort_pulse = 0; weight_ready_pulse = 0; done_clear_pulse = 0;
    fmap_wr_commit_pulse = 0; stage_done_pulse = 0; stage_err_code = 0;
    spike_out_valid = 0; spike_out_timestep = 0; spike_out_vec = '0;
    set_base_cfg();

    rst_n = 0;
    repeat (6) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);

    set_base_cfg(); cfg_K = 4'd5; cfg_C_in = 16'd128;
    cfg_tile_count = 16'd13; cfg_last_tile_valid_count = 16'd128;
    expect_done_err("ERR_ILLEGAL_KKC", 4'd1);

    set_base_cfg(); cfg_tile_count = 16'd2;
    expect_done_err("ERR_TILE_CFG_MISMATCH", 4'd2);

    set_base_cfg(); cfg_H = 16'd65; cfg_out_H = 16'd65;
    expect_done_err("ERR_BAD_GEOMETRY", 4'd3);

    set_base_cfg(); cfg_fmap_base_word = 32'd65530;
    expect_done_err("ERR_FMAP_OOB", 4'd4);

    set_base_cfg(); cfg_T_count = 16'd0;
    expect_done_err("ERR_BAD_T", 4'd5);

    set_base_cfg(); cfg_C_out = 16'd0;
    expect_done_err("ERR_BAD_COUT", 4'd6);

    set_base_cfg(); cfg_weight_timeout_en = 1'b1;
    pulse_start();
    wait (weight_req);
    repeat (20) @(posedge clk);
    if (!done_sticky || err_code !== 4'd8) begin
      $display("[FAIL] ERR_WEIGHT_TIMEOUT got=%0d done=%0d", err_code, done_sticky);
      errors++;
    end else $display("[PASS] ERR_WEIGHT_TIMEOUT err=8");
    clear_done();

    set_base_cfg();
    fmap_wr_addr = 32'd65536;
    @(posedge clk); fmap_wr_commit_pulse <= 1'b1;
    @(posedge clk); fmap_wr_commit_pulse <= 1'b0;
    repeat (3) @(posedge clk);
    if (!done_sticky || err_code !== 4'd9) begin
      $display("[FAIL] ERR_FMAP_WR_OOB got=%0d done=%0d", err_code, done_sticky);
      errors++;
    end else $display("[PASS] ERR_FMAP_WR_OOB err=9");
    clear_done();

    set_base_cfg();
    pulse_start();
    wait (weight_req);
    if (stage_start_count != 0) begin
      $display("[FAIL] stage started before weight_ready");
      errors++;
    end else $display("[PASS] WAIT_WEIGHT blocks stage start");
    @(posedge clk); fmap_wr_commit_pulse <= 1'b1;
    @(posedge clk); fmap_wr_commit_pulse <= 1'b0;
    repeat (3) @(posedge clk);
    if (!done_sticky || err_code !== 4'd7) begin
      $display("[FAIL] ERR_FMAP_WRITE_WHILE_BUSY got=%0d done=%0d", err_code, done_sticky);
      errors++;
    end else $display("[PASS] ERR_FMAP_WRITE_WHILE_BUSY err=7");
    clear_done();

    set_base_cfg();
    stage_start_count = 0;
    pulse_start();
    wait (weight_req);
    repeat (3) @(posedge clk);
    @(posedge clk); weight_ready_pulse <= 1'b1;
    @(posedge clk); weight_ready_pulse <= 1'b0;
    wait (stage_start_pulse);
    if (stage_cfg_input_src !== V2B_BUF_SEL_PATCH_UNROLLER ||
        stage_cfg_in_dim !== 16'd36 ||
        stage_cfg_out_dim !== 16'd8) begin
      $display("[FAIL] stage config after weight_ready");
      errors++;
    end else begin
      $display("[PASS] weight_ready launches stage cfg_in_dim=%0d", stage_cfg_in_dim);
    end

    if (errors == 0) $display("CONV_CTRL_V2_TB_PASS");
    else             $display("CONV_CTRL_V2_TB_FAIL errors=%0d", errors);
    $finish;
  end

  initial begin
    #5_000_000;
    $display("CONV_CTRL_V2_TB_TIMEOUT");
    $finish;
  end
endmodule
