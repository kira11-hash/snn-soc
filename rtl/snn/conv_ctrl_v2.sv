`timescale 1ns/1ps
//======================================================================
// conv_ctrl_v2.sv
//
// V2.B CONV extension outer controller. It owns configuration validation,
// spatial/tile loops, FW-managed weight request/ready handshake, stage_engine
// launches, and final spike writeback into fmap_sram_v2.
//======================================================================
module conv_ctrl_v2
  import snn_soc_pkg::*;
#(
  parameter int P_N_IN       = V2B_NUM_INPUTS,
  parameter int P_N_OUT      = V2B_MAX_OUT_NEURONS,
  parameter int P_T_MAX      = V2B_MAX_TIMESTEPS,
  parameter int P_BANK_WORDS = (V2B_CONV_FMAP_BANK_KIB * 1024) / 4,
  parameter int P_WEIGHT_TIMEOUT_CYCLES = V2B_CONV_WEIGHT_TIMEOUT_CYCLES
) (
  input  logic clk,
  input  logic rst_n,

  input  logic        cfg_conv_mode,
  input  logic        cfg_flatten_mode,
  input  logic        cfg_pp_sel,
  input  logic        cfg_weight_timeout_en,
  input  logic [15:0] cfg_H,
  input  logic [15:0] cfg_W,
  input  logic [15:0] cfg_C_in,
  input  logic [15:0] cfg_C_out,
  input  logic [3:0]  cfg_K,
  input  logic [3:0]  cfg_stride,
  input  logic [3:0]  cfg_pad,
  input  logic [15:0] cfg_out_H,
  input  logic [15:0] cfg_out_W,
  input  logic [15:0] cfg_T_count,
  input  logic [15:0] cfg_tile_count,
  input  logic [15:0] cfg_last_tile_valid_count,
  input  logic [31:0] cfg_fmap_base_word,
  input  logic [31:0] cfg_out_base_word,
  input  logic [31:0] cfg_threshold,
  input  logic [31:0] cfg_sum_max,

  input  logic start_pulse,
  input  logic abort_pulse,
  input  logic weight_ready_pulse,
  input  logic done_clear_pulse,
  input  logic fmap_wr_commit_pulse,
  input  logic [31:0] fmap_wr_addr,

  output logic busy,
  output logic done_sticky,
  output logic weight_req,
  output logic [7:0] current_pixel_h,
  output logic [7:0] current_pixel_w,
  output logic [7:0] current_tile_idx,
  output logic [3:0] err_code,
  output logic [31:0] perf_cycles,

  output logic patch_ctx_valid,
  output logic [7:0] patch_ctx_h,
  output logic [7:0] patch_ctx_w,
  output logic [15:0] patch_ctx_tile_idx,
  output logic [3:0] patch_cfg_K,
  output logic [3:0] patch_cfg_stride,
  output logic [3:0] patch_cfg_pad,
  output logic [15:0] patch_cfg_C_in,
  output logic [15:0] patch_cfg_H,
  output logic [15:0] patch_cfg_W,
  output logic [31:0] patch_cfg_fmap_base_word,
  output logic [3:0] patch_cfg_stream_words,

  output logic flat_ctx_valid,
  output logic [15:0] flat_tile_idx,
  output logic [15:0] flat_cfg_H,
  output logic [15:0] flat_cfg_W,
  output logic [15:0] flat_cfg_C,
  output logic [31:0] flat_cfg_fmap_base_word,
  output logic [3:0] flat_cfg_stream_words,

  output logic stage_start_pulse,
  output logic [15:0] stage_cfg_in_dim,
  output logic [15:0] stage_cfg_out_dim,
  output logic [31:0] stage_cfg_threshold,
  output logic [31:0] stage_cfg_sum_max,
  output logic [V2B_BUF_SEL_W-1:0] stage_cfg_input_src,
  output logic [1:0]  stage_cfg_output_dst,
  output logic        stage_cfg_tile_mode,
  output logic        stage_cfg_is_tile_final,
  output logic        stage_cfg_preserve_membrane,
  output logic [15:0] stage_cfg_t_count,
  output logic        stage_clear_tile_buf,

  input  logic stage_done_pulse,
  input  logic [7:0] stage_err_code,
  input  logic spike_out_valid,
  input  logic [8:0] spike_out_timestep,
  input  logic [P_N_OUT-1:0] spike_out_vec,

  output logic        fmap_wr_en,
  output logic        fmap_wr_bank_sel,
  output logic [31:0] fmap_wr_word_addr,
  output logic [31:0] fmap_wr_data,
  output logic [3:0]  fmap_wr_strb
);

  localparam logic [3:0] ERR_OK                    = 4'd0;
  localparam logic [3:0] ERR_ILLEGAL_KKC           = 4'd1;
  localparam logic [3:0] ERR_TILE_CFG_MISMATCH     = 4'd2;
  localparam logic [3:0] ERR_BAD_GEOMETRY          = 4'd3;
  localparam logic [3:0] ERR_FMAP_OOB              = 4'd4;
  localparam logic [3:0] ERR_BAD_T                 = 4'd5;
  localparam logic [3:0] ERR_BAD_COUT              = 4'd6;
  localparam logic [3:0] ERR_FMAP_WRITE_WHILE_BUSY = 4'd7;
  localparam logic [3:0] ERR_WEIGHT_TIMEOUT        = 4'd8;
  localparam logic [3:0] ERR_FMAP_WR_OOB           = 4'd9;
`ifndef SYNTHESIS
  localparam int P_WEIGHT_TIMEOUT_CYCLES_EFF =
      (P_WEIGHT_TIMEOUT_CYCLES > 1024) ? 1024 : P_WEIGHT_TIMEOUT_CYCLES;
