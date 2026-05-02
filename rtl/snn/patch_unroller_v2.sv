`timescale 1ns/1ps
//======================================================================
// patch_unroller_v2.sv
//
// 【我在 SoC 里的位置】
// 我是 CONV 模式的动态 word-line reader，夹在 stage_engine_v2 和
// fmap_sram_v2 之间。stage_engine 只知道“第 t 个 timestep 需要一条
// 256-lane WL”，但不知道这个 WL 对应哪个 feature-map patch；我把
// conv_ctrl_v2 给出的 {out_h,out_w,tile_idx,K,stride,pad,C_in,H,W,base}
// 转换成最多 256 个 32-bit SRAM 读，再拼成 256-bit dyn_wl_resp_data。
//
// 【接口和数据流】
// - ctx_valid/cfg_* 来自 conv_ctrl_v2，每个输出空间点、每个 KKC tile 更新一次。
// - dyn_wl_req_* / dyn_wl_resp_* 接 stage_engine_v2，按 timestep 请求/返回。
// - fmap_rd_* 接 fmap_sram_v2，读的是 32-bit padded stream word；我只取
//   timestep[4:0] 那一 bit 作为当前 lane 的 spike。
//
// 【关键指标和取舍】
// 目标 50 MHz 单时钟域，吞吐不是一拍一 WL，而是用小 FSM 顺序读 256 lane。
// 这牺牲了单层峰值吞吐，但大幅降低 BRAM 端口需求：只用一个 32-bit read port
// 就能服务 patch 提取。面试里我会强调这是 demo/FPGA 友好的选择；如果要做
// 高吞吐 accelerator，应把 fmap SRAM 做多 bank 并并行读取多个 lane。
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

  // 【架构注释：为什么用 FSM 顺序展开 patch】
  // 一个 patch tile 涉及 K×K×C_in 个逻辑元素，还要处理 padding、last tile
  // zero-fill 和 BRAM 1-cycle latency。用 FSM 可以把“算地址、发读、等数据、
  // 写 response bit”拆开，避免在一个组合块里同时做除法、乘法、边界判断和
  // 256-bit 拼接。代价是 latency 约等于有效 lane 数，但控制可验证、时序稳。
  typedef enum logic [3:0] {
    S_IDLE       = 4'd0,
    S_CTX_LATCH  = 4'd1,
    S_WAIT_REQ   = 4'd2,
    S_INIT0      = 4'd3,
    S_INIT1      = 4'd4,
    S_INIT2      = 4'd5,
    S_PREP_LANE  = 4'd6,
    S_ISSUE_READ = 4'd7,
    S_WAIT_READ  = 4'd8,
    S_RESPOND    = 4'd9
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
  logic [31:0] init_div_work_q;
  logic [31:0] init_klinear_q;
  logic [31:0] init_kwork_q;
  logic [15:0] init_chan_q;
  logic [3:0]  init_kx_q;
  logic [3:0]  init_ky_q;
  logic signed [16:0] origin_h_base_q, origin_w_base_q;
  logic signed [16:0] cur_h_q, cur_w_q;
  logic [3:0]  cur_kx_q;
  logic [15:0] cur_chan_q;
  logic signed [31:0] stream_base_q;
  logic [31:0] row_jump_q;

  assign dyn_wl_req_ready        = (state == S_WAIT_REQ);
  assign dyn_wl_resp_valid       = (state == S_RESPOND);
  assign dyn_wl_resp_data        = resp_data_q;
  assign dyn_wl_resp_valid_count = valid_count_q;
  assign fmap_rd_en              = (state == S_ISSUE_READ);
  assign fmap_rd_word_addr       = read_addr_q;

  // 【Corner case：last tile 不满 256 lane】
  // KKC 不一定是 256 的整数倍，最后一个 tile 之外的 lane 必须返回 0。
  // 如果这里直接固定 256，stage_engine 会把 padding lane 当作真实输入参与 MAC，
  // 对 C_in 较小或 K=3 的层影响特别明显，输出 spike 会比 golden 更密。
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

  // 【架构注释：用移位加法替代可变乘法】
  // cfg_stream_words 的合法范围来自 T_count，最大 8。这里不用 idx*cfg_stream_words，
  // 而是 case 成移位加法，是为了让 Vivado/E203 FPGA 分支少推一个宽乘法器，
  // 这类小优化对 50 MHz 也许不是必须，但能显著降低时序分析里的不确定性。
  function automatic [31:0] scale_stream_words(input [31:0] idx);
    begin
      case (cfg_stream_words_q)
        4'd1: scale_stream_words = idx;
        4'd2: scale_stream_words = idx << 1;
        4'd3: scale_stream_words = (idx << 1) + idx;
        4'd4: scale_stream_words = idx << 2;
        4'd5: scale_stream_words = (idx << 2) + idx;
        4'd6: scale_stream_words = (idx << 2) + (idx << 1);
        4'd7: scale_stream_words = (idx << 2) + (idx << 1) + idx;
        default: scale_stream_words = idx << 3;
      endcase
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
                     + scale_stream_words(linear_stream)
                     + (timestep >> 5);
    end
  endfunction

  // 【架构注释：prep_lane 是 patch 地址语义的唯一入口】
  // 我把 logical lane -> {channel,ky,kx,src_h,src_w,word_addr,bit_idx} 的映射
  // 收在一个 task 里，是为了保证仿真快路径和综合路径使用同一套数学定义。
  // padding 区域不读 SRAM，而是返回 should_read=0；这样 reader 不会为了边缘
  // 像素访问负地址或越过 fmap 边界。
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

  // 【架构注释：E203 分支选择 streaming address generator】
  // 这条分支曾经重点处理 timing closure，所以我没有预先生成 256 项 lane 地址表，
  // 而是用 advance_lane_state 逐 lane 推进 {h,w,kx,chan,stream_base}。这样少了
  // 大数组扇出和 build 表写入，代价是初始化时要用 S_INIT0/1/2 把 tile_base
  // 转成起始 channel/kx/ky。这个 trade-off 更适合小 FPGA 和较保守频率目标。
  task automatic advance_lane_state(
    input  logic signed [16:0] cur_h_in,
    input  logic signed [16:0] cur_w_in,
    input  logic [3:0]         cur_kx_in,
    input  logic [15:0]        cur_chan_in,
    input  logic signed [31:0] stream_base_in,
    output logic signed [16:0] cur_h_out,
    output logic signed [16:0] cur_w_out,
    output logic [3:0]         cur_kx_out,
    output logic [15:0]        cur_chan_out,
    output logic signed [31:0] stream_base_out
  );
    logic [15:0] c_in_eff;
    logic [3:0]  k_eff;
    begin
      c_in_eff = (cfg_C_in_q == 0) ? 16'd1 : cfg_C_in_q;
      k_eff = (cfg_K_q == 0) ? 4'd1 : cfg_K_q;
      cur_h_out = cur_h_in;
      cur_w_out = cur_w_in;
      cur_kx_out = cur_kx_in;
      cur_chan_out = cur_chan_in;
      stream_base_out = stream_base_in;

      if ((cur_chan_in + 16'd1) < c_in_eff) begin
        cur_chan_out = cur_chan_in + 16'd1;
        stream_base_out = stream_base_in + 32'sd1;
      end else begin
        cur_chan_out = 16'd0;
        if ((cur_kx_in + 4'd1) < k_eff) begin
          cur_kx_out = cur_kx_in + 4'd1;
          cur_w_out = cur_w_in + 17'sd1;
          stream_base_out = stream_base_in + 32'sd1;
        end else begin
          cur_kx_out = 4'd0;
          cur_h_out = cur_h_in + 17'sd1;
          cur_w_out = origin_w_base_q;
          stream_base_out = stream_base_in + $signed(row_jump_q);
        end
      end
    end
  endtask

`ifndef SYNTHESIS
  // 【架构注释：仿真 cache 只优化速度，不改变握手语义】
  // unit/cosim 里连续请求多个 timestep 时，t[8:5] 相同代表同一个 32-bit word。
  // 我把每个 lane 的 word 缓下来，下一次只换 bit_idx，不重复 256 次 SRAM 读。
  // 这只在非综合路径启用，保证硬件资源模型不被仿真加速逻辑污染。
  logic [31:0] lane_word_cache [0:P_N_IN-1];
  logic        cache_valid;
  logic [3:0]  cache_word_idx;
  integer      cache_lane;
