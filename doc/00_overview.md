# 00_overview

## 项目目标

**当前版本**：MVP（最小可用版本）
**目标版本**：V1（完整版本，6月30日流片）
**参数口径**：默认参数与时序常量以 `rtl/top/snn_soc_pkg.sv` 为准，本文数值仅作说明，若不一致以 pkg 为准。

### MVP 目标
构建一个最小可用的 SNN SoC，从寄存器配置到完整推理流程可仿真跑通，并可在 Verdi 观察关键波形。

### V1 目标
在 MVP 基础上增加：
- RISC-V Core（蜂鸟 E203）
- UART 控制器（与 PC 通信）
- SPI 控制器（读取 Flash）
- AXI-Lite 总线（替换 simple 总线）

### 流片说明
- **V1 流片类型**：数字 SoC 单独流片 + 片外混合集成验证
- **V2/V3**：片上数模混合集成
- **数字部分**：本项目的 RTL
- **模拟部分**：真实 CIM Macro（由其他同学提供版图）
- **时钟频率**：目标 50MHz
- **接口约定**：`cim_macro_blackbox.sv` 端口定义保持不变

## 分层结构（目录 + 关系）
- 顶层：snn_soc_top  
- bus：简化总线与地址译码  
- mem：SRAM + FIFO  
- reg：寄存器 bank + FIFO 状态窗  
- dma：DMA 引擎（data_sram -> input_fifo）  
- snn：CIM 控制器 + DAC/ADC + LIF 神经元 + CIM 行为模型  
- periph：UART/SPI/JTAG stub  

## 一次推理的数据流
```
data_sram
  -> dma_engine
    -> input_fifo
      -> dac_ctrl
        -> cim_macro (行为模型)
          -> adc_ctrl
            -> lif_neurons
              -> output_fifo
```

**V1 完整数据注入路径**（含外部 Flash）：
```
Flash -> SPI -> CPU(E203) -> data_sram -> DMA -> input_fifo -> ... -> output_fifo
```

## 数据流与控制流分离（设计原则）
- **数据流**：data_sram → DMA → input_fifo → CIM → output_fifo
- **控制流**：CPU 仅做寄存器配置/启动/读取结果

### 为什么 DMA + FIFO 不合并
- DMA 是**固定路径的单通道搬运引擎**（data_sram → input_fifo），避免 CPU 逐字节搬运。
- FIFO 用于**速率解耦与事件缓冲**，吸收 DMA 突发与 CIM/ADC 间歇消费的不匹配。

## 时序流程（bit-plane）
1. 写寄存器：配置阈值、TIMESTEPS（帧数）。
2. DMA 从 data_sram 读取 2 个 32-bit word 拼成 64-bit bit-plane（NUM_INPUTS=64），写入 input_fifo。
3. cim_array_ctrl 启动后：对每一帧的每个 bit-plane（MSB->LSB）依次执行 DAC -> CIM -> ADC。
4. ADC 控制器完成 20 路时分复用采样（Scheme B：10 正 + 10 负）后，执行数字差分减法，输出有符号差分数据 + `neuron_in_valid`。
5. LIF 在 `neuron_in_valid` 处将有符号差分值按 `bitplane_shift` 算术左移累加到有符号膜电位，超阈值产生 spike，写入 output_fifo。

**补充**：当 `TIMESTEPS=0` 时，控制器会立即结束，不进入推理流程。

## 真实实现 vs stub/行为模型
- 真实实现：总线、SRAM、FIFO、寄存器、DMA、SNN 控制、LIF 神经元。
- 行为模型：CIM Macro（仿真可复现 bl_data）。
- Stub：UART/SPI/JTAG，不产生真实协议，仅占位可读写寄存器。

## 关键参数表
| 参数 | 值 | 说明 |
|---|---:|---|
| NUM_INPUTS | 64 | 输入维度（8x8，离线投影后特征） |
| NUM_OUTPUTS | 10 | 输出类别数 |
| ADC_CHANNELS | 20 | CIM BL 通道数（Scheme B：10 正 + 10 负） |
| PIXEL_BITS | 8 | 像素位宽（bit-plane 编码） |
| ADC_BITS | 8 | ADC 输出位宽 |
| NEURON_DATA_WIDTH | 9 | 差分后有符号数据位宽（ADC_BITS+1） |
| TIMESTEPS_DEFAULT | 10 | 默认帧数（定版 T=10，spike-only 90.42%） |
| THRESHOLD_RATIO_DEFAULT | 4 | 阈值比例（4/255 ≈ 0.0157，定版 ratio_code） |
| SPIKE_RESET_MODE | soft | 复位模式定版（soft/hard 在当前推荐配置与 noisy test 上等效） |
| THRESHOLD_DEFAULT | 10200 | 默认阈值（ratio_code × 255 × T = 4×255×10） |
| LIF_MEM_WIDTH | 32 | LIF 膜电位位宽（有符号，建议 >= NEURON_DATA_WIDTH + PIXEL_BITS） |
| DAC_LATENCY_CYCLES | 5 | DAC 延迟（仿真） |
| CIM_LATENCY_CYCLES | 10 | CIM 延迟（仿真） |
| ADC_MUX_SETTLE_CYCLES | 2 | ADC MUX 通道切换建立时间（仿真） |
| ADC_SAMPLE_CYCLES | 3 | ADC 单次采样延迟（仿真） |

## 建模定版补充（复位模式，2026-02-10）
- 对比对象：`SPIKE_RESET_MODE=soft` 与 `SPIKE_RESET_MODE=hard`，其余参数固定（`proj_sup_64, Scheme B, ADC=8, W=4, T=10, ratio_code=4`）。
- 对比入口：`run_all.py` 的 `[3f]`（`add_noise=True`）与 `[3l]`（test 多 seed noisy，`add_noise=True`）。
- soft（历史基线）：
  - val noisy mean：`90.41% +/- 0.0031`
  - test noisy（multi-seed）：`90.98% +/- 0.0012`
- hard（2026-02-10 复跑）：
  - val noisy mean：`90.51% +/- 0.0034`
  - test noisy（multi-seed）：`90.98% +/- 0.0012`
- 结论：
  - 当前推荐配置下，soft/hard 在 noisy test 上无可区分差异（数值一致）。
  - val 侧 `0.10%` 差异小于统计波动量级（`~0.31%-0.34%`），不具显著性。
  - V1 继续沿用 `soft`，作为默认复位模式。
- 结果来源：
  - `项目相关文件/器件对齐/Python建模/results/summary.txt`
  - `项目相关文件/器件对齐/Python建模/results/run_all_skiptrain_hard_20260210_161450.log`
