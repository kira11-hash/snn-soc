//======================================================================
// 文件名: cim_macro_blackbox.sv
// 描述: CIM Macro 数字接口。
//       - 综合：黑盒，仅保留端口
//       - 仿真：行为模型，提供可重复的 bl_data 生成规则
//======================================================================
`ifdef SYNTHESIS
module cim_macro_blackbox #(
  parameter int NUM_INPUTS  = snn_soc_pkg::NUM_INPUTS,
  parameter int NUM_OUTPUTS = snn_soc_pkg::NUM_OUTPUTS
) (
  input  logic clk,
  input  logic rst_n,
  input  logic [NUM_INPUTS-1:0] wl_spike,
  input  logic dac_valid,
  output logic dac_ready,
  input  logic cim_start,
  output logic cim_done,
  input  logic adc_start,
  output logic adc_done,
  input  logic [$clog2(NUM_OUTPUTS)-1:0] bl_sel,
  output logic [7:0] bl_data
);
endmodule
`else
module cim_macro_blackbox #(
  parameter int NUM_INPUTS  = snn_soc_pkg::NUM_INPUTS,
  parameter int NUM_OUTPUTS = snn_soc_pkg::NUM_OUTPUTS
) (
  input  logic clk,
  input  logic rst_n,
  input  logic [NUM_INPUTS-1:0] wl_spike,

  // DAC handshake
  input  logic dac_valid,
  output logic dac_ready,

  // CIM compute
  input  logic cim_start,
  output logic cim_done,

  // ADC
  input  logic adc_start,
  output logic adc_done,
  input  logic [$clog2(NUM_OUTPUTS)-1:0] bl_sel,
  output logic [7:0] bl_data
);
  import snn_soc_pkg::*;

  logic [NUM_INPUTS-1:0] wl_latched;
  logic [7:0]            pop_count;
  logic [NUM_OUTPUTS-1:0][7:0] bl_data_internal;
  logic [7:0]            cim_cnt;
  logic [7:0]            adc_cnt;
  logic                  cim_busy;
  logic                  adc_busy;

  // popcount 计算
  function automatic [7:0] popcount49(input logic [NUM_INPUTS-1:0] v);
    integer k;
    begin
      popcount49 = 8'h0;
      for (k = 0; k < NUM_INPUTS; k = k + 1) begin
        popcount49 = popcount49 + v[k];
      end
    end
  endfunction

  // dac_ready 始终为 1（简化模型）
  always_comb begin
    dac_ready = 1'b1;
  end

  // popcount 组合逻辑
  always_comb begin
    pop_count = popcount49(wl_latched);
  end

  // MUX 选择 bl_data 输出
  always_comb begin
    if (bl_sel < NUM_OUTPUTS) begin
      bl_data = bl_data_internal[bl_sel];
    end else begin
      bl_data = 8'h0;
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
        cim_cnt  <= CIM_LATENCY_CYCLES[7:0];
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
        adc_cnt  <= ADC_SAMPLE_CYCLES[7:0];
      end
      if (adc_busy) begin
        if (adc_cnt == 0) begin
          adc_done <= 1'b1;
          adc_busy <= 1'b0;
          // 可重复输出规则：bl_data[j] = (pop + j*3) & 8'hFF
          for (int j = 0; j < NUM_OUTPUTS; j = j + 1) begin
            bl_data_internal[j] <= (pop_count + j*3) & 8'hFF;
          end
        end else begin
          adc_cnt <= adc_cnt - 1'b1;
        end
      end
    end
  end

  // Assertions for verification
  always @(posedge clk) begin
    if (rst_n) begin
      // Check that bl_sel is within valid range
      assert (bl_sel < NUM_OUTPUTS)
        else $error("[cim_macro] bl_sel out of range! bl_sel=%0d, NUM_OUTPUTS=%0d", bl_sel, NUM_OUTPUTS);
    end
  end
endmodule
`endif
