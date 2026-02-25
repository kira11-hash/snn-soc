`timescale 1ns/1ps
//======================================================================
// 文件名: bus_interconnect.sv
// 描述: 简化总线的地址译码与从设备路由。
//       - 固定 1-cycle 响应：请求在本拍进入寄存，下一拍返回响应。
//       - 不支持 wait-state；主设备必须等待 ready/rvalid。
//       - 地址映射来自 snn_soc_pkg。
//======================================================================
module bus_interconnect (
  input  logic        clk,
  input  logic        rst_n,

  // 主设备侧总线信号
  input  logic        m_valid,
  input  logic        m_write,
  input  logic [31:0] m_addr,
  input  logic [31:0] m_wdata,
  input  logic [3:0]  m_wstrb,
  output logic        m_ready,
  output logic [31:0] m_rdata,
  output logic        m_rvalid,

  // instr_sram
  output logic        instr_req_valid,
  output logic        instr_req_write,
  output logic [31:0] instr_req_addr,
  output logic [31:0] instr_req_wdata,
  output logic [3:0]  instr_req_wstrb,
  input  logic [31:0] instr_rdata,

  // data_sram
  output logic        data_req_valid,
  output logic        data_req_write,
  output logic [31:0] data_req_addr,
  output logic [31:0] data_req_wdata,
  output logic [3:0]  data_req_wstrb,
  input  logic [31:0] data_rdata,

  // weight_sram
  output logic        weight_req_valid,
  output logic        weight_req_write,
  output logic [31:0] weight_req_addr,
  output logic [31:0] weight_req_wdata,
  output logic [3:0]  weight_req_wstrb,
  input  logic [31:0] weight_rdata,

  // reg_bank
  output logic        reg_req_valid,
  output logic        reg_req_write,
  output logic [31:0] reg_req_addr,
  output logic [31:0] reg_req_wdata,
  output logic [3:0]  reg_req_wstrb,
  input  logic [31:0] reg_rdata,
  output logic        reg_resp_read_pulse,
  output logic [31:0] reg_resp_addr,

  // dma_regs
  output logic        dma_req_valid,
  output logic        dma_req_write,
  output logic [31:0] dma_req_addr,
  output logic [31:0] dma_req_wdata,
  output logic [3:0]  dma_req_wstrb,
  input  logic [31:0] dma_rdata,

  // uart_regs
  output logic        uart_req_valid,
  output logic        uart_req_write,
  output logic [31:0] uart_req_addr,
  output logic [31:0] uart_req_wdata,
  output logic [3:0]  uart_req_wstrb,
  input  logic [31:0] uart_rdata,

  // spi_regs
  output logic        spi_req_valid,
  output logic        spi_req_write,
  output logic [31:0] spi_req_addr,
  output logic [31:0] spi_req_wdata,
  output logic [3:0]  spi_req_wstrb,
  input  logic [31:0] spi_rdata,

  // fifo_regs
  output logic        fifo_req_valid,
  output logic        fifo_req_write,
  output logic [31:0] fifo_req_addr,
  output logic [31:0] fifo_req_wdata,
  output logic [3:0]  fifo_req_wstrb,
  input  logic [31:0] fifo_rdata
);
  import snn_soc_pkg::*;

  localparam logic [3:0] SEL_NONE   = 4'd0;
  localparam logic [3:0] SEL_INSTR  = 4'd1;
  localparam logic [3:0] SEL_DATA   = 4'd2;
  localparam logic [3:0] SEL_WEIGHT = 4'd3;
  localparam logic [3:0] SEL_REG    = 4'd4;
  localparam logic [3:0] SEL_DMA    = 4'd5;
  localparam logic [3:0] SEL_UART   = 4'd6;
  localparam logic [3:0] SEL_SPI    = 4'd7;
  localparam logic [3:0] SEL_FIFO   = 4'd8;

  // 请求寄存：保证固定 1-cycle 响应
  logic        req_valid;
  logic        req_write;
  logic [31:0] req_addr;
  logic [31:0] req_wdata;
  logic [3:0]  req_wstrb;
  logic [3:0]  req_sel;
  logic [31:0] req_rdata;

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic in_range(
    input logic [31:0] addr,
    input logic [31:0] base,
    input logic [31:0] last
  );
    in_range = (addr >= base) && (addr <= last);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    req_sel = SEL_NONE;
    if (in_range(req_addr, ADDR_INSTR_BASE, ADDR_INSTR_END)) begin
      req_sel = SEL_INSTR;
    end else if (in_range(req_addr, ADDR_DATA_BASE, ADDR_DATA_END)) begin
      req_sel = SEL_DATA;
    end else if (in_range(req_addr, ADDR_WEIGHT_BASE, ADDR_WEIGHT_END)) begin
      req_sel = SEL_WEIGHT;
    end else if (in_range(req_addr, ADDR_REG_BASE, ADDR_REG_END)) begin
      req_sel = SEL_REG;
    end else if (in_range(req_addr, ADDR_DMA_BASE, ADDR_DMA_END)) begin
      req_sel = SEL_DMA;
    end else if (in_range(req_addr, ADDR_UART_BASE, ADDR_UART_END)) begin
      req_sel = SEL_UART;
    end else if (in_range(req_addr, ADDR_SPI_BASE, ADDR_SPI_END)) begin
      req_sel = SEL_SPI;
    end else if (in_range(req_addr, ADDR_FIFO_BASE, ADDR_FIFO_END)) begin
      req_sel = SEL_FIFO;
    end
  end

  // 捕获主设备请求（下一拍响应）
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      req_valid <= 1'b0;
      req_write <= 1'b0;
      req_addr  <= 32'h0;
      req_wdata <= 32'h0;
      req_wstrb <= 4'h0;
    end else begin
      req_valid <= m_valid;
      if (m_valid) begin
        req_write <= m_write;
        req_addr  <= m_addr;
        req_wdata <= m_wdata;
        req_wstrb <= m_wstrb;
      end
    end
  end

  // 从设备请求：在 req_valid 周期发出
  assign instr_req_valid = req_valid && (req_sel == SEL_INSTR);
  assign data_req_valid  = req_valid && (req_sel == SEL_DATA);
  assign weight_req_valid= req_valid && (req_sel == SEL_WEIGHT);
  assign reg_req_valid   = req_valid && (req_sel == SEL_REG);
  assign dma_req_valid   = req_valid && (req_sel == SEL_DMA);
  assign uart_req_valid  = req_valid && (req_sel == SEL_UART);
  assign spi_req_valid   = req_valid && (req_sel == SEL_SPI);
  assign fifo_req_valid  = req_valid && (req_sel == SEL_FIFO);

  assign instr_req_write = req_write;
  assign data_req_write  = req_write;
  assign weight_req_write= req_write;
  assign reg_req_write   = req_write;
  assign dma_req_write   = req_write;
  assign uart_req_write  = req_write;
  assign spi_req_write   = req_write;
  assign fifo_req_write  = req_write;

  // 传递地址与写数据（各模块自行解释 offset）
  assign instr_req_addr  = req_addr - ADDR_INSTR_BASE;
  assign data_req_addr   = req_addr - ADDR_DATA_BASE;
  assign weight_req_addr = req_addr - ADDR_WEIGHT_BASE;
  assign reg_req_addr    = req_addr - ADDR_REG_BASE;
  assign dma_req_addr    = req_addr - ADDR_DMA_BASE;
  assign uart_req_addr   = req_addr - ADDR_UART_BASE;
  assign spi_req_addr    = req_addr - ADDR_SPI_BASE;
  assign fifo_req_addr   = req_addr - ADDR_FIFO_BASE;

  assign instr_req_wdata = req_wdata;
  assign data_req_wdata  = req_wdata;
  assign weight_req_wdata= req_wdata;
  assign reg_req_wdata   = req_wdata;
  assign dma_req_wdata   = req_wdata;
  assign uart_req_wdata  = req_wdata;
  assign spi_req_wdata   = req_wdata;
  assign fifo_req_wdata  = req_wdata;

  assign instr_req_wstrb = req_wstrb;
  assign data_req_wstrb  = req_wstrb;
  assign weight_req_wstrb= req_wstrb;
  assign reg_req_wstrb   = req_wstrb;
  assign dma_req_wstrb   = req_wstrb;
  assign uart_req_wstrb  = req_wstrb;
  assign spi_req_wstrb   = req_wstrb;
  assign fifo_req_wstrb  = req_wstrb;

  // 读数据多路选择
  always_comb begin
    req_rdata = 32'h0;
    case (req_sel)
      SEL_INSTR:  req_rdata = instr_rdata;
      SEL_DATA:   req_rdata = data_rdata;
      SEL_WEIGHT: req_rdata = weight_rdata;
      SEL_REG:    req_rdata = reg_rdata;
      SEL_DMA:    req_rdata = dma_rdata;
      SEL_UART:   req_rdata = uart_rdata;
      SEL_SPI:    req_rdata = spi_rdata;
      SEL_FIFO:   req_rdata = fifo_rdata;
      default:    req_rdata = 32'h0;
    endcase
  end

  // 固定 1-cycle 响应
  assign m_ready  = req_valid && req_write;
  assign m_rvalid = req_valid && !req_write;
  assign m_rdata  = req_rdata;

  // 供 reg_bank 使用：在 rvalid 周期给出读返回脉冲与地址
  assign reg_resp_read_pulse = req_valid && !req_write && (req_sel == SEL_REG);
  assign reg_resp_addr       = req_addr;

endmodule
