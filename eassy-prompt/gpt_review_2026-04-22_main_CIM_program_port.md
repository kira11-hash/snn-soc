# GPT Code Review Request — main branch: CIM write/erase/verify port from v2

> 日期：2026-04-22
> 背景：用户要求把 v2 分支上的 CIM 编程 / 擦除 / 验证（含 GPT 刚做的 4 档脉冲）
> 移植到 main 分支（流片版本），**只移植编程能力 (A)**，不引入 V2.B multi-layer refactor (B)。
> 已通过 13/13 仿真回归 + 集成 elab check。请你作为独立第二意见做严苛审查。

---

## 1. 项目核心约束（保持不变）

- `NUM_INPUTS = 64`，`ADC_CHANNELS = 20`（Scheme B：ch 0-9 正列，ch 10-19 负列），`ADC_BITS = 8`
- `THRESHOLD_DEFAULT = 2550 = 1 × 255 × 10`，`TIMESTEPS_DEFAULT = 10`
- Scheme B 差分方案（硬冻结，不可改回 Scheme A）
- main 分支是流片 ready 版本；**本次 port 必须保持默认参数下行为 100% 等价**（只允许在
  `snn_soc_top.ENABLE_PROGRAM_MODE=1` 时启用编程路径）

---

## 2. 本次 port 的 commit 清单

### commit 4540f788（main）

| 类型 | 文件 | 描述 |
|---|---|---|
| NEW RTL | `rtl/snn/cim_program_ctrl.sv` | 330 行，11-state FSM：IDLE→SETUP→PULSE→PULSE_HOLD→READBACK→RB_WAIT→VERIFY→{PASS\|RETRY\|FAIL}→DONE |
| NEW RTL | `rtl/snn/cim_macro_arbiter.sv` | 110 行，推理/编程两路径在 CIM 宏访问上的 2:1 寄存器化 MUX |
| MOD RTL | `rtl/top/snn_soc_pkg.sv` | +PROG_LEVELS/ROWS/COLS/WRITE_PULSE_{1,10,100}US_CYC/ERASE_WIDTH_CYC/VERIFY_RETRY_MAX/MAX_BL_SCAN |
| MOD RTL | `rtl/reg/reg_bank.sv` | +6 新寄存器（0x38/3C/40/44/90/94）+ 4 档 pulse preset 解码函数 + snn/prog 互锁 |
| MOD RTL | `rtl/snn/cim_macro_blackbox.sv` | +P_USE_BRAM_WEIGHTS + prog_en/erase_en/verify_en 端口 + weight_mem[64][20] + bram_weighted_sum() |
| MOD RTL | `rtl/top/snn_soc_top.sv` | +ENABLE_PROGRAM_MODE 参数 + generate 块实例化 cim_program_ctrl + arbiter |
| MOD SIM | `sim/models/cim_macro_blackbox_weighted_icarus.sv` | 端口签名对齐：+P_USE_BRAM_WEIGHTS + 3 编程端口（全部忽略） |
| NEW TB | `tb/cim_program_ctrl_tb.sv` | 352 行，8 个子测试（含 4 档脉宽时序测量） |
| NEW TB | `tb/prog_pulse_cfg_tb.sv` | 197 行，REG_PROG_PULSE_WIDTH 4 档 preset + ERASE_WIDTH 写入忽略 |
| NEW SIM | 4 个新 filelist / run 脚本 | `sim/run_cim_program_ctrl.sh`, `sim/run_prog_pulse_cfg.sh` + filelists |
| MOD DOC | `CLAUDE.md`, `doc/02_reg_map.md` | +编程寄存器表 + 4 档 pulse 语义 |
| MOD | `.gitignore` | +sim/*.vvp + fpga_synth/v2b_synth_*/ 等 build artifacts |

**总量**：+1596 / -35 lines, 16 files

---

## 3. 请你重点审查的 7 个问题

