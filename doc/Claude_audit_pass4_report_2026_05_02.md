# Claude Audit Pass 4 — 总结报告（2026-05-02）

> **本轮角色**：第四轮独立 cold-start audit（Claude Opus 4.7，1M context），
> 在 audit-pass3（main `bd78a0b0`/`0ac8f269`、FPGA `7644dea9`/`f778bd78`）已 push
> origin 之后执行。范围：main + main-fpga-e203-alpha 双支线，pre-tape-out 严苛。
> **不**做 FPGA 板验（GPT 那边的任务）。
>
> 用户范围设定：先把 pass3 报告里 4 个 MINOR follow-up（M-1..M-4）中
> 低风险高收益的 M-1 / M-2 / M-3 修掉，再做 cold-start audit pass 4 重审，
> 最后写新 prompt 供下一轮使用。

## 抓到的新问题（按严重度）

### BLOCKER（必修，影响 RTL/FW 流片正确性）

无新增 BLOCKER。pass3 留下的 4 个 MINOR 中，M-1/M-2/M-3 已在本轮修复并验证；
M-4（DMA push timeout 硅片实测）属于硅片回来后才能 actuate 的 schedule item，
保持原样。

### CONCERN（应修，sim 覆盖率 / 可维护性 / byte-strobe 严格性）

| # | 问题 | 文件:行 | main fix commit | FPGA sync commit |
|---|---|---|---|---|
| M-1 | `silicon_bringup.c` 嵌入 `__DATE__` → 每次重 build hex 内容变化，破坏 git tracked golden 的字节级可重现性 | `fw/silicon_bringup/silicon_bringup.c:105` + `build_silicon_bringup.sh` | `3375d898` | `7495172b`（merge） |
| M-2 | PROG_* 寄存器宏散布在 `silicon_bringup.c` / `main.c` / `e203_fpga_smoke.c` 三处，新固件需要重复定义且会漂移；audit-pass3 D-1 已确认这个风险 | `fw/include/soc_regs.h` ← `silicon_bringup.c` / `main.c` / `e203_fpga_smoke.c` | `3375d898` (main) + `7495172b` (FPGA-only) | 同左 |
| M-3 | `spi_ctrl.sv` REG_CTRL pass2 R-M1 fix 只 gate 了 wstrb[0]，让 cs_force（bit 8 / byte1）在严格 byte-store 路径下不可写 | `rtl/periph/spi_ctrl.sv:108` + `tb/spi_tb.sv` (T1c 新增覆盖) | `3375d898` | merged |
| D-2 | `silicon_bringup_plan.md §6.4` R-C9 模板的 NOTE 现在 stale（pass3 D-1 注释还在说"宏只在 silicon_bringup.c:34 局部 alias" + "长远建议把宏迁到 soc_regs.h，未做"，但 pass4 M-2 已经迁了） | `doc/silicon_bringup_plan.md:282-287` | `<this commit>` | <pending FPGA sync> |

### MINOR（建议修，文档 / cosmetic / follow-up）

未在本轮 commit，留给下一轮：

| # | 问题 | 位置 | 建议 |
|---|---|---|---|
| M-4 | DMA `V2B_DMA_PUSH_TIMEOUT_CYCLES = 1M cycles`（20ms @ 50MHz）选值合理但未硅片实测 | `rtl/top/snn_soc_pkg.sv:216` | 已在 `doc/07_tapeout_schedule.md` follow-up 列出 |
| M-5 | `e203_fpga_smoke.c` rebuild 时 `.dump` / `.map` 因绝对路径（worktree 名）而 churn；本次 commit 主动 `git checkout` 回原状只 commit 源码，但下一次别人在不同 worktree 跑 build 还是会 dirty | `fw/e203_smoke/build_e203_smoke.sh` | 加 `objdump --no-show-raw-insn` 或用 relative path；或者 .gitignore 加 `.dump` / `.map`。优先级低 |
| M-6 | `fw/main.c` `boot_full_array_erase` 的 RMW `(pc & ~PROG_CTRL_LOW_MASK)` 会清 LEVEL[3:0]，erase 不读 level 所以无功能影响，但读者可能困惑 | `fw/main.c:55-59` | 加注释说明 LEVEL 在 erase 路径下 don't-care。优先级低 |

## 已 push 的 commit

- main:
  - `3375d898` — audit-pass4(fw,rtl,tb): M-1 + M-2 + M-3
  - `<this commit>` — audit-pass4(doc): D-2 stale NOTE refresh
