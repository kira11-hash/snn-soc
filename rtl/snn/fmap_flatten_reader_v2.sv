`timescale 1ns/1ps
//======================================================================
// fmap_flatten_reader_v2.sv
//
// Dynamic WL reader for CONV->FC flatten mode. It gathers row-major fmap
// bits into a 256-lane wordline using the same 32-bit padded stream layout
// as patch_unroller_v2.
//======================================================================
module fmap_flatten_reader_v2
  import snn_soc_pkg::*;
#(
  parameter int P_N_IN       = V2B_NUM_INPUTS,
  parameter int P_BANK_WORDS = (V2B_CONV_FMAP_BANK_KIB * 1024) / 4
) (
  input  logic clk,
  input  logic rst_n,

  input  logic        ctx_valid,
  input  logic [15:0] flat_tile_idx,
  input  logic [15:0] cfg_H,
  input  logic [15:0] cfg_W,
  input  logic [15:0] cfg_C,
  input  logic [31:0] cfg_fmap_base_word,
  input  logic [3:0]  cfg_stream_words,

  input  logic        dyn_wl_req_valid,
  output logic        dyn_wl_req_ready,
  input  logic [8:0]  dyn_wl_req_timestep,

  output logic        dyn_wl_resp_valid,
  input  logic        dyn_wl_resp_ready,
  output logic [255:0] dyn_wl_resp_data,
  output logic [8:0]  dyn_wl_resp_valid_count,

  output logic        fmap_rd_en,
  output logic [31:0] fmap_rd_word_addr,
  input  logic [31:0] fmap_rd_data
);

  typedef enum logic [2:0] {
    S_IDLE       = 3'd0,
    S_CTX_LATCH  = 3'd1,
    S_WAIT_REQ   = 3'd2,
    S_PREP_LANE  = 3'd3,
    S_ISSUE_READ = 3'd4,
    S_WAIT_READ  = 3'd5,
    S_RESPOND    = 3'd6
  } state_e;

  state_e state;

  logic [15:0] flat_tile_idx_q;
  logic [15:0] cfg_H_q, cfg_W_q, cfg_C_q;
  logic [31:0] cfg_fmap_base_word_q;
  logic [3:0]  cfg_stream_words_q;
  logic [31:0] flat_dim_q;
  logic [31:0] tile_base_q;
  logic [8:0]  valid_count_q;

  logic [8:0]  req_timestep_q;
  logic [8:0]  lane_idx;
  logic [7:0]  read_lane_q;
  logic [4:0]  read_bit_idx_q;
  logic [31:0] read_addr_q;
  logic [255:0] resp_data_q;

  assign dyn_wl_req_ready        = (state == S_WAIT_REQ);
  assign dyn_wl_resp_valid       = (state == S_RESPOND);
  assign dyn_wl_resp_data        = resp_data_q;
  assign dyn_wl_resp_valid_count = valid_count_q;
  assign fmap_rd_en              = (state == S_ISSUE_READ);
  assign fmap_rd_word_addr       = read_addr_q;

  function automatic [8:0] calc_valid_count(input [31:0] full_dim,
                                            input [31:0] tile_base);
    logic [31:0] remaining;
    begin
      if (tile_base >= full_dim) begin
        calc_valid_count = 9'd0;
      end else begin
        remaining = full_dim - tile_base;
        calc_valid_count = (remaining >= P_N_IN) ? 9'd256 : remaining[8:0];
      end
    end
  endfunction

  function automatic [31:0] calc_word_addr(input int unsigned flat_idx,
                                           input [8:0] timestep);
    int unsigned c_eff;
    int unsigned w_eff;
    int unsigned chan;
    int unsigned pixel;
    int unsigned row;
    int unsigned col;
    int unsigned linear_stream;
    begin
      c_eff = (cfg_C_q == 0) ? 1 : cfg_C_q;
      w_eff = (cfg_W_q == 0) ? 1 : cfg_W_q;
      chan = flat_idx % c_eff;
      pixel = flat_idx / c_eff;
      row = pixel / w_eff;
      col = pixel % w_eff;
      linear_stream = (((row * cfg_W_q) + col) * cfg_C_q) + chan;
      calc_word_addr = cfg_fmap_base_word_q
                     + (linear_stream * cfg_stream_words_q)
                     + (timestep >> 5);
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      flat_tile_idx_q <= '0;
      cfg_H_q <= '0; cfg_W_q <= '0; cfg_C_q <= '0;
      cfg_fmap_base_word_q <= '0; cfg_stream_words_q <= '0;
      flat_dim_q <= '0; tile_base_q <= '0; valid_count_q <= '0;
      req_timestep_q <= '0; lane_idx <= '0; read_lane_q <= '0; read_bit_idx_q <= '0;
      read_addr_q <= '0; resp_data_q <= '0;
    end else begin
      case (state)
        S_IDLE: begin
          if (ctx_valid) begin
            flat_tile_idx_q <= flat_tile_idx;
            cfg_H_q <= cfg_H;
            cfg_W_q <= cfg_W;
            cfg_C_q <= cfg_C;
            cfg_fmap_base_word_q <= cfg_fmap_base_word;
            cfg_stream_words_q <= cfg_stream_words;
            flat_dim_q <= cfg_H * cfg_W * cfg_C;
            tile_base_q <= flat_tile_idx * P_N_IN;
            valid_count_q <= calc_valid_count(cfg_H * cfg_W * cfg_C,
                                              flat_tile_idx * P_N_IN);
            state <= S_CTX_LATCH;
          end
        end

        S_CTX_LATCH: begin
          state <= S_WAIT_REQ;
        end

        S_WAIT_REQ: begin
          if (ctx_valid) begin
            flat_tile_idx_q <= flat_tile_idx;
            cfg_H_q <= cfg_H;
            cfg_W_q <= cfg_W;
            cfg_C_q <= cfg_C;
            cfg_fmap_base_word_q <= cfg_fmap_base_word;
            cfg_stream_words_q <= cfg_stream_words;
            flat_dim_q <= cfg_H * cfg_W * cfg_C;
            tile_base_q <= flat_tile_idx * P_N_IN;
            valid_count_q <= calc_valid_count(cfg_H * cfg_W * cfg_C,
                                              flat_tile_idx * P_N_IN);
          end
          if (dyn_wl_req_valid) begin
            req_timestep_q <= dyn_wl_req_timestep;
            lane_idx <= '0;
            resp_data_q <= '0;
            state <= S_PREP_LANE;
          end
        end

        S_PREP_LANE: begin
          if (lane_idx == 9'd256) begin
            state <= S_RESPOND;
          end else if (lane_idx >= valid_count_q) begin
            resp_data_q[lane_idx[7:0]] <= 1'b0;
            lane_idx <= lane_idx + 9'd1;
          end else begin
            read_addr_q <= calc_word_addr(tile_base_q + lane_idx, req_timestep_q);
            read_lane_q <= lane_idx[7:0];
            read_bit_idx_q <= req_timestep_q[4:0];
            state <= S_ISSUE_READ;
          end
        end

        S_ISSUE_READ: begin
          state <= S_WAIT_READ;
        end

        S_WAIT_READ: begin
          resp_data_q[read_lane_q] <= fmap_rd_data[read_bit_idx_q];
          lane_idx <= lane_idx + 9'd1;
          state <= S_PREP_LANE;
        end

        S_RESPOND: begin
          if (dyn_wl_resp_ready) begin
            state <= S_WAIT_REQ;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
`ifdef VCS
  property SVA_DYN_WL_RESP_COUNT_RANGE;
    @(posedge clk) disable iff (!rst_n)
      dyn_wl_resp_valid |-> (dyn_wl_resp_valid_count inside {[9'd1:9'd256]});
  endproperty
  assert property (SVA_DYN_WL_RESP_COUNT_RANGE);

  property SVA_DYN_WL_RESP_NOT_SAME_CYCLE;
    @(posedge clk) disable iff (!rst_n)
      (dyn_wl_req_valid && dyn_wl_req_ready) |-> !dyn_wl_resp_valid;
  endproperty
  assert property (SVA_DYN_WL_RESP_NOT_SAME_CYCLE);

  property SVA_DYN_WL_RESP_STABLE_UNTIL_READY;
    @(posedge clk) disable iff (!rst_n)
      (dyn_wl_resp_valid && !dyn_wl_resp_ready)
      |=> $stable({dyn_wl_resp_data, dyn_wl_resp_valid_count});
  endproperty
  assert property (SVA_DYN_WL_RESP_STABLE_UNTIL_READY);

  property SVA_FLAT_ROW_MAJOR_ADDR;
    @(posedge clk) disable iff (!rst_n)
      fmap_rd_en |-> (fmap_rd_word_addr < P_BANK_WORDS);
  endproperty
  assert property (SVA_FLAT_ROW_MAJOR_ADDR);
`endif
`endif

endmodule