`else
  localparam int P_WEIGHT_TIMEOUT_CYCLES_EFF = P_WEIGHT_TIMEOUT_CYCLES;
`endif

  typedef enum logic [3:0] {
    S_IDLE         = 4'd0,
    S_VALIDATE     = 4'd1,
    S_SPATIAL_INIT = 4'd2,
    S_WAIT_WEIGHT  = 4'd3,
    S_CTX_ISSUE    = 4'd4,
    S_STAGE_START  = 4'd5,
    S_STAGE_WAIT   = 4'd6,
    S_STAGE_DONE   = 4'd7,
    S_WRITEBACK    = 4'd8,
    S_SPATIAL_NEXT = 4'd9,
    S_DONE         = 4'd10
  } state_e;

  state_e state;

  logic [15:0] cur_h, cur_w, cur_tile;
  logic [31:0] wait_ctr;
  logic [31:0] perf_ctr;
  logic [15:0] write_idx;
  logic [15:0] write_chan_idx, write_stream_idx, write_buf_idx_q;
  logic [3:0]  stream_words_q;
  logic [31:0] input_dim_q;
  logic [15:0] tile_count_expected_q;
  logic [15:0] last_count_expected_q;
  logic [15:0] valid_count_cur;
  logic [31:0] fmap_words_in_q, fmap_words_out_q;
  logic [3:0]  validate_err;
  logic [31:0] out_word_addr_cur;
  logic [31:0] pixel_base_word_q, pixel_stride_words_q, write_addr_cursor_q;

  logic [31:0] spike_word_buf [0:(P_N_OUT*V2B_FMAP_WORDS_PER_STREAM_MAX)-1];

  assign current_pixel_h  = cur_h[7:0];
  assign current_pixel_w  = cur_w[7:0];
  assign current_tile_idx = cur_tile[7:0];
  assign perf_cycles      = perf_ctr;

  assign patch_ctx_h              = cur_h[7:0];
  assign patch_ctx_w              = cur_w[7:0];
  assign patch_ctx_tile_idx       = cur_tile;
  assign patch_cfg_K              = cfg_K;
  assign patch_cfg_stride         = cfg_stride;
  assign patch_cfg_pad            = cfg_pad;
  assign patch_cfg_C_in           = cfg_C_in;
  assign patch_cfg_H              = cfg_H;
  assign patch_cfg_W              = cfg_W;
  assign patch_cfg_fmap_base_word = cfg_fmap_base_word;
  assign patch_cfg_stream_words   = stream_words_q;

  assign flat_tile_idx             = cur_tile;
  assign flat_cfg_H                = cfg_H;
  assign flat_cfg_W                = cfg_W;
  assign flat_cfg_C                = cfg_C_in;
  assign flat_cfg_fmap_base_word   = cfg_fmap_base_word;
  assign flat_cfg_stream_words     = stream_words_q;

  assign stage_cfg_out_dim            = cfg_C_out;
  assign stage_cfg_threshold          = cfg_threshold;
  assign stage_cfg_sum_max            = (cfg_sum_max != 32'd0) ? cfg_sum_max : V2B_ADC_MAX;
  assign stage_cfg_output_dst         = V2B_BUF_SEL_STREAM_A[1:0];
  assign stage_cfg_preserve_membrane  = 1'b0;
  assign stage_cfg_t_count            = cfg_T_count;
  assign stage_cfg_input_src          = cfg_flatten_mode ? V2B_BUF_SEL_FMAP_FLATTEN
                                                         : V2B_BUF_SEL_PATCH_UNROLLER;
  assign stage_cfg_is_tile_final      = (cur_tile == (cfg_tile_count - 16'd1));
  assign stage_cfg_tile_mode          = (cfg_tile_count > 16'd1);
  assign stage_cfg_in_dim             = stage_cfg_is_tile_final
                                      ? cfg_last_tile_valid_count
                                      : 16'(P_N_IN);

  function automatic [3:0] calc_stream_words(input [15:0] t_count);
    calc_stream_words = (t_count + 16'd31) >> 5;
  endfunction

  function automatic [15:0] ceil_div_256(input [31:0] value);
    ceil_div_256 = (value + 32'd255) >> 8;
  endfunction

  function automatic [31:0] conv_out_dim(input [15:0] in_size,
                                         input [3:0] k,
                                         input [3:0] stride,
                                         input [3:0] pad);
    conv_out_dim = ((in_size + {28'h0, pad, 1'b0} - k) / stride) + 1;
  endfunction

  task automatic compute_validate;
    logic [31:0] kkc;
    logic [31:0] input_dim;
    logic [15:0] tiles_exp;
    logic [15:0] last_exp;
    logic [31:0] out_h_exp;
    logic [31:0] out_w_exp;
    logic [3:0]  sw;
    logic [31:0] in_words;
    logic [31:0] out_words;
    begin
      sw = calc_stream_words(cfg_T_count);
      if (cfg_flatten_mode) input_dim = cfg_H * cfg_W * cfg_C_in;
      else                  input_dim = cfg_K * cfg_K * cfg_C_in;
      tiles_exp = (input_dim == 0) ? 16'd0 : ceil_div_256(input_dim);
      last_exp = (tiles_exp == 0) ? 16'd0 : input_dim - ((tiles_exp - 16'd1) * P_N_IN);
      kkc = cfg_K * cfg_K * cfg_C_in;
      out_h_exp = (cfg_stride == 0) ? 32'd0 : conv_out_dim(cfg_H, cfg_K, cfg_stride, cfg_pad);
      out_w_exp = (cfg_stride == 0) ? 32'd0 : conv_out_dim(cfg_W, cfg_K, cfg_stride, cfg_pad);
      in_words = cfg_H * cfg_W * cfg_C_in * sw;
      out_words = cfg_out_H * cfg_out_W * cfg_C_out * sw;

      stream_words_q <= sw;
      input_dim_q <= input_dim;
      tile_count_expected_q <= tiles_exp;
      last_count_expected_q <= last_exp;
      fmap_words_in_q <= in_words;
      fmap_words_out_q <= out_words;

      validate_err <= ERR_OK;
      if (!cfg_flatten_mode && (kkc == 0 || kkc > V2B_CONV_MAX_KKC)) begin
        validate_err <= ERR_ILLEGAL_KKC;
      end else if (cfg_flatten_mode && input_dim == 0) begin
        validate_err <= ERR_ILLEGAL_KKC;
      end else if (cfg_tile_count != tiles_exp ||
                   cfg_last_tile_valid_count != last_exp) begin
        validate_err <= ERR_TILE_CFG_MISMATCH;
      end else if ((!cfg_flatten_mode &&
                   ((cfg_K != 4'd3 && cfg_K != 4'd5) ||
                    (cfg_stride != 4'd1 && cfg_stride != 4'd2) ||
                    cfg_pad > 4'd2 ||
                    cfg_H == 0 || cfg_W == 0 ||
                    cfg_H > V2B_CONV_MAX_H || cfg_W > V2B_CONV_MAX_W ||
                    cfg_C_in == 0 ||
                    cfg_out_H == 0 || cfg_out_W == 0 ||
                    cfg_out_H > V2B_CONV_MAX_H || cfg_out_W > V2B_CONV_MAX_W ||
                    (cfg_H + {11'h0, cfg_pad, 1'b0}) < cfg_K ||
                    (cfg_W + {11'h0, cfg_pad, 1'b0}) < cfg_K ||
                    cfg_out_H != out_h_exp[15:0] ||
                    cfg_out_W != out_w_exp[15:0])) ||
                  (cfg_flatten_mode &&
                   (cfg_H == 0 || cfg_W == 0 ||
                    cfg_H > V2B_CONV_MAX_H || cfg_W > V2B_CONV_MAX_W ||
                    cfg_C_in == 0))) begin
        validate_err <= ERR_BAD_GEOMETRY;
      end else if ((cfg_fmap_base_word + in_words) > P_BANK_WORDS ||
                   (!cfg_flatten_mode &&
                    (cfg_out_base_word + out_words) > P_BANK_WORDS)) begin
        validate_err <= ERR_FMAP_OOB;
      end else if (cfg_T_count == 0 || cfg_T_count > P_T_MAX) begin
        validate_err <= ERR_BAD_T;
      end else if (cfg_C_out == 0 || cfg_C_out > P_N_OUT) begin
        validate_err <= ERR_BAD_COUT;
      end
    end
  endtask

  integer ii;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      busy <= 1'b0;
      done_sticky <= 1'b0;
      weight_req <= 1'b0;
      err_code <= ERR_OK;
      cur_h <= '0; cur_w <= '0; cur_tile <= '0;
      wait_ctr <= '0; perf_ctr <= '0; write_idx <= '0;
      write_chan_idx <= '0; write_stream_idx <= '0; write_buf_idx_q <= '0;
      stream_words_q <= '0; input_dim_q <= '0;
      tile_count_expected_q <= '0; last_count_expected_q <= '0;
      fmap_words_in_q <= '0; fmap_words_out_q <= '0; validate_err <= ERR_OK;
      pixel_base_word_q <= '0; pixel_stride_words_q <= '0; write_addr_cursor_q <= '0;
      patch_ctx_valid <= 1'b0; flat_ctx_valid <= 1'b0;
      stage_start_pulse <= 1'b0; stage_clear_tile_buf <= 1'b0;
      fmap_wr_en <= 1'b0; fmap_wr_bank_sel <= 1'b0; fmap_wr_word_addr <= '0;
      fmap_wr_data <= '0; fmap_wr_strb <= 4'h0;
      for (ii = 0; ii < P_N_OUT*V2B_FMAP_WORDS_PER_STREAM_MAX; ii++) begin
        spike_word_buf[ii] <= 32'h0;
      end
    end else begin
      patch_ctx_valid <= 1'b0;
      flat_ctx_valid <= 1'b0;
      stage_start_pulse <= 1'b0;
      stage_clear_tile_buf <= 1'b0;
      fmap_wr_en <= 1'b0;
      fmap_wr_strb <= 4'h0;

      if (done_clear_pulse) done_sticky <= 1'b0;

      if (busy) perf_ctr <= perf_ctr + 32'd1;

      if (fmap_wr_commit_pulse && busy) begin
        err_code <= ERR_FMAP_WRITE_WHILE_BUSY;
        done_sticky <= 1'b1;
      end else if (fmap_wr_commit_pulse && fmap_wr_addr >= P_BANK_WORDS) begin
        err_code <= ERR_FMAP_WR_OOB;
        done_sticky <= 1'b1;
      end

      case (state)
        S_IDLE: begin
          weight_req <= 1'b0;
          if (start_pulse && cfg_conv_mode) begin
            busy <= 1'b1;
            done_sticky <= 1'b0;
            err_code <= ERR_OK;
            perf_ctr <= 32'd0;
            state <= S_VALIDATE;
          end
        end

        S_VALIDATE: begin
          compute_validate();
          state <= S_SPATIAL_INIT;
        end

        S_SPATIAL_INIT: begin
          if (validate_err != ERR_OK) begin
            err_code <= validate_err;
            state <= S_DONE;
          end else begin
            cur_h <= '0;
            cur_w <= '0;
            cur_tile <= '0;
            write_idx <= '0;
            write_chan_idx <= '0;
            write_stream_idx <= '0;
            write_buf_idx_q <= '0;
            pixel_base_word_q <= cfg_out_base_word;
            pixel_stride_words_q <= cfg_C_out * stream_words_q;
            write_addr_cursor_q <= cfg_out_base_word;
            stage_clear_tile_buf <= 1'b1;
            for (ii = 0; ii < P_N_OUT*V2B_FMAP_WORDS_PER_STREAM_MAX; ii++) begin
              spike_word_buf[ii] <= 32'h0;
            end
            state <= S_WAIT_WEIGHT;
          end
        end

        S_WAIT_WEIGHT: begin
          weight_req <= 1'b1;
          if (abort_pulse) begin
            err_code <= ERR_OK;
            state <= S_DONE;
          end else if (weight_ready_pulse) begin
            weight_req <= 1'b0;
            wait_ctr <= 32'd0;
            state <= S_CTX_ISSUE;
          end else begin
            wait_ctr <= wait_ctr + 32'd1;
            if (cfg_weight_timeout_en &&
                wait_ctr >= P_WEIGHT_TIMEOUT_CYCLES_EFF) begin
              err_code <= ERR_WEIGHT_TIMEOUT;
              state <= S_DONE;
            end
          end
        end

        S_CTX_ISSUE: begin
          if (cfg_flatten_mode) flat_ctx_valid <= 1'b1;
          else                  patch_ctx_valid <= 1'b1;
          state <= S_STAGE_START;
        end

        S_STAGE_START: begin
          stage_start_pulse <= 1'b1;
          state <= S_STAGE_WAIT;
        end

        S_STAGE_WAIT: begin
          if (spike_out_valid && !cfg_flatten_mode) begin
            for (ii = 0; ii < P_N_OUT; ii++) begin
              if (ii < cfg_C_out && spike_out_vec[ii]) begin
                spike_word_buf[(ii * V2B_FMAP_WORDS_PER_STREAM_MAX) +
                               spike_out_timestep[8:5]][spike_out_timestep[4:0]]
                  <= 1'b1;
              end
            end
          end
          if (stage_done_pulse) begin
            if (stage_err_code != V2B_STAGE_ERR_OK) err_code <= stage_err_code[3:0];
            state <= S_STAGE_DONE;
          end
        end

        S_STAGE_DONE: begin
          if (cur_tile + 16'd1 < cfg_tile_count) begin
            cur_tile <= cur_tile + 16'd1;
            state <= S_WAIT_WEIGHT;
        end else if (cfg_flatten_mode) begin
            state <= S_DONE;
          end else begin
            write_idx <= '0;
            write_chan_idx <= '0;
            write_stream_idx <= '0;
            write_buf_idx_q <= '0;
            write_addr_cursor_q <= pixel_base_word_q;
            state <= S_WRITEBACK;
          end
        end

        S_WRITEBACK: begin
          if (write_chan_idx < cfg_C_out) begin
            fmap_wr_en <= 1'b1;
            fmap_wr_bank_sel <= ~cfg_pp_sel;
            fmap_wr_word_addr <= write_addr_cursor_q;
            fmap_wr_data <= spike_word_buf[write_buf_idx_q];
            fmap_wr_strb <= 4'hF;
            write_idx <= write_idx + 16'd1;
            write_addr_cursor_q <= write_addr_cursor_q + 32'd1;
            if (write_stream_idx + 16'd1 < stream_words_q) begin
              write_stream_idx <= write_stream_idx + 16'd1;
              write_buf_idx_q <= write_buf_idx_q + 16'd1;
            end else begin
              write_stream_idx <= 16'd0;
              write_chan_idx <= write_chan_idx + 16'd1;
              write_buf_idx_q <= (write_chan_idx + 16'd1) * V2B_FMAP_WORDS_PER_STREAM_MAX;
            end
          end else begin
            state <= S_SPATIAL_NEXT;
          end
        end

        S_SPATIAL_NEXT: begin
          if (cur_w + 16'd1 < cfg_out_W) begin
            cur_w <= cur_w + 16'd1;
            cur_tile <= '0;
            pixel_base_word_q <= pixel_base_word_q + pixel_stride_words_q;
            stage_clear_tile_buf <= 1'b1;
            for (ii = 0; ii < P_N_OUT*V2B_FMAP_WORDS_PER_STREAM_MAX; ii++) begin
              spike_word_buf[ii] <= 32'h0;
            end
            state <= S_WAIT_WEIGHT;
          end else if (cur_h + 16'd1 < cfg_out_H) begin
            cur_h <= cur_h + 16'd1;
            cur_w <= '0;
            cur_tile <= '0;
            pixel_base_word_q <= pixel_base_word_q + pixel_stride_words_q;
            stage_clear_tile_buf <= 1'b1;
            for (ii = 0; ii < P_N_OUT*V2B_FMAP_WORDS_PER_STREAM_MAX; ii++) begin
              spike_word_buf[ii] <= 32'h0;
            end
            state <= S_WAIT_WEIGHT;
          end else begin
            state <= S_DONE;
          end
        end

        S_DONE: begin
          busy <= 1'b0;
          weight_req <= 1'b0;
          done_sticky <= 1'b1;
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
`ifdef VCS
  property SVA_CONV_CFG_VALIDATE_BEFORE_WEIGHT_REQ;
    @(posedge clk) disable iff (!rst_n)
      weight_req |-> (state != S_VALIDATE);
  endproperty
  assert property (SVA_CONV_CFG_VALIDATE_BEFORE_WEIGHT_REQ);

  property SVA_WEIGHT_REQ_BLOCKS_STAGE_START;
    @(posedge clk) disable iff (!rst_n)
      (weight_req && !weight_ready_pulse) |-> !stage_start_pulse;
  endproperty
  assert property (SVA_WEIGHT_REQ_BLOCKS_STAGE_START);

  property SVA_WEIGHT_READY_CLEARS_WEIGHT_REQ;
    @(posedge clk) disable iff (!rst_n)
      (state == S_WAIT_WEIGHT && weight_ready_pulse) |=> !weight_req;
  endproperty
  assert property (SVA_WEIGHT_READY_CLEARS_WEIGHT_REQ);
`endif
`endif

endmodule
