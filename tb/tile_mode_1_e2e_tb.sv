`timescale 1ns/1ps
//======================================================================
// tb/tile_mode_1_e2e_tb.sv
//
// M2 pre-RTL gate: exercise the existing FC tile_mode=1 datapath before
// adding any CONV RTL.  This instantiates only existing V2.B primitives:
//   input_stream_sram + cim_mac_behavioral_v2 + stage_engine_v2
//   + tile_partial_buf + stream_buffer_v2
//
// Scenario:
//   Full logical FC input_dim = 320, output_dim = 16, T = 10.
//   tile0 valid_count = 256, tile1 valid_count = 64.
//
// Current stage_engine_v2 has no input-stream offset port, so the TB models
// firmware tiling by rewriting input_stream_sram with the current tile mapped
// into low lanes [valid_count-1:0] before each stage_engine run.
//======================================================================
module tile_mode_1_e2e_tb;

  import snn_soc_pkg::*;

  localparam int FULL_IN_DIM = 320;
  localparam int TILE0_DIM   = 256;
  localparam int TILE1_DIM   = 64;
  localparam int OUT_DIM     = 16;
  localparam int T           = 10;
  localparam int THRESHOLD   = 128;
  localparam int ADC_BITS    = 10;
  localparam int SUM_MAX0    = TILE0_DIM * 7;
  localparam int SUM_MAX1    = TILE1_DIM * 7;

  localparam int P_T_MAX     = V2B_MAX_TIMESTEPS;
  localparam int P_N_IN      = V2B_NUM_INPUTS;
  localparam int P_N_OUT     = V2B_MAX_OUT_NEURONS;
  localparam int P_PARTIAL_W = V2B_PARTIAL_WIDTH;
  localparam int T_AW        = $clog2(P_T_MAX);
  localparam int I_AW        = $clog2(P_N_IN);
  localparam int J_AW        = $clog2(P_N_OUT);

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  // stage_engine control
  logic start_pulse = 0;
  logic busy, done_pulse;
  logic [7:0] err_code;
  logic [T_AW-1:0] debug_t_idx;
  logic [15:0] cfg_in_dim = 0, cfg_out_dim = 0;
  logic [31:0] cfg_threshold = 0, cfg_sum_max = 0;
  logic [1:0] cfg_input_src = 0, cfg_output_dst = 0;
  logic cfg_tile_mode = 0, cfg_is_tile_final = 0, cfg_preserve_membrane = 0;
  logic [15:0] cfg_t_count = 0;

  // input_stream_sram
  logic isr_wr_en = 0;
  logic [T_AW-1:0] isr_wr_addr = '0;
  logic [P_N_IN-1:0] isr_wr_data = '0;
  logic isr_rd_en;
  logic [T_AW-1:0] isr_rd_addr;
  logic [P_N_IN-1:0] isr_rd_data;
  logic isr_clear_all = 0;

  input_stream_sram u_isr (
    .clk(clk), .rst_n(rst_n),
    .wr_en(isr_wr_en), .wr_addr(isr_wr_addr), .wr_data(isr_wr_data),
    .rd_en(isr_rd_en), .rd_addr(isr_rd_addr), .rd_data(isr_rd_data),
    .clear_all(isr_clear_all)
  );

  // stream_buffer A with TB read mux
  logic sbA_wr_en;
  logic [T_AW-1:0] sbA_wr_addr;
  logic [P_N_OUT-1:0] sbA_wr_data;
  logic sbA_rd_en_se, sbA_rd_en_tb = 0;
  logic [T_AW-1:0] sbA_rd_addr_se, sbA_rd_addr_tb = '0;
  logic [P_N_OUT-1:0] sbA_rd_data;
  logic sbA_rd_en_mux;
  logic [T_AW-1:0] sbA_rd_addr_mux;
  logic sbA_clear_all = 0;
  assign sbA_rd_en_mux   = sbA_rd_en_se | sbA_rd_en_tb;
  assign sbA_rd_addr_mux = sbA_rd_en_tb ? sbA_rd_addr_tb : sbA_rd_addr_se;

  stream_buffer_v2 u_sbA (
    .clk(clk), .rst_n(rst_n),
    .wr_en(sbA_wr_en), .wr_addr(sbA_wr_addr), .wr_data(sbA_wr_data),
    .rd_en(sbA_rd_en_mux), .rd_addr(sbA_rd_addr_mux), .rd_data(sbA_rd_data),
    .clear_all(sbA_clear_all)
  );

  // stream_buffer B unused except for stage_engine port completeness
  logic sbB_wr_en;
  logic [T_AW-1:0] sbB_wr_addr;
  logic [P_N_OUT-1:0] sbB_wr_data;
  logic sbB_rd_en = 0;
  logic [T_AW-1:0] sbB_rd_addr = '0;
  logic [P_N_OUT-1:0] sbB_rd_data;

  stream_buffer_v2 u_sbB (
    .clk(clk), .rst_n(rst_n),
    .wr_en(sbB_wr_en), .wr_addr(sbB_wr_addr), .wr_data(sbB_wr_data),
    .rd_en(sbB_rd_en), .rd_addr(sbB_rd_addr), .rd_data(sbB_rd_data),
    .clear_all(1'b0)
  );

  // tile_partial_buf with TB read mux and explicit clear pulse
  logic tpb_clear_all_se, tpb_acc_en;
  logic [T_AW-1:0] tpb_wr_t, tpb_rd_t_se;
  logic [J_AW-1:0] tpb_wr_j, tpb_rd_j_se;
  logic signed [P_PARTIAL_W-1:0] tpb_wr_diff, tpb_rd_data;
  logic tpb_rd_en_se;
  logic tpb_clear_pulse = 0;
  logic tpb_rd_en_tb = 0;
  logic [T_AW-1:0] tpb_rd_t_tb = '0;
  logic [J_AW-1:0] tpb_rd_j_tb = '0;
  logic tpb_rd_en_mux;
  logic [T_AW-1:0] tpb_rd_t_mux;
  logic [J_AW-1:0] tpb_rd_j_mux;
  assign tpb_rd_en_mux = tpb_rd_en_se | tpb_rd_en_tb;
  assign tpb_rd_t_mux  = tpb_rd_en_tb ? tpb_rd_t_tb : tpb_rd_t_se;
  assign tpb_rd_j_mux  = tpb_rd_en_tb ? tpb_rd_j_tb : tpb_rd_j_se;

  tile_partial_buf u_tpb (
    .clk(clk), .rst_n(rst_n),
    .clear_all(tpb_clear_all_se | tpb_clear_pulse),
    .acc_en(tpb_acc_en), .wr_t(tpb_wr_t), .wr_j(tpb_wr_j), .wr_diff(tpb_wr_diff),
    .rd_en(tpb_rd_en_mux), .rd_t(tpb_rd_t_mux), .rd_j(tpb_rd_j_mux),
    .rd_data(tpb_rd_data)
  );

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
    .isr_rd_en(isr_rd_en), .isr_rd_addr(isr_rd_addr), .isr_rd_data(isr_rd_data),
    .sbA_wr_en(sbA_wr_en), .sbA_wr_addr(sbA_wr_addr), .sbA_wr_data(sbA_wr_data),
    .sbB_wr_en(sbB_wr_en), .sbB_wr_addr(sbB_wr_addr), .sbB_wr_data(sbB_wr_data),
    .sbA_rd_en(sbA_rd_en_se), .sbA_rd_addr(sbA_rd_addr_se), .sbA_rd_data(sbA_rd_data),
    .sbB_rd_en(), .sbB_rd_addr(), .sbB_rd_data(sbB_rd_data),
    .tpb_clear_all(tpb_clear_all_se), .tpb_acc_en(tpb_acc_en),
    .tpb_wr_t(tpb_wr_t), .tpb_wr_j(tpb_wr_j), .tpb_wr_diff(tpb_wr_diff),
    .tpb_rd_en(tpb_rd_en_se), .tpb_rd_t(tpb_rd_t_se), .tpb_rd_j(tpb_rd_j_se),
    .tpb_rd_data(tpb_rd_data),
    .mac_start(mac_start), .mac_done(mac_done), .mac_busy(mac_busy),
    .mac_wl_mask(mac_wl_mask), .mac_cfg_in_dim(mac_cfg_in_dim),
    .mac_cfg_out_dim(mac_cfg_out_dim), .mac_cfg_sum_max(mac_cfg_sum_max),
    .mac_diff_rd_j(mac_diff_rd_j), .mac_diff_rd_data(mac_diff_rd_data)
  );

  // Golden storage
  logic [P_N_IN-1:0] wl_tile0 [0:T-1];
  logic [P_N_IN-1:0] wl_tile1 [0:T-1];
  logic [OUT_DIM-1:0] expected_spike [0:T-1];
  logic [3:0] tile0_w_pos [0:TILE0_DIM*OUT_DIM-1];
  logic [3:0] tile0_w_neg [0:TILE0_DIM*OUT_DIM-1];
  logic [3:0] tile1_w_pos [0:TILE1_DIM*OUT_DIM-1];
  logic [3:0] tile1_w_neg [0:TILE1_DIM*OUT_DIM-1];
  int expected_counts [0:OUT_DIM-1];

  localparam int TRACE_N = 2;
  int trace_t [0:TRACE_N-1];
  int trace_j [0:TRACE_N-1];
  int trace_tile0 [0:TRACE_N-1];
  int trace_final [0:TRACE_N-1];

  int errors = 0;
  string golden_dir;

  task automatic load_golden;
    int fd;
    int dummy;
    begin
      if (!$value$plusargs("GOLDEN_DIR=%s", golden_dir)) begin
        golden_dir = "../python_multilayer/results_multilayer/tile_mode_1_e2e_golden";
      end
      $display("[TB] golden_dir=%s", golden_dir);
      $readmemh({golden_dir, "/wl_tile0.hex"}, wl_tile0);
      $readmemh({golden_dir, "/wl_tile1.hex"}, wl_tile1);
      $readmemh({golden_dir, "/tile0_w_pos.hex"}, tile0_w_pos);
      $readmemh({golden_dir, "/tile0_w_neg.hex"}, tile0_w_neg);
      $readmemh({golden_dir, "/tile1_w_pos.hex"}, tile1_w_pos);
      $readmemh({golden_dir, "/tile1_w_neg.hex"}, tile1_w_neg);
      $readmemh({golden_dir, "/expected_spike_stream.hex"}, expected_spike);

      fd = $fopen({golden_dir, "/expected_counts.txt"}, "r");
      if (fd == 0) begin
        $display("[FATAL] cannot open expected_counts.txt");
        $finish;
      end
      for (int j = 0; j < OUT_DIM; j++) begin
        dummy = $fscanf(fd, "%d\n", expected_counts[j]);
        if (dummy != 1) begin
          $display("[FATAL] expected_counts.txt missing line %0d", j);
          $finish;
        end
      end
      $fclose(fd);

      fd = $fopen({golden_dir, "/partial_trace.txt"}, "r");
      if (fd == 0) begin
        $display("[FATAL] cannot open partial_trace.txt");
        $finish;
      end
      for (int k = 0; k < TRACE_N; k++) begin
        dummy = $fscanf(fd, "%d %d %d %d\n",
                        trace_t[k], trace_j[k], trace_tile0[k], trace_final[k]);
        if (dummy != 4) begin
          $display("[FATAL] partial_trace.txt missing line %0d", k);
          $finish;
        end
      end
      $fclose(fd);
    end
  endtask

  task automatic clear_tile_partial;
    begin
      @(posedge clk);
      tpb_clear_pulse <= 1'b1;
      @(posedge clk);
      tpb_clear_pulse <= 1'b0;
      @(posedge clk);
    end
  endtask

  task automatic load_isr_tile(input int tile_idx);
    begin
      for (int t = 0; t < T; t++) begin
        @(posedge clk);
        isr_wr_en   <= 1'b1;
        isr_wr_addr <= t[T_AW-1:0];
        isr_wr_data <= (tile_idx == 0) ? wl_tile0[t] : wl_tile1[t];
      end
      @(posedge clk);
      isr_wr_en   <= 1'b0;
      isr_wr_addr <= '0;
      isr_wr_data <= '0;
    end
  endtask

  task automatic load_mac_weights(input int tile_idx);
    int tile_dim;
    begin
      tile_dim = (tile_idx == 0) ? TILE0_DIM : TILE1_DIM;
      for (int i = 0; i < tile_dim; i++) begin
        for (int j = 0; j < OUT_DIM; j++) begin
          @(posedge clk);
          mac_w_load_en <= 1'b1;
          mac_w_load_i  <= i[I_AW-1:0];
          mac_w_load_j  <= j[J_AW-1:0];
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
      mac_w_load_en  <= 1'b0;
      mac_w_load_i   <= '0;
      mac_w_load_j   <= '0;
      mac_w_load_pos <= '0;
      mac_w_load_neg <= '0;
    end
  endtask

  task automatic run_tile(input int valid_count, input int sum_max, input bit is_final);
    int guard;
    begin
      @(posedge clk);
      cfg_in_dim <= valid_count[15:0];
      cfg_out_dim <= OUT_DIM[15:0];
      cfg_threshold <= THRESHOLD;
      cfg_sum_max <= sum_max;
      cfg_input_src <= V2B_BUF_SEL_INPUT_SRAM;
      cfg_output_dst <= V2B_BUF_SEL_STREAM_A;
      cfg_tile_mode <= 1'b1;
      cfg_is_tile_final <= is_final;
      cfg_preserve_membrane <= 1'b0;
      cfg_t_count <= T[15:0];
      @(posedge clk);
      start_pulse <= 1'b1;
      @(posedge clk);
      start_pulse <= 1'b0;

      guard = 0;
      while (!done_pulse && guard < 2_000_000) begin
        @(posedge clk);
        guard++;
      end
      if (!done_pulse) begin
        $display("[FAIL] timeout waiting done_pulse final=%0d", is_final);
        errors++;
      end else begin
        $display("[TB] tile done final=%0d valid_count=%0d err=%02h cycles=%0d",
                 is_final, valid_count, err_code, guard);
      end
      if (err_code != V2B_STAGE_ERR_OK) begin
        $display("[FAIL] stage err_code=%02h", err_code);
        errors++;
      end
      @(posedge clk);
    end
  endtask

  task automatic read_tpb(input int t, input int j, output int value);
    begin
      @(posedge clk);
      tpb_rd_en_tb <= 1'b1;
      tpb_rd_t_tb  <= t[T_AW-1:0];
      tpb_rd_j_tb  <= j[J_AW-1:0];
      @(posedge clk);
      tpb_rd_en_tb <= 1'b0;
      @(posedge clk);
      value = $signed(tpb_rd_data);
    end
  endtask

  task automatic check_partial_trace(input bit after_final);
    int got;
    int exp;
    begin
      for (int k = 0; k < TRACE_N; k++) begin
        read_tpb(trace_t[k], trace_j[k], got);
        exp = after_final ? trace_final[k] : trace_tile0[k];
        if (got !== exp) begin
          if (after_final)
            $display("[FAIL] partial tile1_final t=%0d c=%0d got=%0d exp=%0d",
                     trace_t[k], trace_j[k], got, exp);
          else
            $display("[FAIL] partial tile0 t=%0d c=%0d got=%0d exp=%0d",
                     trace_t[k], trace_j[k], got, exp);
          errors++;
        end else begin
          if (after_final)
            $display("[TRACE] partial_tile1_final t=%0d c=%0d = %0d",
                     trace_t[k], trace_j[k], got);
          else
            $display("[TRACE] partial_tile0 t=%0d c=%0d = %0d",
                     trace_t[k], trace_j[k], got);
        end
      end
    end
  endtask

  task automatic check_stream_output;
    int got_counts [0:OUT_DIM-1];
    logic [P_N_OUT-1:0] row;
    int fd;
    begin
      for (int j = 0; j < OUT_DIM; j++) got_counts[j] = 0;
      fd = $fopen({golden_dir, "/rtl_spike_stream.hex"}, "wb");
      if (fd == 0) begin
        $display("[FATAL] cannot open rtl_spike_stream.hex for write");
        $finish;
      end

      for (int t = 0; t < T; t++) begin
        @(posedge clk);
        sbA_rd_en_tb   <= 1'b1;
        sbA_rd_addr_tb <= t[T_AW-1:0];
        @(posedge clk);
        sbA_rd_en_tb <= 1'b0;
        @(posedge clk);
        row = sbA_rd_data;
        $fwrite(fd, "%04x\n", row[OUT_DIM-1:0]);
        if (row[OUT_DIM-1:0] !== expected_spike[t]) begin
          $display("[FAIL] spike_stream t=%0d got=%04x exp=%04x",
                   t, row[OUT_DIM-1:0], expected_spike[t]);
          errors++;
        end
        for (int j = 0; j < OUT_DIM; j++) begin
          if (row[j]) got_counts[j]++;
        end
      end
      $fclose(fd);

      for (int j = 0; j < OUT_DIM; j++) begin
        if (got_counts[j] !== expected_counts[j]) begin
          $display("[FAIL] counts[%0d] got=%0d exp=%0d",
                   j, got_counts[j], expected_counts[j]);
          errors++;
        end
      end
      $display("[TB] RTL counts = [%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d]",
               got_counts[0], got_counts[1], got_counts[2], got_counts[3],
               got_counts[4], got_counts[5], got_counts[6], got_counts[7],
               got_counts[8], got_counts[9], got_counts[10], got_counts[11],
               got_counts[12], got_counts[13], got_counts[14], got_counts[15]);
    end
  endtask

  initial begin
    $display("[TB] tile_mode_1_e2e_tb start full_in=%0d tiles=%0d+%0d out=%0d T=%0d",
             FULL_IN_DIM, TILE0_DIM, TILE1_DIM, OUT_DIM, T);
    load_golden();

    rst_n = 0;
    repeat (6) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    clear_tile_partial();

    load_isr_tile(0);
    load_mac_weights(0);
    run_tile(TILE0_DIM, SUM_MAX0, 1'b0);
    check_partial_trace(1'b0);

    load_isr_tile(1);
    load_mac_weights(1);
    run_tile(TILE1_DIM, SUM_MAX1, 1'b1);
    check_partial_trace(1'b1);

    check_stream_output();

    if (errors == 0) $display("TILE_MODE_1_E2E_TB_PASS");
    else             $display("TILE_MODE_1_E2E_TB_FAIL errors=%0d", errors);
    $finish;
  end

  initial begin
    #50_000_000;
    $display("TILE_MODE_1_E2E_TB_TIMEOUT");
    $finish;
  end

endmodule
