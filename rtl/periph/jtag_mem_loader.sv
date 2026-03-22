`timescale 1ns/1ps

module jtag_mem_loader (
  input  logic        rst_n,
  input  logic        clk,

  input  logic        jtag_tck,
  input  logic        jtag_tms,
  input  logic        jtag_tdi,
  output logic        jtag_tdo,

  output logic        mem_req_pending,
  input  logic        mem_req_grant,
  output logic        mem_m_valid,
  output logic        mem_m_write,
  output logic [31:0] mem_m_addr,
  output logic [3:0]  mem_m_wstrb,
  output logic [31:0] mem_m_wdata,
  input  logic        mem_m_ready,
  input  logic        mem_m_rvalid,
  input  logic [31:0] mem_m_rdata,

  output logic        cpu_reset_hold
);
  import snn_soc_pkg::*;

  localparam logic [3:0] IR_IDCODE = 4'h1;
  localparam logic [3:0] IR_MEMACC = 4'h2;
  localparam logic [3:0] IR_CPUCTL = 4'h3;
  localparam logic [3:0] IR_BYPASS = 4'hF;

  localparam logic [31:0] IDCODE_VALUE = 32'hE203_0001;

  localparam int IR_WIDTH        = 4;
  localparam int IDCODE_DR_WIDTH = 32;
  localparam int MEMACC_DR_WIDTH = 69;
  localparam int CPUCTL_DR_WIDTH = 2;
  localparam int DR_WIDTH_MAX    = MEMACC_DR_WIDTH;

  typedef enum logic [3:0] {
    TAP_TLR     = 4'd0,
    TAP_RTI     = 4'd1,
    TAP_SEL_DR  = 4'd2,
    TAP_CAP_DR  = 4'd3,
    TAP_SHIFT_DR= 4'd4,
    TAP_EXIT1_DR= 4'd5,
    TAP_PAUSE_DR= 4'd6,
    TAP_EXIT2_DR= 4'd7,
    TAP_UPD_DR  = 4'd8,
    TAP_SEL_IR  = 4'd9,
    TAP_CAP_IR  = 4'd10,
    TAP_SHIFT_IR= 4'd11,
    TAP_EXIT1_IR= 4'd12,
    TAP_PAUSE_IR= 4'd13,
    TAP_EXIT2_IR= 4'd14,
    TAP_UPD_IR  = 4'd15
  } tap_state_t;

  typedef enum logic [1:0] {
    CLK_IDLE       = 2'd0,
    CLK_WAIT_GRANT = 2'd1,
    CLK_ISSUE      = 2'd2,
    CLK_WAIT_RSP   = 2'd3
  } clk_state_t;

  tap_state_t tap_state_q;
  logic [IR_WIDTH-1:0] ir_q;
  logic [IR_WIDTH-1:0] ir_shift_q;
  logic [DR_WIDTH_MAX-1:0] dr_shift_q;

  logic        mem_req_write_tck;
  logic [31:0] mem_req_addr_tck;
  logic [3:0]  mem_req_wstrb_tck;
  logic [31:0] mem_req_wdata_tck;
  logic        mem_req_outstanding_tck;
  logic        req_toggle_tck;

  logic        cpuctl_hold_tck;
  logic        cpuctl_toggle_tck;

  (* async_reg = "TRUE" *) logic        rsp_toggle_meta_tck;
  (* async_reg = "TRUE" *) logic        rsp_toggle_sync_tck;
  logic        rsp_toggle_seen_tck;

  logic [31:0] mem_rsp_rdata_tck;
  logic        mem_rsp_err_tck;
  logic        mem_rsp_done_tck;

  (* async_reg = "TRUE" *) logic        req_toggle_meta_clk;
  (* async_reg = "TRUE" *) logic        req_toggle_sync_clk;
  logic        req_toggle_seen_clk;

  (* async_reg = "TRUE" *) logic        cpuctl_toggle_meta_clk;
  (* async_reg = "TRUE" *) logic        cpuctl_toggle_sync_clk;
  logic        cpuctl_toggle_seen_clk;

  logic [31:0] mem_rsp_rdata_clk;
  logic        mem_rsp_err_clk;
  logic        mem_rsp_done_clk;
  logic        rsp_toggle_clk;

  logic        mem_req_write_clk;
  logic [31:0] mem_req_addr_clk;
  logic [3:0]  mem_req_wstrb_clk;
  logic [31:0] mem_req_wdata_clk;
  clk_state_t  clk_state_q;

  // CLK-side bus timeout: if bus hangs (no grant or no response) for 1023 cycles,
  // force error+done so the rescue module itself doesn't get permanently stuck.
  localparam int CLK_TIMEOUT_MAX = 1023;
  logic [9:0] clk_timeout_cnt;

  function automatic tap_state_t tap_next(
    input tap_state_t cur,
    input logic       tms
  );
    case (cur)
      TAP_TLR:      if (tms) tap_next = TAP_TLR;      else tap_next = TAP_RTI;
      TAP_RTI:      if (tms) tap_next = TAP_SEL_DR;   else tap_next = TAP_RTI;
      TAP_SEL_DR:   if (tms) tap_next = TAP_SEL_IR;   else tap_next = TAP_CAP_DR;
      TAP_CAP_DR:   if (tms) tap_next = TAP_EXIT1_DR; else tap_next = TAP_SHIFT_DR;
      TAP_SHIFT_DR: if (tms) tap_next = TAP_EXIT1_DR; else tap_next = TAP_SHIFT_DR;
      TAP_EXIT1_DR: if (tms) tap_next = TAP_UPD_DR;   else tap_next = TAP_PAUSE_DR;
      TAP_PAUSE_DR: if (tms) tap_next = TAP_EXIT2_DR; else tap_next = TAP_PAUSE_DR;
      TAP_EXIT2_DR: if (tms) tap_next = TAP_UPD_DR;   else tap_next = TAP_SHIFT_DR;
      TAP_UPD_DR:   if (tms) tap_next = TAP_SEL_DR;   else tap_next = TAP_RTI;
      TAP_SEL_IR:   if (tms) tap_next = TAP_TLR;      else tap_next = TAP_CAP_IR;
      TAP_CAP_IR:   if (tms) tap_next = TAP_EXIT1_IR; else tap_next = TAP_SHIFT_IR;
      TAP_SHIFT_IR: if (tms) tap_next = TAP_EXIT1_IR; else tap_next = TAP_SHIFT_IR;
      TAP_EXIT1_IR: if (tms) tap_next = TAP_UPD_IR;   else tap_next = TAP_PAUSE_IR;
      TAP_PAUSE_IR: if (tms) tap_next = TAP_EXIT2_IR; else tap_next = TAP_PAUSE_IR;
      TAP_EXIT2_IR: if (tms) tap_next = TAP_UPD_IR;   else tap_next = TAP_SHIFT_IR;
      TAP_UPD_IR:   if (tms) tap_next = TAP_SEL_DR;   else tap_next = TAP_RTI;
      default:      tap_next = TAP_TLR;
    endcase
  endfunction

  function automatic logic in_range(
    input logic [31:0] addr,
    input logic [31:0] base,
    input logic [31:0] last
  );
    in_range = (addr >= base) && (addr <= last);
  endfunction

  function automatic logic is_sram_addr(input logic [31:0] addr);
    is_sram_addr =
        in_range(addr, ADDR_INSTR_BASE,  ADDR_INSTR_END)  ||
        in_range(addr, ADDR_DATA_BASE,   ADDR_DATA_END)   ||
        in_range(addr, ADDR_WEIGHT_BASE, ADDR_WEIGHT_END);
  endfunction

  always_ff @(posedge jtag_tck or negedge rst_n) begin
    if (!rst_n) begin
      tap_state_q             <= TAP_TLR;
      ir_q                    <= IR_IDCODE;
      ir_shift_q              <= IR_IDCODE;
      dr_shift_q              <= '0;
      mem_req_write_tck       <= 1'b0;
      mem_req_addr_tck        <= 32'h0;
      mem_req_wstrb_tck       <= 4'h0;
      mem_req_wdata_tck       <= 32'h0;
      mem_req_outstanding_tck <= 1'b0;
      req_toggle_tck          <= 1'b0;
      cpuctl_hold_tck         <= 1'b0;
      cpuctl_toggle_tck       <= 1'b0;
      rsp_toggle_meta_tck     <= 1'b0;
      rsp_toggle_sync_tck     <= 1'b0;
      rsp_toggle_seen_tck     <= 1'b0;
      mem_rsp_rdata_tck       <= 32'h0;
      mem_rsp_err_tck         <= 1'b0;
      mem_rsp_done_tck        <= 1'b1;
    end else begin
      rsp_toggle_meta_tck <= rsp_toggle_clk;
      rsp_toggle_sync_tck <= rsp_toggle_meta_tck;
      if (rsp_toggle_sync_tck != rsp_toggle_seen_tck) begin
        rsp_toggle_seen_tck     <= rsp_toggle_sync_tck;
        mem_req_outstanding_tck <= 1'b0;
        mem_rsp_rdata_tck       <= mem_rsp_rdata_clk;
        mem_rsp_err_tck         <= mem_rsp_err_clk;
        mem_rsp_done_tck        <= mem_rsp_done_clk;
      end

      case (tap_state_q)
        TAP_CAP_IR: begin
          ir_shift_q <= 4'b0001;
        end
        TAP_SHIFT_IR: begin
          ir_shift_q <= {jtag_tdi, ir_shift_q[IR_WIDTH-1:1]};
        end
        TAP_UPD_IR: begin
          ir_q <= ir_shift_q;
        end
        TAP_CAP_DR: begin
          dr_shift_q <= '0;
          case (ir_q)
            IR_IDCODE: begin
              dr_shift_q[IDCODE_DR_WIDTH-1:0] <= IDCODE_VALUE;
            end
            IR_MEMACC: begin
              dr_shift_q[31:0] <= mem_rsp_rdata_tck;
              dr_shift_q[32]   <= mem_rsp_err_tck;
              dr_shift_q[33]   <= mem_rsp_done_tck;
            end
            IR_CPUCTL: begin
              dr_shift_q[0] <= cpuctl_hold_tck;
              dr_shift_q[1] <= 1'b0;
            end
            default: begin
              dr_shift_q[0] <= 1'b0;
            end
          endcase
        end
        TAP_SHIFT_DR: begin
          case (ir_q)
            IR_IDCODE: begin
              dr_shift_q[IDCODE_DR_WIDTH-1:0] <=
                  {jtag_tdi, dr_shift_q[IDCODE_DR_WIDTH-1:1]};
            end
            IR_MEMACC: begin
              dr_shift_q[MEMACC_DR_WIDTH-1:0] <=
                  {jtag_tdi, dr_shift_q[MEMACC_DR_WIDTH-1:1]};
            end
            IR_CPUCTL: begin
              dr_shift_q[CPUCTL_DR_WIDTH-1:0] <=
                  {jtag_tdi, dr_shift_q[CPUCTL_DR_WIDTH-1:1]};
            end
            default: begin
              dr_shift_q[0] <= jtag_tdi;
            end
          endcase
        end
        TAP_UPD_DR: begin
          case (ir_q)
            IR_MEMACC: begin
              if (mem_req_outstanding_tck) begin
                mem_rsp_rdata_tck <= 32'h0;
                mem_rsp_err_tck   <= 1'b1;
                mem_rsp_done_tck  <= 1'b1;
              end else begin
                mem_req_write_tck       <= dr_shift_q[0];
                mem_req_addr_tck        <= dr_shift_q[32:1];
                mem_req_wstrb_tck       <= dr_shift_q[36:33];
                mem_req_wdata_tck       <= dr_shift_q[68:37];
                mem_req_outstanding_tck <= 1'b1;
                mem_rsp_rdata_tck       <= 32'h0;
                mem_rsp_err_tck         <= 1'b0;
                mem_rsp_done_tck        <= 1'b0;
                req_toggle_tck          <= ~req_toggle_tck;
              end
            end
            IR_CPUCTL: begin
              cpuctl_hold_tck   <= dr_shift_q[0];
              cpuctl_toggle_tck <= ~cpuctl_toggle_tck;
            end
            default: begin
            end
          endcase
        end
        default: begin
        end
      endcase

      tap_state_q <= tap_next(tap_state_q, jtag_tms);
    end
  end

  always_ff @(negedge jtag_tck or negedge rst_n) begin
    if (!rst_n) begin
      jtag_tdo <= 1'b0;
    end else begin
      case (tap_state_q)
        TAP_SHIFT_IR: jtag_tdo <= ir_shift_q[0];
        TAP_SHIFT_DR: jtag_tdo <= dr_shift_q[0];
        default:      jtag_tdo <= 1'b0;
      endcase
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      req_toggle_meta_clk   <= 1'b0;
      req_toggle_sync_clk   <= 1'b0;
      req_toggle_seen_clk   <= 1'b0;
      cpuctl_toggle_meta_clk<= 1'b0;
      cpuctl_toggle_sync_clk<= 1'b0;
      cpuctl_toggle_seen_clk<= 1'b0;
      mem_rsp_rdata_clk     <= 32'h0;
      mem_rsp_err_clk       <= 1'b0;
      mem_rsp_done_clk      <= 1'b1;
      rsp_toggle_clk        <= 1'b0;
      mem_req_write_clk     <= 1'b0;
      mem_req_addr_clk      <= 32'h0;
      mem_req_wstrb_clk     <= 4'h0;
      mem_req_wdata_clk     <= 32'h0;
      clk_state_q           <= CLK_IDLE;
      cpu_reset_hold        <= 1'b0;
      clk_timeout_cnt       <= '0;
    end else begin
      req_toggle_meta_clk    <= req_toggle_tck;
      req_toggle_sync_clk    <= req_toggle_meta_clk;
      cpuctl_toggle_meta_clk <= cpuctl_toggle_tck;
      cpuctl_toggle_sync_clk <= cpuctl_toggle_meta_clk;

      if (cpuctl_toggle_sync_clk != cpuctl_toggle_seen_clk) begin
        cpuctl_toggle_seen_clk <= cpuctl_toggle_sync_clk;
        cpu_reset_hold         <= cpuctl_hold_tck;
      end

      case (clk_state_q)
        CLK_IDLE: begin
          if (req_toggle_sync_clk != req_toggle_seen_clk) begin
            req_toggle_seen_clk <= req_toggle_sync_clk;
            mem_req_write_clk   <= mem_req_write_tck;
            mem_req_addr_clk    <= mem_req_addr_tck;
            mem_req_wstrb_clk   <= mem_req_wstrb_tck;
            mem_req_wdata_clk   <= mem_req_wdata_tck;
            if (!is_sram_addr(mem_req_addr_tck)) begin
              mem_rsp_rdata_clk <= 32'h0;
              mem_rsp_err_clk   <= 1'b1;
              mem_rsp_done_clk  <= 1'b1;
              rsp_toggle_clk    <= ~rsp_toggle_clk;
            end else begin
              clk_state_q <= CLK_WAIT_GRANT;
            end
          end
        end
        CLK_WAIT_GRANT: begin
          if (mem_req_grant) begin
            clk_state_q   <= CLK_ISSUE;
            clk_timeout_cnt <= '0;
          end else if (clk_timeout_cnt == CLK_TIMEOUT_MAX[9:0]) begin
            // Bus grant never came — force error response to unblock JTAG
            mem_rsp_rdata_clk <= 32'h0;
            mem_rsp_err_clk   <= 1'b1;
            mem_rsp_done_clk  <= 1'b1;
            rsp_toggle_clk    <= ~rsp_toggle_clk;
            clk_state_q       <= CLK_IDLE;
            clk_timeout_cnt   <= '0;
          end else begin
            clk_timeout_cnt <= clk_timeout_cnt + 10'd1;
          end
        end
        CLK_ISSUE: begin
          clk_state_q     <= CLK_WAIT_RSP;
          clk_timeout_cnt <= '0;
        end
        CLK_WAIT_RSP: begin
          if ((mem_req_write_clk && mem_m_ready) ||
              (!mem_req_write_clk && mem_m_rvalid)) begin
            mem_rsp_rdata_clk <= mem_req_write_clk ? 32'h0 : mem_m_rdata;
            mem_rsp_err_clk   <= 1'b0;
            mem_rsp_done_clk  <= 1'b1;
            rsp_toggle_clk    <= ~rsp_toggle_clk;
            clk_state_q       <= CLK_IDLE;
            clk_timeout_cnt   <= '0;
          end else if (clk_timeout_cnt == CLK_TIMEOUT_MAX[9:0]) begin
            // Bus response never came — force error response
            mem_rsp_rdata_clk <= 32'h0;
            mem_rsp_err_clk   <= 1'b1;
            mem_rsp_done_clk  <= 1'b1;
            rsp_toggle_clk    <= ~rsp_toggle_clk;
            clk_state_q       <= CLK_IDLE;
            clk_timeout_cnt   <= '0;
          end else begin
            clk_timeout_cnt <= clk_timeout_cnt + 10'd1;
          end
        end
        default: begin
          clk_state_q <= CLK_IDLE;
        end
      endcase
    end
  end

  assign mem_req_pending = (clk_state_q != CLK_IDLE);
  assign mem_m_valid     = (clk_state_q == CLK_ISSUE);
  assign mem_m_write     = mem_req_write_clk;
  assign mem_m_addr      = mem_req_addr_clk;
  assign mem_m_wstrb     = mem_req_wstrb_clk;
  assign mem_m_wdata     = mem_req_wdata_clk;
endmodule
