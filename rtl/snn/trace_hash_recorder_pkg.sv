// -----------------------------------------------------------------------------
// 自动文档头：本文件的可读性说明（仅注释说明，不改变任何逻辑）
// 文件路径：rtl/snn/trace_hash_recorder_pkg.sv
// 作用：M1 trace-hash recorder（Path B paper add-on #1）的接口契约 + CSR 常量集中包。
// 系统角色：Phase 1 Day Mon 落 RTL 第一拍前的 single source of truth；
//           snn_soc_v2b_top.sv / trace_hash_recorder.sv / unit TB / firmware 都从本包
//           读 offset / bit field / 默认参数，避免数值在多文件漂移。
// 行为性质：本文件只有 parameter / typedef / localparam，没有运行时逻辑。
// 项目规则：本包 commit 时间点 = M1 Phase 1 Day Mon；后续任何 CSR 字段修改都必须
//           先改本文件再改其它文件。snn_soc_pkg.sv 在本 phase 不动。
// 集成提示：不要把 V1 main-line / V1 backport 路径混进来；本包 V2.B-only。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: trace_hash_recorder_pkg.sv
// 包名:   trace_hash_recorder_pkg
//
// 【功能概述】
// M1 trace-hash recorder 接口契约 + CSR 寄存器布局集中定义。
// 关联文档：essay/m1_design_doc_2026_05_05.md (Phase 0 Codex-PASS 版)。
// 设计目标：dual-host (ARM PS + E203 PL) byte-exact validation 从 UART 末端
// 升级到 layer × timestep checkpoint 一致性 — paper §4.2 防守核心。
//
// 【硬约束（Codex Phase 0 review 拍板）】
// 1. cfg_recorder_en = 0 时为 sidecar，零反向驱动 stage_engine
// 2. 寄存器落在 0x068-0x078 (snn_soc_v2b_top 的 0x064 / 0x084 之间真实空闲段)
// 3. 0x07C-0x080 reserved 给 H1 Phase 2B (per design doc §2)
// 4. 不动 snn_soc_pkg.sv，本 phase 不修改 V2.B base 全局参数
// 5. layer_id 取 option C：firmware 写 + RTL sticky fault 兜底
// 6. hash 选 CRC-32-IEEE polynomial 0xEDB88320 reflected
//
// 【寄存器布局速查】
// 0x068 TRACE_HASH_CTRL   RW  [0]=ENABLE, [1]=CLEAR_W1P, [10:8]=LAYER_ID,
//                             [16]=OVERFLOW_RO, [17]=LAYER_ID_FAULT_RO
// 0x06C TRACE_HASH_LOG_COUNT   RO  [15:0]=log_count
// 0x070 TRACE_HASH_LOG_RD_ADDR RW  [10:0]=rd_addr (write -> next MMIO read 0x074/0x078)
// 0x074 TRACE_HASH_LOG_RD_DATA RO  [31:0]=hash word at log[rd_addr]
// 0x078 TRACE_HASH_LOG_RD_META RO  [7:0]=t_idx, [10:8]=layer_id, [11]=buf_sel
// 0x07C reserved for H1
// 0x080 reserved for H1
//======================================================================
/* verilator lint_off UNUSEDPARAM */
package trace_hash_recorder_pkg;

  // ──────────────────────────────────────────────────────────────────────────
  // 0. Sizing parameters (must agree with snn_soc_pkg.sv V2B_MAX_*)
  // ──────────────────────────────────────────────────────────────────────────

  // P_N_OUT 必须 = V2B_MAX_OUT_NEURONS = 128
  // P_T_MAX 必须 = V2B_MAX_TIMESTEPS    = 256
  // 实例化时 snn_soc_v2b_top 必须把这两个 V2.B 编译期常量当 parameter override 传入；
  // 这里给的是 default fallback。
  parameter int TRACE_HASH_P_N_OUT_DEFAULT     = 128;
  parameter int TRACE_HASH_P_T_MAX_DEFAULT     = 256;

  // P_LAYER_MAX = 8 — Codex Phase 0 拍板（保持 8，LeNet-5 5L + buffer 够用，
  // 不为 H1 提前膨胀 metadata layout）。
  parameter int TRACE_HASH_P_LAYER_MAX_DEFAULT = 8;

  // P_LOG_DEPTH = 2048 — covers Plain-CNN-4 (5 layers × T=64 = 320 entries) ×
  // 多 sample 重叠保留区，留 ~6× 余量。BRAM 实际宽度 = 32 (hash) + 16 (meta) = 48-bit;
  // 12 KB 总占用 (0.3% 之 4 MiB ZCU102 BRAM)。降级路径见 design doc §9 fallback。
  parameter int TRACE_HASH_P_LOG_DEPTH_DEFAULT = 2048;

  // ──────────────────────────────────────────────────────────────────────────
  // 1. CSR offset constants (12-bit address, AXI/ICB-side)
  // ──────────────────────────────────────────────────────────────────────────

  parameter logic [11:0] TRACE_HASH_A_CTRL          = 12'h068;
  parameter logic [11:0] TRACE_HASH_A_LOG_COUNT     = 12'h06C;
  parameter logic [11:0] TRACE_HASH_A_LOG_RD_ADDR   = 12'h070;
  parameter logic [11:0] TRACE_HASH_A_LOG_RD_DATA   = 12'h074;
  parameter logic [11:0] TRACE_HASH_A_LOG_RD_META   = 12'h078;

  // 0x07C and 0x080 reserved for H1 Phase 2B (do not assign here).
  parameter logic [11:0] TRACE_HASH_A_RSVD_FOR_H1_LO = 12'h07C;
  parameter logic [11:0] TRACE_HASH_A_RSVD_FOR_H1_HI = 12'h080;

  // ──────────────────────────────────────────────────────────────────────────
  // 2. CTRL register bit fields (0x068)
  // ──────────────────────────────────────────────────────────────────────────

  // RW write-from-host bits
  parameter int TRACE_HASH_CTRL_BIT_ENABLE     = 0;   // RW; 1 = recording active
  parameter int TRACE_HASH_CTRL_BIT_CLEAR_W1P  = 1;   // W1P; firmware writes 1 to clear log + counters
  parameter int TRACE_HASH_CTRL_LAYER_ID_LSB   = 8;   // RW; firmware-supplied layer index
  parameter int TRACE_HASH_CTRL_LAYER_ID_MSB   = 10;  // [10:8] = 3-bit, matches P_LAYER_MAX=8

  // RO status bits read-back via the same offset
  parameter int TRACE_HASH_CTRL_BIT_OVERFLOW_RO       = 16;
  parameter int TRACE_HASH_CTRL_BIT_LAYER_ID_FAULT_RO = 17;

  // ──────────────────────────────────────────────────────────────────────────
  // 3. RD_META register layout (0x078)
  // ──────────────────────────────────────────────────────────────────────────

  parameter int TRACE_HASH_META_T_IDX_LSB    = 0;
  parameter int TRACE_HASH_META_T_IDX_MSB    = 7;     // [7:0] = 8-bit, matches P_T_MAX=256
  parameter int TRACE_HASH_META_LAYER_ID_LSB = 8;
  parameter int TRACE_HASH_META_LAYER_ID_MSB = 10;    // [10:8] = 3-bit, matches P_LAYER_MAX=8
  parameter int TRACE_HASH_META_BUF_SEL_BIT  = 11;    // [11] = 0=A, 1=B

  // ──────────────────────────────────────────────────────────────────────────
  // 4. CRC-32-IEEE polynomial constant (Codex Phase 0 拍板)
  // ──────────────────────────────────────────────────────────────────────────

  // Reflected form of CRC-32-IEEE-802.3 polynomial 0x04C11DB7.
  // Used for the per-(layer, t, buf_sel, spike_vec) hash.
  parameter logic [31:0] TRACE_HASH_CRC32_POLY_REFLECTED = 32'hEDB88320;

  // CRC seed (initial register value).
  parameter logic [31:0] TRACE_HASH_CRC32_INIT = 32'hFFFFFFFF;

  // CRC final XOR.
  parameter logic [31:0] TRACE_HASH_CRC32_XOROUT = 32'hFFFFFFFF;

  // ──────────────────────────────────────────────────────────────────────────
  // 5. Width helpers (避免 RTL 里手写 $clog2)
  // ──────────────────────────────────────────────────────────────────────────

  parameter int TRACE_HASH_T_IDX_W    = 8;   // = $clog2(P_T_MAX=256)
  parameter int TRACE_HASH_LAYER_ID_W = 3;   // = $clog2(P_LAYER_MAX=8)
  parameter int TRACE_HASH_LOG_ADDR_W = 11;  // = $clog2(P_LOG_DEPTH=2048)
  parameter int TRACE_HASH_LOG_COUNT_W = 16; // 留 16-bit 余量给溢出 monitoring
  parameter int TRACE_HASH_META_PACKED_W = 16; // RD_META payload packed width

  // ──────────────────────────────────────────────────────────────────────────
  // 6. Read-timing contract assertions (描述性 localparam，给 SVA 用)
  // ──────────────────────────────────────────────────────────────────────────

  // Host write-then-read-next-cycle 协议:
  //   1) host MMIO write A_LOG_RD_ADDR
  //   2) NEXT MMIO read A_LOG_RD_DATA / A_LOG_RD_META 拿到对应 entry
  // 不允许同拍写后立刻读。详见 design doc §2 read-timing contract.
  parameter int TRACE_HASH_RD_PIPELINE_LATENCY = 1;  // 写 RD_ADDR 后 1 拍数据落定

endpackage
/* verilator lint_on UNUSEDPARAM */
