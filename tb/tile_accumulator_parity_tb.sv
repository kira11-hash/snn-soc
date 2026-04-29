`timescale 1ns/1ps
//======================================================================
// tb/tile_accumulator_parity_tb.sv
//
// 【B3 tile-mode bit-parity TB】
// 驱动 stage_engine_v2 TWICE with cfg_tile_mode=1，模拟固件分 tile
// 调用。目的是验证 tile_partial_buf [T][N_out] signed accumulator 和
// is_tile_final LIF sweep 在 RTL 端与 Python _run_stage_streamed_rate_tiled
// bit-exact。
//
// Case (in_dim=16 split into 2 tiles × 8 WL, out_dim=4, T=16):
//   - Tile 0: cfg_in_dim=8, wl_mask bits[0..7]=wl_stream[t][0..7],
//             weights = tile0_w_pos/neg, tile_mode=1, is_tile_final=0
//             → accumulates per-t per-j diff into tile_partial_buf[t][j]
//   - Tile 1: cfg_in_dim=8, wl_mask bits[0..7]=wl_stream[t][8..15],
//             weights = tile1_w_pos/neg, tile_mode=1, is_tile_final=1
//             → adds tile 1 diff, then LIF sweep on tpb, write STREAM_A
//
// 通过：per-class counts from STREAM_A == Python golden counts.
//
// Golden 来源：python_multilayer/results_multilayer/tile_golden/
//======================================================================
module tile_accumulator_parity_tb;

  import snn_soc_pkg::*;

  localparam int IN_DIM_FULL = 16;
  localparam int IN_DIM_TILE = 8;
  localparam int OUT_DIM     = 4;
  localparam int T           = 16;
  localparam int THR         = 6;
  localparam int SUM_MAX_TILE = IN_DIM_TILE * 15;  // 120 per tile

  localparam int P_T_MAX = V2B_MAX_TIMESTEPS;
  localparam int P_N_IN  = V2B_NUM_INPUTS;
  localparam int P_N_OUT = V2B_MAX_OUT_NEURONS;
  localparam int P_PARTIAL_W = V2B_PARTIAL_WIDTH;
  localparam int T_AW = $clog2(P_T_MAX);
  localparam int J_AW = $clog2(P_N_OUT);
  localparam int I_AW = $clog2(P_N_IN);

  // ── Clock / reset ────────────────────────────────────────────────
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // Stage engine control/cfg
  logic start_pulse = 0;
  logic busy, done_pulse;
  logic [7:0] err_code;
  logic [T_AW-1:0] debug_t_idx;
  logic [15:0] cfg_in_dim, cfg_out_dim;
  logic [31:0] cfg_threshold, cfg_sum_max;
  logic [V2B_BUF_SEL_W-1:0] cfg_input_src;
  logic [1:0]  cfg_output_dst;
  logic cfg_tile_mode, cfg_is_tile_final, cfg_preserve_membrane;
  logic [15:0] cfg_t_count;

  // ISR
  logic isr_rd_en;
  logic [T_AW-1:0] isr_rd_addr;
  logic [P_N_IN-1:0] isr_rd_data;
  logic isr_wr_en;
  logic [T_AW-1:0] isr_wr_addr;
  logic [P_N_IN-1:0] isr_wr_data;
  logic isr_clear_all;

  // Stream bufs
  logic sbA_wr_en;
  logic [T_AW-1:0] sbA_wr_addr;
  logic [P_N_OUT-1:0] sbA_wr_data;
  logic sbA_rd_en_se, sbA_rd_en_tb = 0;
  logic [T_AW-1:0] sbA_rd_addr_se, sbA_rd_addr_tb = '0;
  logic [P_N_OUT-1:0] sbA_rd_data;
  logic sbA_rd_en_mux;
  logic [T_AW-1:0] sbA_rd_addr_mux;
  assign sbA_rd_en_mux   = sbA_rd_en_se | sbA_rd_en_tb;
  assign sbA_rd_addr_mux = sbA_rd_en_tb ? sbA_rd_addr_tb : sbA_rd_addr_se;
  logic sbA_clear = 0;

  logic sbB_wr_en;
  logic [T_AW-1:0] sbB_wr_addr;
  logic [P_N_OUT-1:0] sbB_wr_data;
  logic sbB_rd_en = 0;
  logic [T_AW-1:0] sbB_rd_addr = '0;
  logic [P_N_OUT-1:0] sbB_rd_data;

  // tile_partial_buf
  logic tpb_clear_all_se, tpb_acc_en;
  logic [T_AW-1:0] tpb_wr_t, tpb_rd_t;
  logic [J_AW-1:0] tpb_wr_j, tpb_rd_j;
  logic signed [P_PARTIAL_W-1:0] tpb_wr_diff, tpb_rd_data;
  logic tpb_rd_en;
  logic tpb_clear_pulse = 0;

  // MAC
  logic mac_w_load_en = 0;
  logic [I_AW-1:0] mac_w_load_i = '0;
  logic [J_AW-1:0] mac_w_load_j = '0;
  logic [3:0] mac_w_load_pos = '0, mac_w_load_neg = '0;
  logic mac_start, mac_done, mac_busy;
  logic [P_N_IN-1:0] mac_wl_mask;
  logic [15:0] mac_cfg_in_dim, mac_cfg_out_dim;
  logic [31:0] mac_cfg_sum_max;
  logic [J_AW-1:0] mac_diff_rd_j;
  logic signed [P_PARTIAL_W-1:0] mac_diff_rd_data;

  // ── DUTs ───────────────────────────────────────────────────────
  input_stream_sram u_isr (
    .clk(clk), .rst_n(rst_n),
    .wr_en(isr_wr_en), .wr_addr(isr_wr_addr), .wr_data(isr_wr_data),
    .rd_en(isr_rd_en), .rd_addr(isr_rd_addr), .rd_data(isr_rd_data),
    .clear_all(isr_clear_all)
  );

  stream_buffer_v2 u_sbA (
    .clk(clk), .rst_n(rst_n),
    .wr_en(sbA_wr_en), .wr_addr(sbA_wr_addr), .wr_data(sbA_wr_data),
    .rd_en(sbA_rd_en_mux), .rd_addr(sbA_rd_addr_mux), .rd_data(sbA_rd_data),
    .clear_all(sbA_clear)
  );

  stream_buffer_v2 u_sbB (
    .clk(clk), .rst_n(rst_n),
    .wr_en(sbB_wr_en), .wr_addr(sbB_wr_addr), .wr_data(sbB_wr_data),
    .rd_en(sbB_rd_en), .rd_addr(sbB_rd_addr), .rd_data(sbB_rd_data),
    .clear_all(1'b0)
  );

  tile_partial_buf u_tpb (
    .clk(clk), .rst_n(rst_n),
    .clear_all(tpb_clear_all_se | tpb_clear_pulse),
    .acc_en(tpb_acc_en), .wr_t(tpb_wr_t), .wr_j(tpb_wr_j), .wr_diff(tpb_wr_diff),
    .rd_en(tpb_rd_en), .rd_t(tpb_rd_t), .rd_j(tpb_rd_j),
    .rd_data(tpb_rd_data)
  );

  cim_mac_behavioral_v2 #(.P_ADC_BITS(10)) u_mac (
    .clk(clk), .rst_n(rst_n),
    .w_load_en(mac_w_load_en), .w_load_i(mac_w_load_i), .w_load_j(mac_w_load_j),
    .w_load_pos_data(mac_w_load_pos), .w_load_neg_data(mac_w_load_neg),
    .mac_start(mac_start), .wl_mask(mac_wl_mask),
    .cfg_in_dim(mac_cfg_in_dim), .cfg_out_dim(mac_cfg_out_dim),
    .cfg_sum_max(mac_cfg_sum_max),
    .mac_busy(mac_busy), .mac_done(mac_done),
    .diff_rd_j(mac_diff_rd_j), .diff_rd_data(mac_diff_rd_data)
  );

  stage_engine_v2 u_se (
    .clk(clk), .rst_n(rst_n),
    .start_pulse(start_pulse), .busy(busy), .done_pulse(done_pulse),
    .err_code(err_code), .debug_t_idx(debug_t_idx),
    .cfg_in_dim(cfg_in_dim), .cfg_out_dim(cfg_out_dim),
    .cfg_threshold(cfg_threshold), .cfg_sum_max(cfg_sum_max),
    .cfg_input_src(cfg_input_src), .cfg_output_dst(cfg_output_dst),
    .cfg_tile_mode(cfg_tile_mode), .cfg_is_tile_final(cfg_is_tile_final),
    .cfg_preserve_membrane(cfg_preserve_membrane), .cfg_t_count(cfg_t_count),
    .isr_rd_en(isr_rd_en), .isr_rd_addr(isr_rd_addr), .isr_rd_data(isr_rd_data),
    .sbA_wr_en(sbA_wr_en), .sbA_wr_addr(sbA_wr_addr), .sbA_wr_data(sbA_wr_data),
    .sbB_wr_en(sbB_wr_en), .sbB_wr_addr(sbB_wr_addr), .sbB_wr_data(sbB_wr_data),
    .sbA_rd_en(sbA_rd_en_se), .sbA_rd_addr(sbA_rd_addr_se), .sbA_rd_data(sbA_rd_data),
    .sbB_rd_en(), .sbB_rd_addr(), .sbB_rd_data(sbB_rd_data),
    .tpb_clear_all(tpb_clear_all_se), .tpb_acc_en(tpb_acc_en),
    .tpb_wr_t(tpb_wr_t), .tpb_wr_j(tpb_wr_j), .tpb_wr_diff(tpb_wr_diff),
    .tpb_rd_en(tpb_rd_en), .tpb_rd_t(tpb_rd_t), .tpb_rd_j(tpb_rd_j),
    .tpb_rd_data(tpb_rd_data),
    .mac_start(mac_start), .mac_done(mac_done), .mac_busy(mac_busy),
    .mac_wl_mask(mac_wl_mask), .mac_cfg_in_dim(mac_cfg_in_dim),
    .mac_cfg_out_dim(mac_cfg_out_dim), .mac_cfg_sum_max(mac_cfg_sum_max),
    .mac_diff_rd_j(mac_diff_rd_j), .mac_diff_rd_data(mac_diff_rd_data)
  );

  // ── Golden storage ─────────────────────────────────────────────
  logic [3:0] tile0_w_pos [0:IN_DIM_TILE*OUT_DIM-1];
  logic [3:0] tile0_w_neg [0:IN_DIM_TILE*OUT_DIM-1];
  logic [3:0] tile1_w_pos [0:IN_DIM_TILE*OUT_DIM-1];
  logic [3:0] tile1_w_neg [0:IN_DIM_TILE*OUT_DIM-1];
  logic [15:0] wl_stream_gold [0:T-1];
  int expected_counts [0:OUT_DIM-1];

  int errors = 0;

  // ── Tasks ─────────────────────────────────────────────────────
  task automatic load_isr_tile(input int tile_idx);
    // tile 0 = bits[7:0] of wl_stream, tile 1 = bits[15:8]
    begin
      assign isr_clear_all = 1'b0;
      for (int t = 0; t < T; t++) begin
        @(posedge clk);
        isr_wr_en   <= 1'b1;
        isr_wr_addr <= t[T_AW-1:0];
        if (tile_idx == 0)
          isr_wr_data <= {{(P_N_IN-IN_DIM_TILE){1'b0}}, wl_stream_gold[t][IN_DIM_TILE-1:0]};
        else
          isr_wr_data <= {{(P_N_IN-IN_DIM_TILE){1'b0}}, wl_stream_gold[t][2*IN_DIM_TILE-1:IN_DIM_TILE]};
      end
      @(posedge clk);
      isr_wr_en <= 1'b0;
    end
  endtask

  task automatic load_mac_weights(input int tile_idx);
    begin
      for (int i = 0; i < IN_DIM_TILE; i++) begin
        for (int j = 0; j < OUT_DIM; j++) begin
          @(posedge clk);
          mac_w_load_en  <= 1'b1;
          mac_w_load_i   <= i[I_AW-1:0];
          mac_w_load_j   <= j[J_AW-1:0];
          if (tile_idx == 0) begin
            mac_w_load_pos <= tile0_w_pos[i*OUT_DIM + j];
            mac_w_load_neg <= tile0_w_neg[i*OUT_DIM + j];
          end else begin
            mac_w_load_pos <= tile1_w_pos[i*OUT_DIM + j];
            mac_w_load_neg <= tile1_w_neg[i*OUT_DIM + j];
          end
        end
      end
      @(posedge clk);
      mac_w_load_en <= 1'b0;
    end
  endtask

  task automatic run_tile(input bit is_final);
    int g;
    begin
      @(posedge clk);
      cfg_in_dim  <= IN_DIM_TILE;
      cfg_out_dim <= OUT_DIM;
      cfg_threshold <= THR;
      cfg_sum_max   <= SUM_MAX_TILE;
      cfg_input_src  <= V2B_BUF_SEL_INPUT_SRAM;
      cfg_output_dst <= V2B_BUF_SEL_STREAM_A;
      cfg_tile_mode  <= 1'b1;
      cfg_is_tile_final <= is_final;
      cfg_preserve_membrane <= 1'b0;
      cfg_t_count <= T;
      @(posedge clk);
      start_pulse <= 1'b1;
      @(posedge clk);
      start_pulse <= 1'b0;
      g = 0;
      while (!done_pulse && g < 500_000) begin @(posedge clk); g++; end
      if (!done_pulse) begin $display("[FAIL] tile run timeout"); errors++; end
      if (err_code != V2B_STAGE_ERR_OK) begin $display("[FAIL] tile err=%02h", err_code); errors++; end
    end
  endtask

  int got_counts [0:OUT_DIM-1];
  int mismatch;
  task automatic count_sbA;
    logic [P_N_OUT-1:0] row;
    begin
      for (int j = 0; j < OUT_DIM; j++) got_counts[j] = 0;
      for (int t = 0; t < T; t++) begin
        @(posedge clk);
        sbA_rd_en_tb   <= 1'b1;
        sbA_rd_addr_tb <= t[T_AW-1:0];
        @(posedge clk);
        sbA_rd_en_tb <= 1'b0;
        @(posedge clk);
        @(posedge clk);
        row = sbA_rd_data;
        for (int j = 0; j < OUT_DIM; j++)
          if (row[j]) got_counts[j] = got_counts[j] + 1;
      end
    end
  endtask

  string golden_dir = "../python_multilayer/results_multilayer/tile_golden";

  initial begin
    $display("[TB] tile_accumulator_parity_tb start (in_dim=%0d x 2 tiles, out_dim=%0d, T=%0d)",
             IN_DIM_TILE, OUT_DIM, T);
    // init all control signals
    start_pulse=0; isr_wr_en=0; mac_w_load_en=0; tpb_clear_pulse=0;
    cfg_in_dim=0; cfg_out_dim=0; cfg_threshold=0; cfg_sum_max=0;
    cfg_input_src=0; cfg_output_dst=0; cfg_tile_mode=0; cfg_is_tile_final=0;
    cfg_preserve_membrane=0; cfg_t_count=0;

    rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // Load golden hex
    $readmemh({golden_dir, "/tile0_w_pos.hex"}, tile0_w_pos);
    $readmemh({golden_dir, "/tile0_w_neg.hex"}, tile0_w_neg);
    $readmemh({golden_dir, "/tile1_w_pos.hex"}, tile1_w_pos);
    $readmemh({golden_dir, "/tile1_w_neg.hex"}, tile1_w_neg);
    $readmemh({golden_dir, "/wl_stream.hex"},   wl_stream_gold);

    begin : load_counts
      int fd, dummy;
      fd = $fopen({golden_dir, "/counts.txt"}, "r");
      for (int j = 0; j < OUT_DIM; j++)
        dummy = $fscanf(fd, "%d\n", expected_counts[j]);
      $fclose(fd);
      $display("[TB] expected counts = [%0d %0d %0d %0d]",
        expected_counts[0], expected_counts[1], expected_counts[2], expected_counts[3]);
    end

    // Step 1: firmware clears tile_partial_buf (V2B STREAM_BUF_CTRL.CLEAR_TILE_BUF)
    @(posedge clk);
    tpb_clear_pulse <= 1'b1;
    @(posedge clk);
    tpb_clear_pulse <= 1'b0;

    // Step 2: tile 0 — load wl bits[0..7] + tile0 weights + run (is_tile_final=0)
    load_isr_tile(0);
    load_mac_weights(0);
    run_tile(1'b0);   // is_tile_final = 0

    // Step 3: tile 1 — load wl bits[8..15] + tile1 weights + run (is_tile_final=1)
    load_isr_tile(1);
    load_mac_weights(1);
    run_tile(1'b1);   // is_tile_final = 1 → LIF sweep → write STREAM_A

    // Step 4: read per-class counts from STREAM_A
    count_sbA();

    mismatch = 0;
    for (int j = 0; j < OUT_DIM; j++) begin
      if (got_counts[j] !== expected_counts[j]) begin
        $display("[FAIL] class %0d got=%0d exp=%0d", j, got_counts[j], expected_counts[j]);
        mismatch++;
      end
    end
    if (mismatch == 0) begin
      $display("[PASS] tile-correct counts = [%0d %0d %0d %0d]",
        got_counts[0], got_counts[1], got_counts[2], got_counts[3]);
    end else errors += mismatch;

    if (errors == 0) $display("TILE_ACCUMULATOR_PARITY_TB_PASS");
    else             $display("TILE_ACCUMULATOR_PARITY_TB_FAIL (errors=%0d)", errors);
    $finish;
  end

  initial begin
    #5_000_000;
    $display("TILE_ACCUMULATOR_PARITY_TB_TIMEOUT");
    $finish;
  end

endmodule
