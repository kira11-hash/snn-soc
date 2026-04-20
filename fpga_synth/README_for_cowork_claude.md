# 给协作 Claude 的指令：跑 Vivado 综合 + 反馈报告

**任务来源**：用户在外面，本机已装 Vivado，需要你帮忙跑一次 synthesis-only 并把报告反馈给前一个 Claude session。  
**前 session 定位的上下文**：项目 `d:\SoC Design\SoC Design`，Phase A-C + B3 都已 bit-exact 通过（9 个 clean commits），现在需要 Vivado 综合报告来决定是否改 `cim_mac_behavioral_v2`（256-input 并行加法树风险）。  
**你不需要改任何 RTL 代码**。只要跑脚本 + 拿报告 + 反馈。

---

## Step 1: 确认 Vivado 可用

```bash
# Windows Git Bash / PowerShell / CMD 里运行：
vivado -version
```

如果命令找不到，Vivado 的 bin 目录通常在：
- `C:/Xilinx/Vivado/<version>/bin/` (完整安装版)
- `C:/Xilinx/Vivado_Lab/<version>/bin/` (Lab Tools 版，只能烧 bitstream，综合用不了，这个版本**不行**)

需要 **Vivado ML Standard / Enterprise / WebPack**，不是 Lab Tools。

如果 `vivado -version` 报错，先告诉用户：
```
Vivado 装在哪里？请提供完整路径，或者把 Vivado bin 加进 PATH。
```

---

## Step 2: 跑综合脚本

```bash
cd "d:/SoC Design/SoC Design/fpga_synth"
vivado -mode batch -source synth_v2b.tcl
```

**预计时间**：10-30 分钟（首次会编译 Xilinx 内置 IP 库，慢一点；后续快）。

**综合期间**：
- Vivado 会在 `fpga_synth/v2b_synth/` 下创建 project 目录
- 报告会产出到 `fpga_synth/reports/`
- 你会看到大量 INFO/WARNING 滚屏，只要最后没 ERROR 就 OK
- 如果有 ERROR 最常见原因：
  1. `vivado` 命令找不到 → 看 Step 1
  2. 目标 device 不支持 → 脚本里 `PART = xc7a100tcsg324-1`，如果 WebPack 不包含，改成 `xc7a35tcpg236-1`（更小但 WebPack 肯定支持）
  3. SystemVerilog 语法被 Vivado 拒绝 → 告诉用户源码可能需要 tweaks

---

## Step 3: 读取并反馈四个关键数字

综合完后，**最重要的文件是 `fpga_synth/reports/post_synth_status.rpt`**，里面一页话总结。

```bash
cat "d:/SoC Design/SoC Design/fpga_synth/reports/post_synth_status.rpt"
```

内容示例（你应该看到类似这样的）：
```
==============================================
V2.B standalone SoC top — synthesis summary
Target: xc7a100tcsg324-1  Top: snn_soc_v2b_top
==============================================
LUTs      : 8342
FFs       : 5123
BRAMs     : 11.5
DSPs      : 0
WNS (ns)  : -2.5     (negative = timing FAIL)

TIMING_STATUS : FAIL (missed clock period)

Artix-7 XC7A100T budget: 63400 LUT, 126800 FF, 270 BRAM18, 240 DSP48
```

**把这 4 个数字 + TIMING_STATUS 反馈给用户**。格式：

> Vivado 综合结果：
> - LUTs: XXXX
> - FFs: XXXX
> - BRAMs: X
> - DSPs: X
> - WNS: Xns
> - TIMING: PASS/FAIL

---

## Step 4: 抽取 memory inference 关键信息

Claude 前 session 特别关心 `cim_mac_behavioral_v2` 里的 `w_pos_mem` / `w_neg_mem` 和 `tile_partial_buf` 里的 `mem` 是否被 map 到 BRAM（期望）还是 distributed RAM（异常）。

```bash
# 在 synth_log 里找 RAM inference 报告
grep -E "inferred|RAM|BRAM|LUT_RAM" "d:/SoC Design/SoC Design/fpga_synth/reports/synth_log.txt" | head -30
```

你会看到形如：
```
[Synth 8-619] Inferred Distributed RAM ...
[Synth 8-688] Distributed RAM memory ...
[Synth 8-6014] Unused sequential element ...
```

**特别找这些字眼**（把匹配行截图或贴给用户）：
- `w_pos_mem` / `w_neg_mem` 后面跟 `inferred ... Block RAM` = 好 ✅
- `w_pos_mem` / `w_neg_mem` 后面跟 `inferred ... Distributed RAM` = 需要改 ⚠️
- `tile_partial_buf` 或 `u_tpb.mem` 类似判断

---

## Step 5: 给用户的反馈包

最终你只需要贴给用户 **三样东西**：

### 1. One-line summary
（从 Step 3 的 post_synth_status.rpt 贴过来）

### 2. Memory inference lines
（从 Step 4 grep 出来，最多 30 行）

### 3. Critical path snippet (optional, 如果 TIMING FAIL)

```bash
# 找 critical path 的起点终点
grep -A 20 "Slack (VIOLATED)" "d:/SoC Design/SoC Design/fpga_synth/reports/timing.rpt" | head -40
```

贴出来。

---

## Step 6: 不要做的事

- ❌ 不要改任何 RTL 源码
- ❌ 不要进 P&R（`launch_runs impl_1`）—— 目前只要综合报告
- ❌ 不要生成 bitstream
- ❌ 不要删 `v2b_synth/` project 目录（后面可能要复用）
- ❌ 如果综合失败 ≥3 次，停下来告诉用户，不要盲目改脚本

---

## 快速 troubleshoot

| 症状 | 可能原因 | 怎么办 |
|---|---|---|
| `vivado: command not found` | 没在 PATH | 提示用户提供 Vivado 路径 |
| `ERROR: [Common 17-69] Device ... not found` | WebPack 不支持 XC7A100T | 改脚本里 PART 为 `xc7a35tcpg236-1` 重跑 |
| `ERROR: [Synth 8-xxx] Syntax error` | SV 语法 Vivado 不吃 | 贴错误 + 行号给用户 |
| 综合跑 > 1 小时仍没结束 | 可能卡在某个大 module | Ctrl-C 中断，告诉用户 |
| Reports 目录是空的 | 综合失败 | 看 `fpga_synth/v2b_synth/v2b_synth.runs/synth_1/runme.log` 末尾 |

---

## 执行顺序总结

1. `vivado -version` 确认可用
2. `cd d:/SoC\ Design/SoC\ Design/fpga_synth`
3. `vivado -mode batch -source synth_v2b.tcl`
4. 等它跑完（10-30 min）
5. `cat reports/post_synth_status.rpt`
6. `grep -E "inferred|RAM" reports/synth_log.txt | head -30`
7. 把 Step 5 三样东西贴给用户

完毕。不明白的事情就问用户，不要自己发挥。
