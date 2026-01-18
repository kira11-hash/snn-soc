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
  logic [$clog2(512+1)-1:0] in_fifo_count;

  logic        out_fifo_push, out_fifo_pop;
  logic [3:0]  out_fifo_wdata;
  logic [3:0]  out_fifo_rdata;
  logic        out_fifo_empty, out_fifo_full;
  logic [$clog2(256+1)-1:0] out_fifo_count;

  // DMA 与 data_sram
  logic        dma_rd_en;
  logic [31:0] dma_rd_addr;
  logic [31:0] dma_rd_data;

  // SNN 子系统信号
  logic [NUM_INPUTS-1:0] wl_bitmap;
  logic                  wl_valid_pulse;
  logic [NUM_INPUTS-1:0] wl_spike;
  logic                  dac_valid;
  logic                  dac_ready;
  logic                  dac_done_pulse;

  logic                  cim_start_pulse;
  logic                  cim_done;

  logic                  adc_kick_pulse;
  logic                  adc_start;
  logic                  adc_done;
  logic [$clog2(NUM_OUTPUTS)-1:0] bl_sel;
  logic [7:0]            bl_data;

  logic                  neuron_in_valid;
  logic [NUM_OUTPUTS-1:0][7:0] neuron_in_data;

  logic [15:0] neuron_threshold;
  logic [7:0]  timesteps;
  logic        reset_mode;
  logic        snn_busy;
  logic        snn_done_pulse;
  logic        snn_start_pulse;
  logic        snn_soft_reset_pulse;
  logic [7:0]  timestep_counter;

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
  sram_simple #(.MEM_BYTES(65536)) u_instr_sram (
    .clk       (clk),
    .rst_n     (rst_n),
    .req_valid (instr_req_valid),
    .req_write (instr_req_write),
    .req_addr  (instr_req_addr),
    .req_wdata (instr_req_wdata),
    .req_wstrb (instr_req_wstrb),
    .rdata     (instr_rdata)
  );

  sram_simple_dp #(.MEM_BYTES(131072)) u_data_sram (
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

  sram_simple #(.MEM_BYTES(16384)) u_weight_sram (
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
  fifo_sync #(.WIDTH(NUM_INPUTS), .DEPTH(512)) u_input_fifo (
    .clk       (clk),
    .rst_n     (rst_n),
    .push      (in_fifo_push),
    .push_data (in_fifo_wdata),
    .pop       (in_fifo_pop),
    .rd_data   (in_fifo_rdata),
    .empty     (in_fifo_empty),
    .full      (in_fifo_full),
    .count     (in_fifo_count),
    .overflow  (),
    .underflow ()
  );

  fifo_sync #(.WIDTH(4), .DEPTH(256)) u_output_fifo (
    .clk       (clk),
    .rst_n     (rst_n),
    .push      (out_fifo_push),
    .push_data (out_fifo_wdata),
    .pop       (out_fifo_pop),
    .rd_data   (out_fifo_rdata),
    .empty     (out_fifo_empty),
    .full      (out_fifo_full),
    .count     (out_fifo_count),
    .overflow  (),
    .underflow ()
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
    .neuron_threshold(neuron_threshold),
    .timesteps      (timesteps),
    .reset_mode     (reset_mode),
    .start_pulse    (snn_start_pulse),
    .soft_reset_pulse(snn_soft_reset_pulse),
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
    .timestep_counter(timestep_counter)
  );

  dac_ctrl u_dac (
    .clk          (clk),
    .rst_n        (rst_n),
    .wl_bitmap    (wl_bitmap),
    .wl_valid_pulse(wl_valid_pulse),
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
    .dac_ready (dac_ready),
    .cim_start (cim_start_pulse),
    .cim_done  (cim_done),
    .adc_start (adc_start),
    .adc_done  (adc_done),
    .bl_sel    (bl_sel),
    .bl_data   (bl_data)
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
    .neuron_in_data (neuron_in_data)
  );

  lif_neurons u_lif (
    .clk            (clk),
    .rst_n          (rst_n),
    .soft_reset_pulse(snn_soft_reset_pulse),
    .neuron_in_valid(neuron_in_valid),
    .neuron_in_data (neuron_in_data),
    .threshold      (neuron_threshold),
    .reset_mode     (reset_mode),
    .out_fifo_push  (out_fifo_push),
    .out_fifo_wdata (out_fifo_wdata),
    .out_fifo_full  (out_fifo_full)
  );

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
