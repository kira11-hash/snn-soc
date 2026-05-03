// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/top/chip_top.sv
// Purpose: Tapeout-intent chip-level wrapper around snn_soc_top for pad-facing signal routing.
// Role in system: Freezes package-facing logic ports now, while keeping room for future pad cell insertion and physical constraints.
// Current status: Tapeout-intent digital wrapper; the canonical pad source of truth lives in doc/15_asic_pad_map.md.
// Scope note: This file models only signal-facing ports. Power pads and 3 ESD-reserved pads are documented, not instantiated here.
// Remaining tapeout work is pad-cell-library specific: IO cell instantiation, ESD options, drive-strength config, and final package constraints.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: chip_top.sv
// 描述: 芯片 pad 级顶层包装层（tapeout-intent 逻辑版）
//
// 设计意图:
//   1) 以 snn_soc_top 为内核，提供 pad-facing 端口映射，不改变内部协议语义。
//   2) 冻结当前 55-pad 方案里的 pad-facing 信号端口，后续在此层完成 pad cell
//      与物理约束收口。
//   3) 避免把 pad 级改动直接耦合到 snn_soc_top 内核逻辑。
//
// 注意:
//   - 当前外部复用端口已与 snn_soc_top 的 _ext 端口直连，用于冻结 pad-facing 口径。
//   - 全部 55 pad 的正式编号/名称/方向/类型/复位行为以 doc/15_asic_pad_map.md 为准。
//   - 后续 tapeout 前需在本模块内完成:
//       a) pad cell 实例化
//       b) ESD/drive strength/电平配置收敛
//       c) package/pad-ring/IO 约束收敛
//======================================================================
module chip_top #(
  // Simulation / FPGA bring-up hook.  Tape-out replaces boot_rom.sv with a
  // foundry mask-ROM macro generated from the same boot_rom.hex content.
  // ⚠️ 默认空字符串会让 boot_rom 内容全 0（CPU 上电从 0x0 取指 → 全 0
  // 指令在 RV32I 上是非法 → trap）。仿真 / FPGA 必须显式传入 .hex 文件路径，
  // tape-out 由 mask ROM macro 取代。下方 initial 块在仿真时打 WARN，避免
  // 静默崩溃。
  // BLOCKER B-1 fix（2026-05-02 audit）：默认从 ""（空 → ROM 全 0 → 上电 trap）
  // 改为指向 fw/boot_rom/out/boot_rom.hex（FPGA 仿真 + 默认综合都能用）。
  // tape-out 真正流片时由 foundry mask ROM compiler 把这份 hex 烧进 mask ROM，
  // 不再依赖 $readmemh，但参数语义保持一致：默认值必须是一个**有效**的 boot 镜像。
  // 若实例化时确实想让 ROM 全 0（例如 lint-only），必须显式 override 成 ""，
  // 配套 `initial $display` 警告在仿真打印（line 113-117）。
  parameter BOOT_ROM_INIT_FILE = "fw/boot_rom/out/boot_rom.hex"
) (
  // 基础时钟复位（pad）
  input  logic clk_pad,
  input  logic rst_n_pad,

  // 常规外设（pad）
  input  logic uart_rx_pad,
  output logic uart_tx_pad,
  output logic spi_cs_n_pad,
  output logic spi_sck_pad,
  output logic spi_mosi_pad,
  input  logic spi_miso_pad,
  input  logic jtag_tck_pad,
  input  logic jtag_tms_pad,
  input  logic jtag_tdi_pad,
  output logic jtag_tdo_pad,

  // 与模拟芯片互联相关的 pad-facing RTL 端口：
  //   - 推理载体接口对应 doc/15 pads 19..45
  //   - 外部编程 sideband 对应 pads 46..52
  //   推理接口（原有，frozen 2026-03-16）
  output logic [7:0] wl_data_pad,
  output logic [2:0] wl_group_sel_pad,
  output logic       wl_latch_pad,
  output logic       cim_start_pad,
  input  logic       cim_done_pad,
  output logic [4:0] bl_sel_pad,
  input  logic [7:0] bl_data_pad,
  //   外部编程接口（新增，frozen 2026-04-24，方案 α'，7 new pads）
  //   详见 doc/08_cim_analog_interface.md §10 + doc/15_asic_pad_map.md 46..52 号 pad
  output logic [2:0] prog_op_pad,      // op 编码（D→A）
  output logic [3:0] prog_level_pad    // 目标电导等级（D→A，仅 write 生效）
);
  // ── Async / CDC synchronizers (2026-05-03 added，pre-tape-out fix) ──
  //
  //  rst_n_pad：pad 上的异步复位。pre-tape-out audit 发现整个 SoC 之前直接
  //  把 pad-level rst_n 喂给所有 always_ff，缺 sync release。在这里加
  //  reset_sync 做 async-assert / sync-release，下游 SoC 收到的就是干净的
  //  rst_n_sync，避免 deassertion edge 违反 recovery/removal timing 引入
  //  metastability。详见 rtl/sys/reset_sync.sv 头注释。
  //
  //  cim_done_pad：模拟芯片完成信号，时序由模拟侧自己产生，对数字 clk 是
  //  完全异步。同样要 2-FF sync 才能给数字 FSM 用，否则可能被误读早一拍 /
  //  晚一拍 / 进入未知态。详见 rtl/sys/sync_2ff.sv 头注释。
  //
  //  bl_data_pad（多 bit ADC 数据）不做位级 2-FF sync——多 bit 总线的位级
  //  sync 会因 per-bit cycle skew 损坏数据。靠 cim_done sync 后，下游 FSM
  //  在已知稳定窗口内捕获 bl_data 才是正确做法（隐式同步）。
  //
  //  其他 input pad：
  //   - uart_rx_pad：V1 未实现 RX，仅占位 _unused，故不需 sync
  //   - spi_miso_pad：SPI master 内部 SCK 由 clk 分频生成，MISO 与 clk 同
  //     源，时序确定，不属 CDC 不需 sync
  //   - jtag_tck_pad / jtag_tms_pad / jtag_tdi_pad：jtag_mem_loader 内已用
  //     toggle + 2-FF (* async_reg = "TRUE" *) sync 处理（CLAUDE.md FP-005）
  logic rst_n_sync;
  logic cim_done_sync;

  reset_sync #(.STAGES(2)) u_reset_sync (
    .clk         (clk_pad),
    .rst_n_async (rst_n_pad),
    .rst_n_sync  (rst_n_sync)
  );

  sync_2ff #(.WIDTH(1)) u_cim_done_sync (
    .clk        (clk_pad),
    .rst_n_sync (rst_n_sync),
    .din_async  (cim_done_pad),
    .dout_sync  (cim_done_sync)
  );

  // 核心 SoC（TO 目标路径：默认带 E203 + 外部 CIM pad 接口 + mask ROM）
  //   * ENABLE_PROGRAM_MODE=1：挂上 cim_program_ctrl + arbiter（tape-out 需要）
  //   * ENABLE_BOOT_ROM=1：0x0 走 boot_rom mask ROM（上电即跑 bootloader），
  //     instr_sram 上移到 0x1000。BOOT_ROM_INIT_FILE 在正式流片前替换为
  //     foundry ROM compiler 的 mask 数据，这里保持空让 FPGA 仿真可用。
  snn_soc_top #(
    .ENABLE_E203         (1'b1),
    .ENABLE_EXT_CIM_IF   (1'b1),
    .ENABLE_PROGRAM_MODE (1'b1),
    .ENABLE_BOOT_ROM     (1'b1),
    .BOOT_ROM_INIT_FILE  (BOOT_ROM_INIT_FILE)
  ) u_soc_core (
    .clk      (clk_pad),
    .rst_n    (rst_n_sync),       // sync'd reset，不再直传 pad
    .uart_rx  (uart_rx_pad),
    .uart_tx  (uart_tx_pad),
    .spi_cs_n (spi_cs_n_pad),
    .spi_sck  (spi_sck_pad),
    .spi_mosi (spi_mosi_pad),
    .spi_miso (spi_miso_pad),
    .jtag_tck (jtag_tck_pad),
    .jtag_tms (jtag_tms_pad),
    .jtag_tdi (jtag_tdi_pad),
    .jtag_tdo (jtag_tdo_pad),
    .wl_data_ext      (wl_data_pad),
    .wl_group_sel_ext (wl_group_sel_pad),
    .wl_latch_ext     (wl_latch_pad),
    .cim_start_ext    (cim_start_pad),
    .cim_done_ext     (cim_done_sync),    // sync'd cim_done，不再直传 pad
    .bl_sel_ext       (bl_sel_pad),
    .bl_data_ext      (bl_data_pad),
    .prog_op_ext      (prog_op_pad),
    .prog_level_ext   (prog_level_pad)
  );

  // ── Bring-up sanity（仅仿真）──────────────────────────────────────────
  // 若 BOOT_ROM_INIT_FILE 为空，boot_rom 内容全 0，CPU 上电会立刻 trap。
  // 在仿真启动时打一行明显的 warning，避免静默挂死被误判成功能问题。
  // (synthesis 会忽略 initial 显示，对面积/时序无影响)
  // verilator coverage_off
  // synopsys translate_off
  initial begin
    if (BOOT_ROM_INIT_FILE == "") begin
      $display("[chip_top WARN] BOOT_ROM_INIT_FILE is empty: boot ROM will read all zeros.");
      $display("[chip_top WARN] CPU will trap on power-up. For sim/FPGA, override with");
      $display("[chip_top WARN] .BOOT_ROM_INIT_FILE(\"<path>/boot_rom.hex\") at instance.");
    end
  end
  // synopsys translate_on
  // verilator coverage_on
endmodule

