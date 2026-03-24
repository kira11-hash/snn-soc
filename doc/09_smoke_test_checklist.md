# Smoke Test 完整操作手册

最后更新：2026-03-24

---

## 0. 文档范围与环境说明

本文档是 SNN SoC 项目的仿真验证操作手册，覆盖从黑盒 smoke 到带权重仿真的完整流程，包含每一步的**命令、预期输出、波形检查要点和故障排查方法**。

### 仿真环境

| 环境 | 工具 | 平台 | 用途 |
|------|------|------|------|
| Icarus Verilog | iverilog + vvp + GTKWave | 本机 Windows | 黑盒 smoke、带权重 smoke、快速迭代 |
| VCS + Verdi | vcs-2021.09-sp2 + verdi-2021.09-sp2 | 学校服务器 Linux | SVA 断言验证、FSDB 波形深度分析 |

### 服务器 EDA 工具路径

```
VCS_HOME=/opt/Synopsys/vcs_green/vcs-2021.09-sp2
VERDI_HOME=/opt/Synopsys/verdi_green/verdi-2021.09-sp2
环境初始化脚本：/home/opt/demo/syn.env（脚本会自动 source）
```

### 当前冻结参数（所有仿真共用）

| 参数 | 值 | 说明 |
|------|---|------|
| NUM_INPUTS | 64 | 8×8 输入像素 |
| ADC_BITS | 8 | 8-bit ADC |
| ADC_CHANNELS | 20 | Scheme B 差分，10 pos + 10 neg |
| TIMESTEPS | 10 | 时间步数 |
| THRESHOLD_RATIO | 1 | ratio_code |
| THRESHOLD_DEFAULT | 2550 | = 1 × 255 × 10 |
| reset_mode | soft | V = V - Vth |

### 2026-03-24 全量复核覆盖面

以下命令已在当前主线环境重新执行并通过，可作为 tapeout 前的最低复核基线：

| 类别 | 命令 | 结果 |
|------|------|------|
| Python 主机自测 | `python scripts/test_jtag_rescue.py` | `JTAG_PYHOST_SELFTEST_PASS` |
| UART 单测 | `cd sim && bash run_uart_icarus.sh` | `UART_SMOKETEST_PASS` |
| SPI 单测 | `cd sim && bash run_spi_icarus.sh` | `SPI_SMOKETEST_PASS` |
| DMA 单测 | `cd sim && bash run_dma_icarus.sh` | `DMA_SMOKETEST_PASS` |
| AXI-Lite bridge 单测 | `cd sim && bash run_axi_bridge_icarus.sh` | `AXI_BRIDGE_SMOKETEST_PASS` |
| 黑盒顶层 smoke | `cd sim && bash run_icarus_light.sh` | `LIGHT_SMOKETEST_PASS` |
| 带权重顶层回归 | `cd sim && bash run_icarus_weighted.sh +FAIL_ON_ZERO_SPIKE=1` | `WEIGHTED_SIM_PASS` |
| Python↔RTL 样本对齐 | `cd sim && bash run_sample_align.sh` | `SAMPLE_ALIGN_PASS (100/100)` |
| ADC 饱和计数回归 | `cd sim && bash run_adc_sat_counter.sh` | `ADC_SAT_COUNTER_PASS` |
| JTAG loader 单测 | `cd sim && bash run_jtag_loader_icarus.sh` | `JTAG_MEM_LOADER_PASS` |
| JTAG rescue 顶层回归 | `cd sim && bash run_jtag_rescue_top_icarus.sh` | `JTAG_RESCUE_TOP_PASS` |
| E203 最小启动链 | `cd sim && bash run_e203_icarus.sh` | `E203_SMOKETEST_PASS` |
| `chip_top` Icarus 编译门禁 | `cd sim && iverilog -g2012 -gno-assertions -f rtl_with_chip_top_check.f -s chip_top -o chip_top_check.out` | 通过 |
| `chip_top` Verilator lint | `verilator.cmd -Wall --lint-only --top-module chip_top -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -f sim\\rtl_with_chip_top_check.f` | 通过 |
| 旧 `top_tb` 入口 | `cd sim && iverilog -g2012 -gno-assertions -f sim.f -s top_tb -o top_tb_check.out && vvp top_tb_check.out` | 跑通 |
| Shell 语法检查 | `bash -n sim/*.sh fw/*.sh` | 全部通过 |
| Python 语法检查 | `python -m py_compile scripts\\jtag_rescue.py scripts\\test_jtag_rescue.py fw\\bin_to_readmemh.py fw\\build_flash_image.py doc\\threshold_recommend.py` | 全部通过 |

### 参数覆盖说明

上述全量回归均使用冻结默认配置（T=10, ratio=1, reset_mode=soft）。当前 V1 仅冻结单一参数点，不做参数扫描。如需在 bring-up 阶段做额外验证，可手动修改 TB 中的 `TIMESTEPS` / `THRESHOLD` 值进行快速冒烟，但**正式回归以冻结配置为准**。

| 测试 | 基线配置 | 可选手动变参 |
|------|----------|-------------|
| LIGHT_SMOKETEST | T=10, ratio=1, test_mode | T∈{3,5} 快速冒烟 |
| WEIGHTED_SIM | T=10, ratio=1 | 改 threshold 后验证输出变化合理 |
| SAMPLE_ALIGN | T=10, ratio=1, 100 样本 | 固定配置，不做变参 |
| ADC_SAT_COUNTER | T=2+1, test_data_pos=0xFF | 固定配置 |
| E203_SMOKETEST | T=10, ratio=1 | 固定配置 |

