`timescale 1ns/1ps

module icb2simple_bridge #(
  // ENABLE_BOOT_ROM=1（chip_top tape-out 路径）：INSTR 实际范围 0x1000..0x4FFF
  // ENABLE_BOOT_ROM=0（默认 / Gate A 回归）：INSTR 实际范围 0x0..0x3FFF
  // 桥侧据此动态选择 is_sram_addr 上界，确保 OOB 访问立刻被本桥 reject 为
  // cmd_illegal（i_icb_rsp_err=1），而不是被 bus_interconnect 静默返回 rdata=0。
  parameter bit ENABLE_BOOT_ROM = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        i_icb_cmd_valid,
  output logic        i_icb_cmd_ready,
  input  logic [31:0] i_icb_cmd_addr,
  input  logic        i_icb_cmd_read,
  input  logic [31:0] i_icb_cmd_wdata,
  input  logic [3:0]  i_icb_cmd_wmask,
  output logic        i_icb_rsp_valid,
  input  logic        i_icb_rsp_ready,
  output logic        i_icb_rsp_err,
  output logic [31:0] i_icb_rsp_rdata,

  output logic        m_valid,
  output logic        m_write,
  output logic [31:0] m_addr,
  output logic [31:0] m_wdata,
  output logic [3:0]  m_wstrb,
  input  logic        m_ready,
  input  logic [31:0] m_rdata,
  input  logic        m_rvalid,
  output logic        busy_o
);
  import snn_soc_pkg::*;

  typedef enum logic [1:0] {
    ST_IDLE = 2'd0,
    ST_WAIT = 2'd1,
    ST_RSP  = 2'd2
  } state_t;

  state_t      state_q;
  logic        pending_read_q;
  logic        rsp_err_q;
  logic [31:0] rsp_rdata_q;

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic in_range(
    input logic [31:0] addr,
    input logic [31:0] base,
    input logic [31:0] last
  );
    in_range = (addr >= base) && (addr <= last);
  endfunction

  // INSTR 上界跟随 ENABLE_BOOT_ROM：
  //   - ENABLE_BOOT_ROM=0: ADDR_INSTR_BASE..ADDR_INSTR_END         (0x0..0x3FFF)
  //   - ENABLE_BOOT_ROM=1: ADDR_INSTR_BASE..ADDR_INSTR_END_WITH_ROM (0x0..0x4FFF;
  //     涵盖 boot ROM 0x0..0xFFF + 平移后的 INSTR_SRAM 0x1000..0x4FFF)
  // 这样 OOB 访问（如 ENABLE_BOOT_ROM=0 时访问 0x4000）会被本桥 reject 为
  // cmd_illegal → i_icb_rsp_err=1，而不是被 bus_interconnect 静默回 0。
  localparam logic [31:0] INSTR_END_EFFECTIVE =
      ENABLE_BOOT_ROM ? ADDR_INSTR_END_WITH_ROM : ADDR_INSTR_END;

  function automatic logic is_sram_addr(input logic [31:0] addr);
    is_sram_addr =
        in_range(addr, ADDR_INSTR_BASE,  INSTR_END_EFFECTIVE) ||
        in_range(addr, ADDR_DATA_BASE,   ADDR_DATA_END)       ||
        in_range(addr, ADDR_WEIGHT_BASE, ADDR_WEIGHT_END);
  endfunction

  function automatic logic is_mmio_addr(input logic [31:0] addr);
    is_mmio_addr =
        in_range(addr, ADDR_REG_BASE,  ADDR_REG_END)  ||
        in_range(addr, ADDR_DMA_BASE,  ADDR_DMA_END)  ||
        in_range(addr, ADDR_UART_BASE, ADDR_UART_END) ||
        in_range(addr, ADDR_SPI_BASE,  ADDR_SPI_END)  ||
        in_range(addr, ADDR_FIFO_BASE, ADDR_FIFO_END);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  wire cmd_is_sram  = is_sram_addr(i_icb_cmd_addr);
  wire cmd_is_mmio  = is_mmio_addr(i_icb_cmd_addr);
  wire cmd_mapped   = cmd_is_sram || cmd_is_mmio;
  wire cmd_aligned  = (i_icb_cmd_addr[1:0] == 2'b00);
  wire cmd_illegal  = !cmd_mapped || (cmd_is_mmio && !cmd_aligned);
  wire cmd_fire     = i_icb_cmd_valid && i_icb_cmd_ready;
  wire bus_rsp_fire = pending_read_q ? m_rvalid : m_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q        <= ST_IDLE;
      pending_read_q <= 1'b0;
      rsp_err_q      <= 1'b0;
      rsp_rdata_q    <= 32'h0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (cmd_fire) begin
            rsp_rdata_q <= 32'h0;
            if (cmd_illegal) begin
              rsp_err_q      <= 1'b1;
              pending_read_q <= 1'b0;
              state_q        <= ST_RSP;
            end else begin
              rsp_err_q      <= 1'b0;
              pending_read_q <= i_icb_cmd_read;
              state_q        <= ST_WAIT;
            end
          end
        end
        ST_WAIT: begin
          if (bus_rsp_fire) begin
            rsp_err_q   <= 1'b0;
            rsp_rdata_q <= pending_read_q ? m_rdata : 32'h0;
            state_q     <= ST_RSP;
          end
        end
        ST_RSP: begin
          if (i_icb_rsp_ready) begin
            state_q <= ST_IDLE;
          end
        end
        default: begin
          state_q <= ST_IDLE;
        end
      endcase
    end
  end

  always_comb begin
    i_icb_cmd_ready = (state_q == ST_IDLE);
    i_icb_rsp_valid = (state_q == ST_RSP);
    i_icb_rsp_err   = rsp_err_q;
    i_icb_rsp_rdata = rsp_rdata_q;
    busy_o          = rst_n && (state_q != ST_IDLE);

    m_valid = (state_q == ST_IDLE) && i_icb_cmd_valid && !cmd_illegal;
    m_write = !i_icb_cmd_read;
    m_addr  = i_icb_cmd_addr;
    m_wdata = i_icb_cmd_wdata;
    m_wstrb = i_icb_cmd_wmask;
  end
endmodule
