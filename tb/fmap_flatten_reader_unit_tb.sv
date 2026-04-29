`timescale 1ns/1ps
//======================================================================
// fmap_flatten_reader_unit_tb.sv
//
// Unit TB for fmap_flatten_reader_v2 using Python oracle vectors.
//======================================================================
module fmap_flatten_reader_unit_tb;

  import snn_soc_pkg::*;

  localparam int P_BANK_WORDS = (V2B_CONV_FMAP_BANK_KIB * 1024) / 4;
  localparam int MAX_CASE_WORDS = P_BANK_WORDS;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic bank_sel_pp = 0;
  logic fmap_rd_en;
  logic [31:0] fmap_rd_word_addr;
  logic [31:0] fmap_rd_data;
  logic sram_wr_en = 0;
  logic sram_wr_bank_sel = 0;
  logic [31:0] sram_wr_word_addr = 0;
  logic [31:0] sram_wr_data = 0;
  logic [3:0] sram_wr_strb = 0;
  logic sram_addr_oob;

  fmap_sram_v2 u_sram (
    .clk(clk), .rst_n(rst_n), .bank_sel_pp(bank_sel_pp),
    .rd_en(fmap_rd_en), .rd_word_addr(fmap_rd_word_addr), .rd_data(fmap_rd_data),
    .wr_en(sram_wr_en), .wr_bank_sel(sram_wr_bank_sel),
    .wr_word_addr(sram_wr_word_addr), .wr_data(sram_wr_data), .wr_strb(sram_wr_strb),
    .addr_oob(sram_addr_oob)
  );

  logic ctx_valid = 0;
  logic [15:0] flat_tile_idx = 0;
  logic [15:0] cfg_H = 0, cfg_W = 0, cfg_C = 0;
  logic [31:0] cfg_fmap_base_word = 0;
  logic [3:0] cfg_stream_words = 0;
  logic dyn_wl_req_valid = 0;
  logic dyn_wl_req_ready;
  logic [8:0] dyn_wl_req_timestep = 0;
  logic dyn_wl_resp_valid;
  logic dyn_wl_resp_ready = 0;
  logic [255:0] dyn_wl_resp_data;
  logic [8:0] dyn_wl_resp_valid_count;

  fmap_flatten_reader_v2 dut (
    .clk(clk), .rst_n(rst_n),
    .ctx_valid(ctx_valid), .flat_tile_idx(flat_tile_idx),
    .cfg_H(cfg_H), .cfg_W(cfg_W), .cfg_C(cfg_C),
    .cfg_fmap_base_word(cfg_fmap_base_word), .cfg_stream_words(cfg_stream_words),
    .dyn_wl_req_valid(dyn_wl_req_valid), .dyn_wl_req_ready(dyn_wl_req_ready),
    .dyn_wl_req_timestep(dyn_wl_req_timestep),
    .dyn_wl_resp_valid(dyn_wl_resp_valid), .dyn_wl_resp_ready(dyn_wl_resp_ready),
    .dyn_wl_resp_data(dyn_wl_resp_data),
    .dyn_wl_resp_valid_count(dyn_wl_resp_valid_count),
    .fmap_rd_en(fmap_rd_en), .fmap_rd_word_addr(fmap_rd_word_addr),
    .fmap_rd_data(fmap_rd_data)
  );

  logic [31:0] fmap_words [0:MAX_CASE_WORDS-1];
  logic [31:0] exp_words [0:7];
  logic [255:0] exp_data;
  string golden_dir;
  string case_path;
  int errors = 0;

  task automatic write_sram_word(input [31:0] addr, input [31:0] data);
    begin
      @(negedge clk);
      sram_wr_en = 1'b1;
      sram_wr_bank_sel = 1'b0;
      sram_wr_word_addr = addr;
      sram_wr_data = data;
      sram_wr_strb = 4'hf;
      @(posedge clk);
      @(negedge clk);
      sram_wr_en = 1'b0;
      sram_wr_word_addr = '0;
      sram_wr_data = '0;
      sram_wr_strb = '0;
    end
  endtask

  task automatic load_case_words(input int case_idx, input int word_count);
    begin
      $sformat(case_path, "%s/flat_case%0d_words.hex", golden_dir, case_idx);
      $readmemh(case_path, fmap_words, 0, word_count - 1);
      for (int i = 0; i < word_count; i++) begin
        write_sram_word(i[31:0], fmap_words[i]);
      end
    end
  endtask

  task automatic pulse_context(input int tile_idx, input int height, input int width,
                               input int channels, input int stream_words);
    begin
      @(negedge clk);
      flat_tile_idx = tile_idx[15:0];
      cfg_H = height[15:0];
      cfg_W = width[15:0];
      cfg_C = channels[15:0];
      cfg_fmap_base_word = 32'd0;
      cfg_stream_words = stream_words[3:0];
      ctx_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      ctx_valid = 1'b0;
    end
  endtask

  task automatic do_request(input int timestep, input int resp_delay);
    begin
      @(negedge clk);
      dyn_wl_req_timestep = timestep[8:0];
      dyn_wl_req_valid = 1'b1;
      wait (dyn_wl_req_ready);
      @(posedge clk);
      @(negedge clk);
      dyn_wl_req_valid = 1'b0;
      dyn_wl_req_timestep = '0;
      dyn_wl_resp_ready = 1'b0;
      wait (dyn_wl_resp_valid);
      repeat (resp_delay) @(posedge clk);
    end
  endtask

  task automatic finish_response;
    begin
      @(negedge clk);
      dyn_wl_resp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dyn_wl_resp_ready = 1'b0;
    end
  endtask

  initial begin
    int fd;
    int ntests;
    int case_idx, word_count, tile_idx, height, width, channels, t_count;
    int stream_words, timestep, exp_count;
    int dummy;

    $display("[TB] fmap_flatten_reader_unit_tb start");
    if (!$value$plusargs("GOLDEN_DIR=%s", golden_dir)) begin
      golden_dir = "../sim/.flatten_reader_default";
    end
    $display("[TB] golden_dir=%s", golden_dir);

    rst_n = 0;
    repeat (6) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    fd = $fopen({golden_dir, "/flat_expected.txt"}, "r");
    if (fd == 0) begin
      $display("[FATAL] cannot open flat_expected.txt");
      $finish;
    end
    dummy = $fscanf(fd, "%d\n", ntests);
    if (dummy != 1) begin
      $display("[FATAL] missing flatten test count");
      $finish;
    end

    for (int test_id = 0; test_id < ntests; test_id++) begin
      dummy = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %h %h %h %h %h %h %h %h\n",
                      case_idx, word_count, tile_idx, height, width, channels,
                      t_count, stream_words, timestep, exp_count,
                      exp_words[0], exp_words[1], exp_words[2], exp_words[3],
                      exp_words[4], exp_words[5], exp_words[6], exp_words[7]);
      if (dummy != 18) begin
        $display("[FATAL] malformed flat_expected line %0d fields=%0d", test_id, dummy);
        $finish;
      end
      exp_data = {exp_words[7], exp_words[6], exp_words[5], exp_words[4],
                  exp_words[3], exp_words[2], exp_words[1], exp_words[0]};

      $display("[TB] test%0d case=%0d tile=%0d H=%0d W=%0d C=%0d t=%0d count=%0d",
               test_id, case_idx, tile_idx, height, width, channels, timestep, exp_count);
      load_case_words(case_idx, word_count);
      pulse_context(tile_idx, height, width, channels, stream_words);
      do_request(timestep, (test_id % 2) + 1);

      if (dyn_wl_resp_valid_count !== exp_count[8:0]) begin
        $display("[FAIL] test%0d valid_count got=%0d exp=%0d",
                 test_id, dyn_wl_resp_valid_count, exp_count);
        errors++;
      end
      if (dyn_wl_resp_data !== exp_data) begin
        $display("[FAIL] test%0d resp_data mismatch got=%064x exp=%064x",
                 test_id, dyn_wl_resp_data, exp_data);
        errors++;
      end else begin
        $display("[PASS] test%0d resp_data=%064x", test_id, dyn_wl_resp_data);
      end
      finish_response();
    end
    $fclose(fd);

    if (errors == 0) $display("FMAP_FLATTEN_READER_UNIT_TB_PASS");
    else             $display("FMAP_FLATTEN_READER_UNIT_TB_FAIL errors=%0d", errors);
    $finish;
  end

  initial begin
    #200_000_000;
    $display("FMAP_FLATTEN_READER_UNIT_TB_TIMEOUT");
    $finish;
  end

endmodule
