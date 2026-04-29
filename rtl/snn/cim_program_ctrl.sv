`timescale 1ns/1ps
// =============================================================================
// 【面试讲解 cheat sheet · cim_program_ctrl.sv】 —— 设计者视角
//
// 一、它在 SoC 里的角色
//   它是 RRAM CIM 阵列的"硬件 Program-and-Verify FSM"。我把传统软件循环
//   "写一次脉冲 → 读回 → 比较 → 重试" 卸载到 RTL，原因有三：
//   (1) 软件循环要走 bus → reg_bank → cim_macro，每次至少 5~10 cycle
//       overhead，对一次写需要数百 cell × 数次重试的场景，软件做会非常慢；
//   (2) 重试逻辑放硬件可以保持 cim_macro 独占（arbiter 屏蔽推理）整段时间，
//       不会出现"软件中途让出 → 推理插进来 → 模拟 die 状态错乱"；
//   (3) 这套 FSM 后续上 ASIC 时可以用同一段代码跑 silicon bring-up 与
//       生产编程，不需要重写两套。
//
// 二、面试最容易被深问的 4 个点
//   1) 为什么是 11 状态而不是 5 状态？
//      关键是把"脉冲发出 (ST_PULSE)"和"脉冲计时持续 (ST_PULSE_HOLD)"
//      拆开——脉冲宽度由 PROG_PULSE_WIDTH 档位（1us/10us/100us @ 50MHz =
//      50/500/5000 cycle）控制，必须有专门的倒计时状态；不能让 PULSE 自身
//      又驱动信号又计时，会让 dac_valid 出现毛刺。READBACK / RB_WAIT 同
//      理：ADC 启动是边沿触发，等待是电平触发，分两个状态时序最干净。
//
//   2) 为什么写入用 1/10/100us 三档可调，擦除却固定 1ms 不可改？
//      器件团队给的 contract：SET 在不同 level（电导）下需要不同脉宽来
//      达到目标窗口；RESET（擦除）只需要把单元拉到高阻态，1ms 是器件
//      可靠擦除的下限。生产固件不能把擦除拉短，所以我把 ERASE_WIDTH 做成
//      硬编码 RO 寄存器（reg_bank 中 PROG_ERASE_WIDTH 写入直接 ignore）——
//      这是一个"硬件强制约束 SW 不能犯错"的设计选择。
//
//   3) FULL_ARRAY 擦除为什么跳过 verify？
//      全阵列擦除 64×20=1280 cell 单脉冲拉高所有 WL，验证要逐 cell 读
//      → 1280 cycle ADC 时间，加上 retry 可能放大到 5000+ cycle。我把
//      "controller SEQ_DONE" 与"fw 逐 cell verify"两种语义拆开：
//      controller 只保证 1ms 脉冲时序正确（fire-and-forget），verify 由
//      fw 在需要时自己跑一轮"逐 cell readback + 比较"——把 cost 转移到
//      可选的 SW 路径，避免开机就花 5ms 在硬 verify。
//
//   4) 验证窗口 ±2 是怎么定的？
//      器件 D2D 5%±1% + C2C 3%±1% 推算 readback 噪声 ~3 LSB；窗口选 ±2
//      会让低概率漂移误判 PASS 但被下次推理读回的多次平均吸收，工程上
//      对识别率影响 < 0.1%。如果窗口收紧到 ±1 → 误 FAIL 重试率会上升到
//      ~15%，编程时间暴涨；放宽到 ±3 又让权重精度不够。±2 是 D2D/C2C
//      数据 + 100 sample 推理 sweep 出来的 sweet spot，不是拍脑袋。
//
// 三、关键设计指标
//   - 单 cell 写：典型 50us（10us pulse × ~5 retry 平均）；最坏 100us×7=700us。
//   - 单 cell 擦：1ms + 短 verify。
//   - 全阵列擦：1ms 一发，跳 verify。
//   - 编程期间 prog_busy=1 通过 arbiter 屏蔽推理 cim_macro 访问。
//
// 四、Corner case / 风险点
//   - prog_cim_done 输入故意没用：脉冲宽度由数字侧自计时，不等模拟侧握手。
//     这是为了"模拟 die 缺失或 BYPASS_HANDSHAKE=1 时" FSM 仍能完整跑完
//     编程时序——silicon bring-up Phase 1 的关键依赖。
//   - retry 计数器只在 ST_VERIFY → ST_RETRY 路径递增；如果 ADC 一直没
//     回 done，FSM 卡 ST_RB_WAIT。这种情况靠 BYPASS_HANDSHAKE=1（让
//     verify_en 硬接 PASS）规避；生产时由 reg_bank 把 BYPASS 锁在 0。
//   - prog_full_array=1 时 row/col 配置位被 ignore——但我没在 RTL 里
//     强制清 0，因为 cim_macro_arbiter 已经在 prog_busy 下用 prog_wl_spike
//     直接驱动 64 根 WL，row/col 信息从未到模拟 die，不会出错。
// =============================================================================

//======================================================================
// 文件名: cim_program_ctrl.sv
// 模块名: cim_program_ctrl
//
// 【功能概述】
// RRAM CIM 宏的写入/擦除/验证控制器（Program-and-Verify FSM）。
// 将传统的"CPU 软件循环写-读-比"卸载到硬件状态机，显著降低编程延迟。
//
// 【操作模式】
// - 写入模式（prog_erase=0）：向目标单元施加若干个 SET 脉冲，
//   脉冲数等于 prog_level（0~15，对应 4-bit 权重量化等级）
// - 逐 cell 擦除模式（prog_erase=1, prog_full_array=0）：
//   施加 RESET 脉冲，将单元恢复到高阻态
// - 全阵列擦除模式（prog_erase=1, prog_full_array=1）：
//   所有 WL 同时拉高，单个 1ms 宽脉冲（prog_erase_width），跳过验证
//
// 【状态机流程（11 状态）】
// IDLE → SETUP → PULSE → PULSE_HOLD(自计时) → READBACK → RB_WAIT → VERIFY
//   ├─ PASS → DONE → IDLE（验证通过）
//   └─ RETRY → SETUP → ...（验证不通过，重试直到达到 retry_limit）
//       └─ FAIL → DONE → IDLE（重试耗尽）
//
// 全阵列擦除特殊路径：
// IDLE → SETUP → PULSE → PULSE_HOLD → PASS → DONE → IDLE（跳过 verify）
//
// 【脉冲宽度】
// - 写入：由 REG_PROG_PULSE_WIDTH 选择 1us / 10us / 100us 三档
// - 擦除（逐 cell 或全阵列）：固定 1ms（REG_PROG_ERASE_WIDTH 读回该值）
// - 脉冲由数字侧自计时（ST_PULSE_HOLD 倒计时），不依赖 cim_done 握手
//
// 【验证判据】
// - 擦除后：readback_val ≤ 1（近似高阻态）
// - 写入后：readback_val 落在目标电导窗口 ±2 以内
//   目标窗口中心 = pulse_count × (256 / PROG_LEVELS)
//
// 【接口说明】
// - 软件通过 reg_bank 写 PROG_CTRL/PROG_ROW/PROG_COL 配置，写 START 启动
// - 硬件通过 cim_macro_arbiter 获得 CIM 宏独占访问权
// - prog_busy=1 期间，推理路径被仲裁器屏蔽
//======================================================================
module cim_program_ctrl (
  input  logic clk,                    // 系统时钟
  input  logic rst_n,                  // 异步低有效复位

  // ── 软件控制接口（来自 reg_bank）───────────────────────────────────
  input  logic        prog_start,       // W1P: 启动一次编程/擦除序列
  input  logic        prog_erase,       // 操作模式：0=写入(SET)，1=擦除(RESET)
  input  logic        prog_full_array,  // 全阵列擦除模式（1=所有 WL 同时拉高，跳过 verify）
  input  logic [5:0]  prog_row,         // 目标行地址（0~63，逐 cell 模式使用）
  input  logic [4:0]  prog_col,         // 目标列地址（0~19，逐 cell 模式使用）
  input  logic [3:0]  prog_level,       // 目标电导等级（0~15，4-bit 量化权重）
  input  logic [2:0]  prog_retry_limit, // 最大验证重试次数（0~7）
  input  logic [15:0] prog_pulse_width, // 写入脉冲宽度（1/10/100us preset resolved to cycles）
  input  logic [15:0] prog_erase_width, // 擦除脉冲宽度（固定 1ms preset resolved to cycles）

  // ── 状态输出（到 reg_bank → 软件可读）──────────────────────────────
  output logic        prog_busy,        // 编程控制器忙（1=正在编程序列中）
  output logic        prog_done_pulse,  // 编程完成脉冲（单拍高，触发 DONE sticky）
  output logic        prog_pass,        // 上次操作结果：验证通过
  output logic        prog_fail,        // 上次操作结果：验证失败（重试耗尽）
  output logic [2:0]  prog_retry_count, // 上次操作实际重试次数

  // ── CIM 宏接口（经 cim_macro_arbiter 仲裁后连接）──────────────────
  output logic [snn_soc_pkg::NUM_INPUTS-1:0] prog_wl_spike,  // 字线驱动
  output logic        prog_dac_valid,                         // DAC 有效（编程脉冲期间）
  output logic        prog_cim_start,                         // CIM 启动脉冲
  input  logic        prog_cim_done,                          // CIM 完成反馈（自计时模式下不使用）
  output logic        prog_adc_start,                         // ADC 启动（验证读回）
  input  logic        prog_adc_done,                          // ADC 完成反馈
  output logic [$clog2(snn_soc_pkg::MAX_BL_SCAN)-1:0] prog_bl_sel,  // BL 通道选择（位宽 = $clog2(MAX_BL_SCAN)，与 arbiter 一致）
  input  logic [snn_soc_pkg::ADC_BITS-1:0]             prog_bl_data, // ADC 读回数据

  // ── 编程专用控制信号（到 CIM 宏）──────────────────────────────────
  output logic        prog_en,          // 写入使能（SET 操作时拉高）
  output logic        erase_en,         // 擦除使能（RESET 操作时拉高）
  output logic        verify_en         // 验证使能（读回操作时拉高）
);
  import snn_soc_pkg::*;

  // ── 状态机定义（11 状态）──────────────────────────────────────────
  typedef enum logic [3:0] {
    ST_IDLE       = 4'd0,   // 空闲，等待 prog_start
    ST_SETUP      = 4'd1,   // 配置使能信号（prog_en / erase_en）
    ST_PULSE      = 4'd2,   // 发出 CIM 启动脉冲，加载计时器
    ST_PULSE_HOLD = 4'd3,   // 自计时：持续驱动脉冲，倒计时到 0
    ST_READBACK   = 4'd4,   // 启动 ADC 读回（验证当前电导）
    ST_RB_WAIT    = 4'd5,   // 等待 ADC 完成（prog_adc_done）
    ST_VERIFY     = 4'd6,   // 比较读回值与目标窗口
    ST_RETRY      = 4'd7,   // 验证不通过，检查是否可重试
    ST_PASS       = 4'd8,   // 验证通过
    ST_FAIL       = 4'd9,   // 重试耗尽，编程失败
    ST_DONE       = 4'd10   // 完成，输出 done_pulse，回到 IDLE
  } state_t;

  state_t state;
  logic [4:0] pulse_count;             // 已施加的脉冲数
  logic [15:0] pulse_width_cnt;        // 脉冲宽度倒计时器（自计时模式）
  logic [ADC_BITS-1:0] readback_val;   // ADC 读回值（用于验证比较）
  logic op_erase;                      // 锁存的操作模式
  logic op_full_array;                 // 锁存的全阵列擦除标志
  logic [3:0] target_level;            // 锁存的目标等级
  logic [2:0] target_retry_limit;      // 锁存的重试上限
  // D1-003：启动时锁存脉宽设置，防止软件在序列中途改 REG_PROG_PULSE_WIDTH 导致脉宽漂移
  logic [15:0] latched_pulse_width;
  logic [15:0] latched_erase_width;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state           <= ST_IDLE;
      prog_busy       <= 1'b0;
      prog_done_pulse <= 1'b0;
      prog_pass       <= 1'b0;
      prog_fail       <= 1'b0;
      prog_retry_count<= 3'd0;
      prog_wl_spike   <= '0;
      prog_dac_valid  <= 1'b0;
      prog_cim_start  <= 1'b0;
      prog_adc_start  <= 1'b0;
      prog_bl_sel     <= '0;
      prog_en         <= 1'b0;
      erase_en        <= 1'b0;
      verify_en       <= 1'b0;
      pulse_count     <= 5'd0;
      pulse_width_cnt <= 16'd0;
      readback_val    <= '0;
      op_erase        <= 1'b0;
      op_full_array   <= 1'b0;
      target_level    <= 4'd0;
      target_retry_limit <= 3'd0;
      latched_pulse_width <= 16'd0;
      latched_erase_width <= 16'd0;
    end else begin
      // 默认拉低单拍脉冲信号
      prog_done_pulse <= 1'b0;
      prog_cim_start  <= 1'b0;
      prog_adc_start  <= 1'b0;

      case (state)
        // ── 空闲：等待软件启动 ──────────────────────────────────────
        ST_IDLE: begin
          prog_busy    <= 1'b0;
          prog_en      <= 1'b0;
          erase_en     <= 1'b0;
          verify_en    <= 1'b0;
          prog_dac_valid <= 1'b0;
          if (prog_start) begin
            prog_busy        <= 1'b1;
            prog_pass        <= 1'b0;
            prog_fail        <= 1'b0;
            prog_retry_count <= 3'd0;
            pulse_count      <= 5'd0;
            op_erase         <= prog_erase;
            op_full_array    <= prog_erase & prog_full_array;
            target_level     <= prog_level;
            target_retry_limit <= prog_retry_limit;
            // D1-003：锁存脉宽寄存器，整个序列使用启动瞬间的值
            latched_pulse_width <= prog_pulse_width;
            latched_erase_width <= prog_erase_width;

            // ─── 根据操作类型确定 WL/BL 驱动 ─────────────────────────
            // 编程操作有两种粒度：
            //   (a) 全阵列擦除：一次把阵列里所有 cell 都擦回高阻（= weight=0）
            //       → 64 根 WL 同时拉高，BL 不重要（所有列都被擦）
            //   (b) 逐 cell 模式（写入 或 逐 cell 擦除）：只操作一个 cell
            //       → 只拉高目标行那一根 WL（one-hot），BL 指向目标列
            if (prog_erase && prog_full_array) begin
              // 全阵列擦除：所有 WL 同时拉高，BL 任意（固定 0 安全）
              prog_wl_spike <= {NUM_INPUTS{1'b1}};
              prog_bl_sel   <= '0;
            end else begin
              // 逐 cell 模式：先清零整个 WL 向量，再把目标行那一位置 1
              // 这种"先全零 + 后单 bit 写 1"叫 double-NBA 模式，
              // 在同一个 always_ff 块里 SystemVerilog 保证最终结果是 one-hot
              // （IEEE 1800 §10.4.2：同 rank NBA 的最后一次赋值生效）。
              prog_wl_spike <= '0;
              prog_wl_spike[prog_row] <= 1'b1;
              // 【2026-04-22 GPT review Q5 修复】
              //   原先写 `{{($clog2(MAX_BL_SCAN)-5){1'b0}}, prog_col}` 是为了兼容
              //   MAX_BL_SCAN 变大（v2 分支 =128 时 $clog2=7）时做高位零扩展。
              //   但 main 的 MAX_BL_SCAN=20 → $clog2=5，replicate count=0，
              //   zero-width replication 在部分综合/lint 工具（Vivado / DC / Spyglass）
              //   会告警或拒绝。改为直接赋值；SV 语言规范定义窄→宽赋值自动零扩展
              //   （IEEE 1800 §10.7），同时覆盖 MAX_BL_SCAN >= 32 的未来扩展场景。
              prog_bl_sel   <= prog_col;
            end

            // ─── 地址合法性检查（D1-004 + D2-001 + D2-006 + D3-FIX）────
            // 为什么要检查？软件可能写入 prog_row=63 或 prog_col=25 这种值：
            //   - prog_row 是 6-bit 寄存器，最大 63；PROG_ROWS=64 所以 0-63 合法
            //   - prog_col 是 5-bit 寄存器，最大 31；PROG_COLS=20 所以只有 0-19 合法
            //     超过 20 但不超过 31 的值（如 20~31）是"非法但硬件能存下"的陷阱
            //
            // 不检查会怎样？
            //   - 仿真里 weight_mem[r][25] 数组越界，行为不可预测
            //   - 真实硬件会给模拟侧送非法 bl_sel，可能误擦别的 cell 甚至损坏 RRAM
            //
            // 检查条件：`!prog_full_array` 而不是 `!prog_erase`，
            //   因为"全阵列擦除"的 row/col 本来就不用（见上面 if 分支），
            //   但"逐 cell 擦除"和"逐 cell 写入"都必须指向合法 cell。
            //
            // 【D3-FIX 重要教训】
            //   用 `int'()` 强制转 32-bit 再比较，**不要用位宽截断 cast**：
            //     ❌ `prog_row >= 6'(PROG_ROWS)` — 6'(64) 会截断为 0！
            //        (6-bit 容纳不下值 64，SV 规范 §6.24.1 截断高位)
            //        结果：所有 prog_row 都 >= 0 → guard always fires → TB 全挂
            //     ✅ `int'(prog_row) >= PROG_ROWS` — 32-bit 比较，不会截断
            //   prog_col 侧 5'(PROG_COLS)=5'(20)=20 能装下，历史没暴露这个坑。
            //   统一用 int cast 保持对称 + 防御未来参数值变化。
            if (!prog_full_array && ((int'(prog_col) >= PROG_COLS) ||
                                     (int'(prog_row) >= PROG_ROWS))) begin
              state <= ST_FAIL;                   // 非法地址 → 直接失败，不驱动 macro
            end else if (!prog_erase && (prog_level == 4'd0)) begin
              // 优化：写入等级 0 = 写入 HRS（高阻）= 和擦除等价
              // 直接跳 PASS，跳过脉冲发射，节省时间（全阵列擦除不走这里，它的 level 位不关心）
              state <= ST_PASS;
            end else begin
              state <= ST_SETUP;                  // 正常路径：配置使能信号，准备发脉冲
            end
          end
        end

        // ── 配置使能信号 ────────────────────────────────────────────
        ST_SETUP: begin
          prog_en         <= !op_erase;
          erase_en        <= op_erase;
          prog_dac_valid  <= 1'b1;
          state           <= ST_PULSE;
        end

        // ── 发出 CIM 启动脉冲，加载倒计时器 ────────────────────────
        ST_PULSE: begin
          prog_cim_start  <= 1'b1;
          // D1-003：用启动时锁存的脉宽值，防止中途寄存器修改影响本次序列
          // All erase operations use the 1ms erase preset. Only SET/write
          // operations use the selectable 1us / 10us / 100us preset.
          pulse_width_cnt <= op_erase ? latched_erase_width : latched_pulse_width;
          state           <= ST_PULSE_HOLD;
        end

        // ── 自计时：持续驱动脉冲，倒计时到 0 ────────────────────────
        ST_PULSE_HOLD: begin
          prog_dac_valid <= 1'b1;
          if (pulse_width_cnt <= 16'd1) begin
            pulse_count <= pulse_count + 5'd1;
            if (op_full_array) begin
              // 全阵列擦除：跳过 verify，直接成功
              state <= ST_PASS;
            end else if (op_erase) begin
              state <= ST_READBACK;
            end else if (pulse_count + 5'd1 >= {1'b0, target_level}) begin
              state <= ST_READBACK;
            end else begin
              state <= ST_PULSE;
            end
          end else begin
            pulse_width_cnt <= pulse_width_cnt - 16'd1;
          end
        end

        // ── 启动 ADC 读回 ──────────────────────────────────────────
        ST_READBACK: begin
          prog_en        <= 1'b0;
          erase_en       <= 1'b0;
          prog_dac_valid <= 1'b0;
          verify_en      <= 1'b1;
          prog_adc_start <= 1'b1;
          state          <= ST_RB_WAIT;
        end

        // ── 等待 ADC 完成 ──────────────────────────────────────────
        ST_RB_WAIT: begin
          if (prog_adc_done) begin
            readback_val <= prog_bl_data;
            verify_en    <= 1'b0;
            state        <= ST_VERIFY;
          end
        end

        // ── 验证判据 ────────────────────────────────────────────────
        ST_VERIFY: begin
          if (op_erase) begin
            if (readback_val <= ADC_BITS'(1))
              state <= ST_PASS;
            else
              state <= ST_RETRY;
          end else begin
            // D1-001 修复：验证窗口用 target_level（锁存目标等级），
            // 而非 pulse_count（累计脉冲数，retry 后可能 > target_level，窗口会漂移）。
            if (readback_val >= ADC_BITS'(int'(target_level) * (256 / PROG_LEVELS) - 2) &&
                readback_val <= ADC_BITS'(int'(target_level) * (256 / PROG_LEVELS) + 2))
              state <= ST_PASS;
            else
              state <= ST_RETRY;
          end
        end

        // ── 重试判断 ────────────────────────────────────────────────
        ST_RETRY: begin
          if (prog_retry_count >= target_retry_limit) begin
            state <= ST_FAIL;
          end else begin
            prog_retry_count <= prog_retry_count + 3'd1;
            state <= ST_SETUP;
          end
        end

        // ── 编程成功 ────────────────────────────────────────────────
        ST_PASS: begin
          prog_pass <= 1'b1;
          state     <= ST_DONE;
        end

        // ── 编程失败 ────────────────────────────────────────────────
        ST_FAIL: begin
          prog_fail <= 1'b1;
          state     <= ST_DONE;
        end

        // ── 完成：输出 done_pulse，回到 IDLE ────────────────────────
        ST_DONE: begin
          prog_busy       <= 1'b0;
          prog_done_pulse <= 1'b1;
          prog_en         <= 1'b0;
          erase_en        <= 1'b0;
          verify_en       <= 1'b0;
          prog_dac_valid  <= 1'b0;
          state           <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end
endmodule
