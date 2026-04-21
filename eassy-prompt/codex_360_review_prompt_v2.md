# Codex 360° 审查 Prompt V2 — ADC 扫描参数化 + GPT 首轮修复 + E203 回归调查

## 背景

SNN SoC 项目（v2 分支），距离上一次 360° 审查已完成以下工作：

### 1. ADC 扫描机制参数化（新架构）
将推理路径的 ADC 扫描从固定 20 路扩展为可配，为 4 层多层网络（64→32→16→10）做准备：
- `snn_soc_pkg.sv`：新增 `MAX_BL_SCAN = 128` 参数
- `adc_ctrl.sv`：`bl_sel` 位宽从 `$clog2(ADC_CHANNELS)=5` 扩宽到 `$clog2(MAX_BL_SCAN)=7`，`raw_data[]` 数组扩到 128 深度，钳位上限改为 `MAX_BL_SCAN`
- `cim_macro_arbiter.sv` / `cim_program_ctrl.sv` / `cim_macro_blackbox.sv`：`bl_sel` 端口位宽同步到 7-bit
- `snn_soc_top.sv`：`bl_sel`、`arb_bl_sel`、`prog_bl_sel_sig`、外部 `bl_sel_ext` 全部升到 7-bit
- `chip_top.sv`：`bl_sel_pad` 升到 7-bit（流片需要多 2 个 pad）
- 所有 TB（`top_tb.sv`、`e203_tb.sv`、`jtag_rescue_top_tb.sv`、`top_tb_sample_align.sv`、`multilayer_tb.sv`、`top_tb_icarus_light/weighted.sv`、`top_tb_adc_sat_counter.sv`）：`bl_sel_ext` 宣告升级

V1 向后兼容：默认 `bl_scan_count = ADC_CHANNELS = 20`，`use_scan_cfg=0`，行为与原 V1 完全一致。

### 2. GPT 首轮审查修复（8 个 finding）
| ID | 问题 | 修复位置 |
|---|---|---|
| **D1-001** | verify 窗口用 `pulse_count`（retry 后偏移），应该用 `target_level` | `cim_program_ctrl.sv:235-240` |
| **D1-003** | 脉宽启动锁存，防止中途改寄存器影响本次序列 | `cim_program_ctrl.sv` 新增 `latched_pulse_width/latched_erase_width` |
| **D1-004** | `PROG_COL ≥ PROG_COLS(20)` 直接 FAIL | `cim_program_ctrl.sv` ST_IDLE 新增守卫 |
| **D1-005** | 推理/编程顶层互锁（`REG_CIM_CTRL.START` 在 `prog_busy=1` 时屏蔽；`REG_PROG_CTRL.START` 在 `snn_busy=1` 时屏蔽） | `reg_bank.sv:350-362` |
| **D1-006** | 编程使能 `prog_en`/`erase_en`/`verify_en` 通过 `prog_en_ext`/`erase_en_ext`/`verify_en_ext` 引到 `chip_top` pad | `snn_soc_top.sv`、`chip_top.sv` |
| **D1-007** | `cur_wl_offset` / `cur_bl_offset` 标注为"未来硬件多层保留字段"，`verilator lint_off UNUSEDSIGNAL` | `layer_sequencer.sv:100-104` |
| **D5-001** | `chip_top` 实例化 `snn_soc_top` 时加 `ENABLE_PROGRAM_MODE(1'b1)` | `chip_top.sv:58-61` |
| **D4-001** | `doc/03_cim_if_protocol.md` 的编程接口表（旧 `prog_done`/`verify_pass` 等信号）更新为当前 RTL 实际端口 | `doc/03_cim_if_protocol.md` |

### 3. 回归测试通过情况

