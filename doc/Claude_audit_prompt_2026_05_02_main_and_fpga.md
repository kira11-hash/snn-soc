# Claude Cold-Start Prompt — main + main-fpga-e203-alpha 双支线 pre-tape-out 终审

> **角色**：你是一个新开 Claude Code 对话（或新 session）的 Claude，被叫来对一颗
> **未流片** SNN ASIC 项目的 main 分支 + main-fpga-e203-alpha FPGA evidence 支线
> 做最后一轮独立审查。前一轮审查由另一个 Claude 完成（共 14 个 audit-pass /
> audit-pass2 commits，已 push origin/main 和 origin/main-fpga-e203-alpha）。
>
> **你拥有完全权限**：可以修改任何文件、跑任何 shell 命令。遇到问题不要停下来问，
> 直接干。所有自己的修复都 commit 然后 push 到对应分支。
>
> **核心硬约束**（CLAUDE.md 已写明，但本 prompt 再强调一次）：
> - main-fpga-e203-alpha 分支 = main + 仅 FPGA 适配，**其他内容必须完全一样**
> - 任何 audit fix 在 main 上做了，FPGA 支线必须同步（除非 fix 本身就是 FPGA-only）
> - DCO / closure 收尾一律 forward-only：只能追加 commit / merge；不要 `reset`、`rebase`、`force-push`、改 tag（除非用户明确授权）
> - frozen tags 永远不动：`main-fpga-e203-alpha-passed @ 2adc327b`、
>   `v2-arm-fpga-demo-v2-passed`、`v2-fpga-e203-passed`、
>   `v2-permanent-gate-2026-04-25`
> - V1 SNN ASIC **未流片**，main RTL 仍是流片对象，audit 严苛度按 pre-tape-out
>   最后一关执行
>
> **目标**：你结束时交付（a）一份 markdown 总结、（b）所有自己的修复 commit
> 都已 push、（c）跨分支 sanity check（diff main..main-fpga-e203-alpha 只剩
> FPGA-only 文件）。**不需要跑 FPGA 板验**——那是 GPT 那边的任务。

---

## 〇、冷启动必读：项目 30 秒速览

这是一颗 spiking-neural-network (SNN) ASIC SoC：
- **数模分离封装**：模拟 die（CIM RRAM macro + ADC）和数字 die（E203 RISC-V CPU
  + SNN 加速器）独立流片，PCB 互连。
- **V1 当前状态**：RTL 已实现 + sim 全 PASS + ZCU102 FPGA 板验通过；
  **未做后端**（synthesis / P&R / DFT / STA 还没开），所以 RTL 仍可改、必须改对。
- 主要功能：64 输入 × 10 输出 SNN 单层推理 + CIM 编程能力（write / erase /
  verify retry）+ E203 + DMA + UART/SPI/JTAG + boot ROM
- **V2** 是后续扩展（不在本审查 scope，已被 frozen 在 V2.B feature 分支）

---

## 一、仓库布局 + 分支状态

主 worktree：`d:\SoC Design\SoC Design`（main 分支）

```
git worktrees:
  D:/SoC Design/SoC Design          → main                 HEAD 397d2701（或更新）
  D:/SoC Design/audit-fpga          → main-fpga-e203-alpha HEAD fa79d3a3（或更新）
  D:/SoC Design/audit-v2            → feature/v2-arm-fpga-demo-conv（不审）
  D:/SoC Design/audit-v2-e203       → feature/v2-fpga-e203-conv（不审）
```

**重要**：你只审 main 和 main-fpga-e203-alpha。V2 分支已在前几轮审过，跳过。

目录结构（main 视角，FPGA 多 25 个 FPGA-only 文件）：

