`timescale 1ns/1ps
//======================================================================
// 文件名: spi_ctrl.sv
// 模块名: spi_ctrl
//
// 【功能概述】
// SPI Master 控制器，Mode 0（CPOL=0, CPHA=0），8-bit 全双工传输。
// 用于连接外部 SPI Flash，固件通过此接口读取启动镜像和权重数据。
//
// 【寄存器映射（基地址 ADDR_SPI_BASE）】
// - 0x00 REG_CTRL:   [7:0]=clk_div（分频系数），[8]=CS 极性
// - 0x04 REG_STATUS:  [0]=busy，[1]=done
// - 0x08 REG_TXDATA:  [7:0]=待发送数据（写触发传输）
// - 0x0C REG_RXDATA:  [7:0]=接收数据（只读）
//
// 【总线接口】
// 与 spi_stub 保持兼容，可直接替换（drop-in replace）
//======================================================================
module spi_ctrl (
  input  logic        clk,              // 系统时钟（50MHz）
  input  logic        rst_n,            // 异步低有效复位

  // ── simple bus 接口（来自 bus_interconnect）────────────────────────
  input  logic        req_valid,         // 请求有效
  input  logic        req_write,         // 1=写，0=读
  input  logic [31:0] req_addr,          // 寄存器地址
  input  logic [31:0] req_wdata,         // 写数据
  input  logic [3:0]  req_wstrb,         // 字节写使能
  output logic [31:0] rdata,             // 读数据

  // ── SPI 物理引脚（连接外部 Flash）─────────────────────────────────
  output logic        spi_cs_n,          // 片选（低有效）
  output logic        spi_sck,           // 时钟（Mode 0: 空闲低）
  output logic        spi_mosi,          // 主出从入
  input  logic        spi_miso           // 主入从出
);
  // ── 寄存器 offset 定义 ────────────────────────────────────────────────
  localparam logic [7:0] REG_CTRL   = 8'h00;  // 控制寄存器（clk_div + CS 极性）
  localparam logic [7:0] REG_STATUS = 8'h04;  // 状态（busy + rx_valid）
  localparam logic [7:0] REG_TXDATA = 8'h08;  // 写触发发送，读回上次写值
  localparam logic [7:0] REG_RXDATA = 8'h0C;  // 接收数据（读后自动清 rx_valid）

  // ── FSM 状态编码 ──────────────────────────────────────────────────────
  localparam logic [1:0] ST_IDLE  = 2'd0;  // 空闲：等待 TXDATA 写入
  localparam logic [1:0] ST_SHIFT = 2'd1;  // 移位：逐位收发 8-bit 数据
  localparam logic [1:0] ST_DONE  = 2'd2;  // 完成：保持 1 拍后回到 IDLE

  // ── 内部寄存器 ────────────────────────────────────────────────────────
  logic [31:0] ctrl_reg;    // 控制寄存器（[0]=spi_en, [3:1]=clk_div_sel, [8]=cs_force）
  logic [7:0]  tx_shadow;   // TXDATA 影子寄存器（供读回）
  logic [7:0]  rx_shadow;   // RXDATA 影子寄存器（8-bit 接收结果锁存）

  logic [1:0]  state;       // 当前 FSM 状态
  logic [7:0]  div_cnt;     // SCK 分频倒计数器（0→div_limit 循环）
  logic [7:0]  div_limit;   // SCK 半周期计数上限（由 clk_div_sel 决定）
  logic [2:0]  bit_idx;     // 当前正在传输的数据位索引（0~7）
  logic [7:0]  tx_shift;    // 发送移位寄存器（MSB 先发）
  logic [7:0]  rx_shift;    // 接收移位寄存器（MSB 先入）
  logic        sck_int;     // 内部 SCK 信号（busy 时输出到 spi_sck）
  logic        mosi_int;    // 内部 MOSI 信号（busy 时输出到 spi_mosi）
  logic        busy;        // 传输忙标志
  logic        rx_valid;    // 接收数据有效标志（读 RXDATA 后自动清零）
  logic        last_bit_sampled;  // 第 8 位已采样标志（用于保持完整的最后一个 SCK 高半周期）

  // ── 辅助信号 ────────────────────────────────────────────────────────────
  wire write_en = req_valid && req_write;   // 总线写使能
  wire read_en  = req_valid && !req_write;  // 总线读使能
  wire [7:0] addr_offset = req_addr[7:0];   // 寄存器 offset（取低 8 位）
  wire spi_en = ctrl_reg[0];                // SPI 使能位（1=允许发送）
  wire [2:0] clk_div_sel = ctrl_reg[3:1];   // SCK 分频选择（3 位，对应 8 档频率）
  wire cs_force = ctrl_reg[8];              // CS 强制拉低（1=片选有效，0=片选无效）

  // 安全钳位：若软件写 CTRL 时 spi_en=1 但 clk_div=0（对应 /2 分频 = 25MHz SCK），
  // 自动钳位到 clk_div=2（/8 分频 = 6.25MHz SCK），避免超频驱动未验证的 Flash。
  wire [31:0] ctrl_write_data = (req_wdata[0] && (req_wdata[3:1] == 3'd0))
                              ? {req_wdata[31:4], 3'd2, req_wdata[0]}
                              : req_wdata;

  // V1 外设忽略字节写使能（按整字处理）
  wire _unused = &{1'b0, req_wstrb, req_addr[31:8]};
  wire _unused_shift_bits = &{1'b0, tx_shift[7], rx_shift[7]};

  // ── SCK 分频映射 ──────────────────────────────────────────────────────
  // clk_div_sel → div_limit → SCK 半周期 = (div_limit+1) 个 sys_clk
  // SCK 频率 = sys_clk / (2 × (div_limit+1))
  // 例：sys_clk=50MHz，clk_div_sel=2 → div_limit=3 → SCK = 50/8 = 6.25MHz
  always_comb begin
    case (clk_div_sel)
      3'd0: div_limit = 8'd0;    // /2  → 25.0 MHz（被安全钳位拦截，实际不会用到）
      3'd1: div_limit = 8'd1;    // /4  → 12.5 MHz
      3'd2: div_limit = 8'd3;    // /8  → 6.25 MHz（钳位默认档）
      3'd3: div_limit = 8'd7;    // /16 → 3.125 MHz
      3'd4: div_limit = 8'd15;   // /32 → 1.5625 MHz
      3'd5: div_limit = 8'd31;   // /64 → 781 kHz
      3'd6: div_limit = 8'd63;   // /128 → 391 kHz
      default: div_limit = 8'd127; // /256 → 195 kHz
    endcase
  end

  // ── 输出引脚驱动 ──────────────────────────────────────────────────────
  // CS 由软件直接控制（cs_force=1 拉低片选，cs_force=0 释放片选）
  // SCK 和 MOSI 仅在 busy 时输出有效信号，空闲时保持低电平
  assign spi_cs_n = cs_force ? 1'b0 : 1'b1;
  assign spi_sck  = busy ? sck_int  : 1'b0;
  assign spi_mosi = busy ? mosi_int : 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl_reg   <= 32'h0;
      tx_shadow  <= 8'h00;
      rx_shadow  <= 8'h00;
      state      <= ST_IDLE;
      div_cnt    <= 8'h00;
      bit_idx    <= 3'd0;
      tx_shift   <= 8'h00;
      rx_shift   <= 8'h00;
      sck_int    <= 1'b0;
      mosi_int   <= 1'b0;
      busy              <= 1'b0;
      rx_valid          <= 1'b0;
      last_bit_sampled  <= 1'b0;
    end else begin
      // ── 读 RXDATA 时自动消费 rx_valid ──────────────────────────────────
      // 防止软件重复读取同一字节（类似 FIFO pop 语义）
      if (read_en && (addr_offset == REG_RXDATA)) begin
        rx_valid <= 1'b0;
      end

      // ── CTRL 寄存器可随时写入 ──────────────────────────────────────────
      // 发送期间修改 clk_div 不影响当前帧（div_limit 在 ST_SHIFT 中实时生效）
      if (write_en && (addr_offset == REG_CTRL)) begin
        ctrl_reg <= ctrl_write_data;
      end

      case (state)
        //------------------------------------------------------------------
        // ST_IDLE：空闲等待
        // 写 TXDATA 且 spi_en=1 时启动一次 8-bit 全双工传输
        // MOSI 立即输出 MSB（tx_data[7]），准备第一个 SCK 上升沿
        //------------------------------------------------------------------
        ST_IDLE: begin
          busy    <= 1'b0;
          sck_int <= 1'b0;
          div_cnt <= 8'h00;

          if (write_en && (addr_offset == REG_TXDATA) && spi_en) begin
            tx_shadow <= req_wdata[7:0];   // 影子寄存器（供读回）
            tx_shift  <= req_wdata[7:0];   // 移位寄存器（发送数据源）
            rx_shift  <= 8'h00;            // 清空接收移位寄存器
            bit_idx   <= 3'd0;             // 位索引从 0 开始
            mosi_int  <= req_wdata[7];     // 先驱动 MSB（Mode 0：CPHA=0，SCK 上升沿前数据就绪）
            busy      <= 1'b1;
            rx_valid  <= 1'b0;             // 清除上次的接收有效标志
            state     <= ST_SHIFT;
          end
        end

        //------------------------------------------------------------------
        // ST_SHIFT：SPI Mode 0 逐位收发
        //
        // Mode 0 时序（CPOL=0, CPHA=0）：
        //   ┌─SCK 上升沿─┐: 采样 MISO（从机发来的数据）
        //   └─SCK 下降沿─┘: 更新 MOSI（准备下一位发送数据）
        //
        // div_cnt 从 0 计数到 div_limit，达到时翻转 SCK 并执行采样/更新。
        // 每个 SCK 半周期 = (div_limit+1) 个系统时钟。
        //
        // last_bit_sampled 机制：
        //   第 8 位（bit_idx=7）在 SCK 上升沿采样后，不立即结束，
        //   而是保持 SCK=1 一个完整半周期，然后在下降沿才转入 ST_DONE。
        //   这确保从机有足够的 SCK 高电平保持时间（t_hold）。
        //------------------------------------------------------------------
        ST_SHIFT: begin
          if (div_cnt == div_limit) begin
            div_cnt <= 8'h00;  // 半周期计满，重新开始计数

            if (sck_int == 1'b0) begin
              // ── SCK 上升沿：采样 MISO ──────────────────────────────────
              sck_int <= 1'b1;
              if (bit_idx == 3'd7) begin
                // 第 8 位（最后一位）：锁存完整接收字节到 rx_shadow
                rx_shadow        <= {rx_shift[6:0], spi_miso};
                rx_valid         <= 1'b1;   // 标记接收数据有效
                last_bit_sampled <= 1'b1;   // 标记：还需一个 SCK 高半周期
              end else begin
                // 非最后一位：移入接收移位寄存器，推进位索引
                rx_shift <= {rx_shift[6:0], spi_miso};
                bit_idx  <= bit_idx + 3'd1;
              end
            end else begin
              // ── SCK 下降沿：更新 MOSI 或结束传输 ──────────────────────
              if (last_bit_sampled) begin
                // 最后一位的 SCK 高半周期已保持完毕，拉低 SCK，进入 DONE
                sck_int          <= 1'b0;
                last_bit_sampled <= 1'b0;
                state            <= ST_DONE;
              end else begin
                // 正常位：拉低 SCK，左移 tx_shift，驱动下一位 MOSI
                sck_int  <= 1'b0;
                tx_shift <= {tx_shift[6:0], 1'b0};  // 左移，低位填 0
                mosi_int <= tx_shift[6];  // 下一位数据（移位前的 bit[6] = 移位后的 MSB）
              end
            end
          end else begin
            div_cnt <= div_cnt + 8'd1;  // 半周期未满，继续计数
          end
        end

        //------------------------------------------------------------------
        // ST_DONE：传输完成，保持 1 拍后回到 IDLE
        // 这个额外 1 拍确保 SCK 低电平至少持续 1 个系统时钟
        //------------------------------------------------------------------
        ST_DONE: begin
          sck_int <= 1'b0;
          busy    <= 1'b0;
          state   <= ST_IDLE;
        end

        default: begin
          state <= ST_IDLE;
        end
      endcase
    end
  end

  // ── 读数据多路选择（纯组合逻辑）────────────────────────────────────────
  always_comb begin
    rdata = 32'h0;
    case (addr_offset)
      REG_CTRL:   rdata = ctrl_reg;                   // 读回控制寄存器全字
      REG_STATUS: rdata = {30'h0, rx_valid, busy};    // [0]=busy, [1]=rx_valid
      REG_TXDATA: rdata = {24'h0, tx_shadow};         // 影子寄存器读回（非移位寄存器）
      REG_RXDATA: rdata = {24'h0, rx_shadow};         // 接收数据（读后 rx_valid 自动清零）
      default:    rdata = 32'h0;
    endcase
  end
endmodule