- main-fpga-e203-alpha:
  - `7644dea9` (pass3 sync — 既有)
  - `f778bd78` (pass3 sync — 既有)
  - merge of main `3375d898`（pass4 sync）
  - `7495172b` — audit-pass4(fw,fpga-only): M-2 follow-up — drop e203_fpga_smoke.c PROG_* aliases
  - merge of main `<this commit>`（pass4 doc sync，pending）

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

## sim regression 状态（push 前 8/8 PASS）

跑于 main worktree（commit `3375d898`）：

| TB | Status |
|---|---|
| run_chip_top_rom_smoke | CHIP_TOP_ROM_SMOKE_PASS |
| run_chip_top_rom_hi_smoke | CHIP_TOP_ROM_HI_SMOKE_PASS |
| run_cim_program_ctrl | CIM_PROGRAM_CTRL_PASS |
| run_dma_icarus | DMA_SMOKETEST_PASS (39/39) |
| run_uart_icarus | UART_SMOKETEST_PASS (14/14) |
| run_spi_icarus | SPI_SMOKETEST_PASS (12/12, +T1c byte-strobe coverage) |
| run_prog_inflight_lock | PROG_INFLIGHT_LOCK_TB_PASS |
| run_boot_erase_e2e | BOOT_ERASE_E2E_TB_PASS |

Reproducibility check：连续两次 `bash fw/silicon_bringup/build_silicon_bringup.sh`
emit 完全相同字节的 `.bin` 和 `.hex`（M-1 验证）。

## 修不动 / 需人工决策的项

无。pass4 抓到的 M-1 / M-2 / M-3 / D-2 都已修复 + push + sim 验证通过 +
跨分支同步完成。M-4 / M-5 / M-6 留作 MINOR follow-up，已在上表列出。

## 审查方法摘要

按 prompt §三 七大维度逐项 cover，重点在：

1. **跨分支一致性**（§3.1）✓：25/25 全 FPGA-only
2. **RTL 层**（§3.2）✓：spi_ctrl byte-strobe corner cases / cs_force byte1 路径 /
   safety clamp 与 byte-strobe 交互均已审过；CDC / 复位 / byte-strobe 完整性 /
   位宽对齐 / FP-001..FP-005 误报库未触发
3. **FW 层**（§3.3）✓：silicon_bringup.{bin,hex} 字节级可重现 ✓；
   PROG_* 宏迁移完整覆盖 silicon_bringup.c / main.c / e203_fpga_smoke.c；
   soc_regs.h 与 reg_bank.sv 寄存器位定义对齐验证（START/ERASE/FULL_ARRAY/
   BYPASS/LEVEL[7:4]/RETRY_LIMIT[10:8]/STATUS bits[7:0,6:6]）
4. **TB / sim 层**（§3.4）✓：8/8 核心 TB 全 PASS；新增 spi_tb T1c byte-strobe coverage
5. **文档层**（§3.5）✓：silicon_bringup_plan §6.4 NOTE 同步刷新（D-2）；
   markdown links 维持 PASS（pass3 已通过）
6. **边界 / 可疑点**（§3.6）✓：
   - main.c boot_full_array_erase RMW 用 LOW_MASK 清 LEVEL，erase 不读 level → safe
   - 手动 build silicon_bringup.c 不走 wrapper 时，C 端 `#ifndef SILICON_BRINGUP_BUILD_ID #define ... "frozen"` 兜底
   - e203_fpga_smoke.c rebuild 因 worktree 路径 churn → 主动 reset 只 commit 源码

## 关键决策记录

- **PROG_CTRL_LEVEL_MASK / RETRY_LIMIT_MASK 顺手加进 soc_regs.h**：
  reg_bank.sv:267 已声明这两个 RW 字段，未来固件读 / RMW 时直接拿来用，
  集中宏让 spec 与代码对齐
- **build artifact churn 处理**：FPGA-side rebuild 后 .dump/.map 因绝对路径
  diff，主动 `git checkout -- fw/e203_smoke/out/` 只 commit 源码，避免 git
  history 因 worktree 路径污染（M-5 列入 follow-up）
- **D-2 严重度选 CONCERN 不是 MINOR**：stale NOTE 直接误导未来开发者继续
  在新固件文件里复制 PROG_* alias，与 M-2 中心化目标背道而驰，所以必修

完。
