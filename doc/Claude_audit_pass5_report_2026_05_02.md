# Claude Audit Pass 5 — 总结报告（2026-05-02）

> **本轮角色**：第五轮独立 cold-start audit（Claude Opus 4.7，1M context），
> 在 audit-pass4（main `3375d898` / `63bf8692`，FPGA `3dec1142` / `7495172b`
> / `06a7b337`）已 push origin 之后执行。范围：main + main-fpga-e203-alpha
> 双支线，pre-tape-out 严苛度。**不**做 FPGA 板验（GPT 那边的任务）。
>
> 用户范围设定：按 pass5 prompt §三 七大维度做 cold-start re-audit；先验
> baseline 8/8 PASS，再分模块复检 pass2~pass4 的修复后效，并扫之前未深入
> 的角落。本轮抓到一个 CONCERN（DMA stall 计数残留），完成 RTL+TB 修复并
> 经 Codex 二审后 push。

## 抓到的新问题（按严重度）

### BLOCKER（必修，影响 RTL/FW 流片正确性）

无新增 BLOCKER。

### CONCERN（应修，影响 DMA 在 timeout 后续事务的正确性）

| # | 问题 | 文件:行 | main fix commit | FPGA sync commit |
|---|---|---|---|---|
| R-M2.1 | `dma_engine.sv` ST_PUSH timeout-exit 路径 set `err_sticky+done_sticky` 后跳 ST_IDLE，但**未清** `push_stall_cnt`（残留 ≈ `PUSH_TIMEOUT_CYCLES`+1）；下一次 START 进入 ST_PUSH 时若 `in_fifo_full` 仍为 1，**第 1 拍**就触发假阳性 ERR，新事务未享受到完整 timeout 窗口。已有清零路径仅覆盖 (a) async reset 和 (b) ST_PUSH 成功 push 分支 | `rtl/dma/dma_engine.sv:316,372`（fix）+ `tb/dma_tb.sv:T11`（覆盖） | `e46069a6` | `2aae56ef` |

#### Fix 设计（采纳 GPT-5.4 plan 审 + 终审 LGTM 的 Option C，defense-in-depth）

1. **`rtl/dma/dma_engine.sv`** — 新事务入口 + timeout exit 双清零：
   - 加 module 参数 `parameter int unsigned PUSH_TIMEOUT_CYCLES`，默认沿用
     `snn_soc_pkg::V2B_DMA_PUSH_TIMEOUT_CYCLES`（1M cycles ≈ 20ms@50MHz）。
     `snn_soc_top` 不 override，硅片默认行为 100% 等价。
   - ST_IDLE → ST_SETUP 成功路径加 `push_stall_cnt <= 24'd0;`（**语义点**：
     新事务开始，per-op 计数清零）。
   - ST_PUSH timeout-exit 加 `push_stall_cnt <= 24'd0;`（**防御深度**：
     任何路径离开 ST_PUSH 都不残留旧值）。
2. **`tb/dma_tb.sv`** — T11（5 phases / 13 sub-checks）：
   - 实例化 DUT 时 override `PUSH_TIMEOUT_CYCLES=64`，让 sim 在合理 cycle 数
     内观察 timeout/recovery（避免等 1M 真实 cycles）。
   - phase a：第 1 次 START + FIFO 满 → 等 `64+32` 拍 → 断言 `ERR=1, DONE=1, BUSY=0`。
   - phase b：W1C 清 ERR + DONE → 断言两个都清回 0。
   - phase c：第 2 次 START + FIFO **仍满** → 等 16 拍（远 < 64）→
     断言 `BUSY=1, ERR=0, DONE=0`（**关键**：抓"第二次一进 ST_PUSH 立刻 ERR"原 bug）。
   - phase d：释放 FIFO → 等 `wait_done(200)` → 断言 `DONE=1, ERR=0`。
   - phase e：recover 后再次 START + FIFO 满 → 等 `64+32` 拍 → 断言再次正常 timeout
     （证明 push_stall_cnt 残留状态彻底拷问一轮）。

### MINOR（建议修，文档 / cosmetic / follow-up）

未在本轮 commit，留给下一轮：

| # | 问题 | 位置 | 建议 |
|---|---|---|---|
| M-4 | DMA `V2B_DMA_PUSH_TIMEOUT_CYCLES = 1M cycles` 未硅片实测 | `rtl/top/snn_soc_pkg.sv:216` | 等硅片回来再 actuate；与 R-M2.1 互不冲突（参数化机制已就位） |
| M-5 | `e203_fpga_smoke.c` rebuild 时 .dump/.map 因绝对路径 churn | `fw/e203_smoke/build_e203_smoke.sh` | 优先级低；不影响 functional |
| M-6 | `fw/main.c boot_full_array_erase` RMW `(pc & ~PROG_CTRL_LOW_MASK)` 会清 LEVEL[3:0]；erase 路径不读 LEVEL，don't-care，但读者可能困惑 | `fw/main.c:55-59` | 加 1 行注释说明"erase 不依赖 LEVEL"。优先级低 |
| M-7 | `spi_tb T1c` 未覆盖 `wstrb=4'b0011` 同时写 byte0+byte1 的原子更新场景 | `tb/spi_tb.sv:T1c` | 既有 3 子测试已抓住主要 byte-strobe corner；同周期 byte0/1 联写为 nice-to-have |