| TB | 结果 |
|---|---|
| LIGHT_SMOKETEST | ✅ PASS |
| WEIGHTED_SIM | ✅ PASS |
| MULTILAYER_SMOKE | ✅ PASS |
| SAMPLE_ALIGN (100/100) | ✅ PASS |
| ADC_SAT_COUNTER | ✅ PASS |
| JTAG_RESCUE_TOP | ✅ PASS |
| **E203_SMOKETEST** | ❌ **FAIL（需要你帮忙查）** |

---

## 🚨 重点任务 1：E203 回归调查（最高优先级）

### 现象
```
[INFO] E203 minimal-area smoke start
[ERR] Bootloader did not finish SPI load, PC=0x00000000
[ERR] Signature write not observed, PC=0x00000000
[ERR] UART activity not completed, PC=0x00000000
[ERR] Firmware did not complete result/done flow, count=0 done=0x00000000 PC=0x00000000
...
E203_SMOKETEST_FAIL errors=11
Time: 15320130000 (15.3ms 芯片时间)
```

**PC 始终为 0x00000000**，CPU 从未执行任何指令。编译无警告，仿真正常退出到 $fatal（测试逻辑失败）。

### 已确认的事实（请 Codex 参考）
1. **Baseline（`git stash` 把所有 tracked 修改拿走后）E203 PASS**，后续 `git stash pop` 回来 E203 FAIL → 说明 uncommitted 修改中有东西破坏了 E203
2. **其他所有 TB 都通过**（LIGHT/WEIGHTED/MULTILAYER/SAMPLE_ALIGN/ADC_SAT/JTAG）— 说明核心数据通路、bus、reg_bank 写读、FIFO、lif_neurons、adc_ctrl 都正常
3. **E203 TB 用 `.*` wildcard 端口绑定** — `snn_soc_top #(.ENABLE_E203(1'b1)) dut (.*);`
4. **只有 E203 用 vendor IP**（`rtl/vendor_e203/e203/core/*.v`），其他 TB 不用
5. Firmware 编译正常（`fw/out/bootloader.hex` 存在且有内容）
6. 本 session 我新加的东西理论上不该影响 E203：
   - 我新加的 `prog_en_ext/erase_en_ext/verify_en_ext` 只在 `ENABLE_PROGRAM_MODE=1` 时有实际驱动，E203 TB 没有设置这个参数（默认 `1'b0`），所以走 `gen_no_prog` 分支，这三个信号恒 0
   - `bl_sel_ext` 从 5-bit 变 7-bit — E203 TB 不使用 `ENABLE_EXT_CIM_IF`，所以走 `gen_internal_cim_macro` 分支，外部 pad 信号不驱动任何东西
   - `D1-005` 互锁：`prog_busy=0` 时 `!prog_busy=1`，不影响 `start_pulse`；`snn_busy` 同理
7. 本 session 之前就存在的 uncommitted 修改（例如 `e203_min_wrap.sv` 只加了注释）看起来无逻辑改动

### 请帮助调查
1. **`git diff HEAD -- rtl/ tb/ sim/ | head -1500`** 逐项扫描所有 uncommitted 修改，找出 E203 启动被卡住的根因
2. 特别关注：
   - `rtl/reg/reg_bank.sv`（GPT 首轮后新加了 `!prog_busy` 和 `!snn_busy` 互锁 gate，但 E203 boot 期间 `prog_busy=0`，理论上不该生效）
   - `rtl/top/snn_soc_top.sv`（新加了 3 个外部 output 端口 `prog_en_ext/erase_en_ext/verify_en_ext`，用 `.*` 绑定时可能有隐式命名冲突？）
   - `rtl/mem/fifo_sync.sv`（session 前修改过，可能影响 input FIFO 或 output FIFO 初始状态）
   - `rtl/bus/icb2simple_bridge.sv`、`rtl/bus/icb_err_slave.sv`（E203 CPU 通过这两个桥访问 bus，任何改动都可能卡死 CPU）
   - `rtl/periph/jtag_mem_loader.sv`（虽然 E203 不用 rescue，但 jtag_mem_loader 与 E203 共用 bus 仲裁）
   - `rtl/top/e203_min_wrap.sv`（虽然看起来只改注释，请仔细看有没有端口顺序或 reset 信号改动）
