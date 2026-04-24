`timescale 1ns/1ps
//======================================================================
// 文件名: tb/v2_e203_bus_chain_tb.sv
//
// Phase A-4 Gate：整条 bus 路径串联 co-sim
//   ICB master (TB)
//     → icb2simple_bridge_v2b (A-2, DUT)
//     → bus_interconnect_v2_e203 (A-1, DUT)
//     ├── mock INSTR SRAM (V1-like 1-cycle)
//     ├── mock DATA  SRAM
//     ├── mock UART
//     └── simple2v2btop_adapter (A-3, 0-diff DUT)
//            → mock v2b_top (always-ready + SBA/SBB 延迟路径)
//
// 必测（按用户指令）：
//   T1  合法 INSTR / DATA / UART read+write 回路
//   T2  合法 V2B direct-reg read+write
//   T3  合法 V2B SBA/SBB delayed-read
//   T4  V1 REG/DMA/SPI/FIFO/WEIGHT 地址必须 ICB rsp_err=1，且
//       INSTR/DATA/UART/v2b 各 slave 的 *_req_valid 全程不得 = 1
//   T5  MMIO 非 4B 对齐（UART+1, V2B+2）→ rsp_err
//   T6  每拍 m_ready/m_rvalid 互斥
//   T7  single-outstanding：ICB rsp_valid 未 ack 前不发下一笔
//
// PASS 标志：V2_E203_BUS_CHAIN_PASS
//======================================================================
module v2_e203_bus_chain_tb;

  import snn_soc_pkg::*;

  logic clk;
  logic rst_n;

  // ── ICB master (TB drives) ─────────────────────────────────────────
  logic        i_icb_cmd_valid;
  logic        i_icb_cmd_ready;
  logic [31:0] i_icb_cmd_addr;
  logic        i_icb_cmd_read;
  logic [31:0] i_icb_cmd_wdata;
  logic [3:0]  i_icb_cmd_wmask;
  logic        i_icb_rsp_valid;
  logic        i_icb_rsp_ready;
  logic        i_icb_rsp_err;
  logic [31:0] i_icb_rsp_rdata;

  // ── bridge ↔ fabric wires ──────────────────────────────────────────
  logic        br_m_valid;
  logic        br_m_write;
  logic [31:0] br_m_addr;
  logic [31:0] br_m_wdata;
  logic [3:0]  br_m_wstrb;
  logic        br_m_ready;
  logic [31:0] br_m_rdata;
  logic        br_m_rvalid;
  logic        br_busy;

  // ── fabric ↔ 4 slaves ──────────────────────────────────────────────
  logic        instr_req_valid, instr_req_write;
  logic [31:0] instr_req_addr,  instr_req_wdata;
  logic [3:0]  instr_req_wstrb;
  logic [31:0] instr_rdata;

  logic        data_req_valid,  data_req_write;
  logic [31:0] data_req_addr,   data_req_wdata;
  logic [3:0]  data_req_wstrb;
  logic [31:0] data_rdata;

  logic        uart_req_valid,  uart_req_write;
  logic [31:0] uart_req_addr,   uart_req_wdata;
  logic [3:0]  uart_req_wstrb;
  logic [31:0] uart_rdata;

  logic        v2b_m_valid, v2b_m_write;
  logic [31:0] v2b_m_addr,  v2b_m_wdata;
  logic [3:0]  v2b_m_wstrb;
  logic        v2b_m_ready, v2b_m_rvalid;
  logic [31:0] v2b_m_rdata;

  // ── adapter ↔ v2b_top mock ─────────────────────────────────────────
  logic        cmd_valid, cmd_write;
  logic [11:0] cmd_addr;
  logic [31:0] cmd_wdata;
  logic [3:0]  cmd_wstrb;
  logic        cmd_ready;
  logic        rsp_valid;
  logic [31:0] rsp_rdata;

  int errors;

  // ── DUT 1: icb2simple_bridge_v2b ────────────────────────────────────
  icb2simple_bridge_v2b u_bridge (
    .clk(clk), .rst_n(rst_n),
    .i_icb_cmd_valid(i_icb_cmd_valid), .i_icb_cmd_ready(i_icb_cmd_ready),
    .i_icb_cmd_addr(i_icb_cmd_addr),   .i_icb_cmd_read(i_icb_cmd_read),
    .i_icb_cmd_wdata(i_icb_cmd_wdata), .i_icb_cmd_wmask(i_icb_cmd_wmask),
    .i_icb_rsp_valid(i_icb_rsp_valid), .i_icb_rsp_ready(i_icb_rsp_ready),
    .i_icb_rsp_err(i_icb_rsp_err),     .i_icb_rsp_rdata(i_icb_rsp_rdata),
    .m_valid(br_m_valid), .m_write(br_m_write), .m_addr(br_m_addr),
    .m_wdata(br_m_wdata), .m_wstrb(br_m_wstrb),
    .m_ready(br_m_ready), .m_rdata(br_m_rdata), .m_rvalid(br_m_rvalid),
    .busy_o(br_busy)
  );

  // ── DUT 2: bus_interconnect_v2_e203 ─────────────────────────────────
  bus_interconnect_v2_e203 u_fabric (
    .clk(clk), .rst_n(rst_n),
    .m_valid(br_m_valid), .m_write(br_m_write), .m_addr(br_m_addr),
    .m_wdata(br_m_wdata), .m_wstrb(br_m_wstrb),
    .m_ready(br_m_ready), .m_rdata(br_m_rdata), .m_rvalid(br_m_rvalid),
    .instr_req_valid(instr_req_valid), .instr_req_write(instr_req_write),
    .instr_req_addr(instr_req_addr),   .instr_req_wdata(instr_req_wdata),
    .instr_req_wstrb(instr_req_wstrb), .instr_rdata(instr_rdata),
    .data_req_valid(data_req_valid),   .data_req_write(data_req_write),
    .data_req_addr(data_req_addr),     .data_req_wdata(data_req_wdata),
    .data_req_wstrb(data_req_wstrb),   .data_rdata(data_rdata),
    .uart_req_valid(uart_req_valid),   .uart_req_write(uart_req_write),
    .uart_req_addr(uart_req_addr),     .uart_req_wdata(uart_req_wdata),
    .uart_req_wstrb(uart_req_wstrb),   .uart_rdata(uart_rdata),
    .v2b_m_valid(v2b_m_valid), .v2b_m_write(v2b_m_write),
    .v2b_m_addr(v2b_m_addr),   .v2b_m_wdata(v2b_m_wdata),
    .v2b_m_wstrb(v2b_m_wstrb),
    .v2b_m_ready(v2b_m_ready), .v2b_m_rdata(v2b_m_rdata),
    .v2b_m_rvalid(v2b_m_rvalid)
  );

  // ── DUT 3: simple2v2btop_adapter (0-diff copy) ──────────────────────
  simple2v2btop_adapter u_adapter (
    .clk(clk), .rst_n(rst_n),
    .m_valid(v2b_m_valid), .m_write(v2b_m_write), .m_addr(v2b_m_addr),
    .m_wdata(v2b_m_wdata), .m_wstrb(v2b_m_wstrb),
    .m_ready(v2b_m_ready), .m_rdata(v2b_m_rdata), .m_rvalid(v2b_m_rvalid),
    .cmd_valid(cmd_valid), .cmd_write(cmd_write), .cmd_addr(cmd_addr),
    .cmd_wdata(cmd_wdata), .cmd_wstrb(cmd_wstrb),
    .cmd_ready(cmd_ready),
    .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata)
  );

  // ── Clock ──────────────────────────────────────────────────────────
  initial clk = 0;
  always #5 clk = ~clk;

  // ── Mock INSTR / DATA / UART SRAMs（4-word 循环寻址） ─────────────
  logic [31:0] instr_mem [0:3];
  logic [31:0] data_mem  [0:3];
  logic [31:0] uart_mem  [0:3];

  assign instr_rdata = instr_mem[instr_req_addr[3:2]];
  assign data_rdata  = data_mem [data_req_addr[3:2]];
  assign uart_rdata  = uart_mem [uart_req_addr[3:2]];

  always_ff @(posedge clk) begin
    if (instr_req_valid && instr_req_write) instr_mem[instr_req_addr[3:2]] <= instr_req_wdata;
    if (data_req_valid  && data_req_write ) data_mem [data_req_addr [3:2]] <= data_req_wdata;
    if (uart_req_valid  && uart_req_write ) uart_mem [uart_req_addr [3:2]] <= uart_req_wdata;
  end

  // ── Mock v2b_top cmd/rsp：direct-reg + SBA/SBB 延迟路径 ─────────────
  assign cmd_ready = 1'b1;
  localparam logic [11:0] MOCK_READ_SBA_BASE = 12'h400;
  localparam logic [11:0] MOCK_READ_SBB_BASE = 12'h800;

  logic [31:0] mock_read_mux;
  logic        mock_cmd_read_sba, mock_cmd_read_sbb;
  logic        mock_cmd_read_sba_q, mock_cmd_read_sbb_q;
  logic [9:0]  mock_read_sb_t, mock_read_sb_t_q;

  always @* begin
    mock_cmd_read_sba = 1'b0;
    mock_cmd_read_sbb = 1'b0;
    mock_read_sb_t    = 10'h0;
    if (cmd_valid && !cmd_write) begin
      if ((cmd_addr & 12'hF00) == MOCK_READ_SBA_BASE) begin
        mock_cmd_read_sba = 1'b1;
        mock_read_sb_t    = cmd_addr[11:2];
      end else if ((cmd_addr & 12'hF00) == MOCK_READ_SBB_BASE) begin
        mock_cmd_read_sbb = 1'b1;
        mock_read_sb_t    = cmd_addr[11:2];
      end
    end
  end

  always @* begin
    mock_read_mux = {20'h0, cmd_addr};   // direct-reg signature
    if (mock_cmd_read_sba_q) mock_read_mux = {12'h5A0, 10'h0, mock_read_sb_t_q};
    else if (mock_cmd_read_sbb_q) mock_read_mux = {12'h5B0, 10'h0, mock_read_sb_t_q};
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rsp_valid <= 1'b0;
      rsp_rdata <= 32'h0;
      mock_cmd_read_sba_q <= 1'b0;
      mock_cmd_read_sbb_q <= 1'b0;
      mock_read_sb_t_q    <= 10'h0;
    end else begin
      rsp_valid <= cmd_valid;
      rsp_rdata <= mock_read_mux;
      mock_cmd_read_sba_q <= mock_cmd_read_sba;
      mock_cmd_read_sbb_q <= mock_cmd_read_sbb;
      mock_read_sb_t_q    <= mock_read_sb_t;
    end
  end

  // ── 互斥 & leakage checker（Icarus 跑得到）─────────────────────────
  bit illegal_watch_arm;  // 非法事务期间 arm
  always @(posedge clk) begin
    if (rst_n) begin
      // Mutex
      if (br_m_ready && br_m_rvalid) begin
        $display("[ERR] chain: br_m_ready && br_m_rvalid same cycle"); errors++;
      end
      if (v2b_m_ready && v2b_m_rvalid) begin
        $display("[ERR] chain: v2b_m_ready && v2b_m_rvalid same cycle"); errors++;
      end
      // Illegal-address leakage watchdog
      if (illegal_watch_arm && (instr_req_valid || data_req_valid || uart_req_valid || v2b_m_valid || br_m_valid)) begin
        $display("[ERR] illegal addr LEAKED to fabric/adapter: instr_v=%b data_v=%b uart_v=%b v2b_v=%b br_v=%b",
                 instr_req_valid, data_req_valid, uart_req_valid, v2b_m_valid, br_m_valid);
        errors++;
      end
    end
  end

  // ── ICB 事务 task ──────────────────────────────────────────────────
  task automatic icb_cmd(input logic [31:0] addr,
                         input bit         is_read,
                         input logic [31:0] wdata,
                         input logic [3:0]  wmask,
                         output bit         rsp_err,
                         output logic [31:0] rsp_rdata_o,
                         input int max_wait);
    int waited;
    bit done;
    begin
      @(posedge clk);
      i_icb_cmd_valid <= 1'b1;
      i_icb_cmd_addr  <= addr;
      i_icb_cmd_read  <= is_read;
      i_icb_cmd_wdata <= wdata;
      i_icb_cmd_wmask <= wmask;
      // wait cmd_ready
      waited = 0;
      done = 1'b0;
      while (!done) begin
        if (i_icb_cmd_ready) done = 1'b1;
        else begin
          @(posedge clk);
          waited++;
          if (waited > max_wait) begin
            $display("[ERR] cmd_ready timeout addr=0x%08h", addr);
            errors++;
            done = 1'b1;
          end
        end
      end
      @(posedge clk);
      i_icb_cmd_valid <= 1'b0;
      // wait rsp_valid
      i_icb_rsp_ready <= 1'b1;
      waited = 0;
      done = 1'b0;
      while (!done) begin
        if (i_icb_rsp_valid) done = 1'b1;
        else begin
          @(posedge clk);
          waited++;
          if (waited > max_wait) begin
            $display("[ERR] rsp_valid timeout addr=0x%08h", addr);
            errors++;
            done = 1'b1;
          end
        end
      end
      rsp_err     = i_icb_rsp_err;
      rsp_rdata_o = i_icb_rsp_rdata;
      @(posedge clk);
      i_icb_rsp_ready <= 1'b0;
    end
  endtask

  task automatic expect_ok(input logic [31:0] addr, input bit is_read,
                            input logic [31:0] wdata,
                            output logic [31:0] rdata);
    bit err;
    begin
      illegal_watch_arm = 1'b0;
      icb_cmd(addr, is_read, wdata, 4'hF, err, rdata, 64);
      if (err) begin
        $display("[ERR] expect_ok but rsp_err=1 addr=0x%08h", addr); errors++;
      end
    end
  endtask

  task automatic expect_err(input logic [31:0] addr, input bit is_read);
    bit err;
    logic [31:0] rd;
    begin
      illegal_watch_arm = 1'b1;
      icb_cmd(addr, is_read, 32'hDEAD_BEEF, 4'hF, err, rd, 64);
      @(posedge clk);
      illegal_watch_arm = 1'b0;
      if (!err) begin
        $display("[ERR] expect_err but rsp_err=0 addr=0x%08h", addr); errors++;
      end
    end
  endtask

  // ── Init + dump ────────────────────────────────────────────────────
  initial begin
    $dumpfile("waves/v2_e203_bus_chain.vcd");
    $dumpvars(0, v2_e203_bus_chain_tb);
  end

  logic [31:0] rd;
  localparam logic [31:0] V2B_SBA_ADDR_T3 = ADDR_V2B_BASE + 32'h40C;  // SBA base + t=3 slot
  localparam logic [31:0] V2B_SBB_ADDR_T5 = ADDR_V2B_BASE + 32'h814;  // SBB base + t=5 slot

  initial begin
    errors          = 0;
    rst_n           = 0;
    i_icb_cmd_valid = 0;
    i_icb_cmd_addr  = 0;
    i_icb_cmd_read  = 0;
    i_icb_cmd_wdata = 0;
    i_icb_cmd_wmask = 0;
    i_icb_rsp_ready = 0;
    illegal_watch_arm = 0;
    for (int i = 0; i < 4; i++) begin
      instr_mem[i] = 0; data_mem[i] = 0; uart_mem[i] = 0;
    end
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // ── T1: INSTR / DATA / UART write + readback ────────────────────
    $display("[T1] INSTR/DATA/UART write+read");
    expect_ok(ADDR_V2E203_INSTR_BASE + 32'h0, 1'b0, 32'hCAFE_0001, rd);
    expect_ok(ADDR_V2E203_INSTR_BASE + 32'h0, 1'b1, 32'h0, rd);
    if (rd !== 32'hCAFE_0001) begin $display("[ERR] INSTR rd=0x%08h", rd); errors++; end

    expect_ok(ADDR_V2E203_DATA_BASE + 32'h4, 1'b0, 32'hD474_0001, rd);
    expect_ok(ADDR_V2E203_DATA_BASE + 32'h4, 1'b1, 32'h0, rd);
    if (rd !== 32'hD474_0001) begin $display("[ERR] DATA rd=0x%08h", rd); errors++; end

    expect_ok(ADDR_V2E203_UART_BASE + 32'h0, 1'b0, 32'h0000_00AA, rd);
    expect_ok(ADDR_V2E203_UART_BASE + 32'h0, 1'b1, 32'h0, rd);
    if (rd !== 32'h0000_00AA) begin $display("[ERR] UART rd=0x%08h", rd); errors++; end

    // ── T2: V2B direct-reg write + read ─────────────────────────────
    $display("[T2] V2B direct-reg write+read");
    expect_ok(ADDR_V2B_BASE + 32'h0,  1'b0, 32'hA000_0001, rd);
    // direct-reg read returns {20'h0, cmd_addr}
    expect_ok(ADDR_V2B_BASE + 32'h10, 1'b1, 32'h0, rd);
    if (rd !== {20'h0, 12'h010}) begin $display("[ERR] V2B direct rd=0x%08h (exp 0x010)", rd); errors++; end

    // ── T3: V2B SBA/SBB delayed-read ────────────────────────────────
    $display("[T3] V2B SBA/SBB delayed-read");
    expect_ok(V2B_SBA_ADDR_T3, 1'b1, 32'h0, rd);
    // mock signature: {12'h5A0, 10'h0, mock_read_sb_t_q}; sb_t = cmd_addr[11:2] = 12'h40C >> 2 = 0x103
    if (rd !== {12'h5A0, 10'h0, 10'h103}) begin $display("[ERR] V2B SBA rd=0x%08h", rd); errors++; end
    expect_ok(V2B_SBB_ADDR_T5, 1'b1, 32'h0, rd);
    // sb_t = 12'h814[11:2] = 0x205
    if (rd !== {12'h5B0, 10'h0, 10'h205}) begin $display("[ERR] V2B SBB rd=0x%08h", rd); errors++; end

    // ── T4: V1 legacy addresses must rsp_err + never leak to fabric ─
    $display("[T4] V1 legacy MMIO rejected, no fabric leakage");
    expect_err(32'h4000_0000, 1'b0);  // V1 REG_BANK
    expect_err(32'h4000_0100, 1'b1);  // V1 DMA
    expect_err(32'h4000_0200, 1'b0);  // V1 UART (0x4000_0200)
    expect_err(32'h4000_0300, 1'b0);  // V1 SPI
    expect_err(32'h4000_0400, 1'b1);  // V1 FIFO
    expect_err(32'h0003_0000, 1'b0);  // V1 WEIGHT_SRAM
    expect_err(32'h0200_0000, 1'b0);  // E203 CLINT; V2E203 UART must avoid it
    expect_err(32'hFFFF_0000, 1'b0);  // unmapped
    expect_err(ADDR_V2B_END + 32'h1, 1'b0);  // just past V2B window

    // ── T5: MMIO unaligned → rsp_err ────────────────────────────────
    $display("[T5] MMIO misaligned → rsp_err");
    expect_err(ADDR_V2E203_UART_BASE + 32'h1, 1'b0);
    expect_err(ADDR_V2B_BASE         + 32'h2, 1'b1);

    // ── T6: single outstanding sanity (back-to-back mix) ────────────
    $display("[T6] back-to-back mix");
    expect_ok(ADDR_V2E203_INSTR_BASE + 32'h8, 1'b0, 32'h1111_0001, rd);
    expect_ok(ADDR_V2B_BASE          + 32'h8, 1'b0, 32'hFACE_0008, rd);
    expect_ok(ADDR_V2E203_UART_BASE  + 32'h4, 1'b0, 32'hAAAA_0001, rd);
    expect_ok(V2B_SBA_ADDR_T3,                1'b1, 32'h0, rd);
    expect_ok(ADDR_V2E203_DATA_BASE  + 32'hC, 1'b1, 32'h0, rd);

    // ── Summary ──────────────────────────────────────────────────────
    repeat (4) @(posedge clk);
    if (errors == 0) begin
      $display("V2_E203_BUS_CHAIN_PASS");
    end else begin
      $display("V2_E203_BUS_CHAIN_FAIL errors=%0d", errors);
      $fatal(1);
    end
    $finish;
  end

  initial begin
    #500000;
    $display("[ERR] global timeout");
    $fatal(1);
  end

endmodule
