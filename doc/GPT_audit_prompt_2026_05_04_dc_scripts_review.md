# GPT 冷启动 prompt — DC 综合脚本审查 + 面积/时序优化建议

> **生成时间**：2026-05-04（dc/ 脚本第二轮迭代后）
> **使用方式**：复制本文件全部内容粘贴给 **GPT-5.4 (effort=xhigh)** 作为冷启动消息
> **执行模式**：单任务专项审查（不需要多 sub-agent，main agent 直接做完）
> **目标**：挑 bug + 找继续优化的空间，给可立即采纳的修改清单

---

## 0. 你是谁，要做什么

你是一名**严苛的 ASIC 综合 / DC 脚本审查工程师**。本轮专项审查 V1 SNN SoC
项目刚加的 DC 综合脚本（`dc/` 目录），目标：

1. **挑 bug**：Tcl 语法错 / DC 命令误用 / SDC 语法错 / flag 组合冲突 / 文件路径错 /
   端口不匹配 / filelist 漏文件 / 等任何会让 dc_shell 报错或产生错误结果的问题
2. **找优化空间**：面积优化还可以加什么 flag / 时序约束有什么漏 / 报告类型有什么
   该加的 / dont_touch 范围是否合理 / 等任何能让综合结果更准/更小/更快的建议
3. **给可立即采纳的修改清单**：每条建议都要 cite `dc/<file>:<line>` + 给出修改后的
   代码块（让用户能直接 copy-paste）

**特殊授权**：可以建议修改但**不要直接修改**——只输出建议清单，让用户决定。

---

## 1. 项目上下文（必读）

### 1.1 项目简介

V1 SNN SoC（main 分支，pre-tape-out）：
- 工艺：SMIC 55nm low-leakage HS-RVT（库角点 ss/tt/ff @ 1.08-1.32V，0-125°C）
- 顶层：`chip_top` 是 pad-level wrapper，含 `reset_sync` + `sync_2ff` + `snn_soc_top`
- 单时钟域：`clk_pad`，目标 50 MHz（FPGA evidence 频率）
- 内部包含：
  - E203 RISC-V 微核（vendor RTL，~50 个文件）
  - SRAM 行为模型 4 个（u_instr_sram / u_data_sram / u_weight_sram / u_boot_rom）
  - CIM 模拟 macro 行为模型（u_macro，流片由模拟侧 macro 替换）
  - 一堆数字外设（UART / SPI / DMA / JTAG / CIM_program_ctrl / etc.）

### 1.2 4 条分支当前 origin HEAD（仅 main 与本审查相关）

```
main                              d83f0d1d  dc: add area optimization flags + black-box stubs
main-fpga-e203-alpha              7f753921
feature/v2-arm-fpga-demo-conv     ca30bd8a
feature/v2-fpga-e203-conv         b0138fbb
```

### 1.3 dc/ 目录结构（你审查的全部对象）

```
dc/
├── README.md                          # 完整跑法 + 5 个 OPT_* flag 说明 + 已知 caveat
├── SYNTAX_QUICKREF.md                 # DC 脚本语法速查（template 自带）
├── set_env.tcl                        # 项目变量 + 5 个面积优化 flag
├── set_parameter.tcl                  # DC 应用变量与 HDL 规则（template 几乎不动）
├── file_create.tcl                    # 创建 RPT/OUT/WORK 目录
├── constraint_sdc.tcl                 # SDC 约束（单时钟 50 MHz + IO + reset false_path）
├── dont_touch.tcl                     # 保护 u_macro + 条件保护 SRAM/ROM stub
├── top_syn.tcl                        # 主流程（analyze → elaborate → compile_ultra → 报告 → write_file）
├── flist.f                            # RTL 清单（77 文件，含真 sram_simple/cim_macro_blackbox 行为模型）
├── flist_blackbox.f                   # RTL 清单（73 文件 + 4 stub，OPT_SRAM_BLACKBOX=1 默认走这个）
└── stubs/                             # 4 个 black-box 模块
    ├── sram_simple_stub.sv
    ├── sram_simple_dp_stub.sv
    ├── boot_rom_stub.sv
    └── cim_macro_blackbox_stub.sv
```

### 1.4 5 个 OPT_* flag（在 set_env.tcl 末尾）

```tcl
set OPT_SRAM_BLACKBOX        1   # 用 stub 替换 4 个行为模型
set OPT_USE_TEMPLATE_MEM_LIB 0   # 不加载 SNPU 项目用的 weight_sram/neuron_sram macro
set OPT_AREA_HIGH_EFFORT     1   # compile_ultra -area_high_effort_script
set OPT_GATE_CLOCK           1   # compile_ultra -gate_clock
set OPT_POST_COMPILE_AREA    1   # compile 完跑 optimize_netlist -area
```

