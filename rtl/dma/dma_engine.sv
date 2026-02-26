// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/dma/dma_engine.sv
// Purpose: Moves packed input words from source memory to input FIFO using a dedicated FSM.
// Role in system: Offloads repetitive data feeding so CPU/testbench does not write one pixel/bit-plane item at a time.
// Behavior summary: Register-programmed source address/length, reads words, repacks/pushes FIFO entries, exposes status bits.
// Current scope: Lightweight MVP DMA (single source path / no generic memory-to-memory burst engine yet).
// Important for later: This module is the natural insertion point for multi-destination DMA extensions in V1/V2.
// Review hints: Watch packing width assumptions vs NUM_INPUTS and FIFO backpressure handling.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: dma_engine.sv
// 描述: 最小 DMA 引擎：data_sram -> input_fifo。
//       - DMA_SRC_ADDR  指向 data_sram 源地址（byte 地址）
//       - DMA_LEN_WORDS 以 32-bit word 计数，必须为偶数
//       - DMA_CTRL: bit0 START(W1P), bit1 DONE(W1C), bit2 ERR(W1C), bit3 BUSY(RO)
//       - 每 2 个 word 拼成 1 个 64-bit wl_bitmap（NUM_INPUTS=64）
//======================================================================
// NOTE: DMA_SRC_ADDR 为 SoC 物理地址；内部会减去 ADDR_DATA_BASE 转为 SRAM 偏移。
//       需 4B 对齐，且 [SRC, SRC+LEN-1] 不能越过 data_sram 边界。
//
// -------------------------------------------------------------------------
// 寄存器地址映射（相对于模块被挂载的 base，即 0x4000_0100）：
//   offset 0x00 = REG_SRC_ADDR  : DMA 源起始字节地址（物理地址，需 4B 对齐）
//   offset 0x04 = REG_LEN_WORDS : 传输长度（以 32-bit word 计，必须为偶数）
//   offset 0x08 = REG_DMA_CTRL  :
//       bit[0] = START  (W1P) 写 1 启动 DMA，自动清零
//       bit[1] = DONE   (W1C) 传输完成标志，写 1 清零
//       bit[2] = ERR    (W1C) 错误标志（奇数长度/未对齐/越界），写 1 清零
//       bit[3] = BUSY   (RO)  DMA 非 IDLE 状态时为 1
// -------------------------------------------------------------------------
//
// 5 状态 FSM 流转图：
//
//   ST_IDLE  ──(START W1P)──> ST_SETUP
//                              │  (1 拍等待 addr_ptr 稳定)
//                              v
//                           ST_RD0  ─── 读 word0 @ addr_ptr（组合 SRAM 读，零延迟）
//                              │         word0_reg <= dma_rd_data，addr_ptr += 4
//                              v
//                           ST_RD1  ─── 读 word1 @ addr_ptr（组合 SRAM 读，零延迟）
//                              │         word1_reg <= dma_rd_data，addr_ptr += 4
//                              v
//                           ST_PUSH ─── 若 FIFO 未满：拼 {word1_reg, word0_reg} 写入 FIFO
//                              │         words_rem -= 2
//                              │─── 若 words_rem == 2：ST_IDLE（done_sticky=1）
//                              └─── 否则：ST_RD0（继续下一对 word）
//
// 边界异常（在 ST_IDLE 内检测，不进入 ST_SETUP）：
//   - 奇数长度   → err_sticky=1, done_sticky=1, 留 ST_IDLE
//   - 零长度     → done_sticky=1,              留 ST_IDLE
//   - 未对齐地址 → err_sticky=1, done_sticky=1, 留 ST_IDLE
//   - 地址越界   → err_sticky=1, done_sticky=1, 留 ST_IDLE
//
// 零延迟 SRAM 读：sram_simple_dp 的 DMA 端口是纯组合逻辑读，
//   dma_rd_data 在同一周期内与 dma_rd_addr 对应，无需额外等待周期。
//   因此 ST_RD0 进入时读出 word0，下一拍 ST_RD1 进入时读出 word1。
//
// FIFO 背压：ST_PUSH 会持续等待，直到 in_fifo_full 撤低。
//   等待期间 addr_ptr/word0_reg/word1_reg 保持不变，安全重入。
// -------------------------------------------------------------------------
module dma_engine (
  input  logic        clk,
  input  logic        rst_n,

  // 简化总线接口（地址为 offset）
  // req_addr[7:0] 为寄存器偏移，高位忽略（见 _unused lint 处理）
  input  logic        req_valid,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  output logic [31:0] rdata,

  // data_sram 只读 DMA 端口
  // 注意：dma_rd_data 是零延迟组合读，addr 稳定时 data 立即有效
  output logic        dma_rd_en,
  output logic [31:0] dma_rd_addr,
  input  logic [31:0] dma_rd_data,

  // input_fifo 写端口
  // in_fifo_wdata 宽度 = NUM_INPUTS = 64 bits（来自 snn_soc_pkg）
  output logic                          in_fifo_push,
  output logic [snn_soc_pkg::NUM_INPUTS-1:0] in_fifo_wdata,
  input  logic                          in_fifo_full
);
  import snn_soc_pkg::*;

  // -----------------------------------------------------------------------
  // 寄存器偏移常量（相对于本模块挂载基址）
  // REG_SRC_ADDR  = 0x00 → 写入 DMA 源地址（物理字节地址）
  // REG_LEN_WORDS = 0x04 → 写入传输字数（32-bit word，必须偶数）
  // REG_DMA_CTRL  = 0x08 → START(W1P)/DONE(W1C)/ERR(W1C)/BUSY(RO)
  // -----------------------------------------------------------------------
  localparam logic [7:0] REG_SRC_ADDR = 8'h00;
  localparam logic [7:0] REG_LEN_WORDS= 8'h04;
  localparam logic [7:0] REG_DMA_CTRL = 8'h08;

  // -----------------------------------------------------------------------
  // FSM 状态编码（3-bit，支持最多 8 个状态，当前用 5 个）
  // ST_IDLE  : 等待 START 写 1 触发
  // ST_SETUP : 1 拍缓冲，使 addr_ptr 在 SRAM 地址线上稳定
  // ST_RD0   : 读第 1 个 word（addr_ptr 当前值）
  // ST_RD1   : 读第 2 个 word（addr_ptr 已自增 4 字节）
  // ST_PUSH  : 将 {word1_reg, word0_reg} 拼成 64 bit 写入 input_fifo
  // -----------------------------------------------------------------------
  typedef enum logic [2:0] {
    ST_IDLE  = 3'd0,
    ST_SETUP = 3'd1,
    ST_RD0   = 3'd2,
    ST_RD1   = 3'd3,
    ST_PUSH  = 3'd4
  } dma_state_t;

  dma_state_t state;

  // -----------------------------------------------------------------------
  // 内部寄存器说明
  // src_addr_reg  : CPU 写入的 DMA 源起始字节地址（物理地址）
  // len_words_reg : CPU 写入的传输字数
  // addr_ptr      : 当前读取指针（SRAM 内部偏移 = 物理地址 - ADDR_DATA_BASE）
  // words_rem     : 剩余未读 word 数，每次完成一对 word 后减 2
  // word0_reg     : ST_RD0 捕获的第一个 word 暂存
  // word1_reg     : ST_RD1 捕获的第二个 word 暂存
  // done_sticky   : 传输完成标志（W1C；snn_done_pulse 等效于 DMA 的 done）
  // err_sticky    : 传输错误标志（W1C）
  // -----------------------------------------------------------------------
  logic [31:0] src_addr_reg;
  logic [31:0] len_words_reg;
  logic [31:0] addr_ptr;
  logic [31:0] words_rem;
  logic [31:0] word0_reg;
  logic [31:0] word1_reg;

  logic done_sticky;
  logic err_sticky;

  // -----------------------------------------------------------------------
  // 预计算辅助信号（全为组合逻辑）
  // len_bytes    : 字节数 = len_words_reg × 4（左移 2 位等价乘 4）
  // end_addr     : 最后一个字节的物理地址（含），用于边界检查
  // addr_align_ok: src_addr 低 2 位必须为 0（4B 对齐）
  // end_overflow : 若 end_addr 绕回小于 src_addr，说明 32-bit 加法溢出
  // -----------------------------------------------------------------------
  logic [31:0] len_bytes;
  logic [31:0] end_addr;
  logic        addr_align_ok;
  logic        end_overflow;

  // addr_offset 仅取低 8 位用于寄存器解码；高位通过 _unused 消除 lint 警告
  wire [7:0] addr_offset = req_addr[7:0];
  // write_en: 总线有效且为写操作时拉高，用于所有写判断
  wire write_en = req_valid && req_write;
  // 标记未使用高位（lint 友好）
  wire _unused = &{1'b0, req_addr[31:8]};

  // len_bytes = len_words_reg * 4（word 数转字节数）
  assign len_bytes    = len_words_reg << 2;
  // end_addr = 最后一个有效字节地址 = src + 字节数 - 1
  assign end_addr     = src_addr_reg + len_bytes - 1'b1;
  // 4B 对齐检查：字节地址低 2 位必须为 00
  assign addr_align_ok= (src_addr_reg[1:0] == 2'b00);
  // 32-bit 溢出检查：若 end_addr 回绕（< src），说明长度超出地址空间
  assign end_overflow = (end_addr < src_addr_reg);

  // -----------------------------------------------------------------------
  // 寄存器写逻辑：CPU 配置 DMA 源地址和传输长度
  // 使用字节使能（req_wstrb）支持非全字写（虽然 TB 通常用 4'hF 全写）
  // 注意：只有 IDLE 状态下写才安全；运行期间写寄存器行为未定义
  // -----------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      src_addr_reg <= 32'h0;
      len_words_reg<= 32'h0;
    end else begin
      if (write_en) begin
        case (addr_offset)
          REG_SRC_ADDR: begin
            // 字节使能写入：每个字节独立受 wstrb 控制
            if (req_wstrb[0]) src_addr_reg[7:0]   <= req_wdata[7:0];
            if (req_wstrb[1]) src_addr_reg[15:8]  <= req_wdata[15:8];
            if (req_wstrb[2]) src_addr_reg[23:16] <= req_wdata[23:16];
            if (req_wstrb[3]) src_addr_reg[31:24] <= req_wdata[31:24];
          end
          REG_LEN_WORDS: begin
            // 字节使能写入：全字写时 wstrb=4'hF
            if (req_wstrb[0]) len_words_reg[7:0]   <= req_wdata[7:0];
            if (req_wstrb[1]) len_words_reg[15:8]  <= req_wdata[15:8];
            if (req_wstrb[2]) len_words_reg[23:16] <= req_wdata[23:16];
            if (req_wstrb[3]) len_words_reg[31:24] <= req_wdata[31:24];
          end
          default: begin
            // REG_DMA_CTRL 的 START/DONE/ERR W1P/W1C 由 FSM 处理，不在此写
          end
        endcase
      end
    end
  end

  // -----------------------------------------------------------------------
  // DMA 状态机主体
  //
  // 设计要点：
  //   1. W1C 清零（DONE/ERR）放在 always_ff 开头，早于 case 语句执行。
  //      同一拍若 START 也被写入，case 中会覆盖 done_sticky/err_sticky。
  //      这符合"先清后置"语义，保证时序正确。
  //
  //   2. SRAM 读口是零延迟组合读（sram_simple_dp DMA 端口）。
  //      因此 ST_RD0 进入时，dma_rd_data 已经对应 addr_ptr，
  //      可以直接在同拍末尾用时序赋值捕获到 word0_reg。
  //      下一拍 addr_ptr 已加 4，ST_RD1 捕获 word1_reg，同理。
  //
  //   3. ST_PUSH 等待背压：若 FIFO 满，原地等待，不推进计数。
  //      此时 word0_reg/word1_reg/addr_ptr 均已定值，无副作用。
  // -----------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= ST_IDLE;
      addr_ptr    <= 32'h0;
      words_rem   <= 32'h0;
      word0_reg   <= 32'h0;
      word1_reg   <= 32'h0;
      // dma_rd_addr 由组合逻辑驱动，无需时序赋值
      done_sticky <= 1'b0;
      err_sticky  <= 1'b0;
    end else begin
      // ── W1C 清零（DONE bit[1]、ERR bit[2]）──────────────────────────
      // 写 1 to bit 位即清零对应 sticky；如果同时有 START，见下方 case 处理
      if (write_en && (addr_offset == REG_DMA_CTRL)) begin
        if (req_wdata[1]) done_sticky <= 1'b0;
        if (req_wdata[2]) err_sticky  <= 1'b0;
      end

      case (state)
        // ── IDLE：等待 START W1P ──────────────────────────────────────
        ST_IDLE: begin
          if (write_en && (addr_offset == REG_DMA_CTRL) && req_wdata[0]) begin
            // START W1P（bit[0]=1）：进行合法性检查后决定是否启动
            if (len_words_reg[0]) begin
              // 奇数长度：无法组成整数个 64-bit 对，报错
              err_sticky  <= 1'b1;
              done_sticky <= 1'b1;
              state       <= ST_IDLE;
            end else if (len_words_reg == 0) begin
              // 零长度：无需传输，直接置 done（不报错）
              done_sticky <= 1'b1;
              state       <= ST_IDLE;
            end else begin
              // normal start：进行地址合法性检查
              if (!addr_align_ok) begin
                // 未对齐：字节地址低 2 位非 0
                err_sticky  <= 1'b1;
                done_sticky <= 1'b1;
                state       <= ST_IDLE;
              end else if ((src_addr_reg < ADDR_DATA_BASE) || end_overflow || (end_addr > ADDR_DATA_END)) begin
                // 越界：起始地址低于 data_sram 基址，或结束地址超出 data_sram 末尾，
                //         或 32-bit 加法溢出（end_overflow）
                err_sticky  <= 1'b1;
                done_sticky <= 1'b1;
                state       <= ST_IDLE;
              end else begin
                // 所有检查通过：清除旧状态，初始化指针，进入 SETUP
                done_sticky <= 1'b0;
                err_sticky  <= 1'b0;
                // 转换物理地址为 SRAM 内部偏移（以字节为单位）
                // ADDR_DATA_BASE 来自 snn_soc_pkg，是 data_sram 的物理起始地址
                addr_ptr    <= src_addr_reg - ADDR_DATA_BASE;
                words_rem   <= len_words_reg;
                state       <= ST_SETUP;
              end
            end
          end
        end

        // ── SETUP：空等 1 拍 ─────────────────────────────────────────
        // addr_ptr 在上一拍（ST_IDLE）被写入，需要 1 个时钟沿传播到
        // 组合 SRAM 地址输入，确保 ST_RD0 进入时地址已稳定。
        ST_SETUP: begin
          // 空等 1 拍，确保 addr_ptr 稳定
          state <= ST_RD0;
        end

        // ── RD0：读第 1 个 word（低 32 bit）─────────────────────────
        // 此时 dma_rd_en=1, dma_rd_addr=addr_ptr（由下面组合块驱动）。
        // sram_simple_dp DMA 端口是零延迟组合读，dma_rd_data 在本周期末即有效。
        // word0_reg 捕获 word0，addr_ptr 自增 4 准备读 word1。
        ST_RD0: begin
          // 读 word0
          word0_reg   <= dma_rd_data;   // 捕获当前地址的 32-bit 数据（低半 64-bit）
          addr_ptr    <= addr_ptr + 32'd4; // 指向下一个 word（字节偏移 +4）
          state       <= ST_RD1;
        end

        // ── RD1：读第 2 个 word（高 32 bit）─────────────────────────
        // addr_ptr 已是 word1 地址，dma_rd_data 即为 word1。
        // 捕获后再自增 4，为下一对 word 的读取做准备。
        ST_RD1: begin
          // 读 word1
          word1_reg   <= dma_rd_data;   // 捕获当前地址的 32-bit 数据（高半 64-bit）
          addr_ptr    <= addr_ptr + 32'd4; // 指向下下个 word（字节偏移 +4）
          state       <= ST_PUSH;
        end

        // ── PUSH：拼 64 bit 写入 FIFO ────────────────────────────────
        // {word1_reg, word0_reg} 构成一个完整的 NUM_INPUTS(=64)-bit wl_bitmap。
        // in_fifo_push 和 in_fifo_wdata 由下面的组合块驱动。
        // 若 FIFO 满，原地等待，不推进计数和状态。
        ST_PUSH: begin
          if (!in_fifo_full) begin
            // push 一个 NUM_INPUTS-bit wl_bitmap（64-bit）
            words_rem <= words_rem - 32'd2; // 每次消耗两个 word
            if (words_rem == 32'd2) begin
              // 这是最后一对 word，传输完成
              done_sticky <= 1'b1;
              state       <= ST_IDLE;
            end else begin
              // 还有更多 word 对，继续读取
              state       <= ST_RD0;
            end
          end
          // 若 in_fifo_full==1，保持在 ST_PUSH，等待 FIFO 腾出空间
        end
        // ── 防御性默认分支：异常状态回归 IDLE ────────────────────────
        default: state <= ST_IDLE;
      endcase
    end
  end

  // -----------------------------------------------------------------------
  // DMA 读端口组合逻辑
  //
  // dma_rd_en  : 只在 ST_RD0 和 ST_RD1 拉高，其他状态 SRAM DMA 端口休眠。
  // dma_rd_addr: 直接输出 addr_ptr（SRAM 内部字节偏移）。
  //              SRAM 内部再右移 2 位转换为 word 地址（见 sram_simple_dp）。
  //
  // 为什么 dma_rd_addr 默认也赋 addr_ptr（而不是 0）：
  //   非读状态下 dma_rd_en=0，SRAM 忽略地址输入，addr_ptr 赋值无副作用，
  //   但保持 addr_ptr 可以简化后续切换时的时序（避免不必要的地址跳变）。
  // -----------------------------------------------------------------------
  always_comb begin
    dma_rd_en   = 1'b0;
    dma_rd_addr = addr_ptr; // 默认值（SRAM 在 rd_en=0 时忽略此地址）
    case (state)
      ST_RD0, ST_RD1: begin
        dma_rd_en   = 1'b1;   // 使能 SRAM DMA 端口读
        dma_rd_addr = addr_ptr; // 当前字节偏移
      end
      default: begin
        dma_rd_en   = 1'b0;   // 非读状态：关闭 DMA 端口
      end
    endcase
  end

  // -----------------------------------------------------------------------
  // FIFO push 数据拼接组合逻辑
  //
  // 只有在 ST_PUSH 且 FIFO 未满时才发出 push。
  // in_fifo_wdata = {word1_reg[31:0], word0_reg[31:0]} = 64 bit
  //   bit[31:0]  来自 word0（先读的低地址 word，对应 wl_bitmap 低 32 位）
  //   bit[63:32] 来自 word1（后读的高地址 word，对应 wl_bitmap 高 32 位）
  // 这与 TB 写入 SRAM 时的字节序一致：word0 写 plane_vec[31:0]，
  //                                      word1 写 plane_vec[63:32]。
  // -----------------------------------------------------------------------
  always_comb begin
    in_fifo_push = 1'b0;
    in_fifo_wdata= '0;
    if (state == ST_PUSH && !in_fifo_full) begin
      in_fifo_push  = 1'b1;
      in_fifo_wdata = {word1_reg, word0_reg}; // 64-bit wl_bitmap 拼接
    end
  end

  // -----------------------------------------------------------------------
  // 寄存器读回（组合逻辑，无流水线延迟）
  //
  // REG_SRC_ADDR  : 直接返回 CPU 写入的源地址（帮助 SW 调试）
  // REG_LEN_WORDS : 直接返回 CPU 写入的传输字数
  // REG_DMA_CTRL  :
  //   bit[0] = START (只写 W1P，读回固定 0；写时硬件不锁存此位)
  //   bit[1] = DONE  (done_sticky，传输完成后为 1；W1C 清零)
  //   bit[2] = ERR   (err_sticky，出错后为 1；W1C 清零)
  //   bit[3] = BUSY  (state != ST_IDLE 时为 1，实时反映 FSM 状态)
  // -----------------------------------------------------------------------
  // DMA_CTRL 读回
  always_comb begin
    rdata = 32'h0;
    case (addr_offset)
      REG_SRC_ADDR:  rdata = src_addr_reg;
      REG_LEN_WORDS: rdata = len_words_reg;
      REG_DMA_CTRL: begin
        rdata[1] = done_sticky;        // bit[1]: DONE（传输完成，W1C）
        rdata[2] = err_sticky;         // bit[2]: ERR（有错误，W1C）
        rdata[3] = (state != ST_IDLE); // bit[3]: BUSY（FSM 非空闲，只读）
      end
      default: rdata = 32'h0;
    endcase
  end
endmodule