补充说明：
- `run_jtag_rescue_top_icarus.sh` 和 `run_e203_icarus.sh` 依赖 WSL 内可用的 `riscv64-unknown-elf-gcc / objcopy`。
- `run_jtag_rescue_top_icarus.sh` 和 `run_e203_icarus.sh` 在构建固件时会显式传入 `UART_BAUD_DIV_OVERRIDE=2u`，仅用于缩短 Icarus 仿真时间；`uart_ctrl` 的默认硬件口径仍是 `434`（50MHz / 115200）。
- `run_icarus_weighted.sh`、`run_sample_align.sh` 和 `run_vcs_weighted.sh` 会优先在仓库内自动搜索任意 `results/exports/` 目录下的 `weight_pos.hex / weight_neg.hex`（跳过 `backups/`），找不到时再回退到 `fpga/cim_model/` 或 `sim/`；如有多套导出物，建议显式设置 `WEIGHT_SRC_DIR=<目录>`。
- `run_sample_align.sh` 还会自动搜索任意 `rtl_stimulus/` 目录下的 `all_samples.hex / expected_classes.hex`（同样跳过 `backups/`），必要时可显式设置 `STIMULUS_DIR=<目录>`。
- 所有直接使用 `iverilog -f *.f` 的命令都默认**当前工作目录是 `sim/`**；如果从仓库根目录执行，请保留文档里的 `cd sim &&` 前缀，否则 `.f` 内相对路径会解析失败。
- Windows PowerShell 下若直接跑 `chip_top` / `top_tb` 这类裸命令，请使用 `iverilog.exe` / `vvp.exe` / `verilator.cmd`，不要套在 `bash -lc "..."` 里；后者可能会误切到 WSL PATH，出现“`iverilog: command not found`”或错误的 `verilator` 安装路径。
- `top_tb` 入口没有单独的 `PASS` 字符串；判定标准是 `vvp` 退出码为 0，且日志尾部出现 `[TB] Simulation finished.`。

---

## 1. Step 3.1 — 黑盒 Icarus Smoke（本机 Windows）

### 1.1 这一步验证什么

- 用 **test mode**（假数据）验证整条数字控制链路：寄存器写入 → DMA 搬运 → CIM 控制 FSM → ADC → LIF → spike 输出
- **不加载**真实权重 hex，使用 `cim_macro_blackbox.sv`（RTL 内建行为模型）
- 确认新的 threshold=2550、T=10 配置下，test mode 仍能正常产生 spike

### 1.2 运行命令

```bash
cd sim
bash run_icarus_light.sh
```

### 1.3 预期终端输出

正常通过时，终端应该看到类似以下打印：

```
[INFO] Icarus light smoke test start
[INFO] Config: EXPECTED_OUT_COUNT=100 CHECK_OUT_COUNT=1
[INFO] DMA done after 81 polls, DMA_CTRL=0x00000002
[INFO] CIM done after 4722 polls, CIM_CTRL=0x00000080
[INFO] OUT_FIFO_COUNT=0x00000064 (100)
LIGHT_SMOKETEST_PASS
```

> 注：上面的轮询次数来自 2026-03-24 对当前 `main` 的实际复核结果；如果后续 TB 轮询节奏或日志抽样点变化，poll 次数可不同，但 `PASS` 字符串与 `OUT_FIFO_COUNT=100` 判据不应漂移。

**通过标准**：
1. 终端出现 `LIGHT_SMOKETEST_PASS`
2. 脚本退出码为 0（`echo $?` 返回 0）
3. `OUT_FIFO_COUNT=100`（10 个输出神经元 × 10 个时间步 = 100 个 spike）
4. 无任何 `[ERR]` 打印

### 1.4 产物文件

| 文件 | 路径 | 说明 |
|------|------|------|
| 仿真日志 | `sim/icarus_light.log` | 完整终端输出的副本 |
| VCD 波形 | 临时目录（脚本结束后清理） | 如需保留波形见 1.5 |

> 注意：当前 `run_icarus_light.sh` 使用临时目录运行，结束后自动清理。VCD 波形不会保留到 `sim/waves/`。如果需要看波形，见下一节。

### 1.5 如何查看黑盒 smoke 的波形

当前黑盒脚本默认不保留 VCD。如果你需要看波形（推荐首次跑时看一次），有两种方法：

**方法 A：手动跑 iverilog（推荐）**

```bash
cd sim
iverilog -g2012 -gno-assertions -f sim_icarus_light.f -s top_tb_icarus_light -o light.out
vvp light.out +EXPECTED_OUT_COUNT=100 +CHECK_OUT_COUNT=1
```

此时 VCD 文件会生成在 `sim/waves/icarus_light.vcd`，用 GTKWave 打开：

```bash
gtkwave waves/icarus_light.vcd
```

**方法 B：注释掉脚本里的 cleanup**

编辑 `run_icarus_light.sh`，临时注释掉 `trap cleanup EXIT` 那行，跑完后 VCD 在临时目录里。

### 1.6 黑盒波形检查要点

在 GTKWave 中，依次检查以下信号：

#### （1）总线写入阶段

| 信号 | 路径 | 检查内容 |
|------|------|---------|
| m_valid | `dut.bus_if.m_valid` | 每次写操作拉高 1 个周期 |
| m_addr | `dut.bus_if.m_addr` | 确认写入地址序列正确（先写 TIMESTEPS、THRESHOLD，然后写 DATA_SRAM，最后写 DMA） |
| m_wdata | `dut.bus_if.m_wdata` | TIMESTEPS 寄存器写入值 = 0x0000000A (10)，THRESHOLD = 0x000009F6 (2550) |
| m_ready | `dut.bus_if.m_ready` | 每次写操作后 1 个周期内拉高（总线 1-cycle 响应） |

#### （2）DMA 搬运阶段

| 信号 | 路径 | 检查内容 |
|------|------|---------|
| dma_busy | `dut.u_dma.*` | START 后拉高，搬完所有数据后拉低 |
| input_fifo_push | `dut.u_input_fifo.push` | 应看到连续的 push 脉冲 |
| input_fifo_count | `dut.u_input_fifo.*` | 数据逐条入 FIFO，最终深度 = T × PIXEL_BITS = 80 |

