# DC Synthesis — V1 SNN SoC tape-out 面积估算

> 本目录用 Synopsys Design Compiler 综合 V1 main 分支的 chip_top（含 reset_sync
> + snn_soc_top + E203 vendor RTL），输出面积 / 时序 / 功耗报告 + 门级网表。
>
> 工艺库：SMIC 55nm low-leakage HS-RVT（与项目 template 同库）

---

## 文件清单

| 文件 | 作用 |
|---|---|
| `top_syn.tcl` | 综合主流程（analyze → elaborate → constraints → compile_ultra → 报告 → write_file） |
| `set_env.tcl` | 项目变量（顶层模块 / 版本号 / 报告目录 / 库角点 / **5 个面积优化 flag**）|
| `set_parameter.tcl` | DC 应用变量与 HDL / Verilog 输出规则（一般不需改） |
| `file_create.tcl` | 创建 RPT / OUT / WORK 子目录 |
| `constraint_sdc.tcl` | SDC 约束（单时钟 50 MHz + 通用 IO 延迟 + reset false_path） |
| `dont_touch.tcl` | 保护 `u_soc_core/u_macro` + 条件保护 SRAM/ROM stub（OPT_SRAM_BLACKBOX=1 时）|
| `flist.f` | RTL 文件清单（77 个文件，含 vendor E203，包含 4 个 over-estimate 行为模型）|
| `flist_blackbox.f` | RTL 文件清单（77 个，**4 个行为模型替换为 stub**，OPT_SRAM_BLACKBOX=1 默认走这个） |
| `stubs/sram_simple_stub.sv` | sram_simple 的空 stub（端口对齐，输出 tied to 0）|
| `stubs/sram_simple_dp_stub.sv` | sram_simple_dp 的空 stub |
| `stubs/boot_rom_stub.sv` | boot_rom 的空 stub |
| `stubs/cim_macro_blackbox_stub.sv` | cim_macro_blackbox 的空 stub |
| `SYNTAX_QUICKREF.md` | DC 脚本语法速查 |

---

## 关键设计决策

### 1. 顶层模块 = `chip_top`（不是 `snn_soc_top`）
`chip_top` 是 V1 tape-out-intent pad-level wrapper，包含：
- `u_reset_sync`（async-assert / sync-release reset 同步器）
- `u_cim_done_sync`（cim_done_pad 2-FF metastability 同步器）
- `u_soc_core`（snn_soc_top 实例，全开 ENABLE_E203 + ENABLE_EXT_CIM_IF +
  ENABLE_PROGRAM_MODE + ENABLE_BOOT_ROM）

### 2. 单时钟 50 MHz（CLK = `clk_pad`，T = 20 ns）
V1 数字 SoC 单时钟域（CLAUDE.md FP-005 已确认 fifo_sync 是同步 FIFO）。
跨时钟仅 jtag_tck，已由 jtag_mem_loader 内部 `(* async_reg = "TRUE" *)` 处理。
**首次面积估算用 50 MHz baseline；后续可改 `set CLK_PERIOD 10` 看 100 MHz 面积代价。**

### 3. dont_touch 仅保护 CIM 模拟 macro
- ✅ `u_soc_core/u_macro`（cim_macro_blackbox）— 行为模型，流片由模拟 CIM macro 替换
- ❌ `u_soc_core/u_boot_rom` — 让 DC 综合得到 over-estimate；流片由 foundry mask ROM 替换
- ❌ `u_soc_core/u_instr_sram` / `u_data_sram` / `u_weight_sram` — 让 DC 综合
  sram_simple/sram_simple_dp 行为模型；流片由 SRAM macro 替换

**面积估算 caveat**：综合 sram_simple 行为模型会得到大量 FF（远大于真实 SRAM macro
面积）。最终汇报面积时**必须**减去 SRAM 部分（`report_area -hierarchy` 看每个
sram_simple 实例占多大），按 SRAM 容量乘以 macro density 重新计算。

### 4. CIM 模拟 macro 面积单独估
`cim_macro_blackbox` 是数字行为模型；真实模拟 CIM macro die area 由模拟侧提供
（详见 `doc/08_cim_analog_interface.md` + `doc/15_asic_pad_map.md`）。
最终汇报数字 die 总面积时单独标注："模拟 CIM macro = X mm²，由模拟侧提供，
不计入数字侧综合面积"。

---

## 跑综合

### 前提
- DC 在 Linux 服务器（template 里的库路径 `/home/PIE_student_1/Documents/smic55ll`
  必须能访问）
- Synopsys DC（`dc_shell`）在 PATH 里

### 启动命令
```bash
cd dc
dc_shell -f top_syn.tcl 2>&1 | tee top_syn_${USER}_$(date +%Y%m%d_%H%M).log
```

### 输出位置
所有输出按 `file_version`（默认 `soc_v1_estimate`）分子目录：
```
dc/
├── RPT/soc_v1_estimate/        # 报告（area / qor / timing / clock / power / constraints / check_*）
├── OUT/soc_v1_estimate/        # 网表（chip_top.v / .ddc / .sdc / .sdf）
├── WORK/soc_v1_estimate/       # DC 中间产物（cache，可删）
```

### 关键报告（看面积）
- `RPT/soc_v1_estimate/area.rpt` — 总面积概览
- `RPT/soc_v1_estimate/area_hier.rpt` — 按层级分解面积（找出大户）
- `RPT/soc_v1_estimate/qor.rpt` — WNS / TNS / 时序余量 / cell 数 / 等
- `RPT/soc_v1_estimate/timing.max.rpt` — Setup 路径详情
- `RPT/soc_v1_estimate/timing.min.rpt` — Hold 路径详情

