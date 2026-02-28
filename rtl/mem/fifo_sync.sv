// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/mem/fifo_sync.sv
// Purpose: Generic synchronous FIFO used for input/output event buffering.
// Role in system: Absorbs rate mismatch between producer FSMs and consumer FSMs (DMA, LIF, readout path).
// Behavior summary: Single-clock FIFO with count/full/empty and sticky overflow/underflow pulse outputs.
// Timing model: Purely synchronous; write/read happen on the same clock domain.
// Integration note: Depth is parameterized and may be non-power-of-two (assertions should protect assumptions).
// Debug note: overflow/underflow outputs are often left unconnected in top-level unless explicitly monitored.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: fifo_sync.sv
// 描述: 同步 FIFO（单写单读）。
//       - push/pop 同步到 clk
//       - 提供 empty/full/count
//       - 当满时允许 pop+push 同拍通过，否则 push 丢弃并置 overflow
//       - 当空时 pop 不动作并置 underflow
//======================================================================
//
// -----------------------------------------------------------------------
// 功能概述：
//
//   这是一个参数化同步 FIFO，WIDTH 和 DEPTH 可配置。
//   在本 SoC 中有两处实例化：
//     - input_fifo  : WIDTH=NUM_INPUTS(=64), DEPTH=INPUT_FIFO_DEPTH（当前默认 256），DMA 向 SNN 主控送 bit-plane
//     - output_fifo : WIDTH=4（spike_id），DEPTH=OUTPUT_FIFO_DEPTH，LIF 向 CPU 输出
//
// -----------------------------------------------------------------------
// 读写行为（"first-word fall-through" / 组合读）：
//
//   rd_data = mem[rd_ptr]  ── 纯组合逻辑，始终有效（不需要 pop 才能读出）
//   当 FIFO 非空时，rd_data 立即呈现队头数据，消费者无需等待。
//   pop_fire 只推进 rd_ptr，不影响当前周期的 rd_data。
//
//   这与 "registered read" FIFO 不同：
//     * registered read: pop 后，下一拍 rd_data 才更新
//     * 本模块（fall-through）: rd_data 随 rd_ptr 组合更新，同拍可见
//
// -----------------------------------------------------------------------
// 关键设计：满状态下允许 push+pop 同拍（保持吞吐）
//
//   push_fire = push && (!full || pop)
//
//   含义：即使 FIFO 满（full=1），只要 pop 同拍也有效（pop=1，即同拍消费一个），
//   push_fire 仍为 1，允许推入新数据。这样不会因为 full 导致生产者停顿。
//
//   实现原理（count 保持一致）：
//     push_fire=1, pop_fire=1 → case {1,1} → count 不变（+1-1=0）
//     这正确：满时同拍 push+pop，count 保持 DEPTH。
//
//   对比：若 push_fire = push && !full（不允许满时 push）：
//     满时 pop+push 只有 pop_fire，count -= 1，下拍才能 push，吞吐率低。
//
// -----------------------------------------------------------------------
// overflow / underflow 语义（pulse，非 sticky）：
//
//   overflow  = push && full && !pop
//     → 试图推入但 FIFO 已满且无同拍弹出，数据丢失
//     → 注意：push && full && pop 时 push_fire=1，不算 overflow
//
//   underflow = pop && empty && !push
//     → 试图弹出但 FIFO 空且无同拍推入，弹出无效
//
//   两个信号都是 registered（在 always_ff 中赋值），反映上一拍的事件。
//   顶层（snn_soc_top）若需要 sticky 监控，需自行锁存。
//
// -----------------------------------------------------------------------
// 指针和 count 一致性：
//
//   wr_ptr：写指针，push_fire 时自增，范围 [ADDR_BITS-1:0]
//   rd_ptr：读指针，pop_fire 时自增，范围 [ADDR_BITS-1:0]
//   count ：当前存储的有效项数，范围 [0, DEPTH]
//
//   DEPTH 必须是 2 的幂次：确保指针自然绕回（ADDR_BITS 位加法溢出）。
//   若 DEPTH 不是 2 的幂，$fatal 在仿真初始化阶段报错。
//   例：DEPTH=16, ADDR_BITS=4 → wr_ptr 从 15 自增变为 0（4-bit 溢出）。
//
//   count 的 case 逻辑：
//     {push_fire, pop_fire} = 2'b10 → count+1 （只 push）
//     {push_fire, pop_fire} = 2'b01 → count-1 （只 pop）
//     default（00 或 11）           → count 不变 （双空操作或平衡操作）
//
// -----------------------------------------------------------------------
module fifo_sync #(
  parameter int WIDTH = 8,   // 每个 entry 的数据宽度（bit）
  parameter int DEPTH = 16   // FIFO 深度（entry 数，必须是 2 的幂次）
) (
  input  logic             clk,
  input  logic             rst_n,
  // 写端口
  input  logic             push,       // 推入请求（1=有效）
  input  logic [WIDTH-1:0] push_data,  // 推入数据
  // 读端口
  input  logic             pop,        // 弹出请求（1=有效，推进 rd_ptr）
  output logic [WIDTH-1:0] rd_data,    // 当前队头数据（组合输出，!empty 时有效）
  // 状态
  output logic             empty,      // 1 = FIFO 空
  output logic             full,       // 1 = FIFO 满
  output logic [$clog2(DEPTH+1)-1:0] count, // 当前存储 entry 数，范围 [0, DEPTH]
  // 错误脉冲（1 cycle pulse，反映上一拍的溢出/下溢事件）
  output logic             overflow,   // 1 = 上一拍有丢失 push（满且无 pop）
  output logic             underflow   // 1 = 上一拍有无效 pop（空且无 push）
);
  // -----------------------------------------------------------------------
  // 参数衍生常量
  // ADDR_BITS : 指针宽度，能寻址 DEPTH 个 entry（e.g. DEPTH=16 → ADDR_BITS=4）
  // COUNT_W   : count 信号宽度，需覆盖 [0, DEPTH]（e.g. DEPTH=16 → COUNT_W=5）
  // DEPTH_VAL : 将 DEPTH（int）转为 COUNT_W 宽的 logic，用于 full 比较
  // -----------------------------------------------------------------------
  localparam int ADDR_BITS = $clog2(DEPTH);
  localparam int COUNT_W   = $clog2(DEPTH+1);
  localparam logic [COUNT_W-1:0] DEPTH_VAL = COUNT_W'(DEPTH);

  // -----------------------------------------------------------------------
  // 仿真期间合法性断言（综合时跳过）
  //
  // 为什么 DEPTH 必须是 2 的幂次：
  //   wr_ptr 和 rd_ptr 是 ADDR_BITS 位计数器，依赖自然溢出绕回（0→max→0）。
  //   若 DEPTH 不是 2 的幂次，溢出绕回后指针值不对应 mem 数组边界，
  //   导致写入超出 mem 范围或 count 与实际不一致。
  //
  // $fatal(1, ...) 在仿真初始化（elaboration 阶段）立即终止，防止带病运行。
  // -----------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    if ((DEPTH & (DEPTH - 1)) != 0)
      $fatal(1, "[fifo_sync] DEPTH(%0d) must be power of 2 for pointer wrap-around", DEPTH);
    if (DEPTH == 0)
      $fatal(1, "[fifo_sync] DEPTH must be > 0");
  end
