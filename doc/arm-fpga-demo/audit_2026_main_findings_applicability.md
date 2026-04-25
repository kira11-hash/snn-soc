# Main-audit findings applicability on `v2-arm-fpga-demo-passed`

**作者**：Claude (audit cycle, 2026-04-25)
**Base tag**：`v2-arm-fpga-demo-passed @ 8e51ae27`
**Fix branch**：`feature/v2-arm-fpga-demo-fix-claude`

## 背景

我先前在 `main @ d75be55c` 对照 `main-fpga-e203-alpha-passed @ 2adc327b`
跑了一轮独立审查，输出 10 条 finding（F1~F10）。本仓库的 ASIC 主线后端
正在按那份 finding 列表清理。但同一份 finding 列表搬到
`v2-arm-fpga-demo-passed` 时，因为 arm tag 的 commit time 早于 main
HEAD，很多 main-specific 的"问题"在 arm tag 上**根本不存在**。

本文逐条记录每条 finding 在 arm tag 上的实际状态、是否应用，以及
'不应用'时给出可验证的代码/文档证据，避免后续同学误以为本分支漏修。

> 用户已在审查指令里剔除 F1（sram_simple 单写口，由
> `feature/v2-fpga-e203-fix-claude` cherry-pick 继承）和 F3
> （`PROG_VERIFY_RETRY_MAX` 文档不一致，main 流片 scope）。
> 本文不重复讨论这两条。

## 逐条 applicability

### F2 (MAJOR) — 主线 FPGA flow 文件被删

- 主线现象：`main @ d75be55c` 删除了 `fpga/`、`fpga_synth/zcu102_e203_demo/`、
  `fw/e203_smoke/`、`scripts/program_zcu102_e203.tcl`、
  `doc/main-fpga-e203/00_architecture.md` 等 V1 FPGA 工具链。
- 在 arm tag 的状态：**FPGA flow 完整保留**——
  `fpga_synth/zcu102_arm_demo.tcl`、`fpga_synth/bd_sanity_zcu102_arm_demo.tcl`、
  `fpga_synth/ooc_v2b_arm_demo.tcl`、`fpga_synth/zcu102_arm_demo.xdc`、
  `scripts/build_zcu102_arm_demo.sh`、`scripts/program_zcu102_c0.tcl`、
  `scripts/program_zcu102_c1.tcl` 全部在 tag 内可见。
- 应用结论：**N/A**。本分支根本没经历 FPGA flow 删除事件，无需写 archive
  README。
- 验证命令：

  ```bash
  git ls-tree v2-arm-fpga-demo-passed -- fpga_synth/ scripts/build_zcu102_arm_demo.sh
  ```

### F4 (MINOR) — `CLAUDE.md` 把 pad 总数拆成 52 signal+6 power+3 ESD

- 主线现象：`main` 的 `CLAUDE.md` 写 `52 usable signal + 6 power/ground +
  3 ESD-reserved`，三项相加 = 61，与 `doc/15_asic_pad_map.md` 的 55
  pads 不自洽。
- 在 arm tag 的状态：arm tag 的 `CLAUDE.md` 整个文件**没有任何 pad
  数描述**——`grep -E "pad|总 pad" CLAUDE.md` 0 命中。doc/15 也是 V2
  口径（72 pad，53 allocated = 44 signal + 6 power + 3 ESD），内部一致。
- 应用结论：**N/A**。本分支不存在主线那条错误描述，不需要在 doc/15
  额外写"防止 CLAUDE.md 漂移"的 cross-reference（doc/15 自身已是权威）。
- 用户指令里 F4 的红线：'F4 改成在仓库内 doc/15 加 cross-reference'。
  在 arm 分支上这个 cross-reference 没有要锚定的目标（CLAUDE.md 上没
  pad 表述），强行加只会污染 doc。
- 验证命令：

  ```bash
  git -C v2-arm-fpga-demo-passed grep -nE "pad|总 pad" CLAUDE.md   # 0 命中
  ```

### F5 (MINOR) — `chip_top.sv` 头注释 45 个信号 / 48 pad

- 主线现象：`main @ d75be55c` 的 `rtl/top/chip_top.sv` 头注释写
  '冻结外部 45 个信号 pad' / '全部 48 pad 的正式编号'，与 doc/15 现况
  '46 signal + 9 non-signal = 55' 不一致。
- 在 arm tag 的状态：arm tag `chip_top.sv` 头注释写
  '53 pad 已用（44 signal + 6 power + 3 ESD），19 pad 富余 / 数字芯片
  1mm × 2mm，72 pad'。和 arm tag 的 `doc/15_asic_pad_map.md`
  '53 of 72 pads allocated (44 signal + 6 power + 3 ESD)' 完全一致。
- 应用结论：**N/A**。本分支不存在主线那条 mismatch；硬改成 main 的
  '46/55' 反而会破坏 arm 内部一致性。
- 验证命令：

  ```bash
  git -C v2-arm-fpga-demo-passed grep -n "44 signal\|53 pad\|72 pad" \
      rtl/top/chip_top.sv doc/15_asic_pad_map.md
  ```

