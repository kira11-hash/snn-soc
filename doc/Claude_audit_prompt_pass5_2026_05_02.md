# Claude Cold-Start Prompt — Audit Pass 5（main + main-fpga-e203-alpha）

> **角色**：你是新开 Claude Code 对话的 Claude，被叫来对一颗**未流片** SNN ASIC
> 项目的 main 分支 + main-fpga-e203-alpha FPGA evidence 支线做**第五轮**独立审查。
> 前四轮（pass1～pass4）由其他 Claude session 完成，共 18 个 audit-pass commits
> 已 push 到 origin/main 和 origin/main-fpga-e203-alpha。GPT 那边在跑 FPGA 板验
> + 有空再做独立终审，所以本轮 Claude 重点**继续在 RTL/FW/TB/sim/doc 层多扫几遍**，
> 把残留的 corner 抓干净。
>
> **你拥有完全权限**：可以修改任何文件、跑任何 shell 命令。所有自己的修复都
> commit + push 到对应分支。不需要跑 FPGA 板验（GPT 那边的任务）。
>
> **核心硬约束**（CLAUDE.md 已写明，本 prompt 再强调）：
> - main-fpga-e203-alpha 分支 = main + 仅 FPGA 适配，**其他内容必须完全一样**
> - 任何 audit fix 在 main 上做了，FPGA 支线必须同步（除非 fix 本身是 FPGA-only）
> - frozen tags 永远不动：`main-fpga-e203-alpha-passed @ 2adc327b`、
>   `feature/v2-arm-fpga-demo-v2-passed`、`feature/v2-fpga-e203-passed`、
>   `v2-permanent-gate-2026-04-25`
> - V1 SNN ASIC **未流片**，main RTL 仍是流片对象，audit 严苛度按 pre-tape-out
>   最后一关执行
>
> **目标交付**：
> (a) `doc/Claude_audit_pass5_report_2026_05_02.md`（与 pass3/pass4 同结构）
> (b) 所有自己的修复 commit 都已 push 到对应分支
> (c) 跨分支 sanity check：`git diff --name-only main main-fpga-e203-alpha` 仅 25
>     个 FPGA-only 文件

---

## 〇、冷启动必读：项目 30 秒速览

SNN ASIC SoC，数模分离封装：
- 模拟 die：CIM RRAM macro + ADC（独立流片）
- 数字 die：E203 RISC-V CPU + SNN 加速器（本审 scope）
- V1 RTL 已实现 + sim 全 PASS + ZCU102 FPGA 板验通过；**未做后端**（synthesis /
  P&R / DFT / STA 还没开），所以 RTL 仍可改、必须改对
- V2 已 frozen，不在本审 scope

**第一件事**：`cat CLAUDE.md` 完整读完。重点 FP-001..FP-005 误报库——历史上 AI
报错过的模式，再报同类问题前先对照表。

---

## 一、仓库布局 + 当前分支状态

```
git worktrees:
  D:/SoC Design/SoC Design          → main                 HEAD `<latest after pass4 doc sync>`
  D:/SoC Design/audit-fpga          → main-fpga-e203-alpha HEAD `<latest after pass4 doc sync>`
  D:/SoC Design/audit-v2            → feature/v2-arm-fpga-demo-conv（不审）
  D:/SoC Design/audit-v2-e203       → feature/v2-fpga-e203-conv（不审）
```

跑 `git log --oneline -25` 在 main 上，应看到（按时间倒序）：

```
<latest>   audit-pass4(doc): D-2 — refresh stale R-C9 NOTE + land pass4 report
3375d898  audit-pass4(fw,rtl,tb): M-1 + M-2 + M-3 — minor follow-ups from pass3
0ac8f269  audit-pass3(doc): 落地 Claude audit pass 3 总结报告（evidence trail）
bd78a0b0  audit-pass3(rtl,fw,doc): W-1 + R-M1.1 + D-1 — workspace cleanup + uart wstrb + doc macro fix
dc20813a  docs(prompt): GPT audit prompt 加 §4.3.1 板验失败必须回流 main
e6dd423d  audit-pass2(doc): 落地 Claude + GPT cold-start audit prompts
397d2701  audit-pass2(doc): R-C9 — BYPASS_HANDSHAKE policy + production readback assert
... (audit-pass2 / audit-pass1 commits) ...
```

---

## 二、前四轮 audit 已完成（不要重做，验证质量 + 看后效）

