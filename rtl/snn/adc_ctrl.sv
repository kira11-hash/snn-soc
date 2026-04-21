// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/snn/adc_ctrl.sv
// Purpose: Controls ADC sampling order across BL channels and packages converted values for neuron update stage.
// Role in system: Implements time-multiplexed readout (including Scheme-B differential pair handling in digital domain).
// Behavior summary: Iterates bl_sel, waits ADC done, stores/combines samples, outputs signed neuron input data.
// Current architecture: Single ADC reused across multiple BL channels to minimize area; throughput traded for simplicity.
// Critical correctness point: Channel pairing/order directly affects digital subtraction and final classification accuracy.
// Verification focus: bl_sel sequencing, pos/neg pairing, signed width, and end-of-neuron valid pulse timing.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: adc_ctrl.sv
// 描述: ADC 控制器 —— 时分复用 1 个 ADC 读取多个 BL 通道的 Scheme B 差分输出
//======================================================================
//
// 【这个模块做什么？】
//   CIM 阵列推理完一次后，每一列 BL 上都有一个模拟电流值，需要 ADC 量化。
//   我们只有 1 个 ADC（省面积），所以用时分复用：ADC 依次切到不同的 BL 列做转换。
//
//   具体流程：
//     1. cim_array_ctrl 发 adc_kick_pulse → 本模块进入采样序列
//     2. 设置 bl_sel=0 → 等 MUX 建立（ADC_MUX_SETTLE_CYCLES 拍）
//     3. 发 adc_start → 等 adc_done → 把 bl_data 存进 raw_data[0]
//     4. bl_sel 递增到下一通道，重复 2-3
//     5. 所有通道采集完，做数字差分减法，输出 neuron_in_data
//
// 【V1 vs V2 扫描模式】
//   V1 固定：扫 20 路（ADC_CHANNELS=20），前 10 路是正列、后 10 路是负列
//            差分：diff[i] = raw[i] - raw[i+10]（i=0..9）
//
//   V2 可配（本次新增）：扫 2~128 路（最多 MAX_BL_SCAN=128）
//            前半是正列、后半是负列
//            差分：diff[i] = raw[i] - raw[i + bl_scan_count/2]
//            用于 4 层网络 64→32→16→10，每层 bl_count 不同
//
//   V1/V2 切换：use_scan_cfg 信号控制。默认 0 走 V1，上层拉 1 走 V2。
//
// 【为什么要 Scheme B 差分？】
//   模拟 CIM 的权重永远是正值（电阻不能为负）。但神经网络需要负权重。
//   解决方案：用两列 RRAM 实现一个有符号权重 —— 一列存正部分、一列存负部分。
//   数字侧减法得到带符号的"等效权重 × 输入"结果。
//
//   "Scheme B" 指这种"数字侧做减法"的方案。
//   替代方案 "Scheme A"（模拟侧做减法）面积更小但精度差，已经被本项目否决。
//
// -----------------------------------------------------------------------
// 信号说明
// -----------------------------------------------------------------------
// sat_count_clear_pulse : 新推理开始时清零饱和计数器的单拍脉冲。
//                         adc_sat_high/low 语义是"单次推理内的累计值"，所以每次推理
//                         开始前必须清零，否则数值会跨推理累加。
// adc_kick_pulse       : cim_array_ctrl 发来的"开始扫描"信号（单拍高）。
// adc_start            : 本模块发给 cim_macro 的"开始单次转换"信号（单拍高）。
// adc_done             : cim_macro 返回的"单次转换完成"信号（单拍高）。
// bl_data              : cim_macro 返回的 8-bit 无符号 ADC 原始值（0~255）。
// bl_sel               : 通道选择，送给外部 BL MUX。
//                        V1：位宽 5、范围 0-19；V2：位宽 7、范围 0-127（实际用 0..bl_scan_count-1）。
// neuron_in_valid      : 全部差分计算完成的通知脉冲（ST_DONE 状态单拍）。
// neuron_in_data       : V1 10 路差分结果（固定 NUM_OUTPUTS=10 宽）。
// neuron_in_data_wide  : V2 可变宽度差分结果（MAX_NEURONS=128 宽，未用位填 0）。
// bl_scan_count        : V2 运行时扫描通道数（来自 layer_sequencer）。
// use_scan_cfg         : 0=V1 固定 20 路，1=V2 使用 bl_scan_count。
// adc_sat_high/low     : 诊断计数器（bl_data=0xFF / 0x00 的次数），正常推理应接近 0。
//                        如果长时间非 0 → ADC 量程设定有问题 / CIM 电流超标。
// -----------------------------------------------------------------------
module adc_ctrl #(
  parameter int P_MAX_NEURONS = snn_soc_pkg::MAX_NEURONS
) (
  input  logic clk,
  input  logic rst_n,

  input  logic sat_count_clear_pulse,
  input  logic adc_kick_pulse,
  output logic adc_start,
  input  logic adc_done,
  input  logic [snn_soc_pkg::ADC_BITS-1:0] bl_data,

  output logic [$clog2(snn_soc_pkg::MAX_BL_SCAN)-1:0] bl_sel,
  output logic        neuron_in_valid,
  output logic [snn_soc_pkg::NUM_OUTPUTS-1:0][snn_soc_pkg::NEURON_DATA_WIDTH-1:0] neuron_in_data,

  // ADC 饱和监控（诊断用）
  output logic [15:0] adc_sat_high,
  output logic [15:0] adc_sat_low,

  // V2 多层扩展（ENABLE_MULTI_LAYER=0 时绑默认值）
  input  logic [7:0]  bl_scan_count,   // 本层扫描通道数（默认 ADC_CHANNELS=20）
  input  logic        use_scan_cfg,    // 1=使用 bl_scan_count，0=固定 ADC_CHANNELS
  output logic [P_MAX_NEURONS-1:0][snn_soc_pkg::NEURON_DATA_WIDTH-1:0] neuron_in_data_wide
);
  import snn_soc_pkg::*;

  // ═══════════════════════════════════════════════════════════════════════
  // bl_sel 位宽推导
  // ═══════════════════════════════════════════════════════════════════════
  // V1 需要 $clog2(20) = 5 位；V2 最多扫 128 路，需要 $clog2(128) = 7 位。
  // 统一按 V2 的 7 位来声明，V1 路径只用低 5 位，高 2 位恒为 0（安全向后兼容）。
  localparam int BL_SEL_WIDTH = $clog2(MAX_BL_SCAN);

  // V1 兼容默认：bl_scan_count 当前使用索引范围的上限 = ADC_CHANNELS-1 = 19
  localparam logic [BL_SEL_WIDTH-1:0] BL_SEL_MAX = BL_SEL_WIDTH'(ADC_CHANNELS-1);

  // ═══════════════════════════════════════════════════════════════════════
  // V2 可配扫描数的安全钳位
  // ═══════════════════════════════════════════════════════════════════════
  // 上层可能写错 bl_scan_count（比如配成 0 或 999），这里做一层防御：
  //   - 太小（< 2）：差分需要至少一对 pos/neg 列，所以下限是 2
  //   - 太大（> MAX_BL_SCAN=128）：硬件只设计支持到 128
  //   - 超出范围时安全降级回 V1 默认值（ADC_CHANNELS=20），避免硬件进入未定义状态
  wire [7:0] clamped_scan = (bl_scan_count > 8'(MAX_BL_SCAN) || bl_scan_count < 8'd2)
                            ? 8'(ADC_CHANNELS) : bl_scan_count;

  // eff_scan_max：实际使用的 bl_sel 最大索引（扫描范围 0..eff_scan_max）
  //   - V1 路径（use_scan_cfg=0）：固定 = BL_SEL_MAX = 19
  //   - V2 路径（use_scan_cfg=1）：= clamped_scan - 1（比如 bl_scan_count=64 → 63）
  wire [BL_SEL_WIDTH-1:0] eff_scan_max = use_scan_cfg
      ? BL_SEL_WIDTH'(clamped_scan - 8'd1)
      : BL_SEL_MAX;

  // eff_half_count：差分切分点，前 half_count 路是正列、后 half_count 路是负列
  //   - V1 路径：固定 = NUM_OUTPUTS = 10（10 正 + 10 负 = 20 路）
  //   - V2 路径：= clamped_scan / 2（比如 bl_scan_count=64 → 32 正 + 32 负）
  //   这个变量驱动 ST_DONE 状态的差分减法循环
  wire [7:0] eff_half_count = use_scan_cfg ? (clamped_scan >> 1) : 8'(NUM_OUTPUTS);

  // -----------------------------------------------------------------------
  // FSM 状态定义（3 个有效状态，共 2 位编码，留有 ST_DONE=3 备用）
  // -----------------------------------------------------------------------
  // ST_IDLE : 等待 adc_kick_pulse。
  // ST_SEL  : MUX 切换后等待信号建立（settle_cnt 倒计数）。
  //           若 ADC_MUX_SETTLE_CYCLES==0，此状态被编译时分支完全跳过。
  // ST_WAIT : adc_start 已发出，等待 adc_done 返回，采样结果存入 raw_data。
  // ST_DONE : 所有 20 路采样完成，执行 Scheme B 差分减法，拉高 neuron_in_valid。
  // -----------------------------------------------------------------------
  typedef enum logic [1:0] {
    ST_IDLE = 2'd0,
    ST_SEL  = 2'd1,
    ST_WAIT = 2'd2,
    ST_DONE = 2'd3
  } state_t;

  // SETTLE_CNT_W: settle_cnt 计数器位宽。
  // 若 ADC_MUX_SETTLE_CYCLES > 0，需要能表示最大值，位宽 = $clog2(SETTLE_CYCLES+1)。
  // 若 ADC_MUX_SETTLE_CYCLES == 0，编译时绕过 ST_SEL，但计数器仍需至少 1 位（赋为 0 即可）。
  localparam int SETTLE_CNT_W = (ADC_MUX_SETTLE_CYCLES > 0) ? $clog2(ADC_MUX_SETTLE_CYCLES + 1) : 1;

  state_t state;

  // sel_idx: 当前正在采样的通道索引（内部循环计数器）。
  // 范围 0..19（BL_SEL_MAX），每次 adc_done 后自增，达到 BL_SEL_MAX 时进入 ST_DONE。
  logic [BL_SEL_WIDTH-1:0] sel_idx;

  // settle_cnt: MUX 切换后的建立时间倒计数器。
  // 从 ADC_MUX_SETTLE_CYCLES-1 开始倒数到 0，然后才发出 adc_start。
  // 如果 SETTLE_CYCLES==0，此计数器从不被真正使用（编译时 if 绕过）。
  logic [SETTLE_CNT_W-1:0] settle_cnt;

  // raw_data: ADC 采样结果暂存数组（最大 MAX_BL_SCAN 路）。
  // Scheme B: 前半为正列、后半为负列，diff[i] = raw[i] - raw[i + half]
  logic [MAX_BL_SCAN-1:0][ADC_BITS-1:0] raw_data;

  // 说明: 每个通道一次 adc_start -> 等待 adc_done -> 存数
  // Scheme B: 通道 0..9 为正列, 10..19 为负列
  // ST_DONE 时执行数字差分: diff[i] = raw[i] - raw[i+NUM_OUTPUTS]
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // 异步复位：所有状态寄存器、输出寄存器、诊断计数器清零。
      state           <= ST_IDLE;
      sel_idx         <= '0;
      bl_sel          <= '0;
      settle_cnt      <= '0;
      raw_data        <= '0;
      neuron_in_data  <= '0;
      neuron_in_valid     <= 1'b0;
      adc_start           <= 1'b0;
      adc_sat_high        <= 16'h0;
      adc_sat_low         <= 16'h0;
      neuron_in_data_wide <= '0;
    end else begin
      // 每周期默认清除单拍脉冲输出，避免多拍误触发。
      // adc_start 和 neuron_in_valid 均为单拍脉冲，只在特定状态下置 1。
      adc_start       <= 1'b0;
      neuron_in_valid <= 1'b0;

      // bl_sel 追踪 sel_idx：sel_idx 更新在本周期，bl_sel 在下周期反映。
      // 外部 MUX 需要 bl_sel 稳定后再建立，因此 settle 计数正好覆盖这一拍延迟。
      bl_sel          <= sel_idx;

      case (state)
        // -------------------------------------------------------------------
        // ST_IDLE: 静止等待 adc_kick_pulse。
        // 收到 kick 后：
        //   - 清零 sel_idx、raw_data（为新一轮采样做准备）
        //   - 若 SETTLE_CYCLES==0（编译时常量），直接发 adc_start 跳 ST_WAIT
        //   - 否则装载 settle 倒计数器，进入 ST_SEL 等待 MUX 建立
        // 注意：adc_kick_pulse 只需持续 1 个周期。
        // -------------------------------------------------------------------
        ST_IDLE: begin
          if (adc_kick_pulse) begin
            sel_idx      <= '0;
            bl_sel       <= '0;
            raw_data     <= '0;
            if (ADC_MUX_SETTLE_CYCLES == 0) begin
              // 编译时分支：SETTLE_CYCLES 为 0 时跳过 ST_SEL，
              // 立即发 adc_start，节省一个状态周期。
              adc_start <= 1'b1;
              state     <= ST_WAIT;
            end else begin
              // 装载倒计数初值：SETTLE_CYCLES-1（因为计数到 0 时还有最后一拍建立时间）。
              settle_cnt <= ADC_MUX_SETTLE_CYCLES[SETTLE_CNT_W-1:0] - 1'b1;
              state      <= ST_SEL;
            end
          end
        end

        // -------------------------------------------------------------------
        // ST_SEL: 等待 MUX 切换建立时间。
        // settle_cnt 每周期递减，减到 0 时 MUX 输出已稳定，发 adc_start。
        // bl_sel 已在本状态开始时由 sel_idx 驱动（上一状态末更新 sel_idx，
        // 本周期默认赋值 bl_sel <= sel_idx 已生效）。
        // -------------------------------------------------------------------
        ST_SEL: begin
          bl_sel <= sel_idx;          // 保持 bl_sel 稳定，防止 MUX glitch
          if (settle_cnt == 0) begin
            // 建立时间已满，触发 ADC 转换
            adc_start <= 1'b1;
            state     <= ST_WAIT;
          end else begin
            settle_cnt <= settle_cnt - 1'b1;
          end
        end

        // -------------------------------------------------------------------
        // ST_WAIT: 等待 ADC 完成信号。
        // adc_done 由 cim_macro_blackbox（仿真）或实际 ADC（流片后）拉高。
        // 收到 adc_done：
        //   1. 将 bl_data 存入 raw_data[sel_idx]（索引即通道号）
        //   2. 饱和检测：0xFF=满量程高，0x00=零量程低
        //   3. 判断是否已完成所有通道（sel_idx == eff_scan_max）
        //      V1 路径：eff_scan_max = 19（扫完 20 路）
        //      V2 路径：eff_scan_max = bl_scan_count-1（如 63 或 127）
        //      - 是：进入 ST_DONE 执行差分减法
        //      - 否：sel_idx 自增，重新进入 ST_SEL（或直接 ST_WAIT 若 SETTLE==0）
        // -------------------------------------------------------------------
        ST_WAIT: begin
          bl_sel <= sel_idx;          // 维持 bl_sel 不变，等待转换期间 MUX 不切换
          if (adc_done) begin
            raw_data[sel_idx] <= bl_data;   // 存储当前通道采样结果
            // ADC 饱和检测（饱和=ADC 输出被截断，表明信号超出量程）
            if ((bl_data == {ADC_BITS{1'b1}}) && (adc_sat_high != 16'hFFFF)) begin
              adc_sat_high <= adc_sat_high + 16'h1;
            end
            if ((bl_data == {ADC_BITS{1'b0}}) && (adc_sat_low != 16'hFFFF)) begin
              adc_sat_low <= adc_sat_low + 16'h1;
            end
            if (sel_idx == eff_scan_max) begin
              state <= ST_DONE;
            end else begin
              // 切换到下一通道
              sel_idx <= sel_idx + 1'b1;
              if (ADC_MUX_SETTLE_CYCLES == 0) begin
                // 无建立时间需求：保持 settle_cnt 为 0（实际不使用）
                settle_cnt <= '0;
              end else begin
                // 重新装载建立时间计数器，等待新 MUX 建立
                settle_cnt <= ADC_MUX_SETTLE_CYCLES[SETTLE_CNT_W-1:0] - 1'b1;
              end
              state <= ST_SEL;          // 回到建立等待态（或 SETTLE==0 时也走 ST_SEL 路径）
            end
          end
        end

        // -------------------------------------------------------------------
        // ST_DONE: Scheme B 数字差分减法。
        // 对 NUM_OUTPUTS=10 个神经元输出分别计算：
        //   neuron_in_data[i] = raw_data[i] - raw_data[i + NUM_OUTPUTS]
        //                     = pos_col[i]  - neg_col[i]
        // 两个操作数均先符号扩展为有符号数（{1'b0, raw_data[x]} = +raw_data[x]），
        // 相减后截断到 NEURON_DATA_WIDTH=9 位（1 符号位 + 8 数据位）。
        // 差值范围：-(2^8-1) 到 +(2^8-1)，即 -255 到 +255，
        // 9 位有符号数范围 -256 到 +255，足够容纳（不会溢出）。
        //
        // 完成后拉高 neuron_in_valid 单拍，通知 lif_neurons 新数据到达。
        // -------------------------------------------------------------------
        ST_DONE: begin
          // Scheme B 差分：V1 固定 10 路
          for (int i = 0; i < NUM_OUTPUTS; i = i + 1) begin
            neuron_in_data[i] <= NEURON_DATA_WIDTH'(
              $signed({1'b0, raw_data[i]}) - $signed({1'b0, raw_data[i + NUM_OUTPUTS]})
            );
          end
          // V2 多层：可变通道数差分，输出到 neuron_in_data_wide
          for (int i = 0; i < P_MAX_NEURONS; i = i + 1) begin
            if (i < int'(eff_half_count)) begin
              neuron_in_data_wide[i] <= NEURON_DATA_WIDTH'(
                $signed({1'b0, raw_data[i]}) - $signed({1'b0, raw_data[i + int'(eff_half_count)]})
              );
            end else begin
              neuron_in_data_wide[i] <= '0;
            end
          end
          neuron_in_valid <= 1'b1;
          state           <= ST_IDLE;
        end
        default: state <= ST_IDLE;    // 防止综合器推断不可达锁存态
      endcase

      // 诊断计数器按“推理”为边界清零，而不是按单次 20 路扫描清零。
      if (sat_count_clear_pulse) begin
        adc_sat_high <= 16'h0;
        adc_sat_low  <= 16'h0;
      end
    end
  end

  // =========================================================================
  // 仿真断言（synthesis translate_off / on 保护，综合时完全忽略）
  // =========================================================================
  // Assertions for verification
  // synthesis translate_off
  always @(posedge clk) begin
    begin
      // Check that sel_idx never exceeds effective scan max
      if (!$isunknown(sel_idx)) begin
        assert (sel_idx <= eff_scan_max)
          else $error("[adc_ctrl] sel_idx overflow! sel_idx=%0d, eff_scan_max=%0d", sel_idx, eff_scan_max);
      end

      // Check that bl_sel never exceeds effective scan max
      if (!$isunknown(bl_sel)) begin
        assert (bl_sel <= eff_scan_max)
          else $error("[adc_ctrl] bl_sel overflow! bl_sel=%0d, eff_scan_max=%0d", bl_sel, eff_scan_max);
      end

      // Check that neuron_in_valid and neuron_in_data are aligned
      // neuron_in_valid 必须仅在 ST_DONE 状态（上一拍）产生，否则差分数据未就绪。
      if (neuron_in_valid) begin
        assert ($past(state) == ST_DONE)
          else $warning("[adc_ctrl] neuron_in_valid asserted outside ST_DONE state");
      end

      // adc_done 应在等待状态出现
      // 若 adc_done 在 ST_WAIT 之外到来，说明 CIM 宏或仿真模型存在时序错误。
      if (adc_done) begin
        assert (state == ST_WAIT)
          else $warning("[adc_ctrl] adc_done asserted outside ST_WAIT state");
      end
    end
  end
  // synthesis translate_on
endmodule
