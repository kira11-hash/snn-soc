`timescale 1ns/1ps
//======================================================================
// patch_unroller_v2.sv
//
// Dynamic WL reader for CONV mode. A latched spatial/tile context plus a
// per-timestep request yields one 256-bit word-line response gathered from
// the 32-bit padded fmap layout.
//======================================================================
module patch_unroller_v2
  import snn_soc_pkg::*;
#(
  parameter int P_N_IN      = V2B_NUM_INPUTS,
  parameter int P_BANK_WORDS = (V2B_CONV_FMAP_BANK_KIB * 1024) / 4
) (
  input  logic clk,
  input  logic rst_n,

  input  logic        ctx_valid,
  input  logic [7:0]  ctx_h,
  input  logic [7:0]  ctx_w,
  input  logic [15:0] ctx_tile_idx,
  input  logic [3:0]  cfg_K,
  input  logic [3:0]  cfg_stride,
  input  logic [3:0]  cfg_pad,
  input  logic [15:0] cfg_C_in,
  input  logic [15:0] cfg_H,
  input  logic [15:0] cfg_W,
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

  typedef enum logic [3:0] {
    S_IDLE       = 4'd0,
    S_CTX_LATCH  = 4'd1,
    S_CTX_PREP   = 4'd2,
    S_BUILD_CTX  = 4'd3,
    S_WAIT_REQ   = 4'd4,
    S_PREP_LANE  = 4'd5,
    S_ISSUE_READ = 4'd6,
    S_WAIT_READ  = 4'd7,
    S_RESPOND    = 4'd8
  } state_e;

  state_e state;

  logic [7:0]  ctx_h_q, ctx_w_q;
  logic [15:0] ctx_tile_idx_q;
  logic [3:0]  cfg_K_q, cfg_stride_q, cfg_pad_q, cfg_stream_words_q;
  logic [15:0] cfg_C_in_q, cfg_H_q, cfg_W_q;
  logic [31:0] cfg_fmap_base_word_q;

  logic [8:0]  req_timestep_q;
  logic [8:0]  lane_idx;
  logic [7:0]  read_lane_q;
  logic [4:0]  read_bit_idx_q;
  logic [31:0] read_addr_q;
  logic [255:0] resp_data_q;
  logic [8:0]  valid_count_q;
  logic [31:0] full_dim_q;
  logic [31:0] tile_base_q;

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

  function automatic [31:0] calc_word_addr(input int unsigned src_h,
                                           input int unsigned src_w,
                                           input int unsigned chan,
                                           input [8:0] timestep);
    int unsigned linear_stream;
    begin
      linear_stream = (((src_h * cfg_W_q) + src_w) * cfg_C_in_q) + chan;
      calc_word_addr = cfg_fmap_base_word_q
                     + (linear_stream * cfg_stream_words_q)
                     + (timestep >> 5);
    end
  endfunction

  task automatic prep_lane(
    output logic should_read,
    output logic [31:0] addr,
    output logic [4:0] bit_idx
  );
    int unsigned c_eff;
    int unsigned k_eff;
    int unsigned logical_idx;
    int unsigned chan;
    int unsigned k_linear;
    int unsigned ky;
    int unsigned kx;
    int signed src_h_s;
    int signed src_w_s;
    begin
      should_read = 1'b0;
      addr = 32'h0;
      bit_idx = req_timestep_q[4:0];
      c_eff = (cfg_C_in_q == 0) ? 1 : cfg_C_in_q;
      k_eff = (cfg_K_q == 0) ? 1 : cfg_K_q;
      logical_idx = tile_base_q + lane_idx;
      chan = logical_idx % c_eff;
      k_linear = logical_idx / c_eff;
      ky = k_linear / k_eff;
      kx = k_linear % k_eff;
      src_h_s = (int'(ctx_h_q) * int'(cfg_stride_q)) + int'(ky) - int'(cfg_pad_q);
      src_w_s = (int'(ctx_w_q) * int'(cfg_stride_q)) + int'(kx) - int'(cfg_pad_q);
      if (src_h_s >= 0 && src_h_s < int'(cfg_H_q) &&
          src_w_s >= 0 && src_w_s < int'(cfg_W_q)) begin
        should_read = 1'b1;
        addr = calc_word_addr(src_h_s, src_w_s, chan, req_timestep_q);
      end
    end
  endtask

  logic lane_should_read;
  logic [31:0] lane_addr;
  logic [4:0] lane_bit_idx;

`ifndef SYNTHESIS
  logic [31:0] lane_word_cache [0:P_N_IN-1];
  logic        cache_valid;
  logic [3:0]  cache_word_idx;
  integer      cache_lane;
