`timescale 1ns/1ps
//======================================================================
// 文件名: cim_macro_arbiter.sv
// 模块名: cim_macro_arbiter
//
// 【功能概述】
// CIM 宏访问仲裁器，在"推理路径"和"编程路径"之间二选一。
// 任意时刻只有一方能操作 CIM 宏（字线驱动、DAC 有效、CIM/ADC 启停、
// BL 选择），另一方的 done/data 信号被屏蔽为 0。
//
// 【仲裁策略】
// - prog_busy=1 → 编程路径独占 CIM 宏（SET/RESET/Verify 期间）
// - prog_busy=0 → 推理路径独占（正常 SNN 前向推理）
// - 寄存器化输出（always_ff），消除 prog_busy 切换瞬间的组合逻辑毛刺，
//   引入 1 拍延迟（下游 FSM 通过轮询 done 工作，1 拍延迟不影响功能）
//
// 【设计要点】
// - 不存在同时授权的情况：cim_program_ctrl 在 ST_IDLE 时 prog_busy=0，
//   此时推理侧可自由使用 CIM 宏
// - 输出寄存器在复位时全部清零（安全默认：无 WL 驱动、无启动脉冲）
//======================================================================
module cim_macro_arbiter (
  input  logic clk,                                                      // 系统时钟（输出寄存器打拍）
  input  logic rst_n,                                                    // 异步低有效复位

  input  logic prog_busy,                                                // 编程控制器忙标志（1=编程独占）

  // ── 推理侧信号（来自 cim_array_ctrl / adc_ctrl）────────────────────
  input  logic [snn_soc_pkg::NUM_INPUTS-1:0] infer_wl_spike,            // 推理字线向量
  input  logic        infer_dac_valid,                                   // 推理 DAC 有效
  input  logic        infer_cim_start,                                   // 推理 CIM 启动
  input  logic        infer_adc_start,                                   // 推理 ADC 启动
  input  logic [$clog2(snn_soc_pkg::MAX_BL_SCAN)-1:0] infer_bl_sel,    // 推理 BL 通道选择（V2 扩宽）
  output logic        infer_cim_done,                                    // 推理 CIM 完成反馈
  output logic        infer_adc_done,                                    // 推理 ADC 完成反馈
  output logic [snn_soc_pkg::ADC_BITS-1:0] infer_bl_data,               // 推理 ADC 数据反馈

  // ── 编程侧信号（来自 cim_program_ctrl）─────────────────────────────
  input  logic [snn_soc_pkg::NUM_INPUTS-1:0] prog_wl_spike,             // 编程字线向量
  input  logic        prog_dac_valid,                                    // 编程 DAC 有效
  input  logic        prog_cim_start,                                    // 编程 CIM 启动
  input  logic        prog_adc_start,                                    // 编程 ADC 启动
  input  logic [$clog2(snn_soc_pkg::MAX_BL_SCAN)-1:0] prog_bl_sel,     // 编程 BL 通道选择（V2 扩宽）
  output logic        prog_cim_done,                                     // 编程 CIM 完成反馈
  output logic        prog_adc_done,                                     // 编程 ADC 完成反馈
  output logic [snn_soc_pkg::ADC_BITS-1:0] prog_bl_data,                // 编程 ADC 数据反馈

  // ── CIM 宏侧信号（连接到 cim_macro_blackbox）──────────────────────
  output logic [snn_soc_pkg::NUM_INPUTS-1:0] macro_wl_spike,            // 宏字线输入
  output logic        macro_dac_valid,                                   // 宏 DAC 有效
  output logic        macro_cim_start,                                   // 宏 CIM 启动
  output logic        macro_adc_start,                                   // 宏 ADC 启动
  output logic [$clog2(snn_soc_pkg::MAX_BL_SCAN)-1:0] macro_bl_sel,    // 宏 BL 通道选择（V2 扩宽）
  input  logic        macro_cim_done,                                    // 宏 CIM 完成
  input  logic        macro_adc_done,                                    // 宏 ADC 完成
  input  logic [snn_soc_pkg::ADC_BITS-1:0] macro_bl_data                // 宏 ADC 数据
);

  // ── 寄存器化二选一 MUX：prog_busy 决定谁获得 CIM 宏访问权 ────────
  // 所有输出经 1 级寄存器打拍，消除 prog_busy 切换瞬间的组合毛刺。
  // 代价：增加 1 拍延迟（下游 FSM 轮询 done 信号，不影响功能正确性）。
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // 复位安全默认值：无 WL 驱动、无启动脉冲、done/data 全零
      macro_wl_spike  <= '0;
      macro_dac_valid <= 1'b0;
      macro_cim_start <= 1'b0;
      macro_adc_start <= 1'b0;
      macro_bl_sel    <= '0;
      infer_cim_done  <= 1'b0;
      infer_adc_done  <= 1'b0;
      infer_bl_data   <= '0;
      prog_cim_done   <= 1'b0;
      prog_adc_done   <= 1'b0;
      prog_bl_data    <= '0;
    end else begin
      if (prog_busy) begin
        // 编程路径独占：编程信号透传到宏，推理侧被屏蔽
        macro_wl_spike  <= prog_wl_spike;
        macro_dac_valid <= prog_dac_valid;
        macro_cim_start <= prog_cim_start;
        macro_adc_start <= prog_adc_start;
        macro_bl_sel    <= prog_bl_sel;

        prog_cim_done   <= macro_cim_done;
        prog_adc_done   <= macro_adc_done;
        prog_bl_data    <= macro_bl_data;

        infer_cim_done  <= 1'b0;      // 推理侧 done 屏蔽
        infer_adc_done  <= 1'b0;
        infer_bl_data   <= '0;
      end else begin
        // 推理路径独占：推理信号透传到宏，编程侧被屏蔽
        macro_wl_spike  <= infer_wl_spike;
        macro_dac_valid <= infer_dac_valid;
        macro_cim_start <= infer_cim_start;
        macro_adc_start <= infer_adc_start;
        macro_bl_sel    <= infer_bl_sel;

        infer_cim_done  <= macro_cim_done;
        infer_adc_done  <= macro_adc_done;
        infer_bl_data   <= macro_bl_data;

        prog_cim_done   <= 1'b0;      // 编程侧 done 屏蔽
        prog_adc_done   <= 1'b0;
        prog_bl_data    <= '0;
      end
    end
  end
endmodule