#### （3）CIM 推理阶段

| 信号 | 路径 | 检查内容 |
|------|------|---------|
| cim_ctrl state | `dut.u_cim_ctrl.*` | FSM 应从 IDLE → 逐帧逐 bit-plane 处理 → DONE |
| wl_spike | `dut.u_wl_mux_wrapper.*` | 每个 bit-plane 一次 WL 脉冲，8 组 × 8 行 |
| adc state | `dut.u_adc.state` | ADC 状态机：IDLE → 逐 channel 采样 → 差分计算 → DONE |
| bl_sel | `dut.u_adc.bl_sel` | 从 0 扫到 19（20 个 ADC 通道） |
| neuron_in_valid | `dut.u_adc.neuron_in_valid` | 每轮 ADC 完成后出 10 个 valid 脉冲 |
| neuron_in_data | `dut.u_adc.neuron_in_data` | 有符号 9-bit 差分值（Scheme B） |

#### （4）LIF 神经元阶段

| 信号 | 路径 | 检查内容 |
|------|------|---------|
| membrane | `dut.u_lif.*` | 每个神经元的膜电位应单调递增（因为 test mode 数据固定），超过 threshold 后被 reset |
| spike_out | `dut.u_lif.*` | 当 membrane ≥ threshold 时应出 spike |
| output_fifo_push | `dut.u_output_fifo.push` | 每个 spike 对应一次 push |

#### （5）最终结果

| 信号 | 路径 | 检查内容 |
|------|------|---------|
| output_fifo_count | `dut.u_output_fifo.*` | 最终应 = 100 |

### 1.7 可选：覆盖默认参数

```bash
# 修改期望的输出 spike 数量
SMOKE_EXPECTED_OUT_COUNT=18 bash run_icarus_light.sh

# 关闭 count 检查（只看链路通不通）
SMOKE_CHECK_OUT_COUNT=0 bash run_icarus_light.sh
```

---

## 2. Step 3.2 — 带权重 Icarus Smoke（本机 Windows）

### 2.1 这一步验证什么

- 加载 Python 建模导出的**真实权重** (`weight_pos.hex` / `weight_neg.hex`)
- 使用 `cim_macro_blackbox_weighted_icarus.sv`（替换黑盒模型，权重从 hex 文件读入）
- 输入是一个人造的**十字图样**（不是真实 MNIST，真实对齐在 Step 3.4）
- 验证：权重加载正确 → MAC 累加 → Scheme B 差分 → LIF 膜电位 → spike 输出

### 2.2 前置条件

权重 hex 文件必须存在。脚本会按以下顺序自动查找：

1. 若已设置 `WEIGHT_SRC_DIR`，直接使用该目录
2. 仓库内任意 `results/exports/` 目录（自动 `find`，默认跳过 `backups/`）
3. `../fpga/cim_model/`
4. `./`（sim 目录下）

如果自动查找失败，手动指定：

```bash
WEIGHT_SRC_DIR="../项目相关文件/器件对齐/Python建模/results/exports" bash run_icarus_weighted.sh
```

### 2.3 运行命令

```bash
cd sim
bash run_icarus_weighted.sh
```

### 2.4 预期终端输出

```
[INFO] Weighted Icarus source-level simulation start
[INFO] Config: TIMESTEPS=10 THRESHOLD=2550 FAIL_ON_ZERO_SPIKE=1
[INFO] DMA done after 81 polls
[INFO] CIM done after 4722 polls
[INFO] OUT_FIFO_COUNT=55
[INFO] spike_id[0]=0
[INFO] spike_id[1]=6
...
WEIGHTED_SIM_PASS
```

**通过标准**：
1. 终端出现 `WEIGHTED_SIM_PASS`
2. `OUT_FIFO_COUNT > 0`（至少有 spike 输出，说明 MAC→LIF 链路正常）
3. 无任何 `[ERR]` 打印
4. spike_id 值在 0~9 范围内（对应 10 个输出神经元）

### 2.5 产物文件

| 文件 | 路径 | 说明 |
|------|------|------|
| 仿真日志 | `sim/icarus_weighted.log` | 完整终端输出 |
| VCD 波形 | `sim/waves/icarus_weighted.vcd` | 自动保留（与黑盒不同） |

### 2.6 用 GTKWave 查看带权重波形

```bash
gtkwave sim/waves/icarus_weighted.vcd
```

### 2.7 带权重波形检查要点

除了 1.6 中所有检查项之外，还需要额外检查：

#### （1）权重加载确认

权重模型 `cim_macro_blackbox_weighted_icarus.sv` 会在仿真开始时用 `$readmemh` 加载权重。在当前主线日志中应看到类似：

```
[cim_macro_weighted] loaded weight_pos.hex / weight_neg.hex
[cim_macro_weighted] layout=row-major by input_row, outputs=10 inputs=64
```

#### （2）CIM 输出（BL 数据）

| 信号 | 路径 | 检查内容 |
|------|------|---------|
| bl_data | `dut.u_macro.*` | pos 列（ch 0~9）和 neg 列（ch 10~19）的 ADC 输出值，不应该全 0 也不应该全 FF |

#### （3）差分结果

| 信号 | 路径 | 检查内容 |
|------|------|---------|
| neuron_in_data | `dut.u_adc.neuron_in_data` | 有符号 9-bit，= pos - neg。正常情况下有正有负，不应全为 0 |

#### （4）膜电位累加曲线

| 信号 | 路径 | 检查内容 |
|------|------|---------|
| membrane[0~9] | `dut.u_lif.*` | 10 个神经元各自的膜电位，应该逐 timestep 累加。超过 2550 后 reset（soft: V = V - 2550） |

#### （5）spike 输出

| 信号 | 路径 | 检查内容 |
|------|------|---------|
| spike | `dut.u_lif.*` | 哪些神经元在哪个时间步 fire 了 |
| spike_id | 终端打印 | 对应 `[INFO] spike_id[N]=X`，X 是 neuron 编号（0~9 对应数字 0~9） |