### Q1. `REG_PROG_PULSE_WIDTH` 的 4 档硬件钳位
`reg_bank.sv:242-248` 写入路径：
```verilog
function automatic logic [15:0] decode_write_pulse_width(input logic [1:0] sel);
  case (sel)
    2'd0: decode_write_pulse_width = PROG_WRITE_PULSE_1US_CYC[15:0];   // 50
    2'd1: decode_write_pulse_width = PROG_WRITE_PULSE_10US_CYC[15:0];  // 500
    2'd2: decode_write_pulse_width = PROG_WRITE_PULSE_100US_CYC[15:0]; // 5000
    default: decode_write_pulse_width = PROG_WRITE_PULSE_100US_CYC[15:0]; // 3→100us clamp
  endcase
endfunction
```
**问题**：2'd3 语义是"保留"，当前实现把它钳到 100us；但注释说"防止误写 1ms SET 脉冲烧伤器件"。
- 这个软钳位在 RTL 层合理吗？还是应该在更底层（cim_program_ctrl 内部）再做一次防御？
- 2'd3 是否应该直接返回 0 或不生效，避免用户误以为能得到某个有效脉宽？

### Q2. 推理/编程两路径互锁是否足够？
`reg_bank.sv:286-291` 和 `:302-306`：
- 写 `CIM_CTRL.START=1` 时若 `prog_busy=1`，start_pulse 被屏蔽
- 写 `PROG_CTRL.START=1` 时若 `snn_busy=1`，prog_start_pulse 被屏蔽

**问题**：这种"写时互斥 + arbiter 1 拍延迟切换"够不够？能否构造一个时序使两路径同时进入 busy 状态？
具体：若 CPU 在同一总线周期下发两条背靠背请求，会不会绕过互锁？

### Q3. `cim_macro_arbiter` 复位时全清 0 的正确性
`cim_macro_arbiter.sv:62-75`：复位时所有输出（`macro_wl_spike`, `macro_cim_start` 等）都 `<= 0`。
**问题**：如果 `rst_n` 在推理进行中异步掉下来，推理端 `cim_start_pulse` 可能已经发出但被 arbiter 吞掉，会不会让推理 FSM 卡住？
（同理：rst_n 释放后，arbiter 需要多少拍才能恢复正常转发？）

### Q4. `cim_macro_blackbox` 的 `P_USE_BRAM_WEIGHTS` 开关
- 默认 0：popcount ADC model（V1 行为）
- 1：weighted sum from weight_mem（编程回归用）

**问题**：在 `snn_soc_top` 中：
```verilog
cim_macro_blackbox #(
  .P_USE_BRAM_WEIGHTS (ENABLE_PROGRAM_MODE)
) u_macro (...)
```
我把两个开关强绑了。合理吗？会不会出现需要 "ENABLE_PROGRAM_MODE=1 但仍用 popcount"
（例如只测互锁逻辑不关心权重）的场景被堵死？是否应该拆成两个独立的参数？

### Q5. `cim_program_ctrl` 的 `prog_bl_sel` 位宽
v2 原版用 `$clog2(MAX_BL_SCAN)` 宽度（v2 的 MAX_BL_SCAN=128 → 7 bit）；
main port 里 MAX_BL_SCAN = ADC_CHANNELS = 20 → `$clog2=5`。
line 180 原代码：
```verilog
prog_bl_sel <= {{($clog2(MAX_BL_SCAN)-5){1'b0}}, prog_col};
```
在 main 上这个会退化成 `{{0{1'b0}}, prog_col}`（零宽度 replicate + 5-bit prog_col）。
Icarus 接受且 cim_program_ctrl_tb 8/8 PASS，但 Vivado / Synopsys DC 是否也会接受
zero-replicate？是否应该改成更保守的 `prog_bl_sel <= prog_col;`？

### Q6. `cim_macro_blackbox.sv` 行为模型复位值
`:329-333`：
```verilog
if (c < NUM_OUTPUTS)
  weight_mem[r][c] <= ADC_BITS'(2);   // 正列
else
  weight_mem[r][c] <= ADC_BITS'(1);   // 负列
```
**问题**：我选这个复位值是为了"即使启用 weighted-sum 模式但没编程时也能出非零 spike"。
合理吗？还是应该复位到 0（未编程状态）让行为更可预测？

