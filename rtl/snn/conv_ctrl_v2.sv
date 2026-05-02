`timescale 1ns/1ps
//======================================================================
// conv_ctrl_v2.sv
//
// 【我在 SoC 里的位置】
// 我是 V2.B CONV/Flatten 扩展的外层调度器，位于 CPU-facing 寄存器组
// 和 stage_engine_v2 之间。CPU 只负责写配置、预装 fmap/weight，并通过
// start/weight_ready 脉冲推进任务；我负责把一个高层卷积层拆成
// out_h/out_w 空间点、KKC/Flatten tile、每个 tile 的 stage_engine 调用，
// 最后再把 final tile 产生的 spike 打包写回 fmap_sram_v2 的另一侧 bank。
//
// 【接口怎么接】
// - cfg_* / start_pulse / abort_pulse / done_clear_pulse 来自 snn_soc_v2b_top
//   内联寄存器组，承载 firmware 对 CONV 层的描述。
// - weight_req / weight_ready_pulse 是我和 firmware 的权重预装握手：我请求
//   “当前空间点+tile 的 256×C_out 权重已经该装了”，firmware 完成 preload
//   后回一个 pulse；如果 firmware 忘了这一步，功能会长时间卡在 WAIT_WEIGHT，
//   这也是之前 ARM bring-up 看起来“算不对”的根因之一。
// - patch_ctx_* / flat_ctx_* 发给动态 word-line reader，告诉它当前读哪个
//   patch 或 flatten tile。
// - stage_cfg_* / stage_start_pulse 发给 stage_engine_v2，真正执行 T 个
//   timestep 的 CIM MAC、tile partial sum 和最终 LIF。
// - spike_out_* 从 stage_engine_v2 回来，我把 final tile 的 spike 按
//   32-bit timestep-packed fmap layout 写回 fmap_sram_v2。
//
// 【关键指标和取舍】
// 目标是 ZCU102/ARM demo 上 50 MHz 单时钟域稳定跑通，吞吐以“每个空间点
// 每个 tile 启动一次 stage_engine”为基本粒度；控制路径不追求一拍发射，而
// 是优先保证权重 preload、动态 WL 读取、BRAM 1-cycle latency 和写回顺序
// 都可解释、可调试。后续如果要冲更高频率，应优先把大乘法/除法从校验或
// 地址计算路径继续切 pipeline，而不是改动握手机制。
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

  // 【架构注释：为什么这里先缓存 spike 再写 fmap】
  // 我没有让 stage_engine_v2 直接写 fmap_sram_v2，因为 stage_engine 的输出是
  // “某个 timestep 的 C_out-bit spike 向量”，而 fmap_sram_v2 的物理布局是
  // “每个 channel 连续 stream_words 个 32-bit word”。两者维度相反，直接写会
  // 形成跨 timestep/channel 的随机写和复杂 byte/bit mask。这里先用寄存器数组
  // 做一次转置：stage 运行时按 timestep 收集，stage done 后按 fmap layout 顺序
  // 顺写 SRAM。这样控制简单，也避免 CONV 写回和动态 reader 在同一拍抢读写端口。
  // TODO优化方向：如果后续 C_out 或 T_count 扩大，spike_word_buf 应替换为小型
  // dual-port SRAM 或分块 writeback FIFO，避免寄存器面积随 P_N_OUT*T_count 线性放大。
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

  // 【架构注释：为什么启动前集中做 validate】
  // 我把几何、tile、T_count、C_out、fmap 边界都集中在 S_VALIDATE 检查，而不是
  // 在每个状态里边跑边报错。原因是 CONV 一旦发出 weight_req，firmware 就会开始
  // preload 权重；如果配置已经非法却晚到中途才发现，软件侧可能已经覆盖了 MAC
  // 权重 RAM，调试时会误以为是计算错。集中校验的代价是 start 后多 1 个控制状态，
  // 但换来的是错误码稳定、不会产生半启动事务，也不会把错误传播到 fmap_sram。
  //
  // 【Corner case】
  // cfg_stride=0、pad 后尺寸小于 K、tile_count/last_tile_valid_count 与 KKC 不匹配、
  // fmap base+words 越过 bank，这些都必须在 weight_req 前挡住。去掉这些保护后，
  // 典型症状不是立即崩溃，而是 reader 读到 bank 外零值或旧值，最后表现成
  // LeNet-5 层间 spike 稀疏度异常，很难从输出反推真正原因。
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

  // 【架构注释：为什么用显式 FSM 而不是几个嵌套计数器硬连】
  // 我这里要同时协调四类时序：firmware 权重 preload、动态 WL reader 上下文、
  // stage_engine 子任务、fmap 写回。它们的 ready/done 都不是纯固定周期，如果只用
  // 多层计数器，遇到 weight_ready 延迟、abort、stage error 或 timeout 时很容易
  // 出现计数器继续跑但外设还没准备好的“半事务”。显式 FSM 的代价是状态数多，
  // 但每个状态都有唯一职责，面试时也能清楚说明系统为什么不会乱序写 bank。
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

      // 【Corner case：firmware preload 写口必须避开 CONV 正在运行】
      // fmap_wr_commit_pulse 是 CPU/firmware 用来预装输入 fmap 的通道，而运行中的
      // CONV 会把输出写到另一侧 bank。即使理论上 bank 不同，我也禁止 busy 时
      // firmware 写入，因为 bring-up 期间最容易把 pp_sel、target_bank 或 auto-inc
      // 搞错；如果不挡，动态 reader 可能读到半更新数据，最后表现为功能偶发不对。
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

        // 【架构注释：weight_req/weight_ready 是软件参与的 preload 边界】
        // 我没有在 RTL 内部做 weight DMA，是因为当前 demo 的权重来源既可能来自
        // ARM PS/E203 firmware，也可能来自测试平台直接写 MAC weight RAM。把 preload
        // 显式暴露成握手后，硬件只保证“weight_ready 之后才启动 stage_engine”，软件
        // 可以选择任何装载策略。代价是 firmware 必须严格按协议回应；如果忘记回应，
        // 我会一直停在这里，直到 timeout 或 abort，而不是带着旧权重继续算。
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

        // 【架构注释：先发 reader context，再启动 stage_engine】
        // patch_unroller/flatten_reader 都会锁存当前空间点和 tile 信息。这里我专门
        // 给它们一个 ctx_valid 状态，再下一拍才 start stage_engine，避免 stage 在
        // 第一个 timestep 就发 dyn_wl_req_valid 时 reader 还没更新上下文。
        S_CTX_ISSUE: begin
          if (cfg_flatten_mode) flat_ctx_valid <= 1'b1;
          else                  patch_ctx_valid <= 1'b1;
          state <= S_STAGE_START;
        end

        S_STAGE_START: begin
          stage_start_pulse <= 1'b1;
          state <= S_STAGE_WAIT;
        end

        // 【架构注释：只捕获 final tile 的 spike】
        // stage_engine 在 tile_mode 下会把非 final tile 累加到 tile_partial_buf，只有
        // final tile 才做 LIF 并吐 spike_out_*。我在这里仍然用 !flatten_mode 再过滤，
        // 是为了让 Flatten->FC 的“只读 fmap、不回写 fmap”路径保持安静，避免把 FC
        // 输出误写成下一层 feature map。
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

        // 【架构注释：tile 先内循环，空间点后外循环】
        // 对同一个输出像素，我先跑完所有 KKC tile，让 partial sum 在 tile_partial_buf
        // 里闭合，再进入 writeback。这样 membrane/LIF 的语义等同于完整 KKC 一次性
        // MAC；如果空间点先递增，partial buffer 会混入不同像素，错误会非常隐蔽。
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

        // 【架构注释：ARM 分支使用递增 cursor，少放组合乘除在写回热路径】
        // 每个输出像素的 fmap 地址是 (((h*out_W+w)*C_out+c)*stream_words+s)。
        // 在 ARM FPGA demo 这条分支里，我把 pixel_base_word_q 和 write_addr_cursor_q
        // 提前寄存，让 S_WRITEBACK 每拍基本只做 +1 和小计数器更新，降低时序压力。
        // trade-off 是控制寄存器多一点，必须在空间点切换时维护 cursor；如果漏掉
        // pixel_base_word_q 更新，会出现所有像素写到同一块地址的灾难性覆盖。
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

        // 【Corner case：切换空间点时必须清空 spike_word_buf 和 tile partial】
        // 上一个像素的 spike 转置缓存不能泄漏到下一个像素；同时 tile_partial_buf
        // 也要重新开始累加。这里每次移动 w/h 都拉 stage_clear_tile_buf 并清空本地
        // spike_word_buf。去掉这段后，输入全零或边缘 padding 区域最容易暴露问题：
        // 它们本应没有 spike，却会继承前一个像素的残留 bit。
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
