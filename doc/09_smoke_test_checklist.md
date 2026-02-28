# Smoke Test 清单

## 0. 执行边界（2026-02-27 更新）

- 本清单的“完整 smoke test”默认环境是 **Linux + VCS + Verdi**。
- 脚本入口已统一为：
  - `sim/run_vcs.sh`：编译并运行仿真（产出 `sim.log`、`vcs.log`、`waves/snn_soc.fsdb`）
  - `sim/run_verdi.sh`：打开波形
- 运行前建议只做最小环境设置（避免脚本内硬编码）：
  - `export VCS_HOME=/path/to/vcs`
  - `export VERDI_HOME=/path/to/verdi`
  - 可选：`export SYN_ENV_FILE=/path/to/syn.env`（如你们组有统一环境脚本）

### 0.1 无 VCS 环境的替代检查（本地）

若本机暂时没有 VCS，可先执行静态可编译性检查：

```bash
verilator --lint-only -Wall -f sim/sim.f
verilator --lint-only -Wall -f sim/rtl_with_chip_top_check.f
```

> 说明：这不是完整 smoke test，但可快速确认 RTL/顶层集成无语法和大多数连线错误；完整流程仍需在 VCS 环境跑通。

### 0.2 Icarus 本地轻量 Smoke Test（已验证通过，2026-02-27）

> **前置条件**：安装 `iverilog`（`apt install iverilog` 或 `brew install icarus-verilog`）。

**运行方法**（在项目根目录或 `sim/` 目录均可）：

```bash
cd sim
bash run_icarus_light.sh
```

**预期输出**：

```
[INFO] Icarus light smoke test start
[INFO] DMA done after N polls, DMA_CTRL=0x00000002
[INFO] CIM done after N polls, CIM_CTRL=0x00000080
[INFO] OUT_FIFO_COUNT=0xXXXXXXXX (N)
LIGHT_SMOKETEST_PASS
```

**OUT_FIFO_COUNT 说明**：
- 当前轻量测试已按定版参数跑 `TIMESTEPS=10`（不再是早期 `T=1`）
- 通过标准是：`LIGHT_SMOKETEST_PASS` 且 DMA/CIM DONE 位按预期置位
- `OUT_FIFO_COUNT` 属于业务数据结果，允许随输入激励变化；通常为非零（当前回归样例为 20）
- 测试意图：验证**端到端数字链路**（DMA → FIFO → FSM → ADC → LIF → output_fifo）可稳定运行

**波形分析**：运行后产生 `sim/waves/icarus_light.vcd`，可用任意 VCD 查看器（GTKWave 等）打开：

```bash
gtkwave sim/waves/icarus_light.vcd &
```

本文档提供在 Linux 服务器上运行仿真的完整检查清单。

---

## 前置条件检查

### 1. 环境变量检查

```bash
# 检查 VCS 环境
which vcs
echo $VCS_HOME

# 检查 Verdi 环境
which verdi
echo $VERDI_HOME

# 如果未设置，需要 source 环境脚本
# 示例（根据实际安装路径调整）：
# export VCS_HOME=/opt/Synopsys/vcs/vcs-2021.09-sp2
# export VERDI_HOME=/opt/Synopsys/verdi/verdi-2021.09-sp2
# export PATH=$VCS_HOME/bin:$VERDI_HOME/bin:$PATH
```

### 2. 文件完整性检查

```bash
cd /path/to/SoC-Design

# 检查关键目录存在
ls -la rtl/
ls -la tb/
ls -la sim/

# 检查 sim.f 文件存在
cat sim/sim.f

# 检查脚本可执行权限
ls -la sim/*.sh
```

---

## Smoke Test 步骤

### Step 1: 编译仿真

```bash
cd sim

# 确保 waves 目录存在
mkdir -p waves

# 运行 VCS 编译
./run_vcs.sh
```

**检查点 1.1**：编译日志
```bash
# 检查 vcs.log 无 Error
grep -i "error" vcs.log

# 预期结果：无真正的报错。注意日志里可能包含库名（如 -lerrorinf），不代表错误。
```

