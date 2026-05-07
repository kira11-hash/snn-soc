`timescale 1ns/1ps
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
//   0x14  STAGE_CFG3       [2:0]=INPUT_SRC, [9:8]=OUTPUT_DST,
//                          [16]=TILE_MODE, [17]=IS_TILE_FINAL,
//                          [18]=PRESERVE_MEMBRANE
//   0x18  STAGE_CFG4       reserved (weight base addr in full flow)
//   0x1C  STAGE_CFG5       [15:0]=T_COUNT (实际 T，<= MAX_TIMESTEPS)
//
//   0x20  INPUT_SRAM_ADDR  [T_AW-1:0] — 写 WL 到 input_stream_sram 的地址
//   0x24  INPUT_SRAM_W0    wr_data[31:0]
//   0x28  INPUT_SRAM_W1    wr_data[63:32]
//   0x2C  INPUT_SRAM_W2    wr_data[95:64]
//   0x30  INPUT_SRAM_W3    wr_data[127:96]
//   0x34  INPUT_SRAM_W4    wr_data[159:128]
//   0x38  INPUT_SRAM_W5    wr_data[191:160]
//   0x3C  INPUT_SRAM_W6    wr_data[223:192]
//   0x40  INPUT_SRAM_W7    wr_data[255:224]
//   0x44  INPUT_SRAM_CTRL  [0]=WRITE_STROBE W1P（锁存 W0-W7 写入 SRAM）
//
//   0x50  MAC_W_LOAD_ADDR  [7:0]=i, [15:8]=j
//   0x54  MAC_W_LOAD_DATA  [3:0]=pos, [7:4]=neg
//   0x58  MAC_W_LOAD_CTRL  [0]=WRITE_STROBE W1P
//
//   0x60  STREAM_BUF_CTRL  [0]=SWAP W1P（占位，当前 resident 不用）
//                          [1]=CLEAR_A W1P, [2]=CLEAR_B W1P
//                          [3]=CLEAR_TILE_BUF W1P
//   0x64  STATE_CTRL       [0]=CLEAR_MEMBRANE W1P (暂由 stage_engine 自动)
//
//   0x84-0xBC CONV/Flatten extension：mode/HW/C/KSP/outHW/T/tile/base/
//             start/status/fmap preload write port/perf counter。这里是我给
//             ARM/E203 firmware 暴露的最小卷积层控制面。
//
//   0x50+t*4  READ_SBA[t]  RO, 读 stream_buffer_A[t] 的低 32-bit
//   0x50+0x100+t*4  READ_SBB[t] RO, 读 stream_buffer_B[t] 的低 32-bit
//
// 为简化起见，实现把 READ_SBA/READ_SBB 合并为两个地址基（0x0400, 0x0500）
// 加 t 偏移。
//
// 【我在 SoC 里的位置和设计取舍】
// 我是 V2.B demo 的最小 SoC 顶层：没有把 V1 老控制器混进来，而是直接把
// stage_engine_v2、MAC、stream buffers、tile_partial_buf、fmap_sram 和 CONV
// 动态 reader 接到一套简化 memory-mapped register bank 上。这样做的好处是
// bring-up 路径短、每个寄存器和每条握手都能在 TB/firmware 里直接观察；代价是
// 总线协议很朴素，没有 AXI backpressure、burst 或 CDC 适配。
//
// 【关键指标】
// 当前 ARM/E203 FPGA demo 都按单时钟域 50 MHz 目标来收敛，寄存器写 1 cycle
// 接受、读响应 1 cycle 延迟，stream/fmap SRAM 均按同步 1-cycle read 使用。
// 所有跨模块背压都用 ready/valid 或 W1P pulse 表达，不引入第二时钟域。
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

  // ── M1 trace-hash recorder CSR window (0x068-0x078) ────────────────
  // Day Wed top integration; reserved 0x07C/0x080 left for H1 Phase 2B.
  localparam logic [11:0] A_TRACE_HASH_CTRL        = 12'h068;
  localparam logic [11:0] A_TRACE_HASH_LOG_COUNT   = 12'h06C;
  localparam logic [11:0] A_TRACE_HASH_LOG_RD_ADDR = 12'h070;
  localparam logic [11:0] A_TRACE_HASH_LOG_RD_DATA = 12'h074;
  localparam logic [11:0] A_TRACE_HASH_LOG_RD_META = 12'h078;

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
  localparam logic [11:0] A_CONV_PERF_CYCLES   = 12'h0B8;
  localparam logic [11:0] A_CONV_FMAP_WR_CTRL  = 12'h0BC;

  // ── H1-full LIF per-layer schedule CSR window (0x0C0-0x0E4) ─────────
  // GLOBAL_MODE=1 (reset default) keeps the effective threshold/reset-mode
  // path bit-identical to v2.B HEAD (FC vs CONV via conv_busy on
  // se_cfg_threshold). GLOBAL_MODE=0 sources from the per-layer LUT
  // indexed by lif_layer_idx. See essay/h1_full_design_2026_05_07.md §2.
  localparam logic [11:0] A_LIF_GLOBAL_MODE = 12'h0C0;
  localparam logic [11:0] A_LIF_LAYER0_CFG  = 12'h0C4;
  localparam logic [11:0] A_LIF_LAYER1_CFG  = 12'h0C8;
  localparam logic [11:0] A_LIF_LAYER2_CFG  = 12'h0CC;
  localparam logic [11:0] A_LIF_LAYER3_CFG  = 12'h0D0;
  localparam logic [11:0] A_LIF_LAYER4_CFG  = 12'h0D4;
  localparam logic [11:0] A_LIF_LAYER5_CFG  = 12'h0D8;
  localparam logic [11:0] A_LIF_LAYER6_CFG  = 12'h0DC;
  localparam logic [11:0] A_LIF_LAYER7_CFG  = 12'h0E0;
  localparam logic [11:0] A_LIF_LAYER_IDX   = 12'h0E4;

  localparam logic [11:0] A_READ_SBA_BASE   = 12'h400;  // 0x400 + t*4 (up to t=255)
  localparam logic [11:0] A_READ_SBB_BASE   = 12'h800;  // 0x800 + t*4

  // 【Corner case：所有 CPU 可写寄存器都必须尊重 WSTRB】
  // ARM PS / E203 firmware 可能发 byte/halfword 写，尤其 bring-up 时常用
  // devmem 或简化总线任务只写低字节的 W1P bit。这里统一做 read-modify-write，
  // 避免一次写 START/COMMIT 时把同一个寄存器里的 mode、auto-inc、target_bank
  // 等高位配置清掉。之前 partial write invariant TB 就是专门防这个坑。
  function automatic logic [31:0] apply_wstrb(
    input logic [31:0] old_word,
    input logic [31:0] new_word,
    input logic [3:0]  wstrb
  );
    logic [31:0] merged;
    begin
      merged = old_word;
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
  logic [V2B_BUF_SEL_W-1:0] reg_cfg_input_src;
  logic [1:0]  reg_cfg_output_dst;
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

  // CONV register bank
  // 【架构注释：我把 CONV 控制面放在顶层内联，而不是另起 reg_bank 模块】
  // 这条 demo 线最看重可调试性：固件写哪个地址、RTL 哪个 pulse 拉高，都能在
  // 一个文件里追到。长期看独立 reg_bank 更整洁，但当前阶段内联能减少接线错误。
  // TODO优化方向：当寄存器 map 稳定后，可以把 STAGE/CONV register bank 拆成
  // 独立模块，并用同一份 YAML/JSON 生成 C header、RTL decode 和文档。
  logic        reg_conv_mode, reg_flatten_mode, reg_fmap_pp_sel, reg_weight_timeout_en;
  logic [15:0] reg_conv_H, reg_conv_W, reg_conv_C_in, reg_conv_C_out;
  logic [3:0]  reg_conv_K, reg_conv_stride, reg_conv_pad;
  logic [15:0] reg_conv_out_H, reg_conv_out_W, reg_conv_T_count;
  logic [15:0] reg_conv_tile_count, reg_conv_last_tile_valid_count;
  logic [31:0] reg_conv_fmap_base_word, reg_conv_out_base_word;
  logic        reg_conv_start_pulse, reg_conv_abort_pulse, reg_conv_weight_ready_pulse;
  logic        reg_conv_done_clear_pulse;
  logic [31:0] reg_conv_fmap_wr_data, reg_conv_fmap_wr_addr;
  logic        reg_conv_fmap_wr_commit_pulse;
  logic        reg_conv_fmap_wr_auto_inc, reg_conv_fmap_wr_target_bank;
  logic        reg_conv_fmap_wr_inc_pending;

  // ── H1-full LIF per-layer schedule registers ──────────────────────
  // Reset default `lif_global_mode = 1'b1` is the byte-bit identity
  // anchor: the effective threshold/reset_mode mux below preserves the
  // v2.B HEAD expression while GLOBAL_MODE=1. See §2.1 of the design doc.
  logic        lif_global_mode;
  logic [15:0] lif_layer_threshold  [V2B_LIF_LAYER_MAX];
  logic        lif_layer_reset_mode [V2B_LIF_LAYER_MAX];
  logic [2:0]  lif_layer_idx;

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

  // ── M1 trace-hash recorder state (Day Wed top integration) ────────
  // CSR-side registers (host writes via 0x068 / 0x070):
  logic                                                   reg_recorder_en;          // CTRL[0] RW
  logic                                                   reg_recorder_clear_pulse; // CTRL[1] W1P (1-cycle)
  logic [trace_hash_recorder_pkg::TRACE_HASH_LAYER_ID_W-1:0] reg_recorder_layer_id; // CTRL[10:8] RW
  logic [trace_hash_recorder_pkg::TRACE_HASH_LOG_ADDR_W-1:0] reg_recorder_rd_addr;  // 0x070 RW
  logic                                                   reg_recorder_rd_en_pulse; // pulse on WRITE 0x070
  // Module outputs back into CSR readback path:
  logic [trace_hash_recorder_pkg::TRACE_HASH_LOG_COUNT_W-1:0]    recorder_log_count;
  logic                                                          recorder_log_overflow;
  logic                                                          recorder_layer_id_fault;
  logic [31:0]                                                   recorder_rd_data;
  logic [trace_hash_recorder_pkg::TRACE_HASH_META_PACKED_W-1:0]  recorder_rd_meta;
  logic                                                          recorder_rd_fire;
  logic [trace_hash_recorder_pkg::TRACE_HASH_LOG_ADDR_W-1:0]     recorder_rd_addr_write_data;
  logic [trace_hash_recorder_pkg::TRACE_HASH_LOG_ADDR_W-1:0]     recorder_rd_addr_effective;

  logic tpb_clear_all, tpb_acc_en, tpb_clear_busy;
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

  // CONV integration wires
  logic conv_busy, conv_done_sticky, conv_weight_req;
  logic [7:0] conv_cur_h, conv_cur_w, conv_cur_tile;
  logic [3:0] conv_err_code;
  logic [31:0] conv_perf_cycles;

  logic patch_ctx_valid;
  logic [7:0] patch_ctx_h, patch_ctx_w;
  logic [15:0] patch_ctx_tile_idx;
  logic [3:0] patch_cfg_K, patch_cfg_stride, patch_cfg_pad, patch_cfg_stream_words;
  logic [15:0] patch_cfg_C_in, patch_cfg_H, patch_cfg_W;
  logic [31:0] patch_cfg_fmap_base_word;
  logic flat_ctx_valid;
  logic [15:0] flat_tile_idx, flat_cfg_H, flat_cfg_W, flat_cfg_C;
  logic [31:0] flat_cfg_fmap_base_word;
  logic [3:0] flat_cfg_stream_words;

  logic conv_stage_start_pulse;
  logic [15:0] conv_stage_cfg_in_dim, conv_stage_cfg_out_dim;
  logic [31:0] conv_stage_cfg_threshold, conv_stage_cfg_sum_max;
  logic [V2B_BUF_SEL_W-1:0] conv_stage_cfg_input_src;
  logic [1:0] conv_stage_cfg_output_dst;
  logic conv_stage_cfg_tile_mode, conv_stage_cfg_is_tile_final;
  logic conv_stage_cfg_preserve_membrane;
  logic [15:0] conv_stage_cfg_t_count;
  logic conv_stage_clear_tile_buf;

  logic dyn_wl_req_valid, dyn_wl_req_ready, dyn_wl_resp_valid, dyn_wl_resp_ready;
  logic [8:0] dyn_wl_req_timestep, dyn_wl_resp_valid_count;
  logic [P_N_IN-1:0] dyn_wl_resp_data;
  logic patch_req_valid, patch_req_ready, patch_resp_valid, patch_resp_ready;
  logic [255:0] patch_resp_data;
  logic [8:0] patch_resp_count;
  logic flat_req_valid, flat_req_ready, flat_resp_valid, flat_resp_ready;
  logic [255:0] flat_resp_data;
  logic [8:0] flat_resp_count;

  logic patch_fmap_rd_en, flat_fmap_rd_en;
  logic [31:0] patch_fmap_rd_addr, flat_fmap_rd_addr;
  logic [31:0] fmap_rd_data;
  logic conv_fmap_wr_en, conv_fmap_wr_bank_sel;
  logic [31:0] conv_fmap_wr_addr, conv_fmap_wr_data;
  logic [3:0] conv_fmap_wr_strb;
  logic fw_fmap_wr_valid, fmap_sram_wr_en, fmap_sram_wr_bank_sel;
  logic [31:0] fmap_sram_wr_addr, fmap_sram_wr_data;
  logic [3:0] fmap_sram_wr_strb;
  logic fmap_sram_oob;
  logic spike_out_valid;
  logic [8:0] spike_out_timestep;
  logic [P_N_OUT-1:0] spike_out_vec;

  // ── Mux: SE vs bus read access to stream buffers ────────────────────
  logic sbA_rd_en_mux, sbB_rd_en_mux;
  logic [T_AW-1:0] sbA_rd_addr_mux, sbB_rd_addr_mux;
  assign sbA_rd_en_mux   = sbA_rd_en_se | sbA_rd_en_bus;
  assign sbA_rd_addr_mux = sbA_rd_en_bus ? sbA_rd_addr_bus : sbA_rd_addr_se;
  assign sbB_rd_en_mux   = sbB_rd_en_se | sbB_rd_en_bus;
  assign sbB_rd_addr_mux = sbB_rd_en_bus ? sbB_rd_addr_bus : sbB_rd_addr_se;

  // Recorder readback contract: the write to A_TRACE_HASH_LOG_RD_ADDR both
  // updates the latched address register and triggers the underlying BRAM tap.
  // This fire must happen on the write cycle itself so the NEXT MMIO read of
  // 0x074 / 0x078 can observe freshly latched rd_data/rd_meta.
  assign recorder_rd_addr_write_data = {
    cmd_wstrb[1] ? cmd_wdata[10:8] : reg_recorder_rd_addr[10:8],
    cmd_wstrb[0] ? cmd_wdata[7:0]  : reg_recorder_rd_addr[7:0]
  };
  assign recorder_rd_fire =
    cmd_valid && cmd_write && (cmd_addr == A_TRACE_HASH_LOG_RD_ADDR) && (|cmd_wstrb);
  assign recorder_rd_addr_effective = recorder_rd_fire
    ? recorder_rd_addr_write_data
    : reg_recorder_rd_addr;

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
      .clear_all(tpb_clear_all | reg_buf_clear_tile | conv_stage_clear_tile_buf),
      .clear_busy(tpb_clear_busy),
      .acc_en(tpb_acc_en), .wr_t(tpb_wr_t), .wr_j(tpb_wr_j), .wr_diff(tpb_wr_diff),
      .rd_en(tpb_rd_en), .rd_t(tpb_rd_t), .rd_j(tpb_rd_j),
      .rd_data(tpb_rd_data)
    );
  end else begin : g_tpb_none
    // Tie off if tile_partial_buf disabled (saves ~14KB BRAM)
    assign tpb_rd_data = '0;
    assign tpb_clear_busy = 1'b0;
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

  // 【架构注释：dynamic WL 请求在顶层按 input_src 分流】
  // stage_engine_v2 只发一套 dyn_wl_req/resp；我在顶层根据 conv_ctrl 当前给出的
  // input_src 选择 patch_unroller 或 flatten_reader。这样 stage_engine 不需要知道
  // CONV 几何，也不需要实例化两套输入通路。代价是 input_src 必须在一次 stage
  // 运行期间稳定，conv_ctrl 的 stage_cfg_* 寄存输出正是为这个目的存在。
  assign patch_req_valid  = dyn_wl_req_valid && (conv_stage_cfg_input_src == V2B_BUF_SEL_PATCH_UNROLLER);
  assign flat_req_valid   = dyn_wl_req_valid && (conv_stage_cfg_input_src == V2B_BUF_SEL_FMAP_FLATTEN);
  assign dyn_wl_req_ready = (conv_stage_cfg_input_src == V2B_BUF_SEL_FMAP_FLATTEN)
                          ? flat_req_ready : patch_req_ready;
  assign patch_resp_ready = dyn_wl_resp_ready && (conv_stage_cfg_input_src == V2B_BUF_SEL_PATCH_UNROLLER);
  assign flat_resp_ready  = dyn_wl_resp_ready && (conv_stage_cfg_input_src == V2B_BUF_SEL_FMAP_FLATTEN);
  assign dyn_wl_resp_valid = (conv_stage_cfg_input_src == V2B_BUF_SEL_FMAP_FLATTEN)
                           ? flat_resp_valid : patch_resp_valid;
  assign dyn_wl_resp_data = (conv_stage_cfg_input_src == V2B_BUF_SEL_FMAP_FLATTEN)
                          ? flat_resp_data : patch_resp_data;
  assign dyn_wl_resp_valid_count = (conv_stage_cfg_input_src == V2B_BUF_SEL_FMAP_FLATTEN)
                                 ? flat_resp_count : patch_resp_count;

  fmap_sram_v2 u_fmap (
    .clk(clk), .rst_n(rst_n),
    .bank_sel_pp(reg_fmap_pp_sel),
    .rd_en(patch_fmap_rd_en | flat_fmap_rd_en),
    .rd_word_addr(patch_fmap_rd_en ? patch_fmap_rd_addr : flat_fmap_rd_addr),
    .rd_data(fmap_rd_data),
    .wr_en(fmap_sram_wr_en),
    .wr_bank_sel(fmap_sram_wr_bank_sel),
    .wr_word_addr(fmap_sram_wr_addr),
    .wr_data(fmap_sram_wr_data),
    .wr_strb(fmap_sram_wr_strb),
    .addr_oob(fmap_sram_oob)
  );

  patch_unroller_v2 u_patch_unroller (
    .clk(clk), .rst_n(rst_n),
    .ctx_valid(patch_ctx_valid),
    .ctx_h(patch_ctx_h), .ctx_w(patch_ctx_w), .ctx_tile_idx(patch_ctx_tile_idx),
    .cfg_K(patch_cfg_K), .cfg_stride(patch_cfg_stride), .cfg_pad(patch_cfg_pad),
    .cfg_C_in(patch_cfg_C_in), .cfg_H(patch_cfg_H), .cfg_W(patch_cfg_W),
    .cfg_fmap_base_word(patch_cfg_fmap_base_word),
    .cfg_stream_words(patch_cfg_stream_words),
    .dyn_wl_req_valid(patch_req_valid),
    .dyn_wl_req_ready(patch_req_ready),
    .dyn_wl_req_timestep(dyn_wl_req_timestep),
    .dyn_wl_resp_valid(patch_resp_valid),
    .dyn_wl_resp_ready(patch_resp_ready),
    .dyn_wl_resp_data(patch_resp_data),
    .dyn_wl_resp_valid_count(patch_resp_count),
    .fmap_rd_en(patch_fmap_rd_en),
    .fmap_rd_word_addr(patch_fmap_rd_addr),
    .fmap_rd_data(fmap_rd_data)
  );

  fmap_flatten_reader_v2 u_flatten_reader (
    .clk(clk), .rst_n(rst_n),
    .ctx_valid(flat_ctx_valid),
    .flat_tile_idx(flat_tile_idx),
    .cfg_H(flat_cfg_H), .cfg_W(flat_cfg_W), .cfg_C(flat_cfg_C),
    .cfg_fmap_base_word(flat_cfg_fmap_base_word),
    .cfg_stream_words(flat_cfg_stream_words),
    .dyn_wl_req_valid(flat_req_valid),
    .dyn_wl_req_ready(flat_req_ready),
    .dyn_wl_req_timestep(dyn_wl_req_timestep),
    .dyn_wl_resp_valid(flat_resp_valid),
    .dyn_wl_resp_ready(flat_resp_ready),
    .dyn_wl_resp_data(flat_resp_data),
    .dyn_wl_resp_valid_count(flat_resp_count),
    .fmap_rd_en(flat_fmap_rd_en),
    .fmap_rd_word_addr(flat_fmap_rd_addr),
    .fmap_rd_data(fmap_rd_data)
  );

  conv_ctrl_v2 u_conv_ctrl (
    .clk(clk), .rst_n(rst_n),
    .cfg_conv_mode(reg_conv_mode),
    .cfg_flatten_mode(reg_flatten_mode),
    .cfg_pp_sel(reg_fmap_pp_sel),
    .cfg_weight_timeout_en(reg_weight_timeout_en),
    .cfg_H(reg_conv_H), .cfg_W(reg_conv_W),
    .cfg_C_in(reg_conv_C_in), .cfg_C_out(reg_conv_C_out),
    .cfg_K(reg_conv_K), .cfg_stride(reg_conv_stride), .cfg_pad(reg_conv_pad),
    .cfg_out_H(reg_conv_out_H), .cfg_out_W(reg_conv_out_W),
    .cfg_T_count(reg_conv_T_count),
    .cfg_tile_count(reg_conv_tile_count),
    .cfg_last_tile_valid_count(reg_conv_last_tile_valid_count),
    .cfg_fmap_base_word(reg_conv_fmap_base_word),
    .cfg_out_base_word(reg_conv_out_base_word),
    .cfg_threshold(reg_cfg_threshold),
    .cfg_sum_max(reg_cfg_sum_max),
    .start_pulse(reg_conv_start_pulse),
    .abort_pulse(reg_conv_abort_pulse),
    .weight_ready_pulse(reg_conv_weight_ready_pulse),
    .done_clear_pulse(reg_conv_done_clear_pulse),
    .fmap_wr_commit_pulse(reg_conv_fmap_wr_commit_pulse),
    .fmap_wr_addr(reg_conv_fmap_wr_addr),
    .busy(conv_busy), .done_sticky(conv_done_sticky), .weight_req(conv_weight_req),
    .current_pixel_h(conv_cur_h), .current_pixel_w(conv_cur_w),
    .current_tile_idx(conv_cur_tile), .err_code(conv_err_code),
    .perf_cycles(conv_perf_cycles),
    .patch_ctx_valid(patch_ctx_valid),
    .patch_ctx_h(patch_ctx_h), .patch_ctx_w(patch_ctx_w),
    .patch_ctx_tile_idx(patch_ctx_tile_idx),
    .patch_cfg_K(patch_cfg_K), .patch_cfg_stride(patch_cfg_stride),
    .patch_cfg_pad(patch_cfg_pad), .patch_cfg_C_in(patch_cfg_C_in),
    .patch_cfg_H(patch_cfg_H), .patch_cfg_W(patch_cfg_W),
    .patch_cfg_fmap_base_word(patch_cfg_fmap_base_word),
    .patch_cfg_stream_words(patch_cfg_stream_words),
    .flat_ctx_valid(flat_ctx_valid), .flat_tile_idx(flat_tile_idx),
    .flat_cfg_H(flat_cfg_H), .flat_cfg_W(flat_cfg_W), .flat_cfg_C(flat_cfg_C),
    .flat_cfg_fmap_base_word(flat_cfg_fmap_base_word),
    .flat_cfg_stream_words(flat_cfg_stream_words),
    .stage_start_pulse(conv_stage_start_pulse),
    .stage_cfg_in_dim(conv_stage_cfg_in_dim),
    .stage_cfg_out_dim(conv_stage_cfg_out_dim),
    .stage_cfg_threshold(conv_stage_cfg_threshold),
    .stage_cfg_sum_max(conv_stage_cfg_sum_max),
    .stage_cfg_input_src(conv_stage_cfg_input_src),
    .stage_cfg_output_dst(conv_stage_cfg_output_dst),
    .stage_cfg_tile_mode(conv_stage_cfg_tile_mode),
    .stage_cfg_is_tile_final(conv_stage_cfg_is_tile_final),
    .stage_cfg_preserve_membrane(conv_stage_cfg_preserve_membrane),
    .stage_cfg_t_count(conv_stage_cfg_t_count),
    .stage_clear_tile_buf(conv_stage_clear_tile_buf),
    .stage_clear_busy(conv_stage_clear_tile_buf ? 1'b1 : tpb_clear_busy),
    .stage_done_pulse(done_pulse),
    .stage_err_code(err_code),
    .spike_out_valid(spike_out_valid),
    .spike_out_timestep(spike_out_timestep),
    .spike_out_vec(spike_out_vec),
    .fmap_wr_en(conv_fmap_wr_en),
    .fmap_wr_bank_sel(conv_fmap_wr_bank_sel),
    .fmap_wr_word_addr(conv_fmap_wr_addr),
    .fmap_wr_data(conv_fmap_wr_data),
    .fmap_wr_strb(conv_fmap_wr_strb)
  );

  // 【Corner case：firmware preload 写口和 CONV 写回仲裁】
  // ARM bring-up 曾经卡很久的核心原因之一，是 fmap/weight preload 时序没有被讲清：
  // firmware 必须在 CONV idle 时把输入 fmap 写进 reader bank，并在每个 tile 权重装好
  // 后回 weight_ready。这里我明确让 CONV writeback 优先，firmware preload 只能在
  // !conv_busy 且地址在 bank 内时写。否则一次误写会污染正在读取的 fmap，表现成
  // “功能一直不对”而不是明显的总线错误。
  assign fw_fmap_wr_valid      = reg_conv_fmap_wr_commit_pulse && !conv_busy
                               && (reg_conv_fmap_wr_addr < ((V2B_CONV_FMAP_BANK_KIB * 1024) / 4));
  assign fmap_sram_wr_en       = conv_fmap_wr_en | fw_fmap_wr_valid;
  assign fmap_sram_wr_bank_sel = conv_fmap_wr_en ? conv_fmap_wr_bank_sel
                                                 : reg_conv_fmap_wr_target_bank;
  assign fmap_sram_wr_addr     = conv_fmap_wr_en ? conv_fmap_wr_addr
                                                 : reg_conv_fmap_wr_addr;
  assign fmap_sram_wr_data     = conv_fmap_wr_en ? conv_fmap_wr_data
                                                 : reg_conv_fmap_wr_data;
  assign fmap_sram_wr_strb     = conv_fmap_wr_en ? conv_fmap_wr_strb : 4'hF;

  logic se_start_pulse;
  logic [15:0] se_cfg_in_dim, se_cfg_out_dim, se_cfg_t_count;
  logic [31:0] se_cfg_threshold, se_cfg_sum_max;
  logic [V2B_BUF_SEL_W-1:0] se_cfg_input_src;
  logic [1:0] se_cfg_output_dst;
  logic se_cfg_tile_mode, se_cfg_is_tile_final, se_cfg_preserve_membrane;

  assign se_start_pulse = conv_busy ? conv_stage_start_pulse : reg_start_pulse;
  assign se_cfg_in_dim = conv_busy ? conv_stage_cfg_in_dim : reg_cfg_in_dim;
  assign se_cfg_out_dim = conv_busy ? conv_stage_cfg_out_dim : reg_cfg_out_dim;

  // H1-full effective threshold/reset_mode mux. GLOBAL_MODE=1 (reset
  // default) preserves byte-bit identity with the v2.B HEAD path:
  //   se_cfg_threshold = conv_busy ? conv_stage_cfg_threshold : reg_cfg_threshold
  //   reset_mode forced to 0 (soft).
  // GLOBAL_MODE=0 sources from the per-layer LUT indexed by
  // lif_layer_idx. See essay/h1_full_design_2026_05_07.md §2.1.
  logic [31:0] lif_per_layer_threshold_eff;
  logic        lif_per_layer_reset_mode_eff;
  always_comb begin
    if (lif_global_mode) begin
      lif_per_layer_threshold_eff  = conv_busy ? conv_stage_cfg_threshold
                                                : reg_cfg_threshold;
      lif_per_layer_reset_mode_eff = 1'b0;
    end else begin
      lif_per_layer_threshold_eff  = {16'h0, lif_layer_threshold[lif_layer_idx]};
      lif_per_layer_reset_mode_eff = lif_layer_reset_mode[lif_layer_idx];
    end
  end
  assign se_cfg_threshold = lif_per_layer_threshold_eff;
  assign se_cfg_sum_max = conv_busy ? conv_stage_cfg_sum_max : reg_cfg_sum_max;
  assign se_cfg_input_src = conv_busy ? conv_stage_cfg_input_src : reg_cfg_input_src;
  assign se_cfg_output_dst = conv_busy ? conv_stage_cfg_output_dst : reg_cfg_output_dst;
  assign se_cfg_tile_mode = conv_busy ? conv_stage_cfg_tile_mode : reg_cfg_tile_mode;
  assign se_cfg_is_tile_final = conv_busy ? conv_stage_cfg_is_tile_final : reg_cfg_is_tile_final;
  assign se_cfg_preserve_membrane = conv_busy ? conv_stage_cfg_preserve_membrane : reg_cfg_preserve_membrane;
  assign se_cfg_t_count = conv_busy ? conv_stage_cfg_t_count : reg_cfg_t_count;

  stage_engine_v2 u_se (
    .clk(clk), .rst_n(rst_n),
    .start_pulse(se_start_pulse),
    .busy(busy), .done_pulse(done_pulse),
    .err_code(err_code), .debug_t_idx(debug_t_idx),
    .cfg_in_dim(se_cfg_in_dim), .cfg_out_dim(se_cfg_out_dim),
    .cfg_threshold(se_cfg_threshold), .cfg_sum_max(se_cfg_sum_max),
    .cfg_input_src(se_cfg_input_src), .cfg_output_dst(se_cfg_output_dst),
    .cfg_tile_mode(se_cfg_tile_mode), .cfg_is_tile_final(se_cfg_is_tile_final),
    .cfg_preserve_membrane(se_cfg_preserve_membrane),
    .cfg_t_count(se_cfg_t_count),
    .cfg_conv_mode(conv_busy),
    .cfg_flatten_mode(reg_flatten_mode),
    // H1-full: sourced from the effective per-layer reset_mode mux.
    // While LIF_GLOBAL_MODE=1 (reset default) this is forced to 1'b0
    // (soft), so stage_engine_v2's hard-reset arm is unreachable and
    // the path is bit-identical to v2.B HEAD.
    // (essay/h1_full_design_2026_05_07.md §2.1)
    .cfg_reset_mode(lif_per_layer_reset_mode_eff),
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
    .mac_diff_rd_j(mac_diff_rd_j), .mac_diff_rd_data(mac_diff_rd_data),
    .dyn_wl_req_valid(dyn_wl_req_valid),
    .dyn_wl_req_ready(dyn_wl_req_ready),
    .dyn_wl_req_timestep(dyn_wl_req_timestep),
    .dyn_wl_resp_valid(dyn_wl_resp_valid),
    .dyn_wl_resp_ready(dyn_wl_resp_ready),
    .dyn_wl_resp_data(dyn_wl_resp_data),
    .dyn_wl_resp_valid_count(dyn_wl_resp_valid_count),
    .spike_out_valid(spike_out_valid),
    .spike_out_timestep(spike_out_timestep),
    .spike_out_vec(spike_out_vec)
  );

  // ── M1 trace-hash recorder (sidecar; see trace_hash_recorder.sv) ──
  //
  // Sidecar tap on the spike-commit boundary: stage_engine_v2 emits
  // sbA_wr_en or sbB_wr_en (mutually exclusive per stage_engine_v2 FSM)
  // when a per-(layer, t) spike vector is committed to stream_buffer_v2.
  // We mirror that into a CRC-32 hash + meta into a small BRAM that
  // host firmware reads via TRACE_HASH_LOG_RD_DATA / RD_META.
  //
  // cfg_recorder_en defaults to 0 at reset, so the recorder is fully
  // sidecar (no datapath influence) until host CSR enables it. Host
  // dual-host (ARM PS / E203 PL) firmware compares hash sequences for
  // byte-exact validation; see paper section 4.2 (M1 add-on).
  trace_hash_recorder #(
    .P_N_OUT     (V2B_MAX_OUT_NEURONS),
    .P_T_MAX     (V2B_MAX_TIMESTEPS),
    .P_LAYER_MAX (trace_hash_recorder_pkg::TRACE_HASH_P_LAYER_MAX_DEFAULT),
    .P_LOG_DEPTH (trace_hash_recorder_pkg::TRACE_HASH_P_LOG_DEPTH_DEFAULT)
  ) u_trace_hash_recorder (
    .clk(clk), .rst_n(rst_n),
    .cfg_recorder_en      (reg_recorder_en),
    .cfg_recorder_clear   (reg_recorder_clear_pulse),
    .spike_commit_valid   (sbA_wr_en | sbB_wr_en),
    .spike_commit_data    (sbA_wr_en ? sbA_wr_data : sbB_wr_data),
    .spike_commit_t_idx   (sbA_wr_en ? sbA_wr_addr : sbB_wr_addr),
    .spike_commit_buf_sel (sbB_wr_en),  // 0=A, 1=B (mutually exclusive)
    .spike_commit_layer_id(reg_recorder_layer_id),
    .log_count            (recorder_log_count),
    .log_overflow         (recorder_log_overflow),
    .layer_id_fault       (recorder_layer_id_fault),
    .rd_en                (recorder_rd_fire),
    .rd_addr              (recorder_rd_addr_effective),
    .rd_data              (recorder_rd_data),
    .rd_meta              (recorder_rd_meta)
  );

`ifndef SYNTHESIS
`ifdef VCS
  // Recorder buf_sel encoding assumes stage_engine never commits A and B
  // on the same cycle.
  property p_trace_hash_commit_ports_mutex;
    @(posedge clk) disable iff (!rst_n)
      !(sbA_wr_en && sbB_wr_en);
  endproperty
  a_trace_hash_commit_ports_mutex : assert property (p_trace_hash_commit_ports_mutex)
    else $error("TRACE_HASH commit port violation: sbA_wr_en and sbB_wr_en asserted together");

  // ── H1-full SVA family (essay/h1_full_design_2026_05_07.md §2.3) ──

  // SVA-1: GLOBAL_MODE=1 → effective threshold equals the historical
  //   FC-vs-CONV expression bit-for-bit; reset_mode is forced to soft.
  //   This is the byte-bit identity anchor for the entire H1 commit
  //   sequence.
  property p_h1_global_mode_identity;
    @(posedge clk) disable iff (!rst_n)
      lif_global_mode |->
        (lif_per_layer_threshold_eff ==
         (conv_busy ? conv_stage_cfg_threshold : reg_cfg_threshold)) &&
        (lif_per_layer_reset_mode_eff == 1'b0);
  endproperty
  a_h1_global_mode_identity : assert property (p_h1_global_mode_identity)
    else $error("SVA-1: GLOBAL_MODE=1 byte-bit identity broken on se_cfg_threshold mux");

  // SVA-2: out-of-range layer_idx must never be sampled.
  //   CSR width is 3-bit so this is also a defense-in-depth probe.
  property p_h1_layer_idx_in_range;
    @(posedge clk) disable iff (!rst_n)
      !lif_global_mode |-> (lif_layer_idx <= 3'd7);
  endproperty
  a_h1_layer_idx_in_range : assert property (p_h1_layer_idx_in_range)
    else $error("SVA-2: lif_layer_idx out of [0..7] while GLOBAL_MODE=0");

  // SVA-3 family: slot-to-slot isolation expressed against REGISTERED
  //   outputs at the next cycle (|=>) so combinational decode glitches
  //   cannot produce a false fail. Uses live bus signals
  //   (cmd_valid / cmd_write / cmd_addr / cmd_wstrb).
  //   Footnote (Codex round-2 §): SVA-3 is deliberately scoped to
  //   within-window isolation. Non-H1-window isolation is covered by
  //   the byte-mask invariant TB.
  for (genvar gi = 0; gi < V2B_LIF_LAYER_MAX; gi++) begin : g_h1_lif_slot_iso
    localparam logic [11:0] THIS_OFFSET = 12'h0C4 + 12'(gi) * 12'd4;
    property p_h1_lif_slot_iso;
      @(posedge clk) disable iff (!rst_n)
        (cmd_valid && cmd_write && (|cmd_wstrb) &&
         (cmd_addr inside {A_LIF_LAYER0_CFG, A_LIF_LAYER1_CFG,
                            A_LIF_LAYER2_CFG, A_LIF_LAYER3_CFG,
                            A_LIF_LAYER4_CFG, A_LIF_LAYER5_CFG,
                            A_LIF_LAYER6_CFG, A_LIF_LAYER7_CFG}) &&
         (cmd_addr != THIS_OFFSET))
        |=> ($stable(lif_layer_threshold[gi]) &&
             $stable(lif_layer_reset_mode[gi]));
    endproperty
    a_h1_lif_slot_iso : assert property (p_h1_lif_slot_iso)
      else $error("SVA-3: LIF slot %0d mutated by a write to a different LIF slot", gi);
  end

  // SVA-3 scalars: GLOBAL_MODE / LAYER_IDX cannot be mutated by a write
  //   to any other H1-window CSR.
  property p_h1_global_mode_iso;
    @(posedge clk) disable iff (!rst_n)
      (cmd_valid && cmd_write && (|cmd_wstrb) &&
       (cmd_addr inside {A_LIF_LAYER0_CFG, A_LIF_LAYER1_CFG,
                          A_LIF_LAYER2_CFG, A_LIF_LAYER3_CFG,
                          A_LIF_LAYER4_CFG, A_LIF_LAYER5_CFG,
                          A_LIF_LAYER6_CFG, A_LIF_LAYER7_CFG,
                          A_LIF_LAYER_IDX}))
      |=> $stable(lif_global_mode);
  endproperty
  a_h1_global_mode_iso : assert property (p_h1_global_mode_iso)
    else $error("SVA-3: lif_global_mode mutated by write to a non-GLOBAL_MODE H1 slot");

  property p_h1_layer_idx_iso;
    @(posedge clk) disable iff (!rst_n)
      (cmd_valid && cmd_write && (|cmd_wstrb) &&
       (cmd_addr inside {A_LIF_GLOBAL_MODE,
                          A_LIF_LAYER0_CFG, A_LIF_LAYER1_CFG,
                          A_LIF_LAYER2_CFG, A_LIF_LAYER3_CFG,
                          A_LIF_LAYER4_CFG, A_LIF_LAYER5_CFG,
                          A_LIF_LAYER6_CFG, A_LIF_LAYER7_CFG}))
      |=> $stable(lif_layer_idx);
  endproperty
  a_h1_layer_idx_iso : assert property (p_h1_layer_idx_iso)
    else $error("SVA-3: lif_layer_idx mutated by write to a non-IDX H1 slot");
`endif
`endif

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
      reg_cfg_input_src         <= '0;
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
      reg_conv_mode             <= 1'b0;
      reg_flatten_mode          <= 1'b0;
      reg_fmap_pp_sel           <= 1'b0;
      reg_weight_timeout_en     <= 1'b0;
      reg_conv_H <= '0; reg_conv_W <= '0; reg_conv_C_in <= '0; reg_conv_C_out <= '0;
      reg_conv_K <= '0; reg_conv_stride <= '0; reg_conv_pad <= '0;
      reg_conv_out_H <= '0; reg_conv_out_W <= '0; reg_conv_T_count <= '0;
      reg_conv_tile_count <= '0; reg_conv_last_tile_valid_count <= '0;
      reg_conv_fmap_base_word <= '0; reg_conv_out_base_word <= '0;
      reg_conv_start_pulse <= 1'b0;
      reg_conv_abort_pulse <= 1'b0;
      reg_conv_weight_ready_pulse <= 1'b0;
      reg_conv_done_clear_pulse <= 1'b0;
      reg_conv_fmap_wr_data <= '0;
      reg_conv_fmap_wr_addr <= '0;
      reg_conv_fmap_wr_commit_pulse <= 1'b0;
      reg_conv_fmap_wr_auto_inc <= 1'b0;
      reg_conv_fmap_wr_target_bank <= 1'b0;
      reg_conv_fmap_wr_inc_pending <= 1'b0;
      // M1 trace-hash recorder reset
      reg_recorder_en          <= 1'b0;
      reg_recorder_clear_pulse <= 1'b0;
      reg_recorder_layer_id    <= '0;
      reg_recorder_rd_addr     <= '0;
      reg_recorder_rd_en_pulse <= 1'b0;
      // H1-full LIF per-layer schedule reset (GLOBAL_MODE=1 by default
      // is what makes byte-bit identity hold — do not change to 0 here)
      lif_global_mode <= 1'b1;
      lif_layer_idx   <= 3'd0;
      for (int li = 0; li < V2B_LIF_LAYER_MAX; li++) begin
        lif_layer_threshold[li]  <= 16'h0;
        lif_layer_reset_mode[li] <= 1'b0;
      end
    end else begin
      // Default: 1-cycle pulses
      reg_start_pulse    <= 1'b0;
      reg_isram_wstrobe  <= 1'b0;
      reg_w_load_strobe  <= 1'b0;
      reg_buf_clear_a    <= 1'b0;
      reg_buf_clear_b    <= 1'b0;
      reg_buf_clear_tile <= 1'b0;
      reg_conv_start_pulse <= 1'b0;
      reg_conv_abort_pulse <= 1'b0;
      reg_conv_weight_ready_pulse <= 1'b0;
      reg_conv_done_clear_pulse <= 1'b0;
      reg_conv_fmap_wr_commit_pulse <= 1'b0;
      // M1 trace-hash recorder pulse defaults
      reg_recorder_clear_pulse <= 1'b0;
      reg_recorder_rd_en_pulse <= 1'b0;
      // 【Corner case：auto-inc 延后一拍，避免同拍 commit 地址被提前加一】
      // firmware preload 常用“写 DATA、写 CTRL.commit、地址自动+1”的循环。如果我在
      // commit 同一拍就更新 reg_conv_fmap_wr_addr，组合写口可能拿到加一后的地址，
      // 第一 word 被写偏，后续整张 fmap 都错位。inc_pending 把地址递增推迟到
      // commit 脉冲已经被 SRAM 采样之后，这是 ARM preload 问题里最值得记住的细节。
      if (reg_conv_fmap_wr_inc_pending) begin
        reg_conv_fmap_wr_addr <= reg_conv_fmap_wr_addr + 32'd1;
        reg_conv_fmap_wr_inc_pending <= 1'b0;
      end

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
               5'h0, reg_cfg_input_src},
              cmd_wdata,
              cmd_wstrb
            );
            reg_cfg_input_src         <= cfg3_word[V2B_BUF_SEL_W-1:0];
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

          // M1 trace-hash recorder CTRL register: ENABLE [0] (RW),
          // CLEAR_W1P [1] (W1P), LAYER_ID [10:8] (RW); upper bits RO/RSVD.
          A_TRACE_HASH_CTRL: begin
            if (cmd_wstrb[0]) begin
              // CLEAR_W1P in the same low byte must not accidentally disable
              // the recorder on a clear-only write (wdata = 0x02).
              reg_recorder_en <= cmd_wdata[0] | (reg_recorder_en & cmd_wdata[1]);
            end
            if (cmd_wstrb[1]) begin
              reg_recorder_layer_id <= cmd_wdata[10:8];
            end
            if (cmd_wstrb[0] &&
                cmd_wdata[trace_hash_recorder_pkg::TRACE_HASH_CTRL_BIT_CLEAR_W1P])
              reg_recorder_clear_pulse <= 1'b1;
          end

          // M1 trace-hash recorder LOG_RD_ADDR: 11-bit RW, side-effect
          // pulses rd_en into the recorder so hash_mem[addr]/meta_mem[addr]
          // are latched into rd_data_q/rd_meta_q for the NEXT MMIO read of
          // 0x074 / 0x078 (Codex Day Tue review prereq #1).
          A_TRACE_HASH_LOG_RD_ADDR: begin
            if (cmd_wstrb[0]) reg_recorder_rd_addr[7:0]  <= cmd_wdata[7:0];
            if (cmd_wstrb[1]) reg_recorder_rd_addr[10:8] <= cmd_wdata[10:8];
            // Pulse rd_en on this write only (NOT on read of 0x074/0x078)
            if (|cmd_wstrb) reg_recorder_rd_en_pulse <= 1'b1;
          end

          A_CONV_MODE_CFG: begin
            logic [31:0] conv_mode_word;
            conv_mode_word = apply_wstrb({28'h0, reg_weight_timeout_en,
                                           reg_fmap_pp_sel, reg_flatten_mode,
                                           reg_conv_mode},
                                          cmd_wdata, cmd_wstrb);
            reg_conv_mode <= conv_mode_word[0];
            reg_flatten_mode <= conv_mode_word[1];
            reg_fmap_pp_sel <= conv_mode_word[2];
            reg_weight_timeout_en <= conv_mode_word[3];
          end
          A_CONV_CFG_HW: begin
            logic [31:0] word_v;
            word_v = apply_wstrb({reg_conv_W, reg_conv_H}, cmd_wdata, cmd_wstrb);
            reg_conv_H <= word_v[15:0];
            reg_conv_W <= word_v[31:16];
          end
          A_CONV_CFG_C: begin
            logic [31:0] word_v;
            word_v = apply_wstrb({reg_conv_C_out, reg_conv_C_in}, cmd_wdata, cmd_wstrb);
            reg_conv_C_in <= word_v[15:0];
            reg_conv_C_out <= word_v[31:16];
          end
          A_CONV_CFG_K_S_P: begin
            logic [31:0] word_v;
            word_v = apply_wstrb({20'h0, reg_conv_pad, reg_conv_stride, reg_conv_K},
                                  cmd_wdata, cmd_wstrb);
            reg_conv_K <= word_v[3:0];
            reg_conv_stride <= word_v[7:4];
            reg_conv_pad <= word_v[11:8];
          end
          A_CONV_CFG_OUT_HW: begin
            logic [31:0] word_v;
            word_v = apply_wstrb({reg_conv_out_W, reg_conv_out_H}, cmd_wdata, cmd_wstrb);
            reg_conv_out_H <= word_v[15:0];
            reg_conv_out_W <= word_v[31:16];
          end
          A_CONV_CFG_T: begin
            logic [31:0] word_v;
            word_v = apply_wstrb({16'h0, reg_conv_T_count}, cmd_wdata, cmd_wstrb);
            reg_conv_T_count <= word_v[15:0];
          end
          A_CONV_CFG_TILE: begin
            logic [31:0] word_v;
            word_v = apply_wstrb({reg_conv_last_tile_valid_count, reg_conv_tile_count},
                                  cmd_wdata, cmd_wstrb);
            reg_conv_tile_count <= word_v[15:0];
            reg_conv_last_tile_valid_count <= word_v[31:16];
          end
          A_CONV_CFG_FMAP_BASE:
            reg_conv_fmap_base_word <= apply_wstrb(reg_conv_fmap_base_word, cmd_wdata, cmd_wstrb);
          A_CONV_CFG_OUT_BASE:
            reg_conv_out_base_word <= apply_wstrb(reg_conv_out_base_word, cmd_wdata, cmd_wstrb);
          A_CONV_CTRL: begin
            if (cmd_wstrb[0] && cmd_wdata[0]) reg_conv_start_pulse <= 1'b1;
            if (cmd_wstrb[0] && cmd_wdata[1]) reg_conv_abort_pulse <= 1'b1;
            if (cmd_wstrb[0] && cmd_wdata[2]) reg_conv_weight_ready_pulse <= 1'b1;
          end
          A_CONV_STATUS: begin
            if (cmd_wstrb[0] && cmd_wdata[1]) reg_conv_done_clear_pulse <= 1'b1;
          end
          A_CONV_FMAP_WR_DATA:
            reg_conv_fmap_wr_data <= apply_wstrb(reg_conv_fmap_wr_data, cmd_wdata, cmd_wstrb);
          A_CONV_FMAP_WR_ADDR:
            reg_conv_fmap_wr_addr <= apply_wstrb(reg_conv_fmap_wr_addr, cmd_wdata, cmd_wstrb);
          // 【Corner case：commit 是 W1P，auto-inc/target_bank 是状态位】
          // 我把 bit0 设计成写 1 触发、不自保持；bit1/bit2 是可读写配置。这样软件
          // 可以先设置 auto-inc/target_bank，再连续写 commit。若把 commit 做成普通
          // level，firmware 忘记清零会每拍重复写同一个 data word。
          A_CONV_FMAP_WR_CTRL: begin
            logic [31:0] word_v;
            word_v = apply_wstrb({29'h0, reg_conv_fmap_wr_target_bank,
                                   reg_conv_fmap_wr_auto_inc, 1'b0},
                                  cmd_wdata, cmd_wstrb);
            if (cmd_wstrb[0] && cmd_wdata[0]) begin
              reg_conv_fmap_wr_commit_pulse <= 1'b1;
              // 同一笔写事务若同时改 bit1(AUTO_INC) 和 bit0(COMMIT)，本次 commit
              // 应按写后的 bit1 语义决定是否自增，而不是沿用旧寄存值。
              if (word_v[1]) reg_conv_fmap_wr_inc_pending <= 1'b1;
            end
            reg_conv_fmap_wr_auto_inc <= word_v[1];
            reg_conv_fmap_wr_target_bank <= word_v[2];
          end

          // ── H1-full LIF per-layer schedule decode ────────────────
          A_LIF_GLOBAL_MODE: begin
            logic [31:0] word_v;
            word_v = apply_wstrb({31'h0, lif_global_mode}, cmd_wdata, cmd_wstrb);
            lif_global_mode <= word_v[0];
          end
          A_LIF_LAYER0_CFG: begin
            logic [31:0] word_v;
            word_v = apply_wstrb({15'h0, lif_layer_reset_mode[0],
                                  lif_layer_threshold[0]},
                                 cmd_wdata, cmd_wstrb);
            lif_layer_threshold[0]  <= word_v[15:0];
            lif_layer_reset_mode[0] <= word_v[16];
          end
          A_LIF_LAYER1_CFG: begin
            logic [31:0] word_v;
            word_v = apply_wstrb({15'h0, lif_layer_reset_mode[1],
                                  lif_layer_threshold[1]},
                                 cmd_wdata, cmd_wstrb);
            lif_layer_threshold[1]  <= word_v[15:0];
            lif_layer_reset_mode[1] <= word_v[16];
          end
          A_LIF_LAYER2_CFG: begin
            logic [31:0] word_v;
            word_v = apply_wstrb({15'h0, lif_layer_reset_mode[2],
                                  lif_layer_threshold[2]},
                                 cmd_wdata, cmd_wstrb);
            lif_layer_threshold[2]  <= word_v[15:0];
            lif_layer_reset_mode[2] <= word_v[16];
          end
          A_LIF_LAYER3_CFG: begin
            logic [31:0] word_v;
            word_v = apply_wstrb({15'h0, lif_layer_reset_mode[3],
                                  lif_layer_threshold[3]},
                                 cmd_wdata, cmd_wstrb);
            lif_layer_threshold[3]  <= word_v[15:0];
            lif_layer_reset_mode[3] <= word_v[16];
          end
          A_LIF_LAYER4_CFG: begin
            logic [31:0] word_v;
            word_v = apply_wstrb({15'h0, lif_layer_reset_mode[4],
                                  lif_layer_threshold[4]},
                                 cmd_wdata, cmd_wstrb);
            lif_layer_threshold[4]  <= word_v[15:0];
            lif_layer_reset_mode[4] <= word_v[16];
          end
          A_LIF_LAYER5_CFG: begin
            logic [31:0] word_v;
            word_v = apply_wstrb({15'h0, lif_layer_reset_mode[5],
                                  lif_layer_threshold[5]},
                                 cmd_wdata, cmd_wstrb);
            lif_layer_threshold[5]  <= word_v[15:0];
            lif_layer_reset_mode[5] <= word_v[16];
          end
          A_LIF_LAYER6_CFG: begin
            logic [31:0] word_v;
            word_v = apply_wstrb({15'h0, lif_layer_reset_mode[6],
                                  lif_layer_threshold[6]},
                                 cmd_wdata, cmd_wstrb);
            lif_layer_threshold[6]  <= word_v[15:0];
            lif_layer_reset_mode[6] <= word_v[16];
          end
          A_LIF_LAYER7_CFG: begin
            logic [31:0] word_v;
            word_v = apply_wstrb({15'h0, lif_layer_reset_mode[7],
                                  lif_layer_threshold[7]},
                                 cmd_wdata, cmd_wstrb);
            lif_layer_threshold[7]  <= word_v[15:0];
            lif_layer_reset_mode[7] <= word_v[16];
          end
          A_LIF_LAYER_IDX: begin
            logic [31:0] word_v;
            word_v = apply_wstrb({29'h0, lif_layer_idx}, cmd_wdata, cmd_wstrb);
            lif_layer_idx <= word_v[2:0];
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
      A_STAGE_STATUS:  read_mux = {8'h0, reg_err_code, debug_t_idx, 6'h0, tpb_clear_busy, busy};
      A_STAGE_CFG0:    read_mux = {reg_cfg_out_dim, reg_cfg_in_dim};
      A_STAGE_CFG1:    read_mux = reg_cfg_threshold;
      A_STAGE_CFG2:    read_mux = reg_cfg_sum_max;
      A_STAGE_CFG3:    read_mux = {13'h0, reg_cfg_preserve_membrane,
                                    reg_cfg_is_tile_final, reg_cfg_tile_mode,
                                    6'h0, reg_cfg_output_dst,
                                    5'h0, reg_cfg_input_src};
      A_STAGE_CFG5:    read_mux = {16'h0, reg_cfg_t_count};

      // M1 trace-hash recorder readback (5 offsets at 0x068-0x078):
      // CTRL [31:18]=RSVD, [17]=layer_id_fault_RO, [16]=overflow_RO,
      //      [15:11]=RSVD, [10:8]=layer_id, [7:2]=RSVD,
      //      [1]=CLEAR_W1P (always reads 0; pulse-only), [0]=enable
      A_TRACE_HASH_CTRL: read_mux = {14'h0,
                                      recorder_layer_id_fault,
                                      recorder_log_overflow,
                                      5'h0,
                                      reg_recorder_layer_id,
                                      6'h0,
                                      1'b0,
                                      reg_recorder_en};
      A_TRACE_HASH_LOG_COUNT: read_mux =
        {{(32-trace_hash_recorder_pkg::TRACE_HASH_LOG_COUNT_W){1'b0}},
         recorder_log_count};
      A_TRACE_HASH_LOG_RD_ADDR: read_mux =
        {{(32-trace_hash_recorder_pkg::TRACE_HASH_LOG_ADDR_W){1'b0}},
         reg_recorder_rd_addr};
      A_TRACE_HASH_LOG_RD_DATA: read_mux = recorder_rd_data;
      // Per Codex Day Tue review prereq #2: zero-extend 16-bit rd_meta
      // to 32-bit; high bits [31:16] = 0.
      A_TRACE_HASH_LOG_RD_META: read_mux =
        {{(32-trace_hash_recorder_pkg::TRACE_HASH_META_PACKED_W){1'b0}},
         recorder_rd_meta};

      A_CONV_MODE_CFG: read_mux = {28'h0, reg_weight_timeout_en,
                                    reg_fmap_pp_sel, reg_flatten_mode,
                                    reg_conv_mode};
      A_CONV_CFG_HW:   read_mux = {reg_conv_W, reg_conv_H};
      A_CONV_CFG_C:    read_mux = {reg_conv_C_out, reg_conv_C_in};
      A_CONV_CFG_K_S_P: read_mux = {20'h0, reg_conv_pad, reg_conv_stride, reg_conv_K};
      A_CONV_CFG_OUT_HW: read_mux = {reg_conv_out_W, reg_conv_out_H};
      A_CONV_CFG_T:    read_mux = {16'h0, reg_conv_T_count};
      A_CONV_CFG_TILE: read_mux = {reg_conv_last_tile_valid_count, reg_conv_tile_count};
      A_CONV_CFG_FMAP_BASE: read_mux = reg_conv_fmap_base_word;
      A_CONV_CFG_OUT_BASE:  read_mux = reg_conv_out_base_word;
      A_CONV_CTRL:     read_mux = 32'h0;
      A_CONV_STATUS:   read_mux = {conv_cur_tile, conv_cur_w, conv_cur_h,
                                   conv_err_code, 1'b0, conv_weight_req,
                                   conv_done_sticky, conv_busy};
      A_CONV_FMAP_WR_DATA: read_mux = reg_conv_fmap_wr_data;
      A_CONV_FMAP_WR_ADDR: read_mux = reg_conv_fmap_wr_addr;
      A_CONV_PERF_CYCLES:  read_mux = conv_perf_cycles;
      A_CONV_FMAP_WR_CTRL: read_mux = {29'h0, reg_conv_fmap_wr_target_bank,
                                       reg_conv_fmap_wr_auto_inc, 1'b0};

      // ── H1-full LIF per-layer schedule readback ─────────────────
      A_LIF_GLOBAL_MODE: read_mux = {31'h0, lif_global_mode};
      A_LIF_LAYER0_CFG:  read_mux = {15'h0, lif_layer_reset_mode[0], lif_layer_threshold[0]};
      A_LIF_LAYER1_CFG:  read_mux = {15'h0, lif_layer_reset_mode[1], lif_layer_threshold[1]};
      A_LIF_LAYER2_CFG:  read_mux = {15'h0, lif_layer_reset_mode[2], lif_layer_threshold[2]};
      A_LIF_LAYER3_CFG:  read_mux = {15'h0, lif_layer_reset_mode[3], lif_layer_threshold[3]};
      A_LIF_LAYER4_CFG:  read_mux = {15'h0, lif_layer_reset_mode[4], lif_layer_threshold[4]};
      A_LIF_LAYER5_CFG:  read_mux = {15'h0, lif_layer_reset_mode[5], lif_layer_threshold[5]};
      A_LIF_LAYER6_CFG:  read_mux = {15'h0, lif_layer_reset_mode[6], lif_layer_threshold[6]};
      A_LIF_LAYER7_CFG:  read_mux = {15'h0, lif_layer_reset_mode[7], lif_layer_threshold[7]};
      A_LIF_LAYER_IDX:   read_mux = {29'h0, lif_layer_idx};

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