3. 验证 `dut.u_instr_sram.mem` 的实际内容：TB 用 `$readmemh` 写入 bootloader.hex，但如果 `mem` 数组尺寸或路径被改，CPU 会从 NOP(`0x0000_0013`) 开始取指 — PC=0 不动正好符合"CPU 跑 NOP + 默认 PC=0"的症状
4. 必要时回头看看 E203 vendor IP 对 `rst_n` 的释放时机是否被某个修改延后了

### 输出格式要求
```
【E203 回归根因】具体文件:行号
【证据】为什么这是 root cause（最好带波形/信号推理）
【修复建议】最小改动方案
```

---

## 重点任务 2：本轮 ADC 扫描参数化 + D1-XXX 修复的 360° 审查

### 审查范围
与上次相同的 6 个维度（RTL 正确性 / 综合安全 / TB 覆盖度 / 文档一致性 / 架构完整性 / 已知限制）。

### 核心文件变更清单
```
修改：
  rtl/top/snn_soc_pkg.sv          + parameter MAX_BL_SCAN = 128
  rtl/snn/adc_ctrl.sv             bl_sel 7-bit / raw_data[128] / clamp to MAX_BL_SCAN / assertion 用 eff_scan_max
  rtl/snn/cim_macro_arbiter.sv    bl_sel 端口 7-bit（infer/prog/macro）
  rtl/snn/cim_program_ctrl.sv     D1-001 + D1-003 + D1-004，prog_bl_sel 7-bit，prog_col 5-bit 零扩展
  rtl/snn/cim_macro_blackbox.sv   bl_sel 端口 7-bit（行为模型仍只有 20 列权重，超出范围 MUX 返回 0，断言降级为 warning）
  rtl/top/snn_soc_top.sv          bl_sel 7-bit 全链路 + 新 3 个外部 pad 输出（prog_en_ext/erase_en_ext/verify_en_ext）
  rtl/top/chip_top.sv             bl_sel_pad 7-bit + ENABLE_PROGRAM_MODE=1 + 3 个 prog_xxx_pad 端口
  rtl/reg/reg_bank.sv             D1-005 推理/编程互锁
  rtl/snn/layer_sequencer.sv      D1-007 offset 字段 lint 抑制 + 注释
  所有 tb/*.sv                    bl_sel_ext 位宽升级 + 新 3 个 prog_xxx_ext 信号声明
  doc/03_cim_if_protocol.md       编程接口表更新
```

### 特别关注项

#### ADC 扩宽的正确性
- `adc_ctrl.sv` 中 `BL_SEL_MAX = BL_SEL_WIDTH'(ADC_CHANNELS-1)` — 当 `use_scan_cfg=0`（V1 路径），`eff_scan_max = BL_SEL_MAX = 19`，`raw_data[]` 只用到 0..19。V1 行为是否完全一致？
- `cim_macro_blackbox.sv` 行为模型只有 20 列权重，多层扫描时（bl_scan_count>20）会返回 0 — 这对多层 TB 的 MULTILAYER_SMOKE_PASS 意味着什么？是否需要升级行为模型支持 128 列？
- `prog_bl_sel` 扩宽到 7-bit 但 `prog_col` 仍是 5-bit，零扩展 `{{2{1'b0}}, prog_col}` 是否在所有 Icarus/VCS/DC 中等效？

#### D1-001 verify 窗口修复
- `target_level` 锁存的是 `prog_level[3:0]`，窗口计算 `target_level * (256/PROG_LEVELS) ± 2 = target_level * 16 ± 2`
- 当 `target_level=0` 时窗口是 `-2..+2`，但 `readback_val` 是无符号 8-bit，`ADC_BITS'(-2) = 8'hFE`，`readback_val >= 8'hFE` 几乎总是 false — **这是否导致 level=0 写入永远判 FAIL？**
- 但 ST_IDLE 已经对 `level=0 && !erase` 早退到 ST_PASS，所以 ST_VERIFY 不会见到 level=0。**请验证这个保护是否完备**

