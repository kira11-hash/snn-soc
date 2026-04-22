`timescale 1ns/1ps
//======================================================================
// tb/v2b_primitive_reg_contract_tb.sv
//
// BLOCK-V2-02 regression (2026-04-22 GPT dual-line audit).
//
// 【问题背景】
// 旧版 `fw/include/v2b_primitives.h::v2b_run_streamed_stage()` 把 CFG4
// 写 weight_pos_addr、CFG5 写 weight_neg_addr、t_count 以 `(void)` 丢掉；
// 但标准 standalone V2.B RTL (`snn_soc_v2b_top.sv:45`) 定义 CFG5[15:0]=
// T_COUNT。因此固件用 descriptor path 会把 `weight_neg_addr`（典型值
// ≥ 256，常达 0x1000+）写到 CFG5[15:0]，stage_engine 解释为 cfg_t_count
// 超出 P_T_MAX=256 → 触发 ERR_DIM_OUT_OF_RANGE（或进入非法循环）。
//
// 本 TB 从 CPU 角度（直接走 snn_soc_v2b_top 的总线接口）锁死 3 条 invariant：
//
//   T1: 正确契约（CFG5=t_count）→ 设置 CFG0/1/2/3/4/5 后写 START，
//       BUSY 下降，ERR_CODE==ERR_OK。
//
//   T2: 旧 buggy 契约（CFG5=weight_neg_addr≈0x12340000 这种典型地址值）
//       → BUSY 下降，ERR_CODE==ERR_DIM_OUT_OF_RANGE (0x05)。证明一旦
//       固件误回到旧 layout，RTL 能立刻 reject 而不是悄悄跑出错误结果。
//
//   T3: CFG5=0（显式非法 t_count）→ ERR_DIM_OUT_OF_RANGE。
//
//   T4: CFG0 in_dim=0（显式非法）→ ERR_DIM_OUT_OF_RANGE。
//
// 每条 case 额外检查 FSM 能重新接受后续合法 START（非 wedge 证明）。
//======================================================================
module v2b_primitive_reg_contract_tb;

  import snn_soc_pkg::*;

  // V2B reg offsets (mirror snn_soc_v2b_top / v2b_soc_regs.h)
  localparam logic [11:0] A_STAGE_CTRL   = 12'h000;
  localparam logic [11:0] A_STAGE_STATUS = 12'h004;
  localparam logic [11:0] A_STAGE_CFG0   = 12'h008;
  localparam logic [11:0] A_STAGE_CFG1   = 12'h00C;
  localparam logic [11:0] A_STAGE_CFG2   = 12'h010;
  localparam logic [11:0] A_STAGE_CFG3   = 12'h014;
  localparam logic [11:0] A_STAGE_CFG4   = 12'h018;
  localparam logic [11:0] A_STAGE_CFG5   = 12'h01C;
  localparam logic [11:0] A_INPUT_SRAM_ADDR = 12'h020;
  localparam logic [11:0] A_INPUT_SRAM_W0   = 12'h024;
  localparam logic [11:0] A_INPUT_SRAM_CTRL = 12'h044;
  localparam logic [11:0] A_MAC_W_LOAD_ADDR = 12'h050;
  localparam logic [11:0] A_MAC_W_LOAD_DATA = 12'h054;
  localparam logic [11:0] A_MAC_W_LOAD_CTRL = 12'h058;

  // Reasonable small sanity scenario (borrowed from stage_engine_v2_tb)
  localparam int P_IN_DIM  = 4;
  localparam int P_OUT_DIM = 2;
  localparam int P_THRESH  = 40;
  localparam int P_SUM_MAX = 60;
  localparam int P_T       = 4;

  // ── Clock / reset ────────────────────────────────────────────────
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  // ── Bus wires ────────────────────────────────────────────────────
  logic        cmd_valid = 0;
  logic        cmd_ready;
  logic [11:0] cmd_addr  = '0;
  logic        cmd_write = 0;
  logic [31:0] cmd_wdata = '0;
  logic [3:0]  cmd_wstrb = 4'hF;
  logic        rsp_valid;
  logic [31:0] rsp_rdata;

  snn_soc_v2b_top #(
    .P_ENABLE_TILE_BUF(1),
    .P_ADC_BITS(10)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
    .cmd_addr(cmd_addr), .cmd_write(cmd_write),
    .cmd_wdata(cmd_wdata), .cmd_wstrb(cmd_wstrb),
    .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata)
  );

  // ── Bus helpers ──────────────────────────────────────────────────
  task automatic bus_write(input [11:0] addr, input [31:0] data);
    begin
      @(posedge clk);
      cmd_valid <= 1'b1;
      cmd_write <= 1'b1;
      cmd_addr  <= addr;
      cmd_wdata <= data;
      @(posedge clk);
      cmd_valid <= 1'b0;
    end
  endtask

  task automatic bus_read(input [11:0] addr, output [31:0] data);
    begin
      @(posedge clk);
      cmd_valid <= 1'b1;
      cmd_write <= 1'b0;
      cmd_addr  <= addr;
      @(posedge clk);
      cmd_valid <= 1'b0;
      @(posedge clk);
      @(posedge clk);
      data = rsp_rdata;
    end
  endtask

  task automatic wait_busy_clear(output bit done_ok, input int timeout_polls);
    int polls;
    logic [31:0] sts;
    begin : wb_body
      polls = 0;
      done_ok = 0;
      sts = 32'h1;
      while (sts[0] && polls < timeout_polls) begin
        bus_read(A_STAGE_STATUS, sts);
        polls = polls + 1;
      end
      done_ok = !sts[0];
    end
  endtask

  // Configure CFG0..5 matching the NEW primitive contract, then START and
  // return err_code.
  task automatic run_with_new_contract(
      input int in_dim, input int out_dim, input int threshold,
      input int sum_max, input int t_count,
      output logic [7:0] err,
      output bit completed
  );
    logic [31:0] cfg0, cfg3;
    logic [31:0] sts;
    bit ok;
    begin
      cfg0 = ((out_dim & 32'hFFFF) << 16) | (in_dim & 32'hFFFF);
      cfg3 = 32'h0;
      cfg3[1:0]  = V2B_BUF_SEL_INPUT_SRAM;
      cfg3[9:8]  = V2B_BUF_SEL_STREAM_A;
      cfg3[17]   = 1'b1;               // IS_TILE_FINAL (single tile)
      bus_write(A_STAGE_CFG0, cfg0);
      bus_write(A_STAGE_CFG1, threshold);
      bus_write(A_STAGE_CFG2, sum_max);
      bus_write(A_STAGE_CFG3, cfg3);
      bus_write(A_STAGE_CFG4, 32'h0);  // reserved per BLOCK-V2-02 fix
      bus_write(A_STAGE_CFG5, t_count);
      bus_write(A_STAGE_CTRL, 32'h1);  // START W1P
      wait_busy_clear(ok, 2000);
      completed = ok;
      bus_read(A_STAGE_STATUS, sts);
      err = sts[23:16];
      bus_write(A_STAGE_CTRL, 32'h80); // W1C DONE
    end
  endtask

  // Configure CFG0..5 using OLD BUGGY contract (CFG4=weight_pos, CFG5=weight_neg).
  // Returns err_code. Test proves RTL rejects this mapping.
  task automatic run_with_legacy_buggy_contract(
      input int in_dim, input int out_dim, input int threshold, input int sum_max,
      input int t_count_discarded,  // deliberately discarded per the OLD bug
      input logic [31:0] weight_pos_addr,
      input logic [31:0] weight_neg_addr,
      output logic [7:0] err,
      output bit completed
  );
    logic [31:0] cfg0, cfg3;
    logic [31:0] sts;
    bit ok;
    begin
      // t_count_discarded is intentionally ignored here, mimicking the old
      // buggy primitive `(void)t_count;`. Touch it once to silence any
      // lint about unused input.
      if (t_count_discarded < 0) $display("unreachable");
      cfg0 = ((out_dim & 32'hFFFF) << 16) | (in_dim & 32'hFFFF);
      cfg3 = 32'h0;
      cfg3[1:0]  = V2B_BUF_SEL_INPUT_SRAM;
      cfg3[9:8]  = V2B_BUF_SEL_STREAM_A;
      cfg3[17]   = 1'b1;
      bus_write(A_STAGE_CFG0, cfg0);
      bus_write(A_STAGE_CFG1, threshold);
      bus_write(A_STAGE_CFG2, sum_max);
      bus_write(A_STAGE_CFG3, cfg3);
      bus_write(A_STAGE_CFG4, weight_pos_addr); // OLD bug
      bus_write(A_STAGE_CFG5, weight_neg_addr); // OLD bug — written to t_count slot
      bus_write(A_STAGE_CTRL, 32'h1);
      wait_busy_clear(ok, 2000);
      completed = ok;
      bus_read(A_STAGE_STATUS, sts);
      err = sts[23:16];
      bus_write(A_STAGE_CTRL, 32'h80);
    end
  endtask

  // ── Setup: load minimal weights + 4-row WL stream ───────────────
  task automatic load_minimal_env;
    begin
      // Weights: w_pos[i][j]=1, w_neg=0 for i∈0..P_IN_DIM-1, j∈0..P_OUT_DIM-1
      for (int i = 0; i < P_IN_DIM; i++) begin
        for (int j = 0; j < P_OUT_DIM; j++) begin
          bus_write(A_MAC_W_LOAD_ADDR, (j << 8) | i);
          bus_write(A_MAC_W_LOAD_DATA, 32'h1);  // pos=1, neg=0
          bus_write(A_MAC_W_LOAD_CTRL, 32'h1);
        end
      end
      // WL stream: 4 timesteps, wl[0:3] = 0b1101 (popcount=3). Only write
      // the low 32-bit chunk; rest left zero (upper bits don't matter because
      // MAC only looks at in_dim=4 lower bits).
      for (int t = 0; t < P_T; t++) begin
        bus_write(A_INPUT_SRAM_ADDR, t);
        bus_write(A_INPUT_SRAM_W0, 32'hD); // 0b1101
        bus_write(A_INPUT_SRAM_CTRL, 32'h1);
      end
    end
  endtask

  int pass_count = 0, fail_count = 0;

  task automatic report(input [255:0] label, input bit cond, input [7:0] got_err);
    begin
      if (cond) begin
        $display("[PASS] %0s (err=0x%02h)", label, got_err);
        pass_count++;
      end else begin
        $display("[FAIL] %0s (err=0x%02h)", label, got_err);
        fail_count++;
      end
    end
  endtask

  initial begin
    logic [7:0] err;
    bit completed;

    $display("[TB] v2b_primitive_reg_contract_tb start");

    rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);

    load_minimal_env();

    // ── T1: Correct new contract (CFG5 = t_count) ──
    run_with_new_contract(P_IN_DIM, P_OUT_DIM, P_THRESH, P_SUM_MAX, P_T,
                           err, completed);
    $display("T1 completed=%0d err=0x%02h", completed, err);
    report("T1 new-contract CFG5=t_count", (completed && err == 8'h00),
           err);

    // ── T2: Legacy buggy contract (CFG5 = weight_neg_addr) ──
    // Typical addresses land in the [0x0000_1000, 0x1000_0000] range. Any
    // value > 256 in CFG5[15:0] drives cfg_t_count > P_T_MAX (=256).
    run_with_legacy_buggy_contract(P_IN_DIM, P_OUT_DIM, P_THRESH, P_SUM_MAX,
                                    P_T,                      // discarded t_count
                                    32'h1234_0000,            // fake weight_pos_addr
                                    32'h0000_1000,            // fake weight_neg_addr → CFG5[15:0]=0x1000=4096 > 256
                                    err, completed);
    $display("T2 completed=%0d err=0x%02h", completed, err);
    report("T2 legacy-buggy CFG5=weight_neg_addr",
           (completed && err == V2B_STAGE_ERR_DIM_OUT_OF_RANGE),
           err);

    // ── T3: Explicit t_count=0 ──
    run_with_new_contract(P_IN_DIM, P_OUT_DIM, P_THRESH, P_SUM_MAX, 0,
                           err, completed);
    $display("T3 completed=%0d err=0x%02h", completed, err);
    report("T3 new-contract CFG5=0",
           (completed && err == V2B_STAGE_ERR_DIM_OUT_OF_RANGE),
           err);

    // ── T4: Explicit in_dim=0 ──
    run_with_new_contract(0, P_OUT_DIM, P_THRESH, P_SUM_MAX, P_T, err, completed);
    $display("T4 completed=%0d err=0x%02h", completed, err);
    report("T4 new-contract in_dim=0",
           (completed && err == V2B_STAGE_ERR_DIM_OUT_OF_RANGE),
           err);

    // ── T5: After all the rejects, FSM must still execute a valid config ──
    run_with_new_contract(P_IN_DIM, P_OUT_DIM, P_THRESH, P_SUM_MAX, P_T,
                           err, completed);
    $display("T5 completed=%0d err=0x%02h", completed, err);
    report("T5 recovery-after-rejects",
           (completed && err == 8'h00),
           err);

    $display("");
    $display("=== Results: %0d PASS, %0d FAIL ===", pass_count, fail_count);
    if (fail_count == 0)
      $display("V2B_PRIMITIVE_REG_CONTRACT_TB_PASS");
    else
      $display("V2B_PRIMITIVE_REG_CONTRACT_TB_FAIL");
    $finish;
  end

  initial begin
    #30_000_000;
    $display("[FAIL] Global timeout");
    $finish;
  end
endmodule
