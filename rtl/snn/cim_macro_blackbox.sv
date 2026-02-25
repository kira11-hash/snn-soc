`timescale 1ns/1ps
//======================================================================
// 文件名: cim_macro_blackbox.sv
// 描述: CIM Macro 数字接口（Scheme B：20 列 BL）。
//       - 综合：黑盒，仅保留端口
//       - 仿真：行为模型，提供可重复的 bl_data 生成规则
//       - bl_sel 寻址 ADC_CHANNELS=20 列（0..9 正列, 10..19 负列）
//======================================================================
`ifdef SYNTHESIS
module cim_macro_blackbox #(
  parameter int P_NUM_INPUTS   = snn_soc_pkg::NUM_INPUTS,
  parameter int P_ADC_CHANNELS = snn_soc_pkg::ADC_CHANNELS
) (
  input  logic clk,
  input  logic rst_n,
  // wl_spike 为一帧输入图像的单个 bit-plane（64 路并行）
  input  logic [P_NUM_INPUTS-1:0] wl_spike,
  input  logic dac_valid,
  output logic dac_ready,
  input  logic cim_start,
  output logic cim_done,
  input  logic adc_start,
  output logic adc_done,
  input  logic [$clog2(P_ADC_CHANNELS)-1:0] bl_sel,
  output logic [snn_soc_pkg::ADC_BITS-1:0] bl_data
);
endmodule
`else
module cim_macro_blackbox #(
  parameter int P_NUM_INPUTS   = snn_soc_pkg::NUM_INPUTS,
  parameter int P_ADC_CHANNELS = snn_soc_pkg::ADC_CHANNELS
) (
  input  logic clk,
  input  logic rst_n,
  input  logic [P_NUM_INPUTS-1:0] wl_spike,

  // DAC handshake
  input  logic dac_valid,
  output logic dac_ready,

  // CIM compute
  input  logic cim_start,
  output logic cim_done,

  // ADC
  input  logic adc_start,
  output logic adc_done,
  input  logic [$clog2(P_ADC_CHANNELS)-1:0] bl_sel,
  output logic [snn_soc_pkg::ADC_BITS-1:0] bl_data
);
  import snn_soc_pkg::*;

  localparam int BL_SEL_W = $clog2(P_ADC_CHANNELS);
  localparam logic [BL_SEL_W-1:0] ADC_CH_MAX = BL_SEL_W'(P_ADC_CHANNELS); // count, not max index; used as bl_sel < ADC_CH_MAX

  logic [P_NUM_INPUTS-1:0] wl_latched;
  logic [7:0]            pop_count;
  logic [P_ADC_CHANNELS-1:0][ADC_BITS-1:0] bl_data_internal;
  logic [7:0]            cim_cnt;
  logic [7:0]            adc_cnt;
  logic                  cim_busy;
  logic                  adc_busy;

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

  // dac_ready 始终为 1（简化模型）
  always_comb begin
    dac_ready = 1'b1;
  end

  // popcount 组合逻辑
  always_comb begin
    pop_count = popcount_fn(wl_latched);
  end

  // MUX 选择 bl_data 输出
  always_comb begin
    if (bl_sel < ADC_CH_MAX) begin
      bl_data = bl_data_internal[bl_sel];
    end else begin
      bl_data = {ADC_BITS{1'b0}};
    end
  end

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
      cim_done <= 1'b0;
      adc_done <= 1'b0;

      // DAC 握手：锁存 wl_spike
      if (dac_valid && dac_ready) begin
        wl_latched <= wl_spike;
      end

      // CIM 计算延迟
      if (cim_start && !cim_busy) begin
        cim_busy <= 1'b1;
        // 计数语义：延迟 N 周期后 done
        cim_cnt  <= (CIM_LATENCY_CYCLES == 0) ? 8'h0
                                              : (CIM_LATENCY_CYCLES[7:0] - 8'h1);
      end
      if (cim_busy) begin
        if (cim_cnt == 0) begin
          cim_done <= 1'b1;
          cim_busy <= 1'b0;
        end else begin
          cim_cnt <= cim_cnt - 1'b1;
        end
      end

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
          // 行为模型：为 Scheme B 20 列生成可重复数据
          // 正列 (0..9)：较高基数, 负列 (10..19)：较低基数
          // 这样差分 diff[i] = pos[i] - neg[i] > 0，确保膜电位可正向积累
          for (int j = 0; j < P_ADC_CHANNELS; j = j + 1) begin
            if (j < NUM_OUTPUTS) begin
              // 正列：pop_count * 2 + offset
              bl_data_internal[j] <= ADC_BITS'(pop_count * 2 + j);
            end else begin
              // 负列：pop_count / 2 + offset
              // 显式扩展 pop_count 到 32-bit，避免 lint 对移位位宽告警
              bl_data_internal[j] <= ADC_BITS'(({24'b0, pop_count} >> 1) + (j - NUM_OUTPUTS));
            end
          end
        end else begin
          adc_cnt <= adc_cnt - 1'b1;
        end
      end
    end
  end

  // 断言：简单接口合法性检查
  always @(posedge clk) begin
    // 不用 rst_n 作为同步门控，避免与异步复位风格混用触发 SYNCASYNCNET
    // 上电初始周期若 bl_sel 含 X，跳过该拍检查。
    if (!$isunknown(bl_sel)) begin
      // Check that bl_sel is within valid range
      assert (bl_sel < ADC_CH_MAX)
        else $error("[cim_macro] bl_sel 越界: bl_sel=%0d, ADC_CHANNELS=%0d", bl_sel, P_ADC_CHANNELS);
    end
  end
endmodule
`endif
