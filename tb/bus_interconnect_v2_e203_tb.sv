`timescale 1ns/1ps
//======================================================================
// 文件名: tb/bus_interconnect_v2_e203_tb.sv
//
// DUT: `rtl/bus/bus_interconnect_v2_e203.sv`
//
// 验证要点（Phase A-1 Gate）：
//   T1  地址译码：4 个合法窗口（INSTR/DATA/UART/V2B）+ miss 地址各发 1 笔
//   T2  V1-like 写读回路：每个 slave 顺序 write+read 验证 1-cycle 固定延迟
//   T3  V2B 路径：mock adapter 行为（写 1 拍 m_ready，读 2 拍 m_rvalid），
//       TB 发 V2B write / read，检查响应延迟和数据
//   T4  混合交易：V1-like 和 V2B 交替，验证 single-outstanding 不干扰
//   T5  miss 地址：发非法地址，确认不产生 m_ready/m_rvalid（避免总线锁死）
//
// PASS 标志：`BUS_INTERCONNECT_V2_E203_PASS`
//======================================================================
module bus_interconnect_v2_e203_tb;

  import snn_soc_pkg::*;

  logic clk;
  logic rst_n;

  // ── Master signals ─────────────────────────────────────────────────
  logic        m_valid;
  logic        m_write;
  logic [31:0] m_addr;
  logic [31:0] m_wdata;
  logic [3:0]  m_wstrb;
  logic        m_ready;
  logic [31:0] m_rdata;
  logic        m_rvalid;

  // ── V1-like slave signals（behavioral SRAM, 8-word 即可）───────────
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

  // ── V2B adapter mock signals ───────────────────────────────────────
  logic        v2b_m_valid, v2b_m_write;
  logic [31:0] v2b_m_addr,  v2b_m_wdata;
  logic [3:0]  v2b_m_wstrb;
  logic        v2b_m_ready;
  logic [31:0] v2b_m_rdata;
  logic        v2b_m_rvalid;

  // ── Error counter ──────────────────────────────────────────────────
  int errors;

  // ── DUT ────────────────────────────────────────────────────────────
  bus_interconnect_v2_e203 dut (
    .clk(clk), .rst_n(rst_n),
    .m_valid(m_valid), .m_write(m_write), .m_addr(m_addr),
    .m_wdata(m_wdata), .m_wstrb(m_wstrb),
    .m_ready(m_ready), .m_rdata(m_rdata), .m_rvalid(m_rvalid),
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

  // ── Clock ──────────────────────────────────────────────────────────
  initial clk = 0;
  always #5 clk = ~clk;  // 100 MHz

  // ── V1-like mock SRAMs：同步写、组合读（满足 fabric 期望）─────────
  // 每个 slave 4 个 word，地址低 4 位 [3:2] 索引
  logic [31:0] instr_mem [0:3];
  logic [31:0] data_mem  [0:3];
  logic [31:0] uart_mem  [0:3];

  // 组合读（请求当拍返回）
  assign instr_rdata = instr_mem[instr_req_addr[3:2]];
  assign data_rdata  = data_mem [data_req_addr[3:2]];
  assign uart_rdata  = uart_mem [uart_req_addr[3:2]];

  always_ff @(posedge clk) begin
    if (instr_req_valid && instr_req_write) instr_mem[instr_req_addr[3:2]] <= instr_req_wdata;
    if (data_req_valid  && data_req_write ) data_mem [data_req_addr [3:2]] <= data_req_wdata;
    if (uart_req_valid  && uart_req_write ) uart_mem [uart_req_addr [3:2]] <= uart_req_wdata;
  end

  // ── V2B adapter mock：模仿 simple2v2btop_adapter.sv FSM 时序 ─────────
  //   write: cycle 0 采 m_valid → cycle 1 拉 m_ready
  //   read:  cycle 0 采 m_valid → cycle 1 ADP_RD_WAIT → cycle 2 拉 m_rvalid + m_rdata
  typedef enum logic [1:0] {
    MOCK_IDLE    = 2'd0,
    MOCK_WR_ACK  = 2'd1,
    MOCK_RD_WAIT = 2'd2,
    MOCK_RD_DONE = 2'd3
  } mock_state_t;
  mock_state_t mock_state;
  logic [31:0] mock_q_addr;
  logic [31:0] mock_v2b_rdata_mem [0:3];  // V2B 内部 mock 存储

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mock_state  <= MOCK_IDLE;
      mock_q_addr <= 32'h0;
    end else begin
      case (mock_state)
        MOCK_IDLE: begin
          if (v2b_m_valid) begin
            mock_q_addr <= v2b_m_addr;
            if (v2b_m_write) begin
              mock_state <= MOCK_WR_ACK;
              // 写入本拍就落 mock_v2b_rdata_mem（模拟 adapter 内 v2b_top 当拍写）
              mock_v2b_rdata_mem[v2b_m_addr[3:2]] <= v2b_m_wdata;
            end else begin
              mock_state <= MOCK_RD_WAIT;
            end
          end
        end
        MOCK_WR_ACK:  mock_state <= MOCK_IDLE;
        MOCK_RD_WAIT: mock_state <= MOCK_RD_DONE;
        MOCK_RD_DONE: mock_state <= MOCK_IDLE;
        default:      mock_state <= MOCK_IDLE;
      endcase
    end
  end

  assign v2b_m_ready  = (mock_state == MOCK_WR_ACK);
  assign v2b_m_rvalid = (mock_state == MOCK_RD_DONE);
  assign v2b_m_rdata  = mock_v2b_rdata_mem[mock_q_addr[3:2]];

  wire tb_v1_ready  = dut.req_valid_q &&  dut.req_write_q;
  wire tb_v1_rvalid = dut.req_valid_q && !dut.req_write_q;

  always @(posedge clk) begin
    if (rst_n) begin
      if (tb_v1_ready && v2b_m_ready) begin
        $display("[ERR] v1_ready && v2b_m_ready same cycle");
        errors++;
      end
      if (tb_v1_rvalid && v2b_m_rvalid) begin
        $display("[ERR] v1_rvalid && v2b_m_rvalid same cycle");
        errors++;
      end
      if (m_ready && m_rvalid) begin
        $display("[ERR] m_ready && m_rvalid same cycle");
        errors++;
      end
    end
  end

  // ── Master-side bus tasks ──────────────────────────────────────────
  task automatic bus_write(input logic [31:0] addr, input logic [31:0] wdata,
                           input int max_wait);
    int waited;
    begin
      @(posedge clk);
      m_valid <= 1'b1;
      m_write <= 1'b1;
      m_addr  <= addr;
      m_wdata <= wdata;
      m_wstrb <= 4'hF;
      @(posedge clk);
      m_valid <= 1'b0;
      m_write <= 1'b0;
      m_addr  <= 32'h0;
      m_wdata <= 32'h0;
      m_wstrb <= 4'h0;
      waited = 0;
      // Wait for m_ready
      while (!m_ready && waited < max_wait) begin
        @(posedge clk);
        waited++;
      end
      if (!m_ready) begin
        $display("[ERR] bus_write addr=0x%08h timeout after %0d cycles", addr, max_wait);
        errors++;
      end
    end
  endtask

  task automatic bus_read(input logic [31:0] addr, output logic [31:0] rdata,
                          input int max_wait);
    int waited;
    begin
      @(posedge clk);
      m_valid <= 1'b1;
      m_write <= 1'b0;
      m_addr  <= addr;
      m_wstrb <= 4'h0;
      @(posedge clk);
      m_valid <= 1'b0;
      m_addr  <= 32'h0;
      waited = 0;
      while (!m_rvalid && waited < max_wait) begin
        @(posedge clk);
        waited++;
      end
      if (!m_rvalid) begin
        $display("[ERR] bus_read addr=0x%08h timeout after %0d cycles", addr, max_wait);
        errors++;
        rdata = 32'hDEADBEEF;
      end else begin
        rdata = m_rdata;
      end
    end
  endtask

  // ── Wait-for-miss：发 m_valid 后，N 拍内不应出现 m_ready/m_rvalid ──
  task automatic bus_expect_miss(input logic [31:0] addr, input int check_cycles);
    int n;
    bit saw_resp;
    begin
      saw_resp = 0;
      @(posedge clk);
      m_valid <= 1'b1;
      m_write <= 1'b0;  // 读 miss 更严格
      m_addr  <= addr;
      m_wstrb <= 4'h0;
      @(posedge clk);
      m_valid <= 1'b0;
      m_addr  <= 32'h0;
      for (n = 0; n < check_cycles; n++) begin
        if (m_ready || m_rvalid) begin
          $display("[ERR] bus_expect_miss addr=0x%08h got response in %0d cycles (m_ready=%b m_rvalid=%b)",
                   addr, n, m_ready, m_rvalid);
          errors++;
          saw_resp = 1;
        end
        @(posedge clk);
      end
      if (!saw_resp) $display("[INFO] miss addr=0x%08h correctly had no response in %0d cycles", addr, check_cycles);
    end
  endtask

  // ── Main ───────────────────────────────────────────────────────────
  logic [31:0] rd;

  initial begin
    $dumpfile("waves/bus_interconnect_v2_e203.vcd");
    $dumpvars(0, bus_interconnect_v2_e203_tb);
  end

  initial begin
    errors  = 0;
    rst_n   = 0;
    m_valid = 0;
    m_write = 0;
    m_addr  = 0;
    m_wdata = 0;
    m_wstrb = 0;
    for (int i = 0; i < 4; i++) begin
      instr_mem[i] = 32'h0;
      data_mem[i]  = 32'h0;
      uart_mem[i]  = 32'h0;
      mock_v2b_rdata_mem[i] = 32'h0;
    end
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // ── T1+T2: V1-like slave write+read（INSTR）──────────────────────
    $display("[T2] INSTR slave write+read");
    bus_write(ADDR_V2E203_INSTR_BASE + 32'h0, 32'hCAFE0001, 8);
    bus_write(ADDR_V2E203_INSTR_BASE + 32'h4, 32'hCAFE0002, 8);
    bus_read (ADDR_V2E203_INSTR_BASE + 32'h0, rd, 8);
    if (rd !== 32'hCAFE0001) begin $display("[ERR] INSTR readback 0 = 0x%08h", rd); errors++; end
    bus_read (ADDR_V2E203_INSTR_BASE + 32'h4, rd, 8);
    if (rd !== 32'hCAFE0002) begin $display("[ERR] INSTR readback 1 = 0x%08h", rd); errors++; end

    // ── T2: DATA slave write+read ────────────────────────────────────
    $display("[T2] DATA slave write+read");
    bus_write(ADDR_V2E203_DATA_BASE + 32'h8, 32'hD474_0001, 8);
    bus_read (ADDR_V2E203_DATA_BASE + 32'h8, rd, 8);
    if (rd !== 32'hD474_0001) begin $display("[ERR] DATA readback = 0x%08h", rd); errors++; end

    // ── T2: UART slave write+read ────────────────────────────────────
    $display("[T2] UART slave write+read");
    bus_write(ADDR_V2E203_UART_BASE + 32'h0, 32'h0000_00AA, 8);
    bus_read (ADDR_V2E203_UART_BASE + 32'h0, rd, 8);
    if (rd !== 32'h0000_00AA) begin $display("[ERR] UART readback = 0x%08h", rd); errors++; end

    // ── T3: V2B 路径 write+read（mock adapter 延迟 1/2 cycle）────────
    $display("[T3] V2B path write+read (wait-state)");
    bus_write(ADDR_V2B_BASE + 32'h0, 32'hA000_0001, 8);
    bus_write(ADDR_V2B_BASE + 32'h4, 32'hA000_0002, 8);
    bus_read (ADDR_V2B_BASE + 32'h0, rd, 8);
    if (rd !== 32'hA000_0001) begin $display("[ERR] V2B readback 0 = 0x%08h", rd); errors++; end
    bus_read (ADDR_V2B_BASE + 32'h4, rd, 8);
    if (rd !== 32'hA000_0002) begin $display("[ERR] V2B readback 1 = 0x%08h", rd); errors++; end

    // ── T4: 混合交易 INSTR → V2B → UART → V2B → DATA ─────────────────
    $display("[T4] mixed traffic V1-like + V2B 交替");
    bus_write(ADDR_V2E203_INSTR_BASE + 32'h8, 32'h1234_0001, 8);
    bus_write(ADDR_V2B_BASE          + 32'h8, 32'hFACE_0001, 8);
    bus_write(ADDR_V2E203_UART_BASE  + 32'h4, 32'hAAAA_0001, 8);
    bus_write(ADDR_V2B_BASE          + 32'hC, 32'hFACE_0002, 8);
    bus_write(ADDR_V2E203_DATA_BASE  + 32'h0, 32'hDDDD_0001, 8);

    bus_read (ADDR_V2E203_INSTR_BASE + 32'h8, rd, 8);
    if (rd !== 32'h1234_0001) begin $display("[ERR] mix INSTR readback = 0x%08h", rd); errors++; end
    bus_read (ADDR_V2B_BASE          + 32'h8, rd, 8);
    if (rd !== 32'hFACE_0001) begin $display("[ERR] mix V2B[8] readback = 0x%08h", rd); errors++; end
    bus_read (ADDR_V2E203_UART_BASE  + 32'h4, rd, 8);
    if (rd !== 32'hAAAA_0001) begin $display("[ERR] mix UART readback = 0x%08h", rd); errors++; end
    bus_read (ADDR_V2B_BASE          + 32'hC, rd, 8);
    if (rd !== 32'hFACE_0002) begin $display("[ERR] mix V2B[C] readback = 0x%08h", rd); errors++; end
    bus_read (ADDR_V2E203_DATA_BASE  + 32'h0, rd, 8);
    if (rd !== 32'hDDDD_0001) begin $display("[ERR] mix DATA readback = 0x%08h", rd); errors++; end

    // ── T5: miss 地址应无 fabric 响应；A-2 bridge 负责提前返回 ICB error ──
    $display("[T5] miss address -> no fabric response");
    bus_expect_miss(32'h5000_0000, 16);
    bus_expect_miss(32'h0003_0000, 16);  // INSTR_END+1 ~ DATA_BASE-1 的 gap
    bus_expect_miss(ADDR_V2E203_UART_END + 32'h1, 16);
    bus_expect_miss(ADDR_V2B_END + 32'h1, 16);

    // ── Summary ──────────────────────────────────────────────────────
    repeat (4) @(posedge clk);
    if (errors == 0) begin
      $display("BUS_INTERCONNECT_V2_E203_PASS");
    end else begin
      $display("BUS_INTERCONNECT_V2_E203_FAIL errors=%0d", errors);
      $fatal(1);
    end
    $finish;
  end

  initial begin
    #100000;
    $display("[ERR] global timeout");
    $fatal(1);
  end

endmodule