## 已 push 的 commit

- main:
  - `e46069a6` — audit-pass5(rtl,tb): R-M2.1 — clear push_stall_cnt at new-op entry + timeout exit + dma_tb T11
  - `595280ce` — audit-pass5(doc): land Claude audit pass 5 report
- main-fpga-e203-alpha:
  - `2aae56ef` — Merge branch 'main' into main-fpga-e203-alpha (audit-pass5 R-M2.1 sync；FPGA 25 文件无独立改动)
  - `<FPGA doc merge>` — merge of `<doc commit>`

## 跨分支一致性 verification

```
git diff --name-only origin/main origin/main-fpga-e203-alpha → 25 文件
```

全部 FPGA-only：

```
doc/main-fpga-e203/00_architecture.md
doc/main-fpga-e203/alpha_board_bringup_log_20260424.txt
doc/main-fpga-e203/board_bringup_log_c0c1c2.txt
doc/main-fpga-e203/fw_main_c_boot_erase_board_validation_analysis.md
doc/main-fpga-e203/silicon_bringup_uart_capture_20260423_120301.txt
fpga/boards/zcu102/constraints_e203.xdc
fpga/boards/zcu102/snn_soc_fpga_top.sv
fpga/cim_model/cim_fpga_programmable_model.sv
fpga_synth/zcu102_e203_demo/build_e203_demo.{sh,tcl}
fw/e203_smoke/build_e203_smoke.sh
fw/e203_smoke/e203_fpga_smoke.c
fw/e203_smoke/out/e203_smoke.{bin,dump,elf,hex,map,_crt0.o,_main.o,_uart.o}
scripts/gen_bram_init.py
scripts/program_zcu102_e203.tcl
sim/run_fpga_programmable_cim_model.sh
sim/sim_fpga_programmable_cim_model.f
tb/fpga_programmable_cim_model_tb.sv
```

✓ 25/25 全部 FPGA-only，无 RTL / shared FW / shared TB / shared doc 漂移。
R-M2.1 改的是 RTL `rtl/dma/dma_engine.sv` + shared TB `tb/dma_tb.sv`，两支线
共享，FPGA 支线通过普通 fast-forward merge 自动同步，不需要 FPGA-only commit。

## sim regression 状态（push 前 8/8 PASS）

跑于 main worktree（commit `e46069a6`）：

| TB | Status |
|---|---|
| run_chip_top_rom_smoke | CHIP_TOP_ROM_SMOKE_PASS |
| run_chip_top_rom_hi_smoke | CHIP_TOP_ROM_HI_SMOKE_PASS |
| run_cim_program_ctrl | CIM_PROGRAM_CTRL_PASS |
| run_dma_icarus | DMA_SMOKETEST_PASS（**52/52**，pass5 新增 13 个 T11 子测试） |
| run_uart_icarus | UART_SMOKETEST_PASS（14/14） |
| run_spi_icarus | SPI_SMOKETEST_PASS |
| run_prog_inflight_lock | PROG_INFLIGHT_LOCK_TB_PASS |
| run_boot_erase_e2e | BOOT_ERASE_E2E_TB_PASS |

Reproducibility cross-check（验证 pass4 M-1 后效仍稳）：
- 连续两次 `bash fw/silicon_bringup/build_silicon_bringup.sh` → 完全相同字节
- 连续两次 `bash fw/boot_rom/build_boot_rom.sh` → 完全相同字节

## 修不动 / 需人工决策的项

无。pass5 抓到的 R-M2.1 已修复 + 双重 codex 审（plan + 终审 diff LGTM）+
push + sim 验证 + 跨分支同步完成。M-4 / M-5 / M-6 / M-7 留作 MINOR follow-up，
已在上表列出。

## 审查方法摘要

按 prompt §三 七大维度逐项 cover，逐项结论：

