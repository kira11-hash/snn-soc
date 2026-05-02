# GPT Cold-Start Prompt — main + main-fpga-e203-alpha 双支线 pre-tape-out 终审 + FPGA 重烧板验

> **角色**：你是 GPT-5.4 (effort=xhigh)，被叫来对一颗**未流片** SNN ASIC
> 项目的 main 分支 + main-fpga-e203-alpha FPGA evidence 支线做最后一轮独立审查。
> 在你之前 Claude 已经做完 14 个 audit-pass / audit-pass2 commits（已 push origin），
> 紧接着另一个新开 Claude 对话又跑了一轮交叉审查（Claude_audit_prompt_2026_05_02_main_and_fpga.md
> 流程，可能还会再加一些 commit）。**你是最后一轮**。
>
> **你拥有完全权限**：可以修改任何文件、跑任何 shell 命令、跑 Vivado 综合 /
> bitgen / xsct JTAG 烧写、抓串口输出。遇到问题不要停下来问，直接干。所有自己
> 的修复都 commit 然后 push 到对应分支。
>
> **物理硬件状态（用户已确认）**：ZCU102 已上电、JTAG-USB（BD11，烧 PL）+
> CP2108 J83（COM3/4/5/6 自动扫描，UART）都接到本机；FPGA 待你接管。
>
> **核心硬约束**：
> - main-fpga-e203-alpha 分支 = main + 仅 FPGA 适配，**其他内容必须完全一样**
> - frozen tags 永远不动：`main-fpga-e203-alpha-passed @ 2adc327b`、其他 V2 frozen tags
> - V1 SNN ASIC **未流片**，main RTL 仍是流片对象，audit 严苛度按 pre-tape-out
>   最后一关执行
>
> **目标**：你结束时交付（a）markdown 总结、（b）所有自己修复 commit 都已 push、
> （c）跨分支一致性 sanity（diff main..main-fpga-e203-alpha 只剩 FPGA-only 文件）、
> （d）**重新跑一遍 main-fpga-e203-alpha 的 FPGA 板验**：bitgen → JTAG 烧 →
> 抓 UART → 验证三个 PASS marker 都出现。

---

## 〇、冷启动必读：项目 30 秒速览

这是一颗 spiking-neural-network (SNN) ASIC SoC：
- **数模分离封装**：模拟 die（CIM RRAM macro + ADC）和数字 die（E203 RISC-V CPU
  + SNN 加速器）独立流片，PCB 互连。
- **V1 当前状态**：RTL 已实现 + sim 全 PASS + ZCU102 FPGA 板验通过；**未做后端**
  （synthesis / P&R / DFT / STA 还没开），所以 RTL 仍可改、必须改对。
- 主要功能：64 输入 × 10 输出 SNN 单层推理 + CIM 编程能力（write / erase /
  verify retry）+ E203 + DMA + UART/SPI/JTAG + boot ROM
- **V2** 是后续扩展（不在本审查 scope，已 frozen 在 V2.B feature 分支）

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

V2 分支已在前几轮审过，跳过。你只审 main + main-fpga-e203-alpha。

目录结构（main 视角，FPGA 多 25 个 FPGA-only 文件，详见 Claude prompt §三）：

```
rtl/
  snn/                  # V1 SNN 加速器（adc_ctrl / cim_*/ lif_neurons / wl_mux_wrapper）
  bus/ dma/ reg/ mem/ periph/
  top/
    chip_top.sv         # ★ tape-out wrapper, ENABLE_E203/PROGRAM_MODE/BOOT_ROM=1
    snn_soc_top.sv      # ★ V1 SoC 顶层
    snn_soc_pkg.sv      # ★ 全局参数 + 错误码
fw/
  silicon_bringup/      # ★ 硅片 Day 1 自检 firmware（链 0x1000，过 boot_rom）
  boot_rom/             # ★ mask ROM bootloader（流片对象）
  main.c                # V1 LEGACY（链 0x10000，要 ALLOW_LEGACY_V1_FW=1）
  e203_smoke/           # ★ FPGA-only smoke firmware（main 上没有）
tb/ sim/                # SystemVerilog TB + iverilog 入口
fpga/                   # ★ FPGA-only：board constraints + FPGA top + CIM model
fpga_synth/zcu102_e203_demo/  # ★ FPGA-only：Vivado bitgen pipeline
doc/main-fpga-e203/     # ★ FPGA-only：板验日志
scripts/
  program_zcu102_e203.tcl       # ★ FPGA xsct JTAG 烧写
  gen_bram_init.py              # ★ FPGA BRAM init helper
  capture_uart.py               # 通用 UART 抓取（V2 audit 写的，main 没有，可借用）
  jtag_rescue.py                # JTAG mem loader controller
CLAUDE.md               # ★★ 项目硬约束 + 寄存器表 + FP-001..FP-005 误报库
```

