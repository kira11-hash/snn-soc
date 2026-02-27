// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/bus/bus_interconnect.sv
// Purpose: Address-decodes the simple bus and routes one request to one slave region at a time.
// Role in system: Central glue logic between the current bus master and all memory/register/peripheral blocks.
// Behavior summary: Decodes address ranges, forwards request, multiplexes response, and handles default response on miss.
// Assumption: Only one master and one outstanding access are supported in this MVP fabric.
// Design intent: Keep routing/debug simple before AXI-Lite and E203 integration.
// Verification focus: Region boundaries, unmapped accesses, and response selection timing.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: bus_interconnect.sv
// 描述: 简化总线的地址译码与从设备路由。
//       - 固定 1-cycle 响应：请求在本拍进入寄存，下一拍返回响应。
//       - 不支持 wait-state；主设备必须等待 ready/rvalid。
//       - 地址映射来自 snn_soc_pkg。
//======================================================================
//
// ============================================================
// 模块总览 (Module Overview)
// ============================================================
// bus_interconnect 是 SNN SoC 的总线互联结构（Bus Fabric / Crossbar 简化版）。
// 它实现了一个 1-master、N-slave 的地址路由功能，是整个 SoC 的"交换机"。
//
// 关键设计决策：
//
//   1. 请求寄存（Registered Request）：
//      主设备的请求（m_valid, m_addr 等）在时钟上升沿被寄存一拍后，
//      以 req_* 信号的形式转发给从设备。这引入了固定 1 拍的请求延迟。
//
//   2. 固定 1-cycle 响应（Fixed Latency）：
//      从设备（SRAM、寄存器等）均在 req_valid 当拍同步输出读数据，
//      因此主设备从发出请求到收到响应总延迟 = 1 个时钟周期。
//      这简化了握手协议，避免了复杂的流水线对齐逻辑。
//
//   3. 地址偏移转换（Address Offset Translation）：
//      向从设备发出的地址已减去该从设备的基地址（BASE），
//      从设备内部只需处理本地偏移地址，无需知道自己的全局地址。
//
//   4. 读数据 MUX（OR-reduction 等效）：
//      所有从设备的 rdata 通过 case 语句多路选择，
//      每次只有一个从设备的 rdata 有效（确保 OR-tree 正确）。
//
//   5. 写：无读数据返回；读：无写响应
//      m_ready  ← 写事务完成指示（req_valid && req_write）
//      m_rvalid ← 读事务完成指示（req_valid && !req_write）
//      两者互斥，主设备协议要求写请求时不检查 rvalid。
//
// 时序示意（读操作）：
//   时钟: ↑    ↑    ↑    ↑
//   m_valid:   1    0    0    0
//   m_addr:    A    -    -    -
//   ---- 寄存一拍 ----
//   req_valid: 0    1    0    0    ← 从设备在 req_valid 高电平拍处理请求
//   req_addr:  -    A    -    -
//   slave.rdata:     D         ← 从设备组合输出（SRAM 同步读）
//   m_rvalid:  0    1    0    0    ← 主设备在 req_valid 的同一拍看到 rvalid
//   m_rdata:   -    D    -    -
//
// 时序示意（写操作）：
//   时钟: ↑    ↑    ↑    ↑
//   m_valid:   1    0    0
//   m_write:   1    -    -
//   ---- 寄存一拍 ----
//   req_valid: 0    1    0
//   req_write: -    1    -    ← SRAM 在此拍执行写入
//   m_ready:   0    1    0    ← 主设备在此拍得到写完成确认
// ============================================================