完整修复流水（按 commit 时间排序，仅 pass3+pass4 摘录）：

| Commit | 类别 | 要点 |
|---|---|---|
| `bd78a0b0` | pass3 RTL/FW/DOC | W-1（git-track silicon_bringup.bin + .gitignore rom_smoke artifact）+ R-M1.1（uart_ctrl ST_IDLE TX 启动路径加 wstrb[0] gate）+ D-1（silicon_bringup_plan.md 模板宏名 PROG_CTRL_BYPASS_HANDSHAKE_MASK → PROG_CTRL_BYPASS_MASK） |
| `0ac8f269` | pass3 DOC | 落地 pass3 总结报告 |
| `3375d898` | pass4 FW/RTL/TB | **M-1**（silicon_bringup.c 用 SILICON_BRINGUP_BUILD_ID 替代 __DATE__，build_silicon_bringup.sh 注入，默认 "frozen" 字节级可重现）+ **M-2**（PROG_* 寄存器宏从 silicon_bringup.c / main.c 迁到 fw/include/soc_regs.h 集中）+ **M-3**（spi_ctrl REG_CTRL byte0/byte1 独立 wstrb gate，新增 spi_tb T1c byte-strobe coverage） |
| `<latest>` | pass4 DOC | **D-2**（silicon_bringup_plan.md §6.4 R-C9 模板的 NOTE 同步刷新 — pass3 D-1 注释里"宏只在 silicon_bringup.c:34 局部 alias，长远建议迁到 soc_regs.h，未做"现在 stale，pass4 M-2 已迁）+ 落地 pass4 报告 |

main-fpga-e203-alpha 同步 commits：
- `7644dea9` (pass3 sync merge)
- `f778bd78` (pass3 doc merge)
- `<pass4 sync merge>`
- `7495172b` audit-pass4(fw,fpga-only) — drop e203_fpga_smoke.c PROG_* aliases
- `<pass4 doc sync merge>`

---

## 三、你的审查范围（全方位、不留死角）

### 3.1 跨分支一致性（最重要！）

```bash
cd "/d/SoC Design/SoC Design"
git fetch origin
git diff --name-only origin/main origin/main-fpga-e203-alpha | sort
# 期望 25 个文件，全部在：
#   doc/main-fpga-e203/  / fpga/  / fpga_synth/zcu102_e203_demo/
#   fw/e203_smoke/  / scripts/{gen_bram_init,program_zcu102_e203}
#   sim/{sim,run}_fpga_programmable_cim_model
#   tb/fpga_programmable_cim_model_tb.sv
```

如果出现第 26 个文件 → STOP，pass5 工作没做对。

### 3.2 RTL 层（pre-tape-out 严苛）

每个 .sv 文件 Read 进来全文看一遍。重点 pass4 引入的改动 + 此前未深入的角落：

1. **M-3 后效**：`spi_ctrl.sv:108-126` REG_CTRL byte0/byte1 独立 gate
   - 是否有 corner case 漏掉？比如 wstrb=4'b0011 同时写 byte0+byte1 是否符合预期？
   - safety clamp 与 byte-strobe 交互：`ctrl_write_data` 是 word-level 计算，
     wdata[3:1]==0 + wdata[0]=1 时触发 — 如果 byte0 的 wstrb=0 但 wdata[0]=1，
     clamp 计算被触发（无副作用），是否值得 hard-gate clamp 到 wstrb[0]？
   - byte2/byte3 RAZ/WI — 真的没有任何写路径吗？grep `ctrl_reg[`、`ctrl_reg<=`
3. **M-1 后效**：`silicon_bringup.c:106` 用 `SILICON_BRINGUP_BUILD_ID` 替代
   `__DATE__` — `#ifndef ... #define ... "frozen"` 兜底是否所有 build 路径都 OK？
   想象别人 `riscv64-unknown-elf-gcc -c silicon_bringup.c` 不走 wrapper，
   uart_printf 是否真能编过 + 链通？
4. **R-M1 / R-M2 后效**：pass2 加的 uart_ctrl/spi_ctrl wstrb gate 与 dma_engine
   push_stall_cnt 已在 pass3+4 多次审过；再审一次 dma_engine 走出 ST_PUSH 后
   stall_cnt 清零路径，主要看 reset 与 normal exit 两条路是否都覆盖
