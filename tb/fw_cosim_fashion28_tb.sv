`timescale 1ns/1ps
//======================================================================
// tb/fw_cosim_fashion28_tb.sv
//
// Config #5 firmware-style cosim TB.
// Mirrors the board scheduler contract:
//   - stage 0: 784 -> 64, 4 tiles under 256-WL cap
//              with fixed full-stage sum_max on every tile
//   - stage 1: 64 -> 10 single-tile streamed stage
//   - expected counts come from the board-equivalent Python baseline bundle
//======================================================================
module fw_cosim_fashion28_tb;

  import snn_soc_pkg::*;

  localparam int NUM_SAMPLES = 10;
  localparam int T = 64;
  localparam int S0_IN_DIM = 784, S0_OUT_DIM = 64;
  localparam int S1_IN_DIM = 64,  S1_OUT_DIM = 10;
  localparam int S0_THR = 16;
  localparam int S0_SUM_MAX = S0_IN_DIM * 15;
  localparam int S1_THR = 8, S1_SUM_MAX = 960;
  localparam int WL_CAP = 256;
  localparam int WL_PAD = 1024;
  localparam int WORDS_PER_ROW = 8;

  localparam logic [11:0] A_STAGE_CTRL      = 12'h000;
  localparam logic [11:0] A_STAGE_STATUS    = 12'h004;
  localparam logic [11:0] A_STAGE_CFG0      = 12'h008;
  localparam logic [11:0] A_STAGE_CFG1      = 12'h00C;
  localparam logic [11:0] A_STAGE_CFG2      = 12'h010;
  localparam logic [11:0] A_STAGE_CFG3      = 12'h014;
  localparam logic [11:0] A_STAGE_CFG5      = 12'h01C;
  localparam logic [11:0] A_INPUT_SRAM_ADDR = 12'h020;
  localparam logic [11:0] A_INPUT_SRAM_W0   = 12'h024;
  localparam logic [11:0] A_INPUT_SRAM_CTRL = 12'h044;
  localparam logic [11:0] A_MAC_W_LOAD_ADDR = 12'h050;
  localparam logic [11:0] A_MAC_W_LOAD_DATA = 12'h054;
  localparam logic [11:0] A_MAC_W_LOAD_CTRL = 12'h058;
  localparam logic [11:0] A_STREAM_BUF_CTRL = 12'h060;
  localparam logic [11:0] A_READ_SBB_BASE   = 12'h800;
  localparam int CFG3_TILE_MODE_SHIFT = 16;
  localparam int CFG3_IS_TILE_FINAL_SHIFT = 17;
  localparam logic [31:0] STREAM_BUF_CLEAR_A = 32'h2;
  localparam logic [31:0] STREAM_BUF_CLEAR_B = 32'h4;
  localparam logic [31:0] STREAM_BUF_CLEAR_TILE_BUF = 32'h8;

  localparam logic [V2B_BUF_SEL_W-1:0] BUF_SEL_INPUT_SRAM = V2B_BUF_SEL_INPUT_SRAM;
  localparam logic [V2B_BUF_SEL_W-1:0] BUF_SEL_STREAM_A   = V2B_BUF_SEL_STREAM_A;
  localparam logic [1:0]               BUF_DST_STREAM_A   = 2'd1;
  localparam logic [1:0]               BUF_DST_STREAM_B   = 2'd2;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic        cmd_valid = 0;
  logic        cmd_ready;
  logic [11:0] cmd_addr  = '0;
  logic        cmd_write = 0;
  logic [31:0] cmd_wdata = '0;
  logic [3:0]  cmd_wstrb = 4'hF;
  logic        rsp_valid;
  logic [31:0] rsp_rdata;

  snn_soc_v2b_top #(
    .P_ENABLE_TILE_BUF(1),
    .P_ADC_BITS(10)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
    .cmd_addr(cmd_addr), .cmd_write(cmd_write),
    .cmd_wdata(cmd_wdata), .cmd_wstrb(cmd_wstrb),
    .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata)
  );

  task automatic bus_write(input [11:0] addr, input [31:0] data);
    begin
      @(posedge clk);
      cmd_valid <= 1'b1;
      cmd_write <= 1'b1;
      cmd_addr  <= addr;
      cmd_wdata <= data;
      @(posedge clk);
      cmd_valid <= 1'b0;
    end
  endtask

  task automatic bus_read(input [11:0] addr, output [31:0] data);
    begin
      @(posedge clk);
      cmd_valid <= 1'b1;
      cmd_write <= 1'b0;
      cmd_addr  <= addr;
      @(posedge clk);
      cmd_valid <= 1'b0;
      @(posedge clk);
      @(posedge clk);
      data = rsp_rdata;
    end
  endtask

  logic [3:0] s0_w_pos_flat [0:S0_IN_DIM*S0_OUT_DIM-1];
  logic [3:0] s0_w_neg_flat [0:S0_IN_DIM*S0_OUT_DIM-1];
  logic [3:0] s1_w_pos_flat [0:S1_IN_DIM*S1_OUT_DIM-1];
  logic [3:0] s1_w_neg_flat [0:S1_IN_DIM*S1_OUT_DIM-1];
  logic [WL_PAD-1:0] sample_wl_stream [0:T-1];
  int expected_counts [0:S1_OUT_DIM-1];
  int counts_m [0:S1_OUT_DIM-1];
  int errors = 0;

  string golden_dir = "../h1_closeout_logs/config5_board_verify_2026_05_10/python_baseline";
  string golden_dir_plusarg;

  initial begin
    if ($value$plusargs("GOLDEN_DIR=%s", golden_dir_plusarg)) begin
      golden_dir = golden_dir_plusarg;
      $display("[TB] overriding golden_dir=%s", golden_dir);
    end
  end

  task automatic load_sample_golden(input int k);
    string path;
    int fd;
    int dummy;
    begin
      path = $sformatf("%s/sample_%02d_wl_stream.hex", golden_dir, k);
      $readmemh(path, sample_wl_stream);
      path = $sformatf("%s/sample_%02d_counts.txt", golden_dir, k);
      fd = $fopen(path, "r");
      if (fd == 0) begin
        $display("[FATAL] can't open %s", path);
        $finish;
      end
      for (int j = 0; j < S1_OUT_DIM; j++)
        dummy = $fscanf(fd, "%d\n", expected_counts[j]);
      $fclose(fd);
    end
  endtask

  task automatic sw_load_input_stream_tile(input int tile_start, input int tile_in_dim);
    begin
      for (int t = 0; t < T; t++) begin
        logic [255:0] row;
        row = 256'h0;
        for (int i = 0; i < tile_in_dim; i++)
          row[i] = sample_wl_stream[t][tile_start + i];
        bus_write(A_INPUT_SRAM_ADDR, t);
        bus_write(A_INPUT_SRAM_W0, row[31:0]);
        bus_write(A_INPUT_SRAM_W0 + 12'h4, row[63:32]);
        bus_write(A_INPUT_SRAM_W0 + 12'h8, row[95:64]);
        bus_write(A_INPUT_SRAM_W0 + 12'hC, row[127:96]);
        bus_write(A_INPUT_SRAM_W0 + 12'h10, row[159:128]);
        bus_write(A_INPUT_SRAM_W0 + 12'h14, row[191:160]);
        bus_write(A_INPUT_SRAM_W0 + 12'h18, row[223:192]);
        bus_write(A_INPUT_SRAM_W0 + 12'h1C, row[255:224]);
        bus_write(A_INPUT_SRAM_CTRL, 32'h1);
      end
    end
  endtask

  task automatic sw_load_mac_weights_s0_tile(input int tile_start, input int tile_in_dim);
    begin
      for (int i = 0; i < tile_in_dim; i++) begin
        for (int j = 0; j < S0_OUT_DIM; j++) begin
          bus_write(A_MAC_W_LOAD_ADDR, (j << 8) | i);
          bus_write(A_MAC_W_LOAD_DATA,
                    (s0_w_neg_flat[(tile_start + i) * S0_OUT_DIM + j] << 4) |
                     s0_w_pos_flat[(tile_start + i) * S0_OUT_DIM + j]);
          bus_write(A_MAC_W_LOAD_CTRL, 32'h1);
        end
      end
    end
  endtask

  task automatic sw_load_mac_weights_s1;
    begin
      for (int i = 0; i < S1_IN_DIM; i++) begin
        for (int j = 0; j < S1_OUT_DIM; j++) begin
          bus_write(A_MAC_W_LOAD_ADDR, (j << 8) | i);
          bus_write(A_MAC_W_LOAD_DATA,
                    (s1_w_neg_flat[i * S1_OUT_DIM + j] << 4) |
                     s1_w_pos_flat[i * S1_OUT_DIM + j]);
          bus_write(A_MAC_W_LOAD_CTRL, 32'h1);
        end
      end
    end
  endtask

  task automatic sw_run_stage_cfg(
    input int in_dim, input int out_dim,
    input int threshold, input int sum_max,
    input logic [V2B_BUF_SEL_W-1:0] input_src,
    input logic [1:0] output_dst,
    input bit tile_mode,
    input bit is_tile_final
  );
    logic [31:0] cfg3_val, sts;
    int g;
    begin
      bus_write(A_STAGE_CFG0, (in_dim & 32'hFFFF) | ((out_dim & 32'hFFFF) << 16));
      bus_write(A_STAGE_CFG1, threshold);
      bus_write(A_STAGE_CFG2, sum_max);
      cfg3_val = 32'h0;
      cfg3_val[V2B_BUF_SEL_W-1:0] = input_src;
      cfg3_val[9:8] = output_dst;
      if (tile_mode) cfg3_val[CFG3_TILE_MODE_SHIFT] = 1'b1;
      if (is_tile_final) cfg3_val[CFG3_IS_TILE_FINAL_SHIFT] = 1'b1;
      bus_write(A_STAGE_CFG3, cfg3_val);
      bus_write(A_STAGE_CFG5, T);
      bus_write(A_STAGE_CTRL, 32'h1);
      g = 0;
      sts = 32'h1;
      while (sts[0] && g < 400_000) begin
        bus_read(A_STAGE_STATUS, sts);
        g = g + 1;
      end
      if (sts[0]) begin
        $display("[FAIL] stage BUSY never clears");
        errors++;
      end else if (sts[23:16] != 8'h00) begin
        $display("[FAIL] stage err_code = %02h", sts[23:16]);
        errors++;
      end
      bus_write(A_STAGE_CTRL, 32'h80);
    end
  endtask

  task automatic sw_count_stage1_spikes;
    logic [31:0] row;
    begin
      for (int j = 0; j < S1_OUT_DIM; j++) counts_m[j] = 0;
      for (int t = 0; t < T; t++) begin
        bus_read(A_READ_SBB_BASE + (t << 2), row);
        for (int j = 0; j < S1_OUT_DIM; j++)
          if (row[j]) counts_m[j] = counts_m[j] + 1;
      end
    end
  endtask

  task automatic sw_infer_from_golden_wl(input int k);
    int mismatch;
    begin
      load_sample_golden(k);
      bus_write(A_STREAM_BUF_CTRL, STREAM_BUF_CLEAR_A |
                                  STREAM_BUF_CLEAR_B |
                                  STREAM_BUF_CLEAR_TILE_BUF);

      for (int tile_idx = 0; tile_idx < 4; tile_idx++) begin
        int tile_start = tile_idx * WL_CAP;
        int tile_stop = tile_start + WL_CAP;
        int tile_in_dim;
        if (tile_stop > S0_IN_DIM) tile_stop = S0_IN_DIM;
        tile_in_dim = tile_stop - tile_start;
        sw_load_input_stream_tile(tile_start, tile_in_dim);
        sw_load_mac_weights_s0_tile(tile_start, tile_in_dim);
        sw_run_stage_cfg(tile_in_dim, S0_OUT_DIM, S0_THR, S0_SUM_MAX,
                         BUF_SEL_INPUT_SRAM, BUF_DST_STREAM_A, 1'b1, (tile_idx == 3));
      end

      sw_load_mac_weights_s1();
      sw_run_stage_cfg(S1_IN_DIM, S1_OUT_DIM, S1_THR, S1_SUM_MAX,
                       BUF_SEL_STREAM_A, BUF_DST_STREAM_B, 1'b0, 1'b1);
      sw_count_stage1_spikes();

      mismatch = 0;
      for (int j = 0; j < S1_OUT_DIM; j++) begin
        if (counts_m[j] !== expected_counts[j]) begin
          $display("[FAIL] sample %0d class %0d got=%0d exp=%0d",
                   k, j, counts_m[j], expected_counts[j]);
          mismatch++;
        end
      end
      if (mismatch == 0) begin
        $display("[PASS] sample %0d counts=[%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d]",
                 k,
                 counts_m[0], counts_m[1], counts_m[2], counts_m[3], counts_m[4],
                 counts_m[5], counts_m[6], counts_m[7], counts_m[8], counts_m[9]);
      end else begin
        errors += mismatch;
      end
    end
  endtask

  initial begin
    $display("[TB] fw_cosim_fashion28_tb start (%0d samples)", NUM_SAMPLES);
    rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    $readmemh({golden_dir, "/stage0_w_pos.hex"}, s0_w_pos_flat);
    $readmemh({golden_dir, "/stage0_w_neg.hex"}, s0_w_neg_flat);
    $readmemh({golden_dir, "/stage1_w_pos.hex"}, s1_w_pos_flat);
    $readmemh({golden_dir, "/stage1_w_neg.hex"}, s1_w_neg_flat);

    for (int k = 0; k < NUM_SAMPLES; k++) begin
      $display("[TB] ---- sample %0d ----", k);
      sw_infer_from_golden_wl(k);
    end

    if (errors == 0) $display("FW_COSIM_FASHION28_TB_PASS");
    else             $display("FW_COSIM_FASHION28_TB_FAIL (errors=%0d)", errors);
    $finish;
  end

  initial begin
    #(600_000_000);
    $display("FW_COSIM_FASHION28_TB_TIMEOUT");
    $finish;
  end

endmodule