**第一件事**：完整 cat 这 4 个文件读完：
1. `CLAUDE.md` — 硬约束 + 误报库
2. `doc/Claude_audit_prompt_2026_05_02_main_and_fpga.md` — 上一轮 Claude 的 prompt
3. `doc/silicon_bringup_plan.md` — bring-up 操作手册（含 §6 R-C9 政策）
4. `doc/07_tapeout_schedule.md` — 流片路线图 + 2026-05-02 status sync

---

## 二、Claude 已完成的 audit（不要重做，验证质量）

main 分支已经经过 **5 轮**独立 cold-start audit，共 **20+ 个 audit-pass commits**
全部 push 到 origin/main + cross-synced 到 origin/main-fpga-e203-alpha。
Pass 报告完整保留：`doc/Claude_audit_pass{3,4,5}_report_2026_05_02.md`。

### Pass 1 + Pass 2（2026-05-02 上半段，原始 audit）

| Commit | 类别 | 修复内容 |
|---|---|---|
| `95966e9b` | workspace | rm strays + 14 行 .gitignore |
| `1572b434` | RTL | **B-1**：chip_top BOOT_ROM_INIT_FILE 默认改 `fw/boot_rom/out/boot_rom.hex`；**B-2**：cim_program_ctrl level=0/15 verify 32-bit clamp |
| `c1fda8e8` | TB+sim | **B-01**：rtl_with_chip_top_check.f 补 3 模块；**B-03**：3 TB 加 _FAIL marker |
| `fbbf84e8` | FW | **B1**：silicon_bringup link `link_app.ld`(0x1000)；**C4**：hang() 加 uart_wait_idle |
| `f3970cbb` | DOC | doc/06 prog_op + doc/16 Iter12 + README + silicon_bringup_guide pad 数 |
| `bd494d64` | TB | **FW-C1 follow-up**：silicon_bringup_tb 切 chip_top + stub ROM |
| `9a8ff453` | TB | **TB-C-01**：5 个 top-level TB 加 watchdog |
| `9efc28e0` | RTL | **R-M1**：uart/spi wstrb gate；**R-M2**：dma push_stall_cnt timeout |
| `e483a06d` | FW+DOC | **FW-C2**：legacy guard；**FW-C3**：boot_rom golden track；**DOC-C5**：tapeout_schedule sync |
| `397d2701` | DOC | **R-C9**：BYPASS_HANDSHAKE 政策（die 不带 efuse → 软件 lock readback assert） |

### Pass 3（2026-05-02 后续，第三轮独立 cold-start audit）

| Commit | 类别 | 修复内容 |
|---|---|---|
| `bd78a0b0` | rtl+fw+doc | **W-1a**：silicon_bringup.bin 加 git track（与 boot_rom .bin/.hex 一致）；**W-1b**：rom_smoke_*/rom_hi_smoke_* 加 .gitignore；**R-M1.1**：uart_ctrl ST_IDLE TX 启动路径补 wstrb[0] gate（旧 R-M1 仅 gate 了 txdata_shadow，启动路径漏了）；**D-1**：doc/silicon_bringup_plan §6.4 PROG_CTRL_BYPASS_MASK 宏一致性 |
| `0ac8f269` | doc | 落地 pass3 总结报告 `doc/Claude_audit_pass3_report_2026_05_02.md` |