```
rtl/
  snn/                           # V1 SNN 加速器主体
    adc_ctrl / cim_array_ctrl / cim_macro_arbiter / cim_macro_blackbox /
    cim_program_ctrl / dac_ctrl / lif_neurons / wl_mux_wrapper.sv
  bus/                           # bus_simple / interconnect / icb 桥接
  dma/dma_engine.sv
  reg/{reg_bank,fifo_regs}.sv
  mem/{sram_simple,sram_simple_dp,fifo_sync,boot_rom}.sv
  periph/{uart_ctrl,spi_ctrl,jtag_mem_loader}.sv
  top/
    chip_top.sv          # ★ tape-out wrapper, ENABLE_E203/PROGRAM_MODE/BOOT_ROM=1
    snn_soc_top.sv       # ★ V1 SoC 顶层
    snn_soc_pkg.sv       # ★ 全局参数 + 错误码
    e203_min_wrap.sv     # E203 thin wrapper
fw/
  silicon_bringup/       # ★ 硅片回来 Day 1 自检 firmware（链 0x1000，过 boot_rom）
    silicon_bringup.c / .out/silicon_bringup.hex (golden, tracked)
  boot_rom/              # ★ mask ROM bootloader（流片对象）
    boot_rom_main.c / out/boot_rom.bin / boot_rom.hex (golden, tracked)
  main.c                 # ★ V1 LEGACY FPGA app（链 0x10000，仅 sim/FPGA 用，
                         #   build_e203_firmware.sh 现在 default exit 1，
                         #   要 ALLOW_LEGACY_V1_FW=1 才能跑）
  link.ld / link_app.ld / link_app_hi.ld  # 三个 ld 脚本对应三种 base
tb/                      # SystemVerilog testbenches
sim/                     # iverilog 入口（sim_*.f + run_*.sh）
doc/
  CLAUDE.md（项目根目录）— ★★ 必读：核心参数 / 寄存器表 / FP-001..FP-005
                                误报库 / 工作原则 / 仿真路径
  00_overview.md ~ 17_cim_macro_handoff_cover.md
  silicon_bringup_guide.md / silicon_bringup_plan.md
  Claude_audit_prompt_2026_05_02_main_and_fpga.md  ← 本文件
  GPT_audit_prompt_2026_05_02_main_and_fpga.md     ← GPT 用的 prompt
scripts/
  build_zcu102_arm_demo.sh / program_zcu102_*.tcl  # （V2 用）
  jtag_rescue.py             # JTAG mem loader controller
fpga/                    # ★ 仅 main-fpga-e203-alpha 有：board constraints + FPGA top + CIM model
fpga_synth/zcu102_e203_demo/  # ★ 仅 FPGA 支线：Vivado bitgen
fw/e203_smoke/           # ★ 仅 FPGA 支线：FPGA smoke firmware
doc/main-fpga-e203/      # ★ 仅 FPGA 支线：板验日志
```

**第一件事**：`cat CLAUDE.md` 完整读完。重点看 FP-001..FP-005 误报经验知识库——
这是历史上 AI 报错过的模式，再报同类问题前先对照表，避免重复误判。

---

## 二、前一轮 audit 已完成（不要重做，验证质量）

main 分支历史 commits（从 e483a06d 之后到 397d2701 之间）：

| Commit | 类别 | 修复内容 |
|---|---|---|
| `95966e9b` | workspace | rm strays + 14 行 .gitignore 扩展 |
| `1572b434` | RTL | **B-1**：chip_top BOOT_ROM_INIT_FILE 默认 → `fw/boot_rom/out/boot_rom.hex`；**B-2**：cim_program_ctrl level=0/15 verify 窗口 32-bit clamp [0,255] |
| `c1fda8e8` | TB+sim | **B-01**：rtl_with_chip_top_check.f 补 boot_rom + cim_macro_arbiter + cim_program_ctrl；**B-03**：3 TB 加 _FAIL marker；silicon_bringup_tb FW-C1 TODO |
| `fbbf84e8` | FW | **B1**：silicon_bringup link `link.ld` → `link_app.ld`（0x0 → 0x1000）；**C4**：hang() 加 uart_wait_idle；hex 已经通过 WSL 工具链自动重 build |
| `f3970cbb` | DOC | **B1**：doc/06 prog_op 编码错；**B2**：doc/16 Iter12 加 V2 disclaimer；**B3**：README 删 4 行死链；**C1**：silicon_bringup_guide pad 数；**C2**：doc/06 pad 拆分 |
| `bd494d64` | TB | **FW-C1 follow-up**：silicon_bringup_tb 切到 chip_top + stub ROM（jal x0,+0x1000）+ 改 hierarchy 为 dut.u_soc_core.* |
| `9a8ff453` | TB | **TB-C-01**：5 个 top-level TB 加 global watchdog + _FAIL marker（icarus_light/weighted/sample_align/adc_sat_counter/jtag_mem_loader） |
| `9efc28e0` | RTL | **R-M1**：uart_ctrl + spi_ctrl 加 req_wstrb byte-gate；**R-M2**：dma_engine ST_PUSH 加 push_stall_cnt timeout（V2B_DMA_PUSH_TIMEOUT_CYCLES=1M cycles） |
| `e483a06d` | FW+DOC | **FW-C2**：build_e203_firmware.sh 加 ALLOW_LEGACY_V1_FW guard + 顶部 banner；**FW-C3**：boot_rom .bin/.hex 加进 git track（.gitignore file-pattern）；**DOC-C5**：07_tapeout_schedule 加 2026-05-02 status sync |
| `397d2701` | DOC | **R-C9**：BYPASS_HANDSHAKE policy + 生产固件 readback assert 模板（die 不带 efuse，软件 lock）写进 silicon_bringup_plan.md §6 |

