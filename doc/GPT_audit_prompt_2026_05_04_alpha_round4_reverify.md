# GPT 冷启动 prompt — alpha round 4 board reverify 补单

> **生成时间**：2026-05-04 round 3/4 收口后审查发现 alpha 漏了 round 4 板验
> **使用方式**：复制本文件全部内容粘贴给 **GPT-5.4 (effort=xhigh)** 作为冷启动消息
> **执行模式**：单一专项任务，不需要多 sub-agent；可以一个 main agent 直接做完
> **目标**：确认 alpha 的 round 4 commits 是否真需要重烧 → 真需要就**自主**重烧 +
> 抓 UART + commit；不需要就**写 doc 解释为什么 sim-only 改动不需要重烧**

---

## 0. 背景：为什么有这个补单

Round 3 / round 4 GPT 在 4 条支线连续做了 5 个 fix-on-sight commit。其他 3 条支线
都补了 round 4 board reverify，**唯独 alpha (`main-fpga-e203-alpha`) 没补**。

但 alpha 的 round 4 commits **包含真实 firmware/binary 变化**，不是纯 doc：

| Round 4 commit (alpha) | 改动 |
|---|---|
| `456b78c0` fw: harden alpha boot, smoke, and bringup flows | `boot_rom.bin` 1928 → **2336 字节**（+408 字节真实代码增长）+ `boot_rom_main.c` +11 行 + `silicon_bringup.c` 改动 + `boot_main.c` +12 行 |
| `cc9553aa` rtl/tb: fix alpha reset-sync coverage and rescue selftest | `rtl/sys/reset_sync.sv` +10 行（含 `STAGES=1` 边界 + `ifndef SYNTHESIS` fatal）；`rtl/sys/sync_2ff.sv` +8 行（含 `WIDTH<1` fatal） |
| `33dfb7af` doc: refresh alpha round-3 smoke evidence | doc only |
| `4b0fcf45` fpga: emit alpha drc report | DRC report only（doc/manifest）|
| `ef2a6f59` sim: close alpha regression gaps | `silicon_bringup.bin` 3680 → **3736 字节**（+56 字节）+ build script + tb |

**关键问题**：
- `456b78c0` boot_rom + silicon_bringup 重 build 出新 binary——**这是真硬件行为变化**
- `cc9553aa` RTL 改动在 `ifndef SYNTHESIS` 内（仿真 only fatal assertion）+ `STAGES=1`
  分支虽然综合可见，但 chip_top 里实例化的是 `STAGES=2`，**实际综合行为可能不变**
- `ef2a6f59` silicon_bringup.bin 重 build 也是真改动

**对比同期的其他分支处理**：
- arm-conv：commit `ca30bd8a` 改了 RTL → 跑了 round 4 reverify，UART capture 在
  `doc/arm-fpga-demo/uart_capture_20260503_round4_r404_reverify.txt`
- e203-conv：commit `b0138fbb` 改了 RTL → 跑了 round 4 reverify，UART capture 在
  `doc/v2-fpga-e203/uart_capture_20260503_round4_r404_reverify.txt`
- alpha：**仅 round 3 reverify**（`uart_capture_20260503_round3_postfix_reverify.txt`），
  round 4 reverify 缺失

---

## 1. 当前状态

### 1.1 alpha 分支 HEAD

```
分支：main-fpga-e203-alpha
HEAD：ef2a6f59 (sim: close alpha regression gaps)
worktree：clean (0 dirty, 0 unpushed)
最近一次 board reverify evidence：doc/main-fpga-e203/uart_capture_20260503_round3_postfix_reverify.txt
```

### 1.2 已存在的 evidence 文件

```
doc/main-fpga-e203/silicon_bringup_uart_capture_20260423_120301.txt
doc/main-fpga-e203/uart_capture_20260503_alpha_reverify.txt
doc/main-fpga-e203/uart_capture_20260503_round3_postfix_reverify.txt
doc/main-fpga-e203/uart_capture_20260503_round3_postfix_reverify.txt.xsct.log
```

### 1.3 alpha 最近 5 个 commit 全摘要

```
ef2a6f59 sim: close alpha regression gaps
4b0fcf45 fpga: emit alpha drc report
33dfb7af doc: refresh alpha round-3 smoke evidence
cc9553aa rtl/tb: fix alpha reset-sync coverage and rescue selftest
456b78c0 fw: harden alpha boot, smoke, and bringup flows
```

