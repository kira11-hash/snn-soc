`timescale 1ns/1ps
//======================================================================
// fmap_sram_v2.sv
//
// 【我在 SoC 里的位置】
// 我是 CONV 扩展的 feature-map 存储 primitive，挂在 snn_soc_v2b_top 内，
// 一侧被 firmware preload 写口和 conv_ctrl_v2 写回口共用，另一侧被
// patch_unroller_v2 / fmap_flatten_reader_v2 动态读取。我的职责很克制：
// 只提供 ping-pong A/B bank、32-bit word、byte-enable 写和 1-cycle 同步读；
// 不在这里理解 K、stride、channel 或 timestep。
//
// 【接口和数据流】
// - bank_sel_pp 选择 reader 当前读哪一侧 bank，CONV 写回通常写 ~bank_sel_pp，
//   这样上一层输出和下一层输入天然 ping-pong，避免读写同 bank。
// - rd_word_addr/rd_data 给 patch/flatten reader，一次读 32 个 timestep bit。
// - wr_bank_sel/wr_word_addr/wr_data/wr_strb 给 firmware preload 或 CONV writeback。
// - addr_oob 只报告写越界，因为越界写会破坏后续层；读越界我返回 0，方便 padding
//   和异常地址在仿真里表现为可控零值。
//
// 【关键指标和取舍】
// 当前 FPGA 目标是 50 MHz 单时钟域，读延迟固定 1 cycle，写吞吐 1 word/cycle。
// 我刻意不做 bit-level 插入/抽取，是为了把 SRAM primitive 保持成 BRAM 友好的
// 简单接口；复杂 layout 由 reader/ctrl 处理，面试时可以说这是“存储和地址语义
// 解耦”的设计。
//======================================================================
module fmap_sram_v2
  import snn_soc_pkg::*;
#(
  parameter int P_BANK_KIB   = V2B_CONV_FMAP_BANK_KIB,
  parameter int P_BANK_WORDS = (P_BANK_KIB * 1024) / 4,
  parameter int P_ADDR_W     = $clog2(P_BANK_WORDS)
) (
  input  logic clk,
  input  logic rst_n,

  // 0: read bank A, 1: read bank B. Write bank is explicitly selected.
  input  logic        bank_sel_pp,

  input  logic        rd_en,
  input  logic [31:0] rd_word_addr,
  output logic [31:0] rd_data,

  input  logic        wr_en,
  input  logic        wr_bank_sel,
  input  logic [31:0] wr_word_addr,
  input  logic [31:0] wr_data,
  input  logic [3:0]  wr_strb,
  output logic        addr_oob
);

  logic wr_in_range;
  logic rd_in_range;
  logic [P_ADDR_W-1:0] wr_addr_idx;
  logic [P_ADDR_W-1:0] rd_addr_idx;

  // 【Corner case：地址越界的处理策略】
  // 写越界必须显式挡住，否则 Vivado BRAM/仿真数组都会把非法地址截断到低位，
  // 结果不是报错而是悄悄覆盖合法 fmap word。读越界则返回 0，原因是卷积 padding
  // 和非法 reader 地址在系统级上都应该退化为“没有 spike”，这样更利于定位上游。
  assign wr_in_range = (wr_word_addr < P_BANK_WORDS);
  assign rd_in_range = (rd_word_addr < P_BANK_WORDS);
  assign addr_oob    = wr_en && !wr_in_range;
  assign wr_addr_idx = wr_word_addr[P_ADDR_W-1:0];
  assign rd_addr_idx = rd_word_addr[P_ADDR_W-1:0];

`ifdef SYNTHESIS
  logic [31:0] rd_data_a;
  logic [31:0] rd_data_b;
  logic        rd_bank_q;
  logic        rd_oob_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_bank_q <= 1'b0;
      rd_oob_q  <= 1'b1;
    end else if (rd_en) begin
      rd_bank_q <= bank_sel_pp;
      rd_oob_q  <= !rd_in_range;
    end
  end

  assign rd_data = rd_oob_q ? 32'h0 : (rd_bank_q ? rd_data_b : rd_data_a);

  // 【架构注释：综合用 XPM，而不是相信大数组自动推 BRAM】
  // 我在 FPGA 分支里固定用 xpm_memory_sdpram，是因为 Vivado 2022.2 曾把这种
  // 大容量 32-bit bank 推成 LUTRAM，导致面积和时序都失控。XPM 的 trade-off 是
  // 代码带 Xilinx 依赖，但换来资源可预测、READ_LATENCY_B=1 可控，也和板级
  // timing closure 文档里的 BRAM 模型一致。
  // TODO优化方向：如果后续走 ASIC 或非 Xilinx FPGA，可以在这一层抽一个
  // vendor-neutral SRAM wrapper，保持上层 CONV/reader 接口不变。
  xpm_memory_sdpram #(
    .ADDR_WIDTH_A(P_ADDR_W),
    .ADDR_WIDTH_B(P_ADDR_W),
    .AUTO_SLEEP_TIME(0),
    .BYTE_WRITE_WIDTH_A(8),
    .CASCADE_HEIGHT(0),
    .CLOCKING_MODE("common_clock"),
    .ECC_MODE("no_ecc"),
    .MEMORY_INIT_FILE("none"),
    .MEMORY_INIT_PARAM("0"),
    .MEMORY_OPTIMIZATION("true"),
    .MEMORY_PRIMITIVE("block"),
    .MEMORY_SIZE(P_BANK_WORDS * 32),
    .MESSAGE_CONTROL(0),
    .READ_DATA_WIDTH_B(32),
    .READ_LATENCY_B(1),
    .READ_RESET_VALUE_B("0"),
    .RST_MODE_A("SYNC"),
    .RST_MODE_B("SYNC"),
    .SIM_ASSERT_CHK(0),
    .USE_EMBEDDED_CONSTRAINT(0),
    .USE_MEM_INIT(0),
    .WAKEUP_TIME("disable_sleep"),
    .WRITE_DATA_WIDTH_A(32),
    .WRITE_MODE_B("read_first")
  ) u_bank_a_xpm (
    .clka(clk),
    .ena(wr_en && wr_in_range && !wr_bank_sel),
    .wea((wr_en && wr_in_range && !wr_bank_sel) ? wr_strb : 4'b0000),
    .addra(wr_addr_idx),
    .dina(wr_data),
    .injectdbiterra(1'b0),
    .injectsbiterra(1'b0),
    .clkb(clk),
    .enb(rd_en && rd_in_range && !bank_sel_pp),
    .addrb(rd_addr_idx),
    .doutb(rd_data_a),
    .regceb(1'b1),
    .rstb(!rst_n),
    .sleep(1'b0),
    .dbiterrb(),
    .sbiterrb()
  );

  xpm_memory_sdpram #(
    .ADDR_WIDTH_A(P_ADDR_W),
    .ADDR_WIDTH_B(P_ADDR_W),
    .AUTO_SLEEP_TIME(0),
    .BYTE_WRITE_WIDTH_A(8),
    .CASCADE_HEIGHT(0),
    .CLOCKING_MODE("common_clock"),
    .ECC_MODE("no_ecc"),
    .MEMORY_INIT_FILE("none"),
    .MEMORY_INIT_PARAM("0"),
    .MEMORY_OPTIMIZATION("true"),
    .MEMORY_PRIMITIVE("block"),
    .MEMORY_SIZE(P_BANK_WORDS * 32),
    .MESSAGE_CONTROL(0),
    .READ_DATA_WIDTH_B(32),
    .READ_LATENCY_B(1),
    .READ_RESET_VALUE_B("0"),
    .RST_MODE_A("SYNC"),
    .RST_MODE_B("SYNC"),
    .SIM_ASSERT_CHK(0),
    .USE_EMBEDDED_CONSTRAINT(0),
    .USE_MEM_INIT(0),
    .WAKEUP_TIME("disable_sleep"),
    .WRITE_DATA_WIDTH_A(32),
    .WRITE_MODE_B("read_first")
  ) u_bank_b_xpm (
    .clka(clk),
    .ena(wr_en && wr_in_range && wr_bank_sel),
    .wea((wr_en && wr_in_range && wr_bank_sel) ? wr_strb : 4'b0000),
    .addra(wr_addr_idx),
    .dina(wr_data),
    .injectdbiterra(1'b0),
    .injectsbiterra(1'b0),
    .clkb(clk),
    .enb(rd_en && rd_in_range && bank_sel_pp),
    .addrb(rd_addr_idx),
    .doutb(rd_data_b),
    .regceb(1'b1),
    .rstb(!rst_n),
    .sleep(1'b0),
    .dbiterrb(),
    .sbiterrb()
  );

`else
  // 【架构注释：仿真用普通数组，保持语义简单】
  // 非综合路径我保留行为数组，是为了让 Icarus/Verilator/VCS 都能跑 unit TB，
  // 不要求仿真环境提供 XPM library。这里仍保留 ram_style="block" 提示，方便
  // 某些 lint/synth-only smoke test 看到与综合实现一致的意图。
  (* ram_style = "block" *) logic [31:0] bank_a [0:P_BANK_WORDS-1];
  (* ram_style = "block" *) logic [31:0] bank_b [0:P_BANK_WORDS-1];

  always_ff @(posedge clk) begin
    if (wr_en && wr_in_range) begin
      if (!wr_bank_sel) begin
        if (wr_strb[0]) bank_a[wr_addr_idx][7:0]   <= wr_data[7:0];
        if (wr_strb[1]) bank_a[wr_addr_idx][15:8]  <= wr_data[15:8];
        if (wr_strb[2]) bank_a[wr_addr_idx][23:16] <= wr_data[23:16];
        if (wr_strb[3]) bank_a[wr_addr_idx][31:24] <= wr_data[31:24];
      end else begin
        if (wr_strb[0]) bank_b[wr_addr_idx][7:0]   <= wr_data[7:0];
        if (wr_strb[1]) bank_b[wr_addr_idx][15:8]  <= wr_data[15:8];
        if (wr_strb[2]) bank_b[wr_addr_idx][23:16] <= wr_data[23:16];
        if (wr_strb[3]) bank_b[wr_addr_idx][31:24] <= wr_data[31:24];
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_data <= 32'h0;
    end else if (rd_en) begin
      if (!rd_in_range) begin
        rd_data <= 32'h0;
      end else if (!bank_sel_pp) begin
        rd_data <= bank_a[rd_addr_idx];
      end else begin
        rd_data <= bank_b[rd_addr_idx];
      end
    end
  end
`endif

`ifndef SYNTHESIS
`ifdef VCS
  // SVA_FMAP_WR_OOB_NO_WRITE is structurally implemented by wr_in_range
  // gating all bank writes. These assertions document the intended guard.
  property SVA_FMAP_WORD_ADDR_IN_RANGE;
    @(posedge clk) disable iff (!rst_n)
      rd_en |-> (rd_word_addr < P_BANK_WORDS);
  endproperty
  assert property (SVA_FMAP_WORD_ADDR_IN_RANGE);

  property SVA_FMAP_NO_CROSS_BANK_WRITE_A;
    @(posedge clk) disable iff (!rst_n)
      (wr_en && wr_in_range && !wr_bank_sel) |-> $stable(bank_b[wr_addr_idx]);
  endproperty
  assert property (SVA_FMAP_NO_CROSS_BANK_WRITE_A);
`endif
`endif

endmodule