**检查点 1.2**：simv 可执行文件
```bash
ls -la simv

# 预期结果：simv 文件存在且有执行权限
```

### Step 2: 运行仿真

```bash
# 如果 run_vcs.sh 已包含运行步骤，则跳过
# 否则手动运行：
./simv -l sim.log
```

**检查点 2.1**：仿真完成
```bash
# 检查仿真是否正常结束
grep "Simulation finished" sim.log

# 预期结果：
# [TB] Simulation finished.
```

**检查点 2.2**：输出 FIFO 有数据
```bash
grep "OUT_FIFO_COUNT" sim.log

# 预期结果：
# [TB] OUT_FIFO_COUNT = N  (N 随输入激励变化；若多次回归长期为 0，参考“问题 3”排查)
```

**检查点 2.3**：无致命错误
```bash

grep -i "fatal\|error" sim.log

# 预期结果：无输出
```

### Step 3: 检查波形文件

```bash
ls -la waves/snn_soc.fsdb

# 预期结果：文件存在，大小 > 1MB
```

### Step 4: 打开 Verdi 查看波形

```bash
./run_verdi.sh

# 或手动：
verdi -ssf waves/snn_soc.fsdb &
```

---

## 关键波形检查点

在 Verdi 中添加以下信号进行观察：

### 4.1 时钟和复位

| 信号 | 预期行为 |
|------|----------|
| `top_tb.clk` | 50MHz 方波 |
| `top_tb.rst_n` | 初始低，几个周期后拉高 |

### 4.2 DMA 状态机

| 信号 | 预期行为 |
|------|----------|
| `u_dma.state` | IDLE → SETUP → RD0 → RD1 → PUSH → ... → IDLE |
| `u_dma.done_sticky` | DMA 完成后保持为1，直到软件W1C清零 |
| `u_dma.err_sticky` | DMA 发生错误时置1（奇数长度、地址越界等）|

### 4.3 CIM 控制状态机

| 信号                            | 预期行为                                              |
| ----------------------------- | ------------------------------------------------- |
| `u_cim_ctrl.state`            | IDLE → FETCH → DAC → CIM → ADC → INC → ... → DONE |
| `u_cim_ctrl.bitplane_shift`   | 7 → 6 → 5 → 4 → 3 → 2 → 1 → 0 → 7 → ...           |
| `u_cim_ctrl.timestep_counter` | 0 → 1 → 2 → ... → TIMESTEPS-1                     |

### 4.4 ADC 时分复用

| 信号 | 预期行为 |
|------|----------|
| `u_adc.bl_sel` | 0 → 1 → 2 → ... → 19 → 0 → ...（Scheme B：20 通道） |
| `u_adc.neuron_in_valid` | 每完成 20 个通道采样并执行差分减法后产生单拍脉冲 |

### 4.5 LIF 神经元

| 信号                    | 预期行为                   |
| --------------------- | ---------------------- |
| `u_lif.membrane[0]`   | 逐步累加，超过阈值后复位           |
| `u_lif.out_fifo_push` | spike 产生时拉高，将 spike 写入 FIFO |

### 4.6 输出 FIFO

| 信号 | 预期行为 |
|------|----------|
| `u_output_fifo.count` | 有 spike 时从 0 逐步增加；若无 spike 可保持 0 |

---

## 常见问题排查

### 问题 1：vcs.log 报 PLI 路径错误

```
错误信息：cannot find pli.a 或 novas.tab

解决方法：
1. 检查 VERDI_HOME 环境变量
2. 修改 run_vcs.sh 中的 PLI 路径
3. 常见路径：
   $VERDI_HOME/share/PLI/VCS/LINUX64/novas.tab
   $VERDI_HOME/share/PLI/VCS/LINUX64/pli.a
```

### 问题 2：仿真卡死不结束

```
可能原因：
1. FIFO 满阻塞
2. 状态机卡死在某个状态
3. 握手信号错配

排查方法：
1. 添加超时保护：#10000000 $finish;
2. 在 Verdi 中观察各模块 state 信号
3. 检查最后一个活动时刻的状态
```

### 问题 3：OUT_FIFO_COUNT 多次回归长期为 0

