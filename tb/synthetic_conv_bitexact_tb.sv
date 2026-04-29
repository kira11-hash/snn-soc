`timescale 1ns/1ps

`ifndef CONV_CASE_TB_MODULE
`define CONV_CASE_TB_MODULE synthetic_conv_bitexact_tb
`endif
`ifndef CONV_CASE_TB_PASS_TAG
`define CONV_CASE_TB_PASS_TAG "SYNTHETIC_CONV_BITEXACT_PASS"
`endif
`ifndef CONV_CASE_TB_FAIL_TAG
`define CONV_CASE_TB_FAIL_TAG "SYNTHETIC_CONV_BITEXACT_FAIL"
`endif

module `CONV_CASE_TB_MODULE;
  import snn_soc_pkg::*;

  localparam int P_BANK_WORDS = (V2B_CONV_FMAP_BANK_KIB * 1024) / 4;
  localparam int MAX_TILE_COUNT = 13;
  localparam int P_WEIGHT_TILE_WORDS = V2B_NUM_INPUTS * V2B_MAX_OUT_NEURONS;

  localparam logic [11:0] A_STAGE_CFG1       = 12'h00C;
  localparam logic [11:0] A_STAGE_CFG2       = 12'h010;
  localparam logic [11:0] A_MAC_W_LOAD_ADDR  = 12'h050;
  localparam logic [11:0] A_MAC_W_LOAD_DATA  = 12'h054;
  localparam logic [11:0] A_MAC_W_LOAD_CTRL  = 12'h058;
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
  logic [11:0] cmd_addr  = '0;
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
  logic [3:0] weight_pos [0:MAX_TILE_COUNT*P_WEIGHT_TILE_WORDS-1];
  logic [3:0] weight_neg [0:MAX_TILE_COUNT*P_WEIGHT_TILE_WORDS-1];
  logic [3:0] weight_pos_tmp [0:P_WEIGHT_TILE_WORDS-1];
  logic [3:0] weight_neg_tmp [0:P_WEIGHT_TILE_WORDS-1];
  int expected_counts [0:P_BANK_WORDS-1];

  string case_name;
  string golden_dir;
  string out_dir;
  string rtl_counts_path;
  string status_err_path;

  int case_tag;
  int cfg_K;
  int cfg_stride;
  int cfg_pad;
  int cfg_C_in;
  int cfg_C_out;
  int cfg_H;
  int cfg_W;
  int cfg_out_H;
  int cfg_out_W;
  int cfg_T;
  int cfg_threshold;
  int cfg_tile_count;
  int cfg_last_tile_valid_count;
  int expected_err_code;
  string expected_err_name;

  int stream_words;
  int input_word_count;
  int output_word_count;
  int output_count_entries;
  int weight_entries_per_tile;
  int expected_stage_runs;

  int errors = 0;
  int weight_req_count = 0;
  int stage_start_count = 0;
  int mac_start_count = 0;
  int mac_done_count = 0;
  int fmap_write_count = 0;
  int output_bank_changed_words = 0;
  int current_loaded_tile = -1;
  int weight_ready_delay_max = 0;
  int force_timeout = 0;
  int random_seed = 32'h13579;

  logic conv_weight_req_q = 1'b0;
  logic [31:0] final_status = 32'h0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      conv_weight_req_q <= 1'b0;
      weight_req_count <= 0;
      stage_start_count <= 0;
      mac_start_count <= 0;
      mac_done_count <= 0;
      fmap_write_count <= 0;
    end else begin
      if (dut.conv_weight_req && !conv_weight_req_q)
        weight_req_count <= weight_req_count + 1;
      conv_weight_req_q <= dut.conv_weight_req;

      if (dut.conv_stage_start_pulse) stage_start_count <= stage_start_count + 1;
      if (dut.mac_start)              mac_start_count   <= mac_start_count + 1;
      if (dut.mac_done)               mac_done_count    <= mac_done_count + 1;
      if (dut.conv_fmap_wr_en)        fmap_write_count  <= fmap_write_count + 1;
    end
  end

  function automatic int popcount_limited(input logic [31:0] word,
                                          input int valid_bits);
    int count;
    int bit_idx;
    begin
      count = 0;
      for (bit_idx = 0; bit_idx < valid_bits; bit_idx = bit_idx + 1)
        if (word[bit_idx] === 1'b1)
          count = count + 1;
      popcount_limited = count;
    end
  endfunction

  function automatic logic [31:0] sentinel_word(input int word_idx);
    begin
      sentinel_word = 32'hA5C3_0000 ^ (case_tag << 8) ^ word_idx;
    end
  endfunction

  function automatic string err_name_from_code(input int code);
    begin
      case (code)
        0: err_name_from_code = "OK";
        1: err_name_from_code = "ERR_ILLEGAL_KKC";
        2: err_name_from_code = "ERR_TILE_CFG_MISMATCH";
        3: err_name_from_code = "ERR_BAD_GEOMETRY";
        4: err_name_from_code = "ERR_FMAP_OOB";
        5: err_name_from_code = "ERR_BAD_T";
        6: err_name_from_code = "ERR_BAD_COUT";
        7: err_name_from_code = "ERR_FMAP_WRITE_WHILE_BUSY";
        8: err_name_from_code = "ERR_WEIGHT_TIMEOUT";
        9: err_name_from_code = "ERR_FMAP_WR_OOB";
        default: err_name_from_code = $sformatf("UNKNOWN_%0d", code);
      endcase
    end
  endfunction

  task automatic fail_now(input string msg);
    begin
      $display("[FATAL] %s", msg);
      $finish;
    end
  endtask

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
      wait (rsp_valid);
      data = rsp_rdata;
      @(posedge clk);
    end
  endtask

  task automatic require_plusargs;
    begin
      if (!$value$plusargs("CASE_NAME=%s", case_name))
        fail_now("missing +CASE_NAME");
      if (!$value$plusargs("CASE_TAG=%d", case_tag))
        fail_now("missing +CASE_TAG");
      if (!$value$plusargs("GOLDEN_DIR=%s", golden_dir))
        golden_dir = "../python_multilayer";
      if (!$value$plusargs("OUT_DIR=%s", out_dir))
        out_dir = ".";
      if (!$value$plusargs("K=%d", cfg_K))
        fail_now("missing +K");
      if (!$value$plusargs("STRIDE=%d", cfg_stride))
        fail_now("missing +STRIDE");
      if (!$value$plusargs("PAD=%d", cfg_pad))
        fail_now("missing +PAD");
      if (!$value$plusargs("C_IN=%d", cfg_C_in))
        fail_now("missing +C_IN");
      if (!$value$plusargs("C_OUT=%d", cfg_C_out))
        fail_now("missing +C_OUT");
      if (!$value$plusargs("H=%d", cfg_H))
        fail_now("missing +H");
      if (!$value$plusargs("W=%d", cfg_W))
        fail_now("missing +W");
      if (!$value$plusargs("OUT_H=%d", cfg_out_H))
        fail_now("missing +OUT_H");
      if (!$value$plusargs("OUT_W=%d", cfg_out_W))
        fail_now("missing +OUT_W");
      if (!$value$plusargs("T=%d", cfg_T))
        fail_now("missing +T");
      if (!$value$plusargs("THRESHOLD=%d", cfg_threshold))
        fail_now("missing +THRESHOLD");
      if (!$value$plusargs("TILE_COUNT=%d", cfg_tile_count))
        fail_now("missing +TILE_COUNT");
      if (!$value$plusargs("LAST_TILE_VALID=%d", cfg_last_tile_valid_count))
        fail_now("missing +LAST_TILE_VALID");
      if (!$value$plusargs("EXPECTED_ERR_CODE=%d", expected_err_code))
        fail_now("missing +EXPECTED_ERR_CODE");
      if (!$value$plusargs("EXPECTED_ERR_NAME=%s", expected_err_name))
        expected_err_name = err_name_from_code(expected_err_code);
      if (!$value$plusargs("WEIGHT_READY_DELAY_MAX=%d", weight_ready_delay_max))
        weight_ready_delay_max = 0;
      if (!$value$plusargs("FORCE_TIMEOUT=%d", force_timeout))
        force_timeout = 0;
      if (!$value$plusargs("RANDOM_SEED=%d", random_seed))
        random_seed = 32'h13579;

      stream_words = (cfg_T + 31) >> 5;
      input_word_count = cfg_H * cfg_W * cfg_C_in * stream_words;
      output_word_count = cfg_out_H * cfg_out_W * cfg_C_out * stream_words;
      output_count_entries = cfg_out_H * cfg_out_W * cfg_C_out;
      weight_entries_per_tile = V2B_NUM_INPUTS * cfg_C_out;
      expected_stage_runs = cfg_out_H * cfg_out_W * cfg_tile_count;

      if (cfg_tile_count <= 0 || cfg_tile_count > MAX_TILE_COUNT)
        fail_now("cfg_tile_count outside TB bounds");
      if (input_word_count < 0)
        fail_now("input_word_count outside TB bounds");
      if (expected_err_code == 0 && input_word_count > P_BANK_WORDS)
        fail_now("legal-case input_word_count outside TB bounds");
      if (output_word_count < 0 || output_word_count > P_BANK_WORDS)
        fail_now("output_word_count outside TB bounds");
      if (output_count_entries < 0 || output_count_entries > P_BANK_WORDS)
        fail_now("output_count_entries outside TB bounds");
      if (weight_entries_per_tile < 0 || weight_entries_per_tile > P_WEIGHT_TILE_WORDS)
        fail_now("weight_entries_per_tile outside TB bounds");

      rtl_counts_path = {out_dir, "/synthetic_", case_name, "_rtl_output_counts.txt"};
      status_err_path = {out_dir, "/synthetic_", case_name, "_STATUS.ERR"};
    end
  endtask

  task automatic load_input_words;
    string path;
    begin
      path = {golden_dir, "/synthetic_", case_name, "_input_fmap_words.hex"};
      $display("[TB] loading input fmap %s", path);
      $readmemh(path, input_words, 0, input_word_count - 1);
    end
  endtask

  task automatic load_weight_tiles;
    string pos_path;
    string neg_path;
    int tile_idx;
    int tile_base;
    int entry_idx;
    begin
      for (tile_idx = 0; tile_idx < cfg_tile_count; tile_idx = tile_idx + 1) begin
        tile_base = tile_idx * P_WEIGHT_TILE_WORDS;
        pos_path = $sformatf("%s/synthetic_%s_weight_tile_%0d_pos.hex",
                             golden_dir, case_name, tile_idx);
        neg_path = $sformatf("%s/synthetic_%s_weight_tile_%0d_neg.hex",
                             golden_dir, case_name, tile_idx);
        $display("[TB] loading weight tile %0d pos=%s neg=%s", tile_idx, pos_path, neg_path);
        for (entry_idx = 0; entry_idx < P_WEIGHT_TILE_WORDS; entry_idx = entry_idx + 1) begin
          weight_pos_tmp[entry_idx] = 4'h0;
          weight_neg_tmp[entry_idx] = 4'h0;
        end
        $readmemh(pos_path, weight_pos_tmp, 0, weight_entries_per_tile - 1);
        $readmemh(neg_path, weight_neg_tmp, 0, weight_entries_per_tile - 1);
        for (entry_idx = 0; entry_idx < weight_entries_per_tile; entry_idx = entry_idx + 1) begin
          weight_pos[tile_base + entry_idx] = weight_pos_tmp[entry_idx];
          weight_neg[tile_base + entry_idx] = weight_neg_tmp[entry_idx];
        end
      end
    end
  endtask

  task automatic load_expected_counts;
    string path;
    integer fd;
    int h_idx;
    int w_idx;
    int c_idx;
    int count_v;
    int entry_idx;
    begin
      for (entry_idx = 0; entry_idx < P_BANK_WORDS; entry_idx = entry_idx + 1)
        expected_counts[entry_idx] = -1;

      path = {golden_dir, "/synthetic_", case_name, "_output_counts.txt"};
      fd = $fopen(path, "r");
      if (fd == 0)
        fail_now($sformatf("cannot open expected counts file %s", path));

      while (!$feof(fd)) begin
        if ($fscanf(fd, "%d %d %d %d\n", h_idx, w_idx, c_idx, count_v) == 4) begin
          entry_idx = ((h_idx * cfg_out_W) + w_idx) * cfg_C_out + c_idx;
          if (entry_idx >= 0 && entry_idx < P_BANK_WORDS)
            expected_counts[entry_idx] = count_v;
        end
      end
      $fclose(fd);
    end
  endtask

  task automatic prefill_output_bank;
    int word_idx;
    begin
      for (word_idx = 0; word_idx < output_word_count; word_idx = word_idx + 1) begin
        bus_write(A_CONV_FMAP_WR_DATA, sentinel_word(word_idx));
        bus_write(A_CONV_FMAP_WR_ADDR, word_idx);
        bus_write(A_CONV_FMAP_WR_CTRL, 32'h0000_0005);
      end
      $display("[TB] prefilled %0d output words in bank B", output_word_count);
    end
  endtask

  task automatic load_input_fmap_to_bank_a;
    int word_idx;
    begin
      for (word_idx = 0; word_idx < input_word_count; word_idx = word_idx + 1) begin
        bus_write(A_CONV_FMAP_WR_DATA, input_words[word_idx]);
        bus_write(A_CONV_FMAP_WR_ADDR, word_idx);
        bus_write(A_CONV_FMAP_WR_CTRL, 32'h0000_0001);
      end
      $display("[TB] loaded %0d input words into bank A", input_word_count);
    end
  endtask

  // Fast TB-only weight loader: bypass the MMIO MAC_W_LOAD_* path (which would
  // need ~24K bus_writes per tile = millions of cycles per inference) and
  // directly poke the behavioral MAC weight memory via hierarchical reference.
  // The RTL semantics are preserved: the MAC stores w_pos / w_neg as 4-bit
  // unsigned per (lane, out_c). M3.B smoke TB exercises the slow MMIO path
  // and matches byte-byte; M3.C accepts this fast path because the weight
  // load path itself is not under test (it is verified by conv_stage_smoke).
  task automatic load_weight_tile_into_mac(input int tile_idx);
    int lane_idx;
    int out_c_idx;
    int tile_base;
    int entry_idx;
    begin
      tile_base = tile_idx * P_WEIGHT_TILE_WORDS;
      for (lane_idx = 0; lane_idx < V2B_NUM_INPUTS; lane_idx = lane_idx + 1) begin
        for (out_c_idx = 0; out_c_idx < cfg_C_out; out_c_idx = out_c_idx + 1) begin
          entry_idx = tile_base + (lane_idx * cfg_C_out) + out_c_idx;
          dut.u_mac.sim_w_pos_mem[lane_idx][out_c_idx] = weight_pos[entry_idx];
          dut.u_mac.sim_w_neg_mem[lane_idx][out_c_idx] = weight_neg[entry_idx];
        end
      end
      current_loaded_tile = tile_idx;
      $display("[TB] loaded MAC weights for tile %0d (fast path)", tile_idx);
    end
  endtask

  task automatic configure_conv_case;
    begin
      bus_write(A_STAGE_CFG1, cfg_threshold[31:0]);
      bus_write(A_STAGE_CFG2, V2B_ADC_MAX);
      bus_write(A_CONV_MODE_CFG, force_timeout ? 32'h0000_0009 : 32'h0000_0001);
      bus_write(A_CONV_CFG_HW, {cfg_W[15:0], cfg_H[15:0]});
      bus_write(A_CONV_CFG_C, {cfg_C_out[15:0], cfg_C_in[15:0]});
      bus_write(A_CONV_CFG_K_S_P, {20'h0, cfg_pad[3:0], cfg_stride[3:0], cfg_K[3:0]});
      bus_write(A_CONV_CFG_OUT_HW, {cfg_out_W[15:0], cfg_out_H[15:0]});
      bus_write(A_CONV_CFG_T, cfg_T[31:0]);
      bus_write(A_CONV_CFG_TILE, {cfg_last_tile_valid_count[15:0], cfg_tile_count[15:0]});
      bus_write(A_CONV_CFG_FMAP_BASE, 32'd0);
      bus_write(A_CONV_CFG_OUT_BASE, 32'd0);
    end
  endtask

  task automatic run_conv_until_done(output logic [31:0] status_out);
    logic [31:0] status_q;
    int guard;
    bit req_active;
    int tile_idx;
    int delay_cycles;
    begin
      guard = 0;
      req_active = 1'b0;
      status_q = 32'h0;

      bus_write(A_CONV_STATUS, 32'h0000_0002);
      bus_write(A_CONV_CTRL, 32'h0000_0001);

      while (!status_q[1] && guard < 100_000_000) begin
        bus_read(A_CONV_STATUS, status_q);
        if (status_q[2] && !req_active) begin
          req_active = 1'b1;
          tile_idx = status_q[31:24];
          if (tile_idx < 0 || tile_idx >= cfg_tile_count) begin
            $display("[FAIL] case=%s saw illegal tile_idx=%0d status=0x%08h",
                     case_name, tile_idx, status_q);
            errors = errors + 1;
          end else if (force_timeout != 0) begin
            // Intentionally leave FW silent; conv_ctrl timeout path should fire.
          end else if (expected_err_code != 0) begin
            $display("[FAIL] case=%s unexpectedly requested weights for illegal cfg", case_name);
            errors = errors + 1;
          end else begin
            if (weight_ready_delay_max > 0) begin
              delay_cycles = $urandom(random_seed) % (weight_ready_delay_max + 1);
              repeat (delay_cycles) @(posedge clk);
            end
            if (tile_idx != current_loaded_tile)
              load_weight_tile_into_mac(tile_idx);
            bus_write(A_CONV_CTRL, 32'h0000_0004);
          end
        end else if (!status_q[2]) begin
          req_active = 1'b0;
        end
        guard = guard + 1;
      end

      if (!status_q[1]) begin
        $display("[FAIL] case=%s timeout waiting CONV done", case_name);
        errors = errors + 1;
      end else begin
        $display("[TB] case=%s done status=0x%08h", case_name, status_q);
      end
      status_out = status_q;
    end
  endtask

  task automatic count_output_bank_changes(output int changed_words);
    int word_idx;
    logic [31:0] got_word;
    logic [31:0] exp_word;
    begin
      changed_words = 0;
      for (word_idx = 0; word_idx < output_word_count; word_idx = word_idx + 1) begin
        got_word = dut.u_fmap.bank_b[word_idx];
        exp_word = sentinel_word(word_idx);
        if (got_word !== exp_word) begin
          if (changed_words < 16)
            $display("[TB] bank_b[%0d] changed got=%08h exp=%08h",
                     word_idx, got_word, exp_word);
          changed_words = changed_words + 1;
        end
      end
    end
  endtask

  task automatic write_counts_stub_for_illegal_cfg(input string err_name);
    integer fd;
    begin
      fd = $fopen(rtl_counts_path, "wb");
      if (fd == 0)
        fail_now($sformatf("cannot open rtl counts path %s", rtl_counts_path));
      $fwrite(fd, "# illegal config: %s; no output fmap generated\n", err_name);
      $fclose(fd);
    end
  endtask

  task automatic dump_and_check_output_counts;
    integer fd;
    int h_idx;
    int w_idx;
    int c_idx;
    int sw_idx;
    int valid_bits;
    int entry_idx;
    int got_count;
    logic [31:0] word_v;
    begin
      fd = $fopen(rtl_counts_path, "wb");
      if (fd == 0)
        fail_now($sformatf("cannot open rtl counts path %s", rtl_counts_path));

      for (h_idx = 0; h_idx < cfg_out_H; h_idx = h_idx + 1) begin
        for (w_idx = 0; w_idx < cfg_out_W; w_idx = w_idx + 1) begin
          for (c_idx = 0; c_idx < cfg_C_out; c_idx = c_idx + 1) begin
            got_count = 0;
            for (sw_idx = 0; sw_idx < stream_words; sw_idx = sw_idx + 1) begin
              entry_idx = ((((h_idx * cfg_out_W) + w_idx) * cfg_C_out) + c_idx)
                        * stream_words + sw_idx;
              word_v = dut.u_fmap.bank_b[entry_idx];
              if ((sw_idx == stream_words - 1) && ((cfg_T % 32) != 0))
                valid_bits = cfg_T % 32;
              else
                valid_bits = 32;
              got_count = got_count + popcount_limited(word_v, valid_bits);
            end

            entry_idx = ((h_idx * cfg_out_W) + w_idx) * cfg_C_out + c_idx;
            $fwrite(fd, "%0d %0d %0d %0d\n", h_idx, w_idx, c_idx, got_count);
            if (expected_counts[entry_idx] !== got_count) begin
              if (errors < 32)
                $display("[FAIL] case=%s h=%0d w=%0d c=%0d got=%0d exp=%0d",
                         case_name, h_idx, w_idx, c_idx, got_count, expected_counts[entry_idx]);
              errors = errors + 1;
            end
          end
        end
      end
      $fclose(fd);
    end
  endtask

  task automatic check_common_final_status(input logic [31:0] status_q);
    int actual_err_code;
    begin
      actual_err_code = status_q[7:4];
      if (actual_err_code != expected_err_code) begin
        $display("[FAIL] case=%s err_code got=%0d exp=%0d",
                 case_name, actual_err_code, expected_err_code);
        errors = errors + 1;
      end
      if (status_q[1] !== 1'b1) begin
        $display("[FAIL] case=%s done_sticky was not set", case_name);
        errors = errors + 1;
      end
      if (status_q[0] !== 1'b0) begin
        $display("[FAIL] case=%s busy stayed high at completion", case_name);
        errors = errors + 1;
      end
    end
  endtask

  task automatic check_valid_case_metrics;
    begin
      if (weight_req_count != expected_stage_runs) begin
        $display("[FAIL] case=%s weight_req_count got=%0d exp=%0d",
                 case_name, weight_req_count, expected_stage_runs);
        errors = errors + 1;
      end
      if (stage_start_count != expected_stage_runs) begin
        $display("[FAIL] case=%s stage_start_count got=%0d exp=%0d",
                 case_name, stage_start_count, expected_stage_runs);
        errors = errors + 1;
      end
      if (fmap_write_count != output_word_count) begin
        $display("[FAIL] case=%s fmap_write_count got=%0d exp=%0d",
                 case_name, fmap_write_count, output_word_count);
        errors = errors + 1;
      end
    end
  endtask

  task automatic check_invalid_case_invariants;
    begin
      count_output_bank_changes(output_bank_changed_words);
      if (expected_err_code == 8) begin
        if (weight_req_count != 1) begin
          $display("[FAIL] case=%s weight_req_count=%0d for timeout cfg",
                   case_name, weight_req_count);
          errors = errors + 1;
        end
      end else begin
        if (weight_req_count != 0) begin
          $display("[FAIL] case=%s weight_req_count=%0d for illegal cfg",
                   case_name, weight_req_count);
          errors = errors + 1;
        end
      end
      if (stage_start_count != 0) begin
        $display("[FAIL] case=%s stage_start_count=%0d for illegal cfg",
                 case_name, stage_start_count);
        errors = errors + 1;
      end
      if (mac_start_count != 0) begin
        $display("[FAIL] case=%s mac_start_count=%0d for illegal cfg",
                 case_name, mac_start_count);
        errors = errors + 1;
      end
      if (mac_done_count != 0) begin
        $display("[FAIL] case=%s mac_done_count=%0d for illegal cfg",
                 case_name, mac_done_count);
        errors = errors + 1;
      end
      if (fmap_write_count != 0) begin
        $display("[FAIL] case=%s fmap_write_count=%0d for illegal cfg",
                 case_name, fmap_write_count);
        errors = errors + 1;
      end
      if (output_bank_changed_words != 0) begin
        $display("[FAIL] case=%s output_bank_changed_words=%0d for illegal cfg",
                 case_name, output_bank_changed_words);
        errors = errors + 1;
      end
    end
  endtask

  task automatic write_status_file(input logic [31:0] status_q);
    integer fd;
    int actual_err_code;
    begin
      actual_err_code = status_q[7:4];
      fd = $fopen(status_err_path, "wb");
      if (fd == 0)
        fail_now($sformatf("cannot open status path %s", status_err_path));
      $fwrite(fd, "CASE=%s\n", case_name);
      $fwrite(fd, "ERR_CODE=%0d\n", actual_err_code);
      $fwrite(fd, "ERR_NAME=%s\n", err_name_from_code(actual_err_code));
      $fwrite(fd, "WEIGHT_REQ_SEEN=%0d\n", weight_req_count);
      $fwrite(fd, "STAGE_START_COUNT=%0d\n", stage_start_count);
      $fwrite(fd, "MAC_START_COUNT=%0d\n", mac_start_count);
      $fwrite(fd, "MAC_DONE_COUNT=%0d\n", mac_done_count);
      $fwrite(fd, "FMAP_WRITE_COUNT=%0d\n", fmap_write_count);
      $fwrite(fd, "OUTPUT_BANK_CHANGED=%0d\n", output_bank_changed_words);
      $fwrite(fd, "DONE_STICKY=%0d\n", status_q[1]);
      $fwrite(fd, "BUSY_FINAL=%0d\n", status_q[0]);
      $fclose(fd);
    end
  endtask

  initial begin
    require_plusargs();
    $display("[TB] synthetic_conv_bitexact_tb case=%s", case_name);
    $display("[TB] cfg K=%0d stride=%0d pad=%0d Cin=%0d Cout=%0d H=%0d W=%0d outH=%0d outW=%0d T=%0d tile_count=%0d last_tile_valid=%0d err=%0d/%s",
             cfg_K, cfg_stride, cfg_pad, cfg_C_in, cfg_C_out,
             cfg_H, cfg_W, cfg_out_H, cfg_out_W, cfg_T,
             cfg_tile_count, cfg_last_tile_valid_count,
             expected_err_code, expected_err_name);

    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    prefill_output_bank();

    if (expected_err_code == 0) begin
      load_input_words();
      load_weight_tiles();
      load_expected_counts();
      load_input_fmap_to_bank_a();
    end

    configure_conv_case();
    run_conv_until_done(final_status);
    check_common_final_status(final_status);

    if (expected_err_code == 0) begin
      count_output_bank_changes(output_bank_changed_words);
      dump_and_check_output_counts();
      check_valid_case_metrics();
    end else begin
      write_counts_stub_for_illegal_cfg(err_name_from_code(final_status[7:4]));
      check_invalid_case_invariants();
    end

    write_status_file(final_status);

    if (errors == 0)
      $display("%s case=%s", `CONV_CASE_TB_PASS_TAG, case_name);
    else
      $display("%s case=%s errors=%0d", `CONV_CASE_TB_FAIL_TAG, case_name, errors);
    $finish;
  end

  initial begin
    #5_000_000_000;
    $display("%s timeout case=%s", `CONV_CASE_TB_FAIL_TAG, case_name);
    $finish;
  end
endmodule
