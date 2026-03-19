`timescale 1ns/1ps

module icb_err_slave (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        i_icb_cmd_valid,
  output logic        i_icb_cmd_ready,
  input  logic [31:0] i_icb_cmd_addr,
  input  logic        i_icb_cmd_read,
  input  logic [31:0] i_icb_cmd_wdata,
  input  logic [3:0]  i_icb_cmd_wmask,
  output logic        i_icb_rsp_valid,
  input  logic        i_icb_rsp_ready,
  output logic        i_icb_rsp_err,
  output logic [31:0] i_icb_rsp_rdata
);
  typedef enum logic {ST_IDLE, ST_RSP} state_t;

  state_t state_q;

  wire _unused = &{1'b0, i_icb_cmd_addr, i_icb_cmd_read, i_icb_cmd_wdata, i_icb_cmd_wmask};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (i_icb_cmd_valid) begin
            state_q <= ST_RSP;
          end
        end
        ST_RSP: begin
          if (i_icb_rsp_ready) begin
            state_q <= ST_IDLE;
          end
        end
        default: begin
          state_q <= ST_IDLE;
        end
      endcase
    end
  end

  always_comb begin
    i_icb_cmd_ready = (state_q == ST_IDLE);
    i_icb_rsp_valid = (state_q == ST_RSP);
    i_icb_rsp_err   = 1'b1;
    i_icb_rsp_rdata = 32'h0;
  end
endmodule