`endif

  // -----------------------------------------------------------------------
  // 内部存储阵列与指针
  // mem      : DEPTH 个 WIDTH-bit entry 的寄存器数组
  // rd_ptr   : 读指针，指向下一个要被读出的 entry
  // wr_ptr   : 写指针，指向下一个要写入的位置
  // -----------------------------------------------------------------------
  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [ADDR_BITS-1:0] rd_ptr;
  logic [ADDR_BITS-1:0] wr_ptr;

  // -----------------------------------------------------------------------
  // 实际有效的 push/pop 信号（"fire" = 请求且条件满足）
  //
  // push_fire = push && (!full || pop)
  //   → 非满时直接允许；满时仅当同拍有 pop 才允许（保持吞吐，不丢数据）
  //   → 若满且无 pop 时 push=1，则 push_fire=0，同时 overflow 被标记
  //
  // pop_fire = pop && !empty
  //   → 非空时允许弹出；空时 pop 无效，underflow 被标记
  // -----------------------------------------------------------------------
  // 允许 full+pop 同拍时的 push（保持吞吐）
  wire push_fire = push && (!full || pop);
  wire pop_fire  = pop && !empty;

  // -----------------------------------------------------------------------
  // 状态标志（组合逻辑）
  //
  // empty : count == 0（无数据）
  // full  : count == DEPTH（存满）
  // rd_data: mem[rd_ptr] 组合读出（first-word fall-through）
  //   - 当 empty=0 时有效，消费者不需要额外等待
  //   - 当 empty=1 时 rd_data 为 mem[rd_ptr] 的当前值，意义不明，应忽略
  // -----------------------------------------------------------------------
  assign empty = (count == '0);
  assign full  = (count == DEPTH_VAL);
  assign rd_data = mem[rd_ptr]; // 组合读（fall-through）：rd_ptr 一变，rd_data 立即更新

  // -----------------------------------------------------------------------
  // 主时序逻辑：指针推进、count 更新、overflow/underflow 检测
  // -----------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_ptr   <= '0;
      wr_ptr   <= '0;
      count    <= '0;
      overflow <= 1'b0;
      underflow<= 1'b0;
    end else begin
      // ── overflow/underflow 检测（1 cycle pulse，反映本拍请求）──────
      // overflow: push 试图写入，但 FIFO 已满且同拍没有 pop，数据被丢弃
      overflow  <= push && full && !pop;
      // underflow: pop 试图读出，但 FIFO 为空且同拍没有 push，弹出无效
      underflow <= pop && empty && !push;

      // ── 写入（push_fire=1 时推进 wr_ptr）────────────────────────────
      if (push_fire) begin
        mem[wr_ptr] <= push_data; // 写入当前写指针位置
        wr_ptr <= wr_ptr + 1'b1; // 写指针自增（ADDR_BITS 位自然溢出绕回）
      end

      // ── 弹出（pop_fire=1 时推进 rd_ptr）─────────────────────────────
      if (pop_fire) begin
        rd_ptr <= rd_ptr + 1'b1; // 读指针自增（rd_data 组合读，rd_ptr 一变即更新）
      end

      // ── count 更新（4 种 push_fire/pop_fire 组合）────────────────────
      // 2'b10 (push 无 pop) : count +1
      // 2'b01 (pop 无 push) : count -1
      // 2'b00 (均无操作)     : count 不变
      // 2'b11 (同拍 push+pop): count 不变（+1-1 抵消，维持满状态或中间状态）
      case ({push_fire, pop_fire})
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: count <= count; // 2'b00 无操作；2'b11 平衡操作，count 不变
      endcase
    end
  end
endmodule
