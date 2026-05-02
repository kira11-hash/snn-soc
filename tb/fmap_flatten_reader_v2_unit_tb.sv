`timescale 1ns/1ps
//======================================================================
// tb/fmap_flatten_reader_v2_unit_tb.sv
//
// fmap_flatten_reader_v2 unit smoke TB — 验证 dynamic WL ready/valid
// 协议在 CONV→FC flatten 模式下的核心 contract。
//
// 覆盖的 invariant：
//   T1 ctx_valid → req_ready
//   T2 req(t=0) → resp_valid
//   T3 valid_count 在合法范围（H=2,W=2,C=4 → flat_dim=16，单 tile valid=16）
//   T4 第二次 ctx + req(t=1) 也能完成握手
//   T5 ctx_valid=0 时 req_ready 不应拉起
//
// 测试 setup：H=2, W=2, C=4 → flat_dim=H*W*C=16
//======================================================================
module fmap_flatten_reader_v2_unit_tb;

  import snn_soc_pkg::*;

  localparam int P_N_IN = V2B_NUM_INPUTS;
  localparam int P_BANK_WORDS = 1024;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // flatten_reader inputs
  logic        ctx_valid = 1'b0;
  logic [15:0] flat_tile_idx = '0;
  logic [15:0] cfg_H = 16'd2;
  logic [15:0] cfg_W = 16'd2;
  logic [15:0] cfg_C = 16'd4;
  logic [31:0] cfg_fmap_base_word = 32'd0;
  logic [3:0]  cfg_stream_words = 4'd1;

  logic        dyn_wl_req_valid = 1'b0;
  logic        dyn_wl_req_ready;
  logic [8:0]  dyn_wl_req_timestep = '0;
  logic        dyn_wl_resp_valid;
  logic        dyn_wl_resp_ready = 1'b0;
  logic [255:0] dyn_wl_resp_data;
  logic [8:0]  dyn_wl_resp_valid_count;

  logic        fmap_rd_en;
  logic [31:0] fmap_rd_word_addr;
  logic [31:0] fmap_rd_data;

  // 1-cycle latency mock：固定返回 32'h0000_0001
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fmap_rd_data <= 32'h0;
    end else if (fmap_rd_en) begin
      fmap_rd_data <= 32'h0000_0001;
    end
  end

  fmap_flatten_reader_v2 #(
    .P_N_IN      (P_N_IN),
    .P_BANK_WORDS(P_BANK_WORDS)
  ) u_flat (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .ctx_valid              (ctx_valid),
    .flat_tile_idx          (flat_tile_idx),
    .cfg_H                  (cfg_H),
    .cfg_W                  (cfg_W),
    .cfg_C                  (cfg_C),
    .cfg_fmap_base_word     (cfg_fmap_base_word),
    .cfg_stream_words       (cfg_stream_words),
    .dyn_wl_req_valid       (dyn_wl_req_valid),
    .dyn_wl_req_ready       (dyn_wl_req_ready),
    .dyn_wl_req_timestep    (dyn_wl_req_timestep),
    .dyn_wl_resp_valid      (dyn_wl_resp_valid),
    .dyn_wl_resp_ready      (dyn_wl_resp_ready),
    .dyn_wl_resp_data       (dyn_wl_resp_data),
    .dyn_wl_resp_valid_count(dyn_wl_resp_valid_count),
    .fmap_rd_en             (fmap_rd_en),
    .fmap_rd_word_addr      (fmap_rd_word_addr),
    .fmap_rd_data           (fmap_rd_data)
  );

  integer pass_count = 0;
  integer fail_count = 0;

  task automatic wait_for_req_ready(output bit ok, input int max_cycles);
    int i;
    begin : body
      ok = 0;
      for (i = 0; i < max_cycles; i++) begin
        @(posedge clk);
        if (dyn_wl_req_ready) begin ok = 1; disable body; end
      end
    end
  endtask

  task automatic wait_for_resp_valid(output bit ok, input int max_cycles);
    int i;
    begin : body
      ok = 0;
      for (i = 0; i < max_cycles; i++) begin
        @(posedge clk);
        if (dyn_wl_resp_valid) begin ok = 1; disable body; end
      end
    end
  endtask

  initial begin
    bit ok;
    $display("[INFO] fmap_flatten_reader_v2_unit_tb start (H=2 W=2 C=4 flat_dim=16)");
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // ── T5: ctx_valid=0 时 req_ready 不应拉起 ──
    repeat (10) @(posedge clk);
    if (dyn_wl_req_ready === 1'b1) begin
      $display("[FAIL] T5 req_ready unexpectedly high while ctx_valid=0");
      fail_count = fail_count + 1;
    end else begin
      $display("[PASS] T5 req_ready stays low while ctx_valid=0");
      pass_count = pass_count + 1;
    end

    // ── T1: ctx_valid → req_ready ──
    @(posedge clk);
    ctx_valid     <= 1'b1;
    flat_tile_idx <= 16'd0;
    @(posedge clk);
    ctx_valid <= 1'b0;
    wait_for_req_ready(ok, 100);
    if (!ok) begin
      $display("[FAIL] T1 req_ready never high after ctx_valid");
      fail_count = fail_count + 1;
    end else begin
      $display("[PASS] T1 req_ready high after ctx_valid");
      pass_count = pass_count + 1;
    end

    // ── T2/T3: req(t=0) → resp + valid_count ──
    @(posedge clk);
    dyn_wl_req_valid    <= 1'b1;
    dyn_wl_req_timestep <= 9'd0;
    dyn_wl_resp_ready   <= 1'b1;
    @(posedge clk);
    dyn_wl_req_valid <= 1'b0;
    wait_for_resp_valid(ok, 1000);
    if (!ok) begin
      $display("[FAIL] T2 resp_valid never high after req(t=0)");
      fail_count = fail_count + 1;
    end else begin
      $display("[PASS] T2 resp_valid high after req(t=0)");
      pass_count = pass_count + 1;
      // flat_dim = H*W*C = 2*2*4 = 16，单 tile（< P_N_IN=256）→ valid_count=16
      if (dyn_wl_resp_valid_count !== 9'd16) begin
        $display("[FAIL] T3 valid_count for flat_dim=16 got=%0d exp=16",
                 dyn_wl_resp_valid_count);
        fail_count = fail_count + 1;
      end else begin
        $display("[PASS] T3 valid_count for flat_dim=16 got=16");
        pass_count = pass_count + 1;
      end
    end
    @(posedge clk);
    dyn_wl_resp_ready <= 1'b0;

    // ── T4: 第二次 ctx + req(t=1) ──
    repeat (5) @(posedge clk);
    @(posedge clk);
    ctx_valid <= 1'b1;
    @(posedge clk);
    ctx_valid <= 1'b0;
    wait_for_req_ready(ok, 100);
    if (!ok) begin
      $display("[FAIL] T4 req_ready never high after second ctx");
      fail_count = fail_count + 1;
    end else begin
      @(posedge clk);
      dyn_wl_req_valid    <= 1'b1;
      dyn_wl_req_timestep <= 9'd1;
      dyn_wl_resp_ready   <= 1'b1;
      @(posedge clk);
      dyn_wl_req_valid <= 1'b0;
      wait_for_resp_valid(ok, 1000);
      if (!ok) begin
        $display("[FAIL] T4 resp_valid never high after second ctx + req(t=1)");
        fail_count = fail_count + 1;
      end else begin
        $display("[PASS] T4 second-context req(t=1) handshake completes");
        pass_count = pass_count + 1;
      end
    end

    repeat (5) @(posedge clk);
    $display("");
    $display("=== Results: %0d PASS, %0d FAIL ===", pass_count, fail_count);
    if (fail_count == 0)
      $display("FMAP_FLATTEN_READER_V2_UNIT_TB_PASS");
    else
      $display("FMAP_FLATTEN_READER_V2_UNIT_TB_FAIL");
    $finish;
  end

  initial begin
    #500000;
    $display("[ERROR] timeout");
    $display("FMAP_FLATTEN_READER_V2_UNIT_TB_FAIL (timeout)");
    $finish;
  end

endmodule