5. **CDC**（FP-005 提示 fifo_sync 单时钟域，别误报）：jtag_tck ↔ clk 同步链
   再扫一次，特别是 jtag_mem_loader.sv 的 toggle + 2-FF synchronizer 完整性
6. **复位路径**：所有 always_ff 是 negedge rst_n？SRAM macro 不复位（流片预期）？
7. **byte-strobe 完整性 cross-check**：reg_bank.sv 所有 RW 寄存器是否都有
   wstrb gate？特别 `prog_inflight` lock 路径
8. **位宽 / 类型**（FP-001 lif_neurons `<<<` 已审过，别误报）

### 3.3 FW 层

1. **M-2 后效**：`fw/include/soc_regs.h` 集中后，三个固件文件（silicon_bringup.c
   / main.c / e203_fpga_smoke.c）是否都 include 了 soc_regs.h？grep 一下
   `#include.*soc_regs`
2. **PROG_* mask 一致性**：与 RTL `rtl/reg/reg_bank.sv:267` 写明的位定义对照
   `[0]=START W1P, [1]=ERASE RW, [2]=FULL_ARRAY RW, [3]=BYPASS_HANDSHAKE RW,
   [7:4]=LEVEL RW, [10:8]=RETRY_LIMIT RW`，PROG_STATUS 同理
3. **silicon_bringup.{bin,hex} reproducibility**：
   ```bash
   wsl bash fw/silicon_bringup/build_silicon_bringup.sh && \
     cp fw/silicon_bringup/out/silicon_bringup.bin /tmp/sbu1 && \
     wsl bash fw/silicon_bringup/build_silicon_bringup.sh && \
     cmp /tmp/sbu1 fw/silicon_bringup/out/silicon_bringup.bin && echo "OK"
   ```
4. **boot_rom.{bin,hex} 同样可重现性**：boot_rom_main.c 是否也嵌入 __DATE__
   或 __TIME__？grep 一下；如果有，应该也 SOURCE_DATE_EPOCH 化
5. **fw/main.c LEGACY guard**：`build_e203_firmware.sh` 的 ALLOW_LEGACY_V1_FW=1
   guard 是否唯一入口？grep 全 repo 看是否有 implicit caller

### 3.4 TB / sim 层

1. 跑 8 个核心 TB，必须全 PASS：
   ```bash
   cd "/d/SoC Design/SoC Design/sim"
   for s in run_chip_top_rom_smoke run_chip_top_rom_hi_smoke \
            run_cim_program_ctrl run_dma_icarus run_uart_icarus run_spi_icarus \
            run_prog_inflight_lock run_boot_erase_e2e; do
     echo "=== $s ==="; bash "$s.sh" 2>&1 | grep -E "RESULT|_PASS$|_FAIL" | tail -3
   done
   ```
2. **spi_tb T1c byte-strobe coverage**：pass4 新增的 3 子测试是否充分？
   建议加：byte0+byte1 同时写（wstrb=4'b0011），验证两 byte 同步更新
3. **silicon_bringup_tb 切到 chip_top**（pass3 FW-C1 fix）：跑 sim 是否仍 PASS？
   chip_top + boot_rom 的 fallback `jal x0,+0x1000` 行为是否符合预期？
4. **TB watchdog 数值**（pass3 TB-C-01）：5 个 top-level TB 的 timeout 是否够用？
   特别 sample_align（100 sample × 500us ≈ 50ms 估算 vs 100ms 余量）

### 3.5 文档层

1. **D-2 后效**：silicon_bringup_plan.md §6.4 NOTE 已刷新，整段是否还有其他
   stale 引用？例如 §6.5 落地清单是否提到"PROG_* 集中"
2. **CLAUDE.md FP 知识库**：pass4 抓到的 D-2 stale doc 模式值得加进
   FP-006？或者是 anti-pattern（"audit fix 留下的 NOTE 不要忘了在下一轮修同类
   issue 时同步刷新"）
3. **02_reg_map.md**：与 reg_bank.sv:267 位定义对照
4. **markdown links**：`python scripts/check_markdown_links.py` 仍 PASS

### 3.6 边界 / 可疑点

1. **fw/main.c boot_full_array_erase RMW**：`(pc & ~PROG_CTRL_LOW_MASK)` 会清
   LEVEL[3:0]，erase 路径 don't-care，但 ERASE+START 之后下一次 write 入口是否
   依赖 LEVEL 仍是上次值？（应该不依赖，每次 write 入口都重写 LEVEL，但值得
   trace 一遍）