#### D1-005 顶层互锁
- `!prog_busy` 在 ENABLE_PROGRAM_MODE=0 时恒为 `!0=1`（`gen_no_prog` 把 `prog_busy` 接 `1'b0`）
- `!snn_busy` 在空闲时为 1 — E203 boot 期间 CPU 写 `CIM_CTRL.START=1` 时 `prog_busy=0`，gate 应该通过
- **但如果 `prog_busy` 信号链上有 generate 内部连接错误（比如在 ENABLE_PROGRAM_MODE=0 时实际值是 X），会不会引起 E203 boot 问题？**

#### D1-003 脉宽锁存
- `latched_pulse_width <= prog_pulse_width` 在 ST_IDLE 接收 `prog_start` 时锁存
- ST_PULSE 中使用 `latched_pulse_width`，中途软件改 `REG_PROG_PULSE_WIDTH` 不影响本次
- **但 retry 路径（ST_RETRY → ST_SETUP → ST_PULSE）也使用 `latched_pulse_width`（同一个 latch 值）** — 重试时用的脉宽仍是锁存的值，这是正确设计吗？或者应该允许重试时用当前寄存器值？

#### chip_top pad 预算
- 原来 `bl_sel_pad=[4:0]` = 5 pin
- 现在 `bl_sel_pad=[6:0]` = 7 pin（+2 pin）
- 加上新的 `prog_en_pad/erase_en_pad/verify_en_pad` = +3 pin
- **总计 +5 pin**。`doc/15_asic_pad_map.md` 的 45 pin 信号预算是否还够？这里是否需要更新 pad map 文档？

---

## 审查提醒（沿用上次）

1. **先读 `CLAUDE.md` 的误报 KB**，避免 FP-001~FP-008 重复
2. 本项目 SystemVerilog RTL，用硬件设计思维审查
3. `cim_macro_blackbox.sv` 是**行为模型**，不会综合
4. 报告 RTL bug 必须同时给出仿真激励（CLAUDE.md "RTL 漏洞报告规范"）
5. 单时钟域，不要报 CDC 误报（FP-005）
6. **E203 问题优先**，其他 finding 按上次的输出格式：
   ```
   【编号】DX-XXX
   【维度】...
   【严重性】CRITICAL / HIGH / MEDIUM / LOW
   【文件】path:line
   【描述】...
   【仿真激励】（如是 RTL bug）
   【建议修复】...
   ```

## 审查基线命令（请先执行确认）

```bash
cd sim && bash run_icarus_light.sh          # 期望 LIGHT_SMOKETEST_PASS
cd sim && bash run_icarus_weighted.sh       # 期望 WEIGHTED_SIM_PASS
cd sim && bash run_multilayer.sh            # 期望 MULTILAYER_SMOKE_PASS
cd sim && bash run_sample_align.sh          # 期望 SAMPLE_ALIGN_PASS (100/100)
cd sim && bash run_adc_sat_counter.sh       # 期望 ADC_SAT_COUNTER_PASS
cd sim && bash run_jtag_rescue_top_icarus.sh # 期望 JTAG_RESCUE_TOP_PASS
cd sim && bash run_e203_icarus.sh           # 当前 FAIL — 请帮忙查
```

审查时请先跑一遍确认基线现状，再进 360° 审查。

---

## 输出总结表

```
| 维度 | CRITICAL | HIGH | MEDIUM | LOW |
|------|----------|------|--------|-----|
| E203 回归 | ... | ... | ... | ... |
| 本轮修复 RTL | ... | ... | ... | ... |
| ADC 参数化 | ... | ... | ... | ... |
| 综合安全 | ... | ... | ... | ... |
| 文档一致性 | ... | ... | ... | ... |
| 架构完整性 | ... | ... | ... | ... |
```