main-fpga-e203-alpha 历史：**1 个 commit `fa79d3a3`** 把 FPGA 支线 reset 到 main
+ 恢复 25 个 FPGA-only 文件（详见该 commit message）。这是 force-push 重写历史
后的状态。

---

## 三、你的审查范围（全方位、不留死角）

### 3.1 跨分支一致性（最重要！这是用户主要诉求）

逐项验证：

1. `git diff --name-only main main-fpga-e203-alpha` 输出**只能**是这 25 个 FPGA-only
   文件（如有第 26 个文件意味着 fix 没同步好）：
   ```
   doc/main-fpga-e203/00_architecture.md
   doc/main-fpga-e203/alpha_board_bringup_log_20260424.txt
   doc/main-fpga-e203/board_bringup_log_c0c1c2.txt
   doc/main-fpga-e203/fw_main_c_boot_erase_board_validation_analysis.md
   doc/main-fpga-e203/silicon_bringup_uart_capture_20260423_120301.txt
   fpga/boards/zcu102/constraints_e203.xdc
   fpga/boards/zcu102/snn_soc_fpga_top.sv
   fpga/cim_model/cim_fpga_programmable_model.sv
   fpga_synth/zcu102_e203_demo/build_e203_demo.sh
   fpga_synth/zcu102_e203_demo/build_e203_demo.tcl
   fw/e203_smoke/build_e203_smoke.sh
   fw/e203_smoke/e203_fpga_smoke.c
   fw/e203_smoke/out/e203_smoke.{bin,dump,elf,hex,map,_crt0.o,_main.o,_uart.o}
   scripts/gen_bram_init.py
   scripts/program_zcu102_e203.tcl
   sim/run_fpga_programmable_cim_model.sh
   sim/sim_fpga_programmable_cim_model.f
   tb/fpga_programmable_cim_model_tb.sv
   ```
2. 如果发现 main 上某个文件在 FPGA 支线缺失或不一致：
   - 确认它是否真的是 main 应该有的（不是 audit pass 误删）
   - 直接 `git checkout main -- <file>`（在 audit-fpga worktree 下），commit + push
3. 如果发现 FPGA 上有文件应该 sync 到 main（极少见，因为前面 reset 是 main → FPGA
   单向同步），先停下，flag 给用户决定

### 3.2 RTL 层（pre-tape-out 严苛）

每个 .sv 文件都 Read 进来全文看一遍。重点：

1. **B-1 RTL fix**（chip_top.sv:37）：默认改 `"fw/boot_rom/out/boot_rom.hex"` 后，
   ASIC synthesis 是否能找到这个相对路径？是不是要加注释说明 synthesis 工具
   `set_property GENERIC` override 的方法？
2. **B-2 RTL fix**（cim_program_ctrl.sv ST_VERIFY）：`verify_lo` / `verify_hi`
   组合逻辑是否对所有 level=0..15 都正确？特别 level=0（lo=0/hi=2）和
   level=15（lo=238/hi=242）边界？写一个简单的 Python 跑 16 个 level 验证窗口。
3. **R-M1 RTL fix**（uart_ctrl + spi_ctrl）：byte-gate 是否覆盖了所有 W1P 写入
   路径？比如 spi_ctrl 的 ST_TX_DATA 启动事务，wstrb[0]=0 + wdata[7:0]=0
   会不会还有副作用？
