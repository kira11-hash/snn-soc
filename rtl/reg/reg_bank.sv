//======================================================================
// 文件名: reg_bank.sv
// 描述: SNN SoC 主寄存器 Bank。
//       - 地址基址：0x4000_0000
//       - 提供阈值、时步数、控制与状态寄存器
//       - CIM_CTRL.DONE 为 sticky，使用 W1C 清零
//       - CIM_CTRL.START/RESET 为 W1P，写 1 仅产生单拍脉冲
//======================================================================
module reg_bank (
  input  logic        clk,
  input  logic        rst_n,

  // 简化总线接口（地址为 offset）
  input  logic        req_valid,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  output logic [31:0] rdata,

  // 来自 SNN 子系统的状态输入
  input  logic        snn_busy,
  input  logic        snn_done_pulse,
  input  logic [7:0]  timestep_counter,

  // FIFO 状态
  input  logic        in_fifo_empty,
  input  logic        in_fifo_full,
  input  logic        out_fifo_empty,
  input  logic        out_fifo_full,
  input  logic [3:0]  out_fifo_rdata,
  input  logic [$clog2(256+1)-1:0] out_fifo_count,

  // 输出到 SNN 子系统
  output logic [15:0] neuron_threshold,
  output logic [7:0]  timesteps,
  output logic        reset_mode,
  output logic        start_pulse,
  output logic        soft_reset_pulse,

  // 输出 FIFO 弹出控制（在 rvalid 那拍）
  output logic        out_fifo_pop
);
  import snn_soc_pkg::*;

  // 寄存器 offset
  localparam logic [7:0] REG_THRESHOLD   = 8'h00;
  localparam logic [7:0] REG_TIMESTEPS   = 8'h04;
  localparam logic [7:0] REG_NUM_INPUTS  = 8'h08;
  localparam logic [7:0] REG_NUM_OUTPUTS = 8'h0C;
  localparam logic [7:0] REG_RESET_MODE  = 8'h10;
  localparam logic [7:0] REG_CIM_CTRL    = 8'h14;
  localparam logic [7:0] REG_STATUS      = 8'h18;
  localparam logic [7:0] REG_OUT_DATA    = 8'h1C;
  localparam logic [7:0] REG_OUT_COUNT   = 8'h20;

  logic done_sticky;
  logic pop_pending;

  wire [7:0] addr_offset = req_addr[7:0];
  wire write_en = req_valid && req_write;

  // 产生 W1P 脉冲（默认 0）
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      neuron_threshold <= 16'd200;
      timesteps        <= TIMESTEPS_DEFAULT[7:0];
      reset_mode       <= 1'b0;
      start_pulse      <= 1'b0;
      soft_reset_pulse <= 1'b0;
      done_sticky      <= 1'b0;
    end else begin
      start_pulse      <= 1'b0;
      soft_reset_pulse <= 1'b0;

      // sticky DONE
      if (snn_done_pulse) begin
        done_sticky <= 1'b1;
      end

      if (write_en) begin
        case (addr_offset)
          REG_THRESHOLD: begin
            if (req_wstrb[0]) neuron_threshold[7:0]  <= req_wdata[7:0];
            if (req_wstrb[1]) neuron_threshold[15:8] <= req_wdata[15:8];
          end
          REG_TIMESTEPS: begin
            if (req_wstrb[0]) timesteps <= req_wdata[7:0];
          end
          REG_RESET_MODE: begin
            if (req_wstrb[0]) reset_mode <= req_wdata[0];
          end
          REG_CIM_CTRL: begin
            // W1P: START / RESET
            if (req_wdata[0]) start_pulse <= 1'b1;
            if (req_wdata[1]) soft_reset_pulse <= 1'b1;
            // W1C: DONE
            if (req_wdata[7]) done_sticky <= 1'b0;
          end
          default: begin
            // 其他地址忽略
          end
        endcase
      end
    end
  end

  // OUT_FIFO_DATA 读出后下一拍弹出，避免同拍竞争
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pop_pending <= 1'b0;
      out_fifo_pop <= 1'b0;
    end else begin
      out_fifo_pop <= pop_pending;
      pop_pending <= (req_valid && !req_write && (addr_offset == REG_OUT_DATA) && !out_fifo_empty);
    end
  end

  // 状态寄存器组合逻辑
  always_comb begin
    rdata = 32'h0;
    case (addr_offset)
      REG_THRESHOLD:   rdata = {16'h0, neuron_threshold};
      REG_TIMESTEPS:   rdata = {24'h0, timesteps};
      REG_NUM_INPUTS:  rdata = {16'h0, NUM_INPUTS[15:0]};
      REG_NUM_OUTPUTS: rdata = {24'h0, NUM_OUTPUTS[7:0]};
      REG_RESET_MODE:  rdata = {31'h0, reset_mode};
      REG_CIM_CTRL: begin
        rdata = 32'h0;
        rdata[7] = done_sticky;
      end
      REG_STATUS: begin
        rdata[0]   = snn_busy;
        rdata[1]   = in_fifo_empty;
        rdata[2]   = in_fifo_full;
        rdata[3]   = out_fifo_empty;
        rdata[4]   = out_fifo_full;
        rdata[15:8]= timestep_counter;
      end
      REG_OUT_DATA: begin
        if (out_fifo_empty) begin
          rdata = 32'h0;
        end else begin
          rdata = {{(32-4){1'b0}}, out_fifo_rdata};
        end
      end
      REG_OUT_COUNT:  rdata = {16'h0, out_fifo_count};
      default:        rdata = 32'h0;
    endcase
  end
endmodule