```
可能原因：
1. 阈值设置过高，没有 spike 产生
2. TIMESTEPS 设置过小
3. DMA 数据未正确加载

排查方法：
1. 检查 THRESHOLD 寄存器值
2. 检查 input_fifo 是否有数据
3. 观察 LIF membrane 是否在累加
```

### 问题 4：波形文件为空或很小

```
可能原因：
1. 仿真提前终止
2. FSDB dump 语句未执行

排查方法：
1. 检查 sim.log 是否有 $finish 提前调用
2. 确认 $fsdbDumpfile 在复位后执行
```

---

## 完整 Smoke Test 脚本

将以下内容保存为 `sim/smoke_test.sh`：

```bash
#!/usr/bin/env bash
set -e

echo "========== SNN SoC Smoke Test =========="
echo "开始时间: $(date)"

cd "$(dirname "$0")"

# Step 1: 环境检查
echo ""
echo "[Step 1] 环境检查..."
if [ -z "$VCS_HOME" ]; then
    echo "ERROR: VCS_HOME 未设置"
    exit 1
fi
if [ -z "$VERDI_HOME" ]; then
    echo "ERROR: VERDI_HOME 未设置"
    exit 1
fi
echo "VCS_HOME = $VCS_HOME"
echo "VERDI_HOME = $VERDI_HOME"

# Step 2: 编译
echo ""
echo "[Step 2] VCS 编译..."
mkdir -p waves

vcs -full64 -sverilog -timescale=1ns/1ps -f sim.f -o simv \
    -debug_access+all -kdb \
    -P "$VERDI_HOME/share/PLI/VCS/LINUX64/novas.tab" \
       "$VERDI_HOME/share/PLI/VCS/LINUX64/pli.a" \
    -l vcs.log 2>&1

if [ ! -f simv ]; then
    echo "ERROR: simv 生成失败"
    exit 1
fi
echo "编译成功！"

# Step 3: 运行仿真
echo ""
echo "[Step 3] 运行仿真..."
./simv -l sim.log

# Step 4: 检查结果
echo ""
echo "[Step 4] 检查结果..."

# 检查仿真完成
if grep -q "Simulation finished" sim.log; then
    echo "✓ 仿真正常完成"
else
    echo "✗ 仿真未正常完成"
    exit 1
fi

# 检查输出
if grep -q "OUT_FIFO_COUNT = [1-9]" sim.log; then
    echo "✓ 有 spike 输出"
else
    echo "⚠ 无 spike 输出（可能阈值过高）"
fi

# 检查波形文件
if [ -f waves/snn_soc.fsdb ]; then
    size=$(stat -c %s waves/snn_soc.fsdb 2>/dev/null || stat -f %z waves/snn_soc.fsdb)
    if [ "$size" -gt 1000000 ]; then
        echo "✓ 波形文件正常 ($(( size / 1024 / 1024 )) MB)"
    else
        echo "⚠ 波形文件较小 ($size bytes)"
    fi
else
    echo "✗ 波形文件未生成"
    exit 1
fi

# 检查错误
if grep -qi "fatal\|error" sim.log; then
    echo "⚠ 发现错误信息，请检查 sim.log"
else
    echo "✓ 无致命错误"
fi

echo ""
echo "========== Smoke Test 完成 =========="
echo "结束时间: $(date)"
echo ""
echo "下一步："
echo "  运行 ./run_verdi.sh 查看波形"
```

---

## 快速验收标准

| 检查项 | 通过标准 |
|--------|----------|
| VCS 编译 | vcs.log 无 Error |
| simv 生成 | 文件存在且可执行 |
| 仿真完成 | sim.log 包含 "Simulation finished" |
| Spike 输出 | OUT_FIFO_COUNT 为业务结果（当前样例约 20）；若多次回归长期为 0，参考“问题 3”排查 |
| 波形文件 | snn_soc.fsdb > 1MB |
| 状态机流转 | 可在 Verdi 中观察到完整状态转换 |

---

*最后更新：2026-02-27（新增 §0.2 Icarus 本地轻量 smoke test，已实跑通过）*
