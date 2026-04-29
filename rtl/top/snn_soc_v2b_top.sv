`timescale 1ns/1ps
// =============================================================================
// 【面试讲解 cheat sheet · snn_soc_v2b_top.sv】 —— 设计者视角
//
// 一、它在 v2-arm-fpga-demo 里的位置
//   它是 V2.B 加速器的"独立 SoC 顶层"，故意不接 V1 的 snn_soc_top。
//   ARM PS（HPM0 AXI4-Lite）→ v2b_axi_wrapper（AXI slave）→
//   simple2v2btop_adapter（4-state FSM）→ 本模块的 cmd_* simple_bus。
//   再往下：input_stream_sram + stream_buffer A/B + cim_mac_behavioral_v2
//   + tile_partial_buf + stage_engine_v2 + (在 v2-fpga-e203 里还会接
//   layer_sequencer + spike_feedback + lif_neuron_alu)。
//
//   为什么不接 V1 顶层？因为 V1 已经有一套 cim_array_ctrl /
//   layer_sequencer 在驱动相同信号，co-mingle 会多驱动 + 编译期
//   conflict。把 V2.B 拆成独立顶层后，可以 build 矩阵清爽地选"V1 only /
//   V2.B only / V2.B + E203"三种综合 target。
//
// 二、面试最容易被深问的 3 个点
//   1) 为什么 V2.B 不复用 V1 的 cim_macro_blackbox（popcount 公式）？
//      V1 是单层 64×20 推理，行为模型用 popcount 偷懒；V2.B 要做多层
//      streamed-stage MAC，权重要真正参与运算（不能用伪公式），且要支持
//      tile-mode（小子矩阵分批算）和 layer 切换。所以我落了
//      cim_mac_behavioral_v2：WL 维度串行（每拍 1 根 WL）+ j 维度并行
//      （同时算 NUM_OUTPUTS 列），内部 adder tree 做累加。这条 trade-off：
//      面积变大（真乘法）换准确度（不再是 popcount 近似）+ 多层支持。
//
//   2) 为什么所有 config 寄存器都要走 apply_wstrb()？
//      AXI4-Lite 的 WSTRB 允许 partial write（一次只写某几个字节）。
//      早先版本（v1 frozen tag）一律把 cmd_wdata 整字赋给寄存器，
//      WSTRB 完全被忽略——这是协议违例。在 ARM 裸机 C 里恰好不会触发
//      （编译器对 volatile uint32_t * 默认全字 sw），但只要换 byte-mask
//      RPC 路径（例如 V2.B 把 status 字段拆 byte 通过 byte-write 上
//      报）就会让 W1P/W1C 字段被错误清掉 → 这就是 F1 bug 的本质。
//      apply_wstrb 是一个 4-byte mux 函数，带 wstrb[i] 的 byte 用 new
//      值，否则保留 old 值。所有 cfg 写入都套这个函数，加上 START/
//      DONE/CLEAR 这类 W1P/W1C bit 必须额外加 cmd_wstrb[0] gate（不止
//      是 wdata bit 高，还要这个 byte 真的被 strobe 进来）。
//
//   3) 为什么 STAGE_CTRL.DONE W1C 要用 cmd_wstrb[0] && cmd_wdata[7] 双判？
//      光看 cmd_wdata[7]=1 不够：如果 wstrb=4'b1110（只写高 3 byte），
//      cmd_wdata[7] 这个 byte 根本没真的被 strobe 进来，软件意图是"我
//      只想改高字段，DONE 别动我"。如果不加 cmd_wstrb[0] gate，DONE
//      就被错清了——v2b_partial_write_invariant_tb 专门抓这种场景。
//
// 三、关键设计指标
//   - simple_bus 1-cycle 响应（写当拍，读组合）。
//   - cmd_addr 12 bit，4 KB 寄存器窗口足够。
//   - SRAM/MAC weight load 走 W1P strobe（INPUT_SRAM_CTRL[0] /
//     MAC_W_LOAD_CTRL[0]）—— 数据先写入暂存寄存器，CTRL bit 触发
//     同拍真正写 SRAM。这种"两步走"是为了避免 AXI byte-strobe 在
//     SRAM 写口直接触发，把单写口的时序留给 cmd 处理路径。
//
// 四、Corner case / 风险点
//   - F1 修复前的 latent bug：partial WSTRB 时 reg_cfg_in_dim 等会被
//     全字覆盖。frozen v1 tag (8e51ae27) 板上跑 ARM 全字写从未触发。
//     v2 reburn (ea31be22 + 03a39a61) 把这个 bug 修了 → V2B_AXI_
//     PARTIAL_WRITE_TB_PASS 成 8 case AXI 栈级回归 + V2B_PARTIAL_WRITE_
//     INVARIANT_TB_PASS 成 12 check 永久 invariant gate。
//   - apply_wstrb 必须在所有"组合再赋值"路径都用，包括 CFG3/CFG0
//     这种"多字段 packed 在一个 32-bit 字" 的位段——我必须先组装出
//     {high, low} 旧字，过 apply_wstrb 后再拆回各位段写回。这是个
//     容易踩的细节，TB 里有专门 case。
// =============================================================================

//======================================================================
// 文件名: snn_soc_v2b_top.sv
// 模块名: snn_soc_v2b_top
//
// 【功能】
// V2.B streamed-rate 独立 SoC 顶层。按 GPT 2026-04-20 review 的 blind
// spot #1 指示：**不接入 V1 `snn_soc_top`**（V1 里 `layer_sequencer /
// spike_feedback / cim_array_ctrl` 仍在驱动相同信号，co-mingle 会多驱
// 动）。这里为 B5 multilayer bit-parity + C-Milestone-1 提供最小集成
// 面向。
//
// 【本顶层包含】
//   - input_stream_sram      (D6 新 primitive)
//   - stream_buffer_v2 A / B (REV 3.3 ping-pong)
//   - tile_partial_buf       (D1 T×N_out signed buf，tile 模式)
//   - cim_mac_behavioral_v2  (per-position Scheme B diff MAC，behavioral)
//   - stage_engine_v2        (FSM 驱动上述所有)
//   - 简化 reg_bank_v2b（本文件内内联，非独立模块）——CPU-facing
//     memory-mapped 接口
//
// 【简化总线接口】
// 采用 ICB-like 简易总线：cmd_valid/cmd_addr/cmd_wdata/cmd_wstrb/
// rsp_valid/rsp_rdata。一次事务 1 cycle 写或 1 cycle 读（组合返回）。
// TB 用此接口模拟 firmware bus writes。
//
// 【不做的】
//   - 不接 E203 RISC-V core
//   - 不接 SPI boot / UART / JTAG / AXI-Lite bridge
//   - 不接 DMA 引擎
//   - 不接真 CIM analog macro (cim_mac_behavioral_v2 自带 behavioral)
//
// 这些留到后续 Phase C (full firmware) / Phase D (FPGA) 时集成。
//
// 【寄存器 map（v2b-local，不与 V1 reg_bank 冲突）】
//   0x00  STAGE_CTRL       [0]=START W1P, [1]=ABORT W1P, [7]=DONE W1C
//   0x04  STAGE_STATUS     [0]=BUSY RO, [15:8]=T_IDX RO, [23:16]=ERR RO
//   0x08  STAGE_CFG0       [15:0]=IN_DIM, [31:16]=OUT_DIM
//   0x0C  STAGE_CFG1       [31:0]=THRESHOLD
//   0x10  STAGE_CFG2       [31:0]=SUM_MAX
//   0x14  STAGE_CFG3       [1:0]=INPUT_SRC, [9:8]=OUTPUT_DST,
//                          [16]=TILE_MODE, [17]=IS_TILE_FINAL,
//                          [18]=PRESERVE_MEMBRANE
//   0x18  STAGE_CFG4       reserved (weight base addr in full flow)
//   0x1C  STAGE_CFG5       [15:0]=T_COUNT (实际 T，<= MAX_TIMESTEPS)
//
//   0x20  INPUT_SRAM_ADDR  [T_AW-1:0] — 写 WL 到 input_stream_sram 的地址
//   0x24  INPUT_SRAM_LO    低 128 bit (wr_data[127:0])  （分两次写 256-bit）
//   0x28  INPUT_SRAM_HI    高 128 bit (wr_data[255:128])
//   0x2C  INPUT_SRAM_CTRL  [0]=WRITE_STROBE W1P（锁存 LO+HI 写入 SRAM）
//
//   0x30  MAC_W_LOAD_ADDR  [7:0]=i, [15:8]=j
//   0x34  MAC_W_LOAD_DATA  [3:0]=pos, [7:4]=neg
//   0x38  MAC_W_LOAD_CTRL  [0]=WRITE_STROBE W1P
//
//   0x40  STREAM_BUF_CTRL  [0]=SWAP W1P（占位，当前 resident 不用）
//                          [1]=CLEAR_A W1P, [2]=CLEAR_B W1P
//                          [3]=CLEAR_TILE_BUF W1P
//   0x44  STATE_CTRL       [0]=CLEAR_MEMBRANE W1P (暂由 stage_engine 自动)
//
//   0x50+t*4  READ_SBA[t]  RO, 读 stream_buffer_A[t] 的低 32-bit
//   0x50+0x100+t*4  READ_SBB[t] RO, 读 stream_buffer_B[t] 的低 32-bit
//
// 为简化起见，实现把 READ_SBA/READ_SBB 合并为两个地址基（0x0400, 0x0500）
// 加 t 偏移。
//======================================================================
module snn_soc_v2b_top
  import snn_soc_pkg::*;