`else
  logic        lane_can_read_q [0:P_N_IN-1];
  logic [31:0] lane_base_addr_q [0:P_N_IN-1];
  logic [8:0]  build_fill_idx_q;
  logic [31:0] build_logical_idx_q;
  logic [15:0] build_c_q;
  logic [3:0]  build_kx_q, build_ky_q;
  logic signed [17:0] ctx_src_h_base_q, ctx_src_w_base_q;
  logic signed [17:0] cur_src_h_q, cur_src_w_q;
  logic signed [31:0] row_stride_words_q, col_stride_words_q, row_wrap_delta_q;
  logic signed [31:0] ctx_base_pos_q, cur_pos_base_q, cur_chan_base_q;
`endif

  function automatic signed [17:0] calc_src_origin(input [7:0] ctx_pos,
                                                    input [3:0] stride,
                                                    input [3:0] pad);
    integer signed tmp;
    begin
      tmp = integer'(ctx_pos) * integer'(stride) - integer'(pad);
      calc_src_origin = tmp[17:0];
    end
  endfunction

  function automatic logic src_in_bounds(input signed [17:0] src_h,
                                         input signed [17:0] src_w);
    begin
      src_in_bounds = (src_h >= 0) && (src_h < $signed({1'b0, cfg_H_q})) &&
                      (src_w >= 0) && (src_w < $signed({1'b0, cfg_W_q}));
    end
  endfunction

  function automatic signed [31:0] calc_signed_word_base(
    input signed [17:0] src_h,
    input signed [17:0] src_w,
    input signed [31:0] row_stride_words,
    input signed [31:0] col_stride_words
  );
    integer signed tmp;
    begin
      tmp = integer'(cfg_fmap_base_word_q)
          + integer'(src_h) * integer'(row_stride_words)
          + integer'(src_w) * integer'(col_stride_words);
      calc_signed_word_base = tmp[31:0];
    end
  endfunction

`ifndef SYNTHESIS
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      ctx_h_q <= '0; ctx_w_q <= '0; ctx_tile_idx_q <= '0;
      cfg_K_q <= '0; cfg_stride_q <= '0; cfg_pad_q <= '0;
      cfg_C_in_q <= '0; cfg_H_q <= '0; cfg_W_q <= '0;
      cfg_fmap_base_word_q <= '0; cfg_stream_words_q <= '0;
      req_timestep_q <= '0; lane_idx <= '0; read_lane_q <= '0; read_bit_idx_q <= '0;
      read_addr_q <= '0; resp_data_q <= '0; valid_count_q <= '0;
      full_dim_q <= '0; tile_base_q <= '0;
      cache_valid <= 1'b0;
      cache_word_idx <= '0;
      for (cache_lane = 0; cache_lane < P_N_IN; cache_lane = cache_lane + 1) begin
        lane_word_cache[cache_lane] <= 32'h0;
      end
    end else begin
      case (state)
        S_IDLE: begin
          if (ctx_valid) begin
            ctx_h_q <= ctx_h;
            ctx_w_q <= ctx_w;
            ctx_tile_idx_q <= ctx_tile_idx;
            cfg_K_q <= cfg_K;
            cfg_stride_q <= cfg_stride;
            cfg_pad_q <= cfg_pad;
            cfg_C_in_q <= cfg_C_in;
            cfg_H_q <= cfg_H;
            cfg_W_q <= cfg_W;
            cfg_fmap_base_word_q <= cfg_fmap_base_word;
            cfg_stream_words_q <= cfg_stream_words;
            full_dim_q <= cfg_K * cfg_K * cfg_C_in;
            tile_base_q <= ctx_tile_idx * P_N_IN;
            valid_count_q <= calc_valid_count(cfg_K * cfg_K * cfg_C_in,
                                              ctx_tile_idx * P_N_IN);
            cache_valid <= 1'b0;
            state <= S_CTX_LATCH;
          end
        end

        S_CTX_LATCH: begin
          state <= S_WAIT_REQ;
        end

        S_WAIT_REQ: begin
          if (ctx_valid) begin
            ctx_h_q <= ctx_h;
            ctx_w_q <= ctx_w;
            ctx_tile_idx_q <= ctx_tile_idx;
            cfg_K_q <= cfg_K;
            cfg_stride_q <= cfg_stride;
            cfg_pad_q <= cfg_pad;
            cfg_C_in_q <= cfg_C_in;
            cfg_H_q <= cfg_H;
            cfg_W_q <= cfg_W;
            cfg_fmap_base_word_q <= cfg_fmap_base_word;
            cfg_stream_words_q <= cfg_stream_words;
            full_dim_q <= cfg_K * cfg_K * cfg_C_in;
            tile_base_q <= ctx_tile_idx * P_N_IN;
            valid_count_q <= calc_valid_count(cfg_K * cfg_K * cfg_C_in,
                                              ctx_tile_idx * P_N_IN);
            cache_valid <= 1'b0;
          end
          if (dyn_wl_req_valid) begin
            req_timestep_q <= dyn_wl_req_timestep;
            lane_idx <= '0;
            resp_data_q <= '0;
            state <= S_PREP_LANE;
          end
        end

        S_PREP_LANE: begin
          if (cache_valid && cache_word_idx == req_timestep_q[8:5]) begin
            for (cache_lane = 0; cache_lane < P_N_IN; cache_lane = cache_lane + 1) begin
              if (cache_lane < valid_count_q) begin
                resp_data_q[cache_lane] <= lane_word_cache[cache_lane][req_timestep_q[4:0]];
              end else begin
                resp_data_q[cache_lane] <= 1'b0;
              end
            end
            state <= S_RESPOND;
          end else if (lane_idx == 9'd256) begin
            cache_valid <= 1'b1;
            cache_word_idx <= req_timestep_q[8:5];
            state <= S_RESPOND;
          end else if (lane_idx >= valid_count_q) begin
            lane_word_cache[lane_idx[7:0]] <= 32'h0;
            resp_data_q[lane_idx[7:0]] <= 1'b0;
            lane_idx <= lane_idx + 9'd1;
          end else begin
            prep_lane(lane_should_read, lane_addr, lane_bit_idx);
            if (lane_should_read) begin
              read_addr_q <= lane_addr;
              read_lane_q <= lane_idx[7:0];
              read_bit_idx_q <= lane_bit_idx;
              state <= S_ISSUE_READ;
            end else begin
              lane_word_cache[lane_idx[7:0]] <= 32'h0;
              resp_data_q[lane_idx[7:0]] <= 1'b0;
              lane_idx <= lane_idx + 9'd1;
            end
          end
        end

        S_ISSUE_READ: begin
          state <= S_WAIT_READ;
        end

        S_WAIT_READ: begin
          lane_word_cache[read_lane_q] <= fmap_rd_data;
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
`else
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      ctx_h_q <= '0; ctx_w_q <= '0; ctx_tile_idx_q <= '0;
      cfg_K_q <= '0; cfg_stride_q <= '0; cfg_pad_q <= '0;
      cfg_C_in_q <= '0; cfg_H_q <= '0; cfg_W_q <= '0;
      cfg_fmap_base_word_q <= '0; cfg_stream_words_q <= '0;
      req_timestep_q <= '0; lane_idx <= '0; read_lane_q <= '0; read_bit_idx_q <= '0;
      read_addr_q <= '0; resp_data_q <= '0; valid_count_q <= '0;
      full_dim_q <= '0; tile_base_q <= '0;
      build_fill_idx_q <= '0;
      build_logical_idx_q <= '0;
      build_c_q <= '0;
      build_kx_q <= '0;
      build_ky_q <= '0;
      ctx_src_h_base_q <= '0;
      ctx_src_w_base_q <= '0;
      cur_src_h_q <= '0;
      cur_src_w_q <= '0;
      row_stride_words_q <= '0;
      col_stride_words_q <= '0;
      row_wrap_delta_q <= '0;
      ctx_base_pos_q <= '0;
      cur_pos_base_q <= '0;
      cur_chan_base_q <= '0;
    end else begin
      case (state)
        S_IDLE: begin
          if (ctx_valid) begin
            ctx_h_q <= ctx_h;
            ctx_w_q <= ctx_w;
            ctx_tile_idx_q <= ctx_tile_idx;
            cfg_K_q <= cfg_K;
            cfg_stride_q <= cfg_stride;
            cfg_pad_q <= cfg_pad;
            cfg_C_in_q <= cfg_C_in;
            cfg_H_q <= cfg_H;
            cfg_W_q <= cfg_W;
            cfg_fmap_base_word_q <= cfg_fmap_base_word;
            cfg_stream_words_q <= cfg_stream_words;
            full_dim_q <= cfg_K * cfg_K * cfg_C_in;
            tile_base_q <= ctx_tile_idx * P_N_IN;
            valid_count_q <= calc_valid_count(cfg_K * cfg_K * cfg_C_in,
                                              ctx_tile_idx * P_N_IN);
            state <= S_CTX_LATCH;
          end
        end

        S_CTX_LATCH: begin
          row_stride_words_q <= $signed({1'b0, (cfg_W_q * cfg_C_in_q * cfg_stream_words_q)});
          col_stride_words_q <= $signed({1'b0, (cfg_C_in_q * cfg_stream_words_q)});
          ctx_src_h_base_q <= calc_src_origin(ctx_h_q, cfg_stride_q, cfg_pad_q);
          ctx_src_w_base_q <= calc_src_origin(ctx_w_q, cfg_stride_q, cfg_pad_q);
          state <= S_CTX_PREP;
        end

        S_CTX_PREP: begin
          row_wrap_delta_q <= row_stride_words_q
                            - $signed({1'b0, ((cfg_K_q - 4'd1) * col_stride_words_q[15:0])});
          ctx_base_pos_q <= calc_signed_word_base(ctx_src_h_base_q,
                                                  ctx_src_w_base_q,
                                                  row_stride_words_q,
                                                  col_stride_words_q);
          cur_pos_base_q <= calc_signed_word_base(ctx_src_h_base_q,
                                                  ctx_src_w_base_q,
                                                  row_stride_words_q,
                                                  col_stride_words_q);
          cur_chan_base_q <= calc_signed_word_base(ctx_src_h_base_q,
                                                   ctx_src_w_base_q,
                                                   row_stride_words_q,
                                                   col_stride_words_q);
          cur_src_h_q <= ctx_src_h_base_q;
          cur_src_w_q <= ctx_src_w_base_q;
          build_fill_idx_q <= '0;
          build_logical_idx_q <= '0;
          build_c_q <= '0;
          build_kx_q <= '0;
          build_ky_q <= '0;
          state <= S_BUILD_CTX;
        end

        S_BUILD_CTX: begin
          if (build_logical_idx_q >= full_dim_q || build_fill_idx_q == 9'd256) begin
            state <= S_WAIT_REQ;
          end else begin
            if (build_logical_idx_q >= tile_base_q && build_fill_idx_q < 9'd256) begin
              lane_can_read_q[build_fill_idx_q[7:0]] <= src_in_bounds(cur_src_h_q, cur_src_w_q);
              lane_base_addr_q[build_fill_idx_q[7:0]] <= cur_chan_base_q[31:0];
              build_fill_idx_q <= build_fill_idx_q + 9'd1;
            end
            build_logical_idx_q <= build_logical_idx_q + 32'd1;
            if (build_c_q + 16'd1 < cfg_C_in_q) begin
              build_c_q <= build_c_q + 16'd1;
              cur_chan_base_q <= cur_chan_base_q + $signed({1'b0, cfg_stream_words_q});
            end else begin
              build_c_q <= 16'd0;
              if (build_kx_q + 4'd1 < cfg_K_q) begin
                build_kx_q <= build_kx_q + 4'd1;
                cur_src_w_q <= cur_src_w_q + 18'sd1;
                cur_pos_base_q <= cur_pos_base_q + col_stride_words_q;
                cur_chan_base_q <= cur_pos_base_q + col_stride_words_q;
              end else begin
                build_kx_q <= 4'd0;
                cur_src_w_q <= ctx_src_w_base_q;
                if (build_ky_q + 4'd1 < cfg_K_q) begin
                  build_ky_q <= build_ky_q + 4'd1;
                  cur_src_h_q <= cur_src_h_q + 18'sd1;
                  cur_pos_base_q <= cur_pos_base_q + row_wrap_delta_q;
                  cur_chan_base_q <= cur_pos_base_q + row_wrap_delta_q;
                end
              end
            end
          end
        end

        S_WAIT_REQ: begin
          if (ctx_valid) begin
            ctx_h_q <= ctx_h;
            ctx_w_q <= ctx_w;
            ctx_tile_idx_q <= ctx_tile_idx;
            cfg_K_q <= cfg_K;
            cfg_stride_q <= cfg_stride;
            cfg_pad_q <= cfg_pad;
            cfg_C_in_q <= cfg_C_in;
            cfg_H_q <= cfg_H;
            cfg_W_q <= cfg_W;
            cfg_fmap_base_word_q <= cfg_fmap_base_word;
            cfg_stream_words_q <= cfg_stream_words;
            full_dim_q <= cfg_K * cfg_K * cfg_C_in;
            tile_base_q <= ctx_tile_idx * P_N_IN;
            valid_count_q <= calc_valid_count(cfg_K * cfg_K * cfg_C_in,
                                              ctx_tile_idx * P_N_IN);
            state <= S_CTX_LATCH;
          end else if (dyn_wl_req_valid) begin
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
          end else if (!lane_can_read_q[lane_idx[7:0]]) begin
            resp_data_q[lane_idx[7:0]] <= 1'b0;
            lane_idx <= lane_idx + 9'd1;
          end else begin
            read_addr_q <= lane_base_addr_q[lane_idx[7:0]] + {27'd0, req_timestep_q[8:5]};
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
`endif

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

  property SVA_PATCH_WORD_ADDR_IN_RANGE;
    @(posedge clk) disable iff (!rst_n)
      fmap_rd_en |-> (fmap_rd_word_addr < P_BANK_WORDS);
  endproperty
  assert property (SVA_PATCH_WORD_ADDR_IN_RANGE);

  // SVA_PATCH_LAST_TILE_ZERO_PAD is covered by the response construction and
  // the unit TB; variable part-select assertions are avoided for simulator
  // portability.
`endif
`endif

endmodule