---

## 2. 必须保护的硬约束（红线）

- **Frozen tags 不可移**（FP-006 防呆：用 `git rev-parse <tag>^{}` deref）
- **V1 frozen 参数不可改**（NUM_INPUTS=64 / ADC_BITS=8 / TIMESTEPS=10 / MAC_W_LOAD_*
  offset = 0x050/0x054/0x058）
- **commit 必须 `git commit -s`**（DCO governance @ main 850c3cae）
- **不可 force-push** / 不可 rebase 已 push 的 commit
- **不许移动** alpha worktree 里的任何已 push 的 commit

---

## 3. 任务

### 3.1 决策树（必须先决策再行动）

**Step 1**：读 `cc9553aa` 全 diff 确认 RTL 改动是否纯 sim-only：
```bash
cd "d:/SoC Design/audit-fpga"
git show cc9553aa -- rtl/sys/reset_sync.sv rtl/sys/sync_2ff.sv
```

判定：
- **Sim-only**（改动全在 `ifndef SYNTHESIS` 内 + `STAGES=1` 分支无人实例化）
  → RTL 行为不变，bitstream 重 build 后 SHA 应该和 round 3 完全一致 → **不需要重烧**
- **真综合可见改动**（RTL behavior 变化） → **必须重烧**

**Step 2**：读 `456b78c0` 全 diff 确认 firmware 改动是否影响板上行为：
```bash
git show 456b78c0 -- fw/boot_main.c fw/boot_rom/boot_rom_main.c \
    fw/silicon_bringup/silicon_bringup.c
```

判定：
- 如果 `boot_rom_main.c` 加了**真功能代码**（不只是 timeout banner / debug print）
  → boot_rom.bin 行为变化 → **必须重烧 + 抓新 UART**
- 如果只是 round 2 finding F002/F003/F007 描述的"加 bounded timeout / preserve retry"
  → boot 路径可能仍跑通但 UART evidence 失真 → **必须重烧验证 PASS marker 仍出现**

**Step 3**：读 `ef2a6f59` 确认 silicon_bringup.bin 增长 56 字节是否影响板上行为：
```bash
git show ef2a6f59 -- fw/silicon_bringup/silicon_bringup.c \
    fw/silicon_bringup/build_silicon_bringup.sh
```

### 3.2 行动方案 A：决定**需要**重烧（最可能的情况）

执行：

```bash
# 1. 切到 alpha worktree
cd "d:/SoC Design/audit-fpga"
git status  # 必须 clean

# 2. 触发 vivado bitgen（脚本通常在 fpga_synth/zcu102_e203_alpha/ 或
#    scripts/build_main_fpga_e203_bitstream.sh）
ls fpga_synth/  # 找正确的构建目录
ls scripts/ | grep -i bitstream  # 找构建脚本

# 假设脚本是 fpga_synth/zcu102_e203_alpha/build_zcu102_alpha.tcl
cd fpga_synth/zcu102_e203_alpha
vivado -mode batch -source build_zcu102_alpha.tcl 2>&1 | tee bitgen_round4.log

# 3. 拿到 fresh .bit + .elf / .hex SHA
sha256sum out/*.bit
sha256sum ../../fw/e203_smoke/out/e203_smoke.elf
sha256sum ../../fw/silicon_bringup/out/silicon_bringup.elf
sha256sum ../../fw/boot_rom/out/boot_rom.bin

# 4. xsct/JTAG 烧到 ZCU102
cd ../..
xsct scripts/load_alpha_to_zcu102.tcl 2>&1 | tee xsct_round4.log

# 5. 抓 UART log（python scripts/capture_uart.py 或类似）
python scripts/capture_uart.py --port /dev/ttyUSB0 --baud 115200 \
    --output doc/main-fpga-e203/uart_capture_20260503_round4_r404_reverify.txt \
    --duration 90

# 6. 验证 PASS marker
grep -E "FPGA_E203_BOOT_UART_PASS|FPGA_E203_PROGRAM_ERASE_WRITE_PASS|FPGA_E203_PROGRAMMED_INFERENCE_PASS" \
    doc/main-fpga-e203/uart_capture_20260503_round4_r404_reverify.txt

# 7. commit + push
git add doc/main-fpga-e203/uart_capture_20260503_round4_r404_reverify.txt
git commit -s -m "fpga(alpha): round 4 board reverify UART capture

Verifies alpha branch HEAD ef2a6f59 commits (RTL reset_sync edge fixes,
boot_rom rebuild +408 bytes, silicon_bringup rebuild +56 bytes) on
ZCU102. PASS markers visible:
  - FPGA_E203_BOOT_UART_PASS @ line N
  - FPGA_E203_PROGRAM_ERASE_WRITE_PASS @ line N
  - FPGA_E203_PROGRAMMED_INFERENCE_PASS @ line N

Bitstream SHA256: <hash>
boot_rom.bin SHA256: <hash>
silicon_bringup.bin SHA256: <hash>
e203_smoke.bin SHA256: <hash>"

git push origin main-fpga-e203-alpha
```