### Q7. V2.B 余留污染
我只 port 了 (A) CIM programming，但 v2 的 `snn_soc_pkg.sv` 里有一些 V2.B 相关的 parameter
（MAX_LAYERS, MAX_NEURONS, V2B_*）被我**没有**移植过来。
请确认：
- `cim_program_ctrl.sv` / `cim_macro_arbiter.sv` / `tb/cim_program_ctrl_tb.sv` 
  直接从 v2 复制过来，内部有无暗引 V2.B 参数？
  （我 grep 过：只引用 NUM_INPUTS/MAX_BL_SCAN/ADC_BITS/PROG_* —— 全部在 main pkg 里已加）

---

## 4. 回归结果（main post-port）

| # | 回归 | 结果 |
|---|---|---|
| 1 | `run_icarus_light.sh` | LIGHT_SMOKETEST_PASS |
| 2 | `run_icarus_weighted.sh` | WEIGHTED_SIM_PASS |
| 3 | `run_sample_align.sh` | SAMPLE_ALIGN_PASS (100/100) |
| 4 | `run_e203_icarus.sh` | E203_SMOKETEST_PASS |
| 5 | `run_jtag_loader_icarus.sh` | JTAG_MEM_LOADER_PASS |
| 6 | `run_jtag_rescue_top_icarus.sh` | JTAG_RESCUE_TOP_PASS |
| 7 | `run_uart_icarus.sh` | UART_SMOKETEST_PASS |
| 8 | `run_spi_icarus.sh` | SPI_SMOKETEST_PASS |
| 9 | `run_dma_icarus.sh` | DMA_SMOKETEST_PASS |
| 10 | `run_axi_bridge_icarus.sh` | AXI_BRIDGE_SMOKETEST_PASS |
| 11 | `run_adc_sat_counter.sh` | ADC_SAT_COUNTER_PASS |
| 12 | `run_cim_program_ctrl.sh` | CIM_PROGRAM_CTRL_PASS (8/8: 含 100us / 1ms 脉宽时序测量 + 全阵列擦除) |
| 13 | `run_prog_pulse_cfg.sh` | PROG_PULSE_CFG_TB_PASS (4 preset + erase_width 写入忽略) |

额外：ENABLE_PROGRAM_MODE=1 的 snn_soc_top 集成 elaboration PASS（iverilog）。

---

## 5. 你要产出的 verdict

请按以下格式回复：

### 5.1 每个问题 Q1-Q7 给出 verdict
```
Q1: ✅ OK / ⚠️ ACCEPTABLE_WITH_COMMENT / ❌ MUST_FIX
   [说明...]
```

### 5.2 你额外发现的问题
如果你发现上面 7 个问题之外的潜在问题（特别是：RTL 安全性 / 边界条件 / 综合风险 /
LVS 端口 mismatch），按 CLAUDE.md 的"RTL 漏洞报告规范"格式提供：
```
【缺陷描述】
【触发条件】
【仿真激励】（具体的 bus_write / 信号赋值序列）
【预期异常现象】
```

**硬性要求**：如果你无法写出具体仿真激励，必须标记为 `[疑似误报]` 而不是 `[确认 BUG]`。

### 5.3 整体 verdict
- `✅ APPROVE`：可以安全 push 到 origin/main
- `⚠️ APPROVE_WITH_MINOR_FIX`：可以 push，但建议后续 commit 修正 X 点
- `❌ BLOCK`：不要 push，必须先修 X 点

---

## 6. 附：如何取用文件给你审查

请用以下命令/路径查看具体文件：
```
git show main:rtl/snn/cim_program_ctrl.sv
git show main:rtl/snn/cim_macro_arbiter.sv
git show main:rtl/reg/reg_bank.sv
git show main:rtl/snn/cim_macro_blackbox.sv
git show main:rtl/top/snn_soc_pkg.sv
git show main:rtl/top/snn_soc_top.sv
git show main:tb/cim_program_ctrl_tb.sv
git show main:tb/prog_pulse_cfg_tb.sv
git diff main..v2  # 看与 v2 差异，确认 V2.B 未污染
```

commit hash：`4540f788`（main）；对应 v2 参考：`42301a7d`。

---

