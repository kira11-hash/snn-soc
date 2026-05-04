`timescale 1ns/1ps
//======================================================================
// tb/multilayer_sample_parity_tb.sv
//
// 【B5 关键 bit-parity TB】
// Fashion 14×14 multilayer 196_64_10 topology × 10 samples × Python↔RTL
// bit-identical per-class spike_counts。
//
// Pipeline per sample:
//   1. load stage 0 weights into MAC (196×64 cells)
//   2. load WL stream (T=64, 196-bit per row) into input_stream_sram
//   3. run stage 0: input_src=INPUT_SRAM, output_dst=STREAM_A
//   4. load stage 1 weights into MAC (64×10 cells, overwrites stage 0 lower rows)
//   5. run stage 1: input_src=STREAM_A, output_dst=STREAM_B
//   6. read stream_buffer_B rows for T timesteps, count spikes per class
//   7. compare per-class counts to Python golden
//
// Golden files under python_multilayer/results_multilayer/fashion_multilayer_golden/
//
// Pass criterion: all 10 samples have counts[10] bit-exact == golden.
//======================================================================
module multilayer_sample_parity_tb;

  import snn_soc_pkg::*;

  localparam int NUM_SAMPLES = 10;
  localparam int T = 64;
  localparam int S0_IN_DIM  = 196;
  localparam int S0_OUT_DIM = 64;
  localparam int S0_THR     = 16;
  localparam int S0_SUM_MAX = S0_IN_DIM * 15;    // 2940
  localparam int S1_IN_DIM  = 64;
  localparam int S1_OUT_DIM = 10;
  localparam int S1_THR     = 8;
  localparam int S1_SUM_MAX = S1_IN_DIM * 15;    // 960
  localparam int ADC_BITS   = 10;

  localparam int P_T_MAX = V2B_MAX_TIMESTEPS;
  localparam int P_N_IN  = V2B_NUM_INPUTS;
  localparam int P_N_OUT = V2B_MAX_OUT_NEURONS;
  localparam int P_PARTIAL_W = V2B_PARTIAL_WIDTH;
  localparam int T_AW = $clog2(P_T_MAX);
  localparam int J_AW = $clog2(P_N_OUT);
  localparam int I_AW = $clog2(P_N_IN);

  // ── Clock / reset ────────────────────────────────────────────────────
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  // ── Stage engine ports ──────────────────────────────────────────────
  logic start_pulse = 0;
  logic busy, done_pulse;
  logic [7:0] err_code;
  logic [T_AW-1:0] debug_t_idx;

  logic [15:0] cfg_in_dim, cfg_out_dim;
  logic [31:0] cfg_threshold, cfg_sum_max;
  logic [V2B_BUF_SEL_W-1:0] cfg_input_src;
  logic [1:0]               cfg_output_dst;
  logic        cfg_tile_mode = 0, cfg_is_tile_final = 1, cfg_preserve_membrane = 0;
  logic [15:0] cfg_t_count = T[15:0];
  logic        cfg_conv_mode = 1'b0;
  logic        cfg_flatten_mode = 1'b0;

  // Inputs / outputs
  logic isr_rd_en;
  logic [T_AW-1:0] isr_rd_addr;
  logic [P_N_IN-1:0] isr_rd_data;
  logic isr_wr_en = 0;
  logic [T_AW-1:0] isr_wr_addr = '0;
  logic [P_N_IN-1:0] isr_wr_data = '0;
  logic isr_clear_all = 0;

  // stream_buffer_v2 A
  logic sbA_wr_en;
  logic [T_AW-1:0] sbA_wr_addr;
  logic [P_N_OUT-1:0] sbA_wr_data;
  logic sbA_rd_en_from_se;
  logic [T_AW-1:0] sbA_rd_addr_from_se;
  logic [P_N_OUT-1:0] sbA_rd_data;
  logic sbA_rd_en_tb = 0;
  logic [T_AW-1:0] sbA_rd_addr_tb = '0;
  logic sbA_rd_en_mux;
  logic [T_AW-1:0] sbA_rd_addr_mux;
  assign sbA_rd_en_mux   = sbA_rd_en_from_se | sbA_rd_en_tb;
  assign sbA_rd_addr_mux = sbA_rd_en_tb ? sbA_rd_addr_tb : sbA_rd_addr_from_se;
  logic sbA_clear = 0;

  // stream_buffer_v2 B
  logic sbB_wr_en;
  logic [T_AW-1:0] sbB_wr_addr;
  logic [P_N_OUT-1:0] sbB_wr_data;
  logic sbB_rd_en_from_se;
  logic [T_AW-1:0] sbB_rd_addr_from_se;
  logic [P_N_OUT-1:0] sbB_rd_data;
  logic sbB_rd_en_tb = 0;
  logic [T_AW-1:0] sbB_rd_addr_tb = '0;
  logic sbB_rd_en_mux;
  logic [T_AW-1:0] sbB_rd_addr_mux;
  assign sbB_rd_en_mux   = sbB_rd_en_from_se | sbB_rd_en_tb;
  assign sbB_rd_addr_mux = sbB_rd_en_tb ? sbB_rd_addr_tb : sbB_rd_addr_from_se;

  // tile_partial_buf (unused)
  logic tpb_clear_all, tpb_acc_en;
  logic [T_AW-1:0] tpb_wr_t, tpb_rd_t;
  logic [J_AW-1:0] tpb_wr_j, tpb_rd_j;
  logic signed [P_PARTIAL_W-1:0] tpb_wr_diff, tpb_rd_data;
  logic tpb_rd_en;

  // ── MAC wires ───────────────────────────────────────────────────────
  logic mac_w_load_en = 0;
  logic [I_AW-1:0]  mac_w_load_i = '0;
  logic [J_AW-1:0]  mac_w_load_j = '0;
  logic [3:0]       mac_w_load_pos = '0;
  logic [3:0]       mac_w_load_neg = '0;
  logic mac_start, mac_done, mac_busy;
  logic [P_N_IN-1:0] mac_wl_mask;
  logic [15:0] mac_cfg_in_dim, mac_cfg_out_dim;
  logic [31:0] mac_cfg_sum_max;
  logic [J_AW-1:0] mac_diff_rd_j;
  logic signed [P_PARTIAL_W-1:0] mac_diff_rd_data;

  // ── DUT instances ───────────────────────────────────────────────────
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
    .rd_en(sbB_rd_en_mux), .rd_addr(sbB_rd_addr_mux), .rd_data(sbB_rd_data),
    .clear_all(1'b0)
  );

  tile_partial_buf u_tpb (
    .clk(clk), .rst_n(rst_n), .clear_all(tpb_clear_all), .clear_busy(),
    .acc_en(tpb_acc_en), .wr_t(tpb_wr_t), .wr_j(tpb_wr_j), .wr_diff(tpb_wr_diff),
    .rd_en(tpb_rd_en), .rd_t(tpb_rd_t), .rd_j(tpb_rd_j),
    .rd_data(tpb_rd_data)
  );

  cim_mac_behavioral_v2 #(.P_ADC_BITS(ADC_BITS)) u_mac (
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
    .cfg_conv_mode(cfg_conv_mode), .cfg_flatten_mode(cfg_flatten_mode),
    .isr_rd_en(isr_rd_en), .isr_rd_addr(isr_rd_addr), .isr_rd_data(isr_rd_data),
    .sbA_wr_en(sbA_wr_en), .sbA_wr_addr(sbA_wr_addr), .sbA_wr_data(sbA_wr_data),
    .sbB_wr_en(sbB_wr_en), .sbB_wr_addr(sbB_wr_addr), .sbB_wr_data(sbB_wr_data),
    .sbA_rd_en(sbA_rd_en_from_se), .sbA_rd_addr(sbA_rd_addr_from_se), .sbA_rd_data(sbA_rd_data),
    .sbB_rd_en(sbB_rd_en_from_se), .sbB_rd_addr(sbB_rd_addr_from_se), .sbB_rd_data(sbB_rd_data),
    .tpb_clear_all(tpb_clear_all), .tpb_acc_en(tpb_acc_en),
    .tpb_wr_t(tpb_wr_t), .tpb_wr_j(tpb_wr_j), .tpb_wr_diff(tpb_wr_diff),
    .tpb_rd_en(tpb_rd_en), .tpb_rd_t(tpb_rd_t), .tpb_rd_j(tpb_rd_j),
    .tpb_rd_data(tpb_rd_data),
    .mac_start(mac_start), .mac_done(mac_done), .mac_busy(mac_busy),
    .mac_wl_mask(mac_wl_mask), .mac_cfg_in_dim(mac_cfg_in_dim),
    .mac_cfg_out_dim(mac_cfg_out_dim), .mac_cfg_sum_max(mac_cfg_sum_max),
    .mac_diff_rd_j(mac_diff_rd_j), .mac_diff_rd_data(mac_diff_rd_data)
  );

  // ── Golden data ─────────────────────────────────────────────────────
  // Stage 0 weights: 196 × 64 = 12544 cells row-major
  logic [3:0] s0_w_pos_flat [0:S0_IN_DIM*S0_OUT_DIM-1];
  logic [3:0] s0_w_neg_flat [0:S0_IN_DIM*S0_OUT_DIM-1];
  // Stage 1 weights: 64 × 10 = 640 cells row-major
  logic [3:0] s1_w_pos_flat [0:S1_IN_DIM*S1_OUT_DIM-1];
  logic [3:0] s1_w_neg_flat [0:S1_IN_DIM*S1_OUT_DIM-1];

  // Per-sample WL stream (T lines, each 256-bit hex padded from 196-bit)
  // For readmemh we need fixed-sized memory; declare inside task via dynamic load.
  logic [P_N_IN-1:0] sample_wl_stream [0:T-1];

  // Per-sample expected counts (10 ints)
  integer expected_counts [0:S1_OUT_DIM-1];

  int errors = 0;

  // ── Weight load tasks ────────────────────────────────────────────────
  task automatic load_stage0_weights;
    begin
      $display("[TB] loading stage 0 weights (%0d cells)...", S0_IN_DIM*S0_OUT_DIM);
      for (int i = 0; i < S0_IN_DIM; i++) begin
        for (int j = 0; j < S0_OUT_DIM; j++) begin
          @(posedge clk);
          mac_w_load_en  <= 1'b1;
          mac_w_load_i   <= i[I_AW-1:0];
          mac_w_load_j   <= j[J_AW-1:0];
          mac_w_load_pos <= s0_w_pos_flat[i*S0_OUT_DIM + j];
          mac_w_load_neg <= s0_w_neg_flat[i*S0_OUT_DIM + j];
        end
      end
      @(posedge clk);
      mac_w_load_en <= 1'b0;
    end
  endtask

  task automatic load_stage1_weights;
    begin
      $display("[TB] loading stage 1 weights (%0d cells)...", S1_IN_DIM*S1_OUT_DIM);
      for (int i = 0; i < S1_IN_DIM; i++) begin
        for (int j = 0; j < S1_OUT_DIM; j++) begin
          @(posedge clk);
          mac_w_load_en  <= 1'b1;
          mac_w_load_i   <= i[I_AW-1:0];
          mac_w_load_j   <= j[J_AW-1:0];
          mac_w_load_pos <= s1_w_pos_flat[i*S1_OUT_DIM + j];
          mac_w_load_neg <= s1_w_neg_flat[i*S1_OUT_DIM + j];
        end
      end
      @(posedge clk);
      mac_w_load_en <= 1'b0;
    end
  endtask

  task automatic load_wl_stream_into_isr;
    begin
      isr_clear_all <= 1'b1;
      @(posedge clk);
      isr_clear_all <= 1'b0;
      @(posedge clk);
      for (int t = 0; t < T; t++) begin
        @(posedge clk);
        isr_wr_en   <= 1'b1;
        isr_wr_addr <= t[T_AW-1:0];
        isr_wr_data <= sample_wl_stream[t];
      end
      @(posedge clk);
      isr_wr_en <= 1'b0;
    end
  endtask

  // ── Run one stage and wait for done ─────────────────────────────────
  task automatic run_stage(
    input int stage_id,
    input logic [V2B_BUF_SEL_W-1:0] input_src,
    input logic [1:0] output_dst,
    input int in_dim, input int out_dim,
    input int threshold, input int sum_max
  );
    int g;
    begin
      @(posedge clk);
      cfg_in_dim     <= in_dim[15:0];
      cfg_out_dim    <= out_dim[15:0];
      cfg_threshold  <= threshold[31:0];
      cfg_sum_max    <= sum_max[31:0];
      cfg_input_src  <= input_src;
      cfg_output_dst <= output_dst;
      cfg_tile_mode  <= 1'b0;
      cfg_is_tile_final <= 1'b1;
      cfg_preserve_membrane <= 1'b0;
      cfg_t_count    <= T[15:0];
      @(posedge clk);
      start_pulse <= 1'b1;
      @(posedge clk);
      start_pulse <= 1'b0;

      g = 0;
      while (!done_pulse && g < 1_000_000) begin
        @(posedge clk);
        g = g + 1;
      end
      if (!done_pulse) begin
        $display("[FAIL] stage %0d TIMEOUT after %0d cycles (err=%02h)", stage_id, g, err_code);
        errors++;
      end else if (err_code != V2B_STAGE_ERR_OK) begin
        $display("[FAIL] stage %0d err_code=%02h", stage_id, err_code);
        errors++;
      end
    end
  endtask

  // ── Count spikes per class by reading stream_buffer_B ────────────────
  // Module-scope counts array; task writes into it in place (avoids
  // Icarus limitation on unpacked array task ports).
  int got_counts_m [0:S1_OUT_DIM-1];

  task automatic count_stage1_spikes;
    logic [P_N_OUT-1:0] row;
    begin
      for (int j = 0; j < S1_OUT_DIM; j++) got_counts_m[j] = 0;
      for (int t = 0; t < T; t++) begin
        @(posedge clk);
        sbB_rd_en_tb   <= 1'b1;
        sbB_rd_addr_tb <= t[T_AW-1:0];
        @(posedge clk);
        sbB_rd_en_tb <= 1'b0;
        @(posedge clk);  // 1-cycle SRAM read latency
        @(posedge clk);  // extra settle cycle
        row = sbB_rd_data;
        for (int j = 0; j < S1_OUT_DIM; j++)
          if (row[j]) got_counts_m[j] = got_counts_m[j] + 1;
      end
    end
  endtask

  // ── Load golden per sample ──────────────────────────────────────────
  string golden_dir = "../python_multilayer/results_multilayer/fashion_multilayer_golden";

  task automatic load_sample_golden(input int k);
    string path;
    int fd;
    begin
      path = $sformatf("%s/sample_%02d_wl_stream.hex", golden_dir, k);
      $readmemh(path, sample_wl_stream);
      path = $sformatf("%s/sample_%02d_counts.txt", golden_dir, k);
      fd = $fopen(path, "r");
      if (fd == 0) begin
        $display("[FATAL] cannot open %s", path);
        $finish;
      end
      for (int j = 0; j < S1_OUT_DIM; j++) begin
        if ($fscanf(fd, "%d\n", expected_counts[j]) != 1) begin
          $display("[FATAL] %s missing class %0d count", path, j);
          $finish;
        end
      end
      $fclose(fd);
    end
  endtask

  // ── Sample loop ─────────────────────────────────────────────────────
  int mismatch;


  initial begin
    $display("[TB] multilayer_sample_parity_tb start (%0d samples, T=%0d)", NUM_SAMPLES, T);
    $display("[TB]   stage0 %0d->%0d thr=%0d sum_max=%0d", S0_IN_DIM, S0_OUT_DIM, S0_THR, S0_SUM_MAX);
    $display("[TB]   stage1 %0d->%0d thr=%0d sum_max=%0d", S1_IN_DIM, S1_OUT_DIM, S1_THR, S1_SUM_MAX);

    rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // Load all weight hex (static files, not per-sample)
    $readmemh({golden_dir, "/stage0_w_pos.hex"}, s0_w_pos_flat);
    $readmemh({golden_dir, "/stage0_w_neg.hex"}, s0_w_neg_flat);
    $readmemh({golden_dir, "/stage1_w_pos.hex"}, s1_w_pos_flat);
    $readmemh({golden_dir, "/stage1_w_neg.hex"}, s1_w_neg_flat);

    for (int k = 0; k < NUM_SAMPLES; k++) begin
      $display("[TB] ---- sample %0d ----", k);
      load_sample_golden(k);
      load_wl_stream_into_isr();

      // Stage 0: load weights, run
      load_stage0_weights();
      run_stage(0, V2B_BUF_SEL_INPUT_SRAM, V2B_BUF_SEL_STREAM_A,
                S0_IN_DIM, S0_OUT_DIM, S0_THR, S0_SUM_MAX);

      // Stage 1: load weights, run
      load_stage1_weights();
      run_stage(1, V2B_BUF_SEL_STREAM_A, V2B_BUF_SEL_STREAM_B,
                S1_IN_DIM, S1_OUT_DIM, S1_THR, S1_SUM_MAX);

      // Compare
      count_stage1_spikes();
      mismatch = 0;
      for (int j = 0; j < S1_OUT_DIM; j++) begin
        if (got_counts_m[j] !== expected_counts[j]) begin
          $display("[FAIL] sample %0d class %0d: got=%0d exp=%0d", k, j, got_counts_m[j], expected_counts[j]);
          mismatch++;
        end
      end
      if (mismatch == 0) begin
        $display("[PASS] sample %0d counts = [%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d]",
                 k,
                 got_counts_m[0], got_counts_m[1], got_counts_m[2], got_counts_m[3],
                 got_counts_m[4], got_counts_m[5], got_counts_m[6], got_counts_m[7],
                 got_counts_m[8], got_counts_m[9]);
      end else begin
        errors += mismatch;
      end
    end

    if (errors == 0) $display("MULTILAYER_SAMPLE_PARITY_TB_PASS");
    else             $display("MULTILAYER_SAMPLE_PARITY_TB_FAIL (errors=%0d)", errors);
    $finish;
  end

  initial begin
    #(50_000_000);  // 50ms safety
    $display("MULTILAYER_SAMPLE_PARITY_TB_TIMEOUT");
    $finish;
  end

endmodule
