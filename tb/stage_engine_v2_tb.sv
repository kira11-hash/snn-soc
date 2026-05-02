`timescale 1ns/1ps
//======================================================================
// tb/stage_engine_v2_tb.sv
//
// 集成 smoke TB：stage_engine_v2 + input_stream_sram + stream_buffer_v2
// + tile_partial_buf，使用行为 MAC（popcount × stub_weight）验证 FSM
// end-to-end 数据流。
//
// 真实 CIM 集成（B2）会替换 stub 为 cim_array_ctrl + adc_ctrl，届时
// TB 需要用 Python golden 对齐（B5 multilayer_sample_parity_tb）。本
// TB 的角色是先把 FSM + 存储 + handshake 串起来跑通。
//
// Scenario (tile_mode=0, single tile, write to stream_buf_A):
//   in_dim = 4, out_dim = 2, T = 4, threshold = 5, stub_weight = 1
//   All timesteps have wl_mask = 4'b1101 (popcount = 3)
//   diff per neuron per timestep = 3
//   Expected spike per neuron per timestep: [0, 1, 0, 1]
//   (membrane trace: 3, 6→fire→1, 4, 7→fire→2)
//======================================================================
module stage_engine_v2_tb;

  import snn_soc_pkg::*;

  localparam int T_MAX = V2B_MAX_TIMESTEPS;
  localparam int N_IN  = V2B_NUM_INPUTS;
  localparam int N_OUT = V2B_MAX_OUT_NEURONS;
  localparam int PW    = V2B_PARTIAL_WIDTH;
  localparam int T_AW  = $clog2(T_MAX);
  localparam int IN_AW = $clog2(T_MAX);
  localparam int J_AW  = $clog2(N_OUT);

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // Stage engine control
  logic start_pulse = 0;
  logic busy, done_pulse;
  logic [7:0] err_code;
  logic [T_AW-1:0] dbg_t;
  logic [15:0] cfg_in_dim, cfg_out_dim;
  logic [31:0] cfg_threshold, cfg_sum_max;
  logic [V2B_BUF_SEL_W-1:0] cfg_input_src;
  logic [1:0]               cfg_output_dst;
  logic        cfg_tile_mode, cfg_is_tile_final, cfg_preserve_membrane;
  logic [15:0] cfg_t_count;

  // input_stream_sram
  logic isr_rd_en;
  logic [T_AW-1:0] isr_rd_addr;
  logic [N_IN-1:0] isr_rd_data;
  logic isr_wr_en;
  logic [T_AW-1:0] isr_wr_addr;
  logic [N_IN-1:0] isr_wr_data;
  logic isr_clear = 0;

  // stream_buffer_v2 A
  logic sbA_wr_en;
  logic [T_AW-1:0] sbA_wr_addr;
  logic [N_OUT-1:0] sbA_wr_data;
  logic sbA_rd_en_se, sbA_rd_en_tb;
  logic [T_AW-1:0] sbA_rd_addr_se, sbA_rd_addr_tb;
  logic [N_OUT-1:0] sbA_rd_data;
  logic sbA_rd_en;
  logic [T_AW-1:0] sbA_rd_addr;
  assign sbA_rd_en   = sbA_rd_en_se | sbA_rd_en_tb;
  assign sbA_rd_addr = sbA_rd_en_tb ? sbA_rd_addr_tb : sbA_rd_addr_se;

  // stream_buffer_v2 B (unused in this TB)
  logic sbB_wr_en;
  logic [T_AW-1:0] sbB_wr_addr;
  logic [N_OUT-1:0] sbB_wr_data;
  logic sbB_rd_en;
  logic [T_AW-1:0] sbB_rd_addr;
  logic [N_OUT-1:0] sbB_rd_data;

  // tile_partial_buf (unused for tile_mode=0)
  logic tpb_clear, tpb_acc_en;
  logic [T_AW-1:0] tpb_wr_t;
  logic [J_AW-1:0] tpb_wr_j;
  logic signed [PW-1:0] tpb_wr_diff;
  logic tpb_rd_en;
  logic [T_AW-1:0] tpb_rd_t;
  logic [J_AW-1:0] tpb_rd_j;
  logic signed [PW-1:0] tpb_rd_data;

  // ── cim_mac_behavioral_v2 external MAC ─────────────────────────────
  logic                       mac_w_load_en = 0;
  logic [$clog2(N_IN)-1:0]    mac_w_load_i = '0;
  logic [J_AW-1:0]            mac_w_load_j = '0;
  logic [3:0]                 mac_w_load_pos = '0;
  logic [3:0]                 mac_w_load_neg = '0;
  logic                       mac_start, mac_done, mac_busy;
  logic [N_IN-1:0]            mac_wl_mask;
  logic [15:0]                mac_cfg_in_dim, mac_cfg_out_dim;
  logic [31:0]                mac_cfg_sum_max;
  logic [J_AW-1:0]            mac_diff_rd_j;
  logic signed [PW-1:0]       mac_diff_rd_data;

  cim_mac_behavioral_v2 #(.P_ADC_BITS(10)) u_mac (
    .clk(clk), .rst_n(rst_n),
    .w_load_en(mac_w_load_en), .w_load_i(mac_w_load_i), .w_load_j(mac_w_load_j),
    .w_load_pos_data(mac_w_load_pos), .w_load_neg_data(mac_w_load_neg),
    .mac_start(mac_start), .wl_mask(mac_wl_mask),
    .cfg_in_dim(mac_cfg_in_dim), .cfg_out_dim(mac_cfg_out_dim),
    .cfg_sum_max(mac_cfg_sum_max),
    .mac_busy(mac_busy), .mac_done(mac_done),
    .diff_rd_j(mac_diff_rd_j), .diff_rd_data(mac_diff_rd_data)
  );

  // ── DUTs ───────────────────────────────────────────────────────────
  input_stream_sram u_isr (
    .clk(clk), .rst_n(rst_n),
    .wr_en(isr_wr_en), .wr_addr(isr_wr_addr), .wr_data(isr_wr_data),
    .rd_en(isr_rd_en), .rd_addr(isr_rd_addr), .rd_data(isr_rd_data),
    .clear_all(isr_clear)
  );

  stream_buffer_v2 u_sbA (
    .clk(clk), .rst_n(rst_n),
    .wr_en(sbA_wr_en), .wr_addr(sbA_wr_addr), .wr_data(sbA_wr_data),
    .rd_en(sbA_rd_en), .rd_addr(sbA_rd_addr), .rd_data(sbA_rd_data),
    .clear_all(1'b0)
  );

  stream_buffer_v2 u_sbB (
    .clk(clk), .rst_n(rst_n),
    .wr_en(sbB_wr_en), .wr_addr(sbB_wr_addr), .wr_data(sbB_wr_data),
    .rd_en(sbB_rd_en), .rd_addr(sbB_rd_addr), .rd_data(sbB_rd_data),
    .clear_all(1'b0)
  );

  tile_partial_buf u_tpb (
    .clk(clk), .rst_n(rst_n), .clear_all(tpb_clear),
    .acc_en(tpb_acc_en), .wr_t(tpb_wr_t), .wr_j(tpb_wr_j), .wr_diff(tpb_wr_diff),
    .rd_en(tpb_rd_en), .rd_t(tpb_rd_t), .rd_j(tpb_rd_j), .rd_data(tpb_rd_data)
  );

  stage_engine_v2 u_se (
    .clk(clk), .rst_n(rst_n),
    .start_pulse(start_pulse), .busy(busy), .done_pulse(done_pulse),
    .err_code(err_code), .debug_t_idx(dbg_t),
    .cfg_in_dim(cfg_in_dim), .cfg_out_dim(cfg_out_dim),
    .cfg_threshold(cfg_threshold), .cfg_sum_max(cfg_sum_max),
    .cfg_input_src(cfg_input_src), .cfg_output_dst(cfg_output_dst),
    .cfg_tile_mode(cfg_tile_mode), .cfg_is_tile_final(cfg_is_tile_final),
    .cfg_preserve_membrane(cfg_preserve_membrane), .cfg_t_count(cfg_t_count),
    .isr_rd_en(isr_rd_en), .isr_rd_addr(isr_rd_addr), .isr_rd_data(isr_rd_data),
    .sbA_wr_en(sbA_wr_en), .sbA_wr_addr(sbA_wr_addr), .sbA_wr_data(sbA_wr_data),
    .sbB_wr_en(sbB_wr_en), .sbB_wr_addr(sbB_wr_addr), .sbB_wr_data(sbB_wr_data),
    .sbA_rd_en(sbA_rd_en_se), .sbA_rd_addr(sbA_rd_addr_se), .sbA_rd_data(sbA_rd_data),
    .sbB_rd_en(sbB_rd_en), .sbB_rd_addr(sbB_rd_addr), .sbB_rd_data(sbB_rd_data),
    .tpb_clear_all(tpb_clear), .tpb_acc_en(tpb_acc_en),
    .tpb_wr_t(tpb_wr_t), .tpb_wr_j(tpb_wr_j), .tpb_wr_diff(tpb_wr_diff),
    .tpb_rd_en(tpb_rd_en), .tpb_rd_t(tpb_rd_t), .tpb_rd_j(tpb_rd_j),
    .tpb_rd_data(tpb_rd_data),
    .mac_start(mac_start), .mac_done(mac_done), .mac_busy(mac_busy),
    .mac_wl_mask(mac_wl_mask), .mac_cfg_in_dim(mac_cfg_in_dim),
    .mac_cfg_out_dim(mac_cfg_out_dim), .mac_cfg_sum_max(mac_cfg_sum_max),
    .mac_diff_rd_j(mac_diff_rd_j), .mac_diff_rd_data(mac_diff_rd_data)
  );

  // ── Debug monitor ─────────────────────────────────────────────────
  always @(posedge clk) if (sbA_wr_en)
    $display("  [monitor] sbA WRITE addr=%0d data=%b", sbA_wr_addr, sbA_wr_data[3:0]);

  // ── Test harness ──────────────────────────────────────────────────
  int errors = 0;

  task automatic load_isr(input [T_AW-1:0] a, input [N_IN-1:0] d);
    @(posedge clk);
    isr_wr_en <= 1; isr_wr_addr <= a; isr_wr_data <= d;
    @(posedge clk);
    isr_wr_en <= 0;
  endtask

  task automatic read_sbA(input [T_AW-1:0] a, output [N_OUT-1:0] d);
    @(posedge clk);
    sbA_rd_en_tb   <= 1;
    sbA_rd_addr_tb <= a;
    @(posedge clk);
    sbA_rd_en_tb <= 0;
    @(posedge clk);
    d = sbA_rd_data;
  endtask

  logic [N_OUT-1:0] got;

  initial begin
    $display("[TB] stage_engine_v2_tb start");

    cfg_in_dim = 0; cfg_out_dim = 0;
    cfg_threshold = 0; cfg_sum_max = 0;
    cfg_input_src = V2B_BUF_SEL_INPUT_SRAM;
    cfg_output_dst = V2B_BUF_SEL_STREAM_A;
    cfg_tile_mode = 0; cfg_is_tile_final = 0; cfg_preserve_membrane = 0;
    cfg_t_count = 0;
    isr_wr_en = 0; sbA_rd_en_tb = 0; sbA_rd_addr_tb = 0;

    rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // Load MAC weights: w_pos[i][j]=1 for all (i,j), w_neg=0.
    // With wl_mask popcount=3 and sum_max=60, adc_pos = (3*1023 + 30)/60 = 51.
    // diff = 51 - 0 = 51 per neuron per timestep. Threshold 40 guarantees fire.
    for (int i = 0; i < 4; i++) begin
      for (int j = 0; j < 2; j++) begin
        @(posedge clk);
        mac_w_load_en  <= 1'b1;
        mac_w_load_i   <= i[$clog2(N_IN)-1:0];
        mac_w_load_j   <= j[J_AW-1:0];
        mac_w_load_pos <= 4'd1;
        mac_w_load_neg <= 4'd0;
      end
    end
    @(posedge clk);
    mac_w_load_en <= 1'b0;

    // Load input_stream_sram: 4 timesteps, wl[0..3] = 4'b1101 (popcount=3)
    begin
      logic [N_IN-1:0] wl;
      for (int t = 0; t < 4; t++) begin
        wl = '0;
      wl[0] = 1'b1;
      wl[1] = 1'b0;
      wl[2] = 1'b1;
      wl[3] = 1'b1;
      load_isr(t[T_AW-1:0], wl);
      end
    end

    // Configure stage: in_dim=4, out_dim=2, sum_max=60, threshold=40
    @(posedge clk);
    cfg_in_dim = 16'd4;
    cfg_out_dim = 16'd2;
    cfg_threshold = 32'd40;
    cfg_sum_max = 32'd60;
    cfg_input_src = V2B_BUF_SEL_INPUT_SRAM;
    cfg_output_dst = V2B_BUF_SEL_STREAM_A;
    cfg_tile_mode = 0;
    cfg_is_tile_final = 1;
    cfg_preserve_membrane = 0;
    cfg_t_count = 16'd4;

    // Pulse start
    @(posedge clk);
    start_pulse <= 1;
    @(posedge clk);
    start_pulse <= 0;

    // Wait for done (with timeout)
    begin : wait_done
      int cycles;
      cycles = 0;
      while (!done_pulse && cycles < 500) begin
        @(posedge clk);
        cycles++;
      end
      if (cycles >= 500) begin
        $display("[FAIL] DONE never asserted within 500 cycles (err=%02h, dbg_t=%0d)",
                 err_code, dbg_t);
        errors++;
      end else begin
        $display("[INFO] stage engine DONE after %0d cycles (err=%02h)",
                 cycles, err_code);
      end
    end
    repeat (3) @(posedge clk);

    // Verify expected spikes per timestep (popcount=3, ADC scale ~51, thr=40):
    //   t=0: membrane 51 → fire, soft reset to 11, spike[t=0] = 2'b11
    //   t=1: membrane 11+51=62 → fire, reset to 22, spike[t=1] = 2'b11
    //   t=2: membrane 22+51=73 → fire, reset to 33, spike[t=2] = 2'b11
    //   t=3: membrane 33+51=84 → fire, reset to 44, spike[t=3] = 2'b11
    // All 4 timesteps fire on both neurons.
    read_sbA(0, got);
    if (got[1:0] !== 2'b11) begin $display("[FAIL] t=0 spike got=%b exp=11", got[1:0]); errors++; end
    else                        $display("[PASS] t=0 spike = 11");

    read_sbA(1, got);
    if (got[1:0] !== 2'b11) begin $display("[FAIL] t=1 spike got=%b exp=11", got[1:0]); errors++; end
    else                        $display("[PASS] t=1 spike = 11");

    read_sbA(2, got);
    if (got[1:0] !== 2'b11) begin $display("[FAIL] t=2 spike got=%b exp=11", got[1:0]); errors++; end
    else                        $display("[PASS] t=2 spike = 11");

    read_sbA(3, got);
    if (got[1:0] !== 2'b11) begin $display("[FAIL] t=3 spike got=%b exp=11", got[1:0]); errors++; end
    else                        $display("[PASS] t=3 spike = 11");

    // err_code must be OK
    if (err_code !== V2B_STAGE_ERR_OK) begin
      $display("[FAIL] err_code=%02h exp=00", err_code); errors++;
    end else begin
      $display("[PASS] err_code = OK");
    end

    if (errors == 0) $display("STAGE_ENGINE_V2_TB_PASS");
    else             $display("STAGE_ENGINE_V2_TB_FAIL (errors=%0d)", errors);
    $finish;
  end

  initial begin #500000; $display("STAGE_ENGINE_V2_TB_TIMEOUT"); $finish; end

endmodule
