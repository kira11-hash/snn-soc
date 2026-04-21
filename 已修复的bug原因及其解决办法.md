# 已修复的 Bug 原因及其解决办法

> 本文档记录项目中已修复的 bug，按时间倒序累积。
> **每次修复完一个 bug 必须追加一条**（CLAUDE.md 强制规则）。
> 目的：把 debug 经验沉淀成可检索的知识库，避免下次踩同一个坑。

---

## [2026-04-21] V2.B Vivado 综合卡死链（5 处 FPGA-unfriendly 模式）

### 现象
Phase D 首次 Vivado 综合（xczu9eg-ffvb1156-2-e，Vivado 2022.2）**挂了 6 小时**停在 "Cross Boundary and Area Optimization"，进程 CPU 占用 0.3%（卡死不是在算）。Kill 后改第一处再跑，又挂 ~6 分钟停在 RTL elaboration，log 报警 `Synth 8-11357 Potential Runtime issue for 3D-RAM or RAM from Record/Structs for RAM mem_reg with 458752 registers`。

### 根因（5 处同类模式，扫完一次性修）

**问题模式 A：256-input 组合条件加法树**
- `rtl/snn/cim_mac_behavioral_v2.sv`（旧版）MAC 内部 `always @*` 里 `for (si=0..255) if (wl[si]) pos_sum += w_pos_mem[si][j]`
- Vivado 综合为 **深 8 级 12-bit 加法器树 + 256-input conditional select**，"Cross Boundary Optimization" 反复优化不收敛
- 影响：LUT 预估 4-8K × 2（pos+neg），组合延迟 ~12 ns，100 MHz 直接 timing FAIL

**问题模式 B：2D unpacked array 被识别为"3D RAM"**
- `tile_partial_buf.mem [0:D-1][0:W-1]`（D=256, W=128, 14-bit）
- `cim_mac_behavioral_v2.w_pos_mem / w_neg_mem [0:255][0:127]`（4-bit）
- Vivado 报 `Synth 8-11357 3D-RAM with N registers`，尝试推 BRAM 失败 → fallback 成 N 万个 flat FF，综合卡在 optimization

**问题模式 C：大 memory 的 1-cycle broadcast clear**
- `input_stream_sram / stream_buffer_v2 / tile_partial_buf` 的 reset 和 `clear_all` 路径都写：`for (i=0..N-1) mem[i] <= 0`
- Vivado 综合为 **单 cycle 巨大 reset fan-out**（65536 bit / 32768 bit / 458K bit 各一个），触发资源爆炸

### 修复（5 个 commit 连续落地）

| Commit | 修的问题 | 改法 |
|---|---|---|
| `41790ff1` | 模式 A | MAC 改 WL-serial FSM（`MS_ACCUM` N_IN cycle + `MS_ADC` N_OUT cycle），组合路径最深 1 adder |
| `00717074` | 模式 B（tpb）+ 模式 C（tpb） | `tile_partial_buf.mem` 2D→1D flat，`(* ram_style="distributed" *)`，`ifdef SYNTHESIS` 用 counter-walker clear（1 cell/cycle） |
| `5e0cb552` | 模式 B（MAC weights）+ 模式 C（isr / sb） | `w_pos_mem/w_neg_mem` 2D→1D packed 512-bit row（per-si 所有 neuron 权重并行读），`(* ram_style="block" *)`，isr / sb 加 `ifdef SYNTHESIS` counter-walker clear |

### 影响范围
- 所有 V2.B RTL 文件都改过 → 9 个 V2.B TB 逐个回归确认 **bit-exact 行为不变**
- V1 path 完全没碰（`ifdef SYNTHESIS` 只对 Vivado 生效，Icarus/VCS 仿真走原路径）
- V1 LIGHT_SMOKETEST_PASS 回归绿

### 如何避免再犯