### F6 (MINOR) — `doc/16` 删了 V1 FPGA 板上证据 Iteration 12

- 主线现象：`main @ d75be55c` 把 `doc/16_iteration_log.md` 里的
  `Iteration 12 — main-fpga-e203-alpha 板上验证 PASS` 整段删除（71
  lines），导致 V1 ZCU102 board PASS 在 main HEAD 没有 evidence index。
- 在 arm tag 的状态：arm tag 的 `doc/16` 顶端是 `Iteration 16`，
  没有 V1 main-fpga-e203 alpha-passed 的板上记录可以删——它本来就不
  在 arm 的 iteration log 里（arm 是独立 evidence branch，板上记录走
  `doc/arm-fpga-demo/board_bringup_log_*` 而不是 doc/16）。
- 应用结论：**N/A**。本分支不存在删除事件，evidence 索引在
  `doc/arm-fpga-demo/00_architecture.md` 的 §6 Phase A Gate 表 + §4
  Phase B/G3 Evidence Snapshot 里完整记录。
- 验证命令：

  ```bash
  git -C v2-arm-fpga-demo-passed grep -n "main-fpga-e203\|main-fpga-e203-alpha" doc/16_iteration_log.md
  # 0 命中：本来就没记录，谈不上删除
  ```

### F7 (MINOR) — `reg_bank` 在 `ENABLE_PROGRAM_MODE=0` 下 PROG_* 仍可写

- 主线现象：`main @ d75be55c` 的 `rtl/reg/reg_bank.sv` 加了
  `parameter bit ENABLE_PROGRAM_MODE = 1'b1`，并在 PROG_CTRL.START
  写路径上加了 `ENABLE_PROGRAM_MODE` 守卫；但 `PROG_*` 的非 START 字段
  （ERASE / FULL_ARRAY / BYPASS_HANDSHAKE / LEVEL / RETRY_LIMIT / ROW
  / COL / PULSE_WIDTH / ERASE_WIDTH）即使 `ENABLE_PROGRAM_MODE=0` 也
  仍然让 SW 可写，存在'SW 误以为生效'的歧义。
- 在 arm tag 的状态：arm tag 的 `rtl/reg/reg_bank.sv` **没有
  `ENABLE_PROGRAM_MODE` 参数**——

  ```bash
  $ git -C v2-arm-fpga-demo-passed grep -n "ENABLE_PROGRAM_MODE" rtl/reg/reg_bank.sv
  # 0 命中
  ```

  互锁条件就是简单的 `!prog_busy`（行 366：`if (req_wstrb[0] &&
  req_wdata[0] && !prog_busy) start_pulse <= 1'b1;`）。
- 应用结论：**N/A**。`ENABLE_PROGRAM_MODE` 参数化是 main 后期才引入
  的，arm tag 无此功能、无此 ambiguity，谈不上在本分支写 doc 注释。
  当 `ENABLE_PROGRAM_MODE` 参数化沿 e203/main 路径合并回 arm 时（如果
  发生），届时 fix 应跟随沿用。
- 验证命令：

  ```bash
  git -C v2-arm-fpga-demo-passed grep -n "ENABLE_PROGRAM_MODE" rtl/reg/ rtl/top/
  ```

## 应用了的 Finding（fix 已落地为单独 commit）

| Finding | Action | Commit ref |
|---|---|---|
| F8 | `rtl/top/chip_top.sv` 头注释把 pad-cell backlog 升级为 P&R/STA/packaging 硬 blocker，反向链接 doc/19 | 见 `git log feature/v2-arm-fpga-demo-fix-claude --grep "fix(arm/F8)"` |
| F9 | `rtl/dma/dma_engine.sv` SRAM 写端口段补 [DMA dst SRAM byte offset 语义] 注释 | 见 `git log --grep "fix(arm/F9)"` |
| F10 | `doc/19_phase_d_synthesis_readiness.md` 末尾新增 §8 'Icarus SVA 覆盖差距 + ASIC signoff 硬前置' | 见 `git log --grep "fix(arm/F10)"` |

## Frozen artifacts 验证

本 fix branch 仅做 RTL 注释 + doc 修改，未改变任何 RTL 信号赋值 /
端口 / 参数 / 端口连接，故：

- 任何由本 tag 产出的 bitstream / ELF SHA256 都**不应改变**；
- 任何 Vivado synthesis-time gate-level netlist 也**不应改变**（注释不
  进网表）。

校验方式：把 `feature/v2-arm-fpga-demo-fix-claude` 的最后一个 commit
跟 `v2-arm-fpga-demo-passed @ 8e51ae27` 做 RTL-only diff（`git diff
v2-arm-fpga-demo-passed..feature/v2-arm-fpga-demo-fix-claude --
'rtl/**/*.sv'`），应当只看到注释行新增（前缀都是 `// ...` 或在
`/* ... */` 注释块内），无任何赋值/端口/参数行变更。
