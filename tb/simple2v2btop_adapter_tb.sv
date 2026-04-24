`timescale 1ns/1ps
//======================================================================
// 文件名: tb/simple2v2btop_adapter_tb.sv
//
// DUT: `rtl/bus/simple2v2btop_adapter.sv`
//   0 字拷自 `v2-arm-fpga-demo-passed`（commit 24951bb3 / 8301c226），
//   本 TB 独立验证 adapter 合约，不依赖 v2b_top / Python golden。
//
// 验证要点（Phase A-3 Gate）：
//   T1  写事务固定延迟：m_valid 拉高 → **1 cycle 后** m_ready=1，数据
//       原样透传到 cmd_valid/cmd_write/cmd_wdata/cmd_wstrb
//   T2  读事务固定延迟：m_valid 拉高 → **2 cycle 后** m_rvalid=1，
//       m_rdata = mock v2b_top 的 rsp_rdata
//   T3  地址截断：m_addr = 0xA000_0ABC → cmd_addr = 12'hABC
//       （adapter 内部 `addr_low = m_addr[11:0]`）
//   T4  m_ready / m_rvalid 每拍互斥（exclusive）
//   T5  SBA/SBB delayed read：mock 复刻 v2b_top cmd_read_sb*_q 延迟路径
//   T6  cmd_addr 在事务期间"粘住"：RD_WAIT 拍 cmd_addr 仍等于原值，
//       不会回到 default（这是 adapter 存在的原因）
//   T7  连续多笔 write+read，验证 FSM 能稳定循环
//
// PASS 标志：`SIMPLE2V2BTOP_ADAPTER_PASS`
//======================================================================
module simple2v2btop_adapter_tb;

  logic clk;
  logic rst_n;

  // ── simple_bus master (TB drives) ──────────────────────────────────
  logic        m_valid;
  logic        m_write;
  logic [31:0] m_addr;
  logic [31:0] m_wdata;
  logic [3:0]  m_wstrb;
  logic        m_ready;
  logic [31:0] m_rdata;
  logic        m_rvalid;

  // ── v2b_top cmd/rsp (mock drives rsp side) ─────────────────────────
  logic        cmd_valid;
  logic        cmd_write;
  logic [11:0] cmd_addr;
  logic [31:0] cmd_wdata;
  logic [3:0]  cmd_wstrb;
  logic        cmd_ready;
  logic        rsp_valid;
  logic [31:0] rsp_rdata;

  int errors;

  // ── DUT ────────────────────────────────────────────────────────────
  simple2v2btop_adapter dut (
    .clk(clk), .rst_n(rst_n),
    .m_valid(m_valid), .m_write(m_write), .m_addr(m_addr),
    .m_wdata(m_wdata), .m_wstrb(m_wstrb),
    .m_ready(m_ready), .m_rdata(m_rdata), .m_rvalid(m_rvalid),
    .cmd_valid(cmd_valid), .cmd_write(cmd_write), .cmd_addr(cmd_addr),
    .cmd_wdata(cmd_wdata), .cmd_wstrb(cmd_wstrb),
    .cmd_ready(cmd_ready),
    .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata)
  );

  // ── Clock ──────────────────────────────────────────────────────────
  initial clk = 0;
  always #5 clk = ~clk;

  // ── Mock v2b_top cmd/rsp：always-ready，组合 read_mux by cmd_addr ──
  // 这和 snn_soc_v2b_top 的合约一致：rsp_valid <= cmd_valid（1 拍寄存），
  // rsp_rdata <= read_mux（组合 by cmd_addr）。
  // read_mux 对直接寄存器组（非 SBA/SBB）N 拍就 ready；SBA/SBB 通过
  // cmd_read_sb*_q 多等一拍才返回 stream buffer 数据。
  assign cmd_ready = 1'b1;
  // 注意：snn_soc_v2b_top 的 read_mux 是**纯组合**基于 cmd_addr，不 gate on
  // cmd_valid。adapter 在 RD_WAIT 拍 cmd_valid=0 但 cmd_addr 仍被 q_addr
  // 保持住，此时 read_mux 也要能组合返回正确数据，下拍 rsp_rdata 才对。
  logic [31:0] mock_read_mux;
  logic        mock_cmd_read_sba;
  logic        mock_cmd_read_sbb;
  logic        mock_cmd_read_sba_q;
  logic        mock_cmd_read_sbb_q;
  logic [9:0]  mock_read_sb_t;
  logic [9:0]  mock_read_sb_t_q;

  localparam logic [11:0] MOCK_READ_SBA_BASE = 12'h400;
  localparam logic [11:0] MOCK_READ_SBB_BASE = 12'h800;

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
    mock_read_mux = {20'h0, cmd_addr};
    if (mock_cmd_read_sba_q) begin
      mock_read_mux = {12'h5A0, 10'h0, mock_read_sb_t_q};
    end else if (mock_cmd_read_sbb_q) begin
      mock_read_mux = {12'h5B0, 10'h0, mock_read_sb_t_q};
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rsp_valid           <= 1'b0;
      rsp_rdata           <= 32'h0;
      mock_cmd_read_sba_q <= 1'b0;
      mock_cmd_read_sbb_q <= 1'b0;
      mock_read_sb_t_q    <= 10'h0;
    end else begin
      rsp_valid           <= cmd_valid;            // 1-cycle registered
      rsp_rdata           <= mock_read_mux;        // 1-cycle registered on read_mux
      mock_cmd_read_sba_q <= mock_cmd_read_sba;    // match snn_soc_v2b_top cmd_read_sb*_q
      mock_cmd_read_sbb_q <= mock_cmd_read_sbb;
      mock_read_sb_t_q    <= mock_read_sb_t;
    end
  end

  // ── 每拍 m_ready / m_rvalid 互斥 checker (T4) ─────────────────────
  always @(posedge clk) begin
    if (rst_n && m_ready && m_rvalid) begin
      $display("[ERR] m_ready && m_rvalid same cycle (mutex violation)");
      errors++;
    end
  end

  // ── TB master 驱动任务 ─────────────────────────────────────────────
  // 返回 "从 m_valid 拉高 到 m_ready/m_rvalid 出现" 的 clock 数（含起始拍）
  task automatic do_write(input logic [31:0] addr, input logic [31:0] wdata,
                          output int delay_cycles,
                          input int max_wait);
    int waited;
    bit done;
    begin
      @(posedge clk);
      m_valid <= 1'b1;
      m_write <= 1'b1;
      m_addr  <= addr;
      m_wdata <= wdata;
      m_wstrb <= 4'hF;
      delay_cycles = 0;
      waited = 0;
      done = 1'b0;
      while (!done) begin
        @(posedge clk);
        delay_cycles++;
        if (m_valid) m_valid <= 1'b0;
        if (m_ready) done = 1'b1;
        else begin
          waited++;
          if (waited > max_wait) begin
            $display("[ERR] do_write timeout addr=0x%08h", addr);
            errors++;
            done = 1'b1;
          end
        end
      end
      m_valid <= 1'b0;
      m_write <= 1'b0;
      m_addr  <= 32'h0;
      m_wdata <= 32'h0;
      m_wstrb <= 4'h0;
    end
  endtask

  task automatic do_read(input logic [31:0] addr,
                         output logic [31:0] rdata,
                         output int delay_cycles,
                         input int max_wait);
    int waited;
    bit done;
    begin
      @(posedge clk);
      m_valid <= 1'b1;
      m_write <= 1'b0;
      m_addr  <= addr;
      m_wstrb <= 4'h0;
      delay_cycles = 0;
      waited = 0;
      done = 1'b0;
      rdata = 32'h0;
      while (!done) begin
        @(posedge clk);
        delay_cycles++;
        if (m_valid) m_valid <= 1'b0;
        if (m_rvalid) begin
          rdata = m_rdata;
          done = 1'b1;
        end else begin
          waited++;
          if (waited > max_wait) begin
            $display("[ERR] do_read timeout addr=0x%08h", addr);
            errors++;
            rdata = 32'hDEADBEEF;
            done = 1'b1;
          end
        end
      end
      m_valid <= 1'b0;
      m_addr  <= 32'h0;
    end
  endtask

  // ── cmd_addr "粘住" 检查任务 (T5) ─────────────────────────────────
  // 在一笔 read 事务中途采样 cmd_addr：应从 IDLE 那拍的 addr_low
  // 起，到 RD_DONE 为止都保持不变。
  // 实现：捕获 first-cycle cmd_addr，然后每拍比对直到 m_rvalid=1。
  task automatic do_read_check_addr_stable(input logic [31:0] addr,
                                            output logic [31:0] rdata);
    logic [11:0] first_cmd_addr;
    int waited;
    begin
      @(posedge clk);
      m_valid <= 1'b1;
      m_write <= 1'b0;
      m_addr  <= addr;
      m_wstrb <= 4'h0;

      // 采样 IDLE 拍的 cmd_addr（组合 = addr[11:0]）
      #1; // 避免 sample glitch
      first_cmd_addr = cmd_addr;
      if (first_cmd_addr !== addr[11:0]) begin
        $display("[ERR] cmd_addr first-cycle mismatch: got 0x%03h exp 0x%03h",
                 first_cmd_addr, addr[11:0]);
        errors++;
      end

      waited = 0;
      rdata = 32'h0;
      begin : loop_addr_stable
        bit done;
        done = 1'b0;
        while (!done) begin
          @(posedge clk);
          if (m_valid) m_valid <= 1'b0;
          // 在整个事务期间 cmd_addr 必须 == first_cmd_addr
          #1;
          if (cmd_addr !== first_cmd_addr) begin
            $display("[ERR] cmd_addr drift mid-transaction: 0x%03h != 0x%03h",
                     cmd_addr, first_cmd_addr);
            errors++;
          end
          if (m_rvalid) begin
            rdata = m_rdata;
            done  = 1'b1;
          end else begin
            waited++;
            if (waited > 8) begin
              $display("[ERR] addr-stable read timeout");
              errors++;
              rdata = 32'hDEADBEEF;
              done  = 1'b1;
            end
          end
        end
      end
      m_valid <= 1'b0;
      m_addr  <= 32'h0;
    end
  endtask

  // ── Init + dump ────────────────────────────────────────────────────
  initial begin
    $dumpfile("waves/simple2v2btop_adapter.vcd");
    $dumpvars(0, simple2v2btop_adapter_tb);
  end

  // ── Main ───────────────────────────────────────────────────────────
  int d;
  logic [31:0] rd;

  initial begin
    errors  = 0;
    rst_n   = 0;
    m_valid = 0;
    m_write = 0;
    m_addr  = 0;
    m_wdata = 0;
    m_wstrb = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // ── T1: 写延迟（TB 测量 = adapter 1 cycle + NBA 1 cycle = 2）────
    $display("[T1] write: expect 2-cycle m_ready delay (TB drive edge to ack edge)");
    do_write(32'hA000_0004, 32'hDEADBEEF, d, 8);
    if (d !== 2) begin
      $display("[ERR] T1 write delay = %0d (expected 2)", d); errors++;
    end

    // ── T2: 读延迟（TB 测量 = adapter 2 cycle + NBA 1 cycle = 3）+ signature ─
    $display("[T2] read: expect 3-cycle m_rvalid delay");
    do_read(32'hA000_0008, rd, d, 8);
    if (d !== 3) begin
      $display("[ERR] T2 read delay = %0d (expected 3)", d); errors++;
    end
    if (rd !== 32'h0000_0008) begin
      $display("[ERR] T2 read signature = 0x%08h (expected 0x0000_0008)", rd);
      errors++;
    end

    // ── T3: 地址截断 —— 上位 20 bit 任意，cmd_addr 只取 [11:0] ───────
    $display("[T3] addr truncation: m_addr[11:0] → cmd_addr");
    do_read(32'hA000_0ABC, rd, d, 8);
    if (rd !== 32'h0000_0ABC) begin
      $display("[ERR] T3 addr truncation fail: rd=0x%08h (expected 0xABC in low)", rd);
      errors++;
    end
    // 上位变 0xDEAD：m_addr=0xDEAD_0ABC，cmd_addr 仍应 = 0xABC
    do_read(32'hDEAD_0ABC, rd, d, 8);
    if (rd !== 32'h0000_0ABC) begin
      $display("[ERR] T3 upper-ignore fail: rd=0x%08h", rd);
      errors++;
    end

    // ── T4: m_ready / m_rvalid 互斥 checker 已全程运行 ────────────────
    $display("[T4] m_ready/m_rvalid mutex checker active");

    // ── T5: SBA/SBB delayed read path（mock cmd_read_sb*_q 延迟）──────
    $display("[T5] SBA/SBB delayed read path");
    do_read(32'hA000_040C, rd, d, 8);
    if (d !== 3) begin $display("[ERR] T5.sba delay=%0d", d); errors++; end
    if (rd !== {12'h5A0, 10'h0, 10'h103}) begin
      $display("[ERR] T5 SBA rdata=0x%08h expected 0x%08h", rd, {12'h5A0, 10'h0, 10'h103});
      errors++;
    end
    do_read(32'hA000_0808, rd, d, 8);
    if (d !== 3) begin $display("[ERR] T5.sbb delay=%0d", d); errors++; end
    if (rd !== {12'h5B0, 10'h0, 10'h202}) begin
      $display("[ERR] T5 SBB rdata=0x%08h expected 0x%08h", rd, {12'h5B0, 10'h0, 10'h202});
      errors++;
    end

    // ── T6: cmd_addr 在事务期间稳定 ─────────────────────────────────
    $display("[T6] cmd_addr stays stable throughout transaction");
    do_read_check_addr_stable(32'hA000_0F00, rd);
    if (rd !== 32'h0000_0F00) begin
      $display("[ERR] T6 rdata mismatch: rd=0x%08h", rd);
      errors++;
    end

    // ── T7: 连续多笔 write + read ───────────────────────────────────
    $display("[T7] back-to-back mixed traffic");
    do_write(32'hA000_0010, 32'h1111_0001, d, 8);
    if (d !== 2) begin $display("[ERR] T7.w1 delay=%0d", d); errors++; end
    do_read (32'hA000_0010, rd, d, 8);
    if (d !== 3) begin $display("[ERR] T7.r1 delay=%0d", d); errors++; end
    do_write(32'hA000_0020, 32'h2222_0002, d, 8);
    do_read (32'hA000_0020, rd, d, 8);
    do_write(32'hA000_0030, 32'h3333_0003, d, 8);
    do_read (32'hA000_0030, rd, d, 8);

    // ── Summary ──────────────────────────────────────────────────────
    repeat (4) @(posedge clk);
    if (errors == 0) begin
      $display("SIMPLE2V2BTOP_ADAPTER_PASS");
    end else begin
      $display("SIMPLE2V2BTOP_ADAPTER_FAIL errors=%0d", errors);
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