**写 RTL 时的 FPGA-synth 反模式清单（任何一条命中即红灯）**：
1. 2D / 3D unpacked array `logic [W-1:0] mem [0:D1-1][0:D2-1]` → Vivado 不能稳定推 RAM。必须改 1D + 内部 bit-slice。
2. reset / clear 路径用 for 循环一次清所有 cell（超过 ~256 个 FF / 1024 bit）→ 必须 `ifdef SYNTHESIS` 分岔用 counter walker
3. `always @*` 里 for-loop 展开超 ~64 input 的 combinational reduction（popcount / conditional sum）→ 必须 FSM 串行化
4. `ifdef SYNTHESIS` / `ifndef SYNTHESIS` 分离 "综合友好的多周期逻辑" 和 "仿真友好的单周期行为"，TB 语义不变
5. 写大 mem 必须加 `(* ram_style = "block" | "distributed" *)` 明确告诉 Vivado

**开发流程修正**：
- 每次新增/改动 RTL 模块（特别是带 memory 或 combinational reduction 的），提交前先跑 `verilator --lint-only --stats` 拿估算 + grep RTL 检查以上 5 条反模式
- 不要等 Vivado 报错才改；Vivado 综合挂 6 小时代价太大
- 把这份反模式清单在 `doc/19_phase_d_synthesis_readiness.md` 里也加一份（作为综合 checklist 前置条件）

### 剩余已知风险（本次未修，Vivado 大概率自己处理）
- `stage_engine_v2.membrane[128]` 32-bit FF 清零（4K FF reset fan-out，~1% 预算）
- `cim_mac_behavioral_v2.adc_scale()` 里 `num[63:0] / sum_max` 整数除法（Vivado 2022.2 通常推 DSP48 迭代，失败则 LUT 爆；如卡需改多周期 FSM）
- `unique case` implementing as parallel_case —— info message 非 blocker

---

## [2026-04-18] D3-002 ~ D3-006（Codex 第 3 轮审查吸收）

### D3-002 MEDIUM：P_USE_BRAM_WEIGHTS 与 ENABLE_PROGRAM_MODE 硬绑定
- **现象**：如果 TB 实例化 snn_soc_top 时 ENABLE_PROGRAM_MODE=0（不带编程控制器），reload_layer_weights 写入的 weight_mem 不会被推理使用（走 popcount 行为模型）
- **影响**：未来 multilayer_sample_align_tb 如果按默认参数实例化，reload 不生效
- **修复**：
  - `snn_soc_pkg.sv` 新增独立 parameter `ENABLE_BRAM_WEIGHT_MODEL`（`+define+SIM_BRAM_WEIGHT_MODEL` 触发）
  - `snn_soc_top.sv` 改为 `.P_USE_BRAM_WEIGHTS(ENABLE_PROGRAM_MODE | ENABLE_BRAM_WEIGHT_MODEL)`
  - V1 默认：两者都 0（popcount 兼容）；V2 编程：ENABLE_PROGRAM_MODE=1 自动开 BRAM；V2 多层对齐：单独开 ENABLE_BRAM_WEIGHT_MODEL
- **如何避免**：测试用的参数配置应该和生产配置解耦，不要让"功能开关"隐式决定"仿真模型开关"

### D3-003 MEDIUM：MULTILAYER_SCAN_EXT TB 覆盖度不足
- **现象**：原 TB 只检查 bl_sel 最大值到达 63/127，但不能证明 eff_half_count 差分索引正确、neuron_in_data_wide 高索引是否被更新
- **修复**：新增 3 条 pattern 检查
  - T1: `raw_data[5]=100`（test_mode pos）、`raw_data[31]=0`（test_mode neg）
  - T2: `raw_data[63]=0` 且 `raw_data[127]=0`（证明 128 宽数组高索引真被写）
  - T2: `$signed(neuron_in_data_wide[5]) == 100`（证明差分路径在 bl_cnt=128 下仍对）
- **位置**：`tb/multilayer_scan_ext_tb.sv`

### D3-004 LOW：reload_layer_weights task 缺 runtime guard
- **现象**：注释要求 rst_n=1 + 非推理/编程期间调用，但 task 里没运行时检查
- **修复**：task 首行加 3 个 `$fatal` 保护（rst_n=0 / cim_busy/adc_busy / prog_en/erase_en）
- **位置**：`rtl/snn/cim_macro_blackbox.sv` reload_layer_weights 开头

