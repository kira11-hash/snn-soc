`timescale 1ns/1ps
//======================================================================
// 文件名: rtl/periph/uart_ctrl.sv
// 模块名: uart_ctrl
//
// 【功能概述】
// UART TX 控制器（V1 最小可用实现）。
// 实现标准 8N1 帧格式（1 起始位 + 8 数据位 LSB 优先 + 1 停止位），
// 波特率通过 CTRL 寄存器的 baud_div 字段配置。
// RX 路径在 V1 不实现（占位，读回 0）。
//
// 【寄存器映射】（offset 相对于 UART 基地址 0x4000_0200）
//   0x00: TXDATA [7:0] - 写触发发送（忙时写入忽略）；读回上次写值
//   0x04: STATUS [0]=tx_busy - 1=正在发送，0=空闲
//   0x08: CTRL   [15:0]=baud_div - 波特率分频值（默认868=100MHz/115200）
//   0x0C: RXDATA [7:0] - 占位，读返回 0
//
// 【时序说明】
//   baud_div 为每个 baud 周期的时钟数 - 1（即分频系数减1存入）。
//   例：clk=100MHz，baud=115200 → baud_div_reg=868，每 bit = 868+1 个时钟周期。
//   但为编程简便，CTRL 写入的是原始分频系数（868），内部减 1 使用。
//
// 【TX 状态机（8N1 时序）】
//   ST_IDLE  : uart_tx=1（空闲高），等待 TXDATA 写入
//   ST_START : uart_tx=0（起始位），持续 baud_div 个时钟周期
//   ST_DATA  : uart_tx=tx_shift[0]（数据位 D0~D7），每位 baud_div 个周期
//   ST_STOP  : uart_tx=1（停止位），持续 baud_div 个时钟周期，完成后回 IDLE
//
// 【接口与 uart_stub 完全兼容】
//   替换 uart_stub 时，仅需将顶层实例名从 uart_stub 改为 uart_ctrl，端口不变。
//======================================================================

module uart_ctrl (
  // ── 时钟和复位 ────────────────────────────────────────────────────────────
  input  logic        clk,        // 系统时钟
  input  logic        rst_n,      // 异步低有效复位

  // ── 总线接口（bus_simple slave，来自 bus_interconnect）────────────────────
  input  logic        req_valid,  // 请求有效脉冲
  input  logic        req_write,  // 1=写，0=读
  input  logic [31:0] req_addr,   // 字节地址（低4位用作寄存器 offset）
  input  logic [31:0] req_wdata,  // 写数据（32位，实际使用 [7:0] 或 [15:0]）
  input  logic [3:0]  req_wstrb,  // 字节写使能（V1 忽略，按整字处理）
  output logic [31:0] rdata,      // 读返回数据（组合输出）

  // ── UART 物理接口 ─────────────────────────────────────────────────────────
  input  logic        uart_rx,    // RX 线（V1 未实现接收，占位）
  output logic        uart_tx     // TX 线（空闲高电平 = Mark 状态）
);

  // ── 寄存器 offset 定义 ────────────────────────────────────────────────────
  localparam logic [3:0] REG_TXDATA = 4'h0;  // 发送数据
  localparam logic [3:0] REG_STATUS = 4'h4;  // 状态（tx_busy）
  localparam logic [3:0] REG_CTRL   = 4'h8;  // 控制（baud_div）
  localparam logic [3:0] REG_RXDATA = 4'hC;  // 接收数据（占位）

  // 100MHz 时钟 / 115200 baud ≈ 868 个时钟周期
  localparam logic [15:0] BAUD_DIV_DEFAULT = 16'd868;

  // ── 内部寄存器 ────────────────────────────────────────────────────────────
  logic [7:0]  txdata_shadow;   // TXDATA 影子寄存器（供读回，不参与发送移位）
  logic [15:0] baud_div_reg;    // 每个 baud 周期的时钟数（默认868）

  // ── TX FSM ────────────────────────────────────────────────────────────────
  // 状态编码
  localparam logic [1:0] ST_IDLE  = 2'd0;
  localparam logic [1:0] ST_START = 2'd1;
  localparam logic [1:0] ST_DATA  = 2'd2;
  localparam logic [1:0] ST_STOP  = 2'd3;

  logic [1:0]  tx_state;
  logic [15:0] baud_cnt;   // 当前 bit 剩余时钟计数（倒计数，到 0 表示本 bit 结束）
  logic [2:0]  bit_cnt;    // 已发数据位数（0~7）
  logic [7:0]  tx_shift;   // 发送移位寄存器（LSB 先发）
  logic        tx_busy;    // 发送忙标志（高=正在发送）

  // ── 辅助信号 ──────────────────────────────────────────────────────────────
  wire [3:0]  addr_off  = req_addr[3:0];   // 低4位作为寄存器 offset
  wire        write_en  = req_valid && req_write;
  wire        baud_last = (baud_cnt == 16'd0); // 当前 baud 周期最后一拍

  // ── 寄存器写逻辑 ──────────────────────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      txdata_shadow <= 8'h0;
      baud_div_reg  <= BAUD_DIV_DEFAULT;
    end else begin
      if (write_en) begin
        case (addr_off)
          // TXDATA：忙时写入忽略（由 TX FSM 单独处理 tx_shift 的加载）
          REG_TXDATA: if (!tx_busy) txdata_shadow <= req_wdata[7:0];
          // CTRL：任何时候均可更新波特率（下次发送生效）
          REG_CTRL:   baud_div_reg <= req_wdata[15:0];
          default: ;
        endcase
      end
    end
  end

  // ── TX FSM（状态、计数器、移位寄存器）────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_state  <= ST_IDLE;
      baud_cnt  <= 16'd0;
      bit_cnt   <= 3'd0;
      tx_shift  <= 8'hFF;
      tx_busy   <= 1'b0;
    end else begin
      case (tx_state)

        //--------------------------------------------------------------------
        // ST_IDLE：等待 TXDATA 写入
        // 写操作和 tx_busy=0 同时满足时，加载数据、启动发送计时、进入起始位
        //--------------------------------------------------------------------
        ST_IDLE: begin
          if (write_en && (addr_off == REG_TXDATA) && !tx_busy) begin
            tx_shift <= req_wdata[7:0];     // 加载发送字节
            baud_cnt <= baud_div_reg - 1;   // 从 baud_div-1 开始倒数
            tx_busy  <= 1'b1;
            tx_state <= ST_START;
          end
        end

        //--------------------------------------------------------------------
        // ST_START：发送起始位（uart_tx=0），持续 baud_div 个时钟周期
        //--------------------------------------------------------------------
        ST_START: begin
          if (baud_last) begin
            baud_cnt <= baud_div_reg - 1;
            bit_cnt  <= 3'd0;
            tx_state <= ST_DATA;
          end else begin
            baud_cnt <= baud_cnt - 1;
          end
        end

        //--------------------------------------------------------------------
        // ST_DATA：逐位发送 D0~D7（LSB 先发），每位 baud_div 个时钟周期
        //--------------------------------------------------------------------
        ST_DATA: begin
          if (baud_last) begin
            tx_shift <= (tx_shift >> 1);           // 逻辑右移，MSB填0，准备下一位
            if (bit_cnt == 3'd7) begin
              // 8 bit 发完，进入停止位
              baud_cnt <= baud_div_reg - 1;
              tx_state <= ST_STOP;
            end else begin
              baud_cnt <= baud_div_reg - 1;
              bit_cnt  <= bit_cnt + 1;
            end
          end else begin
            baud_cnt <= baud_cnt - 1;
          end
        end

        //--------------------------------------------------------------------
        // ST_STOP：发送停止位（uart_tx=1），持续 baud_div 个时钟周期
        //--------------------------------------------------------------------
        ST_STOP: begin
          if (baud_last) begin
            tx_state <= ST_IDLE;
            tx_busy  <= 1'b0;
          end else begin
            baud_cnt <= baud_cnt - 1;
          end
        end

        default: tx_state <= ST_IDLE;
      endcase
    end
  end

  // ── UART TX 输出（连续赋值，避免 Icarus always 块内常量位选限制）────────
  // Icarus 不支持 always_* 内的常量位选（如 tx_shift[0]），改用 assign。
  // tx_shift[0]：LSB，数据位 D0~D7 依次从 LSB 输出，逻辑正确。
  wire tx_data_bit;
  assign tx_data_bit = tx_shift[0];   // 抽出到 wire，Icarus 允许 assign 内位选
  assign uart_tx = (tx_state == ST_START) ? 1'b0          :  // 起始位：低
                   (tx_state == ST_DATA)  ? tx_data_bit   :  // 数据位：LSB
                   1'b1;                                      // IDLE/STOP：高

  // ── 读数据多路选择（组合逻辑）────────────────────────────────────────────
  always_comb begin
    rdata = 32'h0;
    case (addr_off)
      REG_TXDATA: rdata = {24'h0, txdata_shadow};          // 影子寄存器读回
      REG_STATUS: rdata = {31'h0, tx_busy};                // [0]=tx_busy
      REG_CTRL:   rdata = {16'h0, baud_div_reg};           // [15:0]=baud_div
      REG_RXDATA: rdata = 32'h0;                           // RX 占位，返回0
      default:    rdata = 32'h0;
    endcase
  end

  // ── 哑线：抑制未使用信号 lint 告警 ───────────────────────────────────────
  wire _unused = &{1'b0, uart_rx, req_wstrb, req_addr[31:4]};

endmodule
