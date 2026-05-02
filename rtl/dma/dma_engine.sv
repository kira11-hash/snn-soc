// =============================================================================
// 【面试讲解 cheat sheet · dma_engine.sv】 —— 设计者视角
//
// 一、它解决什么问题
//   DMA 在这条 SoC 里是"软件控制硬件搬数"的唯一通道。E203 / TB master 通过
//   reg_bank 配 SRC/LEN/DST_SEL，写 START 后 FSM 自动从 data_sram 拉数据
//   写到三种目的之一（input_fifo / weight_sram / instr_sram）。如果不上 DMA：
//   软件要"读 → 写"两条 bus 周期搬一个 word，64×80 word 一帧需要 12k+ cycle
//   纯搬运，跟 SNN 推理差一个数量级；上 DMA 后搬运 = 1.5 cycle/word，CPU
//   可以并行干别的（FW 准备下一帧、配 LIF threshold 等）。
//
// 二、面试最容易被深问的 3 个点
//   1) 为什么 6 状态 FSM 而不是更少？
//      关键拆分点：ST_RD0 / ST_RD1 / ST_PUSH / ST_WR。
//      - DST_INPUT_FIFO 路径下，input_fifo 宽度是 NUM_INPUTS=64 bit，DMA
//        bus 是 32 bit，必须读两 word 拼一个 64-bit push。所以 RD0 抓低
//        word、RD1 抓高 word + 同拍 push（其实是隔拍）。
//      - DST_WEIGHT_BUF / DST_INSTR_SRAM 路径下，目的也是 32 bit，单拍读
//        单拍写就够了——所以走 RD0 → WR 的短路径。
//      把"读"和"写"拆成独立状态有个时序好处：sram_simple 是单写口，DMA
//      和 bus 写互斥，把 WR 单独留出来便于 mux 仲裁；如果 WR 和 RD 合在
//      同状态用组合逻辑做，长路径很容易把 50 MHz 的 STA 顶到边界。
//
//   2) ST_WR 为什么是 addr_ptr - 4？这是 bug 吗？
//      不是 bug，是非阻塞赋值的时序补偿。addr_ptr 在 ST_RD0/RD1 用 <=
//      递增，ST_WR 同拍读到的 addr_ptr 是"递增前的旧值"——但写出去的
//      数据是上一拍 RD 抓回来的，对应的地址是 addr_ptr 已经移过的位置，
//      所以要 -4 还原回那一笔读地址。这是经典的 RTL 阻塞 vs 非阻塞陷阱，
//      之前 reviewer 误报过一次（CLAUDE.md FP-003 记录了误报模式）。
//      面试时如果有人质疑这里：拿 always_ff 的语义图画一下就清楚。
//
//   3) DST_INPUT_FIFO 要求偶数长度怎么处理边界？
//      奇数 → ST_IDLE 直接置 ERR + DONE，不进 SETUP。其他三种 corner case
//      （零长度、未对齐、越界）也都在 ST_IDLE 入口判定：零长度 → DONE（不
//      报错，是合法 no-op），其他 → ERR。设计原则：所有"快速失败"判定
//      都集中在 ST_IDLE 入口一处，FSM 中段不做额外检查——这样 FSM 中段
//      的 timing path 最干净，也方便后续 SDC 给 IDLE→SETUP 加 false_path
//      约束（不行，那条是真路径，但思路类似）。
//
// 三、关键设计指标
//   - 吞吐：单端口 SRAM 极限是 1 word/cycle，DMA 不增加任何 wait state，
//     SRC→DST 实际 ~1.5 cycle/word（含 SETUP）。
//   - 寄存器写背压：DMA 启动后 BUSY=1，CPU 写 SRC/LEN/DST_SEL 被 reg_bank
//     侧屏蔽（DMA 自己有 sticky busy 状态，不参与 in-flight 锁）。
//
// 四、Corner case / 风险
//   - SRC 物理地址 → SRAM 偏移转换：减 ADDR_DATA_BASE，需要 4-byte 对齐
//     检查；之前曾被 reviewer 报"未对齐处理"，实际入口已经判 ERR。
//   - DST=2'b11 是预留非法值：直接 ERR，不要乱当成"未来扩展"用。
//   - DST=WEIGHT_BUF/INSTR_SRAM 时 dst SRAM 的"按 src 偏移镜像复制"语义
//     很容易误用——DMA 不能独立指定 dst 起始地址，而是用 src pointer
//     的低位决定 dst 偏移；payload_off 超出 dst 容量会静默 wrap。这是
//     单写口 BRAM 推断的代价，FW 必须自行保证 payload 大小。
//
// 五、可能的优化（TODO优化方向）
//   - TODO优化方向：把 ST_RD0 / ST_RD1 合并成 burst-read pipeline，让
//     连续两拍的读地址背靠背发，可以省 1 cycle setup；但要小心 sram_simple
//     的 read latency 推断会从"组合"变"寄存"，对 STA 影响要 case-by-case 评估。
// =============================================================================

// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/dma/dma_engine.sv
// Purpose: Moves packed data words from data_sram to a configurable destination.
// Role in system: Offloads repetitive data feeding; DST_SEL routes output to
//   input_fifo (inference path), weight_sram, or instr_sram (load path).
// Behavior summary: Register-programmed source/destination/length, FSM reads
//   words from data_sram, writes to selected target each cycle (SRAM) or
//   pair-packs into 64-bit pushes (FIFO).
// Iter 4 extension: Added REG_DST_SEL (0x0C), ST_WR state, weight/instr write ports.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: dma_engine.sv
// 描述: DMA 引擎，支持多目标路由。
//       - DMA_SRC_ADDR  指向 data_sram 源地址（byte 地址）
//       - DMA_LEN_WORDS 以 32-bit word 计数
//       - DMA_CTRL: bit0 START(W1P), bit1 DONE(W1C), bit2 ERR(W1C), bit3 BUSY(RO)
//       - DMA_DST_SEL: 2-bit 目标选择（默认 0 = INPUT_FIFO）
//
// DST_SEL 目标说明：
//   DST_INPUT_FIFO = 2'b00 : 每两个 word 拼成 1 个 64-bit 写入 input_fifo（原有行为）
//   DST_WEIGHT_BUF = 2'b01 : 逐 word 写入 weight_sram（DMA 写端口，相同字节偏移）
//   DST_INSTR_SRAM = 2'b10 : 逐 word 写入 instr_sram（DMA 写端口，相同字节偏移）
//
// 注意：DST_INPUT_FIFO 要求 len_words 为偶数；其他目标无此限制。
//       DST_SEL=2'b11 视为非法配置，START 后立即置 ERR/DONE。
//       REG_DST_SEL 只允许在 ST_IDLE 改写，busy 期间写入会被忽略。
//======================================================================
// NOTE: DMA_SRC_ADDR 为 SoC 物理地址；内部会减去 ADDR_DATA_BASE 转为 SRAM 偏移。
//       需 4B 对齐，且 [SRC, SRC+LEN-1] 不能越过 data_sram 边界。
//
// -------------------------------------------------------------------------
// 寄存器地址映射（相对于模块被挂载的 base，即 0x4000_0100）：
//   offset 0x00 = REG_SRC_ADDR  : DMA 源起始字节地址（物理地址，需 4B 对齐）
//   offset 0x04 = REG_LEN_WORDS : 传输长度（32-bit word 数）
//   offset 0x08 = REG_DMA_CTRL  :
//       bit[0] = START  (W1P) 写 1 启动 DMA
//       bit[1] = DONE   (W1C) 传输完成标志
//       bit[2] = ERR    (W1C) 错误标志
//       bit[3] = BUSY   (RO)  DMA 非 IDLE 时为 1
//   offset 0x0C = REG_DST_SEL   :
//       bit[1:0] = 目标选择（见 DST_* 常量，默认 0 = INPUT_FIFO）
// -------------------------------------------------------------------------
//
// 6 状态 FSM 流转图（DST_INPUT_FIFO 路径）：
//
//   ST_IDLE  ──(START)──> ST_SETUP ──> ST_RD0 ──> ST_RD1 ──> ST_PUSH
//                                        ^                       │
//                                        └───────────────────────┘
//
// 6 状态 FSM 流转图（DST_WEIGHT_BUF / DST_INSTR_SRAM 路径）：
//
//   ST_IDLE  ──(START)──> ST_SETUP ──> ST_RD0 ──> ST_WR
//                                        ^           │
//                                        └───────────┘
//
// 边界异常（在 ST_IDLE 内检测，不进入 ST_SETUP）：
//   - DST_INPUT_FIFO 且奇数长度 → err
//   - 零长度   → done（不报错）
//   - 未对齐地址 → err
//   - 地址越界   → err
// -------------------------------------------------------------------------
module dma_engine (
  input  logic        clk,
  input  logic        rst_n,

  // 简化总线接口（地址为 offset）
  input  logic        req_valid,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  output logic [31:0] rdata,

  // data_sram 只读 DMA 端口（所有目标的源）
  output logic        dma_rd_en,
  output logic [31:0] dma_rd_addr,
  input  logic [31:0] dma_rd_data,

  // input_fifo 写端口（DST_INPUT_FIFO 使用）
  output logic                          in_fifo_push,
  output logic [snn_soc_pkg::NUM_INPUTS-1:0] in_fifo_wdata,
  input  logic                          in_fifo_full,

  // weight_sram DMA 写端口（DST_WEIGHT_BUF 使用）
  output logic        weight_wr_en,
  output logic [31:0] weight_wr_addr,
  output logic [31:0] weight_wr_data,
  output logic [3:0]  weight_wr_strb,

  // instr_sram DMA 写端口（DST_INSTR_SRAM 使用）
  output logic        instr_wr_en,
  output logic [31:0] instr_wr_addr,
  output logic [31:0] instr_wr_data,
  output logic [3:0]  instr_wr_strb
);
  import snn_soc_pkg::*;

  // -----------------------------------------------------------------------
  // 寄存器偏移常量
  // -----------------------------------------------------------------------
  localparam logic [7:0] REG_SRC_ADDR = 8'h00;
  localparam logic [7:0] REG_LEN_WORDS= 8'h04;
  localparam logic [7:0] REG_DMA_CTRL = 8'h08;
  localparam logic [7:0] REG_DST_SEL  = 8'h0C;

  // -----------------------------------------------------------------------
  // DST_SEL 目标编码
  // -----------------------------------------------------------------------
  localparam logic [1:0] DST_INPUT_FIFO = 2'b00; // → input_fifo（64-bit 对拼）
  localparam logic [1:0] DST_WEIGHT_BUF = 2'b01; // → weight_sram（逐 word 写）
  localparam logic [1:0] DST_INSTR_SRAM = 2'b10; // → instr_sram（逐 word 写）

  // -----------------------------------------------------------------------
  // FSM 状态编码（3-bit，支持最多 8 个状态，当前用 6 个）
  // ST_IDLE  : 等待 START
  // ST_SETUP : 1 拍缓冲，addr_ptr 稳定
  // ST_RD0   : 读第 1 个 word（所有目标共用）
  // ST_RD1   : 读第 2 个 word（仅 INPUT_FIFO 使用）
  // ST_PUSH  : 将 64-bit 写入 input_fifo（仅 INPUT_FIFO 使用）
  // ST_WR    : 将单个 word 写入目标 SRAM（WEIGHT_BUF / INSTR_SRAM 使用）
  // -----------------------------------------------------------------------
  typedef enum logic [2:0] {
    ST_IDLE  = 3'd0,
    ST_SETUP = 3'd1,
    ST_RD0   = 3'd2,
    ST_RD1   = 3'd3,
    ST_PUSH  = 3'd4,
    ST_WR    = 3'd5
  } dma_state_t;

  dma_state_t state;

  // -----------------------------------------------------------------------
  // 内部寄存器
  // -----------------------------------------------------------------------
  logic [31:0] src_addr_reg;
  logic [31:0] len_words_reg;
  logic [1:0]  dst_sel_reg;    // DST_SEL 寄存器（默认 DST_INPUT_FIFO）
  logic [31:0] addr_ptr;       // 当前 SRAM 字节偏移（相对 data_sram 内部）
  logic [31:0] words_rem;      // 剩余 word 数
  logic [31:0] word0_reg;      // ST_RD0 捕获的第一个 word
  logic [31:0] word1_reg;      // ST_RD1 捕获的第二个 word（仅 INPUT_FIFO）

  logic done_sticky;
  logic err_sticky;
  // R-M2 fix（2026-05-02 audit）：FIFO 满时累积计数，超过阈值视为下游消费者
  // 卡死，set err_sticky + done_sticky 让 fw 看到 ERR 而不是永远 BUSY。
  logic [23:0] push_stall_cnt;

  // -----------------------------------------------------------------------
  // 预计算辅助信号
  // -----------------------------------------------------------------------
  logic [31:0] len_bytes;
  logic [31:0] end_addr;
  logic        addr_align_ok;
  logic        end_overflow;

  wire [7:0] addr_offset = req_addr[7:0];
  wire write_en = req_valid && req_write;
  wire _unused = &{1'b0, req_addr[31:8]};

  assign len_bytes    = len_words_reg << 2;
  assign end_addr     = src_addr_reg + len_bytes - 1'b1;
  assign addr_align_ok= (src_addr_reg[1:0] == 2'b00);
  assign end_overflow = (end_addr < src_addr_reg);

  // -----------------------------------------------------------------------
  // 寄存器写逻辑
  // -----------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      src_addr_reg <= 32'h0;
      len_words_reg<= 32'h0;
      dst_sel_reg  <= DST_INPUT_FIFO; // 默认目标：input_fifo
    end else begin
      if (write_en) begin
        case (addr_offset)
          REG_SRC_ADDR: begin
            if (req_wstrb[0]) src_addr_reg[7:0]   <= req_wdata[7:0];
            if (req_wstrb[1]) src_addr_reg[15:8]  <= req_wdata[15:8];
            if (req_wstrb[2]) src_addr_reg[23:16] <= req_wdata[23:16];
            if (req_wstrb[3]) src_addr_reg[31:24] <= req_wdata[31:24];
          end
          REG_LEN_WORDS: begin
            if (req_wstrb[0]) len_words_reg[7:0]   <= req_wdata[7:0];
            if (req_wstrb[1]) len_words_reg[15:8]  <= req_wdata[15:8];
            if (req_wstrb[2]) len_words_reg[23:16] <= req_wdata[23:16];
            if (req_wstrb[3]) len_words_reg[31:24] <= req_wdata[31:24];
          end
          REG_DST_SEL: begin
            // DST_SEL 只允许在空闲态更新，避免一次 DMA 进行中途切换目标。
            if (req_wstrb[0] && (state == ST_IDLE)) dst_sel_reg <= req_wdata[1:0];
          end
          default: begin
            // REG_DMA_CTRL 的 START/DONE/ERR 由 FSM 处理
          end
        endcase
      end
    end
  end

  // -----------------------------------------------------------------------
  // DMA 主 FSM
  // -----------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= ST_IDLE;
      addr_ptr    <= 32'h0;
      words_rem   <= 32'h0;
      word0_reg   <= 32'h0;
      word1_reg   <= 32'h0;
      done_sticky    <= 1'b0;
      err_sticky     <= 1'b0;
      push_stall_cnt <= 24'd0;  // R-M2 fix
    end else begin
      // ── W1C 清零 ──────────────────────────────────────────────────────
      if (write_en && (addr_offset == REG_DMA_CTRL) && req_wstrb[0]) begin
        if (req_wdata[1]) done_sticky <= 1'b0;
        if (req_wdata[2]) err_sticky  <= 1'b0;
      end

      case (state)
        // ── IDLE ──────────────────────────────────────────────────────────
        ST_IDLE: begin
          if (write_en && (addr_offset == REG_DMA_CTRL) && req_wstrb[0] && req_wdata[0]) begin
            // INPUT_FIFO 要求偶数长度；其他目标无此限制
            if (dst_sel_reg == 2'b11) begin
              err_sticky  <= 1'b1;
              done_sticky <= 1'b1;
              state       <= ST_IDLE;
            end else if (len_words_reg[0] && (dst_sel_reg == DST_INPUT_FIFO)) begin
              err_sticky  <= 1'b1;
              done_sticky <= 1'b1;
              state       <= ST_IDLE;
            end else if (len_words_reg == 0) begin
              done_sticky <= 1'b1;
              state       <= ST_IDLE;
            end else begin
              if (!addr_align_ok) begin
                err_sticky  <= 1'b1;
                done_sticky <= 1'b1;
                state       <= ST_IDLE;
              end else if ((src_addr_reg < ADDR_DATA_BASE) || end_overflow ||
                           (end_addr > ADDR_DATA_END)) begin
                err_sticky  <= 1'b1;
                done_sticky <= 1'b1;
                state       <= ST_IDLE;
              end else begin
                done_sticky <= 1'b0;
                err_sticky  <= 1'b0;
                addr_ptr    <= src_addr_reg - ADDR_DATA_BASE;
                words_rem   <= len_words_reg;
                state       <= ST_SETUP;
              end
            end
          end
        end

        // ── SETUP ─────────────────────────────────────────────────────────
        ST_SETUP: begin
          state <= ST_RD0;
        end

        // ── RD0：读第 1 个 word ──────────────────────────────────────────
        // 所有目标共用此状态。
        // 读完后：INPUT_FIFO → RD1；SRAM 目标 → WR
        ST_RD0: begin
          word0_reg <= dma_rd_data;
          addr_ptr  <= addr_ptr + 32'd4;
          if (dst_sel_reg == DST_INPUT_FIFO)
            state <= ST_RD1;
          else
            state <= ST_WR;
        end

        // ── RD1：读第 2 个 word（仅 INPUT_FIFO）─────────────────────────
        ST_RD1: begin
          word1_reg <= dma_rd_data;
          addr_ptr  <= addr_ptr + 32'd4;
          state     <= ST_PUSH;
        end

        // ── PUSH：64-bit 写入 input_fifo（仅 INPUT_FIFO）────────────────
        ST_PUSH: begin
          if (!in_fifo_full) begin
            words_rem <= words_rem - 32'd2;
            push_stall_cnt <= 24'd0;  // 命中一次有效 push 就清零 stall 计数
            if (words_rem == 32'd2) begin
              done_sticky <= 1'b1;
              state       <= ST_IDLE;
            end else begin
              state <= ST_RD0;
            end
          end else begin
            // R-M2 fix（2026-05-02 audit）：FIFO 满时不再无限期原地等待。
            // 累计 push_stall_cnt；超过 V2B_DMA_PUSH_TIMEOUT_CYCLES 视为
            // 下游消费者卡死（CIM 推理 hang / FIFO drain 永不发生），
            // 设 err_sticky + done_sticky 让 fw 看到 ERR 而不是永远 BUSY。
            // 流片影响：硅片如果 fifo 卡住，fw polling DONE 永远不归 1 →
            // fw 必须有 timeout 路径处理；不修则系统级死锁无可见错误。
            push_stall_cnt <= push_stall_cnt + 24'd1;
            if (push_stall_cnt >= 24'(V2B_DMA_PUSH_TIMEOUT_CYCLES)) begin
              err_sticky  <= 1'b1;
              done_sticky <= 1'b1;
              state       <= ST_IDLE;
            end
          end
        end

        // ── WR：写单个 word 到目标 SRAM（WEIGHT_BUF / INSTR_SRAM）────────
        // 写使能由下方组合块驱动；同步写在本拍 posedge 完成。
        ST_WR: begin
          words_rem <= words_rem - 32'd1;
          if (words_rem == 32'd1) begin
            done_sticky <= 1'b1;
            state       <= ST_IDLE;
          end else begin
            state <= ST_RD0;
          end
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

  // -----------------------------------------------------------------------
  // data_sram 读端口组合逻辑
  // RD0 和 RD1 均需读（INPUT_FIFO 两者都用；SRAM 目标只用 RD0）
  // -----------------------------------------------------------------------
  always_comb begin
    dma_rd_en   = 1'b0;
    dma_rd_addr = addr_ptr;
    case (state)
      ST_RD0, ST_RD1: begin
        dma_rd_en   = 1'b1;
        dma_rd_addr = addr_ptr;
      end
      default: dma_rd_en = 1'b0;
    endcase
  end

  // -----------------------------------------------------------------------
  // input_fifo push 组合逻辑（DST_INPUT_FIFO 专用）
  // -----------------------------------------------------------------------
  always_comb begin
    in_fifo_push = 1'b0;
    in_fifo_wdata= '0;
    if (state == ST_PUSH && !in_fifo_full) begin
      in_fifo_push  = 1'b1;
      in_fifo_wdata = {word1_reg, word0_reg};
    end
  end

  // -----------------------------------------------------------------------
  // SRAM DMA 写端口组合逻辑（ST_WR 时对应目标拉高 wr_en）
  //
  // 写地址：addr_ptr 在 ST_RD0 末尾已自增 4，因此本次写的 SRAM 偏移
  //         = addr_ptr - 4（即刚才读出 word0_reg 的位置）。
  // 写数据：word0_reg（ST_RD0 捕获）。
  // 字节使能：全字写（4'hF）。
  //
  // 【面试 / review 留意】"addr_ptr - 4" 这种"看着像负向修正"的表达式
  // 容易被 reviewer 误报为 off-by-one bug（CLAUDE.md 误报库 FP-003）。
  // 这里的 -4 不是 bug，而是阻塞/非阻塞赋值的时序补偿：
  //   - ST_RD0 内 addr_ptr 用 <= 自增 4（非阻塞），下一拍才生效；
  //   - ST_WR 同拍读 addr_ptr 拿到的是"已经自增过"的值；
  //   - 但要写的是上一拍 RD0 抓回 word0_reg 时对应的 SRAM 偏移；
  //   - 所以 -4 把 addr_ptr 还原到那一笔读地址。
  // 改 RTL 时不要轻易动这个 -4：如果改 ST_RD0 的 addr_ptr 自增时机或
  // 阻塞性，必须同步改这里的常量；只改一边就会让 dst SRAM 写到错误偏移。
  // -----------------------------------------------------------------------
  always_comb begin
    weight_wr_en   = 1'b0;
    weight_wr_addr = addr_ptr - 32'd4;
    weight_wr_data = word0_reg;
    weight_wr_strb = 4'hF;

    instr_wr_en   = 1'b0;
    instr_wr_addr = addr_ptr - 32'd4;
    instr_wr_data = word0_reg;
    instr_wr_strb = 4'hF;

    if (state == ST_WR) begin
      case (dst_sel_reg)
        DST_WEIGHT_BUF: weight_wr_en = 1'b1;
        DST_INSTR_SRAM: instr_wr_en  = 1'b1;
        default: ; // DST_INPUT_FIFO 不用 SRAM 写端口
      endcase
    end
  end

  // -----------------------------------------------------------------------
  // 寄存器读回
  // -----------------------------------------------------------------------
  always_comb begin
    rdata = 32'h0;
    case (addr_offset)
      REG_SRC_ADDR:  rdata = src_addr_reg;
      REG_LEN_WORDS: rdata = len_words_reg;
      REG_DMA_CTRL: begin
        rdata[1] = done_sticky;
        rdata[2] = err_sticky;
        rdata[3] = (state != ST_IDLE);
      end
      REG_DST_SEL:   rdata = {30'h0, dst_sel_reg};
      default: rdata = 32'h0;
    endcase
  end

`ifndef SYNTHESIS
`ifdef VCS
  // -------------------------------------------------------------------
  // SVA 并发断言（仅 VCS；Icarus -gno-assertions 跳过）
  // B1  in_fifo_push 仅在 ST_PUSH 且 FIFO 非满
  // B2  dma_rd_en 仅在 ST_RD0/ST_RD1
  // B3  IDLE 无 push/rd_en
  // B4  err_sticky 置位时 done_sticky 同时置位
  // B5  weight_wr_en 仅在 ST_WR 且 DST_WEIGHT_BUF
  // B6  instr_wr_en  仅在 ST_WR 且 DST_INSTR_SRAM
  // -------------------------------------------------------------------
  property p_push_in_st_push;
    @(posedge clk) disable iff (!rst_n)
    in_fifo_push |-> (state == ST_PUSH);
  endproperty
  property p_push_no_full;
    @(posedge clk) disable iff (!rst_n)
    in_fifo_push |-> !in_fifo_full;
  endproperty
  property p_rd_in_rd_states;
    @(posedge clk) disable iff (!rst_n)
    dma_rd_en |-> (state == ST_RD0 || state == ST_RD1);
  endproperty
  property p_idle_quiet;
    @(posedge clk) disable iff (!rst_n)
    (state == ST_IDLE) |-> (!in_fifo_push && !dma_rd_en);
  endproperty
  property p_err_with_done;
    @(posedge clk) disable iff (!rst_n)
    $rose(err_sticky) |-> done_sticky;
  endproperty
  property p_weight_wr_in_wt;
    @(posedge clk) disable iff (!rst_n)
    weight_wr_en |-> (state == ST_WR && dst_sel_reg == DST_WEIGHT_BUF);
  endproperty
  property p_instr_wr_in_wt;
    @(posedge clk) disable iff (!rst_n)
    instr_wr_en |-> (state == ST_WR && dst_sel_reg == DST_INSTR_SRAM);
  endproperty
  property p_dst_sel_write_idle_only;
    @(posedge clk) disable iff (!rst_n)
    (write_en && addr_offset == REG_DST_SEL && req_wstrb[0] && state != ST_IDLE) |=> $stable(dst_sel_reg);
  endproperty

  a_push_in_push:  assert property (p_push_in_st_push)  else $error("[dma] in_fifo_push 非 ST_PUSH");
  a_push_no_full:  assert property (p_push_no_full)      else $error("[dma] push when FIFO full");
  a_rd_in_rd:      assert property (p_rd_in_rd_states)   else $error("[dma] dma_rd_en 非 ST_RD0/RD1");
  a_idle_quiet:    assert property (p_idle_quiet)         else $error("[dma] IDLE 产生 push/rd_en");
  a_err_done:      assert property (p_err_with_done)      else $error("[dma] err 未同时置 done");
  a_weight_wr:     assert property (p_weight_wr_in_wt)    else $error("[dma] weight_wr_en 状态错误");
  a_instr_wr:      assert property (p_instr_wr_in_wt)     else $error("[dma] instr_wr_en 状态错误");
  a_dst_sel_idle:  assert property (p_dst_sel_write_idle_only) else $error("[dma] dst_sel_reg changed while busy");
`endif
`endif

endmodule