**审查回复后**，请用户明确告知："Claude, main commit 4540f788 GPT verdict 是 APPROVE/BLOCK/...", 然后再决定是否 push。

---

## UPDATE — 2026-04-22 Fixup Commit（原始 verdict ❌ BLOCK 已闭环）

GPT verdict `❌ BLOCK` 已回复，两个 must-fix：
- **Q2**：back-to-back START race → must add pending / guard 位
- **Q5**：zero-replicate `{{($clog2(MAX_BL_SCAN)-5){1'b0}}, prog_col}` → 改直接赋值

### 修复 1：reg_bank.sv 三重互锁

原 check：`!snn_busy`（仅 busy 单重），被 back-to-back 写绕过。
新 check（REG_CIM_CTRL / REG_PROG_CTRL 两侧对称）：
```verilog
REG_CIM_CTRL:
  if (req_wstrb[0] && req_wdata[0]
      && !prog_busy && !prog_start_pending && !prog_start_pulse) start_pulse <= 1'b1;
REG_PROG_CTRL:
  if (req_wstrb[0] && req_wdata[0]
      && !snn_busy && !snn_start_pending && !start_pulse) prog_start_pulse <= 1'b1;
```
新增 2 个寄存器：`snn_start_pending / prog_start_pending`
- set on start_pulse；clear on busy

三重守卫覆盖：
- `!busy`：稳态互锁（原有）
- `!pending`：start 已发但下游 busy 未升起（任意 N 拍延迟）
- `!start_pulse`：同拍 W1P（最激进的 back-to-back 情形）

### 修复 2：cim_program_ctrl.sv zero-replicate

```diff
-              prog_bl_sel   <= {{($clog2(MAX_BL_SCAN)-5){1'b0}}, prog_col};
+              prog_bl_sel   <= prog_col;
```
SV §10.7 自动窄→宽零扩展，同时覆盖 MAX_BL_SCAN 未来扩展场景。

### 新 TB：tb/prog_start_interlock_tb.sv（6 cases）

| # | 描述 | 结果 |
|---|---|---|
| T1 | 独立 CIM.START | PASS |
| T2 | 独立 PROG.START | PASS |
| T3★ | back-to-back CIM→PROG（Q2 race） | **PASS**（race blocked） |
| T4★ | 反向 PROG→CIM | **PASS**（race blocked） |
| T5 | snn_busy=1 时写 PROG.START（稳态互锁回归） | PASS |
| T6 | pending-only guard（busy 尚未升起但 pending 已高） | PASS |

T3/T4 是 GPT Q2 指出的 race 证据。TB 人为保持 snn_busy / prog_busy 为 0（模拟 downstream FSM 还没 busy），验证 pending+pulse 守卫仍能封堵。

### 全回归（main post-fix，14/14 PASS）

```
LIGHT_SMOKETEST_PASS
WEIGHTED_SIM_PASS
SAMPLE_ALIGN_PASS (100/100)
E203_SMOKETEST_PASS
JTAG_MEM_LOADER_PASS
JTAG_RESCUE_TOP_PASS
UART_SMOKETEST_PASS
SPI_SMOKETEST_PASS
DMA_SMOKETEST_PASS
AXI_BRIDGE_SMOKETEST_PASS
ADC_SAT_COUNTER_PASS
CIM_PROGRAM_CTRL_PASS (8/8)
PROG_PULSE_CFG_TB_PASS
PROG_START_INTERLOCK_TB_PASS (6/6, including T3/T4 race coverage) ← NEW
```

### 未处理（GPT 标注为 non-blocking，本次 commit 不修）

- Q1 readback sel 钳位（acceptable_with_comment）
- Q4 split ENABLE_PROGRAM_WEIGHT_MODEL 参数（acceptable_with_comment）
- Q6 weight_mem reset 改 0（acceptable_with_comment）

这三项可留待后续 commit 单独处理，不阻塞 push。

### 请求二次审查

如上修复妥当，请回 `✅ APPROVE_FIXUP` 或提出新问题。拟 commit message：
`main: fixup CIM programming port — Q2 back-to-back START interlock + Q5 zero-replicate`

