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
// 描述: ADC 控制器（时分复用 1 个 ADC + 20:1 MUX，Scheme B）。
//       - adc_kick_pulse 触发一次完整 20 路采样流程
//       - bl_sel 在 0..ADC_CHANNELS-1 循环，等待 MUX 建立后采样
//       - 20 路原始数据齐全后执行数字差分减法：
//         diff[i] = raw_pos[i] - raw_neg[i]（i = 0..NUM_OUTPUTS-1）
//       - 输出 neuron_in_valid 单拍 + 有符号差分数据
//======================================================================
//
// -----------------------------------------------------------------------
// 信号说明
// -----------------------------------------------------------------------
// adc_kick_pulse  : 单拍脉冲，由 cim_array_ctrl 在 ST_ADC 状态发出，
//                   启动本模块的一轮完整 20 路采样序列。
// adc_start       : 单拍脉冲，送往 cim_macro_blackbox，触发单通道 ADC 转换。
// adc_done        : 来自 cim_macro_blackbox，当前通道转换完成指示（单拍高）。
// bl_data         : 来自 CIM 宏，当前 bl_sel 选中通道的无符号 ADC 结果
//                   位宽 = ADC_BITS = 8，范围 0..255。
// bl_sel          : 通道选择，驱动外部 20:1 MUX，决定哪一 BL 列连到 ADC 输入。
//                   位宽 = $clog2(ADC_CHANNELS) = 5 位（可寻址 0..31，实际用 0..19）。
// neuron_in_valid : 单拍脉冲，ST_DONE 状态产生，通知 lif_neurons 本次差分数据有效。
// neuron_in_data  : 有符号差分数据，位宽 NEURON_DATA_WIDTH=9 位，
//                   每个元素对应 diff[i] = raw[i] - raw[i+NUM_OUTPUTS]。
// adc_sat_high    : 饱和高（bl_data==0xFF）计数，诊断用，正常推理中应接近 0。
// adc_sat_low     : 饱和低（bl_data==0x00）计数，诊断用。
// -----------------------------------------------------------------------
module adc_ctrl (
  input  logic clk,
  input  logic rst_n,

  input  logic adc_kick_pulse,
  output logic adc_start,
  input  logic adc_done,
  input  logic [snn_soc_pkg::ADC_BITS-1:0] bl_data,

  output logic [$clog2(snn_soc_pkg::ADC_CHANNELS)-1:0] bl_sel,
  output logic        neuron_in_valid,
  output logic [snn_soc_pkg::NUM_OUTPUTS-1:0][snn_soc_pkg::NEURON_DATA_WIDTH-1:0] neuron_in_data,

  // ADC 饱和监控（诊断用）
  output logic [15:0] adc_sat_high,  // bl_data == MAX 的累计次数
  output logic [15:0] adc_sat_low    // bl_data == 0   的累计次数
);
  import snn_soc_pkg::*;

  // BL_SEL_WIDTH: bl_sel 所需位宽，= $clog2(ADC_CHANNELS) = $clog2(20) = 5
  // 5 位可表示 0..31，足以容纳 0..19，无截断风险。
  localparam int BL_SEL_WIDTH = $clog2(ADC_CHANNELS);

  // BL_SEL_MAX: 最后一个有效通道索引 = ADC_CHANNELS - 1 = 19
  // 使用 BL_SEL_WIDTH'() 做位宽截断转型，防止 lint 警告。
  // 5'(19) = 5'b10011，不存在截断，值仍为 19。
  localparam logic [BL_SEL_WIDTH-1:0] BL_SEL_MAX = BL_SEL_WIDTH'(ADC_CHANNELS-1);

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

  // raw_data: 20 路无符号 ADC 采样结果暂存数组。
  // raw_data[0..9]  = 正列（positive BL columns）
  // raw_data[10..19]= 负列（negative BL columns）
  // Scheme B: diff[i] = raw_data[i] - raw_data[i+NUM_OUTPUTS]，i=0..9
  logic [ADC_CHANNELS-1:0][ADC_BITS-1:0] raw_data;

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
      neuron_in_valid <= 1'b0;
      adc_start       <= 1'b0;
      adc_sat_high    <= 16'h0;
      adc_sat_low     <= 16'h0;
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
        //   - 清零 sel_idx、raw_data、饱和计数器（为新一轮采样做准备）
        //   - 若 SETTLE_CYCLES==0（编译时常量），直接发 adc_start 跳 ST_WAIT
        //   - 否则装载 settle 倒计数器，进入 ST_SEL 等待 MUX 建立
        // 注意：adc_kick_pulse 只需持续 1 个周期。
        // -------------------------------------------------------------------
        ST_IDLE: begin
          if (adc_kick_pulse) begin
            sel_idx      <= '0;
            bl_sel       <= '0;
            raw_data     <= '0;
            adc_sat_high <= 16'h0;
            adc_sat_low  <= 16'h0;
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
        //   3. 判断是否已完成所有 20 路（sel_idx == BL_SEL_MAX=19）
        //      - 是：进入 ST_DONE 执行差分
        //      - 否：sel_idx 自增，重新进入 ST_SEL（或直接 ST_WAIT 若 SETTLE==0）
        // -------------------------------------------------------------------
        ST_WAIT: begin
          bl_sel <= sel_idx;          // 维持 bl_sel 不变，等待转换期间 MUX 不切换
          if (adc_done) begin
            raw_data[sel_idx] <= bl_data;   // 存储当前通道采样结果
            // ADC 饱和检测（饱和=ADC 输出被截断，表明信号超出量程）
            if (bl_data == {ADC_BITS{1'b1}}) adc_sat_high <= adc_sat_high + 16'h1;
            if (bl_data == {ADC_BITS{1'b0}}) adc_sat_low  <= adc_sat_low  + 16'h1;
            if (sel_idx == BL_SEL_MAX) begin
              // 最后一路（通道 19）采样完毕，进入 Scheme B 差分计算
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
          // Scheme B 数字差分减法: diff[i] = pos[i] - neg[i+NUM_OUTPUTS]
          for (int i = 0; i < NUM_OUTPUTS; i = i + 1) begin
            neuron_in_data[i] <= NEURON_DATA_WIDTH'(
              $signed({1'b0, raw_data[i]}) - $signed({1'b0, raw_data[i + NUM_OUTPUTS]})
            );
            // 解释：
            //   {1'b0, raw_data[i]}            → 9 位无符号正数（MSB=0 保证为正）
            //   $signed(...)                   → 当作有符号数做减法
            //   NEURON_DATA_WIDTH'(...)        → 保留低 9 位，丢弃溢出的高位符号扩展
          end
          neuron_in_valid <= 1'b1;    // 单拍有效脉冲，lif_neurons 在此拍采样 neuron_in_data
          state           <= ST_IDLE; // 返回空闲，等待下一帧的 adc_kick_pulse
        end
        default: state <= ST_IDLE;    // 防止综合器推断不可达锁存态
      endcase
    end
  end

  // =========================================================================
  // 仿真断言（synthesis translate_off / on 保护，综合时完全忽略）
  // =========================================================================
  // Assertions for verification
  // synthesis translate_off
  always @(posedge clk) begin
    begin
      // Check that sel_idx never exceeds ADC_CHANNELS-1
      // sel_idx 越界表示循环计数器逻辑错误，会导致 raw_data 数组越界写。
      if (!$isunknown(sel_idx)) begin
        assert (sel_idx <= BL_SEL_MAX)
          else $error("[adc_ctrl] sel_idx overflow! sel_idx=%0d, ADC_CHANNELS=%0d", sel_idx, ADC_CHANNELS);
      end

      // Check that bl_sel never exceeds ADC_CHANNELS-1
      // bl_sel 越界会导致外部 MUX 选择无效通道，ADC 采样结果无意义。
      if (!$isunknown(bl_sel)) begin
        assert (bl_sel <= BL_SEL_MAX)
          else $error("[adc_ctrl] bl_sel overflow! bl_sel=%0d, ADC_CHANNELS=%0d", bl_sel, ADC_CHANNELS);
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
