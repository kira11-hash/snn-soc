// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/snn/cim_macro_blackbox.sv
// Purpose: Behavioral stand-in for the analog CIM macro during digital development and simulation.
// Role in system: Lets the digital SoC be verified before real analog macro/ADC implementation is available.
// Behavior summary: Consumes WL spike vector / selection control, returns synthetic BL data with configurable latency behavior.
// Synthesis behavior: Acts as a blackbox/interface shell so analog macro can replace it later at integration/tapeout stage.
// Important limitation: Output values are functional placeholders, not calibrated analog-accurate device behavior.
// Use with care: Do not over-interpret numerical accuracy from this model; Python/device plugin path is for parameter studies.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: cim_macro_blackbox.sv
// 描述: CIM Macro 数字接口（Scheme B：20 列 BL）。
//       - 综合：黑盒，仅保留端口
//       - 仿真：行为模型，提供可重复的 bl_data 生成规则
//       - bl_sel 寻址 ADC_CHANNELS=20 列（0..9 正列, 10..19 负列）
//======================================================================
//
// -----------------------------------------------------------------------
// 设计结构说明
// -----------------------------------------------------------------------
// 本文件使用 `ifdef SYNTHESIS 宏将模块分为两个版本：
//
// 【综合版本（`ifdef SYNTHESIS）】
//   - 仅包含端口列表，无任何内部逻辑。
//   - 综合工具将此模块视为黑盒（blackbox），在版图中为空白占位符。
//   - 流片时，由模拟设计团队提供真实的 RRAM CIM 宏 GDSII/LEF，
//     在布局阶段替换此黑盒。
//   - 端口名称和位宽必须与真实宏完全匹配，否则 LVS 会失败。
//
// 【仿真版本（`else，即非综合）】
//   - 提供行为级功能模型，用于数字仿真验证。
//   - 模拟 RRAM CIM 宏的基本行为：
//     * DAC 锁存：dac_valid=1 时（单拍脉冲）捕获 wl_spike 到 wl_latched
//       （真实芯片侧由 wl_latch 时序控制，dac_ready 握手已简化移除）
//     * CIM 计算：触发后延迟 CIM_LATENCY_CYCLES 个周期，产生 cim_done
//     * ADC 采样：触发后延迟 ADC_SAMPLE_CYCLES 个周期，产生 adc_done，
//                 同时计算并存储 bl_data_internal（Scheme B 行为模型）
//     * bl_data 输出：由 bl_sel 选择对应通道数据（MUX 组合逻辑）
//
// -----------------------------------------------------------------------
// Scheme B 行为模型说明
// -----------------------------------------------------------------------
// 真实 RRAM 阵列：
//   - 128×256 差分列配置（0T1R RRAM）
//   - 正列（0..9）：连接正权重行
//   - 负列（10..19）：连接负权重行
//   - 每列 BL 电流 ∝ Σ(weight_i × input_i)
//   - ADC 将 BL 电流量化为 ADC_BITS=8 位无符号数
//
// 仿真行为模型（简化）：
//   - 使用 popcount(wl_latched) 作为"有效 WL 激活数"
//   - 正列 j（0..9）：bl_data_internal[j] = min(2*popcount + j, 2^8-1)
//   - 负列 j（10..19）：bl_data_internal[j] = min(popcount/2 + (j-10), 2^8-1)
//   - 差分结果（由 adc_ctrl 完成）：diff[i] = pos[i] - neg[i] > 0
//     确保正列值 > 负列值，膜电位可正向积累，用于验证推理流程完整性
//   - 注意：此模型不代表真实精度，仅用于功能验证（"接线正确性"验证）
//
// -----------------------------------------------------------------------
// 关键参数说明
// -----------------------------------------------------------------------
// P_NUM_INPUTS   : WL 位图宽度 = NUM_INPUTS = 64
// P_ADC_CHANNELS : BL 通道数 = ADC_CHANNELS = 20（Scheme B：10 正 + 10 负）
// BL_SEL_W       : bl_sel 位宽 = $clog2(P_ADC_CHANNELS) = $clog2(20) = 5
// ADC_CH_MAX     : BL_SEL_W'(P_ADC_CHANNELS) = 5'(20) = 5'b10100 = 20
//                  注意：这是"通道总数"而不是"最大通道索引"（最大索引为 19）。
//                  断言和 MUX 使用 bl_sel < ADC_CH_MAX（即 < 20）来验证合法性。
//                  5 位可以表示 0..31，20 不存在截断风险。
// -----------------------------------------------------------------------

