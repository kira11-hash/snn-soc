`timescale 1ns/1ps
//======================================================================
// tb/streamed_stage_parity_tb.sv
//
// 目标：cim_mac_behavioral_v2 + stage_engine_v2 + input_stream_sram +
// stream_buffer_v2 组合，对 Python _run_stage_streamed_rate golden 做
// bit-exact 对齐。
//
// Golden 生成：python_multilayer/gen_streamed_stage_golden.py
//   results_multilayer/streamed_stage_golden/{wl_stream,w_pos,w_neg,
//   spike_stream,counts,golden_meta}.hex|txt
//
// Case (V0 小 case)：
//   in_dim=8, out_dim=4, T=16, adc_bits=10, threshold=8, sum_max=120
//
// 通过标准：
//   - 每 timestep 的 spike_stream 和 Python golden bit-exact
//   - 最终 counts per neuron == Python golden counts
//======================================================================
module streamed_stage_parity_tb;

  import snn_soc_pkg::*;

  localparam int IN_DIM  = 8;
  localparam int OUT_DIM = 4;
  localparam int T       = 16;
  localparam int ADC_BITS= 10;
  localparam int THRESHOLD = 8;
  localparam int SUM_MAX = IN_DIM * 15;  // 120 for in_dim=8

  localparam int P_T_MAX = V2B_MAX_TIMESTEPS;      // 256
  localparam int P_N_IN  = V2B_NUM_INPUTS;         // 256
  localparam int P_N_OUT = V2B_MAX_OUT_NEURONS;    // 128
  localparam int P_PARTIAL_W = V2B_PARTIAL_WIDTH;  // 14

  // ── Clock / reset ────────────────────────────────────────────────────
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  // ── Control / config ────────────────────────────────────────────────
  logic start_pulse = 0;
  logic busy, done_pulse;
  logic [7:0] err_code;
  logic [$clog2(P_T_MAX)-1:0] debug_t_idx;

  logic [15:0] cfg_in_dim    = IN_DIM[15:0];
  logic [15:0] cfg_out_dim   = OUT_DIM[15:0];
  logic [31:0] cfg_threshold = THRESHOLD;
  logic [31:0] cfg_sum_max   = SUM_MAX;
  logic [V2B_BUF_SEL_W-1:0] cfg_input_src  = V2B_BUF_SEL_INPUT_SRAM;
  logic [1:0]               cfg_output_dst = V2B_BUF_SEL_STREAM_A;
  logic        cfg_tile_mode  = 1'b0;
  logic        cfg_is_tile_final = 1'b1;
  logic        cfg_preserve_membrane = 1'b0;
  logic [15:0] cfg_t_count = T[15:0];
  logic        cfg_conv_mode = 1'b0;
  logic        cfg_flatten_mode = 1'b0;

  // ── input_stream_sram wires ─────────────────────────────────────────
  logic                         isr_wr_en;
  logic [$clog2(P_T_MAX)-1:0]   isr_wr_addr;
  logic [P_N_IN-1:0]            isr_wr_data;
  logic                         isr_rd_en;
  logic [$clog2(P_T_MAX)-1:0]   isr_rd_addr;
  logic [P_N_IN-1:0]            isr_rd_data;
  logic                         isr_clear_all = 0;

  input_stream_sram u_isr (
    .clk(clk), .rst_n(rst_n),
    .wr_en(isr_wr_en), .wr_addr(isr_wr_addr), .wr_data(isr_wr_data),
    .rd_en(isr_rd_en), .rd_addr(isr_rd_addr), .rd_data(isr_rd_data),
    .clear_all(isr_clear_all)
  );

  // ── stream_buffer A (output of this stage) ──────────────────────────
  logic                         sbA_wr_en;
  logic [$clog2(P_T_MAX)-1:0]   sbA_wr_addr;
  logic [P_N_OUT-1:0]           sbA_wr_data;
  logic                         sbA_rd_en = 0;
  logic [$clog2(P_T_MAX)-1:0]   sbA_rd_addr = '0;
  logic [P_N_OUT-1:0]           sbA_rd_data;
  logic                         sbA_clear_all = 0;

  stream_buffer_v2 u_sbA (
    .clk(clk), .rst_n(rst_n),
    .wr_en(sbA_wr_en), .wr_addr(sbA_wr_addr), .wr_data(sbA_wr_data),
    .rd_en(sbA_rd_en), .rd_addr(sbA_rd_addr), .rd_data(sbA_rd_data),
    .clear_all(sbA_clear_all)
  );

  // ── stream_buffer B (unused, tied off) ──────────────────────────────
  logic                         sbB_wr_en;
  logic [$clog2(P_T_MAX)-1:0]   sbB_wr_addr;
  logic [P_N_OUT-1:0]           sbB_wr_data;
  logic                         sbB_rd_en = 0;
  logic [$clog2(P_T_MAX)-1:0]   sbB_rd_addr = '0;
  logic [P_N_OUT-1:0]           sbB_rd_data;

  stream_buffer_v2 u_sbB (
    .clk(clk), .rst_n(rst_n),
    .wr_en(sbB_wr_en), .wr_addr(sbB_wr_addr), .wr_data(sbB_wr_data),
    .rd_en(sbB_rd_en), .rd_addr(sbB_rd_addr), .rd_data(sbB_rd_data),
    .clear_all(1'b0)
  );

  // ── tile_partial_buf (unused in this test) ──────────────────────────
  logic                         tpb_clear_all, tpb_acc_en;
  logic [$clog2(P_T_MAX)-1:0]   tpb_wr_t, tpb_rd_t;
  logic [$clog2(P_N_OUT)-1:0]   tpb_wr_j, tpb_rd_j;
  logic signed [P_PARTIAL_W-1:0] tpb_wr_diff, tpb_rd_data;
  logic                         tpb_rd_en;

  tile_partial_buf u_tpb (
    .clk(clk), .rst_n(rst_n),
    .clear_all(tpb_clear_all), .clear_busy(),
    .acc_en(tpb_acc_en), .wr_t(tpb_wr_t), .wr_j(tpb_wr_j), .wr_diff(tpb_wr_diff),
    .rd_en(tpb_rd_en), .rd_t(tpb_rd_t), .rd_j(tpb_rd_j),
    .rd_data(tpb_rd_data)
  );

  // ── cim_mac_behavioral_v2 (per-position Scheme B diff) ──────────────
  logic                            mac_w_load_en = 0;
  logic [$clog2(P_N_IN)-1:0]       mac_w_load_i = '0;
  logic [$clog2(P_N_OUT)-1:0]      mac_w_load_j = '0;
  logic [3:0]                      mac_w_load_pos = '0;
  logic [3:0]                      mac_w_load_neg = '0;

  logic                            mac_start, mac_done, mac_busy;
  logic [P_N_IN-1:0]               mac_wl_mask;
  logic [15:0]                     mac_cfg_in_dim, mac_cfg_out_dim;
  logic [31:0]                     mac_cfg_sum_max;
  logic [$clog2(P_N_OUT)-1:0]      mac_diff_rd_j;
  logic signed [P_PARTIAL_W-1:0]   mac_diff_rd_data;

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

  // ── stage_engine_v2 DUT ─────────────────────────────────────────────
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
    .cfg_reset_mode(1'b0),  // H1-full default soft (byte-bit identical to v2.B HEAD)
    .isr_rd_en(isr_rd_en), .isr_rd_addr(isr_rd_addr), .isr_rd_data(isr_rd_data),
    .sbA_wr_en(sbA_wr_en), .sbA_wr_addr(sbA_wr_addr), .sbA_wr_data(sbA_wr_data),
    .sbB_wr_en(sbB_wr_en), .sbB_wr_addr(sbB_wr_addr), .sbB_wr_data(sbB_wr_data),
    .sbA_rd_en(), .sbA_rd_addr(), .sbA_rd_data(sbA_rd_data),
    .sbB_rd_en(), .sbB_rd_addr(), .sbB_rd_data(sbB_rd_data),
    .tpb_clear_all(tpb_clear_all), .tpb_acc_en(tpb_acc_en),
    .tpb_wr_t(tpb_wr_t), .tpb_wr_j(tpb_wr_j), .tpb_wr_diff(tpb_wr_diff),
    .tpb_rd_en(tpb_rd_en), .tpb_rd_t(tpb_rd_t), .tpb_rd_j(tpb_rd_j),
    .tpb_rd_data(tpb_rd_data),
    .mac_start(mac_start), .mac_done(mac_done), .mac_busy(mac_busy),
    .mac_wl_mask(mac_wl_mask), .mac_cfg_in_dim(mac_cfg_in_dim),
    .mac_cfg_out_dim(mac_cfg_out_dim), .mac_cfg_sum_max(mac_cfg_sum_max),
    .mac_diff_rd_j(mac_diff_rd_j), .mac_diff_rd_data(mac_diff_rd_data)
  );

  // ── Golden data (loaded from Python-generated hex) ──────────────────
  // wl_stream[t] is in_dim bits = 8 bits. Store with hex width = 2 chars.
  logic [P_N_IN-1:0] wl_stream_gold [0:T-1];

  // spike_stream_gold[t] is out_dim bits = 4 bits.
  logic [P_N_OUT-1:0] spike_stream_gold [0:T-1];

  // Weight hex flat array [in_dim*out_dim] of 4-bit level
  logic [3:0] w_pos_flat [0:IN_DIM*OUT_DIM-1];
  logic [3:0] w_neg_flat [0:IN_DIM*OUT_DIM-1];

  // Expected final counts
  integer expected_counts [0:OUT_DIM-1];

  int errors = 0;

  task automatic load_golden;
    string golden_dir;
    int fd;
    int i_tmp;
    begin
      golden_dir = "../python_multilayer/results_multilayer/streamed_stage_golden";
      // wl_stream: T lines of 2-char hex; each line = IN_DIM-bit value
      $readmemh({golden_dir, "/wl_stream.hex"}, wl_stream_gold);
      // Weights: row-major (i,j) -> flat index i*OUT_DIM + j
      $readmemh({golden_dir, "/w_pos.hex"}, w_pos_flat);
      $readmemh({golden_dir, "/w_neg.hex"}, w_neg_flat);
      // Spike stream: T lines of 1-char hex
      $readmemh({golden_dir, "/spike_stream.hex"}, spike_stream_gold);
      // counts.txt (one int per line)
      fd = $fopen({golden_dir, "/counts.txt"}, "r");
      if (fd == 0) begin
        $display("[FATAL] can't open counts.txt");
        $finish;
      end
      for (int i = 0; i < OUT_DIM; i++) begin
        if ($fscanf(fd, "%d\n", expected_counts[i]) != 1) begin
          $display("[FATAL] counts.txt missing line %0d", i);
          $finish;
        end
      end
      $fclose(fd);
      $display("[TB] loaded golden from %s", golden_dir);
      $display("[TB] expected_counts = [%0d, %0d, %0d, %0d]",
        expected_counts[0], expected_counts[1], expected_counts[2], expected_counts[3]);
    end
  endtask

  // Pre-load input_stream_sram with wl_stream_gold, and MAC weights.
  task automatic preload_inputs_and_weights;
    begin
      // Write wl_stream into isr (one row per cycle)
      for (int t = 0; t < T; t++) begin
        @(posedge clk);
        isr_wr_en   <= 1'b1;
        isr_wr_addr <= t[$clog2(P_T_MAX)-1:0];
        // zero-extend wl_stream_gold[t] (IN_DIM bits) up to P_N_IN
        isr_wr_data <= { {(P_N_IN - IN_DIM){1'b0}}, wl_stream_gold[t][IN_DIM-1:0] };
      end
      @(posedge clk);
      isr_wr_en <= 1'b0;

      // Write weights cell by cell into MAC
      for (int i = 0; i < IN_DIM; i++) begin
        for (int j = 0; j < OUT_DIM; j++) begin
          @(posedge clk);
          mac_w_load_en  <= 1'b1;
          mac_w_load_i   <= i[$clog2(P_N_IN)-1:0];
          mac_w_load_j   <= j[$clog2(P_N_OUT)-1:0];
          mac_w_load_pos <= w_pos_flat[i*OUT_DIM + j];
          mac_w_load_neg <= w_neg_flat[i*OUT_DIM + j];
        end
      end
      @(posedge clk);
      mac_w_load_en <= 1'b0;

      $display("[TB] preloaded %0d WL rows + %0d weight cells", T, IN_DIM*OUT_DIM);
    end
  endtask

  // Run the stage engine
  task automatic run_stage;
    bit saw_done;
    int g;
    begin
      saw_done = 0;
      @(posedge clk);
      start_pulse <= 1'b1;
      @(posedge clk);
      start_pulse <= 1'b0;
      // Wait done with timeout guard (loop exits via disable)
      g = 0;
      while (!saw_done && g < 200000) begin
        @(posedge clk);
        if (done_pulse) begin
          $display("[TB] done_pulse seen at cycle g=%0d, err=%02h", g, err_code);
          saw_done = 1;
        end
        g = g + 1;
      end
      if (!saw_done) begin
        $display("[TB] TIMEOUT waiting done_pulse");
        errors++;
      end
    end
  endtask

  // Compare stream_buffer_A contents to spike_stream_gold
  task automatic check_parity;
    int got_counts [0:OUT_DIM-1];
    logic [P_N_OUT-1:0] got_row;
    begin
      for (int j = 0; j < OUT_DIM; j++) got_counts[j] = 0;
      for (int t = 0; t < T; t++) begin
        // Issue read
        @(posedge clk);
        sbA_rd_en   <= 1'b1;
        sbA_rd_addr <= t[$clog2(P_T_MAX)-1:0];
        @(posedge clk);
        sbA_rd_en <= 1'b0;
        @(posedge clk);  // 1-cycle read latency
        got_row = sbA_rd_data;

        // Compare lower out_dim bits
        if (got_row[OUT_DIM-1:0] !== spike_stream_gold[t][OUT_DIM-1:0]) begin
          $display("[FAIL] t=%0d spike_stream: got=%h exp=%h",
            t, got_row[OUT_DIM-1:0], spike_stream_gold[t][OUT_DIM-1:0]);
          errors++;
        end
        for (int j = 0; j < OUT_DIM; j++) begin
          if (got_row[j]) got_counts[j] = got_counts[j] + 1;
        end
      end
      // Final counts
      for (int j = 0; j < OUT_DIM; j++) begin
        if (got_counts[j] !== expected_counts[j]) begin
          $display("[FAIL] counts[%0d]: got=%0d exp=%0d", j, got_counts[j], expected_counts[j]);
          errors++;
        end else begin
          $display("[PASS] counts[%0d] = %0d", j, got_counts[j]);
        end
      end
    end
  endtask

  initial begin
    $display("[TB] streamed_stage_parity_tb start (in_dim=%0d out_dim=%0d T=%0d adc=%0d)",
             IN_DIM, OUT_DIM, T, ADC_BITS);
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    load_golden();
    preload_inputs_and_weights();

    run_stage();
    check_parity();

    if (errors == 0)
      $display("STREAMED_STAGE_PARITY_TB_PASS");
    else
      $display("STREAMED_STAGE_PARITY_TB_FAIL (errors=%0d)", errors);
    $finish;
  end

  initial begin
    #5000000;  // 5 ms sim safety
    $display("STREAMED_STAGE_PARITY_TB_TIMEOUT");
    $finish;
  end

endmodule