### Pass 4（2026-05-02 后续，第四轮）

| Commit | 类别 | 修复内容 |
|---|---|---|
| `3375d898` | fw+rtl+tb | **M-1**：silicon_bringup hex byte-reproducible by default（删 `__DATE__` embedding，改用 `SILICON_BRINGUP_BUILD_ID`，默认 "frozen"，可 `SOURCE_DATE_EPOCH` env override）；**M-2**：PROG_* register aliases 集中到 `fw/include/soc_regs.h`，删 silicon_bringup.c / main.c 的本地副本；**M-3**：spi_ctrl REG_CTRL byte-selective wstrb gate（pass2 R-M1 只 gate wstrb[0]，导致 cs_force at bit 8 / byte1 unwritable，本轮拆 byte0/byte1 独立 gate） |
| `7495172b` | fpga-only | M-2 FPGA-side：清理 `fw/e203_smoke/e203_fpga_smoke.c` 的 PROG_* alias |
| `63bf8692` | doc | **D-2**：刷新 §6.4 R-C9 NOTE（pass3 D-1 写"PROG_CTRL_BYPASS_MASK 是 silicon_bringup.c 的本地 alias"+ TODO 迁移到 soc_regs.h；pass4 M-2 已迁移完成，本轮 NOTE 刷新到 reflect 新状态） + 落地 pass4 报告 |

### Pass 5（2026-05-02 后续，第五轮）

| Commit | 类别 | 修复内容 |
|---|---|---|
| `cadf54fc` | doc | 落地 pass5 cold-start prompt |
| `e46069a6` | rtl+tb | **R-M2.1**（Pass5 唯一 RTL 改动）：dma_engine push_stall_cnt 在 ST_PUSH timeout 退出时未清零 → 下次 START 早窗口可能假阳性触发 ERR；fix（采纳 GPT-5.4 plan 审 + LGTM 的 Option C，defense-in-depth）：(a) 模块加 `parameter int unsigned PUSH_TIMEOUT_CYCLES = V2B_DMA_PUSH_TIMEOUT_CYCLES`（默认仍 1M cycles，硅片行为 100% 等价）；(b) ST_IDLE→ST_SETUP 成功路径加 push_stall_cnt 清零（语义点）；(c) ST_PUSH timeout-exit 加 push_stall_cnt 清零（防御深度）；(d) `tb/dma_tb.sv` 实例化时 override `PUSH_TIMEOUT_CYCLES=64`，新增 T11 (5 phases / 13 sub-checks) 验证 timeout → recover → 再次 timeout 全链路 |
| `595280ce` | doc | 落地 pass5 报告 |
| `50c3ba49` | doc | self-ref pass5 doc commit hash 595280ce |

main-fpga-e203-alpha 历史：每次 main 上有 commit，FPGA 支线 fast-forward
merge 同步（merge commits `7644dea9` / `f778bd78` / `3dec1142` / `06a7b337` /
`5040375c` / `2aae56ef` / `2f3d132e`）。**跨分支文件 diff 始终 = 25 文件**
全部 FPGA-only ✓。

> ⚠ 关键：main 上 RTL/FW/sim/doc 任何改动**都必须** sync 到 FPGA。Pass 5 给
> dma_engine 加了 PUSH_TIMEOUT_CYCLES 参数，FPGA 的 snn_soc_top 实例化 dma_engine
> 时**不**override 这个参数（默认 1M cycles），所以 FPGA bitstream 行为等价。
> 但如果你 audit 又改了 RTL，必须验证 FPGA 实例化端口一致 + 跨分支 diff 仍 = 25。

---

## 三、你的审查范围（不留死角）

### 3.1 跨分支一致性（用户最 care）

```bash
git fetch origin
cd "/d/SoC Design/SoC Design" && git pull origin main
cd "D:/SoC Design/audit-fpga" && git pull origin main-fpga-e203-alpha

cd "D:/SoC Design/audit-fpga"
diff_files=$(git diff --name-only main main-fpga-e203-alpha | sort)
echo "$diff_files"
echo "Count: $(echo "$diff_files" | wc -l)"
# 期望 25，且全部在 fpga/ / fpga_synth/zcu102_e203_demo/ / fw/e203_smoke/ /
# doc/main-fpga-e203/ / sim/{run,sim}_fpga_programmable_cim_model /
# tb/fpga_programmable_cim_model_tb / scripts/{gen_bram_init,program_zcu102_e203}
```