#(
  parameter bit P_ENABLE_TILE_BUF = 1'b1,    // B0.6 item 4: V2B_ENABLE_TILE
  parameter int P_ADC_BITS = 10              // B0.6 item 2: compile-time 10-bit
) (
  input  logic        clk,
  input  logic        rst_n,

  // Simple bus (ICB-like)
  input  logic        cmd_valid,
  output logic        cmd_ready,
  input  logic [11:0] cmd_addr,    // 4 KB window
  input  logic        cmd_write,   // 1=write, 0=read
  input  logic [31:0] cmd_wdata,
  input  logic [3:0]  cmd_wstrb,

  output logic        rsp_valid,
  output logic [31:0] rsp_rdata
);

  // ── Internal parameter shorthand ───────────────────────────────────
  localparam int P_T_MAX = V2B_MAX_TIMESTEPS;
  localparam int P_N_IN  = V2B_NUM_INPUTS;
  localparam int P_N_OUT = V2B_MAX_OUT_NEURONS;
  localparam int P_PARTIAL_W = V2B_PARTIAL_WIDTH;
  localparam int T_AW = $clog2(P_T_MAX);
  localparam int J_AW = $clog2(P_N_OUT);
  localparam int I_AW = $clog2(P_N_IN);

  // ── V2B address map constants ──────────────────────────────────────
  localparam logic [11:0] A_STAGE_CTRL      = 12'h000;
  localparam logic [11:0] A_STAGE_STATUS    = 12'h004;
  localparam logic [11:0] A_STAGE_CFG0      = 12'h008;
  localparam logic [11:0] A_STAGE_CFG1      = 12'h00C;
  localparam logic [11:0] A_STAGE_CFG2      = 12'h010;
  localparam logic [11:0] A_STAGE_CFG3      = 12'h014;
  localparam logic [11:0] A_STAGE_CFG4      = 12'h018;
  localparam logic [11:0] A_STAGE_CFG5      = 12'h01C;

  // Input SRAM (256-bit row = 8 × 32-bit chunks, write via 8 sequential addrs)
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

  // MAC weight load (single 4-bit pos/neg per write)
  localparam logic [11:0] A_MAC_W_LOAD_ADDR = 12'h050;
  localparam logic [11:0] A_MAC_W_LOAD_DATA = 12'h054;
  localparam logic [11:0] A_MAC_W_LOAD_CTRL = 12'h058;

  localparam logic [11:0] A_STREAM_BUF_CTRL = 12'h060;
  localparam logic [11:0] A_STATE_CTRL      = 12'h064;

  localparam logic [11:0] A_READ_SBA_BASE   = 12'h400;  // 0x400 + t*4 (up to t=255)
  localparam logic [11:0] A_READ_SBB_BASE   = 12'h800;  // 0x800 + t*4

  // -------------------------------------------------------------------------
  // 【面试讲解 · apply_wstrb 是 V2.B AXI 协议 contract 的核心】
  //
  // 这个 function 是 F1 修复 (commit bd860dcc) 引入的"把 4-byte AXI WSTRB
  // 真正落到寄存器写"的工具。在它之前，V2.B 一律 reg <= cmd_wdata（全字
  // 覆盖），WSTRB 完全被忽略——这是 AXI4-Lite 协议违例。
  //
  // 用法约束：所有 cfg 字段写入必须套这个 function；W1P/W1C 这类 control
  // bit 不能用它（必须用 cmd_wstrb[0] && cmd_wdata[bit] 双重 gate，见
  // STAGE_CTRL / STREAM_BUF_CTRL / INPUT_SRAM_CTRL / MAC_W_LOAD_CTRL 几处）。
  //
  // 为什么 W1P/W1C 不能直接套 apply_wstrb？
  // 因为 apply_wstrb 是"按字节合并新旧值"的语义，而 W1P/W1C 的语义是"如
  // 果对应字节真的被 strobe 进来 AND 该 bit 在数据中是 1，触发 pulse / 清
  // sticky"。前者是数据流，后者是控制脉冲，两个语义不可共用一个 function。
  // -------------------------------------------------------------------------
  function automatic logic [31:0] apply_wstrb(
    input logic [31:0] old_word,
    input logic [31:0] new_word,
    input logic [3:0]  wstrb
  );
    logic [31:0] merged;
    begin
      merged = old_word;
      // 4-byte 独立判断，对每个 byte 决定是"用新值"还是"保留旧值"。
      // 对应 AXI4-Lite 标准的 wstrb 语义：wstrb[i]=1 表示这一 byte 上写
      // 的数据是有意为之，wstrb[i]=0 表示软件没动这个 byte。常见误解：
      // 以为整字写时 master 会把所有 wstrb 拉满——RISC-V `sw` 确实如此，
      // 但 ARM 编译器对 `volatile uint8_t *` 的字节赋值会只拉一位 wstrb，
      // 这正是 V2.B 在 v2-arm 跨 ARM PS 接入时必须正确处理 partial wstrb
      // 的根因。
      if (wstrb[0]) merged[7:0]   = new_word[7:0];
      if (wstrb[1]) merged[15:8]  = new_word[15:8];
      if (wstrb[2]) merged[23:16] = new_word[23:16];
      if (wstrb[3]) merged[31:24] = new_word[31:24];
      apply_wstrb = merged;
    end
  endfunction

  // ── Stage engine control & cfg registers (CPU-writable) ───────────
  logic        reg_start_pulse;
  logic [7:0]  reg_err_code;  // sticky mirror of err_code

  logic [15:0] reg_cfg_in_dim, reg_cfg_out_dim;
  logic [31:0] reg_cfg_threshold, reg_cfg_sum_max;
  logic [1:0]  reg_cfg_input_src, reg_cfg_output_dst;
  logic        reg_cfg_tile_mode, reg_cfg_is_tile_final, reg_cfg_preserve_membrane;
  logic [15:0] reg_cfg_t_count;

  // INPUT_SRAM write staging (8 × 32-bit = 256-bit full word)
  logic [T_AW-1:0]  reg_isram_addr;
  logic [31:0]      reg_isram_w0, reg_isram_w1, reg_isram_w2, reg_isram_w3;
  logic [31:0]      reg_isram_w4, reg_isram_w5, reg_isram_w6, reg_isram_w7;
  logic             reg_isram_wstrobe;

  // MAC weight load staging
  logic [I_AW-1:0]  reg_w_load_i;
  logic [J_AW-1:0]  reg_w_load_j;
  logic [3:0]       reg_w_load_pos;
  logic [3:0]       reg_w_load_neg;
  logic             reg_w_load_strobe;

  // Pulses (W1P)
  logic reg_buf_clear_a, reg_buf_clear_b, reg_buf_clear_tile;

  // ── Stage engine wires ─────────────────────────────────────────────
  logic busy, done_pulse;
  logic [7:0] err_code;
  logic [T_AW-1:0] debug_t_idx;

  logic isr_rd_en;
  logic [T_AW-1:0] isr_rd_addr;
  logic [P_N_IN-1:0] isr_rd_data;
  logic isr_wr_en;
  logic [T_AW-1:0] isr_wr_addr;
  logic [P_N_IN-1:0] isr_wr_data;
  logic isr_clear_all;

  logic sbA_wr_en;
  logic [T_AW-1:0] sbA_wr_addr;
  logic [P_N_OUT-1:0] sbA_wr_data;
  logic sbA_rd_en_se;
  logic [T_AW-1:0] sbA_rd_addr_se;
  logic sbA_rd_en_bus;
  logic [T_AW-1:0] sbA_rd_addr_bus;
  logic [P_N_OUT-1:0] sbA_rd_data;

  logic sbB_wr_en;
  logic [T_AW-1:0] sbB_wr_addr;
  logic [P_N_OUT-1:0] sbB_wr_data;
  logic sbB_rd_en_se;
  logic [T_AW-1:0] sbB_rd_addr_se;
  logic sbB_rd_en_bus;
  logic [T_AW-1:0] sbB_rd_addr_bus;
  logic [P_N_OUT-1:0] sbB_rd_data;

  logic tpb_clear_all, tpb_acc_en;
  logic [T_AW-1:0] tpb_wr_t, tpb_rd_t;
  logic [J_AW-1:0] tpb_wr_j, tpb_rd_j;
  logic signed [P_PARTIAL_W-1:0] tpb_wr_diff, tpb_rd_data;
  logic tpb_rd_en;

  logic mac_start, mac_done, mac_busy;
  logic [P_N_IN-1:0] mac_wl_mask;
  logic [15:0] mac_cfg_in_dim, mac_cfg_out_dim;
  logic [31:0] mac_cfg_sum_max;
  logic [J_AW-1:0] mac_diff_rd_j;
  logic signed [P_PARTIAL_W-1:0] mac_diff_rd_data;

  // ── Mux: SE vs bus read access to stream buffers ────────────────────
  logic sbA_rd_en_mux, sbB_rd_en_mux;
  logic [T_AW-1:0] sbA_rd_addr_mux, sbB_rd_addr_mux;
  assign sbA_rd_en_mux   = sbA_rd_en_se | sbA_rd_en_bus;
  assign sbA_rd_addr_mux = sbA_rd_en_bus ? sbA_rd_addr_bus : sbA_rd_addr_se;
  assign sbB_rd_en_mux   = sbB_rd_en_se | sbB_rd_en_bus;
  assign sbB_rd_addr_mux = sbB_rd_en_bus ? sbB_rd_addr_bus : sbB_rd_addr_se;

  // ── Primitives ─────────────────────────────────────────────────────
  input_stream_sram u_isr (
    .clk(clk), .rst_n(rst_n),
    .wr_en(isr_wr_en), .wr_addr(isr_wr_addr), .wr_data(isr_wr_data),
    .rd_en(isr_rd_en), .rd_addr(isr_rd_addr), .rd_data(isr_rd_data),
    .clear_all(isr_clear_all)
  );

  stream_buffer_v2 u_sbA (
    .clk(clk), .rst_n(rst_n),
    .wr_en(sbA_wr_en), .wr_addr(sbA_wr_addr), .wr_data(sbA_wr_data),
    .rd_en(sbA_rd_en_mux), .rd_addr(sbA_rd_addr_mux), .rd_data(sbA_rd_data),
    .clear_all(reg_buf_clear_a)
  );

  stream_buffer_v2 u_sbB (
    .clk(clk), .rst_n(rst_n),
    .wr_en(sbB_wr_en), .wr_addr(sbB_wr_addr), .wr_data(sbB_wr_data),
    .rd_en(sbB_rd_en_mux), .rd_addr(sbB_rd_addr_mux), .rd_data(sbB_rd_data),
    .clear_all(reg_buf_clear_b)
  );

  generate if (P_ENABLE_TILE_BUF) begin : g_tpb
    tile_partial_buf u_tpb (
      .clk(clk), .rst_n(rst_n),
      .clear_all(tpb_clear_all | reg_buf_clear_tile),
      .acc_en(tpb_acc_en), .wr_t(tpb_wr_t), .wr_j(tpb_wr_j), .wr_diff(tpb_wr_diff),
      .rd_en(tpb_rd_en), .rd_t(tpb_rd_t), .rd_j(tpb_rd_j),
      .rd_data(tpb_rd_data)
    );
  end else begin : g_tpb_none
    // Tie off if tile_partial_buf disabled (saves ~14KB BRAM)
    assign tpb_rd_data = '0;
  end endgenerate

  cim_mac_behavioral_v2 #(.P_ADC_BITS(P_ADC_BITS)) u_mac (
    .clk(clk), .rst_n(rst_n),
    .w_load_en(reg_w_load_strobe),
    .w_load_i(reg_w_load_i), .w_load_j(reg_w_load_j),
    .w_load_pos_data(reg_w_load_pos), .w_load_neg_data(reg_w_load_neg),
    .mac_start(mac_start), .wl_mask(mac_wl_mask),
    .cfg_in_dim(mac_cfg_in_dim), .cfg_out_dim(mac_cfg_out_dim),
    .cfg_sum_max(mac_cfg_sum_max),
    .mac_busy(mac_busy), .mac_done(mac_done),
    .diff_rd_j(mac_diff_rd_j), .diff_rd_data(mac_diff_rd_data)
  );

  stage_engine_v2 u_se (
    .clk(clk), .rst_n(rst_n),
    .start_pulse(reg_start_pulse),
    .busy(busy), .done_pulse(done_pulse),
    .err_code(err_code), .debug_t_idx(debug_t_idx),
    .cfg_in_dim(reg_cfg_in_dim), .cfg_out_dim(reg_cfg_out_dim),
    .cfg_threshold(reg_cfg_threshold), .cfg_sum_max(reg_cfg_sum_max),
    .cfg_input_src(reg_cfg_input_src), .cfg_output_dst(reg_cfg_output_dst),
    .cfg_tile_mode(reg_cfg_tile_mode), .cfg_is_tile_final(reg_cfg_is_tile_final),
    .cfg_preserve_membrane(reg_cfg_preserve_membrane),
    .cfg_t_count(reg_cfg_t_count),
    .isr_rd_en(isr_rd_en), .isr_rd_addr(isr_rd_addr), .isr_rd_data(isr_rd_data),
    .sbA_wr_en(sbA_wr_en), .sbA_wr_addr(sbA_wr_addr), .sbA_wr_data(sbA_wr_data),
    .sbB_wr_en(sbB_wr_en), .sbB_wr_addr(sbB_wr_addr), .sbB_wr_data(sbB_wr_data),
    .sbA_rd_en(sbA_rd_en_se), .sbA_rd_addr(sbA_rd_addr_se), .sbA_rd_data(sbA_rd_data),
    .sbB_rd_en(sbB_rd_en_se), .sbB_rd_addr(sbB_rd_addr_se), .sbB_rd_data(sbB_rd_data),
    .tpb_clear_all(tpb_clear_all), .tpb_acc_en(tpb_acc_en),
    .tpb_wr_t(tpb_wr_t), .tpb_wr_j(tpb_wr_j), .tpb_wr_diff(tpb_wr_diff),
    .tpb_rd_en(tpb_rd_en), .tpb_rd_t(tpb_rd_t), .tpb_rd_j(tpb_rd_j),
    .tpb_rd_data(tpb_rd_data),
    .mac_start(mac_start), .mac_done(mac_done), .mac_busy(mac_busy),
    .mac_wl_mask(mac_wl_mask), .mac_cfg_in_dim(mac_cfg_in_dim),
    .mac_cfg_out_dim(mac_cfg_out_dim), .mac_cfg_sum_max(mac_cfg_sum_max),
    .mac_diff_rd_j(mac_diff_rd_j), .mac_diff_rd_data(mac_diff_rd_data)
  );

  // ── Done sticky ────────────────────────────────────────────────────
  logic done_sticky;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) done_sticky <= 1'b0;
    else if (done_pulse) done_sticky <= 1'b1;
    else if (cmd_valid && cmd_write && cmd_addr == A_STAGE_CTRL && cmd_wstrb[0] && cmd_wdata[7])
      done_sticky <= 1'b0;  // W1C bit 7
  end

  // Err sticky mirror (updates from engine's err_code on done)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) reg_err_code <= 8'h00;
    else if (done_pulse) reg_err_code <= err_code;
  end

  // ── Bus write path ─────────────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      reg_start_pulse           <= 1'b0;
      reg_cfg_in_dim            <= '0;
      reg_cfg_out_dim           <= '0;
      reg_cfg_threshold         <= '0;
      reg_cfg_sum_max           <= '0;
      reg_cfg_input_src         <= 2'd0;
      reg_cfg_output_dst        <= 2'd0;
      reg_cfg_tile_mode         <= 1'b0;
      reg_cfg_is_tile_final     <= 1'b1;
      reg_cfg_preserve_membrane <= 1'b0;
      reg_cfg_t_count           <= '0;
      reg_isram_addr            <= '0;
      reg_isram_w0 <= '0; reg_isram_w1 <= '0; reg_isram_w2 <= '0; reg_isram_w3 <= '0;
      reg_isram_w4 <= '0; reg_isram_w5 <= '0; reg_isram_w6 <= '0; reg_isram_w7 <= '0;
      reg_isram_wstrobe         <= 1'b0;
      reg_w_load_i              <= '0;
      reg_w_load_j              <= '0;
      reg_w_load_pos            <= '0;
      reg_w_load_neg            <= '0;
      reg_w_load_strobe         <= 1'b0;
      reg_buf_clear_a           <= 1'b0;
      reg_buf_clear_b           <= 1'b0;
      reg_buf_clear_tile        <= 1'b0;
    end else begin
      // Default: 1-cycle pulses
      reg_start_pulse    <= 1'b0;
      reg_isram_wstrobe  <= 1'b0;
      reg_w_load_strobe  <= 1'b0;
      reg_buf_clear_a    <= 1'b0;
      reg_buf_clear_b    <= 1'b0;
      reg_buf_clear_tile <= 1'b0;

      if (cmd_valid && cmd_write) begin
        case (cmd_addr)
          A_STAGE_CTRL: begin
            if (cmd_wstrb[0] && cmd_wdata[0]) reg_start_pulse <= 1'b1;   // START W1P
            // bit 1 = ABORT (not implemented); bit 7 = DONE W1C handled above
          end
          A_STAGE_CFG0: begin
            logic [31:0] cfg0_word;
            cfg0_word = apply_wstrb({reg_cfg_out_dim, reg_cfg_in_dim}, cmd_wdata, cmd_wstrb);
            reg_cfg_in_dim  <= cfg0_word[15:0];
            reg_cfg_out_dim <= cfg0_word[31:16];
          end
          A_STAGE_CFG1: reg_cfg_threshold <= apply_wstrb(reg_cfg_threshold, cmd_wdata, cmd_wstrb);
          A_STAGE_CFG2: reg_cfg_sum_max   <= apply_wstrb(reg_cfg_sum_max, cmd_wdata, cmd_wstrb);
          A_STAGE_CFG3: begin
            logic [31:0] cfg3_word;
            cfg3_word = apply_wstrb(
              {13'h0, reg_cfg_preserve_membrane,
               reg_cfg_is_tile_final, reg_cfg_tile_mode,
               6'h0, reg_cfg_output_dst,
               6'h0, reg_cfg_input_src},
              cmd_wdata,
              cmd_wstrb
            );
            reg_cfg_input_src         <= cfg3_word[1:0];
            reg_cfg_output_dst        <= cfg3_word[9:8];
            reg_cfg_tile_mode         <= cfg3_word[16];
            reg_cfg_is_tile_final     <= cfg3_word[17];
            reg_cfg_preserve_membrane <= cfg3_word[18];
          end
          A_STAGE_CFG5: begin
            logic [31:0] cfg5_word;
            cfg5_word = apply_wstrb({16'h0, reg_cfg_t_count}, cmd_wdata, cmd_wstrb);
            reg_cfg_t_count <= cfg5_word[15:0];
          end

          A_INPUT_SRAM_ADDR: begin
            logic [31:0] isram_addr_word;
            isram_addr_word = apply_wstrb({{32-T_AW{1'b0}}, reg_isram_addr}, cmd_wdata, cmd_wstrb);
            reg_isram_addr <= isram_addr_word[T_AW-1:0];
          end
          A_INPUT_SRAM_W0:   reg_isram_w0 <= apply_wstrb(reg_isram_w0, cmd_wdata, cmd_wstrb);
          A_INPUT_SRAM_W1:   reg_isram_w1 <= apply_wstrb(reg_isram_w1, cmd_wdata, cmd_wstrb);
          A_INPUT_SRAM_W2:   reg_isram_w2 <= apply_wstrb(reg_isram_w2, cmd_wdata, cmd_wstrb);
          A_INPUT_SRAM_W3:   reg_isram_w3 <= apply_wstrb(reg_isram_w3, cmd_wdata, cmd_wstrb);
          A_INPUT_SRAM_W4:   reg_isram_w4 <= apply_wstrb(reg_isram_w4, cmd_wdata, cmd_wstrb);
          A_INPUT_SRAM_W5:   reg_isram_w5 <= apply_wstrb(reg_isram_w5, cmd_wdata, cmd_wstrb);
          A_INPUT_SRAM_W6:   reg_isram_w6 <= apply_wstrb(reg_isram_w6, cmd_wdata, cmd_wstrb);
          A_INPUT_SRAM_W7:   reg_isram_w7 <= apply_wstrb(reg_isram_w7, cmd_wdata, cmd_wstrb);
          A_INPUT_SRAM_CTRL: if (cmd_wstrb[0] && cmd_wdata[0]) reg_isram_wstrobe <= 1'b1;

          A_MAC_W_LOAD_ADDR: begin
            logic [31:0] mac_addr_word;
            mac_addr_word = apply_wstrb(
              {{(32-(8+J_AW)){1'b0}}, reg_w_load_j, reg_w_load_i},
              cmd_wdata,
              cmd_wstrb
            );
            reg_w_load_i <= mac_addr_word[I_AW-1:0];
            reg_w_load_j <= mac_addr_word[8 +: J_AW];
          end
          A_MAC_W_LOAD_DATA: begin
            logic [31:0] mac_data_word;
            mac_data_word = apply_wstrb({24'h0, reg_w_load_neg, reg_w_load_pos}, cmd_wdata, cmd_wstrb);
            reg_w_load_pos <= mac_data_word[3:0];
            reg_w_load_neg <= mac_data_word[7:4];
          end
          A_MAC_W_LOAD_CTRL: if (cmd_wstrb[0] && cmd_wdata[0]) reg_w_load_strobe <= 1'b1;

          A_STREAM_BUF_CTRL: begin
            if (cmd_wstrb[0] && cmd_wdata[1]) reg_buf_clear_a    <= 1'b1;
            if (cmd_wstrb[0] && cmd_wdata[2]) reg_buf_clear_b    <= 1'b1;
            if (cmd_wstrb[0] && cmd_wdata[3]) reg_buf_clear_tile <= 1'b1;
          end

          default: ;
        endcase
      end
    end
  end

  // ── Input SRAM write path ──────────────────────────────────────────
  // On write strobe, forward reg_isram_addr / {hi,lo} to input_stream_sram
  // 128-bit-wide LO+HI pair is only 256 bit if P_N_IN=256, which is our case.
  assign isr_wr_en   = reg_isram_wstrobe;
  assign isr_wr_addr = reg_isram_addr;
  assign isr_wr_data = {reg_isram_w7, reg_isram_w6, reg_isram_w5, reg_isram_w4,
                        reg_isram_w3, reg_isram_w2, reg_isram_w1, reg_isram_w0};
  assign isr_clear_all = 1'b0;  // firmware currently does not need full clear

  // ── Bus read path (combinational — no latency, matches SRAM 1-cycle via prior read cmd) ──
  // For stream_buffer reads, caller must issue two cycles (read cmd + readback).
  // We expose sbA_rd_en_bus / sbB_rd_en_bus via the cmd_addr pattern on read cmds.
  logic [31:0] read_mux;
  logic [T_AW-1:0] read_sb_t;
  logic cmd_read_sba, cmd_read_sbb;

  // Read addr decode (combinational from cmd)
  always @* begin
    cmd_read_sba = 1'b0;
    cmd_read_sbb = 1'b0;
    read_sb_t    = '0;
    if (cmd_valid && !cmd_write) begin
      if ((cmd_addr & 12'hF00) == A_READ_SBA_BASE) begin
        cmd_read_sba = 1'b1;
        read_sb_t    = (cmd_addr[11:2] & {T_AW{1'b1}});
      end else if ((cmd_addr & 12'hF00) == A_READ_SBB_BASE) begin
        cmd_read_sbb = 1'b1;
        read_sb_t    = (cmd_addr[11:2] & {T_AW{1'b1}});
      end
    end
  end

  assign sbA_rd_en_bus   = cmd_read_sba;
  assign sbA_rd_addr_bus = read_sb_t;
  assign sbB_rd_en_bus   = cmd_read_sbb;
  assign sbB_rd_addr_bus = read_sb_t;

  // Register one cycle of cmd_read_sba/sbb so rsp_rdata (latched next cycle)
  // aligns with stream_buffer's 1-cycle synchronous read latency.
  logic cmd_read_sba_q, cmd_read_sbb_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cmd_read_sba_q <= 1'b0;
      cmd_read_sbb_q <= 1'b0;
    end else begin
      cmd_read_sba_q <= cmd_read_sba;
      cmd_read_sbb_q <= cmd_read_sbb;
    end
  end

  // Read mux (combinational select, data latency handled by TB sequencing)
  always @* begin
    read_mux = 32'h0;
    case (cmd_addr)
      A_STAGE_CTRL:    read_mux = {24'h0, done_sticky, 7'h0};
      A_STAGE_STATUS:  read_mux = {8'h0, reg_err_code, debug_t_idx, 7'h0, busy};
      A_STAGE_CFG0:    read_mux = {reg_cfg_out_dim, reg_cfg_in_dim};
      A_STAGE_CFG1:    read_mux = reg_cfg_threshold;
      A_STAGE_CFG2:    read_mux = reg_cfg_sum_max;
      A_STAGE_CFG3:    read_mux = {13'h0, reg_cfg_preserve_membrane,
                                    reg_cfg_is_tile_final, reg_cfg_tile_mode,
                                    6'h0, reg_cfg_output_dst,
                                    6'h0, reg_cfg_input_src};
      A_STAGE_CFG5:    read_mux = {16'h0, reg_cfg_t_count};
      default: begin
        // Use registered versions so rd_data has had one cycle to settle.
        if (cmd_read_sba_q) read_mux = sbA_rd_data[31:0];
        else if (cmd_read_sbb_q) read_mux = sbB_rd_data[31:0];
      end
    endcase
  end

  // ── Bus response (1-cycle registered) ──────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rsp_valid <= 1'b0;
      rsp_rdata <= 32'h0;
    end else begin
      rsp_valid <= cmd_valid;  // 1-cycle delay
      rsp_rdata <= read_mux;
    end
  end

  // Simple always-ready bus
  assign cmd_ready = 1'b1;

endmodule
