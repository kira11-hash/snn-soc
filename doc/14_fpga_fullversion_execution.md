# 14_fpga_fullversion_execution.md
# FPGA Full-Version SNN SoC 完整实施文档

> 分支：`fpga-fullversion-snnsoc`
> 目标板：ZCU102（XCZU9EG-2FFVB1156E）
> 目标：2 个月内投出 SCI 论文

---

## 目录

1. [背景与策略](#1-背景与策略)
2. [完整实施计划](#2-完整实施计划)
3. [已完成工作（Phase 0-3）](#3-已完成工作phase-0-3)
4. [Vivado 综合详细流程](#4-vivado-综合详细流程)
5. [板上 Bringup 详细流程](#5-板上-bringup-详细流程)
6. [批量测试与论文数据收集](#6-批量测试与论文数据收集)
7. [论文素材清单](#7-论文素材清单)
8. [关键文件索引](#8-关键文件索引)
9. [CPU 接入双线路径规划](#9-cpu-接入双线路径规划)

---

## 1. 背景与策略

### 1.1 为什么做 FPGA 版本

RRAM CIM 宏无法在 FPGA 上实现，但数字控制链路（AXI、DMA、LIF、寄存器）可以完整跑在 FPGA 上。替换策略：

```
ASIC 主线                     FPGA 分支
─────────────────────────────────────────────────────
cim_macro_blackbox (RRAM 行为模型)
          ↓                        ↓
    流片后替换为真实 RRAM    cim_fpga_model.sv（BRAM权重+数字MAC）
```

FPGA 验证的意义：
- 端到端推理跑通（bus → DMA → CIM → LIF → spike 全链路）
- 精度验证：FPGA 结果 vs Python golden 对比
- 资源/功耗报告：LUT/BRAM/DSP/power（直接写进论文）
- 器件非理想仿真：注入 D2D/C2C 扰动做 robustness 曲线（SCI 加分项）

### 1.2 GPT/本文采用的工程策略

> **先做"差不多但可靠"的基线，再做 1-2 个"可讲故事"的优化点，不做极致算子优化。**

停线标准（满足三条即可投稿）：
1. 功能全通过（现有仿真回归全绿）
2. FPGA 时序 clean（无 negative slack），资源不过载（<5%）
3. 有"基线 vs 优化"对比数据图

---

## 2. 完整实施计划

| Phase | 内容 | 预估时间 | 依赖 |
|-------|------|----------|------|
| 0 | 分支创建 + feature 合并 | 30 min | 无 |
| 1 | CIM FPGA 模型 + 权重导出 + 单元测试 | 2-3 天 | Phase 0 |
| 2 | 系统集成到 snn_soc_top + Icarus 验证 | 1-2 天 | Phase 1 |
| 3 | 板级 wrapper + 约束 + Vivado 脚本 | 2-3 天 | Phase 2 |
| 4 | **真实权重导出（Linux 服务器）** | 1 天 | Phase 1 |
| 5 | **Vivado 综合 + bitstream 生成** | 1-2 天 | Phase 3+4 |
| 6 | **板上 bringup（ZCU102）** | 2-3 天 | Phase 5 |
| 7 | **批量测试 + 数据收集** | 3-5 天 | Phase 6 |
| 8 | 论文撰写 | 与 7 并行 | Phase 7 |
| **总计** | | **~2-3 周** | |

---

## 3. 已完成工作（Phase 0-3）

### Phase 0: 分支创建与合并 ✅

```bash
git checkout -b fpga-fullversion-snnsoc main
git merge feature/axi-lite --no-edit   # AXI-Lite 桥（PS-PL 通信）
git merge feature/uart-tx --no-edit    # UART TX（调试输出）
git merge feature/spi --no-edit        # SPI Master（外接 Flash 可选）
# 验证：
cd sim && bash run_icarus_light.sh     # LIGHT_SMOKETEST_PASS ✅
```

### Phase 1: CIM FPGA 模型 ✅

已创建文件：

| 文件 | 内容 |
|------|------|
| `fpga/cim_model/cim_fpga_model.sv` | 核心：BRAM权重 + 1-bit×4-bit MAC，接口与 blackbox 100% 兼容 |
| `fpga/cim_model/weight_pos.hex` | 正列权重（当前为测试用结构化权重，需替换为真实训练权重） |
| `fpga/cim_model/weight_neg.hex` | 负列权重 |
| `fpga/cim_model/test_image.hex` | 测试图片 bit-plane 编码（24 行 = T=3 × 8 bit-planes） |
| `fpga/cim_model/test_golden.txt` | 预期膜电位和 spike 结果 |
| `fpga/scripts/gen_test_weights.py` | 生成确定性测试权重（纯 Python，无依赖） |
| `fpga/scripts/export_weights.py` | PyTorch 真实权重导出（需在 Linux 服务器运行） |
| `fpga/sim/tb_cim_fpga.sv` | CIM 单元测试（5 个测试用例） |
| `fpga/sim/run_cim_fpga_test.sh` | 运行单元测试（Icarus） |

单元测试结果：`CIM_FPGA_UNIT_PASS (5/5)` ✅

### Phase 2: 系统集成 ✅

- `snn_soc_top.sv` 中 `cim_macro_blackbox` → `cim_fpga_model` 已替换
- `sim/sim_icarus_light.f` 已更新文件列表
- 端到端验证：`LIGHT_SMOKETEST_PASS`（OUT_FIFO_COUNT=42）✅

### Phase 3: 板级 Wrapper ✅

| 文件 | 内容 |
|------|------|
| `fpga/boards/zcu102/top_fpga.sv` | MMCM (300MHz→50MHz) + 复位同步 + LED + UART |
| `fpga/boards/zcu102/constraints.xdc` | ZCU102 引脚约束（时钟、复位、UART、LED、SPI） |
| `fpga/boards/zcu102/build.tcl` | Vivado 非工程模式自动化脚本 |

---

## 4. Vivado 综合详细流程

### 4.1 前提条件

- Vivado 2022.2 或更高版本（支持 Zynq UltraScale+）
- ZCU102 板型支持包已安装
- **真实权重 .hex 文件已生成**（见第 4.0 节）

### 4.0 先做真实权重导出（在 Linux 服务器上）

```bash
# 进入 Python 建模目录
cd "SoC Design/SoC Design/项目相关文件/器件对齐/Python建模"

# 激活你的 Python 环境（conda 或 venv）
conda activate snn_env   # 或 source .venv/bin/activate

# 运行权重导出脚本
python "../../fpga/scripts/export_weights.py" \
  --method proj_sup_64 \
  --out-dir "../../fpga/cim_model"

# 如果器件模型可用，会自动使用器件感知量化
# 否则回退到均匀量化（精度略有差异，但 RTL 可以跑通）

# 可选：同时导出一张测试图
python "../../fpga/scripts/export_weights.py" \
  --method proj_sup_64 \
  --out-dir "../../fpga/cim_model" \
  --export-image

# 检查输出
ls ../../fpga/cim_model/
# 应该有: weight_pos.hex weight_neg.hex (可选: test_image.hex)
```

> **注意**：权重文件格式是每行一个 16 进制数字（4-bit），共 640 行（64 rows × 10 cols）。
> $readmemh 读取顺序：weight[row=0][col=0], weight[0][1], ..., weight[0][9], weight[1][0], ...

将生成的 .hex 文件同步回 Windows（或在 Git 中提交）：

```bash
git add fpga/cim_model/weight_pos.hex fpga/cim_model/weight_neg.hex
git commit -m "feat(fpga): add real trained weights (.hex)"
git push origin fpga-fullversion-snnsoc
```

### 4.2 运行 Vivado 综合

#### 方法 A：命令行（推荐，可重复，适合服务器）

```bash
# 进入项目根目录
cd "SoC Design/SoC Design"

# 非交互式批处理模式
vivado -mode batch -source fpga/boards/zcu102/build.tcl 2>&1 | tee vivado_build.log

# 查看关键结果
grep -E "(Timing|WNS|LUT|BRAM|DSP|WARNING|ERROR)" vivado_build.log
```

#### 方法 B：Vivado GUI（调试阶段更方便）

```tcl
# 在 Vivado Tcl Console 中执行
source D:/SoC_Design/SoC_Design/fpga/boards/zcu102/build.tcl
```

### 4.3 综合过程各步骤说明

**build.tcl 做了什么**：

```
1. read_verilog (所有 RTL + cim_fpga_model + top_fpga)
2. read_xdc (引脚约束 + 时序约束)
3. synth_design -top top_fpga -part xczu9eg-...
4. 输出 post_synth_utilization.rpt
5. opt_design → place_design → phys_opt_design → route_design
6. 输出 post_impl_utilization.rpt, timing.rpt, power.rpt
7. write_bitstream → snn_soc_fpga.bit
```

所有输出在 `fpga/boards/zcu102/output/` 目录下。

### 4.4 综合报告解读

综合完成后检查这几个报告：

**资源利用率** (`post_impl_utilization.rpt`)：

```
预期值（目标：全部 <5% ZCU102）
  LUT:    3000-5000 / 274080 = ~1-2%
  FF:     2000-4000 / 548160 = ~1%
  BRAM18: 20-30     / 1824   = ~1-2%
  DSP:    0         / 2520   = 0%（1-bit MAC 用 LUT 不用 DSP）
```

**时序报告** (`post_impl_timing.rpt`)：

```
关键路径：cim_fpga_model 的组合累加逻辑（64×20 MAC tree）
目标：WNS ≥ 0（无 negative slack）
如果 WNS < 0：说明 50MHz 时序紧，可以尝试：
  1. 添加流水线寄存器（在 MAC 中间加一级 reg）
  2. 降低时钟频率（改为 25MHz，latency 加倍但 timing 更容易过）
  3. Vivado 自动约束松弛：set_multicycle_path 对 CIM 路径
```

**功耗报告** (`post_impl_power.rpt`)：

```
关注：
  Total On-Chip Power
  Dynamic Power（主要来自时钟网络和逻辑翻转）
  Static Power（漏电流）
这些数据直接写进论文的表格。
```

### 4.5 常见综合错误处理

| 错误 | 原因 | 解决 |
|------|------|------|
| `MMCM not found` | MMCME4_ADV 原语需要 UltraScale+ | 确认 part 是 xczu9eg（不是 xc7xxx） |
| `$readmemh: file not found` | .hex 文件路径问题 | build.tcl 会先 copy hex 到 output/，确认 copy 成功 |
| `Multiple drivers` | 某信号被两个地方驱动 | 检查 snn_soc_top 中 CIM 信号的 MUX 逻辑 |
| `Timing not met (WNS<0)` | MAC 树组合延迟太大 | 见 4.4 时序处理方法 |
| `BRAM inference failed` | sram_simple.sv 未被推断为 BRAM | 手动加 RAM_STYLE attribute 或用 XPM_MEMORY |

### 4.6 BRAM 推断帮助（如果 SRAM 未被自动推断）

如果 Vivado 没有自动把 `sram_simple.sv` 映射为 BRAM，在 RTL 中加一行注释即可：

```systemverilog
// 在 sram_simple.sv 的 mem 数组声明前加：
(* ram_style = "block" *) logic [31:0] mem [0:4095];
```

---

## 5. 板上 Bringup 详细流程

### 5.1 硬件准备

```
必需：
  - ZCU102 开发板 + 电源
  - USB-UART 转换器（接 PMOD J55）
  - JTAG/USB 下载线（ZCU102 板载，接 PC USB）

可选（调试用）：
  - 示波器（看 WL/BL 信号时序）
  - 逻辑分析仪
```

### 5.2 软件环境

```bash
# 串口工具（任选一）
pip install pyserial         # Python 串口
# 或使用 minicom / PuTTY / MobaXterm

# Vivado 已安装（用于 hw_manager 下载 bitstream）
```

### 5.3 下载 Bitstream

```bash
# 方法 A：Vivado hw_manager（命令行）
vivado -mode batch -source fpga/boards/zcu102/program.tcl

# 方法 B：Vivado GUI
# Open Hardware Manager → Program Device → 选 snn_soc_fpga.bit
```

`program.tcl` 内容（如未创建，按以下写）：

```tcl
open_hw_manager
connect_hw_server
open_hw_target
set_property PROGRAM.FILE {fpga/boards/zcu102/output/snn_soc_fpga.bit} [get_hw_devices xczu9eg_0]
program_hw_devices [get_hw_devices xczu9eg_0]
refresh_hw_device [get_hw_devices xczu9eg_0]
```

### 5.4 最小冒烟序列（7 步）

上板后第一件事：用 Vivado **VIO（Virtual IO）** 替代 CPU 发起总线事务，不需要 E203 固件。

#### 步骤 1：在 top_fpga.sv 中添加 VIO/ILA（如需调试）

```systemverilog
// 在 top_fpga.sv 中的 u_soc 实例化之前插入
// 注：这是调试手段，最终版本不需要

// ILA 监控关键信号
ila_0 u_ila (
  .clk    (clk_50m),
  .probe0 (u_soc.cim_done),        // CIM 完成信号
  .probe1 (u_soc.adc_done),        // ADC 完成信号
  .probe2 (u_soc.in_fifo_empty),   // 输入 FIFO 空
  .probe3 (u_soc.out_fifo_count),  // 输出 FIFO 计数
  .probe4 (u_soc.u_dma.state)      // DMA 状态机
);

// VIO 提供虚拟按键和寄存器读写
// （实际上 VIO 无法直接发总线事务，需要自定义简单接口）
```

> **推荐更简单的调试方案**：
> 不用 VIO，直接在 top_fpga.sv 中写一个上电自动运行的**状态机**（FSM）：
> 上电 → 配置寄存器 → 触发 DMA → 触发 CIM → 等待完成 → 点亮 LED

#### 步骤 2：上电自检 FSM（最简方案）

在 `top_fpga.sv` 中添加一个 bringup FSM，上电后自动完成测试序列：

```systemverilog
// 在 top_fpga.sv 中添加 bringup 状态机（简化，仅用于上板调试）
typedef enum logic [3:0] {
  BU_INIT, BU_CFG, BU_DMA_START, BU_DMA_WAIT,
  BU_CIM_START, BU_CIM_WAIT, BU_READ, BU_DONE, BU_ERR
} bringup_t;

bringup_t bu_state;
logic [31:0] bu_timer;

// 简单总线驱动（直接连 snn_soc_top 的内部 bus_if）
// 详见下面的固件程序（或用 E203 固件）
```

> **实际上最简单的做法**：用 ZCU102 的 **ARM（PS 侧）** 驱动 PL 的寄存器。
> ARM 通过 AXI HP 口访问 PL SRAM，通过 AXI GP 口访问 PL 寄存器。
> 这就是 doc/13 里的 "Path B：PS ARM + PL 加速器" 方案。

#### 步骤 3：Path B — PS ARM 驱动 PL（推荐 bringup 路径）

在 Vitis 或 Petalinux 上写简单的 C 程序：

```c
// ARM 程序（跑在 PS A53 上）
// 通过 AXI 总线访问 PL 侧 SNN SoC

#include <stdio.h>
#include <stdint.h>

// PL 寄存器基地址（在 Vivado 设计中配置）
#define REG_BASE       0x4000_0000UL   // SNN reg_bank
#define DMA_BASE       0x4000_0100UL   // DMA regs
#define DATA_SRAM_BASE 0x0001_0000UL   // data_sram

// 寄存器偏移（与 doc/02_reg_map.md 一致）
#define REG_THRESHOLD    (REG_BASE + 0x00)
#define REG_TIMESTEPS    (REG_BASE + 0x04)
#define REG_CIM_CTRL     (REG_BASE + 0x14)
#define REG_STATUS       (REG_BASE + 0x18)
#define REG_OUT_DATA     (REG_BASE + 0x1C)
#define REG_OUT_COUNT    (REG_BASE + 0x20)
#define DMA_SRC_ADDR     (DMA_BASE + 0x00)
#define DMA_LEN_WORDS    (DMA_BASE + 0x04)
#define DMA_CTRL         (DMA_BASE + 0x08)

static inline uint32_t readl(uint64_t addr) {
    return *(volatile uint32_t *)addr;
}
static inline void writel(uint64_t addr, uint32_t val) {
    *(volatile uint32_t *)addr = val;
}

// ============================================================
// Step 1: 配置寄存器
// ============================================================
void snn_configure() {
    writel(REG_THRESHOLD, 3060);   // 工程默认阈值
    writel(REG_TIMESTEPS, 3);      // T=3
    printf("[OK] Configured: threshold=3060, timesteps=3\n");
    printf("[OK] Read back threshold=0x%08X\n", readl(REG_THRESHOLD));
}

// ============================================================
// Step 2: 加载输入数据到 data_sram
// image_data: bit-plane 编码数据，共 T×PIXEL_BITS=24 个 64-bit 字
// ============================================================
void load_image(const uint32_t *data, int num_words) {
    volatile uint32_t *sram = (volatile uint32_t *)DATA_SRAM_BASE;
    for (int i = 0; i < num_words; i++) {
        sram[i] = data[i];
    }
    printf("[OK] Loaded %d words to data_sram\n", num_words);
}

// ============================================================
// Step 3: 触发 DMA 搬运 data_sram → input_fifo
// ============================================================
void run_dma(uint32_t src_addr, uint32_t len_words) {
    writel(DMA_SRC_ADDR,  src_addr);
    writel(DMA_LEN_WORDS, len_words);
    writel(DMA_CTRL, 0x1);          // START (W1P)
    // 轮询 DONE 位
    int poll = 0;
    while (!(readl(DMA_CTRL) & 0x2)) {  // DONE = bit[1]
        poll++;
        if (poll > 10000) { printf("[ERR] DMA timeout!\n"); return; }
    }
    writel(DMA_CTRL, 0x2);          // 清除 DONE (W1C)
    printf("[OK] DMA done after %d polls\n", poll);
}

// ============================================================
// Step 4: 触发 CIM 推理，等待完成
// ============================================================
void run_inference() {
    writel(REG_CIM_CTRL, 0x1);      // START (W1P, bit[0])
    // 轮询 DONE 位（bit[7] in CIM_CTRL）
    int poll = 0;
    while (!(readl(REG_CIM_CTRL) & 0x80)) {  // DONE = bit[7]
        poll++;
        if (poll > 100000) { printf("[ERR] CIM timeout!\n"); return; }
    }
    writel(REG_CIM_CTRL, 0x80);     // 清除 DONE (W1C)
    printf("[OK] CIM done after %d polls\n", poll);
}

// ============================================================
// Step 5: 读取推理结果（spike 神经元 ID）
// ============================================================
int read_results() {
    uint32_t count = readl(REG_OUT_COUNT);
    printf("[OK] OUT_FIFO_COUNT = %d\n", count);
    int best_class = -1;
    int max_spikes = 0;
    // 简单实现：统计每个类的 spike 次数
    int spike_cnt[10] = {0};
    for (int i = 0; i < (int)count; i++) {
        uint32_t spike_id = readl(REG_OUT_DATA) & 0xF;  // 4-bit 神经元 ID
        if (spike_id < 10) spike_cnt[spike_id]++;
    }
    for (int j = 0; j < 10; j++) {
        printf("  neuron[%d] spikes = %d\n", j, spike_cnt[j]);
        if (spike_cnt[j] > max_spikes) {
            max_spikes = spike_cnt[j];
            best_class = j;
        }
    }
    printf("[RESULT] Predicted class = %d (spikes=%d)\n", best_class, max_spikes);
    return best_class;
}

// ============================================================
// 完整冒烟测试流程
// ============================================================
void smoke_test() {
    printf("\n=== SNN SoC FPGA Smoke Test ===\n");

    // 测试 1: 寄存器读写
    snn_configure();

    // 测试 2: 用 CIM test mode 验证数字链路（不依赖真实权重）
    writel(REG_BASE + 0x2C, 0x00006401);  // test_mode=1, pos=100, neg=0
    // 触发推理（test mode 下 CIM 输出 fake 数据）
    // ... DMA + CIM + 读结果 ...

    printf("\n=== Smoke Test PASS ===\n");
}
```

### 5.5 最小冒烟序列（7 步检查清单）

```
□ Step 1: 上电 → LED[1] 亮（MMCM lock）→ LED[2] 亮（reset 释放）→ LED[0] 闪烁（heartbeat）
□ Step 2: 读 REG_THRESHOLD（0x4000_0000） → 返回 0x00000BF4（=3060）
□ Step 3: 写 REG_THRESHOLD = 0xDEAD → 读回 0xDEAD → 确认读写正常
□ Step 4: 加载测试图片到 data_sram（24 个 64-bit 字 = 48 个 32-bit 字）
□ Step 5: 触发 DMA（DMA_CTRL.START=1）→ 等待 DONE=1 → 读 DMA_CTRL.ERR=0
□ Step 6: 触发 CIM（CIM_CTRL.START=1）→ 等待 DONE=1 → 读 OUT_FIFO_COUNT > 0
□ Step 7: 读出 OUT_FIFO 中的 spike → 打印预测类别 → 与 golden reference 比对
```

### 5.6 调试工具选择

| 场景 | 工具 | 说明 |
|------|------|------|
| 快速验证寄存器 | Vivado hw_manager + VIO | 无需 ARM，直接从 PC 发访问 |
| 主流 bringup | ARM Cortex-A53 + C 程序 | 最灵活，可写循环 |
| 时序问题 | Vivado ILA | 抓关键信号波形 |
| 串口调试输出 | UART + pyserial | printf 风格日志 |

### 5.7 常见 Bringup 问题

| 现象 | 可能原因 | 排查方法 |
|------|----------|----------|
| MMCM lock 不亮 | 时钟输入引脚错误 / 差分对方向反 | 检查 XDC 中 sys_clk_p/n 引脚 |
| 读寄存器返回 0xFFFFFFFF | AXI 总线未连通 / 地址映射错误 | 检查 PS-PL AXI 配置，用 ILA 抓 AXI 信号 |
| DMA 超时 | data_sram 地址偏移错误 | 检查 DMA_SRC_ADDR，确认和 SRAM 基地址对应 |
| CIM 超时 | input_fifo 为空 / DMA 未完成 | 先确认 DMA 完成（DONE=1, ERR=0） |
| OUT_FIFO_COUNT = 0 | LIF 阈值太高 / 权重全零 | 先用 CIM test mode（REG 0x2C = 0x6401）验证 |
| 结果与 Python 不一致 | 权重未正确量化 / bit-plane 编码错误 | 打印中间变量（BL_DATA, diff, membrane） |

---

## 6. 批量测试与论文数据收集

### 6.1 测试环境搭建

```python
# batch_test.py — 在 ARM 上运行的 Python 脚本
# 通过 /dev/mem 或 mmap 访问 PL 寄存器

import mmap, os, struct, time
from torchvision import datasets, transforms
import numpy as np

# PL 寄存器访问（通过 /dev/mem）
class PLRegs:
    def __init__(self):
        self.fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.sram = mmap.mmap(self.fd, 0x4000, offset=0x0001_0000)  # data_sram
        self.reg  = mmap.mmap(self.fd, 0x100,  offset=0x4000_0000)  # reg_bank
        self.dma  = mmap.mmap(self.fd, 0x100,  offset=0x4000_0100)  # DMA

    def read32(self, base_map, offset):
        base_map.seek(offset)
        return struct.unpack("<I", base_map.read(4))[0]

    def write32(self, base_map, offset, val):
        base_map.seek(offset)
        base_map.write(struct.pack("<I", val))

    def run_image(self, bitplanes_64bit):
        # 将 64-bit bit-planes 拆成 32-bit 写入 SRAM
        for i, bp in enumerate(bitplanes_64bit):
            lo = int(bp) & 0xFFFF_FFFF
            hi = (int(bp) >> 32) & 0xFFFF_FFFF
            self.write32(self.sram, (2*i)*4, lo)
            self.write32(self.sram, (2*i+1)*4, hi)

        # DMA
        self.write32(self.dma, 0x00, 0x0001_0000)     # src = data_sram base
        self.write32(self.dma, 0x04, len(bitplanes_64bit) * 2)  # len in 32-bit words
        self.write32(self.dma, 0x08, 0x1)              # START
        while not (self.read32(self.dma, 0x08) & 0x2):
            pass
        self.write32(self.dma, 0x08, 0x2)              # clear DONE

        # CIM
        self.write32(self.reg, 0x14, 0x1)              # START
        while not (self.read32(self.reg, 0x14) & 0x80):
            pass
        self.write32(self.reg, 0x14, 0x80)             # clear DONE

        # Read results
        count = self.read32(self.reg, 0x20)
        spike_cnt = [0] * 10
        for _ in range(count):
            sid = self.read32(self.reg, 0x1C) & 0xF
            if sid < 10:
                spike_cnt[sid] += 1
        return spike_cnt.index(max(spike_cnt))
```

### 6.2 全量 MNIST 精度测试

```python
# 运行 MNIST 10000 张测试集
def run_full_eval(pl, proj_weight=None):
    test_dataset = datasets.MNIST("./data", train=False,
                                  transform=transforms.ToTensor(), download=True)
    correct = 0
    total = len(test_dataset)

    for idx, (img, label) in enumerate(test_dataset):
        # 1. 图像预处理：784 → 64（监督投影）
        flat = img.numpy().flatten() * 255
        if proj_weight is not None:
            projected = proj_weight @ flat  # [64,]
            projected = np.clip(projected, 0, 255).astype(np.uint8)
        else:
            projected = flat[:64].astype(np.uint8)

        # 2. Bit-plane 编码（T=3 × 8 planes = 24 个 64-bit 字）
        bitplanes = []
        for _t in range(3):   # T=3
            for b in range(7, -1, -1):   # MSB first
                bp = np.uint64(0)
                for i in range(64):
                    if (int(projected[i]) >> b) & 1:
                        bp |= np.uint64(1) << np.uint64(i)
                bitplanes.append(bp)

        # 3. 发送到 FPGA 推理
        pred = pl.run_image(bitplanes)
        if pred == label:
            correct += 1

        if idx % 500 == 0:
            print(f"[{idx}/{total}] acc = {correct/(idx+1)*100:.2f}%")

    final_acc = correct / total * 100
    print(f"\nFinal accuracy: {final_acc:.2f}% ({correct}/{total})")
    return final_acc
```

### 6.3 论文必需实验（MVP）

#### 实验 1: 端到端精度对比

```bash
# 目标：FPGA 精度 vs Python golden 差异 < 0.5%
# Python golden: 90.35% (proj_sup_64, Scheme B, T=3, 8-bit)
# FPGA 目标: > 89.85% (允许 ±0.5% 误差)

python batch_test.py --mode full_eval --out results/fpga_accuracy.json
```

#### 实验 2: 资源与功耗（直接从 Vivado 报告提取）

```bash
# 从综合报告提取
grep -A 20 "Slice LUTs" fpga/boards/zcu102/output/post_impl_utilization.rpt
grep "Total On-Chip Power" fpga/boards/zcu102/output/post_impl_power.rpt
```

#### 实验 3: 推理延迟

```c
// 在 ARM 固件中用 cycle counter 测量
#include "xtime_l.h"

XTime t_start, t_end;
XTime_GetTime(&t_start);
run_inference();
XTime_GetTime(&t_end);

// ZCU102 PS 定时器频率
double latency_us = (double)(t_end - t_start) / COUNTS_PER_SECOND * 1e6;
printf("Inference latency: %.2f us\n", latency_us);

// 或者读 SoC 内部 debug counter
uint32_t cim_cycles = readl(REG_BASE + 0x30) >> 16;  // DBG_CNT_0 高 16 位
printf("CIM cycles: %d (at 50MHz = %.1f us)\n",
       cim_cycles, cim_cycles * 20e-3);  // 20 ns/cycle
```

### 6.4 论文加分项实验

#### 加分实验 A: MAC 并行优化（基线 vs 优化对比）

在 `cim_fpga_model.sv` 中实现列并行：

```systemverilog
// 当前基线：逐列串行扫描（由 adc_ctrl FSM 控制，一次 adc_start 扫一列）
// 优化：CIM 内部同时计算所有 10 列（预计算并缓存）

// 当前 cim_fpga_model 实际上已经是组合逻辑同时计算所有列！
// 真正的"延迟"来自 adc_ctrl 逐列扫描 20 次 × ADC_SAMPLE_CYCLES
// 优化点：减少 ADC_SAMPLE_CYCLES，或一次 ADC 读出多列

// 方案 1（最简）：在 snn_soc_pkg.sv 中减小 ADC_SAMPLE_CYCLES
// parameter int ADC_SAMPLE_CYCLES = 1;  // 从 3 改为 1
// 对比：T=3 下 CIM 时间从 1418 cycles → 约 600 cycles

// 方案 2：报告中的"基线 vs 优化"
// 基线: ADC_SAMPLE_CYCLES = 3  → latency = X us
// 优化: ADC_SAMPLE_CYCLES = 1  → latency = Y us
// 加速比 = X/Y（写进论文）
```

#### 加分实验 B: 器件非理想注入（robustness 曲线）

在 `cim_fpga_model.sv` 中添加可配置的噪声注入参数：

```systemverilog
// 在 cim_fpga_model 顶层加参数
parameter bit  ENABLE_D2D = 0;        // 开关（Vivado 综合时可以是常量）
parameter int  D2D_SIGMA_PERCENT = 5; // σ = 5%（器件实测）

// 在 MAC 计算后加扰动
// 注意：FPGA 上做真正的随机数较复杂，可以用 LFSR 或预计算的噪声表
```

```python
# 在 Python 仿真中扫描不同扰动程度（更方便）
for sigma in [0, 1, 2, 5, 10]:   # D2D 变化率 %
    acc = run_snn_eval_with_noise(sigma_percent=sigma)
    results[sigma] = acc

# 画 robustness 曲线：X=σ (%), Y=accuracy (%)
# 这条曲线很适合论文！展示系统对器件变异的鲁棒性
```

### 6.5 T sweep 实验（直接在 FPGA 上跑）

```python
# 不同 timesteps 下的精度和延迟
for T in [1, 3, 5, 10]:
    pl.write32(pl.reg, 0x04, T)          # 设置 TIMESTEPS
    # 更新阈值：threshold = 4 × 255 × T
    pl.write32(pl.reg, 0x00, 4 * 255 * T)  # REG_THRESHOLD

    acc = run_full_eval(pl)              # 全量精度测试
    # 同时记录延迟（从 debug counter 读取）
    latency = pl.read32(pl.reg, 0x30) >> 16  # DBG_CNT_0 高 16 位
    print(f"T={T}: acc={acc:.2f}%, latency={latency} cycles")
```

### 6.6 数据收集清单

```
□ 精度：FPGA accuracy (%) — 全量 10000 张 MNIST
□ 精度对比：FPGA vs Python golden（差异应 < 0.5%）
□ 延迟：cycles per frame（从 debug counter）+ us (@50MHz)
□ 吞吐量：frames per second = 1e6 / latency_us
□ 资源：LUT / FF / BRAM / DSP（来自 utilization report）
□ 功耗：Total On-Chip Power (W)（来自 power report）
□ T sweep：T=1,3,5,10 的 accuracy 和 latency（4组数据）
□ robustness：σ=0,1,2,5,10% 的 accuracy（Python 仿真即可）
□ 基线 vs 优化：ADC_SAMPLE_CYCLES=3 vs 1 的延迟对比
```

---

## 7. 论文素材清单

### 7.1 必须有（MVP）

| 素材 | 来源 | 预期值 |
|------|------|--------|
| 系统框图 | 手绘/Visio | SoC 架构 + FPGA 映射关系 |
| 精度表格 | FPGA 实测 | >89% (vs Python 90.35%) |
| 资源利用率表 | Vivado report | LUT<5k, BRAM<30 |
| 推理延迟 | debug counter | T=3 约 600-1500 cycles = 12-30 us |
| 功耗 | Vivado power report | 估计 <1W PL 动态功耗 |

### 7.2 加分项

| 素材 | 来源 | 说明 |
|------|------|------|
| T sweep 图 | FPGA 实测 | accuracy vs latency trade-off |
| Robustness 曲线 | Python 仿真 | D2D variation 对精度的影响 |
| 与其他工作对比表 | 文献调研 | 见 doc/13_fpga_paper_plan.md §6.2 |
| 优化加速比 | 基线 vs 优化 | ADC 并行 / 流水线改进 |

### 7.3 论文定位

> *"面向 RRAM CIM 的器件感知 SNN SoC 数字架构设计与 FPGA 原型验证"*

| 内容 | 期刊级别 |
|------|----------|
| 纯 RTL 仿真 | EI 会议 |
| **FPGA 验证 + 端到端推理** | **SCI Q4 / EI 期刊** |
| FPGA + 器件非理想注入 + robustness 曲线 | SCI Q3-Q4 |
| ASIC 流片 + 测试 | SCI Q2-Q3 |

---

## 8. 关键文件索引

### FPGA 分支文件

| 文件 | 说明 |
|------|------|
| `fpga/cim_model/cim_fpga_model.sv` | CIM FPGA 模型（核心） |
| `fpga/cim_model/weight_pos.hex` | 正列权重（需替换为真实训练权重） |
| `fpga/cim_model/weight_neg.hex` | 负列权重 |
| `fpga/cim_model/test_golden.txt` | 测试权重对应的 golden 结果 |
| `fpga/scripts/export_weights.py` | PyTorch → .hex 导出（Linux 服务器用） |
| `fpga/scripts/gen_test_weights.py` | 生成测试用结构化权重（无 PyTorch 依赖） |
| `fpga/sim/tb_cim_fpga.sv` | CIM 单元测试（5/5 PASS） |
| `fpga/sim/run_cim_fpga_test.sh` | 运行 CIM 单元测试 |
| `fpga/boards/zcu102/top_fpga.sv` | ZCU102 板级 wrapper |
| `fpga/boards/zcu102/constraints.xdc` | ZCU102 引脚约束 |
| `fpga/boards/zcu102/build.tcl` | Vivado 自动化综合脚本 |

### 参考文档

| 文档 | 说明 |
|------|------|
| `doc/12_fpga_validation_guide.md` | FPGA 验证流程（详细步骤） |
| `doc/13_fpga_paper_plan.md` | FPGA 论文策略 + CIM 建模 + 资源估算 |
| `doc/02_reg_map.md` | 寄存器地址表（固件开发必备） |
| `doc/09_smoke_test_checklist.md` | 冒烟测试检查清单 |

### 分支状态（2026-03-03）

```
fpga-fullversion-snnsoc (HEAD, pushed to origin)
├── Phase 0 ✅ (branch + merges)
├── Phase 1 ✅ (CIM model, unit test 5/5 PASS)
├── Phase 2 ✅ (integrated, LIGHT_SMOKETEST_PASS)
├── Phase 3 ✅ (board wrapper, XDC, TCL)
└── Phase 4-8 🔜 (on Linux server + ZCU102 board)
```

---

## 9. CPU 接入双线路径规划

### 9.1 当前状态总览

CLAUDE.md 中定义的 ASIC 主线迭代路径：

```
1. AXI-Lite 基础骨架  ✅ (bridge + TB 完成，interconnect 待做)
2. UART              ✅ (feature/uart-tx 分支完成，待主线集成)
3. SPI Master        ✅ (feature/spi 分支完成，待主线集成)
4. DMA 扩展          ❌ 未开始 (SPI→SRAM, SRAM→input_fifo)
5. E203 CPU 接入     ❌ 未开始 (最小固件 → 完整流程)
```

当前 `fpga-fullversion-snnsoc` 分支的做法是**跳过第 4、5 步**，先用最短路径验证 CIM 数字逻辑：
- Phase 0-3 完成了 CIM FPGA 模型 + 板级 wrapper
- 推理链路用 `$readmemh` 预加载 SRAM + TB 自动灌数据跑通
- 板上 bringup 计划先用 VIO 手动驱动，不依赖任何 CPU

**为什么可以跳步**：FPGA 分支的 `snn_soc_top` 内部总线仍然正常工作，DMA、寄存器、FIFO 都在。只是"谁来发起总线事务"这个问题，在 FPGA 上有比 E203 更快的选项（VIO / PS ARM）。

### 9.2 三阶段推进策略

```
阶段 1: VIO 验证（零 CPU 依赖，最快上板）
    │
    │   跑通后 ↓
    │
    ├─→ FPGA 分支（两步走，均在 fpga-fullversion-snnsoc 上）
    │     ├─ Step B: PS ARM 先跑通 → 批量 MNIST → 论文数据（快速路径）
    │     └─ Step C: E203 再接入 → 完整 SoC 演示（完整性展示）
    │
    └─→ main 分支（ASIC 主线）
          └─ DMA 扩展 → E203 接入 → 流片准备
```

**FPGA 上两个 CPU 都要做，各有侧重**：

| | PS ARM (Step B) | E203 RISC-V (Step C) |
|---|---|---|
| **目的** | 快速跑通批量测试、收集论文数据 | 展示完整 SoC 设计能力，体现 CPU 集成度 |
| **论文角色** | "快速原型验证"、精度/延迟/资源数据来源 | "完整系统集成"、证明 SoC 数字链路可独立工作 |
| **优先级** | 高（先做） | 中（数据收集后补做） |
| **依赖** | Vivado Block Design + Vitis | DMA 扩展 + ICB 桥 + 固件 |
| **分支** | fpga-fullversion-snnsoc | fpga-fullversion-snnsoc（或独立 sub-branch） |

### 9.3 阶段 1：VIO 先行验证（当前最高优先级）

**目标**：用 Vivado VIO + ILA 在 ZCU102 上跑通第一次推理，不依赖任何 CPU 固件。

**原理**：VIO（Virtual IO）让你从 PC 的 Vivado GUI 直接控制 PL 内部信号。相当于一个"虚拟 CPU"，但操作是手动的、非编程的。

**具体做法**：

1. 在 `top_fpga.sv` 中实例化 VIO IP（Vivado 生成）：

```systemverilog
// VIO: 输出 = 虚拟寄存器写入，输入 = 状态读回
// 这些信号直接连到 snn_soc_top 的内部 bus 接口
// 需要在 top_fpga 中额外引出一个简单的 "debug bus master" FSM
```

2. 更实用的方案 — 在 `top_fpga.sv` 中写一个**上电自动跑**的 bringup FSM：

```systemverilog
// bringup FSM: 上电后自动执行 smoke test 序列
// 结果通过 LED 和 ILA 可观察
// LED[3] = 最终 PASS/FAIL
//
// 状态: INIT → WRITE_THRESHOLD → READ_BACK → DMA_START → DMA_WAIT
//       → CIM_START → CIM_WAIT → READ_FIFO → DONE/ERR
```

3. 用 ILA 抓取关键信号确认链路正确：

```
ILA 抓取信号清单：
  - bus_if.addr, bus_if.wdata, bus_if.rdata  (总线事务)
  - cim_start, cim_done                       (CIM 控制)
  - adc_start, adc_done, bl_sel, bl_data      (ADC 扫描)
  - out_fifo_count                             (推理结果)
  - dma_state                                  (DMA 状态机)
```

**Pass 标准**：
- LED[0] 闪烁（heartbeat，证明时钟正常）
- LED[1] 亮（MMCM locked）
- LED[2] 亮（reset released）
- LED[3] 亮（bringup FSM 跑到 DONE 状态）
- ILA 中 OUT_FIFO_COUNT > 0

**预计时间**：1-2 天（Vivado 综合 + 下板 + 观察 LED/ILA）

### 9.4 Step C / Path A：DMA 扩展 + E203 接入

**分支**：
- FPGA 上：`fpga-fullversion-snnsoc`（Step C，ARM 数据跑完后再做）
- ASIC 主线：`main`（Path A，流片必需，与 FPGA 并行开发）

**目标**：
- FPGA 侧：完整 SoC 集成演示，体现 E203 + SNN 加速器协同工作
- ASIC 侧：完成流片所需的全 CPU 集成

> **为什么 FPGA 上也要做 E203**：
> PS ARM 是 Zynq 内置的，不是我们设计的一部分。E203 接入 FPGA 才能真正验证
> "自研 RISC-V CPU + 自研 SNN SoC" 的完整性，这在论文里是显著区别于其他工作的亮点。
> 论文图表中可以呈现：
> - Table 1: 用 PS ARM 跑的精度/延迟/资源（工程验证）
> - Table 2 / Figure X: E203 + SNN SoC 联合跑通（系统完整性验证）

#### Step A1: DMA 扩展

当前 `dma_engine.sv` 已支持 SRAM → input_fifo 搬运。需要扩展的路径：

```
新增路径:
  1. SPI Flash → data_sram  (SPI 读命令 + DMA burst write)
  2. data_sram → input_fifo (已有，需验证 64-bit packing)

工作内容:
  - dma_engine 新增 SPI 源模式（或独立 SPI-DMA 桥）
  - TB: spi_to_sram_tb.sv (SPI Flash model → DMA → SRAM → 内容校验)
  - TB: sram_to_fifo_tb.sv (SRAM 预载 → DMA → input_fifo → 内容校验)

依赖:
  - feature/spi 已合入 main（spi_ctrl.sv 可用）
  - spi_stub 需替换为 spi_ctrl（主线集成）

预计时间: 3-5 天
```

#### Step A2: AXI-Lite Interconnect 集成

当前 `axi2simple_bridge.sv` 是点对点的，需要一个简单的地址译码器分发到多个外设：

```
AXI-Lite Interconnect 地址映射:
  0x0000_0000 ~ 0x0000_FFFF → code_sram (E203 指令)
  0x0001_0000 ~ 0x0001_FFFF → data_sram
  0x4000_0000 ~ 0x4000_00FF → reg_bank
  0x4000_0100 ~ 0x4000_01FF → DMA regs
  0x4000_0200 ~ 0x4000_02FF → UART regs
  0x4000_0300 ~ 0x4000_03FF → SPI regs

工作内容:
  - axi_lite_interconnect.sv (地址译码 + response MUX)
  - TB: interconnect_tb.sv (多外设同时访问)
  - 集成到 snn_soc_top.sv (替换现有 bus_interconnect)

预计时间: 2-3 天
```

#### Step A3: E203 CPU 接入

E203 是 RISC-V RV32IMC 核，通过 AXI-Lite 或自带总线接口连接：

```
集成方案（两选一）:
  方案 A: E203 自带 ICB 总线 → ICB-to-AXI bridge → AXI-Lite Interconnect
  方案 B: E203 自带 ICB 总线 → ICB-to-bus_simple bridge → 现有 bus_interconnect

推荐方案 B:
  - 省一层 AXI 转换（ICB 和 bus_simple 都是简单的 req/ack 协议）
  - 复用现有 bus_interconnect（已验证）
  - E203 只需适配 ICB → bus_simple 的信号映射

最小固件验证顺序:
  1. UART printf "Hello SNN"     → 证明 CPU 能跑、UART 通
  2. 寄存器读写 REG_THRESHOLD    → 证明总线互连通
  3. SPI 读 Flash ID             → 证明 SPI 通
  4. DMA 搬运一帧 → CIM 推理     → 证明全链路通
  5. 完整 MNIST 推理循环          → 系统级验证

预计时间: 5-7 天（含固件开发和调试）
```

#### Path A 总时间线

```
A1 DMA 扩展     ████████░░     3-5 天
A2 AXI Interco  ░░░░████░░     2-3 天（可与 A1 部分并行）
A3 E203 接入    ░░░░░░░█████   5-7 天
───────────────────────────────
总计                            ~2-3 周
```

### 9.5 Step B：PS ARM 接入（FPGA 论文快速路径，优先做）

**分支**：`fpga-fullversion-snnsoc`

**目标**：用 ZCU102 的 PS 端 ARM Cortex-A53 驱动 PL，实现批量 MNIST 测试，快速拿到论文数据

#### 为什么 Path B 更快

```
Path A (E203):
  需要: DMA 扩展 + AXI Interconnect + E203 RTL + 固件 + 调试
  时间: ~2-3 周
  输出: ASIC 可流片的完整 SoC

Path B (PS ARM):
  需要: Vivado Block Design 连线 + C 程序
  时间: ~3-5 天
  输出: FPGA 上能批量跑 MNIST，能发论文

关键区别:
  - Path B 不需要 DMA 扩展 — ARM 直接 mmap 写 PL SRAM
  - Path B 不需要 E203 — ARM 自己就是 CPU
  - Path B 不需要 AXI Interconnect — Zynq PS-PL AXI 端口是硬件内置的
```

#### Step B1: Vivado Block Design

在 Vivado 中创建 Block Design，连接 PS 和 PL：

```
Zynq PS (ARM A53)
  │
  ├─ M_AXI_HPM0_FPD (GP 口) ──→ AXI Interconnect ──→ axi2simple_bridge ──→ reg_bank
  │                                                                      ──→ DMA regs
  │
  └─ S_AXI_HP0_FPD (HP 口) ──→ data_sram (高带宽，批量图片加载用)

操作步骤:
  1. Vivado → Create Block Design
  2. 添加 Zynq UltraScale+ MPSoC IP
  3. 配置 M_AXI_HPM0 (GP 口，32-bit，低带宽寄存器访问)
  4. 配置 S_AXI_HP0 (HP 口，128-bit，高带宽 SRAM 访问)
  5. 添加 snn_soc_top 为自定义 IP（或 RTL module）
  6. 插入 axi2simple_bridge 做协议转换
  7. 连线 + Generate Output Products + Create HDL Wrapper
  8. 综合 → 实现 → 生成 bitstream
  9. Export Hardware (含 bitstream) → 给 Vitis 用
```

#### Step B2: Vitis/Petalinux 固件

```
方案 A: Vitis Bare-Metal (推荐，最简单)
  - 新建 Vitis Platform Project → 基于导出的 .xsa
  - 新建 Application Project → Bare-Metal (standalone BSP)
  - 编写 C 程序（见 doc/14 §5.4 中的 smoke_test()）
  - 直接用 Xil_In32/Xil_Out32 访问 PL 寄存器

方案 B: Petalinux (批量测试更方便)
  - 跑 Linux → 用 /dev/mem + mmap 访问 PL
  - 可以跑 Python batch_test.py（见 doc/14 §6.1）
  - 适合一次跑完 10000 张 MNIST
```

#### Step B3: AXI2Simple Bridge 集成

当前 `axi2simple_bridge.sv` 已在 `feature/axi-lite` 分支完成（T1~T9 全 PASS），但还未集成到 `snn_soc_top.sv`。

```
集成工作:
  1. 在 snn_soc_top.sv 中添加 AXI-Lite slave 端口
  2. axi2simple_bridge 输出连到现有 bus_interconnect 的 master 端口
  3. 地址映射：PS 看到的地址 → PL 内部地址
     - PS 0xA000_0000 → PL reg_bank (0x4000_0000)
     - PS 0xA000_0100 → PL DMA regs (0x4000_0100)
     - PS 0xA001_0000 → PL data_sram (0x0001_0000)
  4. 实际地址取决于 Vivado Block Design 中的地址分配

注意:
  - 这里有两种 bus master 可能同时存在:
    a) 原有 bus_simple 的 CPU master 口（给 E203 用的）
    b) 新增的 axi2simple_bridge 输出（给 PS ARM 用的）
  - FPGA 分支可以直接把 E203 的 master 口断开（接常量），
    只用 AXI bridge 作为唯一 master
  - 或者加一个简单的 2:1 arbiter（但不值得，FPGA 上不需要两个 CPU）
```

#### Path B 总时间线

```
B1 Block Design   ████░░░░     1-2 天
B2 固件 (bare-metal) ░░████░░  1-2 天
B3 AXI 集成       ░░░░░███     1 天（可与 B1 并行）
B4 批量测试       ░░░░░░░███   2-3 天
───────────────────────────────
总计                            ~5-7 天
```

### 9.6 双线并行时间线总览

```
Week 1:
  Day 1-2  ║ VIO 验证（阶段 1）— Vivado 综合 + 下板 + LED/ILA 确认
           ║
  Day 3-5  ║ ┌─ Path B: Block Design + AXI 集成 + bare-metal 固件
           ║ └─ Path A: DMA 扩展（SPI→SRAM TB）开始

Week 2:
  Day 6-8  ║ ┌─ Path B: 批量 MNIST 测试 + 论文数据收集
           ║ └─ Path A: DMA 扩展完成 + AXI Interconnect

Week 3:
  Day 9-12 ║ ┌─ Path B: 论文撰写（实验数据已齐）
           ║ └─ Path A: E203 接入 + 最小固件验证

Week 4:
           ║ ┌─ Path B: 论文投稿
           ║ └─ Path A: E203 全链路验证 + ASIC 准备
```

### 9.7 两条路径的交叉点

虽然是并行开发，但有几个共享成果可以互相复用：

```
Path B → Path A 的复用:
  ✓ cim_fpga_model.sv 的 MAC 逻辑可作为 CIM blackbox 验证的 golden model
  ✓ FPGA 批量测试结果可直接作为 ASIC RTL 仿真的 golden reference
  ✓ axi2simple_bridge 在 Path B 验证后，Path A 的 interconnect 可直接复用

Path A → Path B 的复用:
  ✓ DMA 扩展完成后，FPGA 分支可以 cherry-pick，实现 SPI Flash 加载权重
  ✓ E203 固件的寄存器操作序列，可以直接翻译为 ARM C 程序
```

### 9.8 FPGA 上两 CPU 的论文定位

```
论文结构建议：

§ System Implementation
  ├── 4.1 FPGA Prototype (ZCU102)
  │     ├── 4.1.1 SNN Accelerator (CIM FPGA model + LIF + DMA)  ← 核心贡献
  │     ├── 4.1.2 Control Path A: PS ARM (Cortex-A53)
  │     │         "Rapid validation using onboard ARM processor"
  │     │         → 精度/延迟/资源/功耗数据在此获取
  │     └── 4.1.3 Control Path B: E203 RISC-V SoC
  │               "Full SoC integration with custom RISC-V CPU"
  │               → 证明数字链路完整自洽，CPU + Accelerator 协同工作

§ Experimental Results
  ├── Table 1: Resource Utilization (LUT/FF/BRAM/DSP)
  ├── Table 2: Accuracy (FPGA vs Python golden)
  ├── Table 3: Inference Latency (ARM-measured / E203-measured)
  └── Figure X: E203 + SNN SoC 完整系统框图
```

**两者的互补价值**：
- PS ARM：工业界熟悉，数据可靠性高，batch test 速度快
- E203：学术界展示 full-stack 自研能力，是区别同类 FPGA 加速器论文的关键

### 9.9 决策记录

| 日期 | 决策 | 理由 |
|------|------|------|
| 2026-03-03 | FPGA 分支跳过 DMA 扩展和 E203，直接做 CIM 模型 | 论文最快路径，先跑通加速器核心 |
| 2026-03-03 | 先 VIO 验证，再双路并行 | VIO 零依赖，最快拿到板上第一个结果 |
| 2026-03-03 | FPGA 上 PS ARM 先行（Step B） | ARM 是"免费的"，省 2-3 周，快速收集论文数据 |
| 2026-03-03 | FPGA 上 E203 后补（Step C） | 展示完整 SoC 集成能力，是论文区别于同类工作的亮点 |
| 2026-03-03 | main 分支独立推进 E203（Path A） | ASIC 流片必需，与 FPGA 工作并行不相互阻塞 |

---

---

## 10. 从 main 到 FPGA 分支：改动清单与学习路径

> **面向读者**：已熟悉 `main` 分支全部代码，想快速理解 `fpga-fullversion-snnsoc`
> 分支新增了什么、改了什么、为什么这样改。

### 10.1 相对 main 的完整改动清单

共 37 个文件发生变化，按性质分为三类：

#### 类型 A：合并自 feature 分支（原样带入，逻辑未改）

这些文件在 main 上不存在，是从三个 feature 分支合并进来的：

| 文件 | 来源分支 | 作用 |
|------|----------|------|
| `rtl/bus/axi_lite_if.sv` | feature/axi-lite | AXI-Lite 接口定义（SystemVerilog interface） |
| `rtl/bus/axi2simple_bridge.sv` | feature/axi-lite | AXI-Lite Slave → bus_simple Master 桥（5态 FSM） |
| `tb/axi_bridge_tb.sv` | feature/axi-lite | AXI 桥单元测试（T1~T9，9/9 PASS） |
| `sim/sim_axi_bridge.f` | feature/axi-lite | AXI 桥 Icarus 文件列表 |
| `sim/run_axi_bridge_icarus.sh` | feature/axi-lite | AXI 桥测试入口 |
| `new_branchnotes/axi-lite.md` | feature/axi-lite | AXI 分支开发记录 |
| `rtl/periph/uart_ctrl.sv` | feature/uart-tx | UART 控制器（TX/RX，可配置波特率） |
| `tb/uart_tb.sv` | feature/uart-tx | UART 单元测试 |
| `sim/sim_uart.f` | feature/uart-tx | UART Icarus 文件列表 |
| `sim/run_uart_icarus.sh` | feature/uart-tx | UART 测试入口 |
| `new_branchnotes/uart.md` | feature/uart-tx | UART 分支开发记录 |
| `rtl/periph/spi_ctrl.sv` | feature/spi | SPI Master（Mode0，MSB first） |
| `tb/spi_flash_model.sv` | feature/spi | SPI Flash 行为模型（仿真用） |
| `tb/spi_tb.sv` | feature/spi | SPI 单元测试（T1~T4+T1b，9/9 PASS） |
| `sim/sim_spi.f` | feature/spi | SPI Icarus 文件列表 |
| `sim/run_spi_icarus.sh` | feature/spi | SPI 测试入口 |
| `new_branchnotes/spi.md` | feature/spi | SPI 分支开发记录 |

> **注意**：这 17 个文件在 `main` 上也有对应的 feature 分支，只是未合入。
> 如果你已读过 feature 分支的代码，这部分可以跳过。

#### 类型 B：FPGA 分支新建（fpga 专属，main 上无对应）

| 文件 | 作用 | 关键设计决策 |
|------|------|-------------|
| `fpga/cim_model/cim_fpga_model.sv` | **核心**：BRAM 权重 + 数字 MAC，替代 RRAM blackbox | 4-bit 权重 × 1-bit spike，组合逻辑累加，无 DSP |
| `fpga/cim_model/weight_pos.hex` | 正列权重（64×10 个 4-bit 值，$readmemh 格式） | 当前为测试权重，需替换为训练权重 |
| `fpga/cim_model/weight_neg.hex` | 负列权重 | 同上 |
| `fpga/cim_model/test_image.hex` | 测试图片 bit-plane 编码（T=3 × 8 planes） | 用于 CIM 单元测试 |
| `fpga/cim_model/test_golden.txt` | 预期推理结果（膜电位 + spike） | 验证 MAC 计算正确性 |
| `fpga/scripts/export_weights.py` | PyTorch → .hex 权重导出（Linux 服务器用） | 器件感知量化 or 均匀量化 |
| `fpga/scripts/gen_test_weights.py` | 纯 Python 测试权重生成器（无 PyTorch 依赖） | 结构化权重，类 j 对 rows [j×6, j×6+5] 响应强 |
| `fpga/sim/tb_cim_fpga.sv` | CIM FPGA 模型单元测试（5/5 PASS） | 独立验证 CIM 时序 + MAC 正确性 |
| `fpga/sim/run_cim_fpga_test.sh` | CIM 单元测试入口 | |
| `fpga/sim/weight_{pos,neg}.hex` | Icarus 仿真用权重副本（$readmemh 搜索 CWD） | 与 fpga/cim_model/ 内容相同 |
| `fpga/boards/zcu102/top_fpga.sv` | ZCU102 板级顶层 wrapper | MMCM 300→50MHz，2-FF 复位同步，LED |
| `fpga/boards/zcu102/constraints.xdc` | ZCU102 引脚约束 | 时钟 AL8/AL7，复位 AM13，UART A20/B20 |
| `fpga/boards/zcu102/build.tcl` | Vivado 非工程模式自动化综合 | synth→opt→place→route→bitstream |
| `doc/14_fpga_fullversion_execution.md` | 本文档 | |
| `sim/weight_{pos,neg}.hex` | Icarus 主仿真用权重副本 | 端到端 smoke test 需要 |

#### 类型 C：对已有文件的修改（最关键，影响集成行为）

| 文件 | 改动内容 | 影响 |
|------|----------|------|
| `rtl/top/snn_soc_top.sv` | `cim_macro_blackbox u_macro` → `cim_fpga_model u_macro`（仅实例化名+模块名，接口完全兼容） | **FPGA 分支与 ASIC 主线最核心的区别** |
| `sim/sim_icarus_light.f` | 第 15 行：`cim_macro_blackbox.sv` → `fpga/cim_model/cim_fpga_model.sv` | Icarus 编译时引入 FPGA 模型而非 blackbox |
| `sim/icarus_light.out` | 仿真输出日志更新（OUT_FIFO_COUNT=42，原为 20） | 非代码改动，仅记录 |

**总结：整个 FPGA 分支在逻辑层面只改了 2 行代码**——`snn_soc_top.sv` 和 `sim_icarus_light.f` 各改了 1 行，其余全是新增文件。

---

### 10.2 学习路径建议

> 假设你已完整读过 `main` 分支代码（包括 snn_soc_top、cim_macro_blackbox、cim_array_ctrl、adc_ctrl 等），
> 按以下顺序学习 FPGA 分支新增内容。

#### 第 1 步：理解 FPGA 分支的核心改动（10 分钟）

先看那 2 行关键修改：

```bash
git diff main...fpga-fullversion-snnsoc -- rtl/top/snn_soc_top.sv
git diff main...fpga-fullversion-snnsoc -- sim/sim_icarus_light.f
```

你会看到：`snn_soc_top.sv` 只改了模块名（`cim_macro_blackbox` → `cim_fpga_model`），
接口信号名一字未动。这就是 "100% 端口兼容" 的含义。

#### 第 2 步：读 cim_fpga_model.sv（核心，30-45 分钟）

**路径**：[fpga/cim_model/cim_fpga_model.sv](fpga/cim_model/cim_fpga_model.sv)

**带着这些问题读**：

```
Q1: 权重是怎么存的？（$readmemh 格式，4-bit，weight_pos/neg 各 64×10）
Q2: MAC 怎么计算的？（组合逻辑 for 循环，wl_latched[i] ? weight[i][j] : 0）
Q3: 和 cim_macro_blackbox 的时序模型有什么区别？（相同：CIM_LATENCY_CYCLES + ADC_SAMPLE_CYCLES）
Q4: adc_start/bl_sel/bl_data 的时序是什么？（adc_start 触发，ADC_SAMPLE_CYCLES 后输出，拉 adc_done）
Q5: 为什么用 10-bit 累加器？（max = 64 × 15 = 960 < 1024，需要 10-bit 防溢出）
Q6: 差分是在哪里计算的？（不在这里！adc_ctrl.sv 做 diff = raw[i] - raw[i+10]，与 main 一致）
```

**读完对照参考**：[rtl/snn/cim_macro_blackbox.sv](rtl/snn/cim_macro_blackbox.sv)（main 分支），
体会两者的接口完全一样，只是内部实现从 RRAM 行为模型换成了 BRAM 数字 MAC。

#### 第 3 步：读 CIM 单元测试（20 分钟）

**路径**：[fpga/sim/tb_cim_fpga.sv](fpga/sim/tb_cim_fpga.sv)

5 个测试用例帮助理解 cim_fpga_model 的行为：

| 测试 | 验证内容 | 学习点 |
|------|----------|--------|
| T1: 基本时序 | cim_start → cim_done 延迟 | CIM_LATENCY_CYCLES 的含义 |
| T2: ADC 扫描 | adc_start → bl_data × 20 列 | ADC_SAMPLE_CYCLES + bl_sel 遍历 |
| T3: Scheme B 验证 | pos - neg 差分结果 | 差分在 adc_ctrl 做，这里只输出原始值 |
| T4: 全零输入 | spike=0 时 bl_data=0 | MAC 的条件性（spike=0 → 不累加） |
| T5: 单行激活 | 只激活 row 0 → 只有 j=0 列有响应 | 权重结构验证 |

#### 第 4 步：读权重格式（10 分钟）

**路径**：[fpga/scripts/gen_test_weights.py](fpga/scripts/gen_test_weights.py)

理解 `.hex` 文件格式规范：

```
weight_pos.hex / weight_neg.hex:
  640 行，每行 1 个 16 进制数字（0-f，代表 4-bit 权重 0-15）
  存储顺序（行优先）：
    weight[row=0][col=0]   ← 第 1 行
    weight[0][1]           ← 第 2 行
    ...
    weight[0][9]           ← 第 10 行
    weight[1][0]           ← 第 11 行
    ...
    weight[63][9]          ← 第 640 行

  $readmemh 自动按此顺序填充 2D 数组
```

如果有 PyTorch 环境，可以顺便看 [fpga/scripts/export_weights.py](fpga/scripts/export_weights.py) 了解
训练权重如何量化到 4-bit 并导出。

#### 第 5 步：读板级 wrapper（20 分钟）

**路径**：[fpga/boards/zcu102/top_fpga.sv](fpga/boards/zcu102/top_fpga.sv)

这是纯 FPGA 板级代码，与 SNN 逻辑无关，重点理解：

```
1. IBUFDS：差分输入缓冲（300MHz 差分时钟 → 单端）
2. MMCME4_ADV：MMCM 原语（300MHz × 4/24 = 50MHz）
   参数：CLKIN1_PERIOD=3.333，CLKFBOUT_MULT_F=4.0，CLKOUT0_DIVIDE_F=24.0
3. BUFG：全局时钟缓冲（避免时序违例）
4. 2-FF 复位同步器：异步断言（!mmcm_locked | btn_rst），同步释放
5. snn_soc_top 实例化：时钟/复位/UART/SPI 连线（与 chip_top.sv 类比）
6. LED 指示逻辑：heartbeat 计数器（[25] bit → ~1 Hz），mmcm_locked，rst_n
```

#### 第 6 步：读约束和构建脚本（10 分钟）

**路径**：[fpga/boards/zcu102/constraints.xdc](fpga/boards/zcu102/constraints.xdc)，
[fpga/boards/zcu102/build.tcl](fpga/boards/zcu102/build.tcl)

不需要精读，只需了解：
- `.xdc` = FPGA 引脚约束，`PACKAGE_PIN` + `IOSTANDARD` + `create_clock`
- `build.tcl` = Vivado 非工程模式流程，`synth_design` → `place_design` → `route_design` → `write_bitstream`

#### 第 7 步（可选）：了解合并进来的外设

如果你还没读过 feature 分支，可以按以下顺序补充：

```
优先级高：
  rtl/bus/axi2simple_bridge.sv     ← AXI-Lite → bus_simple 桥，Path B 必需
  new_branchnotes/axi-lite.md      ← 设计说明，比代码更易入门

优先级中：
  rtl/periph/uart_ctrl.sv          ← UART 控制器
  rtl/periph/spi_ctrl.sv           ← SPI Master

优先级低（仅在 feature/spi 做单独测试时才需要）：
  tb/axi_bridge_tb.sv / tb/uart_tb.sv / tb/spi_tb.sv
```

---

### 10.3 改动一览表（快速索引版）

```
main → fpga-fullversion-snnsoc 改动总览
═══════════════════════════════════════════════════════════════

【逻辑改动】仅 2 处，其余全是新增文件

  rtl/top/snn_soc_top.sv  line 714:  cim_macro_blackbox → cim_fpga_model
  sim/sim_icarus_light.f  line 15:   cim_macro_blackbox.sv → fpga/cim_model/cim_fpga_model.sv

【新增：FPGA CIM 模型（核心）】
  fpga/cim_model/cim_fpga_model.sv    ← 替代 RRAM 的可综合数字 MAC
  fpga/cim_model/weight_{pos,neg}.hex ← 4-bit 权重
  fpga/cim_model/test_image.hex       ← 测试输入
  fpga/cim_model/test_golden.txt      ← 期望输出

【新增：权重工具】
  fpga/scripts/export_weights.py      ← PyTorch 权重导出（Linux 用）
  fpga/scripts/gen_test_weights.py    ← 纯 Python 测试权重生成

【新增：CIM 单元测试】
  fpga/sim/tb_cim_fpga.sv             ← 5 测试用例，5/5 PASS
  fpga/sim/run_cim_fpga_test.sh
  fpga/sim/{weight_pos,weight_neg}.hex  ← Icarus 仿真副本

【新增：ZCU102 板级】
  fpga/boards/zcu102/top_fpga.sv      ← 板级 wrapper（MMCM + 复位 + LED）
  fpga/boards/zcu102/constraints.xdc  ← 引脚约束
  fpga/boards/zcu102/build.tcl        ← Vivado 综合自动化

【来自 feature/axi-lite】
  rtl/bus/axi_lite_if.sv
  rtl/bus/axi2simple_bridge.sv        ← PS ARM 接入的关键桥
  tb/axi_bridge_tb.sv，sim/sim_axi_bridge.f，sim/run_axi_bridge_icarus.sh

【来自 feature/uart-tx】
  rtl/periph/uart_ctrl.sv
  tb/uart_tb.sv，sim/sim_uart.f，sim/run_uart_icarus.sh

【来自 feature/spi】
  rtl/periph/spi_ctrl.sv
  tb/spi_{tb,flash_model}.sv，sim/sim_spi.f，sim/run_spi_icarus.sh

【文档】
  doc/14_fpga_fullversion_execution.md  ← 本文档
  new_branchnotes/{axi-lite,uart,spi}.md
  sim/weight_{pos,neg}.hex（端到端仿真副本）
```

---

> **更新记录**：
> - 2026-03-03 初版，基于 `fpga-fullversion-snnsoc` 分支 commit `feabb267`
> - 2026-03-03 新增 §9 CPU 接入双线路径规划（VIO 先行 + Path A/B 并行）
> - 2026-03-03 §9.2/9.4/9.8 更新：明确 FPGA 上两 CPU 均需实现（ARM 先行快速验证 + E203 后补完整性展示），并补充论文定位分析
> - 2026-03-03 新增 §10 从 main 到 FPGA 分支的改动清单与学习路径