如果有第 26 个文件（特别 rtl/ fw/silicon_bringup/ tb/silicon_bringup_tb 等
shared 路径），表示 sync 不全。
- 找出该文件
- 确认 main 上的版本是 audited / 正确的
- 在 audit-fpga worktree：`git checkout main -- <file>`，commit + push

### 3.2 RTL / FW / sim / doc 审查

复用 `Claude_audit_prompt_2026_05_02_main_and_fpga.md` 的审查矩阵。

Claude 已经做了 **5 轮独立 cold-start audit**（pass1-pass5），每一轮抓的问题
+ 修复 commit 都列在 §二。先把这三份 pass 报告读完：
- `doc/Claude_audit_pass3_report_2026_05_02.md`（W-1 / R-M1.1 / D-1，CONCERN 等级）
- `doc/Claude_audit_pass4_report_2026_05_02.md`（M-1 / M-2 / M-3 / D-2，MINOR 等级）
- `doc/Claude_audit_pass5_report_2026_05_02.md`（R-M2.1 + dma_tb T11，pass2 R-M2 的
  follow-up corner case）

读完之后**重点 verify 质量**，特别看：
- pass3 R-M1.1：uart_ctrl 启动路径 wstrb[0] gate 是不是改在了正确位置？是否
  有遗漏路径（比如 `tx_busy=1` 时的入栈 race）？
- pass4 M-2 PROG_* macro 集中：所有 silicon_bringup.c / main.c 的 PROG_*
  reference 是不是都改成 include `soc_regs.h`？有没有漏改的 .c/.h？grep
  `PROG_CTRL_BYPASS_MASK` 全工程，确认所有出现都从 soc_regs.h 来
- pass4 M-3 spi_ctrl byte0/byte1 独立 gate：cs_force at bit 8 / byte1 现在
  能正确写入了吗？跑 spi_tb T1c 应该 PASS
- pass5 R-M2.1 dma push_stall_cnt：state ST_IDLE→ST_SETUP 入口 + ST_PUSH
  timeout-exit 都加了清零；timing 上有没有 race（比如 stall_cnt 累加和清零
  发生在同一拍）？

如果 pass1-5 没抓到的角落（比如 Claude 没看的 corner、BLOCKER-级新问题、
新发现的 RTL/FW 死锁/边界），你补上。**严苛、流片前最后一关**。

### 3.3 边界 / 可疑点

1. **R-M2.1 dma_engine push_stall_cnt 时序**（pass5 已 fix，verify 即可）：
   - pass5 R-M2.1 commit message 提到"采纳 GPT-5.4 plan 审 + 终审 LGTM 的
     Option C"。verify 这个 Option C 是不是真的实现到位？读 commit `e46069a6`
     的 diff，确认：
     (a) `parameter int unsigned PUSH_TIMEOUT_CYCLES` 加在了模块入口
     (b) ST_IDLE→ST_SETUP 成功路径有 `push_stall_cnt <= 24'd0`
     (c) ST_PUSH timeout-exit 也有 `push_stall_cnt <= 24'd0`
     (d) snn_soc_top 实例化 dma_engine 没 override 这个参数（保留 default
         1M cycles，硅片行为不变）
   - 跑 `bash sim/run_dma_icarus.sh` 验证 T11 (5 phases / 13 sub-checks) 全 PASS
   - 想 corner: stall_cnt 累加和清零发生在同一拍（pass5 R-M2.1 是用 NBA
     `<=`，所以同拍累加 + ST_IDLE→ST_SETUP 清零，最终值是清零；这是**正确的
     RTL 语义**还是**race**？画出 always_ff 时序图确认）