### D3-005 LOW：doc/03 没同步 D2-006 row guard
- **修复**：`doc/03_cim_if_protocol.md` 第 99 行保护说明改为 "prog_col ≥ PROG_COLS **或** prog_row ≥ PROG_ROWS" + 注明全阵列擦除不 care

### D3-006 LOW：chip_top 注释 Pad 19-45 过时
- **修复**：注释改为 Pad 19-50 + 分段说明 V1 baseline / V2 新增 / ESD reserved，引用 doc/15 权威源
- **位置**：`rtl/top/chip_top.sv` 第 53 行附近

---

## [2026-04-18] D3-FIX（CRITICAL）：D2-006 的 `6'(PROG_ROWS)` 位宽截断，guard 反向触发

- **现象**：
  - 严苛审查（第 2 轮 Ultra Review）时用 test_cast.sv 手动验证，发现 `6'(PROG_ROWS) = 6'(64) = 6'b000000 = 0`
  - `prog_row >= 0` 对任何 prog_row 都为 true，所以 guard 变成"**一直触发 FAIL**"
  - 重新跑 cim_program_ctrl_tb（用 `-o /tmp/fix.vvp` 确保不用 stale vvp）：T1-T5 全部 FAIL，T4 global timeout
  - 但之前记录 "CIM_PROGRAM_CTRL_PASS 7/7" 是因为 `iverilog ... -s name -o name.vvp` 命令行的 `-s` 参数位置不对，iverilog 未编译，`vvp cim_prog_tb.vvp` 跑的是**之前编译的 stale vvp**（D2-006 修改前的版本）

