`timescale 1ns/1ps
//======================================================================
// 文件名: boot_rom.sv
// 模块名: boot_rom
//
// 【功能概述】
// 小容量只读 ROM 模型。为 ASIC tape-out 准备：
//   - FPGA 综合：Vivado 会把 $readmemh + 组合读的 logic 数组推成
//     分布式 ROM（小容量 <= 4KB 时 LUT 实现）或 BRAM。
//   - ASIC 流片：在 tape-out 前替换为工艺 foundry 的 mask ROM macro
//     （如 TSMC ROM compiler 生成的 PRE65GP*_ROM_xxxx），保持接口
//     不变；INIT_FILE 烧进掩膜版图。
//
// 【用途（silicon bring-up）】
// 真流片芯片上电后，SRAM macro 内容通常是 X（无法 $readmemh 预装），
// CPU 从 0x0 取指会读到 garbage 然后 fault。解决方案：在 0x0 处放一颗
// mask ROM，内容是 bootloader（或直接是 silicon_bringup self-test）：
//   - 最简：ROM 只做一个 `jal 0x1000` 跳到 INSTR_SRAM，让 JTAG/SPI
//     boot 把真正应用固件加载到 INSTR_SRAM 后跳过去。
//   - 升级：ROM 里直接烧完整的 silicon_bringup.c，上电即可自检。
//
// 【接口协议】
// 与 sram_simple 对齐的 bus_simple_if 从设备接口，只读：
//   - rdata 组合输出（0 拍延迟，bus_interconnect 下一拍注册）
//   - 所有写请求被忽略（ROM 本质只读）
//
// 【参数】
//   SIZE_BYTES : ROM 容量，默认 4096 B (4 KB)。必须 4 的倍数。
//   INIT_FILE  : $readmemh 格式文件，每行 1 个 32-bit word。
//                为空时 ROM 内容为全 0（FPGA 综合时等价于"未烧写"）。
//
// 【tape-out 替换指南】
//   1. 综合时 `(* dont_touch = "true" *)` 或直接在约束里 set_replacement
//      把本模块替换为工艺库 ROM macro。
//   2. 替换后 INIT_FILE 参数失效，改用 macro 的 mask content 配置
//      （由 foundry / 设计所提供的 ROM compiler flow）。
//   3. 接口（clk / req_valid / req_addr / rdata）保持一致。
//======================================================================
module boot_rom #(
  parameter int unsigned SIZE_BYTES = 4096,   // 默认 4 KB
  parameter              INIT_FILE  = ""       // $readmemh 预装文件
) (
  input  logic        clk,
  input  logic        rst_n,

  // 总线接口（bus_simple slave，与 sram_simple 对齐）
  input  logic        req_valid,
  input  logic        req_write,   // 写请求被忽略（ROM 只读）
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,   // 未使用
  input  logic [3:0]  req_wstrb,   // 未使用
  output logic [31:0] rdata
);
  // ── 参数派生 ──────────────────────────────────────────────────────────
  localparam int WORDS     = SIZE_BYTES / 4;
  localparam int ADDR_BITS = (WORDS <= 1) ? 1 : $clog2(WORDS);

  // ── ROM 存储阵列 ──────────────────────────────────────────────────────
  // 仿真 + FPGA：reg 数组 + $readmemh。ASIC：替换为 foundry ROM macro。
  logic [31:0] rom [0:WORDS-1];

  // Word 地址提取（字节地址 >> 2，取 ADDR_BITS 位）。
  // SIZE_BYTES=4 时只有 rom[0] 一个 word；ADDR_BITS 被钳到 1 仅为避免零宽
  // 向量，真实地址必须继续钳成 0，不能让 req_addr[2] 访问 rom[1]。
  wire [ADDR_BITS-1:0] word_addr =
      (WORDS <= 1) ? '0 : req_addr[ADDR_BITS+1:2];

  // 预装 ROM 内容
  initial begin
    if (INIT_FILE != "") begin
      $readmemh(INIT_FILE, rom);
    end else begin
      // 默认：全 0（未烧写的 ROM 行为）
      for (int i = 0; i < WORDS; i++) rom[i] = 32'h0000_0000;
    end
  end

  // ── 组合读（0 拍延迟，与 sram_simple 对齐）──────────────────────────
  assign rdata = rom[word_addr];

  // ── 写请求显式忽略 + lint 消除 ──────────────────────────────────────
  wire _unused = &{1'b0, rst_n, req_valid, req_write, req_addr,
                   req_wdata, req_wstrb};

endmodule