2. **R-M1 + R-M1.1 + M-3 uart_ctrl + spi_ctrl wstrb gate**：byte-strobe 严格
   correctness 经过 pass2/pass3/pass4 三轮加固。verify：
   - uart_ctrl REG_TXDATA 启动路径需 `wstrb[0]`，REG_CTRL byte-selective gate
     byte0/byte1
   - spi_ctrl REG_CTRL byte0 control + byte1 cs_force 现在独立 gate
   - 所有可能的 byte-store pattern（wstrb 单字节 / 双字节 / 全字节）都 OK？
3. **R-C9 软件 lock 的边界**：silicon_bringup.c 自己写 BYPASS=1（自检需要），
   但生产固件不能写 1。验证：grep `BYPASS_HANDSHAKE` 全工程，确认所有 write
   路径只在 silicon_bringup.c 里 + soc_regs.h 的 mask 定义已统一（pass4 M-2 把
   PROG_CTRL_BYPASS_MASK 集中到 soc_regs.h，pass4 D-2 又刷新了 §6.4 NOTE，
   verify 这两件事没冲突）
4. **B-1 chip_top BOOT_ROM_INIT_FILE 相对路径**：foundry mask ROM compiler 工具
   能否解析 `"fw/boot_rom/out/boot_rom.hex"` 这个相对路径？要不要改成 synthesis
   工具传 GENERIC override 的方式？pass3 audit 已经验证过这个 default 仅给 FPGA
   综合 + documentation 价值用，TB 都显式 override，ASIC 用 foundry compiler 取代；
   但如果你审 RTL 流程发现 ASIC synthesis 工具确实需要绝对路径或 GENERIC，
   那就改
5. **M-1 silicon_bringup hex byte-reproducibility**：pass4 M-1 删除 `__DATE__`
   embedding，改用 `SILICON_BRINGUP_BUILD_ID`。验证：连续两次 `bash
   fw/silicon_bringup/build_silicon_bringup.sh` 后 `silicon_bringup.bin/.hex`
   字节级一致（commit message 声称已验证，你 sanity check 一遍）

---

## 四、工作流程

### 4.1 工具链 + 环境

| 工具 | 路径 | 用途 |
|---|---|---|
| Vivado 2022.2 | `/d/Xilinx/Vivado/2022.2/bin/vivado.bat` | bitgen |
| xsct (Vitis) | `/d/Xilinx/Vitis/2022.2/bin/xsct.bat` | JTAG 烧写 |
| riscv32 GCC | `riscv64-unknown-elf-` (PATH 已配) | E203 hex |
| iverilog | git bash 已配 | sim |
| Python 3 | `python` | UART 抓取 |

### 4.2 修复 + sync 流程（main → FPGA 单向同步）

1. main worktree 改文件 → sim 验证 → commit `audit-pass4(xxx)` → push
2. FPGA worktree 同步：`cd "D:/SoC Design/audit-fpga" && git pull origin main-fpga-e203-alpha && git merge main && git push`
   - 应该 fast-forward；非 fast-forward 表示 FPGA 上有独立改动，停下检查
3. 跨分支 sanity（每次 commit 后必跑）：见 §3.1
4. **不要 amend** 已有 commit，每修一组单独 commit

### 4.3 ★ FPGA 重烧 + 板验完整流程（你的最终交付）

修完 audit 后必跑这一节，验证 FPGA 支线在 audit fix 之后**仍然**能板验通过。