### 2.8 稳定性验证

同一组权重和配置，**重跑一次**，确认结果完全一致（spike_id 序列相同、OUT_FIFO_COUNT 相同）。不一致说明有时序竞争或未初始化寄存器。

### 2.9 可选：修改参数看输出变化

```bash
# 降低 threshold，应产生更多 spike
bash run_icarus_weighted.sh +THRESHOLD=1000

# 减少时间步
bash run_icarus_weighted.sh +TIMESTEPS=5

# 强制 zero-spike 判定为 FAIL
bash run_icarus_weighted.sh +FAIL_ON_ZERO_SPIKE=1
```

改 threshold 后 OUT_FIFO_COUNT 应有**合理变化**（降低 threshold → spike 更多，升高 → 更少），这验证了 LIF 的阈值比较逻辑确实在起作用。

---

## 3. Step 3.3 — VCS + Verdi 带权重仿真（学校服务器 Linux）

### 3.1 这一步验证什么

- 与 Step 3.2 相同的带权重仿真，但使用工业级仿真器 VCS
- 启用 **SVA 断言**（`+define+VCS` 宏开启，Icarus 跳过断言）
- 生成 FSDB 波形文件，用 Verdi 做深度波形分析
- 验证目标：**WEIGHTED_SIM_PASS + 零 assertion failure**

### 3.2 文件搬运清单

把以下文件/目录从本机 Windows 搬到服务器（保持目录结构）：

```
SoC Design/
├── rtl/                          # 全部 RTL 源码
├── tb/                           # 全部 testbench
├── sim/                          # 仿真脚本 + filelist + models/
│   ├── run_vcs_weighted.sh
│   ├── run_verdi_weighted.sh
│   ├── sim_icarus_weighted.f     # VCS 也用这个 filelist
│   ├── verdi_weighted.tcl
│   └── models/
│       └── cim_macro_blackbox_weighted_icarus.sv
└── 项目相关文件/器件对齐/Python建模/results/exports/
    ├── weight_pos.hex            # 必须！
    └── weight_neg.hex            # 必须！
```

> 也可以直接把整个项目文件夹全部搬过去，最省心。

### 3.3 服务器上首次运行前的准备

```bash
# 1. 修复 Windows→Linux 行尾问题（CRLF → LF）
cd sim
sed -i 's/\r$//' run_vcs_weighted.sh run_verdi_weighted.sh run_icarus_weighted.sh run_icarus_light.sh

# 2. 加执行权限
chmod +x run_vcs_weighted.sh run_verdi_weighted.sh

# 3. 确认 EDA 环境（应自动加载，如果不行手动 source）
source /home/opt/demo/syn.env
which vcs    # 应输出 /opt/Synopsys/vcs_green/vcs-2021.09-sp2/bin/vcs
which verdi  # 应输出 /opt/Synopsys/verdi_green/verdi-2021.09-sp2/bin/verdi
```

### 3.4 运行 VCS 仿真

```bash
cd sim
bash run_vcs_weighted.sh
```

脚本会自动完成两步：
1. **编译**：`vcs` 编译所有 RTL + TB，输出编译日志到 `sim/vcs_weighted_compile.log`
2. **运行**：执行仿真，输出运行日志到 `sim/vcs_weighted.log`

### 3.5 预期终端输出

与 Step 3.2 相同的 `[INFO]` 打印序列，最终出现 `WEIGHTED_SIM_PASS`。

**额外关注**：编译和运行过程中**不应有任何 assertion failure**。如果有，会看到类似：

```
Error: ... Assertion ... failed at time ...
```

### 3.6 通过标准

1. `WEIGHTED_SIM_PASS` 出现
2. **零 assertion failure**（编译日志 + 运行日志中无 `Error` / `Fatal` / `Assertion failed`）
3. FSDB 波形文件已生成：`sim/waves/snn_soc_weighted.fsdb`

快速检查命令：

```bash
# 检查仿真结果
grep "WEIGHTED_SIM_PASS" sim/vcs_weighted.log

# 检查断言失败
grep -iE "error|fatal|assertion" sim/vcs_weighted_compile.log sim/vcs_weighted.log

# 检查 FSDB 文件存在
ls -lh sim/waves/snn_soc_weighted.fsdb
```

### 3.7 产物文件

| 文件 | 路径 | 说明 |
|------|------|------|
| 编译日志 | `sim/vcs_weighted_compile.log` | VCS 编译输出，检查有无语法错误 |
| 仿真日志 | `sim/vcs_weighted.log` | 运行时输出，检查 PASS/FAIL 和断言 |
| FSDB 波形 | `sim/waves/snn_soc_weighted.fsdb` | Verdi 打开查看 |

### 3.8 用 Verdi 查看波形

```bash
cd sim
bash run_verdi_weighted.sh
```

该脚本会自动加载 `verdi_weighted.tcl`，预配置好以下信号组：

| 信号组 | 包含信号 |
|--------|---------|
| 总线接口 | `dut.bus_if.*` |
| 寄存器组 | `dut.u_reg_bank.*` |
| DMA | `dut.u_dma.*` |
| 输入 FIFO | `dut.u_input_fifo.*` |
| 输出 FIFO | `dut.u_output_fifo.*` |
| CIM 控制 | `dut.u_cim_ctrl.*` |
| DAC | `dut.u_dac.*` |
| CIM 宏 | `dut.u_macro.*` |
| ADC 状态/选择/输出 | `dut.u_adc.state`, `dut.u_adc.bl_sel`, `dut.u_adc.neuron_in_valid`, `dut.u_adc.neuron_in_data` |
| LIF 神经元 | `dut.u_lif.*` |

### 3.9 Verdi 波形逐项检查清单（共 8 项）

信号路径前缀统一为 `top_tb_icarus_weighted.dut`（以下简写为 `dut`）。

