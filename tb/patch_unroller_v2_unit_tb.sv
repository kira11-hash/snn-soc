`timescale 1ns/1ps
//======================================================================
// tb/patch_unroller_v2_unit_tb.sv
//
// patch_unroller_v2 unit smoke TB — 验证 dynamic WL ready/valid 协议
// 的核心 contract，不追求穷尽 K/stride/pad/corner case（那些由
// LeNet-5 cosim 端到端覆盖）。
//
// 覆盖的 invariant：
//   T1 ctx_valid=1 → 一段时间后 dyn_wl_req_ready=1（FSM 进入 S_WAIT_REQ）
//   T2 dyn_wl_req_valid + ready 握手后，dyn_wl_resp_valid 在合理时间内拉起
//   T3 dyn_wl_resp_valid_count 在合法范围 [1, 256]（K=1, C_in=1 → 1）
//   T4 不同 timestep 都能拿到 resp_valid（FSM 能多次重入 S_WAIT_REQ）
//   T5 ctx_valid=0 + 没 cfg → dyn_wl_req_ready 不会无故拉高
//
// fmap 路径：用一个简单 1-cycle latency 行为模型（不接 fmap_sram_v2），
// 任何读地址都返回 32'h0000_0001（保证 dyn_wl_resp 不带 X）。
// 测试 setup：K=1, stride=1, pad=0, C_in=1, H=W=4 → KKC=1，valid_count=1
//======================================================================
module patch_unroller_v2_unit_tb;

  import snn_soc_pkg::*;

  localparam int P_N_IN = V2B_NUM_INPUTS;
  localparam int P_BANK_WORDS = 1024;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // patch_unroller inputs
  logic        ctx_valid = 1'b0;
  logic [7:0]  ctx_h = '0;
  logic [7:0]  ctx_w = '0;
  logic [15:0] ctx_tile_idx = '0;
  logic [3:0]  cfg_K = 4'd1;
  logic [3:0]  cfg_stride = 4'd1;
  logic [3:0]  cfg_pad = 4'd0;
  logic [15:0] cfg_C_in = 16'd1;
  logic [15:0] cfg_H = 16'd4;
  logic [15:0] cfg_W = 16'd4;
  logic [31:0] cfg_fmap_base_word = 32'd0;
  logic [3:0]  cfg_stream_words = 4'd1;

  logic        dyn_wl_req_valid = 1'b0;
  logic        dyn_wl_req_ready;
  logic [8:0]  dyn_wl_req_timestep = '0;
  logic        dyn_wl_resp_valid;
  logic        dyn_wl_resp_ready = 1'b0;
  logic [255:0] dyn_wl_resp_data;
  logic [8:0]  dyn_wl_resp_valid_count;

  // fmap interface — 简单行为模型
  logic        fmap_rd_en;
  logic [31:0] fmap_rd_word_addr;
  logic [31:0] fmap_rd_data;

  // 1-cycle latency mock：rd_en pulse 后下一拍返回固定值 32'h0000_0001
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fmap_rd_data <= 32'h0;
    end else if (fmap_rd_en) begin
      // bit0=1 让 patch unroller 提取出 1（避免全 X）
      fmap_rd_data <= 32'h0000_0001;
    end
  end

  // ── DUT ─────────────────────────────────────────────────────────
  patch_unroller_v2 #(
    .P_N_IN      (P_N_IN),
    .P_BANK_WORDS(P_BANK_WORDS)
  ) u_patch (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .ctx_valid              (ctx_valid),
    .ctx_h                  (ctx_h),
    .ctx_w                  (ctx_w),
    .ctx_tile_idx           (ctx_tile_idx),
    .cfg_K                  (cfg_K),
    .cfg_stride             (cfg_stride),
    .cfg_pad                (cfg_pad),
    .cfg_C_in               (cfg_C_in),
    .cfg_H                  (cfg_H),
    .cfg_W                  (cfg_W),
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

  task automatic check_int(input string tag,
                           input integer got,
                           input integer exp);
    if (got === exp) begin
      $display("[PASS] %s got=%0d exp=%0d", tag, got, exp);
      pass_count = pass_count + 1;
    end else begin
      $display("[FAIL] %s got=%0d exp=%0d", tag, got, exp);
      fail_count = fail_count + 1;
    end
  endtask

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

  // ── 主流程 ─────────────────────────────────────────────────────
  initial begin
    bit ok;
    $display("[INFO] patch_unroller_v2_unit_tb start (K=1 stride=1 pad=0 C_in=1 H=W=4)");
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
    ctx_valid    <= 1'b1;
    ctx_h        <= 8'd0;
    ctx_w        <= 8'd0;
    ctx_tile_idx <= 16'd0;
    @(posedge clk);
    ctx_valid <= 1'b0;
    wait_for_req_ready(ok, 100);
    if (!ok) begin
      $display("[FAIL] T1 req_ready never high after ctx_valid");
      fail_count = fail_count + 1;
    end else begin
      $display("[PASS] T1 req_ready high after ctx_valid (FSM in S_WAIT_REQ)");
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
      if (dyn_wl_resp_valid_count !== 9'd1) begin
        $display("[FAIL] T3 valid_count for K=1,C_in=1 got=%0d exp=1",
                 dyn_wl_resp_valid_count);
        fail_count = fail_count + 1;
      end else begin
        $display("[PASS] T3 valid_count for K=1,C_in=1 got=1 exp=1");
        pass_count = pass_count + 1;
      end
    end
    @(posedge clk);
    dyn_wl_resp_ready <= 1'b0;

    // ── T4: 第二次 ctx + req(t=1) 也能完成握手 ──
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
      $display("PATCH_UNROLLER_V2_UNIT_TB_PASS");
    else
      $display("PATCH_UNROLLER_V2_UNIT_TB_FAIL");
    $finish;
  end

  initial begin
    #500000;
    $display("[ERROR] timeout");
    $display("PATCH_UNROLLER_V2_UNIT_TB_FAIL (timeout)");
    $finish;
  end

endmodule
