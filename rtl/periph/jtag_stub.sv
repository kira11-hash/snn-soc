// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/periph/jtag_stub.sv
// Purpose: JTAG placeholder to reserve top-level ports and compilation hooks before E203 integration.
// Role in system: Avoids interface churn while the real core/debug subsystem is still pending.
// Behavior summary: Passive stub only; no TAP state machine behavior.
// Upgrade path: Replace with E203-provided JTAG/debug path during CPU integration stage.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: jtag_stub.sv
// 模块名: jtag_stub
//
// 【功能概述】
// JTAG 接口占位模块（stub）。V1 阶段尚未集成真实 E203 RISC-V 调试
// 子系统，本模块仅保留 JTAG 端口，使顶层编译通过并保持接口不变。
//
// 【JTAG 协议背景 - IEEE 1149.1】
// 标准 4 线 JTAG 接口：
//   TCK - Test Clock    : 调试时钟，由外部 JTAG 探针（如 J-Link）驱动
//   TMS - Test Mode Sel : 控制 TAP 状态机跳转（16 状态，如 Shift-DR, Capture-IR）
//   TDI - Test Data In  : 串行数据输入（移入寄存器/指令的最高有效位先）
//   TDO - Test Data Out : 串行数据输出（移出数据的最低有效位先）
// 真实实现中，TDO 在 TCK 下降沿驱动，避免与 TCK 上升沿采样冲突。
//
// 【此 stub 行为】
// - 不实现任何 TAP 状态机
// - TDO 固定为 0：相当于一条空的扫描链，外部调试器读到全 0
// - 所有输入信号通过 lint 链"使用"但不参与任何逻辑
//
// 【升级路径】
// V2：接入 E203 RISC-V 核的 JTAG 调试子系统（TAP 控制器 + DMI 接口），
//     实现 OpenOCD 兼容的 RISC-V 调试规范（RISCV-DEBUG-0.13）
//======================================================================
module jtag_stub (
  // ── JTAG 4 线接口（IEEE 1149.1 标准）─────────────────────────────────────
  input  logic jtag_tck,  // 测试时钟（与系统时钟异步；探针频率通常 1~20 MHz）
  input  logic jtag_tms,  // 测试模式选择（控制 TAP 状态机；连续5个1可复位到 Test-Logic-Reset）
  input  logic jtag_tdi,  // 数据输入（MSB 先入扫描链；stub 不处理，直接丢弃）
  output logic jtag_tdo   // 数据输出（stub 固定 0；真实实现在 TCK 下降沿驱动捕获到的移位数据）
);
  // ── lint 告警抑制 ──────────────────────────────────────────────────────────
  // 将所有未使用输入接入 XOR 链，消除"输入信号未使用"lint 告警。
  // 使用 XOR 而非 AND，因为 AND 链在输入全 0 时结果为常量，
  // 可能被优化器进一步消除，导致端口在 netlist 中丢失。
  wire _unused = jtag_tck ^ jtag_tms ^ jtag_tdi;

  // ── 输出驱动 ───────────────────────────────────────────────────────────────
  // TDO 固定 0 = 空扫描链响应。外部调试器（如 OpenOCD）会读到全 0 数据，
  // 但只要 TCK/TMS 握手正常，连接本身不会报错（只是无有效 DM/DMI 功能）。
  assign jtag_tdo = 1'b0;
endmodule
