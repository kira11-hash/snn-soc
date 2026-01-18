//======================================================================
// 文件名: spi_stub.sv
// 描述: SPI Flash 外设 stub。
//       - 提供简单寄存器窗口，读写不报错
//       - 不产生真实 SPI 波形，仅作为占位
//======================================================================
module spi_stub (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        req_valid,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  output logic [31:0] rdata,

  output logic        spi_cs_n,
  output logic        spi_sck,
  output logic        spi_mosi,
  input  logic        spi_miso
);
  localparam logic [7:0] REG_CTRL   = 8'h00;
  localparam logic [7:0] REG_STATUS = 8'h04;
  localparam logic [7:0] REG_TXDATA = 8'h08;
  localparam logic [7:0] REG_RXDATA = 8'h0C;

  logic [31:0] ctrl_reg;
  logic [31:0] status_reg;
  logic [31:0] txdata_reg;

  wire [7:0] addr_offset = req_addr[7:0];
  wire write_en = req_valid && req_write;

  // stub 输出默认值
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl_reg   <= 32'h0;
      status_reg <= 32'h0;
      txdata_reg <= 32'h0;
    end else begin
      if (write_en) begin
        case (addr_offset)
          REG_CTRL:   ctrl_reg   <= req_wdata;
          REG_TXDATA: txdata_reg <= req_wdata;
          default: begin
          end
        endcase
      end
    end
  end

  // 输出端口固定为安全状态
  assign spi_cs_n = 1'b1;
  assign spi_sck  = 1'b0;
  assign spi_mosi = 1'b0;

  always_comb begin
    rdata = 32'h0;
    case (addr_offset)
      REG_CTRL:   rdata = ctrl_reg;
      REG_STATUS: rdata = status_reg;
      REG_TXDATA: rdata = txdata_reg;
      REG_RXDATA: rdata = 32'h0; // stub：无真实接收
      default:    rdata = 32'h0;
    endcase
  end
endmodule