4. **R-M2 RTL fix**（dma_engine push_stall_cnt）：超时阈值 1M cycles 合理吗？
   重置条件是否完整（每次成功 push 清零 + reset 清零）？
5. **CDC**（FP-005 提示：fifo_sync 是单时钟域，别误报）：jtag_tck ↔ clk 同步链
   是否完整？toggle + 2FF synchronizer 在 jtag_mem_loader 走得通吗？
6. **复位路径**：所有 always_ff 是不是 negedge rst_n？SRAM macro 是不是不复位
   （流片预期）？
7. **byte-strobe 完整性**：reg_bank.sv 所有 RW 寄存器写路径是否都用 wstrb？
   有没有遗漏的 W1P/W1C 配置？
8. **位宽 / 类型**（FP-001 提示：lif_neurons <<< 已审过别误报）：所有
   $signed/$unsigned 转换是否正确？立即数有标位宽？

### 3.3 FW 层

1. silicon_bringup.hex 与源码一致性：`bash fw/silicon_bringup/build_silicon_bringup.sh`
   重 build 后 hex 应该 byte-identical（除非 __DATE__ 嵌入；前一轮已修了）
2. boot_rom.bin / boot_rom.hex：现在 git tracked，下次有人改 boot_rom_main.c
   重 build 后 hex 变化，需要 commit hex；这个 workflow 是否在文档里清楚？
3. fw/main.c legacy：`build_e203_firmware.sh` 加了 ALLOW_LEGACY_V1_FW=1 guard，
   除了 sim/run_e203_icarus.sh 设置了这个 env，还有别的地方 implicitly 跑这个
   脚本吗？grep 一下确认