2. **e203_fpga_smoke build artifact churn**（pass4 M-5 follow-up）：rebuild
   时 .dump/.map 因 worktree 路径 churn — 可以加 `objdump --no-show-raw-insn`
   或干脆 .gitignore 这两个文件（保留 .bin/.hex 即可）
3. **PROG_CTRL writeback 时序**：silicon_bringup.c STAGE_B 测试了 START 之后
   立即清 PROG_CTRL（`PROG_CTRL = 0u;`），RTL latch 在 START 一拍内是否完整？

---

## 四、工作流程

### 4.1 修复流程（main + 同步 FPGA 支线）

1. 在 main worktree（`d:/SoC Design/SoC Design`）改文件
2. 跑 affected sim 验证：`bash sim/run_<gate>.sh`
3. `git add` + `git commit -m "audit-pass5(xxx): 描述"`
4. 同步到 FPGA 支线（`D:/SoC Design/audit-fpga` worktree）：
   ```bash
   cd "D:/SoC Design/audit-fpga"
   git fetch origin
   git merge origin/main --no-ff -m "Merge branch 'main' into main-fpga-e203-alpha (audit-pass5 sync)"
   git push origin main-fpga-e203-alpha
   ```
5. 验证跨分支一致性：`git diff --name-only origin/main origin/main-fpga-e203-alpha`
   只应输出 25 个 FPGA-only 文件
6. **不要 amend** 已有 commit，每修一组就单独 commit

### 4.2 sim regression 全 pass 后才 push

不许在 sim FAIL 状态 push 任何 commit。每次 push 前在 main worktree 跑 8 个
核心 TB，全 PASS 才 push。

### 4.3 跨分支 sanity（每次修改后必跑）

```bash
cd "/d/SoC Design/SoC Design"
git fetch origin
git diff --name-only origin/main origin/main-fpga-e203-alpha | sort | wc -l
# 必须是 25
```

---

## 五、不要做的

- 不要再修一遍 §二 已修的 pass3/pass4 commits（除非发现没修好或后效有问题）
- 不要把任何 frozen tag 移动或删除
- 不要重写任何 commit history（除非用户授权）
- 不要碰 V2 evidence 分支（feature/v2-arm-fpga-demo-conv 等）
- 不要做 FPGA bitgen / 板验——那是 GPT prompt 的任务
- 不要碰模拟 die / 模拟 PCB layout 文件（doc/08 / doc/11 / doc/17 不是审 RTL
  的 scope）

---

## 六、deliverable（你结束时必须交付）

格式与 pass3 / pass4 报告一致，路径：
`doc/Claude_audit_pass5_report_2026_05_02.md`

```markdown
# Claude Audit Pass 5 — 总结报告（YYYY-MM-DD）

## 抓到的新问题（按严重度）
### BLOCKER
| # | 问题 | 文件:行 | main fix commit | FPGA sync commit |
|---|---|---|---|---|

### CONCERN
（同表格）

### MINOR
（同表格）

## 已 push 的 commit
- main: aaaaaaa, ...
- main-fpga-e203-alpha: ddddddd

## 跨分支一致性 verification
- `git diff --name-only origin/main origin/main-fpga-e203-alpha` → 25 文件，全 FPGA-only ✓

## sim regression 状态（必须全 PASS）
- 8/8 核心 TB PASS

## 修不动 / 需人工决策的项
（如有）
```

---

## 七、pass4 留下的 follow-up（可选优先级）

不必都修，挑值得做的：

| # | 问题 | 位置 | 建议 |
|---|---|---|---|
| M-4 | DMA `V2B_DMA_PUSH_TIMEOUT_CYCLES = 1M cycles` 未硅片实测 | `rtl/top/snn_soc_pkg.sv:216` | 等硅片回来再 actuate；不要现在动 |
| M-5 | `e203_fpga_smoke.c` rebuild 时 .dump/.map 因绝对路径 churn | `fw/e203_smoke/build_e203_smoke.sh` | 加 .gitignore（保留 .bin/.hex/.elf）或者重写 build 用 relative path |
| M-6 | `fw/main.c boot_full_array_erase` RMW 清 LEVEL，需注释说明 erase 路径不读 LEVEL | `fw/main.c:55-59` | 加 1 行注释 |

完。开干吧。
