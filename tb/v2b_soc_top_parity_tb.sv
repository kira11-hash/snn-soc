`timescale 1ns/1ps
//======================================================================
// tb/v2b_soc_top_parity_tb.sv
//
// 【Phase C-Milestone-1 前置 TB】
// Bus-driven 版本的 B5 multilayer sample parity：通过 `snn_soc_v2b_top`
// 的 CPU-facing ICB-like 简易总线配置寄存器 + 写 input_stream_sram +
// 写 MAC 权重 + 触发 START，全程用 bus write / read，不从模块端口直接
// 操控内部信号。
//
// 目标：证明 V2B 寄存器接口能复现 B5 的 10 Fashion 14×14 样本 bit-exact
// parity（Phase C firmware C wrappers 接下来只需写这些寄存器即可）。
//
// Golden 复用 python_multilayer/results_multilayer/fashion_multilayer_golden/
//======================================================================
module v2b_soc_top_parity_tb;

  import snn_soc_pkg::*;

  localparam int NUM_SAMPLES = 10;
  localparam int T = 64;
  localparam int S0_IN_DIM  = 196;
  localparam int S0_OUT_DIM = 64;
  localparam int S0_THR     = 16;
  localparam int S0_SUM_MAX = S0_IN_DIM * 15;
  localparam int S1_IN_DIM  = 64;
  localparam int S1_OUT_DIM = 10;
  localparam int S1_THR     = 8;
  localparam int S1_SUM_MAX = S1_IN_DIM * 15;

  localparam int P_N_IN  = V2B_NUM_INPUTS;
  localparam int P_N_OUT = V2B_MAX_OUT_NEURONS;
  localparam int T_AW    = $clog2(V2B_MAX_TIMESTEPS);

  // V2B reg map (mirrors snn_soc_v2b_top)
  localparam logic [11:0] A_STAGE_CTRL      = 12'h000;
  localparam logic [11:0] A_STAGE_STATUS    = 12'h004;
  localparam logic [11:0] A_STAGE_CFG0      = 12'h008;
  localparam logic [11:0] A_STAGE_CFG1      = 12'h00C;
  localparam logic [11:0] A_STAGE_CFG2      = 12'h010;
  localparam logic [11:0] A_STAGE_CFG3      = 12'h014;
  localparam logic [11:0] A_STAGE_CFG5      = 12'h01C;
  localparam logic [11:0] A_INPUT_SRAM_ADDR = 12'h020;
  localparam logic [11:0] A_INPUT_SRAM_W0   = 12'h024;
  localparam logic [11:0] A_INPUT_SRAM_W1   = 12'h028;
  localparam logic [11:0] A_INPUT_SRAM_W2   = 12'h02C;
  localparam logic [11:0] A_INPUT_SRAM_W3   = 12'h030;
  localparam logic [11:0] A_INPUT_SRAM_W4   = 12'h034;
  localparam logic [11:0] A_INPUT_SRAM_W5   = 12'h038;
  localparam logic [11:0] A_INPUT_SRAM_W6   = 12'h03C;
  localparam logic [11:0] A_INPUT_SRAM_W7   = 12'h040;
  localparam logic [11:0] A_INPUT_SRAM_CTRL = 12'h044;
  localparam logic [11:0] A_MAC_W_LOAD_ADDR = 12'h050;
  localparam logic [11:0] A_MAC_W_LOAD_DATA = 12'h054;
  localparam logic [11:0] A_MAC_W_LOAD_CTRL = 12'h058;
  localparam logic [11:0] A_STREAM_BUF_CTRL = 12'h060;
  localparam logic [11:0] A_READ_SBB_BASE   = 12'h800;

  // ── Clock / reset ────────────────────────────────────────────────
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  // ── Bus wires ────────────────────────────────────────────────────
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

  // ── Bus tasks ───────────────────────────────────────────────────
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

  // Bus read: 3-cycle wait to align with both (a) rsp_valid's 1-cycle NBA and
  // (b) stream_buffer's synchronous 1-cycle read latency. For RO regs the
  // middle cycle is redundant but harmless.
  task automatic bus_read(input [11:0] addr, output [31:0] data);
    begin
      @(posedge clk);
      cmd_valid <= 1'b1;
      cmd_write <= 1'b0;
      cmd_addr  <= addr;
      @(posedge clk);      // cmd sampled this posedge; SRAM read_en=1 here
      cmd_valid <= 1'b0;
      @(posedge clk);      // stream_buffer rd_data lands this posedge
      @(posedge clk);      // read_mux + rsp register now reflect sbx_rd_data
      data = rsp_rdata;
    end
  endtask

  // Wait until STAGE_STATUS.BUSY == 0
  task automatic wait_stage_done;
    int g;
    logic [31:0] sts;
    begin
      g = 0;
      sts = 32'h1;
      while (sts[0] && g < 200_000) begin
        bus_read(A_STAGE_STATUS, sts);
        g = g + 1;
      end
      if (sts[0]) $display("[FAIL] stage BUSY never clears after %0d polls", g);
    end
  endtask

  // ── Golden storage ──────────────────────────────────────────────
  logic [3:0] s0_w_pos_flat [0:S0_IN_DIM*S0_OUT_DIM-1];
  logic [3:0] s0_w_neg_flat [0:S0_IN_DIM*S0_OUT_DIM-1];
  logic [3:0] s1_w_pos_flat [0:S1_IN_DIM*S1_OUT_DIM-1];
  logic [3:0] s1_w_neg_flat [0:S1_IN_DIM*S1_OUT_DIM-1];
  logic [P_N_IN-1:0] sample_wl_stream [0:T-1];
  integer expected_counts [0:S1_OUT_DIM-1];

  int errors = 0;
  int mismatch;

  // ── Load tasks (via bus) ─────────────────────────────────────────
  task automatic load_stage0_weights_via_bus;
    begin
      $display("[TB] load stage 0 weights via bus (%0d cells)", S0_IN_DIM*S0_OUT_DIM);
      for (int i = 0; i < S0_IN_DIM; i++) begin
        for (int j = 0; j < S0_OUT_DIM; j++) begin
          bus_write(A_MAC_W_LOAD_ADDR, (j << 8) | i);
          bus_write(A_MAC_W_LOAD_DATA, {24'h0, s0_w_neg_flat[i*S0_OUT_DIM+j], s0_w_pos_flat[i*S0_OUT_DIM+j]});
          bus_write(A_MAC_W_LOAD_CTRL, 32'h1);
        end
      end
    end
  endtask

  task automatic load_stage1_weights_via_bus;
    begin
      $display("[TB] load stage 1 weights via bus (%0d cells)", S1_IN_DIM*S1_OUT_DIM);
      for (int i = 0; i < S1_IN_DIM; i++) begin
        for (int j = 0; j < S1_OUT_DIM; j++) begin
          bus_write(A_MAC_W_LOAD_ADDR, (j << 8) | i);
          bus_write(A_MAC_W_LOAD_DATA, {24'h0, s1_w_neg_flat[i*S1_OUT_DIM+j], s1_w_pos_flat[i*S1_OUT_DIM+j]});
          bus_write(A_MAC_W_LOAD_CTRL, 32'h1);
        end
      end
    end
  endtask

  // Load a WL stream row into input_stream_sram via bus (256-bit → 8×32-bit chunks)
  task automatic load_wl_row_via_bus(input int t, input [P_N_IN-1:0] wl);
    begin
      bus_write(A_INPUT_SRAM_ADDR, t);
      bus_write(A_INPUT_SRAM_W0, wl[ 31:  0]);
      bus_write(A_INPUT_SRAM_W1, wl[ 63: 32]);
      bus_write(A_INPUT_SRAM_W2, wl[ 95: 64]);
      bus_write(A_INPUT_SRAM_W3, wl[127: 96]);
      bus_write(A_INPUT_SRAM_W4, wl[159:128]);
      bus_write(A_INPUT_SRAM_W5, wl[191:160]);
      bus_write(A_INPUT_SRAM_W6, wl[223:192]);
      bus_write(A_INPUT_SRAM_W7, wl[255:224]);
      bus_write(A_INPUT_SRAM_CTRL, 32'h1);
    end
  endtask

  task automatic load_sample_wl_stream;
    begin
      for (int t = 0; t < T; t++) load_wl_row_via_bus(t, sample_wl_stream[t]);
    end
  endtask

  // Configure stage via bus and start
  task automatic run_stage_via_bus(
    input int in_dim, input int out_dim, input int threshold, input int sum_max,
    input logic [1:0] input_src, input logic [1:0] output_dst
  );
    logic [31:0] cfg3_val;
    begin
      bus_write(A_STAGE_CFG0, {out_dim[15:0], in_dim[15:0]});
      bus_write(A_STAGE_CFG1, threshold);
      bus_write(A_STAGE_CFG2, sum_max);
      cfg3_val = 32'h0;
      cfg3_val[1:0] = input_src;
      cfg3_val[9:8] = output_dst;
      cfg3_val[17]  = 1'b1;  // IS_TILE_FINAL (always single tile)
      bus_write(A_STAGE_CFG3, cfg3_val);
      bus_write(A_STAGE_CFG5, T);
      bus_write(A_STAGE_CTRL, 32'h1);  // START W1P
      wait_stage_done();
      bus_write(A_STAGE_CTRL, 32'h80);  // clear DONE W1C
    end
  endtask

  // Count stage 1 spikes by reading SBB rows
  int got_counts_m [0:S1_OUT_DIM-1];

  task automatic count_sbb_spikes;
    logic [31:0] row;
    begin
      for (int j = 0; j < S1_OUT_DIM; j++) got_counts_m[j] = 0;
      for (int t = 0; t < T; t++) begin
        bus_read(A_READ_SBB_BASE + (t << 2), row);
        for (int j = 0; j < S1_OUT_DIM; j++)
          if (row[j]) got_counts_m[j] = got_counts_m[j] + 1;
      end
    end
  endtask

  string golden_dir = "../python_multilayer/results_multilayer/fashion_multilayer_golden";

  task automatic load_sample_golden(input int k);
    string path;
    int fd;
    begin
      path = $sformatf("%s/sample_%02d_wl_stream.hex", golden_dir, k);
      $readmemh(path, sample_wl_stream);
      path = $sformatf("%s/sample_%02d_counts.txt", golden_dir, k);
      fd = $fopen(path, "r");
      if (fd == 0) begin
        $display("[FATAL] cannot open %s", path);
        $finish;
      end
      for (int j = 0; j < S1_OUT_DIM; j++) begin
        int dummy;
        dummy = $fscanf(fd, "%d\n", expected_counts[j]);
      end
      $fclose(fd);
    end
  endtask

  // Trace first ISR write events
  int isr_trace_cnt = 0;
  always @(posedge clk) begin
    if (rst_n && dut.u_isr.wr_en && isr_trace_cnt < 3) begin
      $display("[ISR-WR] addr=%0d popcount=%0d low64=%h",
        dut.u_isr.wr_addr, $countones(dut.u_isr.wr_data[195:0]),
        dut.u_isr.wr_data[63:0]);
      isr_trace_cnt++;
    end
  end
  // Trace sbA reads during stage 1 (first few)
  int sba_rd_trace = 0;
  always @(posedge clk) begin
    if (rst_n && dut.u_sbA.rd_en && sba_rd_trace < 5) begin
      $display("[SBA-RD] mux_addr=%0d en_se=%0b en_bus=%0b (mux en=%0b)",
        dut.u_sbA.rd_addr, dut.sbA_rd_en_se, dut.sbA_rd_en_bus, dut.u_sbA.rd_en);
      sba_rd_trace++;
    end
  end
  // Trace when stage_engine is in S_READ_WL with cfg_input_src=STREAM_A (stage 1)
  int sba_input_trace = 0;
  always @(posedge clk) begin
    if (rst_n && dut.u_se.state == 4'd3 &&
        dut.u_se.cfg_input_src == V2B_BUF_SEL_STREAM_A && sba_input_trace < 5) begin
      $display("[SE-S_READ_WL stage1] t_idx=%0d sbA_rd_en_se=%0b sbA_rd_addr_se=%0d",
        dut.u_se.t_idx, dut.sbA_rd_en_se, dut.sbA_rd_addr_se);
      sba_input_trace++;
    end
  end
  // Trace all SBA writes (addr seq) + start/done events
  int sba_wr_trace = 0;
  always @(posedge clk) begin
    if (rst_n && dut.u_sbA.wr_en && sba_wr_trace < 80) begin
      $display("[SBA-WR] t=%0t addr=%0d", $time, dut.u_sbA.wr_addr);
      sba_wr_trace++;
    end
  end
  always @(posedge clk) begin
    if (rst_n && dut.reg_start_pulse)
      $display("[START] t=%0t cfg_input_src=%0d cfg_out_dim=%0d", $time,
        dut.reg_cfg_input_src, dut.reg_cfg_out_dim);
    if (rst_n && dut.done_pulse)
      $display("[DONE] t=%0t cfg_input_src=%0d", $time, dut.reg_cfg_input_src);
  end
  // Trace first stage 0 + stage 1 MAC-DONE events
  int mac_s0_cnt = 0, mac_s1_cnt = 0;
  always @(posedge clk) begin
    if (rst_n && dut.u_mac.mac_done) begin
      if (dut.u_mac.in_dim_latched == 196 && mac_s0_cnt < 2) begin
        $display("[MAC-S0] wl_low64=%h diff[0..3]=%0d %0d %0d %0d",
          dut.u_mac.wl_latched_mac[63:0],
          $signed(dut.u_mac.diff_mem[0]), $signed(dut.u_mac.diff_mem[1]),
          $signed(dut.u_mac.diff_mem[2]), $signed(dut.u_mac.diff_mem[3]));
        mac_s0_cnt++;
      end
      if (dut.u_mac.in_dim_latched == 64 && mac_s1_cnt < 3) begin
        $display("[MAC-S1] wl_low64=%h diff[0..9]=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
          dut.u_mac.wl_latched_mac[63:0],
          $signed(dut.u_mac.diff_mem[0]), $signed(dut.u_mac.diff_mem[1]),
          $signed(dut.u_mac.diff_mem[2]), $signed(dut.u_mac.diff_mem[3]),
          $signed(dut.u_mac.diff_mem[4]), $signed(dut.u_mac.diff_mem[5]),
          $signed(dut.u_mac.diff_mem[6]), $signed(dut.u_mac.diff_mem[7]),
          $signed(dut.u_mac.diff_mem[8]), $signed(dut.u_mac.diff_mem[9]));
        mac_s1_cnt++;
      end
    end
  end

  initial begin
    $display("[TB] v2b_soc_top_parity_tb start (%0d samples, bus-driven)", NUM_SAMPLES);
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
      load_sample_golden(k);

      // Clear stream buffers before each sample (stage 0 will overwrite, but
      // ensures no stale data survives between samples)
      bus_write(A_STREAM_BUF_CTRL, 32'h6);  // CLEAR_A | CLEAR_B

      load_sample_wl_stream();

      // Stage 0 — load weights and run (INPUT_SRAM=0 -> STREAM_A=1)
      load_stage0_weights_via_bus();
      run_stage_via_bus(S0_IN_DIM, S0_OUT_DIM, S0_THR, S0_SUM_MAX,
                       V2B_BUF_SEL_INPUT_SRAM, V2B_BUF_SEL_STREAM_A);

      // Stage 1 — load weights and run (STREAM_A=1 -> STREAM_B=2)
      load_stage1_weights_via_bus();
      run_stage_via_bus(S1_IN_DIM, S1_OUT_DIM, S1_THR, S1_SUM_MAX,
                       V2B_BUF_SEL_STREAM_A, V2B_BUF_SEL_STREAM_B);

      // Compare
      count_sbb_spikes();
      mismatch = 0;
      for (int j = 0; j < S1_OUT_DIM; j++) begin
        if (got_counts_m[j] !== expected_counts[j]) begin
          $display("[FAIL] sample %0d class %0d: got=%0d exp=%0d", k, j, got_counts_m[j], expected_counts[j]);
          mismatch++;
        end
      end
      if (mismatch == 0) begin
        $display("[PASS] sample %0d counts = [%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d]",
                 k,
                 got_counts_m[0], got_counts_m[1], got_counts_m[2], got_counts_m[3],
                 got_counts_m[4], got_counts_m[5], got_counts_m[6], got_counts_m[7],
                 got_counts_m[8], got_counts_m[9]);
      end else begin
        errors += mismatch;
      end
    end

    if (errors == 0) $display("V2B_SOC_TOP_PARITY_TB_PASS");
    else             $display("V2B_SOC_TOP_PARITY_TB_FAIL (errors=%0d)", errors);
    $finish;
  end

  initial begin
    #(200_000_000);
    $display("V2B_SOC_TOP_PARITY_TB_TIMEOUT");
    $finish;
  end

endmodule