- **根因**：
  - [rtl/snn/cim_program_ctrl.sv:197](rtl/snn/cim_program_ctrl.sv#L197) 的 D2-006 修复写了 `prog_row >= 6'(PROG_ROWS)`
  - SystemVerilog LRM §6.24.1：size-cast 当值超出目标位宽时截断高位
  - PROG_ROWS = 64 = 7'b1000000，用 6'() 转换得到低 6 位 = 6'b000000 = 0
  - `5'(PROG_COLS) = 5'(20) = 5'b10100 = 20`（没截断）—— 所以 prog_col 那边历史从未暴露此坑

- **修复**：
  - 把 guard 改为 `int'(prog_row) >= PROG_ROWS`（32-bit 比较，不会截断）
  - prog_col 也统一用 `int'(prog_col) >= PROG_COLS` 保持风格一致
  - 在代码注释里加粗强调这个坑，防止以后有人再写 `N'(large_param)`

- **影响范围**：
  - 修复前：**任何逐 cell 编程 / 逐 cell 擦除都会被判 FAIL**（全阵列擦除不受影响）
  - 修复后：cim_program_ctrl_tb T1-T7 全部真 PASS（之前的 7/7 PASS 是 stale vvp 假象）
  - LIGHT/WEIGHTED/MULTILAYER/SAMPLE_ALIGN/E203/JTAG/ADC_SAT 不经过编程路径，没有直接影响
  - 真实硬件如果按修复前发布，V2 编程功能完全不可用

- **如何避免再犯**：
  - **规则 1**：`N'(parameter)` 这种位宽截断 cast 只适用于"parameter 值确保能用 N bit 表示"的场景。如果 param 值 ≥ 2^N，**必须用 int 或更宽的 cast**
  - **规则 2**：验证修改时必须用 `-o /path/output.vvp` 明确指定输出，不要依赖默认 `a.out` 或残留的 vvp 文件
  - **规则 3**：修改 RTL 后如果 TB 报 PASS，反问一下"失败用例会不会因为 stale binary 也显示 PASS"——加一个故意触发失败的用例验证 TB 有效性
  - **加入 FP 知识库**：这不是 FP（不是误报），应该加入"经验陷阱库"——本项目 CLAUDE.md 的"禁止行为"章节将追加 N'(large_param) 位宽截断警告

---

## [2026-04-18] D2-006 ~ D2-008：Ultra Review 发现的次级问题

一次性记录 code-reviewer agent 独立审查发现的 3 个次级问题（主修复 D2-001/002/003/005 之后的补丁）：

### D2-006 HIGH：prog_row 与 prog_col 越界保护不对称
- **现象**：cim_program_ctrl 对 prog_col 有 guard，但 prog_row 没有。虽然 prog_row 是 6-bit 最大 63、PROG_ROWS=64 隐性安全，但未来 PROG_ROWS 改小会暴露风险
- **修复**：把 guard 扩展为 `(prog_col >= PROG_COLS) || (prog_row >= PROG_ROWS)`，两者对称处理
- **位置**：[rtl/snn/cim_program_ctrl.sv:172-180](rtl/snn/cim_program_ctrl.sv#L172)

### D2-007 MEDIUM：reload_layer_weights task 与 always_ff 竞争
- **现象**：task 用阻塞赋值改写 prog_pulse_acc，同一信号又被 always_ff 非阻塞驱动，在 posedge clk 同拍调用时有 multi-driver 竞争
- **修复**：task 内加 `@(negedge clk);` 避开时钟边沿
- **位置**：[rtl/snn/cim_macro_blackbox.sv](rtl/snn/cim_macro_blackbox.sv) 的 `reload_layer_weights` task

### D2-008 LOW：force 无 release + TB bl_sel_max 清零竞争
- 修 1：[tb/e203_tb.sv](tb/e203_tb.sv) 在 `$finish` 前加 `release dut.u_jtag_loader.cpu_reset_hold`，防止污染后续 regression
- 修 2：[tb/multilayer_scan_ext_tb.sv](tb/multilayer_scan_ext_tb.sv) 把 `bl_sel_max_observed = '0` 改为 `@(negedge clk); bl_sel_max_observed = '0` 避开时钟边沿

### 共同教训
**教训**：独立 reviewer 比作者自己更容易发现"表面正确但边界脆弱"的问题。以后大修复后务必过一遍 code-reviewer agent。

---

## [2026-04-18] D2-001：逐 cell erase 路径缺少 PROG_COL 越界保护

- **现象**：
  - Codex 360° 审查 v2 报告 HIGH 级 finding D2-001
  - 未触发，属于隐藏 bug，但仿真激励可以复现：写 `REG_PROG_COL=20` + `REG_PROG_CTRL={START=1, ERASE=1, FULL_ARRAY=0}`（逐 cell erase 非法列）
  - 预期：`PROG_STATUS.FAIL=1, DONE=1`
  - 实际（修复前）：进入 ST_SETUP/ST_PULSE，驱动 `erase_en=1` + `prog_bl_sel=20`，黑盒内数组越界（SV 静默回绕到合法索引）；真实硬件会给模拟侧送非法 bl_sel，**可能误擦其他 cell 甚至损坏 RRAM**

- **根因**：
  - [rtl/snn/cim_program_ctrl.sv:173](rtl/snn/cim_program_ctrl.sv#L173) 的 D1-004 guard 写为 `if (!prog_erase && (prog_col >= 5'(PROG_COLS)))`
  - `!prog_erase` 只覆盖写入路径，逐 cell erase（`prog_erase=1, prog_full_array=0`）不受保护
  - 全阵列擦除（`prog_full_array=1`）其实已经在之前把 `prog_bl_sel` 固定为 `'0`，不 care `prog_col`

- **修复**：
  - 把 guard 改为 `if (!prog_full_array && (prog_col >= 5'(PROG_COLS))) state <= ST_FAIL;`
  - 统一覆盖"写入 + 逐 cell erase"两条路径，全阵列擦除仍然跳过 prog_col 检查
  - 保留 `level=0 && !erase` 快速路径
  - 位置：[rtl/snn/cim_program_ctrl.sv:172-180](rtl/snn/cim_program_ctrl.sv#L172-L180)

- **影响范围**：
  - cim_program_ctrl 正常路径不受影响（prog_col 合法时行为不变）
  - 非法 prog_col 现在直接 FAIL，不会驱动 macro
  - 无 RTL 回归（原路径就不会走非法 col）

- **如何避免再犯**：
  - 编程 FSM 的路径 guard 要按"操作模式的真实语义"而不是"单一 flag 的对立"来写——全阵列擦除不 care col 是确定的，逐 cell 操作（无论写/擦）都 care col
  - 建议未来给 `cim_program_ctrl_tb.sv` 加一个负测试点：写非法 prog_col + erase，验证直接 FAIL
  - 本类 guard 遗漏在 Codex 审查前没被发现，说明 TB 覆盖不足——加入 A0 后的"负测试补全"TODO

---

## [2026-04-18] E203_SMOKETEST 回归：CPU 永远处于 reset 状态（PC=0x00000000）

- **现象**：
  - `bash sim/run_e203_icarus.sh` 输出 11 个错误全部集中在 "PC=0x00000000"
  - Bootloader 未启动 SPI 装载、UART 无活动、固件未完成 — 即 CPU 从未执行任何指令
  - 仿真正常跑完 15.3ms 才 $fatal，编译无警告
  - 其他 TB（LIGHT/WEIGHTED/MULTILAYER/SAMPLE_ALIGN/ADC_SAT/JTAG_RESCUE）都通过

- **根因**：
  - [rtl/periph/jtag_mem_loader.sv](rtl/periph/jtag_mem_loader.sv) 的 `cpu_reset_hold` reset 值被改为 `1'b1`（上电后 CPU 默认保持复位，需要 JTAG CPUCTL 显式释放）
  - 这是 V2 安全引导语义：上电 → CPU hold in reset → SPI/JTAG 装程序 → 释放 CPU
  - `cpu_local_rst_n = rst_n & ~cpu_reset_hold_effective` — 当 `cpu_reset_hold=1` 时 `cpu_local_rst_n` 恒为 0，CPU 永远被复位
  - [tb/e203_tb.sv](tb/e203_tb.sv) 用 `$readmemh` 直接预加载 bootloader，没走 JTAG CPUCTL 流程，所以 CPU 无法被释放

- **修复**：
  - 在 [tb/e203_tb.sv:80](tb/e203_tb.sv#L80) 复位释放后通过层级 `force` 覆写：
    ```systemverilog
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    force dut.u_jtag_loader.cpu_reset_hold = 1'b0;
    ```
  - 只改 TB，不改 RTL——保留 V2 安全引导语义

- **影响范围**：
  - 修复后 `E203_SMOKETEST_PASS`（60144 cycles，100 spikes 全部符合预期）
  - `jtag_rescue_top_tb` 通过 JTAG CPUCTL 正确释放 CPU，不受影响
  - 其他 `top_tb_*.sv` / `multilayer_tb` / `sample_align_tb` 都默认 `ENABLE_E203=0`，不实例化 E203，不受影响
  - 唯一受影响的是 `e203_tb.sv` 这种"CPU + 非 JTAG 路径"的组合

- **如何避免再犯**：
  - 下次 `jtag_mem_loader.sv` 修改 `cpu_reset_hold` reset 值时，必须同步检查所有启用 E203 的 TB 是否走了 JTAG CPUCTL 释放流程
  - 可考虑加 `parameter bit CPU_RESET_HOLD_DEFAULT = 1'b1`，让测试环境按需覆盖
  - 或在 `e203_tb.sv` 开头加 assertion：仿真开始 100 cycle 后 PC 应 != 0，否则 $error（快速定位）

---

## 模板

复制此模板往上追加：

```markdown
## [YYYY-MM-DD] <简短标题>

- **现象**：外部观察到的错误表现
- **根因**：具体文件:行号 + 为什么会发生
- **修复**：改了什么（diff 摘要）+ 修复位置
- **影响范围**：哪些 TB/模块被影响、回归结果
- **如何避免再犯**：是否需要加断言 / 注释 / 更新误报 KB
```