1. **跨分支一致性**（§3.1）✓：baseline 25/25 全 FPGA-only；R-M2.1 fix 后仍 25/25。
2. **RTL 层**（§3.2）✓：
   - **M-3 后效**（spi_ctrl REG_CTRL byte-selective）：clamp 正确 scope（仅
     `req_wdata` word-level，byte0 经 `wstrb[0]` gate，byte1 直接 `wdata[15:8]`
     不经 clamp，无串扰）；byte2/byte3 RAZ/WI（仅在 `wstrb[0]/[1]` 分支写
     `ctrl_reg[7:0]/[15:8]`，`ctrl_reg[31:16]` 永远为 reset 0）。
   - **M-1 后效**（silicon_bringup BUILD_ID）：`#ifndef SILICON_BRINGUP_BUILD_ID
     #define ... "frozen"` 兜底使任何 build path 都能 link；连续 2 次 build
     bin/hex 字节级相同。
   - **R-M2 后效**（dma_engine push_stall_cnt）：**抓到残留 R-M2.1**（见上）。
   - **CDC**：`jtag_mem_loader` TCK↔CLK 三对 toggle handshake（req / cpuctl /
     rsp），全部走 2-FF + `async_reg=TRUE`；data 在 toggle 升起后稳定多
     TCK 周期才被对侧读取，符合"data hold + handshake toggle"标准模式；
     无遗漏 sync 路径。
   - **复位**：所有 always_ff 走 negedge rst_n；jtag_mem_loader 双时钟域
     async-reset 正确（TCK FSM + CLK FSM 各自 reset 自己的状态）。
   - **byte-strobe 完整性**：`reg_bank.sv` 全部 RW 字段都通过 `req_wstrb[i]`
     gate（REG_THRESHOLD 4 byte / TIMESTEPS / RESET_MODE / THRESHOLD_RATIO /
     CIM_TEST 3 字段 / CIM_CTRL W1P+W1C / PROG_CTRL 6 字段 / PROG_ROW / PROG_COL
     / PROG_STATUS W1C / PROG_PULSE_WIDTH sel）；无遗漏。
   - **`prog_inflight` lock**：`PROG_CTRL.{ERASE,FULL_ARRAY,BYPASS,LEVEL,
     RETRY_LIMIT}` / `PROG_ROW` / `PROG_COL` / `PROG_PULSE_WIDTH` 全部走
     `if (req_wstrb[*] && !prog_inflight)` 双重 gate；`PROG_STATUS.DONE`
     (W1C) 与 `PROG_CTRL.START` (W1P) 故意不锁，符合规范。
   - **位宽 / 类型**（FP-001 lif_neurons `<<<` 已审过 pass3）：未触发。
3. **FW 层**（§3.3）✓：
   - 三个固件文件（silicon_bringup.c / main.c / e203_fpga_smoke.c）全部
     `#include "soc_regs.h"`，无残留本地 PROG_* alias。
   - PROG_CTRL/PROG_STATUS 位定义与 `reg_bank.sv:267-272` 完全对齐
     （START[0]/ERASE[1]/FULL_ARRAY[2]/BYPASS[3]/LEVEL[7:4]/RETRY_LIMIT[10:8]
     + STATUS BUSY[0]/PASS[1]/FAIL[2]/RETRY[5:3]/FSM_PRESENT[6]/DONE[7]）。
   - **boot_rom 字节级可重现**也确认：连续 2 次 `bash fw/boot_rom/build_boot_rom.sh`
     emit 相同 .bin/.hex（无 `__DATE__`/`__TIME__` 嵌入）。
   - `__DATE__` / `__TIME__` 全 repo grep 后只剩 `build_silicon_bringup.sh`
     注释中提到的"避免 __DATE__"——所有源码都干净。
4. **TB / sim 层**（§3.4）✓：8/8 核心 TB 全 PASS；新增 dma_tb T11（13 子检查）。
5. **文档层**（§3.5）✓：
   - `silicon_bringup_plan.md §6.4` NOTE 指向 `soc_regs.h`，与 pass4 D-2 一致。
   - `02_reg_map.md` PROG_* 表与 `reg_bank.sv:267-272` 位定义逐项对齐。
   - markdown links 维持 PASS（pass3 通过的检查未受 R-M2.1 影响）。
6. **边界 / 可疑点**（§3.6）✓：
   - `boot_full_array_erase` RMW 清 LEVEL：erase 路径不依赖 LEVEL，
     don't-care；下一次 write 入口必重写 LEVEL，无 carry-over 风险（M-6 留
     注释 follow-up）。
   - `e203_fpga_smoke` rebuild churn（M-5）：行为问题，非功能问题。
   - PROG_CTRL writeback 时序：silicon_bringup STAGE_B 测过 START 后立即清
     PROG_CTRL，cim_program_ctrl FSM 在 START 那一拍内部锁存 op/level/bypass，
     之后 PROG_CTRL 改写不影响进行中的 op（pass4 已审）。

## 关键决策记录

- **R-M2.1 选 Option C 不是最小 diff Option B**：GPT-5.4 plan 审 + 终审都
  推荐 C（双清零）作为 pre-tape-out 更稳的选择。语义上"新事务入口清"与
  防御深度上"timeout exit 清"互补，组合后任何路径离开 ST_PUSH 都不残留。
- **PUSH_TIMEOUT_CYCLES 暴露为 module parameter**：让 dma_tb 能用 64-cycle
  小窗口在合理 sim time 内验证 timeout/recovery，避免等 1M 真实 cycles。
  顶层 `snn_soc_top` 不传该参数，硅片默认行为 100% 等价。`int unsigned`
  类型避免 signed parameter 风格告警（codex 终审 polish 建议）。
- **T11 加 phase e**：codex 终审建议加"recover 后第 N≥2 次也能正常
  timeout"硬证明，与 phase a/c 的"第 1 次 / 第 2 次"配合，把 push_stall_cnt
  残留状态彻底拷问一轮。
- **R-M2.1 不需要 FPGA-only commit**：`dma_engine.sv` + `dma_tb.sv` 两支线
  共享，普通 fast-forward merge 即同步完成。FPGA 25 文件无任何独立改动。

完。
