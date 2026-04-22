`timescale 1ns/1ps
//===========================================================================
// fpga/cim_model/cim_fpga_programmable_model.sv
//
// FPGA-specific, fully programmable CIM macro behavioral model.
// Module name is `cim_macro_blackbox` for drop-in Vivado substitution:
//   - Exclude  rtl/snn/cim_macro_blackbox.sv  from build filelist
//   - Include  fpga/cim_model/cim_fpga_programmable_model.sv  instead
//
// Key differences vs. rtl/snn/cim_macro_blackbox.sv:
//   • No `ifdef SYNTHESIS guard — this IS the synthesis-time implementation
//   • Always uses weight_mem BRAM model (P_USE_BRAM_WEIGHTS=1 permanently)
//   • No $error / $fatal / $display (Vivado-safe)
//   • Weighted sum computed combinationally from weight_mem FFs, then
//     registered into bl_data_internal when adc_done fires
//   • Timing model matches behavioral: CIM_LATENCY_CYCLES / ADC_SAMPLE_CYCLES
//     from snn_soc_pkg (same values as sim model, firmware polls done signals)
//===========================================================================
module cim_macro_blackbox #(
  parameter int  P_NUM_INPUTS      = snn_soc_pkg::NUM_INPUTS,   // 64
  parameter int  P_ADC_CHANNELS    = snn_soc_pkg::ADC_CHANNELS, // 20
  // P_USE_BRAM_WEIGHTS: kept for port-signature parity; always-1 in FPGA model
  parameter bit  P_USE_BRAM_WEIGHTS = 1'b1
) (
  input  logic clk,
  input  logic rst_n,

  // WL bitmap (64 parallel inputs, one bit-plane per CIM cycle)
  input  logic [P_NUM_INPUTS-1:0] wl_spike,

  // DAC latch trigger: single-cycle pulse, capture wl_spike → wl_latched
  input  logic dac_valid,

  // CIM compute handshake
  input  logic cim_start,
  output logic cim_done,

  // ADC sample handshake
  input  logic adc_start,
  output logic adc_done,
  input  logic [$clog2(P_ADC_CHANNELS)-1:0] bl_sel,
  output logic [snn_soc_pkg::ADC_BITS-1:0]  bl_data,

  // Programming ports (from cim_program_ctrl, direct — NOT via arbiter)
  input  logic prog_en,
  input  logic erase_en,
  input  logic verify_en   // used as qualifier by program_ctrl FSM; read back
                            // via normal adc_start/done path — no special action here
);
  import snn_soc_pkg::*;

  localparam int  BL_SEL_W  = $clog2(P_ADC_CHANNELS);
  localparam logic [BL_SEL_W-1:0] ADC_CH_MAX = BL_SEL_W'(P_ADC_CHANNELS);

  // -------------------------------------------------------------------------
  // Weight storage (implemented as FFs; small enough for XCZU9EG)
  //   weight_mem[r][c]     — 8-bit ADC level for cell (row r, col c)
  //   prog_pulse_acc[r][c] — 4-bit pulse accumulator (0..15)
  // -------------------------------------------------------------------------
  logic [ADC_BITS-1:0] weight_mem     [0:P_NUM_INPUTS-1][0:P_ADC_CHANNELS-1];
  logic [3:0]          prog_pulse_acc [0:P_NUM_INPUTS-1][0:P_ADC_CHANNELS-1];

  // Latched WL bitmap (captured on dac_valid)
  logic [P_NUM_INPUTS-1:0] wl_latched;

  // Registered ADC output buffer (updated on adc_done)
  logic [P_ADC_CHANNELS-1:0][ADC_BITS-1:0] bl_data_internal;

  // Latency counters and busy flags
  logic [7:0] cim_cnt, adc_cnt;
  logic       cim_busy, adc_busy;

  // -------------------------------------------------------------------------
  // Combinational weighted sum: ws_tmp[j] = Σ weight_mem[r][j] * wl_latched[r]
  // Reading weight_mem as combinational (FF outputs) is legal and synthesises
  // as a wide adder tree.  Vivado 2022.2 handles nested for loops in always_comb.
  // -------------------------------------------------------------------------
  logic [15:0] ws_tmp [0:P_ADC_CHANNELS-1];

  always_comb begin
    for (int j = 0; j < P_ADC_CHANNELS; j++) begin
      ws_tmp[j] = 16'd0;
      for (int r = 0; r < P_NUM_INPUTS; r++) begin
        if (wl_latched[r])
          ws_tmp[j] = ws_tmp[j] + {8'd0, weight_mem[r][j]};
      end
    end
  end

  // -------------------------------------------------------------------------
  // bl_data output MUX (combinational)
  // -------------------------------------------------------------------------
  always_comb begin
    bl_data = (bl_sel < ADC_CH_MAX) ? bl_data_internal[bl_sel] : {ADC_BITS{1'b0}};
  end

  // -------------------------------------------------------------------------
  // Main inference timing block
  //   dac_valid  → capture wl_spike
  //   cim_start  → CIM_LATENCY_CYCLES countdown → cim_done
  //   adc_start  → ADC_SAMPLE_CYCLES countdown  → adc_done + latch ws_tmp
  // -------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wl_latched       <= '0;
      cim_done         <= 1'b0;
      adc_done         <= 1'b0;
      cim_cnt          <= 8'h0;
      adc_cnt          <= 8'h0;
      cim_busy         <= 1'b0;
      adc_busy         <= 1'b0;
      bl_data_internal <= '0;
    end else begin
      cim_done <= 1'b0;
      adc_done <= 1'b0;

      // DAC latch
      if (dac_valid)
        wl_latched <= wl_spike;

      // CIM latency
      if (cim_start && !cim_busy) begin
        cim_busy <= 1'b1;
        cim_cnt  <= (CIM_LATENCY_CYCLES == 0) ? 8'h0
                                              : (CIM_LATENCY_CYCLES[7:0] - 8'h1);
      end
      if (cim_busy) begin
        if (cim_cnt == 8'h0) begin
          cim_done <= 1'b1;
          cim_busy <= 1'b0;
        end else
          cim_cnt <= cim_cnt - 8'h1;
      end

      // ADC latency + weighted-sum capture
      if (adc_start && !adc_busy) begin
        adc_busy <= 1'b1;
        adc_cnt  <= (ADC_SAMPLE_CYCLES == 0) ? 8'h0
                                             : (ADC_SAMPLE_CYCLES[7:0] - 8'h1);
      end
      if (adc_busy) begin
        if (adc_cnt == 8'h0) begin
          adc_done <= 1'b1;
          adc_busy <= 1'b0;
          for (int j = 0; j < P_ADC_CHANNELS; j++) begin
            bl_data_internal[j] <= (ws_tmp[j] > 16'd255) ? 8'hFF : ws_tmp[j][7:0];
          end
        end else
          adc_cnt <= adc_cnt - 8'h1;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Programming / erase block (weight_mem update)
  //   erase_en + cim_start + !cim_busy:
  //     &wl_latched → full-array erase (all cells → 0)
  //     else        → per-cell erase (activated rows, column = bl_sel)
  //   prog_en + cim_start + !cim_busy:
  //     increment prog_pulse_acc[r][bl_sel] for active rows; update weight_mem
  // -------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int r = 0; r < P_NUM_INPUTS; r++) begin
        for (int c = 0; c < P_ADC_CHANNELS; c++) begin
          weight_mem[r][c]     <= 8'd0;
          prog_pulse_acc[r][c] <= 4'd0;
        end
      end
    end else begin
      if (erase_en && cim_start && !cim_busy) begin
        if (&wl_latched) begin
          // Full-array erase
          for (int r = 0; r < P_NUM_INPUTS; r++) begin
            for (int c = 0; c < P_ADC_CHANNELS; c++) begin
              weight_mem[r][c]     <= 8'd0;
              prog_pulse_acc[r][c] <= 4'd0;
            end
          end
        end else begin
          // Per-cell erase: activated rows, selected column
          for (int r = 0; r < P_NUM_INPUTS; r++) begin
            if (wl_latched[r]) begin
              weight_mem[r][bl_sel]     <= 8'd0;
              prog_pulse_acc[r][bl_sel] <= 4'd0;
            end
          end
        end
      end else if (prog_en && cim_start && !cim_busy) begin
        // Write: saturate at PROG_LEVELS-1 = 15
        for (int r = 0; r < P_NUM_INPUTS; r++) begin
          if (wl_latched[r] && prog_pulse_acc[r][bl_sel] < 4'd15) begin
            prog_pulse_acc[r][bl_sel] <= prog_pulse_acc[r][bl_sel] + 4'd1;
            weight_mem[r][bl_sel]     <=
              ADC_BITS'((int'(prog_pulse_acc[r][bl_sel]) + 1) * (256 / PROG_LEVELS));
          end
        end
      end
    end
  end

  // Silence unused-signal lint
  wire _unused = &{1'b0, verify_en, P_USE_BRAM_WEIGHTS};

endmodule