---

#### 检查项 1：寄存器初始化

| 信号 | 预期 |
|------|------|
| `dut.u_reg_bank.neuron_threshold` [32-bit] | rst_n 释放后被写为 `32'd2550`（0x9F6），之后保持不变 |
| `dut.u_reg_bank.timesteps` [8-bit] | 被写为 `8'd10`（0x0A），之后保持不变 |
| `dut.u_reg_bank.reset_mode` [1-bit] | 保持 `0`（soft reset） |
| `dut.u_reg_bank.cim_test_mode` [1-bit] | 保持 `0`（关闭 test mode） |
| `dut.bus_if.m_valid` [1-bit] | 每笔总线写操作拉高 1 拍 |
| `dut.bus_if.m_addr` [32-bit] | 依次出现 `0x4000_0004`（TIMESTEPS）、`0x4000_0000`（THRESHOLD）、`0x4000_002C`（CIM_TEST） |
| `dut.bus_if.m_wdata` [32-bit] | 对应出现 `0x0000_000A`、`0x0000_09F6`、`0x0000_0000` |
| `dut.bus_if.m_ready` [1-bit] | 每笔写后 1 周期内拉高，确认总线响应正常 |

---

#### 检查项 2：DMA 数据搬运

| 信号                                 | 预期                                                               |
| ---------------------------------- | ---------------------------------------------------------------- |
| `dut.u_dma.state` [FSM]            | START 后循环：`IDLE → SETUP → RD0 → RD1 → PUSH → RD0 → ...`，最终回 IDLE |
| `dut.u_dma.dma_rd_addr` [32-bit]   | 从 `ADDR_DATA_BASE` 起每次 +4 连续递增                                   |
| `dut.u_dma.dma_rd_data` [32-bit]   | SRAM 读出的像素 bit-plane 数据，不应全 0                                    |
| `dut.u_dma.in_fifo_push` [1-bit]   | 每 2 个 word 读完后拉高 1 拍，共 80 次（10帧×8bp）                             |
| `dut.u_dma.in_fifo_wdata` [64-bit] | `{word1, word0}` 拼接值，即一个 bit-plane 的 64-bit WL bitmap            |
| `dut.u_dma.in_fifo_full` [1-bit]   | 正常应始终为 0（DMA 先灌完再推理）                                             |
| `dut.u_dma.words_rem` [内部]         | 从 160 递减到 0（每次 push 减 2）                                         |
| `dut.u_input_fifo.count` [深度位宽]    | DMA 期间从 0 涨到 80；CIM 推理期间从 80 降回 0（每 pop 一个 bp 减 1） |

---

#### 检查项 3：CIM 控制 FSM

| 信号                                        | 预期                                                                                     |
| ----------------------------------------- | -------------------------------------------------------------------------------------- |
| `dut.u_cim_ctrl.state` [3-bit]            | 每个 bp 循环：`FETCH(1)→DAC(2)→CIM(3)→ADC(4)→INC(5)→FETCH(1)...`；最后一轮 `INC→DONE(6)→IDLE(0)` |
| `dut.u_cim_ctrl.busy` [1-bit]             | start 后拉高，DONE 状态后拉低                                                                   |
| `dut.u_cim_ctrl.bitplane_shift` [3-bit]   | 序列：**7,6,5,4,3,2,1,0** 重复 10 次（MSB 先，每帧 8 个 bp）                                        |
| `dut.u_cim_ctrl.timestep_counter` [8-bit] | 第 1 帧 8 个 bp 期间为 0，第 2 帧为 1，...，第 10 帧为 9                                              |
| `dut.u_cim_ctrl.in_fifo_pop` [1-bit]      | 仅在 FETCH 状态拉高 1 拍，共 80 次                                                               |
| `dut.u_cim_ctrl.wl_valid_pulse` [1-bit]   | 仅在 DAC 状态首拍拉高 1 拍                                                                      |
| `dut.u_cim_ctrl.cim_start_pulse` [1-bit]  | 仅在 CIM 状态首拍拉高 1 拍                                                                      |
| `dut.u_cim_ctrl.adc_kick_pulse` [1-bit]   | 仅在 ADC 状态首拍拉高 1 拍                                                                      |
| `dut.u_cim_ctrl.dac_done_pulse` [1-bit]   | DAC 状态等待期间收到 1 拍，触发 DAC→CIM 跳转                                                         |
| `dut.u_cim_ctrl.cim_done` [1-bit]         | CIM 状态等待期间收到 1 拍，触发 CIM→ADC 跳转                                                         |
| `dut.u_cim_ctrl.neuron_in_valid` [1-bit]  | ADC 状态等待期间收到 1 拍，触发 ADC→INC 跳转                                                         |
| `dut.u_cim_ctrl.done_pulse` [1-bit]       | DONE 状态拉高**恰好 1 拍**，整次推理只出现 1 次                                                        |

---

#### 检查项 4：WL 时分复用

| 信号                                                | 预期                                                        |
| ------------------------------------------------- | --------------------------------------------------------- |
| `dut.u_wl_mux_wrapper.state` [2-bit]              | 每次 wl_valid_pulse_in 后：`IDLE→SEND(持续8拍)→DONE(1拍)→IDLE`    |
| `dut.u_wl_mux_wrapper.wl_buf` [64-bit]            | 收到 pulse 时锁存 wl_bitmap_in 值，SEND 期间保持不变                   |
| `dut.u_wl_mux_wrapper.grp_idx` [3-bit]            | SEND 期间从 0 递增到 7，每拍 +1                                    |
| `dut.u_wl_mux_wrapper.wl_data` [8-bit]            | grp0=wl_buf[7:0]，grp1=wl_buf[15:8]，...，grp7=wl_buf[63:56] |
| `dut.u_wl_mux_wrapper.wl_group_sel` [3-bit]       | 跟随 grp_idx：0,1,2,3,4,5,6,7                                |
| `dut.u_wl_mux_wrapper.wl_latch` [1-bit]           | SEND 期间为 1，IDLE/DONE 期间为 0（组合逻辑）                          |
| `dut.u_wl_mux_wrapper.wl_valid_pulse_out` [1-bit] | DONE 状态拉高 1 拍，转发给 dac_ctrl                                |