module bus_interconnect (
  // 全局时钟与异步低有效复位
  input  logic        clk,
  input  logic        rst_n,

  // ----------------------------------------------------------
  // 主设备侧总线信号（来自 snn_soc_top 的 bus_if 接口）
  // Testbench 在 MVP 阶段直接通过层级引用（dut.bus_if）驱动这些信号，
  // 模拟 CPU（E203）发出的总线事务。
  // ----------------------------------------------------------
  input  logic        m_valid,   // 主设备请求有效（高=有请求，低=总线空闲）
  input  logic        m_write,   // 事务类型：1=写操作，0=读操作
  input  logic [31:0] m_addr,    // 32-bit 字节地址（全局地址空间，由 pkg 定义映射）
  input  logic [31:0] m_wdata,   // 写数据（32-bit）
  input  logic [3:0]  m_wstrb,   // 字节写使能（bit3=byte3，bit0=byte0；读操作时忽略）
  output logic        m_ready,   // 写完成握手：互联通知主设备写操作已被从设备接受
  output logic [31:0] m_rdata,   // 读返回数据（32-bit，m_rvalid 为高时有效）
  output logic        m_rvalid,  // 读数据有效：互联通知主设备读数据已就绪

  // ----------------------------------------------------------
  // 从设备接口：instr_sram（指令 SRAM）
  // 地址范围：ADDR_INSTR_BASE ~ ADDR_INSTR_END（见 snn_soc_pkg）
  // 用途：存放 CPU 指令（MVP 阶段 TB 预加载，E203 V2 接入后使用）
  // ----------------------------------------------------------
  output logic        instr_req_valid, // 指令 SRAM 请求有效（地址命中 instr 区域）
  output logic        instr_req_write, // 写使能（通常为 0，CPU 不写指令空间）
  output logic [31:0] instr_req_addr,  // 本地偏移地址（= 全局地址 - ADDR_INSTR_BASE）
  output logic [31:0] instr_req_wdata, // 写数据（透传，SRAM 内部用 wstrb 选择字节）
  output logic [3:0]  instr_req_wstrb, // 字节写使能（透传）
  input  logic [31:0] instr_rdata,     // SRAM 读出数据（组合输出，当拍有效）

  // ----------------------------------------------------------
  // 从设备接口：data_sram（数据 SRAM，双端口）
  // 地址范围：ADDR_DATA_BASE ~ ADDR_DATA_END
  // 用途：存放输入像素矩阵（8x8=64 像素）
  // 注意：data_sram 有两个端口，此接口是端口 A（总线侧）
  // ----------------------------------------------------------
  output logic        data_req_valid,
  output logic        data_req_write,
  output logic [31:0] data_req_addr,   // 本地偏移地址（= 全局地址 - ADDR_DATA_BASE）
  output logic [31:0] data_req_wdata,
  output logic [3:0]  data_req_wstrb,
  input  logic [31:0] data_rdata,

  // ----------------------------------------------------------
  // 从设备接口：weight_sram（权重 SRAM）
  // 地址范围：ADDR_WEIGHT_BASE ~ ADDR_WEIGHT_END
  // 用途：V1 占位（实际权重存储在 RRAM 阵列中，无需在线加载）
  // ----------------------------------------------------------
  output logic        weight_req_valid,
  output logic        weight_req_write,
  output logic [31:0] weight_req_addr,  // 本地偏移地址（= 全局地址 - ADDR_WEIGHT_BASE）
  output logic [31:0] weight_req_wdata,
  output logic [3:0]  weight_req_wstrb,
  input  logic [31:0] weight_rdata,

  // ----------------------------------------------------------
  // 从设备接口：reg_bank（控制/状态寄存器组）
  // 地址范围：ADDR_REG_BASE ~ ADDR_REG_END
  // 用途：SW 通过此接口读写 SNN 控制寄存器
  // 额外信号：
  //   reg_resp_read_pulse : 当前拍是对 reg 区域的读响应（单拍脉冲）
  //   reg_resp_addr       : 对应的读地址（调试用，当前 reg_bank 未使用，接 _unused）
  // ----------------------------------------------------------
  output logic        reg_req_valid,
  output logic        reg_req_write,
  output logic [31:0] reg_req_addr,   // 本地偏移地址（= 全局地址 - ADDR_REG_BASE）
  output logic [31:0] reg_req_wdata,
  output logic [3:0]  reg_req_wstrb,
  input  logic [31:0] reg_rdata,
  output logic        reg_resp_read_pulse, // 读响应脉冲（给 reg_bank 的额外握手信号）
  output logic [31:0] reg_resp_addr,       // 读响应地址（调试用）

  // ----------------------------------------------------------
  // 从设备接口：dma_regs（DMA 控制寄存器）
  // 地址范围：ADDR_DMA_BASE ~ ADDR_DMA_END
  // 用途：SW 配置 DMA 源地址、长度，写 START 位触发传输
  // ----------------------------------------------------------
  output logic        dma_req_valid,
  output logic        dma_req_write,
  output logic [31:0] dma_req_addr,   // 本地偏移地址（= 全局地址 - ADDR_DMA_BASE）
  output logic [31:0] dma_req_wdata,
  output logic [3:0]  dma_req_wstrb,
  input  logic [31:0] dma_rdata,

  // ----------------------------------------------------------
  // 从设备接口：uart_regs（UART stub 寄存器）
  // 地址范围：ADDR_UART_BASE ~ ADDR_UART_END
  // 用途：V1 占位，uart_stub 所有寄存器读返回 0
  // ----------------------------------------------------------
  output logic        uart_req_valid,
  output logic        uart_req_write,
  output logic [31:0] uart_req_addr,  // 本地偏移地址（= 全局地址 - ADDR_UART_BASE）
  output logic [31:0] uart_req_wdata,
  output logic [3:0]  uart_req_wstrb,
  input  logic [31:0] uart_rdata,

  // ----------------------------------------------------------
  // 从设备接口：spi_regs（SPI stub 寄存器）
  // 地址范围：ADDR_SPI_BASE ~ ADDR_SPI_END
  // 用途：V1 占位，spi_stub 所有寄存器读返回 0
  // ----------------------------------------------------------
  output logic        spi_req_valid,
  output logic        spi_req_write,
  output logic [31:0] spi_req_addr,   // 本地偏移地址（= 全局地址 - ADDR_SPI_BASE）
  output logic [31:0] spi_req_wdata,
  output logic [3:0]  spi_req_wstrb,
  input  logic [31:0] spi_rdata,

  // ----------------------------------------------------------
  // 从设备接口：fifo_regs（FIFO 状态只读寄存器）
  // 地址范围：ADDR_FIFO_BASE ~ ADDR_FIFO_END
  // 用途：SW 通过此接口读取 input/output FIFO 的 count/empty/full
  // ----------------------------------------------------------
  output logic        fifo_req_valid,
  output logic        fifo_req_write,
  output logic [31:0] fifo_req_addr,  // 本地偏移地址（= 全局地址 - ADDR_FIFO_BASE）
  output logic [31:0] fifo_req_wdata,
  output logic [3:0]  fifo_req_wstrb,
  input  logic [31:0] fifo_rdata
);
  // 导入 snn_soc_pkg 中的地址常量（ADDR_*_BASE / ADDR_*_END）
  import snn_soc_pkg::*;

  // ----------------------------------------------------------
  // 从设备选择编码（4-bit 枚举）
  // 使用局部参数而非 enum，以便兼容不同综合工具。
  // SEL_NONE   : 地址未命中任何从设备（未映射地址区域）
  // SEL_INSTR  : 命中指令 SRAM
  // SEL_DATA   : 命中数据 SRAM
  // SEL_WEIGHT : 命中权重 SRAM
  // SEL_REG    : 命中控制寄存器组
  // SEL_DMA    : 命中 DMA 控制寄存器
  // SEL_UART   : 命中 UART stub 寄存器
  // SEL_SPI    : 命中 SPI stub 寄存器
  // SEL_FIFO   : 命中 FIFO 状态寄存器
  // ----------------------------------------------------------
  localparam logic [3:0] SEL_NONE   = 4'd0;
  localparam logic [3:0] SEL_INSTR  = 4'd1;
  localparam logic [3:0] SEL_DATA   = 4'd2;
  localparam logic [3:0] SEL_WEIGHT = 4'd3;
  localparam logic [3:0] SEL_REG    = 4'd4;
  localparam logic [3:0] SEL_DMA    = 4'd5;
  localparam logic [3:0] SEL_UART   = 4'd6;
  localparam logic [3:0] SEL_SPI    = 4'd7;
  localparam logic [3:0] SEL_FIFO   = 4'd8;

  // ----------------------------------------------------------
  // 寄存后的请求信号（req_*）
  // 这些是将 m_* 信号寄存一拍后的版本，用于产生从设备请求和 m_ready/m_rvalid。
  // req_valid  : 当前拍有有效请求需要从设备处理
  // req_write  : 当前请求是写操作
  // req_addr   : 当前请求的字节地址（全局地址，未减 BASE）
  // req_wdata  : 当前请求的写数据
  // req_wstrb  : 当前请求的字节写使能
  // req_sel    : 根据 req_addr 译码得到的从设备选择（组合逻辑，在 always_comb 中更新）
  // req_rdata  : 从选中从设备取到的读数据（组合逻辑，在 case 中选择）
  // ----------------------------------------------------------
  logic        req_valid;
  logic        req_write;
  logic [31:0] req_addr;
  logic [31:0] req_wdata;
  logic [3:0]  req_wstrb;
  logic [3:0]  req_sel;    // 地址译码结果（从设备选择编号）
  logic [31:0] req_rdata;  // 读数据 MUX 输出

  // ----------------------------------------------------------
  // in_range()：地址范围判断辅助函数
  // 功能：判断 addr 是否在 [base, last] 闭区间内（字节地址）
  // 参数：
  //   addr : 待判断的地址
  //   base : 从设备地址段的起始地址（inclusive）
  //   last : 从设备地址段的结束地址（inclusive，= BASE + SIZE - 1）
  // 返回：1 = 命中，0 = 未命中
  //
  // 实现说明：
  //   使用 >= 和 <= 进行无符号比较，适合地址空间在 32-bit 范围内的情况。
  //   下方使用 Verilator 元注释来抑制"函数参数未在函数外使用"的警告。
  // ----------------------------------------------------------
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic in_range(
    input logic [31:0] addr,
    input logic [31:0] base,
    input logic [31:0] last
  );
    in_range = (addr >= base) && (addr <= last);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ----------------------------------------------------------
  // 地址译码逻辑（组合逻辑，always_comb）
  // 输入：req_addr（寄存后的请求地址）
  // 输出：req_sel（从设备选择编号）
  //
  // 优先级：按 if-else if 顺序，优先级依次递减。
  // 实际上各地址段不重叠（由 snn_soc_pkg 保证），所以顺序不影响功能，
  // 但保持 if-else if 结构有助于综合工具生成更优的优先编码器。
  //
  // 未命中地址（address miss）：req_sel = SEL_NONE，读操作返回 32'h0。
  // 这是一种防御性设计，避免总线锁死（即使地址错误也能正常返回）。
  // ----------------------------------------------------------
  always_comb begin
    req_sel = SEL_NONE; // 默认：未命中任何从设备
    if (in_range(req_addr, ADDR_INSTR_BASE, ADDR_INSTR_END)) begin
      req_sel = SEL_INSTR;   // 命中指令 SRAM
    end else if (in_range(req_addr, ADDR_DATA_BASE, ADDR_DATA_END)) begin
      req_sel = SEL_DATA;    // 命中数据 SRAM
    end else if (in_range(req_addr, ADDR_WEIGHT_BASE, ADDR_WEIGHT_END)) begin
      req_sel = SEL_WEIGHT;  // 命中权重 SRAM
    end else if (in_range(req_addr, ADDR_REG_BASE, ADDR_REG_END)) begin
      req_sel = SEL_REG;     // 命中控制寄存器组
    end else if (in_range(req_addr, ADDR_DMA_BASE, ADDR_DMA_END)) begin
      req_sel = SEL_DMA;     // 命中 DMA 控制寄存器
    end else if (in_range(req_addr, ADDR_UART_BASE, ADDR_UART_END)) begin
      req_sel = SEL_UART;    // 命中 UART stub
    end else if (in_range(req_addr, ADDR_SPI_BASE, ADDR_SPI_END)) begin
      req_sel = SEL_SPI;     // 命中 SPI stub
    end else if (in_range(req_addr, ADDR_FIFO_BASE, ADDR_FIFO_END)) begin
      req_sel = SEL_FIFO;    // 命中 FIFO 状态寄存器
    end
    // 其他地址：req_sel 保持 SEL_NONE（由 default 值保证）
  end

  // ----------------------------------------------------------
  // 请求寄存器（always_ff，1 拍延迟）
  // 功能：将主设备的请求信号寄存一拍，产生 req_* 信号组。
  // 这是整个 1-cycle 延迟的来源。
  //
  // 复位行为：
  //   rst_n=0 → req_valid 清 0（总线处于空闲状态，从设备不会收到请求）
  //   地址/数据/控制保持复位值（0），防止复位后产生误操作。
  //
  // 正常工作：
  //   每个时钟上升沿采样 m_valid。
  //   只有 m_valid=1 时才更新 req_write/req_addr/req_wdata/req_wstrb，
  //   这是一种功耗优化（避免无效请求时寄存器翻转）。
  //   req_valid 无条件跟随 m_valid（用于从设备的 valid 门控）。
  // ----------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // 异步复位：所有请求寄存器清零
      req_valid <= 1'b0;
      req_write <= 1'b0;
      req_addr  <= 32'h0;
      req_wdata <= 32'h0;
      req_wstrb <= 4'h0;
    end else begin
      req_valid <= m_valid; // 每拍更新：主设备有请求则 req_valid=1，否则=0
      if (m_valid) begin
        // 只在主设备有请求时才捕获地址/数据/控制（减少无效翻转）
        req_write <= m_write;
        req_addr  <= m_addr;
        req_wdata <= m_wdata;
        req_wstrb <= m_wstrb;
      end
    end
  end

  // ----------------------------------------------------------
  // 从设备请求分发（组合逻辑，assign）
  // 每个从设备的 req_valid 由两个条件决定：
  //   1. req_valid：当前拍有有效请求（寄存后）
  //   2. req_sel == SEL_xxx：地址译码结果命中该从设备
  //
  // 在任意时刻，最多只有一个从设备的 req_valid 为高
  //（因为 req_sel 是互斥的一热编码结果）。
  // ----------------------------------------------------------
  assign instr_req_valid = req_valid && (req_sel == SEL_INSTR);   // 指令 SRAM 请求有效
  assign data_req_valid  = req_valid && (req_sel == SEL_DATA);    // 数据 SRAM 请求有效
  assign weight_req_valid= req_valid && (req_sel == SEL_WEIGHT);  // 权重 SRAM 请求有效
  assign reg_req_valid   = req_valid && (req_sel == SEL_REG);     // 寄存器组请求有效
  assign dma_req_valid   = req_valid && (req_sel == SEL_DMA);     // DMA 寄存器请求有效
  assign uart_req_valid  = req_valid && (req_sel == SEL_UART);    // UART stub 请求有效
  assign spi_req_valid   = req_valid && (req_sel == SEL_SPI);     // SPI stub 请求有效
  assign fifo_req_valid  = req_valid && (req_sel == SEL_FIFO);    // FIFO 寄存器请求有效

  // 事务类型（读/写）广播给所有从设备
  // 从设备根据自身的 req_valid 决定是否响应，req_write 只在 req_valid=1 时有意义
  assign instr_req_write = req_write;
  assign data_req_write  = req_write;
  assign weight_req_write= req_write;
  assign reg_req_write   = req_write;
  assign dma_req_write   = req_write;
  assign uart_req_write  = req_write;
  assign spi_req_write   = req_write;
  assign fifo_req_write  = req_write;

  // ----------------------------------------------------------
  // 地址偏移转换（Address Base Subtraction）
  // 每个从设备收到的是本地偏移地址（从 0 开始），而非全局地址。
  // 好处：从设备内部地址解码逻辑更简单（不需要知道自己的全局 BASE）。
  // 实现：直接相减，由综合工具优化为常量相减逻辑。
  //
  // 注意：减法仅在对应 req_valid 有效时才有意义；
  //       无效拍时 req_addr 可能是任意值，但从设备不会响应（req_valid=0）。
  // ----------------------------------------------------------
  assign instr_req_addr  = req_addr - ADDR_INSTR_BASE;   // 相对于指令 SRAM 起始地址的偏移
  assign data_req_addr   = req_addr - ADDR_DATA_BASE;    // 相对于数据 SRAM 起始地址的偏移
  assign weight_req_addr = req_addr - ADDR_WEIGHT_BASE;  // 相对于权重 SRAM 起始地址的偏移
  assign reg_req_addr    = req_addr - ADDR_REG_BASE;     // 相对于控制寄存器起始地址的偏移
  assign dma_req_addr    = req_addr - ADDR_DMA_BASE;     // 相对于 DMA 寄存器起始地址的偏移
  assign uart_req_addr   = req_addr - ADDR_UART_BASE;    // 相对于 UART 寄存器起始地址的偏移
  assign spi_req_addr    = req_addr - ADDR_SPI_BASE;     // 相对于 SPI 寄存器起始地址的偏移
  assign fifo_req_addr   = req_addr - ADDR_FIFO_BASE;    // 相对于 FIFO 寄存器起始地址的偏移

  // ----------------------------------------------------------
  // 写数据广播（直接透传，不做转换）
  // 所有从设备共用同一组 req_wdata/req_wstrb，
  // 从设备仅在 req_valid && req_write 时采用这些数据写入。
  // ----------------------------------------------------------
  assign instr_req_wdata = req_wdata;
  assign data_req_wdata  = req_wdata;
  assign weight_req_wdata= req_wdata;
  assign reg_req_wdata   = req_wdata;
  assign dma_req_wdata   = req_wdata;
  assign uart_req_wdata  = req_wdata;
  assign spi_req_wdata   = req_wdata;
  assign fifo_req_wdata  = req_wdata;

  // 字节写使能广播（4-bit，bit3=最高字节，bit0=最低字节）
  assign instr_req_wstrb = req_wstrb;
  assign data_req_wstrb  = req_wstrb;
  assign weight_req_wstrb= req_wstrb;
  assign reg_req_wstrb   = req_wstrb;
  assign dma_req_wstrb   = req_wstrb;
  assign uart_req_wstrb  = req_wstrb;
  assign spi_req_wstrb   = req_wstrb;
  assign fifo_req_wstrb  = req_wstrb;

  // ----------------------------------------------------------
  // 读数据多路选择（always_comb，case 语句）
  // 功能：根据 req_sel 从所有从设备的 rdata 中选择有效的一路。
  //
  // 设计说明：
  //   - 每次只有一个从设备的 req_valid 为高，对应的 rdata 是有效值，
  //     其他从设备的 rdata 可能是 0 或不定值（但 case 语句确保只选择目标从设备）。
  //   - default 分支：未命中地址时返回 32'h0（防御性设计，避免锁死）。
  //   - 此处的组合逻辑直接映射到 m_rdata（见下方 assign）。
  //
  // 为什么用 case 而不用 OR-tree？
  //   case 语句在综合后等效于 MUX，时序和面积均优于显式 OR-reduction。
  //   而且 case 更直观，便于 lint 和代码审查。
  // ----------------------------------------------------------
  always_comb begin
    req_rdata = 32'h0; // 默认：未命中时返回全零
    case (req_sel)
      SEL_INSTR:  req_rdata = instr_rdata;   // 指令 SRAM 读出数据
      SEL_DATA:   req_rdata = data_rdata;    // 数据 SRAM 读出数据
      SEL_WEIGHT: req_rdata = weight_rdata;  // 权重 SRAM 读出数据
      SEL_REG:    req_rdata = reg_rdata;     // 控制寄存器读出数据
      SEL_DMA:    req_rdata = dma_rdata;     // DMA 寄存器读出数据
      SEL_UART:   req_rdata = uart_rdata;    // UART stub 读出数据（恒为 0）
      SEL_SPI:    req_rdata = spi_rdata;     // SPI stub 读出数据（恒为 0）
      SEL_FIFO:   req_rdata = fifo_rdata;    // FIFO 状态寄存器读出数据
      default:    req_rdata = 32'h0;         // 未命中地址：返回 0
    endcase
  end

  // ----------------------------------------------------------
  // 主设备响应信号生成（纯组合，assign）
  // 响应在 req_valid 为高的同一拍产生，实现严格的 1-cycle 延迟。
  //
  // m_ready（写完成）：
  //   条件：req_valid=1（有请求）且 req_write=1（是写事务）
  //   含义：互联已将写请求转发给对应从设备，从设备在此拍写入，
  //          主设备可在下一拍发出新请求。
  //   注意：写操作无需等待从设备"真正完成"，因为所有从设备均在 1 拍内完成写入。
  //
  // m_rvalid（读数据有效）：
  //   条件：req_valid=1（有请求）且 req_write=0（是读事务）
  //   含义：从设备在此拍已将读数据放到 rdata 总线，m_rdata 有效。
  //   注意：m_ready 和 m_rvalid 互斥（同一事务不可能既是读又是写）。
  //
  // m_rdata（读返回数据）：
  //   直接连接到 req_rdata（case 语句选择的从设备读数据）。
  //   无寄存器，纯组合路径：req_addr → req_sel → req_rdata → m_rdata。
  // ----------------------------------------------------------
  assign m_ready  = req_valid && req_write;   // 写事务完成指示
  assign m_rvalid = req_valid && !req_write;  // 读数据有效指示
  assign m_rdata  = req_rdata;                // 读数据（来自选中从设备的组合输出）

  // ----------------------------------------------------------
  // reg_resp_read_pulse / reg_resp_addr（额外输出，供 reg_bank 使用）
  //
  // reg_resp_read_pulse：
  //   当前拍恰好是对 reg_bank 区域的读响应（=1 表示 reg_bank 读操作正在返回数据）。
  //   条件：req_valid=1 && !req_write（读事务）&& req_sel==SEL_REG（地址命中 reg）
  //   用途：reg_bank 可用此脉冲触发内部逻辑（如：自动清除 done_pulse）。
  //   当前版本：reg_bank 未使用（接 _unused_top lint 抑制 wire）。
  //
  // reg_resp_addr：
  //   对应读操作的全局字节地址（req_addr，未减 BASE）。
  //   注意：这里使用 req_addr（全局地址）而非 reg_req_addr（偏移地址），
  //         是为了让 reg_bank 在调试时能看到完整地址信息。
  //   当前版本：reg_bank 未使用。
  // ----------------------------------------------------------
  assign reg_resp_read_pulse = req_valid && !req_write && (req_sel == SEL_REG);
  assign reg_resp_addr       = req_addr; // 注意：此处是全局地址，非偏移地址

endmodule