4. fw/include/*.h 寄存器宏与 RTL 一致？特别 PROG_CTRL.BYPASS_HANDSHAKE_MASK 位
   定义？

### 3.4 TB / sim 层

1. TB-C-01 watchdog：5 个 TB 加的 timeout 数值合理吗？sample_align 100ms 够吗
   （100 sample × 500us 估算 50ms，留 100ms 余量）？
2. silicon_bringup_tb.sv 切到 chip_top 之后：实际跑 sim 能 PASS 吗？stub ROM
   `jal x0,+0x1000` 在 chip_top 的 boot_rom 接入后行为是否符合预期？
3. 跑下面这些核心 TB 全 PASS：
   ```bash
   cd "/d/SoC Design/SoC Design/sim"
   bash run_chip_top_rom_smoke.sh    # 验证 RTL B-1
   bash run_cim_program_ctrl.sh      # 验证 RTL B-2 (8/8 sub-tests)
   bash run_dma_icarus.sh            # 验证 R-M2
   bash run_uart_icarus.sh           # 验证 R-M1 uart
   bash run_spi_icarus.sh            # 验证 R-M1 spi
   bash run_prog_inflight_lock.sh    # 验证 TB-B-03
   bash run_boot_erase_e2e.sh        # 验证 TB-B-03
   bash run_chip_top_rom_hi_smoke.sh
   ```

### 3.5 文档层

1. silicon_bringup_plan.md §6 R-C9 描述：流程是否完整？code 模板能编译过？
   开发顺序是否合理？
2. 07_tapeout_schedule.md 2026-05-02 status sync：内容完整吗？有没有遗漏 audit
   commit？
3. CLAUDE.md：参数表与 RTL 是否一致？FP-001..FP-005 是否需要扩展（这次 audit
   抓的 BLOCKER 是否值得加进 FP）？
4. 文档跨文件链接：用 `python scripts/check_markdown_links.py` 跑一下，看有
   没有死链

### 3.6 边界 / 可疑点

1. R-M2 dma_engine push_stall_cnt：状态机走出 ST_PUSH 后再回来，stall_cnt
   是否正确清零？
2. RTL B-1 chip_top BOOT_ROM_INIT_FILE：相对路径 `"fw/boot_rom/out/boot_rom.hex"`
   是相对于 ASIC synthesis 工具的工作目录还是源文件目录？工艺库流程下要不要改成
   绝对路径或参数化？
3. R-C9 软件 lock：silicon_bringup.c 自己也写 PROG_CTRL.BYPASS_HANDSHAKE=1
   （它自检阶段需要）；别让生产固件代码 *include* silicon_bringup.c 或借用其
   helper 函数，避免误把 BYPASS=1 的代码 path 拉进生产 binary

---

## 四、工作流程

### 4.1 修复流程（main + 同步 FPGA 支线）

1. 在 main worktree（`d:/SoC Design/SoC Design`）改文件
2. 跑 affected sim 验证：`bash sim/run_<gate>.sh`
3. `git add` + `git commit -m "audit-pass3(xxx): 描述"`，xxx ∈ {rtl, fw, doc, sim, tb}
4. **同步到 FPGA 支线**：在 `D:/SoC Design/audit-fpga` worktree：
   ```bash
   cd "D:/SoC Design/audit-fpga"
   git fetch origin
   git merge main  # 应该 fast-forward；如果不能 fast-forward 表示 FPGA 上
                   # 又有了独立改动，停下检查
   git push origin main-fpga-e203-alpha
   ```
5. 验证跨分支一致性：`git diff --name-only main main-fpga-e203-alpha`
   只应输出 25 个 FPGA-only 文件
6. **不要 amend** 已有 commit，每修一组就单独 commit

### 4.2 跨分支一致性 sanity（每次修改后必跑）

```bash
cd "/d/SoC Design/SoC Design"
git fetch origin
echo "=== main HEAD vs origin ==="
git status -sb

cd "D:/SoC Design/audit-fpga"
git fetch origin
echo "=== FPGA HEAD vs origin ==="
git status -sb

# 关键：跨分支文件 diff 只能是 FPGA-only
echo "=== files diff main vs FPGA ==="
git diff --name-only main main-fpga-e203-alpha | sort
# 期望 25 个文件，全部在：
#   doc/main-fpga-e203/  / fpga/  / fpga_synth/zcu102_e203_demo/
#   fw/e203_smoke/  / scripts/{gen_bram_init,program_zcu102_e203}
#   sim/{sim,run}_fpga_programmable_cim_model
#   tb/fpga_programmable_cim_model_tb.sv
# 如果有第 26 个文件（特别是 rtl/ fw/silicon_bringup/ tb/silicon_bringup_tb 等）
# → STOP, 你的 fix 没 sync 好
```

### 4.3 sim regression 全 pass 后才 push

不许在 sim FAIL 状态 push 任何 commit。每次 push 前在 main worktree 跑：
```bash
cd "/d/SoC Design/SoC Design/sim"
for s in run_chip_top_rom_smoke run_chip_top_rom_hi_smoke \
         run_cim_program_ctrl run_dma_icarus run_uart_icarus run_spi_icarus \
         run_prog_inflight_lock run_boot_erase_e2e; do
  echo "=== $s ==="
  bash "$s.sh" 2>&1 | tail -3 | head -2
done
```
全部应输出 `[RESULT] xxx_PASS`。

---

## 五、不要做的

- 不要再修一遍 §二 已修的 audit-pass / audit-pass2 commits（除非发现没修好）
- 不要把任何 frozen tag 移动或删除
- 不要重写任何 commit history（除非用户授权）
- 不要碰 V2 evidence 分支（feature/v2-arm-fpga-demo-conv 等）
- 不要做 FPGA bitgen / 板验——那是 GPT prompt 的任务
- 不要碰模拟 die / 模拟 PCB layout 文件（doc/08 / doc/11 / doc/17 不是审 RTL
  的 scope）

---

## 六、deliverable（你结束时必须交付）

```markdown
# Claude Audit Pass 3 — 总结报告（YYYY-MM-DD）

## 抓到的新问题（按严重度）

### BLOCKER（必修，影响 RTL/FW 流片正确性）
| # | 问题 | 文件:行 | main fix commit | FPGA sync commit |
|---|---|---|---|---|

### CONCERN（应修，sim 覆盖率/可维护性）
（同表格）

### MINOR（建议修，文档/cosmetic）
（同表格）

## 已 push 的 commit
- main: aaaaaaa, bbbbbbb, ...
- main-fpga-e203-alpha: ddddddd（应该都是从 main fast-forward 来的）

## 跨分支一致性 verification
- `git diff --name-only main main-fpga-e203-alpha` → N 文件，全部 FPGA-only ✓
- 列出 N 个文件确认

## sim regression 状态（必须全 PASS）
- 8/8 核心 TB PASS

## 修不动 / 需人工决策的项
（如果有）
```

完。开干吧。
