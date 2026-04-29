`timescale 1ns/1ps
module conv_to_fc_chain_tb;
  import snn_soc_pkg::*;

  localparam int H      = 8;
  localparam int W      = 8;
  localparam int C_IN   = 4;
  localparam int C_MID  = 8;
  localparam int C_OUT  = 10;
  localparam int K      = 3;
  localparam int STRIDE = 1;
  localparam int PAD    = 1;
  localparam int T      = 10;

  localparam int STREAM_WORDS          = (T + 31) >> 5;
  localparam int FMAP_IN_WORDS         = H * W * C_IN * STREAM_WORDS;
  localparam int FMAP_MID_WORDS        = H * W * C_MID * STREAM_WORDS;
  localparam int CONV_TILE_ENTRIES     = V2B_NUM_INPUTS * C_MID;
  localparam int FC_TILE_ENTRIES       = V2B_NUM_INPUTS * C_OUT;
  localparam int CONV_TILE_COUNT       = 1;
  localparam int CONV_LAST_TILE_VALID  = K * K * C_IN;
  localparam int FC_TILE_COUNT         = 2;
  localparam int FC_LAST_TILE_VALID    = 256;
  localparam int CONV_THRESHOLD        = 4;
  localparam int CONV_SUM_MAX          = V2B_ADC_MAX;
  localparam int FC_THRESHOLD          = 32;
  localparam int FC_SUM_MAX            = V2B_ADC_MAX;

  localparam logic [11:0] A_STAGE_CFG1         = 12'h00C;
  localparam logic [11:0] A_STAGE_CFG2         = 12'h010;
  localparam logic [11:0] A_MAC_W_LOAD_ADDR    = 12'h050;
  localparam logic [11:0] A_MAC_W_LOAD_DATA    = 12'h054;
  localparam logic [11:0] A_MAC_W_LOAD_CTRL    = 12'h058;
  localparam logic [11:0] A_STREAM_BUF_CTRL    = 12'h060;
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
  localparam logic [11:0] A_READ_SBA_BASE      = 12'h400;

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

  snn_soc_v2b_top dut (
    .clk(clk), .rst_n(rst_n),
    .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
    .cmd_addr(cmd_addr), .cmd_write(cmd_write),
    .cmd_wdata(cmd_wdata), .cmd_wstrb(cmd_wstrb),
    .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata)
  );

  logic [31:0] input_words [0:FMAP_IN_WORDS-1];
  logic [31:0] exp_conv_words [0:FMAP_MID_WORDS-1];
  logic [3:0] conv_w_pos [0:CONV_TILE_ENTRIES-1];
  logic [3:0] conv_w_neg [0:CONV_TILE_ENTRIES-1];
  logic [3:0] fc0_w_pos  [0:FC_TILE_ENTRIES-1];
  logic [3:0] fc0_w_neg  [0:FC_TILE_ENTRIES-1];
  logic [3:0] fc1_w_pos  [0:FC_TILE_ENTRIES-1];
  logic [3:0] fc1_w_neg  [0:FC_TILE_ENTRIES-1];
  logic [31:0] exp_stream_words [0:T-1];

  int errors = 0;
  string golden_dir;
  string rtl_stream_path;

  task automatic bus_write(input logic [11:0] addr, input logic [31:0] data);
    begin
      @(posedge clk);
      cmd_valid <= 1'b1;
      cmd_write <= 1'b1;
      cmd_addr  <= addr;
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
      cmd_addr  <= addr;
      cmd_wdata <= 32'h0;
      cmd_wstrb <= 4'h0;
      @(posedge clk);
      cmd_valid <= 1'b0;
      @(posedge clk);
      @(posedge clk);
      data = rsp_rdata;
    end
  endtask

  task automatic clear_buffers(input logic clear_a, input logic clear_b);
    logic [31:0] word_v;
    begin
      word_v = 32'h0;
      if (clear_a) word_v[1] = 1'b1;
      if (clear_b) word_v[2] = 1'b1;
      word_v[3] = 1'b1;
      bus_write(A_STREAM_BUF_CTRL, word_v);
    end
  endtask

  task automatic load_input_fmap_bank_a;
    begin
      bus_write(A_CONV_FMAP_WR_CTRL, 32'h0);
      for (int i = 0; i < FMAP_IN_WORDS; i++) begin
        bus_write(A_CONV_FMAP_WR_DATA, input_words[i]);
        bus_write(A_CONV_FMAP_WR_ADDR, i);
        bus_write(A_CONV_FMAP_WR_CTRL, 32'h1);
      end
      $display("[TB] loaded %0d input fmap words into bank A", FMAP_IN_WORDS);
    end
  endtask

  task automatic load_conv_weight_tile;
    begin
      for (int lane = 0; lane < V2B_NUM_INPUTS; lane++) begin
        for (int oc = 0; oc < C_MID; oc++) begin
          bus_write(A_MAC_W_LOAD_ADDR, (oc << 8) | lane);
          bus_write(A_MAC_W_LOAD_DATA,
                    {24'h0, conv_w_neg[lane*C_MID + oc], conv_w_pos[lane*C_MID + oc]});
          bus_write(A_MAC_W_LOAD_CTRL, 32'h1);
        end
      end
    end
  endtask

  task automatic load_fc_weight_tile(input int tile_idx);
    begin
      for (int lane = 0; lane < V2B_NUM_INPUTS; lane++) begin
        for (int oc = 0; oc < C_OUT; oc++) begin
          bus_write(A_MAC_W_LOAD_ADDR, (oc << 8) | lane);
          case (tile_idx)
            0: bus_write(A_MAC_W_LOAD_DATA,
                         {24'h0, fc0_w_neg[lane*C_OUT + oc], fc0_w_pos[lane*C_OUT + oc]});
            1: bus_write(A_MAC_W_LOAD_DATA,
                         {24'h0, fc1_w_neg[lane*C_OUT + oc], fc1_w_pos[lane*C_OUT + oc]});
            default: bus_write(A_MAC_W_LOAD_DATA, 32'h0);
          endcase
          bus_write(A_MAC_W_LOAD_CTRL, 32'h1);
        end
      end
    end
  endtask

  task automatic configure_conv_phase1;
    begin
      bus_write(A_STAGE_CFG1, CONV_THRESHOLD);
      bus_write(A_STAGE_CFG2, CONV_SUM_MAX);
      bus_write(A_CONV_MODE_CFG, 32'h0000_0001);
      bus_write(A_CONV_CFG_HW, {16'd8, 16'd8});
      bus_write(A_CONV_CFG_C, {16'(C_MID), 16'(C_IN)});
      bus_write(A_CONV_CFG_K_S_P, (PAD << 8) | (STRIDE << 4) | K);
      bus_write(A_CONV_CFG_OUT_HW, {16'd8, 16'd8});
      bus_write(A_CONV_CFG_T, T);
      bus_write(A_CONV_CFG_TILE, {16'(CONV_LAST_TILE_VALID), 16'(CONV_TILE_COUNT)});
      bus_write(A_CONV_CFG_FMAP_BASE, 32'd0);
      bus_write(A_CONV_CFG_OUT_BASE, 32'd0);
      bus_write(A_CONV_STATUS, 32'h0000_0002);
    end
  endtask

  task automatic configure_flatten_phase2;
    begin
      bus_write(A_STAGE_CFG1, FC_THRESHOLD);
      bus_write(A_STAGE_CFG2, FC_SUM_MAX);
      bus_write(A_CONV_MODE_CFG, 32'h0000_0007);
      bus_write(A_CONV_CFG_HW, {16'd8, 16'd8});
      bus_write(A_CONV_CFG_C, {16'(C_OUT), 16'(C_MID)});
      bus_write(A_CONV_CFG_K_S_P, 32'h0);
      bus_write(A_CONV_CFG_OUT_HW, {16'd1, 16'd1});
      bus_write(A_CONV_CFG_T, T);
      bus_write(A_CONV_CFG_TILE, {16'(FC_LAST_TILE_VALID), 16'(FC_TILE_COUNT)});
      bus_write(A_CONV_CFG_FMAP_BASE, 32'd0);
      bus_write(A_CONV_CFG_OUT_BASE, 32'd0);
      bus_write(A_CONV_STATUS, 32'h0000_0002);
    end
  endtask

  task automatic wait_for_weight_req(output logic [31:0] status, input int guard_limit);
    int guard;
    begin
      guard = 0;
      status = 32'h0;
      while (!status[2] && !status[1] && guard < guard_limit) begin
        bus_read(A_CONV_STATUS, status);
        guard++;
      end
      if (guard >= guard_limit) begin
        $display("[FAIL] timeout waiting weight_req status=0x%08h", status);
        errors++;
      end
    end
  endtask

  task automatic service_conv_weight_req;
    logic [31:0] status;
    begin
      wait_for_weight_req(status, 200000);
      if (!status[2]) begin
        $display("[FAIL] conv phase reached status=0x%08h before weight load", status);
        errors++;
      end else begin
        load_conv_weight_tile();
        bus_write(A_CONV_CTRL, 32'h0000_0004);
      end
    end
  endtask

  task automatic service_fc_weight_req(input int exp_tile_idx);
    logic [31:0] status;
    int got_tile_idx;
    begin
      wait_for_weight_req(status, 200000);
      if (!status[2]) begin
        $display("[FAIL] fc phase reached status=0x%08h before weight load", status);
        errors++;
      end else begin
        got_tile_idx = status[31:24];
        if (got_tile_idx !== exp_tile_idx) begin
          $display("[FAIL] fc phase tile index mismatch got=%0d exp=%0d status=0x%08h",
                   got_tile_idx, exp_tile_idx, status);
          errors++;
        end
        load_fc_weight_tile(exp_tile_idx);
        bus_write(A_CONV_CTRL, 32'h0000_0004);
      end
    end
  endtask

  task automatic wait_for_done(input string tag);
    logic [31:0] status;
    int guard;
    begin
      guard = 0;
      status = 32'h0;
      while (!status[1] && guard < 500000) begin
        bus_read(A_CONV_STATUS, status);
        guard++;
      end
      if (!status[1]) begin
        $display("[FAIL] %s timeout waiting done status=0x%08h", tag, status);
        errors++;
      end else if (status[7:4] != 4'h0) begin
        $display("[FAIL] %s done with err_code=%0h status=0x%08h", tag, status[7:4], status);
        errors++;
      end else begin
        $display("[TB] %s done status=0x%08h", tag, status);
      end
    end
  endtask

  task automatic check_conv_output_bank_b;
    logic [31:0] got_word;
    begin
      for (int idx = 0; idx < FMAP_MID_WORDS; idx++) begin
        got_word = dut.u_fmap.bank_b[idx];
        if (got_word !== exp_conv_words[idx]) begin
          if (errors < 20) begin
            $display("[FAIL] conv bank_b word[%0d] got=0x%08h exp=0x%08h",
                     idx, got_word, exp_conv_words[idx]);
          end
          errors++;
        end
      end
    end
  endtask

  task automatic dump_and_check_final_stream;
    int fd;
    logic [31:0] row;
    begin
      fd = $fopen(rtl_stream_path, "wb");
      if (fd == 0) begin
        $display("[FATAL] cannot open rtl stream dump path=%s", rtl_stream_path);
        $finish;
      end
      for (int t = 0; t < T; t++) begin
        row = dut.u_sbA.mem[t][31:0];
        $fwrite(fd, "%08x\n", row);
        if (row !== exp_stream_words[t]) begin
          if (errors < 20) begin
            $display("[FAIL] stream row t=%0d got=0x%08h exp=0x%08h", t, row, exp_stream_words[t]);
          end
          errors++;
        end
      end
      $fclose(fd);
    end
  endtask

  initial begin
    if (!$value$plusargs("GOLDEN_DIR=%s", golden_dir))
      golden_dir = "../sim/.conv_to_fc_chain_default";
    if (!$value$plusargs("RTL_STREAM=%s", rtl_stream_path))
      rtl_stream_path = "conv_to_fc_chain_rtl_stream.hex";

    $readmemh({golden_dir, "/chain_input_fmap_words.hex"}, input_words);
    $readmemh({golden_dir, "/chain_conv_output_words.hex"}, exp_conv_words);
    $readmemh({golden_dir, "/synthetic_CHAIN_CONV_weight_tile_0_pos.hex"}, conv_w_pos);
    $readmemh({golden_dir, "/synthetic_CHAIN_CONV_weight_tile_0_neg.hex"}, conv_w_neg);
    $readmemh({golden_dir, "/synthetic_CHAIN_FC_weight_tile_0_pos.hex"}, fc0_w_pos);
    $readmemh({golden_dir, "/synthetic_CHAIN_FC_weight_tile_0_neg.hex"}, fc0_w_neg);
    $readmemh({golden_dir, "/synthetic_CHAIN_FC_weight_tile_1_pos.hex"}, fc1_w_pos);
    $readmemh({golden_dir, "/synthetic_CHAIN_FC_weight_tile_1_neg.hex"}, fc1_w_neg);
    $readmemh({golden_dir, "/chain_final_stream_words.hex"}, exp_stream_words);

    rst_n = 0;
    repeat (8) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);

    clear_buffers(1'b1, 1'b1);
    load_input_fmap_bank_a();

    configure_conv_phase1();
    bus_write(A_CONV_CTRL, 32'h0000_0001);
    for (int pixel = 0; pixel < H*W; pixel++) begin
      service_conv_weight_req();
    end
    wait_for_done("conv_phase1");
    check_conv_output_bank_b();

    clear_buffers(1'b1, 1'b0);
    configure_flatten_phase2();
    bus_write(A_CONV_CTRL, 32'h0000_0001);
    for (int tile = 0; tile < FC_TILE_COUNT; tile++) begin
      service_fc_weight_req(tile);
    end
    wait_for_done("flatten_fc_phase2");

    dump_and_check_final_stream();

    if (errors == 0) $display("CONV_TO_FC_CHAIN_TB_PASS");
    else             $display("CONV_TO_FC_CHAIN_TB_FAIL errors=%0d", errors);
    $finish;
  end

  initial begin
    #300_000_000;
    $display("CONV_TO_FC_CHAIN_TB_TIMEOUT");
    $finish;
  end
endmodule