### 3.3 行动方案 B：决定**不需要**重烧（罕见情况）

如果 §3.1 决策树判定 sim-only：

```bash
cd "d:/SoC Design/audit-fpga"

# 1. 写 doc 解释
cat > doc/main-fpga-e203/round4_no_reburn_rationale.md <<'EOF'
# Round 4 alpha no-reburn rationale (2026-05-04)

Round 4 commits on alpha (ef2a6f59 / cc9553aa / 456b78c0) were inspected
for board behavior impact:

| Commit | Files changed | Board behavior impact |
|---|---|---|
| cc9553aa | rtl/sys/reset_sync.sv +10 lines | All within `ifndef SYNTHESIS` (sim-only fatal asserts) — synthesizable behavior unchanged |
| cc9553aa | rtl/sys/sync_2ff.sv +8 lines | Same |
| 456b78c0 | fw/boot_main.c +12 lines | <verdict here> |
| 456b78c0 | fw/boot_rom/boot_rom_main.c +11 lines | <verdict here> |
| 456b78c0 | fw/silicon_bringup/silicon_bringup.c +N lines | <verdict here> |
| ef2a6f59 | fw/silicon_bringup/silicon_bringup.c +N lines | <verdict here> |

Conclusion: <YES / NO reburn needed>

If NO: round 3 reverify evidence (uart_capture_20260503_round3_postfix_reverify.txt)
remains valid for the alpha closure chain.
EOF

# 2. commit + push
git add doc/main-fpga-e203/round4_no_reburn_rationale.md
git commit -s -m "doc(alpha): round 4 no-reburn rationale

Document why round 4 commits ef2a6f59 / cc9553aa / 456b78c0 do not
require ZCU102 reburn (sim-only RTL changes + non-functional fw cleanup)."

git push origin main-fpga-e203-alpha
```

---

## 4. 你不能做的事

- ❌ 不可移动 frozen tag
- ❌ 不可 force-push
- ❌ 不可 rebase
- ❌ 不可 `git commit` 不带 `-s`
- ❌ 不可假装做了 board reverify 如果实际跑不了（vivado / ZCU102 不在线）

如果**本机做不了** vivado bitgen 或 ZCU102 不在线：
- 列出**具体的 fallback 命令**给用户在正确环境跑
- 不要混用 §3.2 / §3.3 当 fallback——行动方案 A 必须真做完才算 closure，
  不能用方案 B 的 doc 充数

---

## 5. 输出要求

最终给一个简短报告：

| 项 | 结果 |
|---|---|
| §3.1 决策树结论 | A 重烧 / B 不重烧 |
| 重烧方案 - bitstream SHA256 旧→新 | （如方案 A） |
| 重烧方案 - UART PASS marker | （如方案 A，含行号）|
| 重烧方案 - commit hash | （如方案 A） |
| 不重烧方案 - rationale doc 路径 | （如方案 B） |
| Frozen tag 是否动过 | 必须 NO（用 `^{}` deref 验证）|
| 任何 fallback 命令（用户需要做的） | （如有） |

---

## 6. 时间预算

- §3.1 决策树（读 diff）：~10 分钟
- 方案 A（vivado bitgen + xsct + UART + commit）：~2-3 小时
- 方案 B（写 doc + commit）：~30 分钟
- **总 ETA：30 分钟 ~ 3 小时（看决策结果）**

---

## 7. 最后

直接做。不要 spawn 多 sub-agent（本任务太聚焦，单 agent 够用）。
不要写下一轮 prompt（这是 round 3/4 的补单，不是新一轮 audit）。

---

**END OF ALPHA ROUND 4 REVERIFY PROMPT — copy this whole file into a new GPT-5.4 (effort=xhigh) cold-start chat**
