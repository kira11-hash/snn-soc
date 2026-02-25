`timescale 1ns/1ps
//======================================================================
// 文件名: snn_soc_top.sv
// 描述: SNN SoC 顶层。
//       - 实例化总线、SRAM、寄存器、DMA、FIFO、SNN 子系统与外设 stub
//       - 总线 master 由 Testbench 通过 dut.bus_if 直接驱动
//======================================================================
module snn_soc_top (
  input  logic        clk,
  input  logic        rst_n,

  // UART (stub)
  input  logic        uart_rx,
  output logic        uart_tx,

  // SPI Flash (stub)
  output logic        spi_cs_n,
  output logic        spi_sck,
  output logic        spi_mosi,
  input  logic        spi_miso,

  // JTAG (stub)
  input  logic        jtag_tck,
  input  logic        jtag_tms,
  input  logic        jtag_tdi,
  output logic        jtag_tdo
);
  import snn_soc_pkg::*;

  // 简化总线接口（Testbench 通过层级引用驱动）
  bus_simple_if bus_if(.clk(clk));

  // bus -> slave 连接信号
  logic        instr_req_valid, instr_req_write;
  logic [31:0] instr_req_addr,  instr_req_wdata;
  logic [3:0]  instr_req_wstrb;
  logic [31:0] instr_rdata;

  logic        data_req_valid,  data_req_write;
  logic [31:0] data_req_addr,   data_req_wdata;
  logic [3:0]  data_req_wstrb;
  logic [31:0] data_rdata;

  logic        weight_req_valid, weight_req_write;
  logic [31:0] weight_req_addr,  weight_req_wdata;
  logic [3:0]  weight_req_wstrb;
  logic [31:0] weight_rdata;

  logic        reg_req_valid, reg_req_write;
  logic [31:0] reg_req_addr,  reg_req_wdata;
  logic [3:0]  reg_req_wstrb;
  logic [31:0] reg_rdata;
  logic        reg_resp_read_pulse;
  logic [31:0] reg_resp_addr;

  logic        dma_req_valid, dma_req_write;
  logic [31:0] dma_req_addr,  dma_req_wdata;
  logic [3:0]  dma_req_wstrb;
  logic [31:0] dma_rdata;

  logic        uart_req_valid, uart_req_write;
  logic [31:0] uart_req_addr,  uart_req_wdata;
  logic [3:0]  uart_req_wstrb;
  logic [31:0] uart_rdata;

  logic        spi_req_valid, spi_req_write;
  logic [31:0] spi_req_addr,  spi_req_wdata;
  logic [3:0]  spi_req_wstrb;
  logic [31:0] spi_rdata;

  logic        fifo_req_valid, fifo_req_write;
  logic [31:0] fifo_req_addr,  fifo_req_wdata;
  logic [3:0]  fifo_req_wstrb;
  logic [31:0] fifo_rdata;

  // FIFO 连接信号
  logic        in_fifo_push, in_fifo_pop;
  logic [NUM_INPUTS-1:0] in_fifo_wdata;
  logic [NUM_INPUTS-1:0] in_fifo_rdata;
  logic        in_fifo_empty, in_fifo_full;
  logic        in_fifo_overflow, in_fifo_underflow;
  logic [$clog2(INPUT_FIFO_DEPTH+1)-1:0] in_fifo_count;

  logic        out_fifo_push, out_fifo_pop;
  logic [3:0]  out_fifo_wdata;
  logic [3:0]  out_fifo_rdata;
  logic        out_fifo_empty, out_fifo_full;
  logic        out_fifo_overflow, out_fifo_underflow;
  logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] out_fifo_count;

  // 标记未使用信号（lint 友好）
  wire _unused_top = reg_resp_read_pulse ^ &reg_resp_addr ^
                     in_fifo_overflow ^ in_fifo_underflow ^
                     out_fifo_overflow ^ out_fifo_underflow;

  // DMA 与 data_sram
  logic        dma_rd_en;
  logic [31:0] dma_rd_addr;
  logic [31:0] dma_rd_data;

  // SNN 子系统信号
  logic [NUM_INPUTS-1:0] wl_bitmap;
  logic                  wl_valid_pulse;
  logic [NUM_INPUTS-1:0] wl_bitmap_wrapped;
  logic                  wl_valid_pulse_wrapped;
  // WL 复用协议原型信号（用于冻结字段/时序，后续可迁移到 chip_top）
  logic [WL_GROUP_WIDTH-1:0] wl_data;
  logic [$clog2(WL_GROUP_COUNT)-1:0] wl_group_sel;
  logic                               wl_latch;
  logic                               wl_mux_busy;
  logic [NUM_INPUTS-1:0] wl_spike;
  logic                  dac_valid;
  logic                  dac_ready;
  logic                  dac_done_pulse;

  logic                  cim_start_pulse;
  logic                  cim_done;

  logic                  adc_kick_pulse;
  logic                  adc_start;
  logic                  adc_done;
  logic [$clog2(ADC_CHANNELS)-1:0] bl_sel;
  logic [ADC_BITS-1:0]   bl_data;

  logic                  neuron_in_valid;
  logic [NUM_OUTPUTS-1:0][NEURON_DATA_WIDTH-1:0] neuron_in_data;

  logic [31:0] neuron_threshold;
  logic [7:0]  timesteps;
  logic        reset_mode;
  logic        snn_busy;
  logic        snn_done_pulse;
  logic        snn_start_pulse;
  logic        snn_soft_reset_pulse;
  logic [7:0]  timestep_counter;
  logic [$clog2(PIXEL_BITS)-1:0] bitplane_shift;
  // 仅为 lint 保留（协议信号当前未连到顶层 pad）
  wire _unused_wl_mux = ^wl_data ^ ^wl_group_sel ^ wl_latch ^ wl_mux_busy;

  // ADC 饱和监控信号（adc_ctrl → reg_bank）
  logic [15:0] adc_sat_high;
  logic [15:0] adc_sat_low;

  // CIM Test Mode 信号（reg_bank → test MUX）
  logic                cim_test_mode;
  logic [ADC_BITS-1:0] cim_test_data;
  // 硬件侧（cim_macro_blackbox 原始输出，test mode MUX 前）
  logic                dac_ready_hw;
  logic                cim_done_hw;
  logic                adc_done_hw;
  logic [ADC_BITS-1:0] bl_data_hw;
  // 测试侧响应信号
  logic                dac_ready_test;
  logic                cim_done_test;
  logic                adc_done_test;
  logic [3:0]          test_cim_cnt;
  logic                test_cim_busy;
  logic [3:0]          test_adc_cnt;
  logic                test_adc_busy;

  // Debug 计数器（16-bit 饱和计数，仅 rst_n 清零）
  logic [15:0] dbg_dma_frame_cnt;
  logic [15:0] dbg_cim_cycle_cnt;
  logic [15:0] dbg_spike_cnt;
  logic [15:0] dbg_wl_stall_cnt;

  //======================
  // 总线互联
  //======================
  bus_interconnect u_bus_interconnect (
    .clk            (clk),
    .rst_n          (rst_n),

    .m_valid        (bus_if.m_valid),
    .m_write        (bus_if.m_write),
    .m_addr         (bus_if.m_addr),
    .m_wdata        (bus_if.m_wdata),
    .m_wstrb        (bus_if.m_wstrb),
    .m_ready        (bus_if.m_ready),
    .m_rdata        (bus_if.m_rdata),
    .m_rvalid       (bus_if.m_rvalid),

    .instr_req_valid(instr_req_valid),
    .instr_req_write(instr_req_write),
    .instr_req_addr (instr_req_addr),
    .instr_req_wdata(instr_req_wdata),
    .instr_req_wstrb(instr_req_wstrb),
    .instr_rdata    (instr_rdata),

    .data_req_valid (data_req_valid),
    .data_req_write (data_req_write),
    .data_req_addr  (data_req_addr),
    .data_req_wdata (data_req_wdata),
    .data_req_wstrb (data_req_wstrb),
    .data_rdata     (data_rdata),

    .weight_req_valid(weight_req_valid),
    .weight_req_write(weight_req_write),
    .weight_req_addr (weight_req_addr),
    .weight_req_wdata(weight_req_wdata),
    .weight_req_wstrb(weight_req_wstrb),
    .weight_rdata    (weight_rdata),

    .reg_req_valid  (reg_req_valid),
    .reg_req_write  (reg_req_write),
    .reg_req_addr   (reg_req_addr),
    .reg_req_wdata  (reg_req_wdata),
    .reg_req_wstrb  (reg_req_wstrb),
    .reg_rdata      (reg_rdata),
    .reg_resp_read_pulse(reg_resp_read_pulse),
    .reg_resp_addr  (reg_resp_addr),

    .dma_req_valid  (dma_req_valid),
    .dma_req_write  (dma_req_write),
    .dma_req_addr   (dma_req_addr),
    .dma_req_wdata  (dma_req_wdata),
    .dma_req_wstrb  (dma_req_wstrb),
    .dma_rdata      (dma_rdata),

    .uart_req_valid (uart_req_valid),
    .uart_req_write (uart_req_write),
    .uart_req_addr  (uart_req_addr),
    .uart_req_wdata (uart_req_wdata),
    .uart_req_wstrb (uart_req_wstrb),
    .uart_rdata     (uart_rdata),

    .spi_req_valid  (spi_req_valid),
    .spi_req_write  (spi_req_write),
    .spi_req_addr   (spi_req_addr),
    .spi_req_wdata  (spi_req_wdata),
    .spi_req_wstrb  (spi_req_wstrb),
    .spi_rdata      (spi_rdata),

    .fifo_req_valid (fifo_req_valid),
    .fifo_req_write (fifo_req_write),
    .fifo_req_addr  (fifo_req_addr),
    .fifo_req_wdata (fifo_req_wdata),
    .fifo_req_wstrb (fifo_req_wstrb),
    .fifo_rdata     (fifo_rdata)
  );

  //======================
  // SRAM 实例
  //======================
  sram_simple #(.MEM_BYTES(INSTR_SRAM_BYTES)) u_instr_sram (
    .clk       (clk),
    .rst_n     (rst_n),
    .req_valid (instr_req_valid),
    .req_write (instr_req_write),
    .req_addr  (instr_req_addr),
    .req_wdata (instr_req_wdata),
    .req_wstrb (instr_req_wstrb),
    .rdata     (instr_rdata)
  );

  sram_simple_dp #(.MEM_BYTES(DATA_SRAM_BYTES)) u_data_sram (
    .clk       (clk),
    .rst_n     (rst_n),
    .req_valid (data_req_valid),
    .req_write (data_req_write),
    .req_addr  (data_req_addr),
    .req_wdata (data_req_wdata),
    .req_wstrb (data_req_wstrb),
    .rdata     (data_rdata),
    .dma_rd_en (dma_rd_en),
    .dma_rd_addr(dma_rd_addr),
    .dma_rdata (dma_rd_data)
  );

  sram_simple #(.MEM_BYTES(WEIGHT_SRAM_BYTES)) u_weight_sram (
    .clk       (clk),
    .rst_n     (rst_n),
    .req_valid (weight_req_valid),
    .req_write (weight_req_write),
    .req_addr  (weight_req_addr),
    .req_wdata (weight_req_wdata),
    .req_wstrb (weight_req_wstrb),
    .rdata     (weight_rdata)
  );

  //======================
  // DMA
  //======================
  dma_engine u_dma (
    .clk         (clk),
    .rst_n       (rst_n),
    .req_valid   (dma_req_valid),
    .req_write   (dma_req_write),
    .req_addr    (dma_req_addr),
    .req_wdata   (dma_req_wdata),
    .req_wstrb   (dma_req_wstrb),
    .rdata       (dma_rdata),
    .dma_rd_en   (dma_rd_en),
    .dma_rd_addr (dma_rd_addr),
    .dma_rd_data (dma_rd_data),
    .in_fifo_push(in_fifo_push),
    .in_fifo_wdata(in_fifo_wdata),
    .in_fifo_full(in_fifo_full)
  );

  //======================
  // FIFO
  //======================
  fifo_sync #(.WIDTH(NUM_INPUTS), .DEPTH(INPUT_FIFO_DEPTH)) u_input_fifo (
    .clk       (clk),
    .rst_n     (rst_n),
    .push      (in_fifo_push),
    .push_data (in_fifo_wdata),
    .pop       (in_fifo_pop),
    .rd_data   (in_fifo_rdata),
    .empty     (in_fifo_empty),
    .full      (in_fifo_full),
    .count     (in_fifo_count),
    .overflow  (in_fifo_overflow),
    .underflow (in_fifo_underflow)
  );

  fifo_sync #(.WIDTH(4), .DEPTH(OUTPUT_FIFO_DEPTH)) u_output_fifo (
    .clk       (clk),
    .rst_n     (rst_n),
    .push      (out_fifo_push),
    .push_data (out_fifo_wdata),
    .pop       (out_fifo_pop),
    .rd_data   (out_fifo_rdata),
    .empty     (out_fifo_empty),
    .full      (out_fifo_full),
    .count     (out_fifo_count),
    .overflow  (out_fifo_overflow),
    .underflow (out_fifo_underflow)
  );

  //======================
  // Reg Bank + FIFO Regs
  //======================
  reg_bank u_reg_bank (
    .clk            (clk),
    .rst_n          (rst_n),
    .req_valid      (reg_req_valid),
    .req_write      (reg_req_write),
    .req_addr       (reg_req_addr),
    .req_wdata      (reg_req_wdata),
    .req_wstrb      (reg_req_wstrb),
    .rdata          (reg_rdata),
    .snn_busy       (snn_busy),
    .snn_done_pulse (snn_done_pulse),
    .timestep_counter(timestep_counter),
    .in_fifo_empty  (in_fifo_empty),
    .in_fifo_full   (in_fifo_full),
    .out_fifo_empty (out_fifo_empty),
    .out_fifo_full  (out_fifo_full),
    .out_fifo_rdata (out_fifo_rdata),
    .out_fifo_count (out_fifo_count),
    .adc_sat_high   (adc_sat_high),
    .adc_sat_low    (adc_sat_low),
    .dbg_dma_frame_cnt(dbg_dma_frame_cnt),
    .dbg_cim_cycle_cnt(dbg_cim_cycle_cnt),
    .dbg_spike_cnt    (dbg_spike_cnt),
    .dbg_wl_stall_cnt (dbg_wl_stall_cnt),
    .neuron_threshold(neuron_threshold),
    .timesteps      (timesteps),
    .reset_mode     (reset_mode),
    .start_pulse    (snn_start_pulse),
    .soft_reset_pulse(snn_soft_reset_pulse),
    .cim_test_mode  (cim_test_mode),
    .cim_test_data  (cim_test_data),
    .out_fifo_pop   (out_fifo_pop)
  );

  fifo_regs u_fifo_regs (
    .req_valid    (fifo_req_valid),
    .req_write    (fifo_req_write),
    .req_addr     (fifo_req_addr),
    .req_wdata    (fifo_req_wdata),
    .req_wstrb    (fifo_req_wstrb),
    .rdata        (fifo_rdata),
    .in_fifo_count(in_fifo_count),
    .out_fifo_count(out_fifo_count),
    .in_fifo_empty(in_fifo_empty),
    .in_fifo_full (in_fifo_full),
    .out_fifo_empty(out_fifo_empty),
    .out_fifo_full(out_fifo_full)
  );

  //======================
  // SNN 子系统
  //======================
  cim_array_ctrl u_cim_ctrl (
    .clk             (clk),
    .rst_n           (rst_n),
    .soft_reset_pulse(snn_soft_reset_pulse),
    .start_pulse     (snn_start_pulse),
    .timesteps       (timesteps),
    .in_fifo_rdata   (in_fifo_rdata),
    .in_fifo_empty   (in_fifo_empty),
    .in_fifo_pop     (in_fifo_pop),
    .wl_bitmap       (wl_bitmap),
    .wl_valid_pulse  (wl_valid_pulse),
    .dac_done_pulse  (dac_done_pulse),
    .cim_start_pulse (cim_start_pulse),
    .cim_done        (cim_done),
    .adc_kick_pulse  (adc_kick_pulse),
    .neuron_in_valid (neuron_in_valid),
    .busy            (snn_busy),
    .done_pulse      (snn_done_pulse),
    .timestep_counter(timestep_counter),
    .bitplane_shift  (bitplane_shift)
  );

  wl_mux_wrapper u_wl_mux_wrapper (
    .clk               (clk),
    .rst_n             (rst_n),
    .wl_bitmap_in      (wl_bitmap),
    .wl_valid_pulse_in (wl_valid_pulse),
    .wl_bitmap_out     (wl_bitmap_wrapped),
    .wl_valid_pulse_out(wl_valid_pulse_wrapped),
    .wl_data           (wl_data),
    .wl_group_sel      (wl_group_sel),
    .wl_latch          (wl_latch),
    .wl_busy           (wl_mux_busy)
  );

  dac_ctrl u_dac (
    .clk          (clk),
    .rst_n        (rst_n),
    .wl_bitmap    (wl_bitmap_wrapped),
    .wl_valid_pulse(wl_valid_pulse_wrapped),
    .wl_spike     (wl_spike),
    .dac_valid    (dac_valid),
    .dac_ready    (dac_ready),
    .dac_done_pulse(dac_done_pulse)
  );

  cim_macro_blackbox u_macro (
    .clk       (clk),
    .rst_n     (rst_n),
    .wl_spike  (wl_spike),
    .dac_valid (dac_valid),
    .dac_ready (dac_ready_hw),
    .cim_start (cim_start_pulse),
    .cim_done  (cim_done_hw),
    .adc_start (adc_start),
    .adc_done  (adc_done_hw),
    .bl_sel    (bl_sel),
    .bl_data   (bl_data_hw)
  );

  adc_ctrl u_adc (
    .clk            (clk),
    .rst_n          (rst_n),
    .adc_kick_pulse (adc_kick_pulse),
    .adc_start      (adc_start),
    .adc_done       (adc_done),
    .bl_sel         (bl_sel),
    .bl_data        (bl_data),
    .neuron_in_valid(neuron_in_valid),
    .neuron_in_data (neuron_in_data),
    .adc_sat_high   (adc_sat_high),
    .adc_sat_low    (adc_sat_low)
  );

  lif_neurons u_lif (
    .clk            (clk),
    .rst_n          (rst_n),
    .soft_reset_pulse(snn_soft_reset_pulse),
    .neuron_in_valid(neuron_in_valid),
    .neuron_in_data (neuron_in_data),
    .bitplane_shift (bitplane_shift),
    .threshold      (neuron_threshold),
    .reset_mode     (reset_mode),
    .out_fifo_push  (out_fifo_push),
    .out_fifo_wdata (out_fifo_wdata),
    .out_fifo_full  (out_fifo_full)
  );

  //======================
  // CIM Test Mode MUX + 响应生成器
  //======================
  // 当 cim_test_mode=1 时，旁路 cim_macro_blackbox 的输出，
  // 由数字侧生成 fake 响应，用于硅上验证数字逻辑（不依赖真实 RRAM 宏）。
  assign dac_ready_test = 1'b1; // 测试模式下 DAC 始终就绪
  assign dac_ready = cim_test_mode ? dac_ready_test : dac_ready_hw;
  assign cim_done  = cim_test_mode ? cim_done_test  : cim_done_hw;
  assign adc_done  = cim_test_mode ? adc_done_test  : adc_done_hw;
  assign bl_data   = cim_test_mode ? cim_test_data   : bl_data_hw;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cim_done_test  <= 1'b0;
      adc_done_test  <= 1'b0;
      test_cim_cnt   <= 4'd0;
      test_cim_busy  <= 1'b0;
      test_adc_cnt   <= 4'd0;
      test_adc_busy  <= 1'b0;
    end else begin
      cim_done_test <= 1'b0;
      adc_done_test <= 1'b0;
      // CIM: 2 cycle delay after cim_start
      if (cim_start_pulse && !test_cim_busy) begin
        test_cim_busy <= 1'b1;
        test_cim_cnt  <= 4'd1;
      end else if (test_cim_busy) begin
        if (test_cim_cnt == 4'd0) begin
          cim_done_test <= 1'b1;
          test_cim_busy <= 1'b0;
        end else begin
          test_cim_cnt <= test_cim_cnt - 4'd1;
        end
      end
      // ADC: 1 cycle delay after adc_start
      if (adc_start && !test_adc_busy) begin
        test_adc_busy <= 1'b1;
        test_adc_cnt  <= 4'd0;
      end else if (test_adc_busy) begin
        if (test_adc_cnt == 4'd0) begin
          adc_done_test <= 1'b1;
          test_adc_busy <= 1'b0;
        end else begin
          test_adc_cnt <= test_adc_cnt - 4'd1;
        end
      end
    end
  end

  //======================
  // Debug 计数器（16-bit 饱和）
  //======================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dbg_dma_frame_cnt <= 16'h0;
      dbg_cim_cycle_cnt <= 16'h0;
      dbg_spike_cnt     <= 16'h0;
      dbg_wl_stall_cnt  <= 16'h0;
    end else begin
      // DMA frame count: 每次成功 push 64-bit bitmap 到 FIFO
      if (in_fifo_push && !(&dbg_dma_frame_cnt))
        dbg_dma_frame_cnt <= dbg_dma_frame_cnt + 16'h1;
      // CIM cycle count: busy 期间每拍 +1
      if (snn_busy && !(&dbg_cim_cycle_cnt))
        dbg_cim_cycle_cnt <= dbg_cim_cycle_cnt + 16'h1;
      // Spike count: 每次 LIF 向 output_fifo push
      if (out_fifo_push && !(&dbg_spike_cnt))
        dbg_spike_cnt <= dbg_spike_cnt + 16'h1;
      // WL stall count: wl_valid_pulse 到来时 mux 仍忙（协议违规）
      if (wl_valid_pulse && wl_mux_busy && !(&dbg_wl_stall_cnt))
        dbg_wl_stall_cnt <= dbg_wl_stall_cnt + 16'h1;
    end
  end

  //======================
  // 外设 stub
  //======================
  uart_stub u_uart (
    .clk       (clk),
    .rst_n     (rst_n),
    .req_valid (uart_req_valid),
    .req_write (uart_req_write),
    .req_addr  (uart_req_addr),
    .req_wdata (uart_req_wdata),
    .req_wstrb (uart_req_wstrb),
    .rdata     (uart_rdata),
    .uart_rx   (uart_rx),
    .uart_tx   (uart_tx)
  );

  spi_stub u_spi (
    .clk       (clk),
    .rst_n     (rst_n),
    .req_valid (spi_req_valid),
    .req_write (spi_req_write),
    .req_addr  (spi_req_addr),
    .req_wdata (spi_req_wdata),
    .req_wstrb (spi_req_wstrb),
    .rdata     (spi_rdata),
    .spi_cs_n  (spi_cs_n),
    .spi_sck   (spi_sck),
    .spi_mosi  (spi_mosi),
    .spi_miso  (spi_miso)
  );

  jtag_stub u_jtag (
    .jtag_tck (jtag_tck),
    .jtag_tms (jtag_tms),
    .jtag_tdi (jtag_tdi),
    .jtag_tdo (jtag_tdo)
  );
endmodule

