//======================================================================
// 文件名: cim_array_ctrl.sv
// 描述: CIM 阵列控制器核心 FSM。
//       状态流转：
//       IDLE -> STEP_FETCH -> STEP_DAC -> STEP_CIM -> STEP_ADC -> STEP_INC -> DONE
//======================================================================
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
  output logic [7:0] timestep_counter
);
  import snn_soc_pkg::*;

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
        dac_sent          <= 1'b0;
        cim_sent          <= 1'b0;
        adc_sent          <= 1'b0;
      end else begin
        case (state)
          ST_IDLE: begin
            busy <= 1'b0;
            if (start_pulse) begin
              busy              <= 1'b1;
              timestep_counter <= 8'h0;
              state             <= ST_FETCH;
            end
          end

          ST_FETCH: begin
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
            if (timestep_counter + 1 >= timesteps) begin
              state <= ST_DONE;
            end else begin
              timestep_counter <= timestep_counter + 1'b1;
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