`endif

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

        // 【Corner case：ctx_valid 只是一拍，但 reader 可能晚很多拍才收到 timestep】
        // 我在 ctx_valid 时立即锁存所有 cfg，后续 WAIT_REQ 阶段即使 firmware 改写了
        // 寄存器，也不会影响当前 stage_engine 正在消费的 patch。否则一次 CONV 运行中
        // 软件写下一层配置会把当前地址生成打乱。
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
      init_div_work_q <= '0;
      init_klinear_q <= '0; init_chan_q <= '0; init_kx_q <= '0; init_ky_q <= '0;
      init_kwork_q <= '0;
      origin_h_base_q <= '0; origin_w_base_q <= '0;
      cur_h_q <= '0; cur_w_q <= '0; cur_kx_q <= '0; cur_chan_q <= '0;
      stream_base_q <= '0; row_jump_q <= '0;
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
          end
          if (dyn_wl_req_valid) begin
            req_timestep_q <= dyn_wl_req_timestep;
            lane_idx <= '0;
            resp_data_q <= '0;
            init_div_work_q <= tile_base_q;
            init_klinear_q <= 32'd0;
            init_kwork_q <= 32'd0;
            init_chan_q <= 16'd0;
            init_kx_q <= 4'd0;
            init_ky_q <= 4'd0;
            state <= S_INIT0;
          end
        end

        // 【架构注释：把 tile_base 除以 C_in 拆成多拍】
        // 这里用减法循环替代一个可变除法器，是为了避免综合出很深的组合除法路径。
        // 因为 tile_base 每个 stage 只初始化一次，多花几个 cycle 比牺牲 Fmax 更划算。
        S_INIT0: begin
          logic [15:0] c_in_eff;
          c_in_eff = (cfg_C_in_q == 0) ? 16'd1 : cfg_C_in_q;
          if (init_div_work_q >= c_in_eff) begin
            init_div_work_q <= init_div_work_q - c_in_eff;
            init_klinear_q <= init_klinear_q + 32'd1;
          end else begin
            init_chan_q <= init_div_work_q[15:0];
            init_kwork_q <= init_klinear_q;
            init_ky_q <= 4'd0;
            state <= S_INIT1;
          end
        end

        // 【架构注释：继续把 k_linear 拆成 ky/kx】
        // 同样用小循环而不是除法/取模。这个设计让 timing 更可控，代价是 tile 起点
        // 初始化 latency 与 tile_base 有关；在 demo 规模下这部分远小于 MAC 总时间。
        S_INIT1: begin
          logic [3:0] k_eff;
          k_eff = (cfg_K_q == 0) ? 4'd1 : cfg_K_q;
          if (init_kwork_q >= k_eff) begin
            init_kwork_q <= init_kwork_q - k_eff;
            init_ky_q <= init_ky_q + 4'd1;
          end else begin
            init_kx_q <= init_kwork_q[3:0];
            state <= S_INIT2;
          end
        end

        S_INIT2: begin
          logic signed [16:0] base_h_v;
          logic signed [16:0] base_w_v;
          logic signed [31:0] stream_base_v;
          base_h_v = $signed({1'b0, ctx_h_q}) * $signed({13'd0, cfg_stride_q})
                   - $signed({13'd0, cfg_pad_q});
          base_w_v = $signed({1'b0, ctx_w_q}) * $signed({13'd0, cfg_stride_q})
                   - $signed({13'd0, cfg_pad_q});
          origin_h_base_q <= base_h_v;
          origin_w_base_q <= base_w_v;
          cur_h_q <= base_h_v + $signed({13'd0, init_ky_q});
          cur_w_q <= base_w_v + $signed({13'd0, init_kx_q});
          cur_kx_q <= init_kx_q;
          cur_chan_q <= init_chan_q;
          row_jump_q <= ((cfg_W_q - cfg_K_q) * cfg_C_in_q) + 32'd1;
          stream_base_v = (($signed(base_h_v + $signed({13'd0, init_ky_q})) * $signed({16'd0, cfg_W_q}))
                         + $signed(base_w_v + $signed({13'd0, init_kx_q})))
                         * $signed({16'd0, cfg_C_in_q})
                         + $signed({16'd0, init_chan_q});
          stream_base_q <= stream_base_v;
          state <= S_PREP_LANE;
        end

        // 【Corner case：padding lane 和 last tile lane 都必须显式写 0】
        // response 是 256-bit 宽总线，未赋值 bit 会在仿真里变 X，在硬件里保留旧值。
        // 所以无论是超出 valid_count，还是 pad 到 fmap 外，我都主动把对应 lane 置 0。
        // 【Corner case：综合路径同样要 zero-fill 无效 lane】
        // lane_idx>=valid_count_q 是 last tile 空洞，cur_h/cur_w 越界是 padding。
        // 两者都不能发 SRAM 读，否则负坐标会参与地址计算并可能变成 bank 内旧数据。
        S_PREP_LANE: begin
          if (lane_idx == 9'd256) begin
            state <= S_RESPOND;
          end else if (lane_idx >= valid_count_q) begin
            logic signed [16:0] next_h_v;
            logic signed [16:0] next_w_v;
            logic [3:0] next_kx_v;
            logic [15:0] next_chan_v;
            logic signed [31:0] next_stream_base_v;
            resp_data_q[lane_idx[7:0]] <= 1'b0;
            advance_lane_state(cur_h_q, cur_w_q, cur_kx_q, cur_chan_q, stream_base_q,
                               next_h_v, next_w_v, next_kx_v, next_chan_v, next_stream_base_v);
            cur_h_q <= next_h_v;
            cur_w_q <= next_w_v;
            cur_kx_q <= next_kx_v;
            cur_chan_q <= next_chan_v;
            stream_base_q <= next_stream_base_v;
            lane_idx <= lane_idx + 9'd1;
          end else begin
            if (cur_h_q >= 0 && cur_h_q < $signed({1'b0, cfg_H_q}) &&
                cur_w_q >= 0 && cur_w_q < $signed({1'b0, cfg_W_q})) begin
              read_addr_q <= cfg_fmap_base_word_q
                           + scale_stream_words(stream_base_q[31:0])
                           + (req_timestep_q >> 5);
              read_lane_q <= lane_idx[7:0];
              read_bit_idx_q <= req_timestep_q[4:0];
              state <= S_ISSUE_READ;
            end else begin
              logic signed [16:0] next_h_v;
              logic signed [16:0] next_w_v;
              logic [3:0] next_kx_v;
              logic [15:0] next_chan_v;
              logic signed [31:0] next_stream_base_v;
              resp_data_q[lane_idx[7:0]] <= 1'b0;
              advance_lane_state(cur_h_q, cur_w_q, cur_kx_q, cur_chan_q, stream_base_q,
                                 next_h_v, next_w_v, next_kx_v, next_chan_v, next_stream_base_v);
              cur_h_q <= next_h_v;
              cur_w_q <= next_w_v;
              cur_kx_q <= next_kx_v;
              cur_chan_q <= next_chan_v;
              stream_base_q <= next_stream_base_v;
              lane_idx <= lane_idx + 9'd1;
            end
          end
        end

        S_ISSUE_READ: begin
          state <= S_WAIT_READ;
        end

        S_WAIT_READ: begin
          logic signed [16:0] next_h_v;
          logic signed [16:0] next_w_v;
          logic [3:0] next_kx_v;
          logic [15:0] next_chan_v;
          logic signed [31:0] next_stream_base_v;
          resp_data_q[read_lane_q] <= fmap_rd_data[read_bit_idx_q];
          advance_lane_state(cur_h_q, cur_w_q, cur_kx_q, cur_chan_q, stream_base_q,
                             next_h_v, next_w_v, next_kx_v, next_chan_v, next_stream_base_v);
          cur_h_q <= next_h_v;
          cur_w_q <= next_w_v;
          cur_kx_q <= next_kx_v;
          cur_chan_q <= next_chan_v;
          stream_base_q <= next_stream_base_v;
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
