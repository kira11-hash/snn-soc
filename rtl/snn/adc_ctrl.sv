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

  localparam int BL_SEL_WIDTH = $clog2(ADC_CHANNELS);
  localparam logic [BL_SEL_WIDTH-1:0] BL_SEL_MAX = BL_SEL_WIDTH'(ADC_CHANNELS-1);

  typedef enum logic [1:0] {
    ST_IDLE = 2'd0,
    ST_SEL  = 2'd1,
    ST_WAIT = 2'd2,
    ST_DONE = 2'd3
  } state_t;

  localparam int SETTLE_CNT_W = (ADC_MUX_SETTLE_CYCLES > 0) ? $clog2(ADC_MUX_SETTLE_CYCLES + 1) : 1;

  state_t state;
  logic [BL_SEL_WIDTH-1:0] sel_idx;
  logic [SETTLE_CNT_W-1:0] settle_cnt;
  // 20 路无符号原始 ADC 数据
  logic [ADC_CHANNELS-1:0][ADC_BITS-1:0] raw_data;

  // 说明: 每个通道一次 adc_start -> 等待 adc_done -> 存数
  // Scheme B: 通道 0..9 为正列, 10..19 为负列
  // ST_DONE 时执行数字差分: diff[i] = raw[i] - raw[i+NUM_OUTPUTS]
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
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
      adc_start       <= 1'b0;
      neuron_in_valid <= 1'b0;
      bl_sel          <= sel_idx;

      case (state)
        ST_IDLE: begin
          if (adc_kick_pulse) begin
            sel_idx      <= '0;
            bl_sel       <= '0;
            raw_data     <= '0;
            adc_sat_high <= 16'h0;
            adc_sat_low  <= 16'h0;
            if (ADC_MUX_SETTLE_CYCLES == 0) begin
              adc_start <= 1'b1;
              state     <= ST_WAIT;
            end else begin
              settle_cnt <= ADC_MUX_SETTLE_CYCLES[SETTLE_CNT_W-1:0] - 1'b1;
              state      <= ST_SEL;
            end
          end
        end

        ST_SEL: begin
          bl_sel <= sel_idx;
          if (settle_cnt == 0) begin
            adc_start <= 1'b1;
            state     <= ST_WAIT;
          end else begin
            settle_cnt <= settle_cnt - 1'b1;
          end
        end

        ST_WAIT: begin
          bl_sel <= sel_idx;
          if (adc_done) begin
            raw_data[sel_idx] <= bl_data;
            // ADC 饱和检测
            if (bl_data == {ADC_BITS{1'b1}}) adc_sat_high <= adc_sat_high + 16'h1;
            if (bl_data == {ADC_BITS{1'b0}}) adc_sat_low  <= adc_sat_low  + 16'h1;
            if (sel_idx == BL_SEL_MAX) begin
              state <= ST_DONE;
            end else begin
              sel_idx <= sel_idx + 1'b1;
              if (ADC_MUX_SETTLE_CYCLES == 0) begin
                settle_cnt <= '0;
              end else begin
                settle_cnt <= ADC_MUX_SETTLE_CYCLES[SETTLE_CNT_W-1:0] - 1'b1;
              end
              state <= ST_SEL;
            end
          end
        end

        ST_DONE: begin
          // Scheme B 数字差分减法: diff[i] = pos[i] - neg[i+NUM_OUTPUTS]
          for (int i = 0; i < NUM_OUTPUTS; i = i + 1) begin
            neuron_in_data[i] <= NEURON_DATA_WIDTH'(
              $signed({1'b0, raw_data[i]}) - $signed({1'b0, raw_data[i + NUM_OUTPUTS]})
            );
          end
          neuron_in_valid <= 1'b1;
          state           <= ST_IDLE;
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

  // Assertions for verification
  // synthesis translate_off
  always @(posedge clk) begin
    begin
      // Check that sel_idx never exceeds ADC_CHANNELS-1
      if (!$isunknown(sel_idx)) begin
        assert (sel_idx <= BL_SEL_MAX)
          else $error("[adc_ctrl] sel_idx overflow! sel_idx=%0d, ADC_CHANNELS=%0d", sel_idx, ADC_CHANNELS);
      end

      // Check that bl_sel never exceeds ADC_CHANNELS-1
      if (!$isunknown(bl_sel)) begin
        assert (bl_sel <= BL_SEL_MAX)
          else $error("[adc_ctrl] bl_sel overflow! bl_sel=%0d, ADC_CHANNELS=%0d", bl_sel, ADC_CHANNELS);
      end

      // Check that neuron_in_valid and neuron_in_data are aligned
      if (neuron_in_valid) begin
        assert ($past(state) == ST_DONE)
          else $warning("[adc_ctrl] neuron_in_valid asserted outside ST_DONE state");
      end

      // adc_done 应在等待状态出现
      if (adc_done) begin
        assert (state == ST_WAIT)
          else $warning("[adc_ctrl] adc_done asserted outside ST_WAIT state");
      end
    end
  end
  // synthesis translate_on
endmodule
