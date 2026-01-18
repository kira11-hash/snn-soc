//======================================================================
// 文件名: sram_simple.sv
// 描述: 简化单端口 SRAM 模型。
//       - 写：同步写，支持 byte strobe
//       - 读：组合读（本工程总线固定 1-cycle 响应）
//       - 地址以 byte 为单位，内部按 32-bit word 寻址
//======================================================================
module sram_simple #(
  parameter int MEM_BYTES = 65536  // 例如 64KB
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        req_valid,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  output logic [31:0] rdata
);
  localparam int WORDS = MEM_BYTES / 4;
  localparam int ADDR_BITS = $clog2(WORDS);

  logic [31:0] mem [0:WORDS-1];

  wire [ADDR_BITS-1:0] word_addr = req_addr[ADDR_BITS+1:2];

  // 组合读：直接读当前地址
  assign rdata = mem[word_addr];

  // 同步写：按字节使能更新
  always_ff @(posedge clk) begin
    if (req_valid && req_write) begin
      if (req_wstrb[0]) mem[word_addr][7:0]   <= req_wdata[7:0];
      if (req_wstrb[1]) mem[word_addr][15:8]  <= req_wdata[15:8];
      if (req_wstrb[2]) mem[word_addr][23:16] <= req_wdata[23:16];
      if (req_wstrb[3]) mem[word_addr][31:24] <= req_wdata[31:24];
    end
  end
endmodule
