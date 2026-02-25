`timescale 1ns/1ps
//======================================================================
// 文件名: cim_array_ctrl.sv
// 描述: CIM 阵列控制器核心 FSM。
//       状态流转：
//       IDLE -> STEP_FETCH -> STEP_DAC -> STEP_CIM -> STEP_ADC -> STEP_INC -> DONE
//======================================================================
// NOTE: 每帧拆成 PIXEL_BITS 个 bit-plane（MSB->LSB）输入。
//       bitplane_shift 表示当前位平面权重（用于 LIF 移位累加）。
module cim_array_ctrl (
  input  logic clk,
  input  logic rst_n,
  input  logic soft_reset_pulse,

  input  logic start_pulse,
  input  logic [7:0] timesteps,

  // input_fifo
  input  logic [snn_soc_pkg::NUM_INPUTS-1:0] in_fifo_rdata,
  input  logic in_fifo_empty,
  output logic in_fifo_pop,

  // DAC
  output logic [snn_soc_pkg::NUM_INPUTS-1:0] wl_bitmap,
  output logic wl_valid_pulse,
  input  logic dac_done_pulse,

  // CIM Macro
  output logic cim_start_pulse,
  input  logic cim_done,

  // ADC
  output logic adc_kick_pulse,
  input  logic neuron_in_valid,

  // 状态输出
  output logic busy,
  output logic done_pulse,
  // timestep_counter 统计帧数（bit-plane 子时间步在内部处理）
  output logic [7:0] timestep_counter,
  output logic [$clog2(snn_soc_pkg::PIXEL_BITS)-1:0] bitplane_shift
);
  import snn_soc_pkg::*;

  localparam int BITPLANE_W = $clog2(PIXEL_BITS);
  localparam logic [BITPLANE_W-1:0] BITPLANE_MAX = BITPLANE_W'(PIXEL_BITS-1);

  typedef enum logic [2:0] {
    ST_IDLE  = 3'd0,
    ST_FETCH = 3'd1,
    ST_DAC   = 3'd2,
    ST_CIM   = 3'd3,
    ST_ADC   = 3'd4,
    ST_INC   = 3'd5,
    ST_DONE  = 3'd6
  } state_t;

  state_t state;
  logic [NUM_INPUTS-1:0] wl_reg;
  logic dac_sent;
  logic cim_sent;
  logic adc_sent;

  assign wl_bitmap = wl_reg;

`ifndef SYNTHESIS
  // 参数与运行期简单断言
  initial begin
    if (PIXEL_BITS <= 0) begin
      $fatal(1, "[cim_array_ctrl] PIXEL_BITS 需 > 0");
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n && busy) begin
      /* verilator lint_off CMPCONST */
      assert (bitplane_shift <= BITPLANE_MAX)
        else $fatal(1, "[cim_array_ctrl] bitplane_shift 越界: %0d", bitplane_shift);
      /* verilator lint_on CMPCONST */
    end
  end
`endif
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state            <= ST_IDLE;
      wl_reg           <= '0;
      wl_valid_pulse   <= 1'b0;
      cim_start_pulse  <= 1'b0;
      adc_kick_pulse   <= 1'b0;
      in_fifo_pop      <= 1'b0;
      busy             <= 1'b0;
      done_pulse       <= 1'b0;
      timestep_counter<= 8'h0;
      bitplane_shift  <= BITPLANE_MAX;
      dac_sent         <= 1'b0;
      cim_sent         <= 1'b0;
      adc_sent         <= 1'b0;
    end else begin
      wl_valid_pulse  <= 1'b0;
      cim_start_pulse <= 1'b0;
      adc_kick_pulse  <= 1'b0;
      in_fifo_pop     <= 1'b0;
      done_pulse      <= 1'b0;

      if (soft_reset_pulse) begin
        state             <= ST_IDLE;
        busy              <= 1'b0;
        timestep_counter <= 8'h0;
        bitplane_shift   <= BITPLANE_MAX;
        dac_sent          <= 1'b0;
        cim_sent          <= 1'b0;
        adc_sent          <= 1'b0;
      end else begin
        case (state)
          ST_IDLE: begin
            busy <= 1'b0;
            if (start_pulse) begin
              if (timesteps == 0) begin
                // timesteps=0：立即完成，不进入推理流程
                busy              <= 1'b0;
                timestep_counter <= 8'h0;
                bitplane_shift    <= BITPLANE_MAX;
                done_pulse        <= 1'b1;
                state             <= ST_IDLE;
              end else begin
                busy              <= 1'b1;
                timestep_counter <= 8'h0;
                bitplane_shift    <= BITPLANE_MAX;
                state             <= ST_FETCH;
              end
            end
          end

          ST_FETCH: begin
            // 每个 FIFO 条目是一幅输入帧的一个 bit-plane（MSB->LSB）
            // 若 FIFO 为空，本步使用全 0 wl_bitmap
            if (!in_fifo_empty) begin
              wl_reg      <= in_fifo_rdata;
              in_fifo_pop <= 1'b1;
            end else begin
              wl_reg <= '0;
            end
            dac_sent <= 1'b0;
            state    <= ST_DAC;
          end

          ST_DAC: begin
            if (!dac_sent) begin
              wl_valid_pulse <= 1'b1;
              dac_sent       <= 1'b1;
            end
            if (dac_done_pulse) begin
              cim_sent <= 1'b0;
              state    <= ST_CIM;
            end
          end

          ST_CIM: begin
            if (!cim_sent) begin
              cim_start_pulse <= 1'b1;
              cim_sent        <= 1'b1;
            end
            if (cim_done) begin
              adc_sent <= 1'b0;
              state    <= ST_ADC;
            end
          end

          ST_ADC: begin
            if (!adc_sent) begin
              adc_kick_pulse <= 1'b1;
              adc_sent       <= 1'b1;
            end
            if (neuron_in_valid) begin
              state <= ST_INC;
            end
          end

          ST_INC: begin
            // bit-plane 子时间步：先 MSB 后 LSB（bit 7 -> bit 0）
            if (bitplane_shift == 0) begin
              if (timestep_counter + 1 >= timesteps) begin
                state <= ST_DONE;
              end else begin
                timestep_counter <= timestep_counter + 1'b1;
                bitplane_shift   <= BITPLANE_MAX;
                state            <= ST_FETCH;
              end
            end else begin
              bitplane_shift <= bitplane_shift - 1'b1;
              state <= ST_FETCH;
            end
          end

          ST_DONE: begin
            busy       <= 1'b0;
            done_pulse <= 1'b1;
            state      <= ST_IDLE;
          end

          default: state <= ST_IDLE;
        endcase
      end
    end
  end
endmodule
