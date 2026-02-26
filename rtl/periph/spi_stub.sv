// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: rtl/periph/spi_stub.sv
// Purpose: SPI placeholder module for future flash boot/data-loading support.
// Role in system: Keeps peripheral address map stable during MVP development and verification.
// Behavior summary: Stubbed register behavior only; no real SPI waveforms/transactions are generated.
// Upgrade path: Replace by SPI master controller while keeping bus decode range and software-facing registers coherent.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: spi_stub.sv
// 模块名: spi_stub
//
// 【功能概述】
// SPI Flash 外设占位模块（stub）。V1 阶段不实现真实 SPI 协议，
// 但提供完整寄存器接口，地址空间：0x4000_0300 ~ 0x4000_03FF。
//
// 【SPI 协议背景】
// SPI（Serial Peripheral Interface）4 线制：
//   CS_N  - 片选（低有效；拉低启动事务，拉高结束事务）
//   SCK   - 时钟（主机提供；CPOL/CPHA 决定采样沿）
//   MOSI  - Master Out Slave In（主机→Flash 数据）
//   MISO  - Master In Slave Out（Flash→主机 数据）
// Flash 常见指令：0x03=Read、0x02=Page Program、0xD8=Sector Erase、0x9F=JEDEC ID
//
// 【寄存器映射】（offset 相对于 SPI 基地址 0x4000_0300）
//   0x00: REG_CTRL   - 控制（可读写；模式、速率、使能等）
//   0x04: REG_STATUS - 状态（只读；BUSY/DONE/ERROR 等；stub 固定为 0）
//   0x08: REG_TXDATA - 发送数据（可读写；stub 不真正发送）
//   0x0C: REG_RXDATA - 接收数据（只读；stub 固定返回 0）
//
// 【物理输出安全状态（stub）】
//   spi_cs_n = 1：Flash 处于待机，不响应任何命令
//   spi_sck  = 0：时钟空闲（CPOL=0 默认）
//   spi_mosi = 0：数据线空闲
//
// 【升级路径】
// V2：替换为完整 SPI Master（支持 Mode 0/1/2/3、DMA 突发、Flash 指令集）
//======================================================================
module spi_stub (
  // ── 时钟和复位 ────────────────────────────────────────────────────────────
  input  logic        clk,       // 系统时钟
  input  logic        rst_n,     // 异步低有效复位

  // ── 总线接口（来自 bus_interconnect，简化 memory-mapped 协议）──────────
  input  logic        req_valid, // 请求有效（当拍）
  input  logic        req_write, // 1=写，0=读
  input  logic [31:0] req_addr,  // 字节地址（低8位=寄存器 offset）
  input  logic [31:0] req_wdata, // 写数据（stub 整字写，不区分字节）
  input  logic [3:0]  req_wstrb, // 字节写使能（stub 忽略，计入 _unused）
  output logic [31:0] rdata,     // 读返回数据（组合，1拍后注册返回主机）

  // ── SPI 物理接口（4 线制）────────────────────────────────────────────────
  output logic        spi_cs_n,  // 片选（低有效；stub 固定 1，Flash 不响应）
  output logic        spi_sck,   // SPI 时钟（stub 固定 0，无时钟波形）
  output logic        spi_mosi,  // 主机→Flash 数据（stub 固定 0）
  input  logic        spi_miso   // Flash→主机 数据（stub 忽略）
);
  // ── 寄存器 offset 定义 ────────────────────────────────────────────────────
  localparam logic [7:0] REG_CTRL   = 8'h00; // 控制寄存器
  localparam logic [7:0] REG_STATUS = 8'h04; // 状态寄存器（只读）
  localparam logic [7:0] REG_TXDATA = 8'h08; // 发送数据
  localparam logic [7:0] REG_RXDATA = 8'h0C; // 接收数据（只读）

  // ── 内部寄存器 ────────────────────────────────────────────────────────────
  logic [31:0] ctrl_reg;    // 控制配置影子寄存器（可读写）
  logic [31:0] status_reg;  // 状态影子寄存器（stub 固定为 0）
  logic [31:0] txdata_reg;  // 发送数据影子寄存器（可读写）

  // ── 地址 offset 提取 ──────────────────────────────────────────────────────
  wire [7:0] addr_offset = req_addr[7:0]; // [31:8] 由 bus_interconnect 路由决策

  // 写使能
  wire write_en = req_valid && req_write;

  // lint 友好：高地址位、wstrb、spi_miso 均不使用
  wire _unused = &{1'b0, req_addr[31:8], req_wstrb, spi_miso};

  // ── SPI 输出固定安全状态 ───────────────────────────────────────────────────
  // stub 下所有输出为"总线空闲"状态，不发起任何 SPI 事务，
  // 确保 Flash 不会因错误波形导致误操作（扇区擦除等不可逆操作）
  assign spi_cs_n = 1'b1; // CS_N=1：Flash 去选中，处于高阻待机
  assign spi_sck  = 1'b0; // SCK=0 ：无时钟（CPOL=0 下空闲为低）
  assign spi_mosi = 1'b0; // MOSI=0：无数据输出

  // ── 寄存器写逻辑（同步时序）───────────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl_reg   <= 32'h0;
      status_reg <= 32'h0;
      txdata_reg <= 32'h0;
    end else begin
      if (write_en) begin
        case (addr_offset)
          REG_CTRL:   ctrl_reg   <= req_wdata; // 软件配置控制（stub 保存不处理）
          REG_TXDATA: txdata_reg <= req_wdata; // 软件写发送数据（stub 不发送）
          default: begin
            // REG_STATUS 只读，REG_RXDATA 只读，其他 offset 忽略
          end
        endcase
      end
    end
  end

  // ── 读数据多路选择（组合逻辑）────────────────────────────────────────────
  always_comb begin
    rdata = 32'h0;
    case (addr_offset)
      REG_CTRL:   rdata = ctrl_reg;    // 读回控制配置
      REG_STATUS: rdata = status_reg;  // stub：固定 0（无 BUSY，随时就绪）
      REG_TXDATA: rdata = txdata_reg;  // 读回上次写入的发送数据
      REG_RXDATA: rdata = 32'h0;       // stub：无真实接收，固定返回 0
      default:    rdata = 32'h0;
    endcase
  end
endmodule