---

#### 检查项 5：DAC + CIM 宏

| 信号                                 | 预期                                             |
| ---------------------------------- | ---------------------------------------------- |
| `dut.u_dac.state` [1-bit]          | 收到 pulse 后 `IDLE→LAT`，倒计完 `LAT→IDLE`           |
| `dut.u_dac.wl_reg` [64-bit]        | 在 IDLE 收到 pulse 时锁存，之后保持不变直到下一次 pulse          |
| `dut.u_dac.wl_spike` [64-bit]      | 等于 wl_reg（assign 直连），不应全 0（全 0 说明 bitmap 没传过来） |
| `dut.u_dac.dac_valid` [1-bit]      | 锁存同拍拉高 1 拍                                     |
| `dut.u_dac.lat_cnt` [8-bit]        | 从初值倒数到 0（DAC_LATENCY_CYCLES=0 时只停 1 拍）         |
| `dut.u_dac.dac_done_pulse` [1-bit] | lat_cnt 到 0 时拉高 1 拍                            |
| `dut.u_macro.wl_spike` [64-bit]    | 等于 dac 输出的 wl_spike，CIM 计算期间保持稳定               |
| `dut.u_macro.cim_start` [1-bit]    | cim_array_ctrl 发出的启动脉冲，1 拍                     |
| `dut.u_macro.cim_done` [1-bit]     | 启动后延迟 CIM_LATENCY_CYCLES 拍，拉高 1 拍              |

---

#### 检查项 6：ADC 20 路扫描 + Scheme B 差分

| 信号                                           | 预期                                                              |
| -------------------------------------------- | --------------------------------------------------------------- |
| `dut.u_adc.state` [2-bit]                    | kick 后循环 20 次 `SEL→WAIT`（或直接 WAIT），最后 `DONE→IDLE`               |
| `dut.u_adc.sel_idx` [5-bit]                  | 从 0 递增到 19，共 20 个通道                                             |
| `dut.u_adc.bl_sel` [5-bit]                   | 跟随 sel_idx：0,1,2,...,19                                         |
| `dut.u_adc.adc_start` [1-bit]                | 每个通道拉高 1 拍，共 20 次                                               |
| `dut.u_adc.adc_done` [1-bit]                 | 每次 adc_start 后收到 1 拍回应                                          |
| `dut.u_adc.bl_data` [8-bit]                  | 时分复用单路输出，随 bl_sel 0→19 依次给出每个通道的 ADC 值。波形为一串连续变化的数值，不应全为 0x00（权重无效）或全为 0xFF（ADC 饱和） |
| `dut.u_adc.raw_data` [20×8-bit]              | 20 路采样全部存入后，raw_data[0]~[9] 为 pos，[10]~[19] 为 neg               |
| `dut.u_adc.neuron_in_data` [10×9-bit signed] | `neuron_in_data[i] = raw_data[i] - raw_data[i+10]`；应有正有负，不应全为 0 |
| `dut.u_adc.neuron_in_valid` [1-bit]          | ST_DONE 状态拉高**恰好 1 拍**                                          |
| `dut.u_adc.adc_sat_high` [16-bit]            | 正常推理应接近 0（bl_data=0xFF 的次数）                                     |
| `dut.u_adc.adc_sat_low` [16-bit]             | 正常推理应接近 0（bl_data=0x00 的次数）                                     |

---

#### 检查项 7：LIF 膜电位 + spike

| 信号 | 预期 |
|------|------|
| `dut.u_lif.membrane[0]` ~ `dut.u_lif.membrane[9]` [32-bit signed] | 每次 neuron_in_valid 时更新：`membrane += neuron_in_data[i] <<< bitplane_shift`。波形呈**阶梯状**：bitplane_shift=7（MSB）跳最大，=0（LSB）跳最小。同一 timestep 内 8 步增量比例约 128:64:32:16:8:4:2:1。超过 2550 时 spike，soft reset 后 membrane 降回一个小正值继续累加 |
| `dut.u_lif.neuron_in_valid` [1-bit] | 与 u_adc 输出一致，每轮 ADC 完成后 1 拍 |
| `dut.u_lif.bitplane_shift` [3-bit] | 跟随 cim_ctrl：7,6,5,...,0 重复 10 次 |
| `dut.u_lif.threshold` [32-bit] | 整个仿真保持 `32'd2550` 不变 |
| `dut.u_lif.reset_mode` [1-bit] | 整个仿真保持 `0`（soft） |
| `dut.u_lif.out_fifo_push` [1-bit] | spike 发生后拉高 1 拍（内部队列每拍最多 pop 1 个到 FIFO） |
| `dut.u_lif.out_fifo_wdata` [4-bit] | spike 的 neuron id，范围 0~9 |
| `dut.u_lif.q_count` [内部] | 瞬时 spike 缓存深度，正常应很快清空 |
| `dut.u_lif.queue_overflow` [1-bit] | 必须始终为 0（队列深度 32，单拍最多 10 个 spike） |

10 个 neuron 的 membrane 不应完全相同（否则说明权重没有分化）。membrane 不应出现很大负值（否则有符号溢出）。

---

#### 检查项 8：输出 FIFO 最终结果

