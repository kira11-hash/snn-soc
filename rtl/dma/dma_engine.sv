//======================================================================
// 文件名: dma_engine.sv
// 描述: 最小 DMA 引擎：data_sram -> input_fifo。
//       - DMA_SRC_ADDR  指向 data_sram 源地址（byte 地址）
//       - DMA_LEN_WORDS 以 32-bit word 计数，必须为偶数
//       - DMA_CTRL: bit0 START(W1P), bit1 DONE(W1C), bit2 ERR(W1C)
//       - 每 2 个 word 拼成 1 个 49-bit wl_bitmap
//======================================================================
module dma_engine (
  input  logic        clk,
  input  logic        rst_n,

  // 简化总线接口（地址为 offset）
  input  logic        req_valid,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  output logic [31:0] rdata,

  // data_sram 只读 DMA 端口
  output logic        dma_rd_en,
  output logic [31:0] dma_rd_addr,
  input  logic [31:0] dma_rd_data,

  // input_fifo 写端口
  output logic        in_fifo_push,
  output logic [48:0] in_fifo_wdata,
  input  logic        in_fifo_full
);
  import snn_soc_pkg::*;

  localparam logic [7:0] REG_SRC_ADDR = 8'h00;
  localparam logic [7:0] REG_LEN_WORDS= 8'h04;
  localparam logic [7:0] REG_DMA_CTRL = 8'h08;

  typedef enum logic [2:0] {
    ST_IDLE  = 3'd0,
    ST_SETUP = 3'd1,
    ST_RD0   = 3'd2,
    ST_RD1   = 3'd3,
    ST_PUSH  = 3'd4
  } dma_state_t;

  dma_state_t state;

  logic [31:0] src_addr_reg;
  logic [31:0] len_words_reg;
  logic [31:0] addr_ptr;
  logic [31:0] words_rem;
  logic [31:0] word0_reg;
  logic [31:0] word1_reg;

  logic done_sticky;
  logic err_sticky;

  wire [7:0] addr_offset = req_addr[7:0];
  wire write_en = req_valid && req_write;

  // 写寄存器（地址与长度）
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      src_addr_reg <= 32'h0;
      len_words_reg<= 32'h0;
    end else begin
      if (write_en) begin
        case (addr_offset)
          REG_SRC_ADDR: begin
            if (req_wstrb[0]) src_addr_reg[7:0]   <= req_wdata[7:0];
            if (req_wstrb[1]) src_addr_reg[15:8]  <= req_wdata[15:8];
            if (req_wstrb[2]) src_addr_reg[23:16] <= req_wdata[23:16];
            if (req_wstrb[3]) src_addr_reg[31:24] <= req_wdata[31:24];
          end
          REG_LEN_WORDS: begin
            if (req_wstrb[0]) len_words_reg[7:0]   <= req_wdata[7:0];
            if (req_wstrb[1]) len_words_reg[15:8]  <= req_wdata[15:8];
            if (req_wstrb[2]) len_words_reg[23:16] <= req_wdata[23:16];
            if (req_wstrb[3]) len_words_reg[31:24] <= req_wdata[31:24];
          end
          default: begin
          end
        endcase
      end
    end
  end

  // DMA 状态机
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= ST_IDLE;
      addr_ptr    <= 32'h0;
      words_rem   <= 32'h0;
      word0_reg   <= 32'h0;
      word1_reg   <= 32'h0;
      dma_rd_addr <= 32'h0;
      done_sticky <= 1'b0;
      err_sticky  <= 1'b0;
    end else begin
      // W1C 清零
      if (write_en && (addr_offset == REG_DMA_CTRL)) begin
        if (req_wdata[1]) done_sticky <= 1'b0;
        if (req_wdata[2]) err_sticky  <= 1'b0;
      end

      case (state)
        ST_IDLE: begin
          if (write_en && (addr_offset == REG_DMA_CTRL) && req_wdata[0]) begin
            // START W1P
            if (len_words_reg[0]) begin
              // 长度为奇数 -> 报错，不启动
              err_sticky  <= 1'b1;
              done_sticky <= 1'b1;
              state       <= ST_IDLE;
            end else if (len_words_reg == 0) begin
              // 长度为 0 -> 直接 done
              done_sticky <= 1'b1;
              state       <= ST_IDLE;
            end else begin
              // 正常启动
              done_sticky <= 1'b0;
              err_sticky  <= 1'b0;
              addr_ptr    <= src_addr_reg;
              words_rem   <= len_words_reg;
              state       <= ST_SETUP;
            end
          end
        end

        ST_SETUP: begin
          // 空等 1 拍，确保 addr_ptr 稳定
          state <= ST_RD0;
        end

        ST_RD0: begin
          // 读 word0
          word0_reg   <= dma_rd_data;
          addr_ptr    <= addr_ptr + 32'd4;
          state       <= ST_RD1;
        end

        ST_RD1: begin
          // 读 word1
          word1_reg   <= dma_rd_data;
          addr_ptr    <= addr_ptr + 32'd4;
          state       <= ST_PUSH;
        end

        ST_PUSH: begin
          if (!in_fifo_full) begin
            // push 一个 49-bit wl_bitmap
            words_rem <= words_rem - 32'd2;
            if (words_rem == 32'd2) begin
              done_sticky <= 1'b1;
              state       <= ST_IDLE;
            end else begin
              state       <= ST_RD0;
            end
          end
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

  // DMA 读端口控制
  always_comb begin
    dma_rd_en   = 1'b0;
    dma_rd_addr = addr_ptr;
    case (state)
      ST_RD0, ST_RD1: begin
        dma_rd_en   = 1'b1;
        dma_rd_addr = addr_ptr;
      end
      default: begin
        dma_rd_en   = 1'b0;
      end
    endcase
  end

  // FIFO push 数据拼接
  always_comb begin
    in_fifo_push = 1'b0;
    in_fifo_wdata= 49'h0;
    if (state == ST_PUSH && !in_fifo_full) begin
      in_fifo_push  = 1'b1;
      in_fifo_wdata = {word1_reg[16:0], word0_reg};
    end
  end

  // DMA_CTRL 读回
  always_comb begin
    rdata = 32'h0;
    case (addr_offset)
      REG_SRC_ADDR:  rdata = src_addr_reg;
      REG_LEN_WORDS: rdata = len_words_reg;
      REG_DMA_CTRL: begin
        rdata[1] = done_sticky;
        rdata[2] = err_sticky;
        rdata[3] = (state != ST_IDLE); // busy
      end
      default: rdata = 32'h0;
    endcase
  end
endmodule