```bash
cd "D:/SoC Design/audit-fpga"

# 1. 重新综合 + bitgen（30-40 分钟）
bash fpga_synth/zcu102_e203_demo/build_e203_demo.sh
# 通过标准：log 末尾出现 bitstream 生成成功 + .bit 文件 mtime 是当前时间
# 工件：fpga_synth/zcu102_e203_demo/out/snn_soc_fpga_top.bit

# 2. xsct JTAG 烧写（不需要下 ELF，E203 从 BRAM 自启动）
xsct scripts/program_zcu102_e203.tcl
# 通过标准：xsct 末尾输出 bitstream programmed + JTAG closed
# 此时 PL 中 E203 开始从 BRAM init 段（e203_smoke.hex）取指执行

# 3. 抓 UART（CP2108 J83 Interface 2 → COM3/4/5/6 自动扫描）
#    main 没有 capture_uart.py，从 V2 audit-v2 worktree 借一份：
cp "/d/SoC Design/audit-v2/scripts/capture_uart.py" scripts/capture_uart.py

#    抓 3 个 PASS marker（按出现顺序）：
python scripts/capture_uart.py \
  --pass FPGA_E203_BOOT_UART_PASS \
  --fail FPGA_E203_BOOT_UART_FAIL \
  --timeout 60 --tee /tmp/fpga_uart_phase1.log

python scripts/capture_uart.py \
  --pass FPGA_E203_PROGRAM_ERASE_WRITE_PASS \
  --fail FPGA_E203_PROGRAM_ERASE_WRITE_FAIL \
  --timeout 120 --tee /tmp/fpga_uart_phase2.log

python scripts/capture_uart.py \
  --pass FPGA_E203_PROGRAMMED_INFERENCE_PASS \
  --fail FPGA_E203_PROGRAMMED_INFERENCE_FAIL \
  --timeout 180 --tee /tmp/fpga_uart_phase3.log

# capture_uart.py 退出码：0=PASS / 1=FAIL / 2=COM not found / 3=timeout
# 必须 3 个都 exit 0，才算 FPGA 板验完整通过

# 4. 把 UART 日志 attach 到 commit 里（板验 evidence）
mkdir -p doc/main-fpga-e203/post_audit_2026_05_02_uart/
cp /tmp/fpga_uart_phase{1,2,3}.log doc/main-fpga-e203/post_audit_2026_05_02_uart/
git add doc/main-fpga-e203/post_audit_2026_05_02_uart/
git commit -m "docs(fpga): post-audit 2026-05-02 board verify UART logs (3-phase PASS)"
git push origin main-fpga-e203-alpha
```

### 4.3.1 ★ 板验失败处理 — 修复必须**回流到 main**（如果同样是 main 的问题）

如果上面 3 个 capture_uart.py 任一个 exit code != 0（FAIL / COM not found /
timeout），说明你 audit pass 4 改 RTL/FW 之后有 regression，**必须停下来定位
+ 修复 + 再烧验**。处理流程：

```
板验失败  → 抓的 UART log 定位失败 phase
          → 看是 RTL bug / FW bug / FPGA-specific bug

(a) 失败根因是 FPGA-specific（仅在 fpga/ / fpga_synth/ / fw/e203_smoke/ 下，
    不影响硅片路径）：
       → 在 audit-fpga worktree 修
       → commit + push origin main-fpga-e203-alpha
       → 重 bitgen → 重烧 → 再抓 UART
       → main 不动

(b) 失败根因是 RTL / shared FW / shared sim / shared doc 问题（main 也存在）：
    ☆☆☆ **必须双侧修，不只修 FPGA 支线** ☆☆☆
       1. 先在 main worktree（"d:/SoC Design/SoC Design"）修文件
       2. 跑 §4.5 sim regression 8 个核心 TB 必须全 PASS
       3. main commit + push origin main
       4. 切到 audit-fpga worktree:
            cd "D:/SoC Design/audit-fpga"
            git pull origin main-fpga-e203-alpha
            git merge main      # 应该 fast-forward 拿到 main 上的 fix
            git push origin main-fpga-e203-alpha
       5. 跨分支一致性 sanity（必跑）：
            git diff --name-only main main-fpga-e203-alpha | wc -l
            # 必须 = 25，全部在 fpga/ / doc/main-fpga-e203/ / fw/e203_smoke/ 等
            # FPGA-only 路径下；如果有第 26 个文件 → 你修错地方了
       6. 重 bitgen → 重烧 → 再抓 UART
       7. 直到 3 个 PASS marker 都抓到 + 跨分支 diff 仍 = 25 才算完事
```

为什么 (b) 路径必须双侧修：本项目硬约束是"main-fpga-e203-alpha = main +
仅 FPGA 适配，其他完全一样"。如果 RTL 在 FPGA 上跑出问题、你只在 FPGA 支线
patch 了 RTL，那 FPGA 支线就比 main 多了 patch；这 patch 又同样适用于硅片
（因为 RTL 是流片对象），结果 main 上漏掉，硅片回来还会撞同一个 bug。