| 信号                                    | 预期                                                |
| ------------------------------------- | ------------------------------------------------- |
| `dut.u_output_fifo.push` [1-bit]      | 推理期间每个 spike 拉高 1 拍                               |
| `dut.u_output_fifo.push_data` [4-bit] | 范围 0~9，不应出现 >9 的值                                 |
| `dut.u_output_fifo.count` [深度位宽]      | 推理期间从 0 逐渐增长（spike 不断 push）；推理完成后 TB 逐个 pop 读取，count 降回 0。峰值 = 终端打印的 `OUT_FIFO_COUNT` |
| `dut.u_output_fifo.pop` [1-bit]       | 推理完成后 TB 逐个读取时拉高                                  |
| `dut.u_output_fifo.rd_data` [4-bit]   | FIFO 空时为不定态（X）；有数据后显示队头 neuron id；TB pop 时依次读出的序列 = 终端打印的 `spike_id[0], spike_id[1], ...`；pop 完后回到不定态 |
| `dut.u_output_fifo.empty` [1-bit]     | 仿真开始时为 1（空）；第一个 spike push 后变 0；TB pop 完所有结果后回到 1 |
| `dut.u_output_fifo.full` [1-bit]      | 整个仿真保持 0（深度 4096）                                 |
| `dut.u_output_fifo.overflow` [1-bit]  | 整个仿真保持 0                                          |

---

## 4. Step 3.4 — Python↔RTL 样本对齐（本机 Windows）

### 4.1 这一步验证什么

- 使用 Python 导出的**正式样本集**而不是十字图样，验证 RTL 推理结果与 Python 建模的 `predicted_class` 一致。
- 覆盖完整带权重路径：`data_sram -> DMA -> CIM weighted model -> ADC diff -> LIF -> output_fifo`。
- 这是进入 tapeout 前数值一致性检查的关键门禁，不再只看“链路通不通”，而是看“分类结果是否与软件参考口径一致”。

### 4.2 前置条件

需要同时具备两类导出物：

- 权重：`weight_pos.hex` / `weight_neg.hex`
- 样本：`all_samples.hex` / `expected_classes.hex`

脚本默认自动发现规则：

1. 若设置了 `WEIGHT_SRC_DIR` / `STIMULUS_DIR`，优先使用显式目录。
2. 否则在仓库内自动搜索任意 `results/exports/` 与 `rtl_stimulus/` 目录，并优先跳过 `backups/`。
3. 若样本或权重被临时复制到 `sim/`，脚本也会接受当前目录下的同名文件。

### 4.3 运行命令

```bash
cd sim
bash run_sample_align.sh
```

调试时可缩小样本数：

```bash
cd sim
bash run_sample_align.sh +SAMPLE_COUNT=8
```

若需要显式指定资源目录：

```bash
cd sim
WEIGHT_SRC_DIR="../项目相关文件/器件对齐/Python建模/results/exports" \
STIMULUS_DIR="../项目相关文件/器件对齐/Python建模/results/exports/rtl_stimulus" \
bash run_sample_align.sh
```

### 4.4 预期输出与通过标准

正常通过时，日志会逐样本打印：

- `expected_python_class=<n>`
- `OUT_FIFO_COUNT=<m>`
- `PASS (predicted=<x> expected=<x>)`

最终必须看到：

```text
SAMPLE_ALIGN_PASS (100/100 samples matched)
```

通过标准：

1. `SAMPLE_ALIGN_PASS` 出现
2. 默认正式语料下为 `100/100`
3. 无任何 `[FAIL]` 或 `[ERR]` 打印
4. 若只跑子集调试，子集内所有样本也必须全部匹配

### 4.5 常见问题

| 症状 | 可能原因 | 排查方法 |
|------|---------|---------|
| `weight_pos.hex / weight_neg.hex not found` | 权重目录未被自动扫描到 | 手动设 `WEIGHT_SRC_DIR=<路径>` |
| `Stimulus files not found` | `rtl_stimulus/` 导出物不存在或目录不对 | 先重新导出样本，再设 `STIMULUS_DIR=<路径>` |
| `all_samples.hex has only ... planes` | 样本平面数与 `expected_classes.hex` 不匹配 | 检查 Python 导出脚本是否完整跑完 |
| 子集能过、100 样本不过 | 个别样本数值口径漂移 | 先用 `+SAMPLE_COUNT=<n>` 缩小范围，再对照 Python 端对应样本日志 |

## 5. SVA 断言说明