`ifdef SYNTHESIS
// =====================================================================
// 综合版本：黑盒（仅端口，无逻辑）
// 在综合和布局阶段，此模块是模拟 CIM 宏的占位符。
// =====================================================================
module cim_macro_blackbox #(
  parameter int P_NUM_INPUTS      = snn_soc_pkg::NUM_INPUTS,
  parameter int P_ADC_CHANNELS    = snn_soc_pkg::ADC_CHANNELS,
  parameter bit P_USE_BRAM_WEIGHTS = 0
) (
  input  logic clk,
  input  logic rst_n,
  input  logic [P_NUM_INPUTS-1:0] wl_spike,
  input  logic dac_valid,
  input  logic cim_start,
  output logic cim_done,
  input  logic adc_start,
  output logic adc_done,
  input  logic [$clog2(snn_soc_pkg::MAX_BL_SCAN)-1:0] bl_sel,
  output logic [snn_soc_pkg::ADC_BITS-1:0] bl_data,

  // V2 programming interface
  input  logic prog_en,
  input  logic erase_en,
  input  logic verify_en
);
endmodule

`else
// =====================================================================
// 仿真版本：行为模型（非综合，含功能逻辑和断言）
// =====================================================================
module cim_macro_blackbox #(
  parameter int P_NUM_INPUTS      = snn_soc_pkg::NUM_INPUTS,
  parameter int P_ADC_CHANNELS    = snn_soc_pkg::ADC_CHANNELS,
  parameter bit P_USE_BRAM_WEIGHTS = 0
) (
  input  logic clk,
  input  logic rst_n,
  input  logic [P_NUM_INPUTS-1:0] wl_spike,
  input  logic dac_valid,
  input  logic cim_start,
  output logic cim_done,
  input  logic adc_start,
  output logic adc_done,
  input  logic [$clog2(snn_soc_pkg::MAX_BL_SCAN)-1:0] bl_sel,
  output logic [snn_soc_pkg::ADC_BITS-1:0] bl_data,

  // V2 programming interface
  input  logic prog_en,
  input  logic erase_en,
  input  logic verify_en
);
  import snn_soc_pkg::*;

  // BL_SEL_W: bl_sel 位宽 = $clog2(P_ADC_CHANNELS) = $clog2(20) = 5
  localparam int BL_SEL_W = $clog2(P_ADC_CHANNELS);

  // ADC_CH_MAX: 通道总数（用作上界比较），值为 P_ADC_CHANNELS = 20。
  // 注意区分：ADC_CH_MAX = 20（count），最大合法索引 = 19（ADC_CH_MAX - 1）。
  // bl_sel < ADC_CH_MAX 等价于 bl_sel <= 19，即合法范围检查。
  // 5 位编码：5'(20) = 5'b10100，无截断，正常表示 20。
  localparam logic [BL_SEL_W-1:0] ADC_CH_MAX = BL_SEL_W'(P_ADC_CHANNELS); // count, not max index; used as bl_sel < ADC_CH_MAX

  // wl_latched: 锁存的 WL 激活图。
  // 在 dac_valid 单拍脉冲时从 wl_spike 捕获（dac_ready 已移除，固定时序）。
  // 后续 CIM 计算和 ADC 采样均基于此锁存值（不随 wl_spike 变化）。
  logic [P_NUM_INPUTS-1:0] wl_latched;

  // pop_count: 当前 wl_latched 中置 1 的位数（激活的 WL 数量）。
  // 真实 CIM 中，BL 电流 ∝ Σ(weight × input)；
  // 仿真模型中用 popcount 简化代替（假设所有权重为 1）。
  logic [7:0]            pop_count;

  // bl_data_internal: 全部 20 路 BL 通道的 ADC 量化结果缓存数组。
  // 在 adc_done 产生时更新（ADC 采样完成时），adc_ctrl 的 bl_sel 循环读取各通道。
  logic [P_ADC_CHANNELS-1:0][ADC_BITS-1:0] bl_data_internal;

  // 延迟计数器（CIM 和 ADC 各自独立）
  logic [7:0]            cim_cnt;    // CIM 计算延迟倒计数器
  logic [7:0]            adc_cnt;    // ADC 采样延迟倒计数器

  // 忙标志（防止重复触发）
  logic                  cim_busy;   // 1 = CIM 计算进行中
  logic                  adc_busy;   // 1 = ADC 采样进行中

  // V2 BRAM weight storage (behavioral model for programming)
  logic [ADC_BITS-1:0] weight_mem [0:P_NUM_INPUTS-1][0:P_ADC_CHANNELS-1];

  // Programming pulse counter per cell (tracks accumulated pulses)
  logic [3:0] prog_pulse_acc [0:P_NUM_INPUTS-1][0:P_ADC_CHANNELS-1];

  wire _unused_prog = &{1'b0, verify_en};

  // -----------------------------------------------------------------------
  // popcount 函数：计算向量中置 1 的位数
  // 使用 for 循环逐位累加，综合时等效于加法树（位宽 log2(N) 层）。
  // 这里用于仿真行为模型，综合版本中不存在此函数。
  // -----------------------------------------------------------------------
  // popcount 计算
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic [7:0] popcount_fn(input logic [P_NUM_INPUTS-1:0] v);
    integer k;
    begin
      popcount_fn = 8'h0;
      for (k = 0; k < P_NUM_INPUTS; k = k + 1) begin
        popcount_fn = popcount_fn + v[k];
      end
    end
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // -----------------------------------------------------------------------
  // popcount 组合逻辑
  // pop_count 实时反映 wl_latched 的当前值，ADC 采样时使用此值生成 bl_data。
  // -----------------------------------------------------------------------
  // popcount 组合逻辑
  always_comb begin
    pop_count = popcount_fn(wl_latched);
  end

  // -----------------------------------------------------------------------
  // bl_data MUX：根据 bl_sel 选择对应通道的内部缓存数据输出
  // 合法范围：bl_sel < ADC_CH_MAX（即 0..19）
  // 越界情况：输出全 0（安全降级）
  // -----------------------------------------------------------------------
  // MUX 选择 bl_data 输出
  always_comb begin
    if (bl_sel < ADC_CH_MAX) begin
      bl_data = bl_data_internal[bl_sel];
    end else begin
      bl_data = {ADC_BITS{1'b0}};
    end
  end

  function automatic [ADC_BITS-1:0] bram_weighted_sum(input int col);
    logic [15:0] wsum;
    begin
      wsum = 16'd0;
      for (int r = 0; r < P_NUM_INPUTS; r = r + 1) begin
        if (wl_latched[r])
          wsum = wsum + {8'd0, weight_mem[r][col]};
      end
      if (wsum > ((1 << ADC_BITS) - 1))
        bram_weighted_sum = {ADC_BITS{1'b1}};
      else
        bram_weighted_sum = ADC_BITS'(wsum);
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wl_latched <= '0;
      cim_done   <= 1'b0;
      adc_done   <= 1'b0;
      cim_cnt    <= 8'h0;
      adc_cnt    <= 8'h0;
      cim_busy   <= 1'b0;
      adc_busy   <= 1'b0;
      bl_data_internal <= '0;
    end else begin
      // 每周期默认清除单拍完成脉冲（在计数结束时置 1）
      cim_done <= 1'b0;
      adc_done <= 1'b0;

      // -------------------------------------------------------------------
      // DAC 锁存 wl_spike
      // dac_valid 单拍脉冲（来自 dac_ctrl）表示 wl_spike 已稳定。
      // 将 wl_spike 捕获到 wl_latched，供后续 popcount 和 ADC 模型使用。
      // 注意：dac_ctrl 中 wl_reg 在 wl_valid_pulse 后一拍更新，
      //       dac_valid 也在同一拍发出，所以此处锁存的是新 wl_spike 值。
      // -------------------------------------------------------------------
      // DAC 锁存 wl_spike
      if (dac_valid) begin
        wl_latched <= wl_spike;
      end

      // -------------------------------------------------------------------
      // CIM 计算延迟模型
      // cim_start 触发（且 cim_busy==0，防止重入）：
      //   - 设置 cim_busy=1，装载延迟计数器
      //   - CIM_LATENCY_CYCLES==0：lat_cnt=0，下一拍即完成（1 拍最小延迟）
      //   - CIM_LATENCY_CYCLES==N：lat_cnt=N-1，经过 N 拍后 cim_done
      // cim_busy 期间每拍递减 cim_cnt，减到 0 时产生 cim_done 并清除 busy。
      // -------------------------------------------------------------------
      // CIM 计算延迟
      if (cim_start && !cim_busy) begin
        cim_busy <= 1'b1;
        // 计数语义：延迟 N 周期后 done
        cim_cnt  <= (CIM_LATENCY_CYCLES == 0) ? 8'h0
                                              : (CIM_LATENCY_CYCLES[7:0] - 8'h1);
      end
      if (cim_busy) begin
        if (cim_cnt == 0) begin
          cim_done <= 1'b1;    // 单拍完成脉冲
          cim_busy <= 1'b0;
        end else begin
          cim_cnt <= cim_cnt - 1'b1;
        end
      end

      // -------------------------------------------------------------------
      // ADC 延迟与 bl_data_internal 更新
      // adc_start 触发（且 adc_busy==0）：
      //   - 设置 adc_busy=1，装载延迟计数器（与 CIM 延迟语义相同）
      // adc_busy 期间每拍递减 adc_cnt：
      //   - 减到 0 时：
      //     1. 产生 adc_done 单拍
      //     2. 根据 Scheme B 行为模型，更新 bl_data_internal[0..19]
      //        正列（j=0..9） : bl_data_internal[j] = min(pop_count*2 + j, 255)
      //        负列（j=10..19）: bl_data_internal[j] = min(pop_count/2 + (j-10), 255)
      //        （ADC_BITS 位截断由 ADC_BITS'() 完成，超出范围会绕回但不溢出，
      //         因为 pop_count 最大 64，2*64+9=137 < 255，pop_count/2+9=41 < 255）
      //     3. 清除 adc_busy
      // adc_done 拉高后，adc_ctrl 的 ST_WAIT 检测到，读取 bl_data（当前 bl_sel 通道），
      // 存入其内部 raw_data 数组。
      // -------------------------------------------------------------------
      // ADC 延迟与输出
      if (adc_start && !adc_busy) begin
        adc_busy <= 1'b1;
        // 计数语义：延迟 N 周期后 done
        adc_cnt  <= (ADC_SAMPLE_CYCLES == 0) ? 8'h0
                                             : (ADC_SAMPLE_CYCLES[7:0] - 8'h1);
      end
      if (adc_busy) begin
        if (adc_cnt == 0) begin
          adc_done <= 1'b1;
          adc_busy <= 1'b0;
          if (P_USE_BRAM_WEIGHTS) begin
            for (int j = 0; j < P_ADC_CHANNELS; j = j + 1) begin
              bl_data_internal[j] <= bram_weighted_sum(j);
            end
          end else begin
            for (int j = 0; j < P_ADC_CHANNELS; j = j + 1) begin
              if (j < (P_ADC_CHANNELS / 2))
                bl_data_internal[j] <= ADC_BITS'(int'(pop_count) * 2 + j);
              else
                bl_data_internal[j] <= ADC_BITS'(int'(pop_count) / 2 + (j - P_ADC_CHANNELS/2));
            end
          end
        end else begin
          adc_cnt <= adc_cnt - 1'b1;
        end
      end
    end
  end

  // =========================================================================
  // V2 Programming logic: prog_en pulse writes, erase_en pulse erases
  // =========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int r = 0; r < P_NUM_INPUTS; r++) begin
        for (int c = 0; c < P_ADC_CHANNELS; c++) begin
          // Default weights: V1-compatible popcount-based initialization
          if (c < NUM_OUTPUTS)
            weight_mem[r][c] <= ADC_BITS'(2);   // pos columns: small positive
          else
            weight_mem[r][c] <= ADC_BITS'(1);   // neg columns: smaller
          prog_pulse_acc[r][c] <= 4'd0;
        end
      end
    end else begin
      if (erase_en && cim_start && !cim_busy) begin
        if (&wl_latched) begin
          // 全阵列擦除：所有 WL 同时拉高，擦除所有行所有列
          for (int r = 0; r < P_NUM_INPUTS; r++) begin
            for (int c = 0; c < P_ADC_CHANNELS; c++) begin
              weight_mem[r][c]     <= '0;
              prog_pulse_acc[r][c] <= 4'd0;
            end
          end
        end else begin
          // 逐 cell 擦除：只擦活跃行的 bl_sel 列
          for (int r = 0; r < P_NUM_INPUTS; r++) begin
            if (wl_latched[r]) begin
              weight_mem[r][bl_sel]     <= '0;
              prog_pulse_acc[r][bl_sel] <= 4'd0;
            end
          end
        end
      end else if (prog_en && cim_start && !cim_busy) begin
        // Program: increment pulse count, update weight proportionally
        for (int r = 0; r < P_NUM_INPUTS; r++) begin
          if (wl_latched[r]) begin
            if (prog_pulse_acc[r][bl_sel] < 4'd15) begin
              prog_pulse_acc[r][bl_sel] <= prog_pulse_acc[r][bl_sel] + 4'd1;
              weight_mem[r][bl_sel]     <= ADC_BITS'((int'(prog_pulse_acc[r][bl_sel]) + 1) * (256 / PROG_LEVELS));
            end
          end
        end
      end
    end
  end

  // =========================================================================
  // V2 时间多层：按层 reload 权重接口（仿真 shortcut）
  // =========================================================================
  //
  // 【这个 task 解决什么问题？】
  // V2 时间多层架构是"一个物理 CIM macro，按时间顺序跑多层"：
  //
  //   固件端实际流程：
  //     推理第 0 层 → 读 spike → 全阵列擦除 → 逐 cell 写第 1 层权重（~1280 cells）
  //     → 推理第 1 层 → ... 以此类推
  //
  //   层之间的"擦除 + 重编程"要走 cim_program_ctrl FSM 真正跑 1280 个编程脉冲，
  //   假设每个脉冲 ~1ms，单层编程 = 1.28 秒仿真时间。4 层累计 ~5 秒 Icarus 时间。
  //
  //   如果每次 TB 回归都等这 5 秒，CI 太慢。因此提供这个 shortcut：
  //     TB 在层切换时直接从 hex 文件把下一层权重装进 weight_mem，
  //     跳过 cim_program_ctrl 的脉冲发射和验证循环。
  //
  // 【真实硬件 vs 仿真 shortcut 的区别】
  //   - 真实硬件：不存在这个 task，层切换必须走 cim_program_ctrl FSM
  //   - 仿真 shortcut：TB 显式调用 task，直接把权重"搬"进来
  //   - 正式编程闭环回归（+define+PROG_DEEP_SWEEP）要走 FSM，不用此 shortcut
  //
  // 【调用方法】
  //   dut.u_macro.reload_layer_weights("fw/out/weight_L1.hex");
  //
  // 【hex 文件格式】
  //   $readmemh 接受的二维 memory 文本格式。
  //   行数 = P_NUM_INPUTS × P_ADC_CHANNELS（默认 64 × 20 = 1280 行）。
  //   每行一个 8-bit 权重值（16 进制）。
  //
  // 【调用时序约束（重要！）】
  //   调用者必须保证：
  //     1. rst_n == 1（非复位期间）
  //     2. 不在推理进行中（否则正在跑的 ADC 读到的还是旧权重）
  //     3. 不在 prog_busy（cim_program_ctrl 编程期间）
  //
  //   task 内部首行 `@(negedge clk)` 保证权重写入避开 posedge 时钟边沿，
  //   防止和 always_ff 驱动同一变量时产生 multi-driver 竞争（D2-007 修复）。
  //
  // 【副作用】
  //   - weight_mem 被新权重覆盖
  //   - prog_pulse_acc 被清零（模拟"全擦 + 重写"后 pulse 计数重置的语义）
  //
  // =========================================================================
  task reload_layer_weights(input string hex_path);
    int unsigned r, c;
    begin
      // D3-004: 运行时 guard，防止误调用破坏仿真状态（行为模型仿真专用，综合里不存在）
      if (!rst_n) begin
        $fatal(1, "[cim_macro] reload_layer_weights called during reset — rst_n=0 will overwrite weights");
      end
      if (cim_busy || adc_busy) begin
        $fatal(1, "[cim_macro] reload_layer_weights called during CIM/ADC activity — would corrupt in-flight inference");
      end
      if (prog_en || erase_en) begin
        $fatal(1, "[cim_macro] reload_layer_weights called while prog_en/erase_en active — conflicts with editing always_ff");
      end
      // 等到下一个 negedge clk：把 task 内部的操作错开 always_ff 的 posedge 采样点
      // → 保证 $readmemh 写 weight_mem 和 always_ff 块的 NBA 不在同一时间步竞争
      @(negedge clk);
      $readmemh(hex_path, weight_mem);
      // 清零 pulse accumulator：真实硬件里层切换前会先全擦除，
      // 之后重新走 Write-Verify 循环，pulse_acc 从 0 重新累加。
      // Shortcut 跳过了那个过程，这里手动对齐状态。
      for (r = 0; r < P_NUM_INPUTS; r++) begin
        for (c = 0; c < P_ADC_CHANNELS; c++) begin
          prog_pulse_acc[r][c] = 4'd0;
        end
      end
      $display("[cim_macro] reload_layer_weights: loaded %s @ %0t", hex_path, $time);
    end
  endtask

  // =========================================================================
  // 仿真断言（仅在仿真模式下有效，已在 `else 块内，无需额外 `ifdef 保护）
  // =========================================================================
  // 断言：简单接口合法性检查
  always @(posedge clk) begin
    // 不用 rst_n 作为同步门控，避免与异步复位风格混用触发 SYNCASYNCNET
    // 上电初始周期若 bl_sel 含 X，跳过该拍检查。
    if (!$isunknown(bl_sel)) begin
      // V2: blackbox weight storage 仅覆盖 P_ADC_CHANNELS 列（默认 20），
      // 若 bl_sel >= P_ADC_CHANNELS（多层扫描超出黑盒容量），MUX 会返回 0，
      // 由于这是行为模型，不是 RTL 逻辑错误 → 降级为 warning 而非 error。
      assert (bl_sel < ADC_CH_MAX)
        else $warning("[cim_macro] bl_sel 超出黑盒容量（行为模型，非 RTL 错误）: bl_sel=%0d, P_ADC_CHANNELS=%0d", bl_sel, P_ADC_CHANNELS);
    end
  end
endmodule
`endif