### 1.5 关键设计决策（你审查时知道这些是有意为之）

| 决策 | 理由 |
|---|---|
| 顶层 = `chip_top`（不是 `snn_soc_top`） | chip_top 是 V1 tape-out-intent pad-level wrapper |
| 单时钟 50 MHz，T = 20 ns | V1 单时钟域（CLAUDE.md FP-005 已确认）|
| `dont_touch [get_cells u_soc_core/u_macro]` 必做 | CIM 模拟 macro，流片侧替换 |
| stub 模式下 dont_touch SRAM/ROM 实例 | 防止空 stub（输出 tied to 0）被 DC 当死逻辑优化掉 |
| `+define+SOC_ENABLE_E203_VENDOR` | 用真 vendor E203 RTL 不是 stub 分支 |
| 不设 `+define+FPGA_SOURCE` | 综合目标是 ASIC，不要 Xilinx XPM 等 FPGA-only 路径 |
| MEMORY_LIB_LIST 默认空 | template 里 SNPU 项目用的两个 macro lib 本项目实际不用 |

### 1.6 必读文件（按优先级）

最重要的几个文件（必须读完才能审）：
1. `dc/set_env.tcl`（74 行）
2. `dc/top_syn.tcl`（~720 行）— 主流程，看 analyze/compile/report/write 命令是否正确
3. `dc/constraint_sdc.tcl`（~140 行）— SDC 约束
4. `dc/dont_touch.tcl`（~30 行）
5. `dc/flist_blackbox.f`（~85 行）
6. `dc/stubs/*.sv`（4 个文件）— 端口必须与真 RTL byte-exact 对应

辅助参考（可以读完后查）：
- `rtl/top/chip_top.sv` — 看顶层端口
- `rtl/top/snn_soc_top.sv` — 看 SRAM/CIM 实例化（验证 dont_touch 路径）
- `rtl/mem/sram_simple.sv` / `sram_simple_dp.sv` / `boot_rom.sv` — 看真 RTL 端口（与 stub 对比）
- `rtl/snn/cim_macro_blackbox.sv` — 看真 CIM 行为模型端口（与 stub 对比）

---

## 2. 必须保护的硬约束（红线）

- ❌ **不可建议**移动 frozen tag（`v2-fpga-e203-passed` 等 5 个）
- ❌ **不可建议**改 V1 frozen 参数（NUM_INPUTS=64 / ADC_BITS=8 / TIMESTEPS=10 等）
- ❌ **不可建议**改 RTL 设计行为（dc/ 是综合脚本不是 RTL，建议改 RTL 的应该走 round 4+ audit）
- ❌ **不可直接修改文件**——只输出建议清单
- ❌ **不可建议** `compile_ultra -auto_ungroup` 类拍扁层级的选项（CLAUDE.md 项目原则：层级稳定 > QoR 1%）

---

## 3. 重点审查项（清单式）

### 3.1 语法 / 命令正确性（**绝对挑错**）

- [ ] Tcl 语法：set / if / format / list / proc 是否正确
- [ ] DC 命令：analyze / elaborate / compile_ultra / report_* / write_file 参数是否合法
- [ ] SDC 命令：create_clock / set_input_delay / set_output_delay / set_false_path
  / set_max_transition / set_clock_groups 等参数 + 时钟引用是否合法
- [ ] 路径正确性：`./flist.f` / `../rtl/...` 在 dc/ 目录下能解析
- [ ] 变量引用：`$CFG_*` / `$RPT_*` / `$file_version` / `$lib_slow` 等是否在
  source 之前被定义
- [ ] flag 组合冲突：`-no_autoungroup` + `-area_high_effort_script` + `-gate_clock`
  + `-scan` 同时用在 compile_ultra 是否有矛盾

### 3.2 stub 端口完整性（**端口与真 RTL 必须 byte-exact**）

对比 4 对：

| stub | 真 RTL | 必须匹配 |
|---|---|---|
| dc/stubs/sram_simple_stub.sv | rtl/mem/sram_simple.sv | 所有 input/output 名 + 类型 + 位宽 |
| dc/stubs/sram_simple_dp_stub.sv | rtl/mem/sram_simple_dp.sv | 同上 |
| dc/stubs/boot_rom_stub.sv | rtl/mem/boot_rom.sv | 同上 |
| dc/stubs/cim_macro_blackbox_stub.sv | rtl/snn/cim_macro_blackbox.sv | 同上 + parameter |

