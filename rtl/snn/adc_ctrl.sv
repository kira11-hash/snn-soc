//======================================================================
// 文件名: adc_ctrl.sv
// 描述: ADC 控制器（时分复用 1 个 ADC + 10:1 MUX）。
//       - adc_kick_pulse 触发一次完整 10 路采样流程
//       - bl_sel 在 0..9 循环，等待 MUX 建立后采样
//       - 10 路数据齐全后输出 neuron_in_valid 单拍
//======================================================================
module adc_ctrl (
  input  logic clk,
  input  logic rst_n,

  input  logic adc_kick_pulse,
  output logic adc_start,
  input  logic adc_done,
  input  logic [7:0] bl_data,

  output logic [$clog2(snn_soc_pkg::NUM_OUTPUTS)-1:0] bl_sel,
  output logic        neuron_in_valid,
  output logic [snn_soc_pkg::NUM_OUTPUTS-1:0][7:0] neuron_in_data
);
  import snn_soc_pkg::*;

  localparam int BL_SEL_WIDTH = $clog2(NUM_OUTPUTS);

  typedef enum logic [2:0] {
    ST_IDLE   = 3'd0,
    ST_SEL    = 3'd1,
    ST_SAMPLE = 3'd2,
    ST_STORE  = 3'd3,
    ST_DONE   = 3'd4
  } state_t;

  localparam int SETTLE_CNT_W = $clog2(ADC_MUX_SETTLE_CYCLES + 1);
  localparam int SAMPLE_CNT_W = $clog2(ADC_SAMPLE_CYCLES + 1);

  state_t state;
  logic [BL_SEL_WIDTH-1:0] sel_idx;
  logic [SETTLE_CNT_W-1:0] settle_cnt;
  logic [SAMPLE_CNT_W-1:0] sample_cnt;
  logic [NUM_OUTPUTS-1:0][7:0] data_reg;

  // 说明: adc_done 目前不参与控制流程，采样时序由计数器定义
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state           <= ST_IDLE;
      sel_idx         <= '0;
      bl_sel          <= '0;
      settle_cnt      <= '0;
      sample_cnt      <= '0;
      data_reg        <= '0;
      neuron_in_data  <= '0;
      neuron_in_valid <= 1'b0;
      adc_start       <= 1'b0;
    end else begin
      adc_start       <= 1'b0;
      neuron_in_valid <= 1'b0;
      bl_sel          <= sel_idx;

      case (state)
        ST_IDLE: begin
          if (adc_kick_pulse) begin
            sel_idx    <= '0;
            bl_sel     <= '0;
            data_reg   <= '0;
            if (ADC_MUX_SETTLE_CYCLES == 0) begin
              adc_start <= 1'b1;
              if (ADC_SAMPLE_CYCLES <= 1) begin
                state <= ST_STORE;
              end else begin
                sample_cnt <= ADC_SAMPLE_CYCLES[SAMPLE_CNT_W-1:0] - 2'd2;
                state      <= ST_SAMPLE;
              end
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
            if (ADC_SAMPLE_CYCLES <= 1) begin
              state <= ST_STORE;
            end else begin
              sample_cnt <= ADC_SAMPLE_CYCLES[SAMPLE_CNT_W-1:0] - 2'd2;
              state      <= ST_SAMPLE;
            end
          end else begin
            settle_cnt <= settle_cnt - 1'b1;
          end
        end

        ST_SAMPLE: begin
          bl_sel <= sel_idx;
          if (sample_cnt == 0) begin
            state <= ST_STORE;
          end else begin
            sample_cnt <= sample_cnt - 1'b1;
          end
        end

        ST_STORE: begin
          bl_sel <= sel_idx;
          data_reg[sel_idx] <= bl_data;
          if (sel_idx == NUM_OUTPUTS-1) begin
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

        ST_DONE: begin
          neuron_in_data  <= data_reg;
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
    if (rst_n) begin
      // Check that sel_idx never exceeds NUM_OUTPUTS-1
      assert (sel_idx < NUM_OUTPUTS)
        else $error("[adc_ctrl] sel_idx overflow! sel_idx=%0d, NUM_OUTPUTS=%0d", sel_idx, NUM_OUTPUTS);

      // Check that bl_sel never exceeds NUM_OUTPUTS-1
      assert (bl_sel < NUM_OUTPUTS)
        else $error("[adc_ctrl] bl_sel overflow! bl_sel=%0d, NUM_OUTPUTS=%0d", bl_sel, NUM_OUTPUTS);

      // Check that neuron_in_valid and neuron_in_data are aligned
      if (neuron_in_valid) begin
        assert ($past(state) == ST_DONE)
          else $warning("[adc_ctrl] neuron_in_valid asserted outside ST_DONE state");
      end
    end
  end
  // synthesis translate_on
endmodule