---

## 调参建议

### 想看 100 MHz 综合的面积代价
改 `constraint_sdc.tcl`：
```tcl
set CLK_PERIOD 10
```
然后改 `set_env.tcl`：
```tcl
set file_version soc_v1_estimate_100mhz
```
重跑。`RPT/soc_v1_estimate_100mhz/area.rpt` 与 50 MHz 版本对比。

### 想开 DFT scan
改 `set_env.tcl`：
```tcl
set do_scan 1
```
top_syn 里 `compile_ultra -scan` 自动加 -scan flag。

### 想 dont_touch 所有 SRAM
改 `dont_touch.tcl`，把 boot_rom + 3 个 SRAM 加进去：
```tcl
set_dont_touch [get_cells u_soc_core/u_boot_rom]
set_dont_touch [get_cells u_soc_core/u_instr_sram]
set_dont_touch [get_cells u_soc_core/u_data_sram]
set_dont_touch [get_cells u_soc_core/u_weight_sram]
```
然后综合后报告里这些 cell 显示为 0 area（实际 SRAM macro 面积单独从 SRAM
compiler 算出来 add 上去）。

### 想换工艺库
改 `set_env.tcl` 里 `lib_slow` / `lib_fast`，再改 `top_syn.tcl` 里
`LIB_PATH` / `TARGET_LIB_LIST` / `IO_LIBRARY` / `MEMORY_LIB_LIST`。

---

## 已知 caveat

1. ~~sram_simple 综合成 FF 阵列~~ — **已修**：默认 OPT_SRAM_BLACKBOX=1 用 stub，面积 0；真 macro 由 P&R 接入
2. ~~CIM 模拟 macro 不在数字综合范围~~ — **已修**：默认 stub，面积 0；真模拟 macro die area 由模拟侧提供（doc/08）
3. ~~MEMORY_LIB_LIST 本项目实际不用~~ — **已修**：默认 OPT_USE_TEMPLATE_MEM_LIB=0 不加载（如 DC 报错可切回 1）
4. **vendor E203 综合很大** — `e203_core.v` 等 RTL 综合后 cell 数 5 万+ 是正常（这不是 over-estimate，是真实 RTL 复杂度）
5. ~~boot_rom 是 mask ROM 替换占位~~ — **已修**：默认 stub 面积 0；真 mask ROM 由 foundry compiler 接入

---

## 面积优化 flag（set_env.tcl 末尾的 5 个 OPT_*）

| Flag | 默认 | 作用 |
|---|---|---|
| `OPT_SRAM_BLACKBOX` | **1** | 1 = 用 dc/stubs/ 4 个空 stub 替换 SRAM/ROM/CIM 行为模型（**修 over-estimate**）；0 = 综合所有真 RTL |
| `OPT_USE_TEMPLATE_MEM_LIB` | **0** | 0 = 不加载 template 里 SNPU 用的 weight_sram/neuron_sram macro lib（本项目用不到）；1 = 加载（仅当 DC 因为 link library 报错时切回） |
| `OPT_AREA_HIGH_EFFORT` | **1** | 1 = compile_ultra 加 `-area_high_effort_script`（多跑几轮 area recovery）；0 = 标准 compile |
| `OPT_GATE_CLOCK` | **1** | 1 = compile_ultra 加 `-gate_clock`（自动插入 clock gating，省面积+功耗）；0 = 不插 |
| `OPT_POST_COMPILE_AREA` | **1** | 1 = compile 完后跑 `optimize_netlist -area` 扫尾（再省 1~3% 面积）；0 = 跳过节省 5~10 min |

### 默认配置（5 项全开）的面积估算口径

跑出来的 `area.rpt` **就是**真实流片**数字面积上限的合理近似**（不含 SRAM macro
和模拟 CIM macro，这两块是 P&R / 模拟侧分别接入）。

最终上报口径：
```
total chip area ≈ DC area report  + SRAM macro area  + analog CIM macro area
                 (digital, 本目录) (foundry compiler) (analog team)
```

### 想看更准的"全综合 over-estimate"对照

```bash
# 切到全综合模式
sed -i 's/set OPT_SRAM_BLACKBOX 1/set OPT_SRAM_BLACKBOX 0/' set_env.tcl
sed -i 's/set file_version    soc_v1_estimate/set file_version    soc_v1_estimate_full/' set_env.tcl
dc_shell -f top_syn.tcl 2>&1 | tee full_$(date +%Y%m%d_%H%M).log
```
对比 `RPT/soc_v1_estimate/area.rpt`（black-box）vs `RPT/soc_v1_estimate_full/area.rpt`（all-syn）
差值 ≈ FF-array 模型综合出的 over-estimate 面积。

---

## 后续 DC → P&R 流程
本目录只做综合（DC）。后续 P&R（ICC2 / Innovus）需要：
- 综合输出的 `.v` 网表（OUT/$file_version/chip_top.v）
- `.sdc` 约束（OUT/$file_version/chip_top.sdc）
- `.ddc` 数据库（OUT/$file_version/chip_top.ddc）
- pad cell library（待 PDK 接入）
- SRAM macro library（待 SRAM compiler 输出）
- CIM 模拟 macro abstract（待模拟侧交付）

不在本目录的 scope 内。