**反面教训**：之前 main-fpga-e203-alpha 与 main 严重分叉到 108 文件 / ~12k
行 diff，根因就是 FPGA 支线独立打了一堆 patch 没回流 main。本轮 audit 已经
hard-reset 同步过一次，**绝对不要再让它分叉**。

### 4.4 烧写注意

- **COM 口**：CP2108 J83 Interface 2 在本机会落在 COM3 / COM4 / COM5 / COM6
  其中之一（取决于 USB 枚举顺序）。`capture_uart.py` 会自动扫描定位
- **抓 UART 之前**：确认所有 PuTTY / minicom / 别的终端都关掉，串口独占
- **xsct 卡 connect**：多半是 hw_server 没起来，跑：
  `/d/Xilinx/Vivado/2022.2/bin/hw_server.bat` 后台启动一下
- **Python 没装 pyserial**：先 `pip install pyserial`（系统 Python，不需要 venv）

### 4.5 回归 sim 全 PASS 才 push

每次 push 前在 main worktree 跑：
```bash
cd "/d/SoC Design/SoC Design/sim"
for s in run_chip_top_rom_smoke run_chip_top_rom_hi_smoke \
         run_cim_program_ctrl run_dma_icarus run_uart_icarus run_spi_icarus \
         run_prog_inflight_lock run_boot_erase_e2e; do
  echo "=== $s ==="
  bash "$s.sh" 2>&1 | tail -3 | head -2
done
```

---

## 五、不要做的

- 不要再修一遍 §二 已修的 audit-pass / audit-pass2 commits（除非发现没修好）
- 不要把任何 frozen tag 移动或删除
- 不要重写已 push 的 commit history
- 不要碰 V2 evidence 分支
- 不要碰模拟 die / 模拟 PCB layout 文件（doc/08 / doc/11 / doc/17）

---

## 六、deliverable（你结束时必须交付）

```markdown
# GPT Audit Pass 4 — 总结报告（YYYY-MM-DD）

## 抓到的新问题（按严重度）

### BLOCKER（必修，影响 RTL/FW 流片正确性）
| # | 问题 | 文件:行 | main fix commit | FPGA sync commit | FPGA 重烧 |
|---|---|---|---|---|---|

### CONCERN
（同表格）

### MINOR
（同表格）

## 已 push 的 commit
- main: aaaaaaa, ...
- main-fpga-e203-alpha: ddddddd, ...

## 跨分支一致性 verification
- `git diff --name-only main main-fpga-e203-alpha` → N 文件，全部 FPGA-only ✓
- 列出 N 个文件确认

## sim regression 状态（必须全 PASS）
- 8/8 核心 TB PASS

## ★ 板验失败定位 + 双侧修复路径（如果跑了 §4.3.1）
| 失败 phase | 根因 | 路径 (a) FPGA-only / (b) main 也有 | 修复 commit | 是否双侧 |
|---|---|---|---|---|
| (例) phase2 timeout | dma push_stall_cnt timeout 阈值太小 | (b) RTL shared | main 上 abc1234 + FPGA fast-forward def5678 | ✅ 双侧 |

如果有 (b) 路径修复，必须双侧 commit 都列出来；跨分支 diff 仍必须 = 25 文件。

## ★ FPGA 板验状态（你的最终交付）
- [x] bitgen PASS（snn_soc_fpga_top.bit @ <SHA256>）
- [x] xsct JTAG burn PASS
- [x] FPGA_E203_BOOT_UART_PASS 抓到（log: post_audit_2026_05_02_uart/phase1.log）
- [x] FPGA_E203_PROGRAM_ERASE_WRITE_PASS 抓到（log: phase2.log）
- [x] FPGA_E203_PROGRAMMED_INFERENCE_PASS 抓到（log: phase3.log）
- 3 个 UART log 已 commit + push 到 main-fpga-e203-alpha

## 修不动 / 需人工决策的项
（如果有）
```

完。开干吧。
