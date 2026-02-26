// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/mem/sram_simple_dp.sv
// Purpose: Minimal dual-port SRAM behavioral model supporting bus access plus DMA read path.
// Role in system: Serves data SRAM where CPU/testbench and DMA need concurrent visibility in MVP flow.
// Behavior summary: One port is memory-mapped bus-facing, another lightweight port feeds DMA reads.
// Modeling intent: Functional dual-port behavior for integration simulation before macro inference/replacement.
// Debug note: Address slicing and byte lanes are intentionally simplified to match current SoC packing assumptions.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: sram_simple_dp.sv
// 描述: 简化双端口 SRAM 模型（1 个总线端口 + 1 个只读 DMA 端口）。
//       - 总线端口：同步写 + 组合读
//       - DMA 端口：只读组合读
//======================================================================
//
// -----------------------------------------------------------------------
// 端口行为总结：
//
//   Port A（总线端口）：
//     - 写：同步（posedge clk），受字节使能（req_wstrb[3:0]）控制
//     - 读：组合（纯组合逻辑，bus_word_addr → mem[...] → rdata），零延迟
//     - 同一地址同拍先写后读：rdata 会反映写入值（写透模型）
//       因为 rdata 直接来自 mem 数组组合读，而同步写在 posedge 后才更新 mem，
//       所以在仿真中：
//         * 同拍写+读，rdata 读到的是写前旧值（寄存器还未更新）
//         * 下一拍读，rdata 读到的才是写后新值
//       这与典型 synchronous-write + combinational-read SRAM 行为一致。
//
//   Port B（DMA 只读端口）：
//     - 读：组合（dma_rd_en 为 1 时，dma_rd_addr → mem[...] → dma_rdata）
//     - 零延迟：dma_engine 在 ST_RD0/ST_RD1 拉高 dma_rd_en 时，
//               dma_rdata 当拍即有效，无需额外等待周期
//     - dma_rd_en=0 时，dma_rdata 输出 32'h0（避免 X 传播）
//
// 两个端口共享同一 mem 数组，支持 CPU 写后 DMA 立即读（无冲突仲裁，
// 因为 V1 中 DMA 只读、CPU 只写，写端口和读端口方向不冲突）。
//
// -----------------------------------------------------------------------
// 地址映射：
//   参数 MEM_BYTES 决定 SRAM 总字节数（默认 16KB = 4096 个 32-bit word）
//   word 地址 = 字节地址[ADDR_BITS+1:2]（右移 2 位，即除以 4）
//   ADDR_BITS = $clog2(WORDS) = $clog2(MEM_BYTES/4)
//   示例（MEM_BYTES=16384）：WORDS=4096，ADDR_BITS=12，地址范围 [11:0]
//
// -----------------------------------------------------------------------
// 与 dma_engine 的接口时序（关键）：
//   ST_RD0: dma_rd_en↑, dma_rd_addr=addr_ptr → 同拍 dma_rdata 有效
//           → dma_engine 在 posedge 时序捕获到 word0_reg
//   ST_RD1: dma_rd_en↑, dma_rd_addr=addr_ptr+4 → 同拍 dma_rdata 有效
//           → dma_engine 在 posedge 时序捕获到 word1_reg
//   这就是为什么 dma_engine FSM 无需额外等待周期：SRAM 是零延迟模型。
// -----------------------------------------------------------------------
module sram_simple_dp #(
  parameter int MEM_BYTES = 16384  // 例如 16KB；必须是 4 的整数倍
) (
  input  logic        clk,
  input  logic        rst_n,
  // 总线端口（Port A）
  // req_valid + req_write = 1 时同步写入；req_valid + req_write = 0 时组合读出
  input  logic        req_valid,
  input  logic        req_write,
  input  logic [31:0] req_addr,   // 字节地址（低 2 位用于字节使能，高位用于 word 寻址）
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,  // 字节使能：bit[n]=1 表示写入 byte n
  output logic [31:0] rdata,      // 组合读输出，始终反映 mem[bus_word_addr]
  // DMA 只读端口（Port B）
  // 无时钟控制，dma_rdata 是纯组合逻辑输出，零延迟
  input  logic        dma_rd_en,  // 读使能（=0 时输出强制为 0）
  input  logic [31:0] dma_rd_addr, // 字节地址（低 2 位忽略，高位用于 word 寻址）
  output logic [31:0] dma_rdata   // 零延迟读出数据（dma_rd_en=0 时为 32'h0）
);
  // -----------------------------------------------------------------------
  // 存储器参数计算
  // WORDS    : 总 word 数 = MEM_BYTES / 4
  // ADDR_BITS: word 地址宽度 = ceil(log2(WORDS))
  //            例：MEM_BYTES=16384 → WORDS=4096 → ADDR_BITS=12
  // -----------------------------------------------------------------------
  localparam int WORDS     = MEM_BYTES / 4;
  localparam int ADDR_BITS = $clog2(WORDS);

  // -----------------------------------------------------------------------
  // 主存储阵列：WORDS 个 32-bit word
  // 在综合时会被映射为 SRAM macro（后续流程）；
  // 仿真中是 reg 数组，初始值为 X（未初始化），TB 写入前不应读取。
  // -----------------------------------------------------------------------
  logic [31:0] mem [0:WORDS-1];

  // -----------------------------------------------------------------------
  // 地址解码（组合逻辑）
  //
  // bus_word_addr: 取字节地址 [ADDR_BITS+1:2]，即右移 2 位得 word 地址
  //               范围 [ADDR_BITS-1:0]，对应 mem 数组索引
  //
  // dma_word_addr: 对 DMA 字节地址做同样处理
  //               DMA 传入的是 SRAM 内部偏移（dma_engine 已减去 ADDR_DATA_BASE）
  //
  // 注：req_addr 和 dma_rd_addr 的高位超出 SRAM 范围的部分被截断，
  //     行为未定义（越界访问）；dma_engine 在 ST_IDLE 已做范围检查。
  // -----------------------------------------------------------------------
  wire [ADDR_BITS-1:0] bus_word_addr = req_addr[ADDR_BITS+1:2];
  wire [ADDR_BITS-1:0] dma_word_addr = dma_rd_addr[ADDR_BITS+1:2];
  // 标记未使用信号位（lint 友好）
  // rst_n: 本模型无时序复位（SRAM 上电后内容不定），rst_n 仅 lint 消警
  // req_addr, dma_rd_addr 的低 2 位（字节内偏移）和高位在地址切片后被忽略
  wire _unused = &{1'b0, rst_n, req_addr, dma_rd_addr};

  // -----------------------------------------------------------------------
  // Port A 组合读（零延迟）
  //
  // rdata 直接对应 mem[bus_word_addr]，无寄存器。
  // 优点：CPU 读操作无等待周期，简化 bus_interconnect 时序。
  // 注意：若同拍 CPU 写入同一地址，rdata 读到的是写前旧值（写透模型对此是旧值）。
  // -----------------------------------------------------------------------
  assign rdata    = mem[bus_word_addr];

  // -----------------------------------------------------------------------
  // Port B DMA 组合读（零延迟）
  //
  // dma_rd_en=1 时：dma_rdata = mem[dma_word_addr]，立即有效
  // dma_rd_en=0 时：dma_rdata = 32'h0（避免不必要的 X 传播和功耗模拟误差）
  //
  // 这是 dma_engine FSM 无需在 ST_SETUP 之外额外等待的根本原因：
  // 只要 dma_rd_en 拉高，同一拍 dma_rdata 就已稳定，posedge 可直接捕获。
  // -----------------------------------------------------------------------
  assign dma_rdata = dma_rd_en ? mem[dma_word_addr] : 32'h0;

  // -----------------------------------------------------------------------
  // Port A 同步写（字节使能）
  //
  // 触发条件：req_valid && req_write（同 bus_interconnect 解码逻辑）
  // 字节使能：每个字节独立受 req_wstrb[n] 控制，支持 8/16/32-bit 写入。
  // 写操作在 posedge clk 后才更新 mem，因此同拍组合读 rdata 仍为旧值。
  //
  // 无复位：SRAM 内容上电不确定（X），系统复位不清零 mem，
  //          固件/TB 需要先写入再读取。
  // -----------------------------------------------------------------------
  // 同步写
  always_ff @(posedge clk) begin
    if (req_valid && req_write) begin
      if (req_wstrb[0]) mem[bus_word_addr][7:0]   <= req_wdata[7:0];   // byte 0（最低字节）
      if (req_wstrb[1]) mem[bus_word_addr][15:8]  <= req_wdata[15:8];  // byte 1
      if (req_wstrb[2]) mem[bus_word_addr][23:16] <= req_wdata[23:16]; // byte 2
      if (req_wstrb[3]) mem[bus_word_addr][31:24] <= req_wdata[31:24]; // byte 3（最高字节）
    end
  end
endmodule
