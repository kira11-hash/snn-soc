//======================================================================
// 文件名: uart_stub.sv
// 描述: UART 外设 stub。
//       - 提供简单寄存器窗口，读写不报错
//       - 不产生真实串口协议，仅作为占位
//======================================================================
module uart_stub (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        req_valid,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  output logic [31:0] rdata,

  input  logic        uart_rx,
  output logic        uart_tx
);
  localparam logic [7:0] REG_TXDATA = 8'h00;
  localparam logic [7:0] REG_RXDATA = 8'h04;
  localparam logic [7:0] REG_STATUS = 8'h08;
  localparam logic [7:0] REG_CTRL   = 8'h0C;

  logic [31:0] txdata_reg;
  logic [31:0] ctrl_reg;
  logic [31:0] status_reg;

  wire [7:0] addr_offset = req_addr[7:0];
  wire write_en = req_valid && req_write;

  assign uart_tx = 1'b1; // 空闲高电平

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      txdata_reg <= 32'h0;
      ctrl_reg   <= 32'h0;
      status_reg <= 32'h0;
    end else begin
      if (write_en) begin
        case (addr_offset)
          REG_TXDATA: txdata_reg <= req_wdata;
          REG_CTRL:   ctrl_reg   <= req_wdata;
          default: begin
          end
        endcase
      end
    end
  end

  always_comb begin
    rdata = 32'h0;
    case (addr_offset)
      REG_TXDATA: rdata = txdata_reg;
      REG_RXDATA: rdata = 32'h0;      // stub：无真实接收
      REG_STATUS: rdata = status_reg;
      REG_CTRL:   rdata = ctrl_reg;
      default:    rdata = 32'h0;
    endcase
  end
endmodule