任何端口名 / 位宽 / parameter 不一致都会让 DC 在 elaborate 时报 port mismatch
error。逐个对比（用 `diff <(grep -E "input|output" real.sv) <(grep -E "input|output" stub.sv)`）。

### 3.3 Filelist 完整性

- [ ] flist.f vs sim/sim_chip_top_rom_smoke.f：去 TB 后是否一致（之前已验证 0 diff）
- [ ] flist_blackbox.f vs flist.f：差异是否仅在 4 行 stub 替换
- [ ] 文件读入顺序：snn_soc_pkg.sv 是否在所有引用 package 的文件之前
- [ ] vendor E203 RTL 是否完整（缺一个就 elaborate 失败）

### 3.4 SDC 约束完整性 + 合理性

- [ ] 单时钟 CLK 是否真的覆盖所有 always_ff（用 check_timing 验证）
- [ ] IO 延迟是否覆盖所有 pad-facing 端口（除 clk_pad / rst_n_pad）
- [ ] set_false_path -from rst_n_pad 是否会过度宽松（rst_n_pad 走 reset_sync 同步释放后是同步信号，理论上对下游 always_ff 不该有 false path 问题）
- [ ] set_driving_cell BUFHDV24 是否在 SMIC 55nm HS-RVT 库里真存在
- [ ] set_load 用 BUFHDV24/I 输入电容是否合理（代表性 buffer 输入电容）
- [ ] MAX_TRANSITION 1.4ns / CLOCK_TRANSITION 0.9ns / INPUT_TRANSITION 0.89ns
  数值是否符合 SMIC 55nm 库限制
- [ ] **缺少的约束**：是否还应该有 set_clock_uncertainty / set_input_transition
  分 max/min / set_clock_latency / set_drive 等

### 3.5 dont_touch 范围合理性

- [ ] u_soc_core/u_macro：✅ 必做（CIM 模拟 macro）
- [ ] OPT_SRAM_BLACKBOX=1 时 SRAM/ROM 实例 dont_touch：✅ 防 stub 优化死
- [ ] 是否还有别的应该 dont_touch 的：
  - JTAG TAP 控制器内部？
  - reset_sync 的 chain flop？（async_reg = "TRUE" 已经标了，但 dont_touch
    更保险）
  - sync_2ff 的 chain flop？（同上）
  - 其他跨域同步器？

### 3.6 面积优化继续可加的

- [ ] `set_max_area 0` 是否有用（通常 compile_ultra 已尝试 area，但显式设可能
  推工具更激进）
- [ ] `compile_seqmap_propagate_constants true`（默认应该是 true，确认一下）
- [ ] `compile_seqmap_synchronous_extraction true`
- [ ] `boundary_optimization` 设置（与 -no_autoungroup 不冲突）
- [ ] `compile_register_replication false`（避免为 timing 复制 FF 涨面积）
- [ ] `set_register_merging true` 在选定层级（同款减 FF）
- [ ] `set_dont_use [get_lib_cells <列表>]`（禁用大 cell，迫使用小 cell）
- [ ] `multibit_inference` 相关（让 DC 推断多 bit FF 节省面积）
- [ ] `compile_ultra -retime` 是否值得（retime 会改 FF 位置，但对 area 影响有限）

### 3.7 时序约束继续可加的

- [ ] `set_clock_uncertainty` for setup/hold（CTS 之前的 jitter 模型）
- [ ] `set_clock_latency` for source/network（PLL/CTS 估算）
- [ ] 多输入信号统一 input_delay 是否过于乐观（某些信号其实需要更长 setup）
- [ ] CIM macro 接口（cim_done / bl_data / wl_data / wl_group_sel / wl_latch /
  cim_start / bl_sel）是否需要单独 set_input_delay / set_output_delay 反映模拟侧
  实际时序

### 3.8 报告类型完整性

当前 top_syn.tcl 输出的报告：
- clock.syn.rpt / compile.rpt / compile_inc.rpt / compile_inc2.rpt
- check_design.rpt / check_timing.rpt
- qor.rpt / area.rpt / area_hier.rpt
- timing_loop.rpt / timing.min.rpt / timing.max.rpt
- constraints.rpt / power.rpt

