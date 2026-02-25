`timescale 1ns/1ps
//======================================================================
// 文件名: dac_ctrl.sv
// 描述: DAC 控制器。
//       - wl_valid_pulse 到来时锁存 wl_bitmap
//       - 拉高 dac_valid，等待 dac_ready
//       - dac_ready 后等待 DAC_LATENCY_CYCLES，产生 dac_done_pulse
//======================================================================
module dac_ctrl (
  input  logic clk,
  input  logic rst_n,

  input  logic [snn_soc_pkg::NUM_INPUTS-1:0] wl_bitmap,
  input  logic wl_valid_pulse,

  output logic [snn_soc_pkg::NUM_INPUTS-1:0] wl_spike,
  output logic dac_valid,
  input  logic dac_ready,
  output logic dac_done_pulse
);
  import snn_soc_pkg::*;

  typedef enum logic [1:0] {
    ST_IDLE  = 2'd0,
    ST_WAIT  = 2'd1,
    ST_LAT   = 2'd2
  } state_t;

  state_t state;
  logic [7:0] lat_cnt;
  logic [NUM_INPUTS-1:0] wl_reg;

  assign wl_spike = wl_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state          <= ST_IDLE;
      dac_valid      <= 1'b0;
      dac_done_pulse <= 1'b0;
      lat_cnt        <= 8'h0;
      wl_reg         <= '0;
    end else begin
      dac_done_pulse <= 1'b0;

      case (state)
        ST_IDLE: begin
          dac_valid <= 1'b0;
          if (wl_valid_pulse) begin
            wl_reg    <= wl_bitmap;
            dac_valid <= 1'b1;
            state     <= ST_WAIT;
          end
        end

        ST_WAIT: begin
          if (dac_ready) begin
            dac_valid <= 1'b0;
            // 让“延迟 N 周期”的语义更直观：计数 N 个周期后 done
            lat_cnt   <= (DAC_LATENCY_CYCLES == 0) ? 8'h0
                                                   : (DAC_LATENCY_CYCLES[7:0] - 8'h1);
            state     <= ST_LAT;
          end
        end

        ST_LAT: begin
          if (lat_cnt == 0) begin
            dac_done_pulse <= 1'b1;
            state          <= ST_IDLE;
          end else begin
            lat_cnt <= lat_cnt - 1'b1;
          end
        end
        default: state <= ST_IDLE;
      endcase
    end
  end
endmodule
