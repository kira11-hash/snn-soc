//======================================================================
// 文件名: fifo_sync.sv
// 描述: 同步 FIFO（单写单读）。
//       - push/pop 同步到 clk
//       - 提供 empty/full/count
//       - 当满时 push 丢弃并置 overflow
//       - 当空时 pop 不动作并置 underflow
//======================================================================
module fifo_sync #(
  parameter int WIDTH = 8,
  parameter int DEPTH = 16
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             push,
  input  logic [WIDTH-1:0] push_data,
  input  logic             pop,
  output logic [WIDTH-1:0] rd_data,
  output logic             empty,
  output logic             full,
  output logic [$clog2(DEPTH+1)-1:0] count,
  output logic             overflow,
  output logic             underflow
);
  localparam int ADDR_BITS = $clog2(DEPTH);

  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [ADDR_BITS-1:0] rd_ptr;
  logic [ADDR_BITS-1:0] wr_ptr;

  wire push_fire = push && !full;
  wire pop_fire  = pop && !empty;

  assign empty = (count == 0);
  assign full  = (count == DEPTH);
  assign rd_data = mem[rd_ptr];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_ptr   <= '0;
      wr_ptr   <= '0;
      count    <= '0;
      overflow <= 1'b0;
      underflow<= 1'b0;
    end else begin
      overflow  <= push && full;
      underflow <= pop && empty;

      if (push_fire) begin
        mem[wr_ptr] <= push_data;
        wr_ptr <= wr_ptr + 1'b1;
      end
      if (pop_fire) begin
        rd_ptr <= rd_ptr + 1'b1;
      end

      case ({push_fire, pop_fire})
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: count <= count;
      endcase
    end
  end
endmodule