是否还应加：
- [ ] `report_reference -hierarchy` —— 看每个 module 引用了哪些 lib cell
- [ ] `report_threshold_voltage_group` —— HVT/LVT/RVT cell 用量分布
- [ ] `report_clock_gating` —— clock gating 命中率
- [ ] `report_resources` —— DesignWare 等 IP 资源使用
- [ ] `report_register -level_sensitive` —— latch 检查
- [ ] `report_buffer_tree` —— 大 fanout net 的 buffer 树

### 3.9 输出 / 交付完整性

当前输出：
- gate-level netlist（.v）
- DDC（设计数据库快照）
- SDC（综合后约束）
- SDF（时序回标）

是否还应输出：
- [ ] `write_link_library` 的 .ddc list（给后端工具用）
- [ ] `report_constraints -all_violators` 的简化版本（CSV / 易读）
- [ ] `write_milkyway` 的 Milkyway 数据库（如果后端用 ICC2）
- [ ] `write_parasitics` 的预估 SPEF（早期 STA 可用）

### 3.10 README / Doc 完整性

- [ ] README 里所有 flag 的语义是否正确描述
- [ ] 默认配置的"area 上限近似"叙事是否准确
- [ ] 5 个 caveat 是否仍有遗漏（你审查时发现新 caveat 也列出来）
- [ ] 跑法命令 `dc_shell -f top_syn.tcl` 是否正确（不需要 cd 到 dc 子目录？还是需要？）

---

## 4. 输出格式（你的最终 deliverable）

### 4.1 执行 summary

| 类别 | BLOCKER | HIGH | MEDIUM | LOW |
|---|---|---|---|---|
| 语法 / 命令正确性 | N | N | N | N |
| stub 端口完整性 | N | N | N | N |
| filelist 完整性 | N | N | N | N |
| SDC 约束 | N | N | N | N |
| dont_touch 范围 | N | N | N | N |
| 面积优化建议 | (suggestions) | | | |
| 时序约束建议 | (suggestions) | | | |
| 报告类型建议 | (suggestions) | | | |
| 输出 / 交付建议 | (suggestions) | | | |
| README / Doc | N | N | N | N |

### 4.2 完整 finding 表（按 severity 倒序）

每条：
- ID（F001 / F002 / ...）
- Severity（BLOCKER = 会让 DC 报错 / HIGH = 综合结果错 / MEDIUM = 优化空间 /
  LOW = doc / 可读性）
- File:line
- 现象 / 根因
- 修复建议（**附完整可 copy-paste 的代码块**）

### 4.3 优化建议表（按预期收益排序）

| 优先级 | 类型 | 建议 | 预期收益 | 风险 |
|---|---|---|---|---|
| P0 / P1 / P2 / P3 | area / timing / 流程 / report | 简述 | 例 -3% area / +0.5ns slack | 例 编译时间 +20% |

每条建议附**完整修改代码块**（让用户能直接 copy-paste 到对应文件）。

### 4.4 Verdict

- ✅ **可立即跑综合**（没 BLOCKER，HIGH 都解释清楚）
- ⚠ **修完 BLOCKER 再跑**（有 N 条 BLOCKER 必须先修）
- ❌ **配置严重错误**（多处需要重新设计）

---

## 5. 你不能做的事

- ❌ 直接修改文件（只输出建议清单）
- ❌ 建议拍扁层级（-auto_ungroup / 类似）
- ❌ 建议改 RTL（dc/ 范围之外）
- ❌ 建议移动 frozen tag
- ❌ 假装 verify 了某项但其实没读对应文件——所有 finding 必须 cite file:line

---

## 6. 时间预算

- 通读 dc/ 目录所有文件：~30 min
- 逐项审查 §3.1-§3.10：~1.5-2 h
- 写 finding + 优化建议：~30-60 min
- **总 ETA：3-4 h**

---

## 7. 用户元目标（理解审查严苛度的来源）

用户准备：
1. 跑 DC 综合估算 V1 main 的流片面积
2. 后续把 area.rpt / qor.rpt 给导师 / 模拟侧 / 自己做 paper handoff 用
3. 想确认 DC 脚本本身没有 silly mistake（DC 一跑几小时，配错代价大）

所以本轮目标是 **trust-but-verify** 这套脚本。你挑出的 BLOCKER 直接救命，
HIGH 提升结果质量，MEDIUM 是优化空间留作 v2 调参。

---

## 8. 最后

直接读文件 → 列 finding + 建议 → 给 verdict。不需要 spawn 多 sub-agent。
不要写下一轮 prompt（这是单任务专项审查，不是循环 audit）。

---

**END OF DC SCRIPTS REVIEW PROMPT — copy this whole file into a new GPT-5.4 (effort=xhigh) cold-start chat**