项目中在两个模块埋入了 SVA 断言，用 `` `ifdef VCS `` 保护，仅在 VCS 仿真时启用：

### cim_array_ctrl.sv 断言（P1~P6）

| 断言 | 检查内容 |
|------|---------|
| P1 | IDLE 时 FSM 输出信号应全为 0 |
| P2 | bitplane_shift 初始值正确 |
| P3 | WL 有效脉冲只在正确状态发出 |
| P4 | ADC enable 只在正确状态发出 |
| P5 | 状态转换不出现非法状态 |
| P6 | DONE 标志在正确时刻拉起 |

### dma_engine.sv 断言（B1~B5）

| 断言 | 检查内容 |
|------|---------|
| B1 | IDLE 时 FIFO push 不被意外触发 |
| B2 | DMA 传输长度与配置一致 |
| B3 | BUSY 和 DONE 不同时拉高 |
| B4 | 地址递增正确 |
| B5 | 传输完成时 DONE 正确拉起 |

> Icarus 用 `-gno-assertions` 跳过这些断言（Icarus 不完整支持 `$past` 等 SVA 语法），所以只有 VCS 才能验证断言。

---

## 6. 故障排查指南

### 6.1 通用问题

| 症状 | 可能原因 | 排查方法 |
|------|---------|---------|
| 脚本报 `command not found: iverilog` | 本机未安装 Icarus | Windows 上安装 Icarus Verilog 并加入 PATH |
| 脚本报 `command not found: vcs` | 服务器 EDA 环境未加载 | `source /home/opt/demo/syn.env` |
| 编译错误 `unknown module type: snn_soc_top` | filelist 路径错误 | 检查 `sim_icarus_light.f` 或 `sim_icarus_weighted.f` 内的相对路径 |
| VCS 编译报 `Syntax error` | CRLF 行尾问题 | `sed -i 's/\r$//' sim/*.sh sim/*.f` |

### 6.2 黑盒 smoke 失败

| 症状 | 可能原因 | 排查方法 |
|------|---------|---------|
| `DMA done not observed` | DMA FSM 卡住 | 看波形 `dut.u_dma.*`，检查 SRAM 地址是否正确 |
| `CIM done not observed` | CIM FSM 无限循环 | 看波形 `dut.u_cim_ctrl.*`，检查 input_fifo 是否有数据 |
| `OUT_FIFO_COUNT mismatch` | threshold 太高或数据错误 | 看波形 LIF membrane 是否在增长但未超过 threshold |
| `OUT_FIFO_COUNT=0` | test mode 数据未进入链路 | 检查 `REG_CIM_TEST` 配置是否正确 |

### 6.3 带权重 smoke 失败

| 症状 | 可能原因 | 排查方法 |
|------|---------|---------|
| `weight_pos.hex / weight_neg.hex not found` | hex 文件不在查找路径上 | 手动设 `WEIGHT_SRC_DIR=<路径>` |
| `WEIGHTED_SIM_PASS` 但 `OUT_FIFO_COUNT=0` | 权重太小导致 membrane 永远不到 threshold | 降低 THRESHOLD 重跑验证，或检查 hex 内容 |
| spike_id 全相同 | 权重可能只有一个 neuron 有效 | 检查 weight hex 是否 10 列都有非零值 |
| 重跑结果不一致 | 存在时序竞争 | 检查是否有未初始化的 reg |

### 6.4 VCS 特有问题

| 症状 | 可能原因 | 排查方法 |
|------|---------|---------|
| Assertion failure | RTL 逻辑 bug | 看断言名称和触发时刻，对照上面的断言表 |
| FSDB 文件为 0 字节 | Verdi PLI 链接失败 | 检查 `$VERDI_HOME/share/PLI/VCS/LINUX64/pli.a` 是否存在 |
| `VERDI_HOME not found` | 路径配置错误 | 确认 `/opt/Synopsys/verdi_green/verdi-2021.09-sp2` 存在 |

---

## 7. 最小通过标准汇总

| 阶段 | 通过标准 | 工具 | 环境 |
|------|---------|------|------|
| Step 3.1 黑盒 | `LIGHT_SMOKETEST_PASS` + `OUT_FIFO_COUNT=100` + 无 `[ERR]` + 波形检查关键信号正常 | Icarus + GTKWave | 本机 Windows |
| Step 3.2 带权重 | `WEIGHTED_SIM_PASS` + `OUT_FIFO_COUNT > 0` + 改 threshold 后输出合理变化 + 重跑结果稳定 + 波形检查权重/diff/membrane 正常 | Icarus + GTKWave | 本机 Windows |
| Step 3.3 VCS | `WEIGHTED_SIM_PASS` + 零 assertion failure + FSDB 已生成 + Verdi 波形 5 项检查全过 | VCS + Verdi | 学校服务器 |

**三步全过后，才能进入 Step 3.4（Python↔RTL 数值对齐）。**

---

## 8. 快速参考命令

```bash
# === 本机 Windows（Git Bash / MSYS2）===

# Step 3.1 黑盒
cd sim && bash run_icarus_light.sh

# Step 3.1 黑盒 + 保留波形（手动跑）
cd sim
iverilog -g2012 -gno-assertions -f sim_icarus_light.f -s top_tb_icarus_light -o light.out
vvp light.out +EXPECTED_OUT_COUNT=100 +CHECK_OUT_COUNT=1
gtkwave waves/icarus_light.vcd

# Step 3.2 带权重
cd sim && bash run_icarus_weighted.sh
gtkwave waves/icarus_weighted.vcd

# === 学校服务器 Linux ===

# 首次准备
cd sim && sed -i 's/\r$//' *.sh *.f

# Step 3.3 VCS 仿真
cd sim && bash run_vcs_weighted.sh

# Step 3.3 Verdi 看波形
cd sim && bash run_verdi_weighted.sh

# 快速检查通过状态
grep "WEIGHTED_SIM_PASS" sim/vcs_weighted.log
grep -iE "error|fatal|assertion" sim/vcs_weighted_compile.log sim/vcs_weighted.log
```

---

## 9. E203 V1 最小接入的验证标准补充

对于本轮 **最小面积 E203 接入**，当前判断是：**Icarus 验证已足够，暂不要求额外跑 VCS/Verdi**。

适用范围：

- 关闭 `cache / ITCM / DTCM / JTAG / NICE / ECC / AMO / share-muldiv`
- 覆盖 `RV32I + mem_icb + MMIO + SPI boot + DMA/SNN` 的最小 bare-metal 启动链
- 固件通过 WSL 中的 `riscv64-unknown-elf-gcc / objcopy` 构建，`sim/run_e203_icarus.sh` 会先生成 `bootloader.hex` 与 `flash_image.hex` 再跑仿真；为缩短 Icarus 时间，脚本构建时默认临时覆盖 `UART_BAUD_DIV=2u`
- 不涉及 Debug Module / JTAG 单步
- 不做大规模 ISA regression，也不做复杂 assertion 收敛

本轮通过标准：

- `E203_SMOKETEST_PASS`
- 固件能完成：bootloader 上电启动、SPI 读取 app、跳转执行、UART 打印阶段日志、启动 DMA/SNN，并将 `OUT_FIFO_COUNT` 写回 SRAM
- 主线回归保持通过：`LIGHT_SMOKETEST_PASS`、`WEIGHTED_SIM_PASS`

只有在进入下面这些阶段时，才建议把 VCS/Verdi 纳入必跑项：

- 引入更复杂的 boot image 校验、异常恢复或更长固件流程
- 打开 Debug/JTAG 路径
- 做 ISA regression、异常/中断覆盖或更深的 SVA 调试
- 需要用 FSDB/Verdi 追复杂软硬件交互时序
