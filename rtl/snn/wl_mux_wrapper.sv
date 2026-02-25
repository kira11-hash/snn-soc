`timescale 1ns/1ps
//======================================================================
// 文件名: wl_mux_wrapper.sv
// 描述: WL 复用包装器（V1 协议原型）。
//       - 输入：cim_array_ctrl 给出的 64-bit 并行 wl_bitmap + 单拍有效
//       - 输出：8bit 分组时分信号（wl_data/wl_group_sel/wl_latch）
//       - 内部：完成 8 组发送后再向内部链路发出 wl_valid_pulse_out
//
// 说明:
//   1) 本模块用于冻结"外部引脚复用协议"的字段与时序，避免接口漂移。
//   2) 当前仍在 snn_soc_top 内部使用，后续可平移到 chip_top/pad wrapper。
//   3) 总延迟：1(IDLE→SEND 锁存) + 8(ST_SEND 发送 group 0~7) + 1(ST_DONE) = 10 cycles。
//      文档中"8 cycles"仅指 ST_SEND 阶段，实际含首尾过渡共 10 cycles。
//======================================================================
module wl_mux_wrapper #(
  parameter int P_NUM_INPUTS = snn_soc_pkg::NUM_INPUTS,
  parameter int P_GROUP_W    = snn_soc_pkg::WL_GROUP_WIDTH
) (
  input  logic clk,
  input  logic rst_n,

  // 来自 CIM 控制器（并行协议）
  input  logic [P_NUM_INPUTS-1:0] wl_bitmap_in,
  input  logic                    wl_valid_pulse_in,

  // 给内部链路（并行协议，供 dac_ctrl/cim_macro 使用）
  output logic [P_NUM_INPUTS-1:0] wl_bitmap_out,
  output logic                    wl_valid_pulse_out,

  // 冻结后的外部复用协议（后续 chip_top 可直接复用）
  output logic [P_GROUP_W-1:0] wl_data,
  output logic [$clog2(P_NUM_INPUTS / P_GROUP_W)-1:0] wl_group_sel,
  output logic                 wl_latch,
  output logic                 wl_busy
);
  localparam int GROUPS = (P_NUM_INPUTS / P_GROUP_W);
  localparam int GROUP_W_SEL = $clog2(GROUPS);

  typedef enum logic [1:0] {
    ST_IDLE = 2'b00,
    ST_SEND = 2'b01,
    ST_DONE = 2'b10
  } state_t;

  state_t state;
  logic [P_NUM_INPUTS-1:0] wl_buf;
  logic [GROUP_W_SEL-1:0] grp_idx;

  // 并行数据直接从内部缓冲导出，确保与发送序列一致
  assign wl_bitmap_out = wl_buf;
  assign wl_group_sel = grp_idx;

  // 分组数据：当前组的 8bit
  always_comb begin
    wl_data = '0;
    wl_data = wl_buf[grp_idx*P_GROUP_W +: P_GROUP_W];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state               <= ST_IDLE;
      wl_buf              <= '0;
      grp_idx             <= '0;
      wl_valid_pulse_out  <= 1'b0;
      wl_latch            <= 1'b0;
      wl_busy             <= 1'b0;
    end else begin
      wl_valid_pulse_out <= 1'b0;
      wl_latch           <= 1'b0;

      case (state)
        ST_IDLE: begin
          wl_busy <= 1'b0;
          if (wl_valid_pulse_in) begin
            wl_buf  <= wl_bitmap_in;
            grp_idx <= '0;
            wl_busy <= 1'b1;
            state   <= ST_SEND;
          end
        end

        ST_SEND: begin
          wl_busy  <= 1'b1;
          wl_latch <= 1'b1;  // 当前组在本拍锁存
          if (grp_idx == GROUP_W_SEL'(GROUPS - 1)) begin
            state <= ST_DONE;
          end else begin
            grp_idx <= grp_idx + GROUP_W_SEL'(1);
          end
        end

        ST_DONE: begin
          wl_busy            <= 1'b0;
          wl_valid_pulse_out <= 1'b1; // 所有组发送完成后，触发内部链路
          state              <= ST_IDLE;
        end

        default: begin
          state <= ST_IDLE;
        end
      endcase

      // 异常保护：忙期间若再次收到新帧，提示协议使用错误
      if (wl_valid_pulse_in && (state != ST_IDLE)) begin
        $warning("[wl_mux_wrapper] 收到重入 wl_valid_pulse_in，当前帧尚未完成发送");
      end
    end
  end

  // 参数合法性检查
  initial begin
    if (P_GROUP_W <= 0) begin
      $fatal(1, "[wl_mux_wrapper] P_GROUP_W 必须 > 0");
    end
    if ((P_NUM_INPUTS % P_GROUP_W) != 0) begin
      $fatal(1, "[wl_mux_wrapper] P_NUM_INPUTS(%0d) 必须能被 P_GROUP_W(%0d) 整除",
             P_NUM_INPUTS, P_GROUP_W);
    end
  end
endmodule

