`timescale 1ns/1ps
module conv_stage_smoke_tb;
  import snn_soc_pkg::*;

  localparam int H = 8;
  localparam int W = 8;
  localparam int C_IN = 4;
  localparam int C_OUT = 8;
  localparam int T = 10;
  localparam int FMAP_IN_WORDS = H * W * C_IN;
  localparam int FMAP_OUT_WORDS = H * W * C_OUT;
  localparam int WEIGHT_ENTRIES = V2B_NUM_INPUTS * C_OUT;

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

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic cmd_valid = 0, cmd_ready, cmd_write = 0;
  logic [11:0] cmd_addr = '0;
  logic [31:0] cmd_wdata = '0;
  logic [3:0] cmd_wstrb = 0;
  logic rsp_valid;
  logic [31:0] rsp_rdata;

  snn_soc_v2b_top dut (
    .clk(clk), .rst_n(rst_n),
    .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
    .cmd_addr(cmd_addr), .cmd_write(cmd_write),
    .cmd_wdata(cmd_wdata), .cmd_wstrb(cmd_wstrb),
    .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata)
  );

  logic [31:0] input_words [0:FMAP_IN_WORDS-1];
  logic [3:0] weight_pos [0:WEIGHT_ENTRIES-1];
  logic [3:0] weight_neg [0:WEIGHT_ENTRIES-1];
  int expected_counts [0:FMAP_OUT_WORDS-1];
  int errors = 0;
  string golden_dir;
  string rtl_counts_path;

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

  task automatic load_input_fmap;
    begin
      for (int i = 0; i < FMAP_IN_WORDS; i++) begin
        bus_write(A_CONV_FMAP_WR_DATA, input_words[i]);
        bus_write(A_CONV_FMAP_WR_ADDR, i);
        bus_write(A_CONV_FMAP_WR_CTRL, 32'h0000_0001);
      end
      $display("[TB] loaded %0d input fmap words into bank A", FMAP_IN_WORDS);
    end
  endtask

  task automatic load_weight_tile;
    begin
      for (int lane = 0; lane < V2B_NUM_INPUTS; lane++) begin
        for (int oc = 0; oc < C_OUT; oc++) begin
          bus_write(A_MAC_W_LOAD_ADDR, (oc << 8) | lane);
          bus_write(A_MAC_W_LOAD_DATA,
                    {24'h0, weight_neg[lane*C_OUT + oc], weight_pos[lane*C_OUT + oc]});
          bus_write(A_MAC_W_LOAD_CTRL, 32'h1);
        end
      end
    end
  endtask

  task automatic service_one_weight_req;
    logic [31:0] status;
    int guard;
    begin
      guard = 0;
      status = 0;
      while (!status[2] && guard < 200000) begin
        bus_read(A_CONV_STATUS, status);
        guard++;
      end
      if (!status[2]) begin
        $display("[FAIL] timeout waiting WEIGHT_REQ");
        errors++;
      end else begin
        load_weight_tile();
        bus_write(A_CONV_CTRL, 32'h0000_0004);
      end
    end
  endtask

  task automatic configure_conv;
    begin
      bus_write(A_STAGE_CFG1, 32'd4);
      bus_write(A_STAGE_CFG2, V2B_ADC_MAX);
      bus_write(A_CONV_MODE_CFG, 32'h0000_0001); // conv mode, read A write B
      bus_write(A_CONV_CFG_HW, {16'd8, 16'd8});
      bus_write(A_CONV_CFG_C, {16'd8, 16'd4});
      bus_write(A_CONV_CFG_K_S_P, 32'h0000_0113);
      bus_write(A_CONV_CFG_OUT_HW, {16'd8, 16'd8});
      bus_write(A_CONV_CFG_T, 32'd10);
      bus_write(A_CONV_CFG_TILE, {16'd36, 16'd1});
      bus_write(A_CONV_CFG_FMAP_BASE, 32'd0);
      bus_write(A_CONV_CFG_OUT_BASE, 32'd0);
    end
  endtask

  task automatic load_expected_counts;
    int fd;
    int h, w, c, count;
    int idx;
    begin
      for (int i = 0; i < FMAP_OUT_WORDS; i++) expected_counts[i] = -1;
      fd = $fopen({golden_dir, "/synthetic_C1_output_counts.txt"}, "r");
      if (fd == 0) begin
        $display("[FATAL] cannot open synthetic_C1_output_counts.txt");
        $finish;
      end
      while (!$feof(fd)) begin
        if ($fscanf(fd, "%d %d %d %d\n", h, w, c, count) == 4) begin
          idx = ((h * W) + w) * C_OUT + c;
          expected_counts[idx] = count;
        end
      end
      $fclose(fd);
    end
  endtask

  function automatic int popcount_t(input logic [31:0] word);
    int count;
    begin
      count = 0;
      for (int t = 0; t < T; t++) if (word[t]) count++;
      popcount_t = count;
    end
  endfunction

  task automatic check_output_counts;
    int fd;
    int got;
    int idx;
    logic [31:0] word;
    begin
      fd = $fopen(rtl_counts_path, "wb");
      if (fd == 0) begin
        $display("[FATAL] cannot open rtl output counts");
        $finish;
      end
      for (int h = 0; h < H; h++) begin
        for (int w = 0; w < W; w++) begin
          for (int c = 0; c < C_OUT; c++) begin
            idx = ((h * W) + w) * C_OUT + c;
            word = dut.u_fmap.bank_b[idx];
            got = popcount_t(word);
            $fwrite(fd, "%0d %0d %0d %0d\n", h, w, c, got);
            if (got !== expected_counts[idx]) begin
              if (errors < 20) begin
                $display("[FAIL] count h=%0d w=%0d c=%0d got=%0d exp=%0d word=%08h",
                         h, w, c, got, expected_counts[idx], word);
              end
              errors++;
            end
          end
        end
      end
      $fclose(fd);
    end
  endtask

  initial begin
    if (!$value$plusargs("GOLDEN_DIR=%s", golden_dir))
      golden_dir = "../python_multilayer";
    if (!$value$plusargs("RTL_COUNTS=%s", rtl_counts_path))
      rtl_counts_path = "conv_stage_smoke_rtl_counts.txt";

    $readmemh({golden_dir, "/synthetic_C1_input_fmap_words.hex"}, input_words);
    $readmemh({golden_dir, "/synthetic_C1_weight_tile_0_pos.hex"}, weight_pos);
    $readmemh({golden_dir, "/synthetic_C1_weight_tile_0_neg.hex"}, weight_neg);
    load_expected_counts();

    rst_n = 0;
    repeat (8) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);

    load_input_fmap();
    configure_conv();
    bus_write(A_CONV_CTRL, 32'h0000_0001);

    for (int pixel = 0; pixel < H*W; pixel++) begin
      service_one_weight_req();
    end

    begin : wait_done
      logic [31:0] status;
      int guard;
      guard = 0;
      status = 0;
      while (!status[1] && guard < 500000) begin
        bus_read(A_CONV_STATUS, status);
        guard++;
      end
      if (!status[1]) begin
        $display("[FAIL] timeout waiting CONV DONE");
        errors++;
      end else begin
        $display("[TB] CONV done status=0x%08h", status);
      end
    end

    check_output_counts();
    if (errors == 0) $display("CONV_STAGE_SMOKE_TB_PASS");
    else             $display("CONV_STAGE_SMOKE_TB_FAIL errors=%0d", errors);
    $finish;
  end

  initial begin
    #200_000_000;
    $display("CONV_STAGE_SMOKE_TB_TIMEOUT");
    $finish;
  end
endmodule
