`timescale 1ns/1ps
module lenet5_cosim_tb;
  import snn_soc_pkg::*;

  localparam int T = 10;
  localparam int P_BANK_WORDS = (V2B_CONV_FMAP_BANK_KIB * 1024) / 4;
  localparam int P_WEIGHT_TILE_WORDS = V2B_NUM_INPUTS * V2B_MAX_OUT_NEURONS;

  localparam logic [11:0] A_STAGE_CTRL       = 12'h000;
  localparam logic [11:0] A_STAGE_CFG0       = 12'h008;
  localparam logic [11:0] A_STAGE_CFG1       = 12'h00C;
  localparam logic [11:0] A_STAGE_CFG2       = 12'h010;
  localparam logic [11:0] A_STAGE_CFG3       = 12'h014;
  localparam logic [11:0] A_STAGE_CFG5       = 12'h01C;
  localparam logic [11:0] A_STREAM_BUF_CTRL  = 12'h060;
  localparam logic [11:0] A_CONV_MODE_CFG      = 12'h084;
  localparam logic [11:0] A_CONV_CFG_HW        = 12'h088;
  localparam logic [11:0] A_CONV_CFG_C         = 12'h08C;
  localparam logic [11:0] A_CONV_CFG_K_S_P     = 12'h090;
  localparam logic [11:0] A_CONV_CFG_OUT_HW    = 12'h094;
  localparam logic [11:0] A_CONV_CFG_T         = 12'h098;
  localparam logic [11:0] A_CONV_CFG_TILE      = 12'h09C;
  localparam logic [11:0] A_CONV_CFG_FMAP_BASE = 12'h0A0;
  localparam logic [11:0] A_CONV_CFG_OUT_BASE  = 12'h0A4;
  localparam logic [11:0] A_CONV_CTRL          = 12'h0A8;
  localparam logic [11:0] A_CONV_STATUS        = 12'h0AC;
  localparam logic [11:0] A_CONV_FMAP_WR_DATA  = 12'h0B0;
  localparam logic [11:0] A_CONV_FMAP_WR_ADDR  = 12'h0B4;
  localparam logic [11:0] A_CONV_FMAP_WR_CTRL  = 12'h0BC;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        cmd_valid = 1'b0;
  logic        cmd_ready;
  logic [11:0] cmd_addr = '0;
  logic        cmd_write = 1'b0;
  logic [31:0] cmd_wdata = '0;
  logic [3:0]  cmd_wstrb = 4'h0;
  logic        rsp_valid;
  logic [31:0] rsp_rdata;

  snn_soc_v2b_top dut (
    .clk(clk), .rst_n(rst_n),
    .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
    .cmd_addr(cmd_addr), .cmd_write(cmd_write),
    .cmd_wdata(cmd_wdata), .cmd_wstrb(cmd_wstrb),
    .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata)
  );

  logic [31:0] input_words [0:P_BANK_WORDS-1];
  logic [31:0] expected_words [0:P_BANK_WORDS-1];
  logic [3:0] weight_pos_tmp [0:P_WEIGHT_TILE_WORDS-1];
  logic [3:0] weight_neg_tmp [0:P_WEIGHT_TILE_WORDS-1];
  int expected_counts [0:9];
  int expected_stage_counts [0:127];

  string golden_dir;
  string rtl_counts_path;
  int samples;
  int errors = 0;
  int th_conv1;
  int th_conv2;
  int th_fc1;
  int th_fc2;
  int th_fc3;
  int summax_conv1;
  int summax_conv2;
  int summax_fc1;
  int summax_fc2;
  int summax_fc3;

  task automatic bus_write(input logic [11:0] addr, input logic [31:0] data);
    begin
      @(posedge clk);
      cmd_valid <= 1'b1;
      cmd_write <= 1'b1;
      cmd_addr <= addr;
      cmd_wdata <= data;
      cmd_wstrb <= 4'hF;
      @(posedge clk);
      cmd_valid <= 1'b0;
      cmd_write <= 1'b0;
      cmd_wstrb <= 4'h0;
      @(posedge clk);
    end
  endtask

  task automatic bus_read(input logic [11:0] addr, output logic [31:0] data);
    begin
      @(posedge clk);
      cmd_valid <= 1'b1;
      cmd_write <= 1'b0;
      cmd_addr <= addr;
      cmd_wstrb <= 4'h0;
      @(posedge clk);
      cmd_valid <= 1'b0;
      @(posedge clk);
      @(posedge clk);
      data = rsp_rdata;
    end
  endtask

  task automatic clear_streams;
    begin
      bus_write(A_STREAM_BUF_CTRL, 32'h0000_000E);
    end
  endtask

  task automatic load_input_fmap(input int sample_idx);
    string path;
    int word_idx;
    begin
      path = $sformatf("%s/sample_%02d_input_fmap_words.hex", golden_dir, sample_idx);
      for (word_idx = 0; word_idx < P_BANK_WORDS; word_idx++) input_words[word_idx] = 32'h0;
      $readmemh(path, input_words);
      bus_write(A_CONV_FMAP_WR_CTRL, 32'h0);
      for (word_idx = 0; word_idx < 784; word_idx++) begin
        bus_write(A_CONV_FMAP_WR_DATA, input_words[word_idx]);
        bus_write(A_CONV_FMAP_WR_ADDR, word_idx);
        bus_write(A_CONV_FMAP_WR_CTRL, 32'h1);
      end
    end
  endtask

  task automatic load_expected_counts(input int sample_idx);
    string path;
    integer fd;
    int idx;
    int value;
    int rc;
    begin
      path = $sformatf("%s/sample_%02d_output_counts.txt", golden_dir, sample_idx);
      fd = $fopen(path, "r");
      if (fd == 0) begin
        $display("[FATAL] cannot open %s", path);
        $finish;
      end
      for (int i = 0; i < 10; i++) expected_counts[i] = -1;
      while (!$feof(fd)) begin
        rc = $fscanf(fd, "%d %d\n", idx, value);
        if (rc == 2 && idx >= 0 && idx < 10) expected_counts[idx] = value;
      end
      $fclose(fd);
    end
  endtask

  task automatic load_expected_stage_counts(input int sample_idx, input string layer_name,
                                            input int out_dim);
    string path;
    integer fd;
    int idx;
    int value;
    int rc;
    begin
      path = $sformatf("%s/sample_%02d_stream_%s_counts.txt", golden_dir, sample_idx, layer_name);
      fd = $fopen(path, "r");
      if (fd == 0) begin
        $display("[FATAL] cannot open %s", path);
        $finish;
      end
      for (int i = 0; i < 128; i++) expected_stage_counts[i] = -1;
      while (!$feof(fd)) begin
        rc = $fscanf(fd, "%d %d\n", idx, value);
        if (rc == 2 && idx >= 0 && idx < out_dim) expected_stage_counts[idx] = value;
      end
      $fclose(fd);
    end
  endtask

  task automatic load_weight_tile(input string layer_name, input int tile_idx, input int c_out);
    string pos_path;
    string neg_path;
    int entry_count;
    int entry_idx;
    begin
      pos_path = $sformatf("%s/weights/synthetic_%s_weight_tile_%0d_pos.hex",
                           golden_dir, layer_name, tile_idx);
      neg_path = $sformatf("%s/weights/synthetic_%s_weight_tile_%0d_neg.hex",
                           golden_dir, layer_name, tile_idx);
      entry_count = V2B_NUM_INPUTS * c_out;
      for (entry_idx = 0; entry_idx < P_WEIGHT_TILE_WORDS; entry_idx++) begin
        weight_pos_tmp[entry_idx] = 4'h0;
        weight_neg_tmp[entry_idx] = 4'h0;
      end
      $readmemh(pos_path, weight_pos_tmp, 0, entry_count - 1);
      $readmemh(neg_path, weight_neg_tmp, 0, entry_count - 1);
      for (int lane = 0; lane < V2B_NUM_INPUTS; lane++) begin
        for (int oc = 0; oc < c_out; oc++) begin
          entry_idx = lane * c_out + oc;
          dut.u_mac.sim_w_pos_mem[lane][oc] = weight_pos_tmp[entry_idx];
          dut.u_mac.sim_w_neg_mem[lane][oc] = weight_neg_tmp[entry_idx];
        end
      end
    end
  endtask

  task automatic configure_conv(
    input int pp_sel,
    input int h,
    input int w,
    input int c_in,
    input int c_out,
    input int k,
    input int stride,
    input int pad,
    input int out_h,
    input int out_w,
    input int threshold,
    input int sum_max,
    input int tile_count,
    input int last_count
  );
    begin
      bus_write(A_STAGE_CFG1, threshold);
      bus_write(A_STAGE_CFG2, sum_max);
      bus_write(A_CONV_MODE_CFG, {29'h0, 1'b0, pp_sel[0], 1'b0, 1'b1});
      bus_write(A_CONV_CFG_HW, {w[15:0], h[15:0]});
      bus_write(A_CONV_CFG_C, {c_out[15:0], c_in[15:0]});
      bus_write(A_CONV_CFG_K_S_P, {20'h0, pad[3:0], stride[3:0], k[3:0]});
      bus_write(A_CONV_CFG_OUT_HW, {out_w[15:0], out_h[15:0]});
      bus_write(A_CONV_CFG_T, T);
      bus_write(A_CONV_CFG_TILE, {last_count[15:0], tile_count[15:0]});
      bus_write(A_CONV_CFG_FMAP_BASE, 32'd0);
      bus_write(A_CONV_CFG_OUT_BASE, 32'd0);
      bus_write(A_CONV_STATUS, 32'h0000_0002);
    end
  endtask

  task automatic configure_flatten(
    input int pp_sel,
    input int h,
    input int w,
    input int c_in,
    input int c_out,
    input int threshold,
    input int sum_max,
    input int tile_count,
    input int last_count
  );
    begin
      bus_write(A_STAGE_CFG1, threshold);
      bus_write(A_STAGE_CFG2, sum_max);
      bus_write(A_CONV_MODE_CFG, {29'h0, 1'b0, pp_sel[0], 1'b1, 1'b1});
      bus_write(A_CONV_CFG_HW, {w[15:0], h[15:0]});
      bus_write(A_CONV_CFG_C, {c_out[15:0], c_in[15:0]});
      bus_write(A_CONV_CFG_K_S_P, 32'h0);
      bus_write(A_CONV_CFG_OUT_HW, {16'd1, 16'd1});
      bus_write(A_CONV_CFG_T, T);
      bus_write(A_CONV_CFG_TILE, {last_count[15:0], tile_count[15:0]});
      bus_write(A_CONV_CFG_FMAP_BASE, 32'd0);
      bus_write(A_CONV_CFG_OUT_BASE, 32'd0);
      bus_write(A_CONV_STATUS, 32'h0000_0002);
    end
  endtask

  task automatic wait_for_weight_req(output logic [31:0] status);
    int guard;
    begin
      guard = 0;
      status = 32'h0;
      while (!status[2] && !status[1] && guard < 300000) begin
        bus_read(A_CONV_STATUS, status);
        guard++;
      end
      if (!status[2]) begin
        $display("[FAIL] expected WEIGHT_REQ, status=0x%08h", status);
        errors++;
      end
    end
  endtask

  task automatic wait_conv_done(input string tag);
    logic [31:0] status;
    int guard;
    begin
      guard = 0;
      status = 32'h0;
      while (!status[1] && guard < 1000000) begin
        bus_read(A_CONV_STATUS, status);
        guard++;
      end
      if (!status[1] || status[7:4] != 4'h0) begin
        $display("[FAIL] %s status=0x%08h guard=%0d", tag, status, guard);
        errors++;
      end else begin
        $display("[TB] %s done status=0x%08h", tag, status);
      end
    end
  endtask

  task automatic service_conv_layer(input string layer_name, input int pixels, input int c_out);
    logic [31:0] status;
    int tile_idx;
    begin
      for (int req = 0; req < pixels; req++) begin
        wait_for_weight_req(status);
        tile_idx = status[31:24];
        load_weight_tile(layer_name, tile_idx, c_out);
        bus_write(A_CONV_CTRL, 32'h0000_0004);
      end
    end
  endtask

  task automatic start_conv_and_service(input string tag, input string layer_name,
                                        input int requests, input int c_out);
    begin
      bus_write(A_CONV_CTRL, 32'h0000_0001);
      service_conv_layer(layer_name, requests, c_out);
      wait_conv_done(tag);
    end
  endtask

  task automatic run_fc_stage(input string layer_name, input int in_dim, input int out_dim,
                              input int threshold, input int sum_max,
                              input int input_src, input int output_dst);
    logic [31:0] ctrl;
    int cfg3;
    int guard;
    begin
      load_weight_tile(layer_name, 0, out_dim);
      bus_write(A_STAGE_CTRL, 32'h0000_0080);
      bus_write(A_STAGE_CFG0, {out_dim[15:0], in_dim[15:0]});
      bus_write(A_STAGE_CFG1, threshold);
      bus_write(A_STAGE_CFG2, sum_max);
      cfg3 = (output_dst << 8) | input_src;
      bus_write(A_STAGE_CFG3, cfg3[31:0]);
      bus_write(A_STAGE_CFG5, T);
      bus_write(A_STAGE_CTRL, 32'h1);
      guard = 0;
      ctrl = 32'h0;
      while (!ctrl[7] && guard < 500000) begin
        bus_read(A_STAGE_CTRL, ctrl);
        guard++;
      end
      if (!ctrl[7]) begin
        $display("[FAIL] %s stage timeout ctrl=0x%08h", layer_name, ctrl);
        errors++;
      end
    end
  endtask

  task automatic check_final_counts(input int sample_idx);
    int got [0:9];
    int fd;
    int pred;
    int exp_pred;
    begin
      for (int c = 0; c < 10; c++) got[c] = 0;
      for (int t = 0; t < T; t++) begin
        for (int c = 0; c < 10; c++) begin
          if (dut.u_sbA.mem[t][c]) got[c]++;
        end
      end
      fd = $fopen(rtl_counts_path, "a");
      if (fd == 0) begin
        $display("[FATAL] cannot open rtl counts path %s", rtl_counts_path);
        $finish;
      end
      $fwrite(fd, "sample %0d\n", sample_idx);
      for (int c = 0; c < 10; c++) begin
        $fwrite(fd, "%0d %0d\n", c, got[c]);
        if (got[c] != expected_counts[c]) begin
          $display("[FAIL] sample=%0d class=%0d got=%0d exp=%0d",
                   sample_idx, c, got[c], expected_counts[c]);
          errors++;
        end
      end
      $fclose(fd);
      pred = 0; exp_pred = 0;
      for (int c = 1; c < 10; c++) begin
        if (got[c] > got[pred]) pred = c;
        if (expected_counts[c] > expected_counts[exp_pred]) exp_pred = c;
      end
      $display("[TB] sample=%0d pred=%0d exp_pred=%0d counts=[%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d]",
               sample_idx, pred, exp_pred,
               got[0], got[1], got[2], got[3], got[4],
               got[5], got[6], got[7], got[8], got[9]);
    end
  endtask

  task automatic check_stream_counts(input string tag, input int out_dim, input int bank_sel);
    int got;
    begin
      for (int c = 0; c < out_dim; c++) begin
        got = 0;
        for (int t = 0; t < T; t++) begin
          if (bank_sel == 0) begin
            if (dut.u_sbA.mem[t][c]) got++;
          end else begin
            if (dut.u_sbB.mem[t][c]) got++;
          end
        end
        if (got != expected_stage_counts[c]) begin
          if (errors < 24) begin
            $display("[FAIL] %s c=%0d got=%0d exp=%0d",
                     tag, c, got, expected_stage_counts[c]);
          end
          errors++;
        end
      end
    end
  endtask

  task automatic check_fmap_words(input int sample_idx, input string layer_name,
                                  input int word_count, input int bank_sel);
    string path;
    logic [31:0] got;
    begin
      path = $sformatf("%s/sample_%02d_intermediate_%s.hex", golden_dir, sample_idx, layer_name);
      for (int i = 0; i < P_BANK_WORDS; i++) expected_words[i] = 32'h0;
      $readmemh(path, expected_words, 0, word_count - 1);
      for (int i = 0; i < word_count; i++) begin
        got = (bank_sel == 0) ? dut.u_fmap.bank_a[i] : dut.u_fmap.bank_b[i];
        if (got !== expected_words[i]) begin
          if (errors < 24) begin
            $display("[FAIL] %s bank=%0d word[%0d] got=0x%08h exp=0x%08h",
                     layer_name, bank_sel, i, got, expected_words[i]);
          end
          errors++;
        end
      end
    end
  endtask

  task automatic run_sample(input int sample_idx);
    begin
      clear_streams();
      load_expected_counts(sample_idx);
      load_input_fmap(sample_idx);

      configure_conv(0, 28, 28, 1, 6, 5, 1, 2, 28, 28, th_conv1, summax_conv1, 1, 25);
      start_conv_and_service("conv1", "conv1", 28*28, 6);
      check_fmap_words(sample_idx, "conv1", 28*28*6, 1);

      configure_conv(1, 28, 28, 6, 16, 5, 2, 0, 12, 12, th_conv2, summax_conv2, 1, 150);
      start_conv_and_service("conv2", "conv2", 12*12, 16);
      check_fmap_words(sample_idx, "conv2", 12*12*16, 0);

      clear_streams();
      configure_flatten(0, 12, 12, 16, 120, th_fc1, summax_fc1, 9, 256);
      start_conv_and_service("fc1_flatten", "fc1", 9, 120);
      load_expected_stage_counts(sample_idx, "fc1", 120);
      check_stream_counts("fc1_stream_A", 120, 0);

      run_fc_stage("fc2", 120, 84, th_fc2, summax_fc2, V2B_BUF_SEL_STREAM_A, V2B_BUF_SEL_STREAM_B);
      load_expected_stage_counts(sample_idx, "fc2", 84);
      check_stream_counts("fc2_stream_B", 84, 1);
      run_fc_stage("fc3", 84, 10, th_fc3, summax_fc3, V2B_BUF_SEL_STREAM_B, V2B_BUF_SEL_STREAM_A);
      check_final_counts(sample_idx);
    end
  endtask

  initial begin
    if (!$value$plusargs("GOLDEN_DIR=%s", golden_dir))
      golden_dir = "../python_multilayer/results_conv/lenet5";
    if (!$value$plusargs("RTL_COUNTS=%s", rtl_counts_path))
      rtl_counts_path = "lenet5_rtl_counts.txt";
    if (!$value$plusargs("SAMPLES=%d", samples))
      samples = 1;
    if (!$value$plusargs("TH_CONV1=%d", th_conv1)) th_conv1 = 9;
    if (!$value$plusargs("TH_CONV2=%d", th_conv2)) th_conv2 = 17;
    if (!$value$plusargs("TH_FC1=%d", th_fc1)) th_fc1 = 25;
    if (!$value$plusargs("TH_FC2=%d", th_fc2)) th_fc2 = 17;
    if (!$value$plusargs("TH_FC3=%d", th_fc3)) th_fc3 = 9;
    if (!$value$plusargs("SUMMAX_CONV1=%d", summax_conv1)) summax_conv1 = 25 * 7;
    if (!$value$plusargs("SUMMAX_CONV2=%d", summax_conv2)) summax_conv2 = 150 * 7;
    if (!$value$plusargs("SUMMAX_FC1=%d", summax_fc1)) summax_fc1 = 256 * 7;
    if (!$value$plusargs("SUMMAX_FC2=%d", summax_fc2)) summax_fc2 = 120 * 7;
    if (!$value$plusargs("SUMMAX_FC3=%d", summax_fc3)) summax_fc3 = 84 * 7;

    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    for (int s = 0; s < samples; s++) begin
      run_sample(s);
    end

    if (errors == 0) $display("LENET5_COSIM_TB_PASS samples=%0d", samples);
    else             $display("LENET5_COSIM_TB_FAIL errors=%0d", errors);
    $finish;
  end

  initial begin
    #20_000_000_000;
    $display("LENET5_COSIM_TB_TIMEOUT");
    $finish;
  end
endmodule
