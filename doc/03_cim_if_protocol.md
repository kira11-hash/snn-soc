# 03_cim_if_protocol

**版本**：v2.1
**日期**：2026-03-16
**模块**：`cim_macro_blackbox`
**参数口径**：与时序相关的默认参数以 `rtl/top/snn_soc_pkg.sv` 为准，本文数值仅作说明，若不一致以 pkg 为准。
**架构说明**：本文描述的是数字芯片内部的 `snn_soc_top` 与行为模型 `cim_macro_blackbox` 之间的**内部并行接口**。实际流片后，数字芯片与模拟 CIM 芯片为独立封装，通过 PCB 互联，使用 `wl_mux_wrapper` 提供的**外部复用接口**（45 个可用 pad 口径）。详见 `doc/08_cim_analog_interface.md` §1.3 与 `doc/15_asic_pad_map.md`。

> **边界说明（2026-04-23）**：本文只覆盖**推理**链路的内部协议，不定义外部 `erase/write/verify` 编程协议。若 V1 外部模拟 die 需要支持数字发起编程，请以 `doc/11_analog_handoff_execution_plan.md` 的 A8 为准，先冻结跨芯片编程合同。

## 接口信号
| 方向 | 信号 | 位宽 | 类型 | 说明 |
|---|---|---:|---|---|
| input | wl_spike | NUM_INPUTS(=64) | 数据 | 单个 bit-plane（64 路并行），同一子时间步的特征向量第 x 位 |
| input | dac_valid | 1 | 脉冲 | 单拍触发信号；行为模型在该拍锁存 `wl_spike`（真实芯片由 `wl_latch` 时序控制） |
| input | cim_start | 1 | 脉冲 | CIM 计算启动 |
| output | cim_done | 1 | 脉冲 | CIM 计算完成 |
| input | adc_start | 1 | 脉冲 | ADC 启动（**仅内部仿真接口**，不在外部 45-pad 接口中；流片后由 `snn_soc_top` 内部固定延迟生成 `adc_done`） |
| output | adc_done | 1 | 脉冲 | ADC 完成（**仅内部仿真接口**，同上） |
| input | bl_sel | $clog2(ADC_CHANNELS)(=5) | 控制 | bitline 选择（0..ADC_CHANNELS-1，Scheme B: 0-9 正列, 10-19 负列） |
| output | bl_data | ADC_BITS(=8) | 数据 | 当前通道的 8-bit ADC 输出 |

## 时序与触发
1. `wl_mux_wrapper` 用 `wl_latch` 完成 8 组 WL 复用发送。
2. `dac_ctrl` 在 `wl_valid_pulse` 到来后锁存 `wl_bitmap` 到 `wl_spike`，并发出 `dac_valid` 单拍。
3. 行为模型在 `dac_valid` 单拍时锁存 `wl_spike`；真实芯片侧不依赖 `dac_ready`，采用固定时序。
4. 控制器等待固定 `DAC_LATENCY_CYCLES` 后发出 `cim_start`，Macro 经过 `CIM_LATENCY_CYCLES` 后拉高 `cim_done`。
5. 控制器发出 `adc_start`，进入 ADC 时分复用采样。

## ADC 时分复用（Scheme B）
- `bl_sel` 依次为 0..ADC_CHANNELS-1（共 20 通道）。
- 每次切换后等待 `ADC_MUX_SETTLE_CYCLES`。
- 对每个通道触发一次 `adc_start`，等待 `adc_done` 后锁存该通道的 `bl_data`。
- 20 路原始数据齐全后，ADC 控制器执行数字差分减法：`diff[i] = raw[i] - raw[i+10]`（i=0..9）。
- 输出 10 路有符号差分数据（NEURON_DATA_WIDTH=9 bit）+ `neuron_in_valid`。

**行为模型说明**：当前 CIM 行为模型在 `adc_done` 时更新所有 20 通道的内部结果，`bl_data` 由 `bl_sel` 选择输出。正列 (0..9) 产生较高值，负列 (10..19) 产生较低值。`adc_done` 的延迟由 `ADC_SAMPLE_CYCLES` 决定。

## 行为模型 bl_data 生成规则

> **注**：以下规则仅适用于数字芯片内的仿真行为模型（`cim_macro_blackbox.sv`）。流片后真实模拟芯片返回的 `bl_data` 由 RRAM 阵列的物理权重决定，公式不同。带权重仿真使用 `sim/models/cim_macro_blackbox_weighted_icarus.sv`，其 ADC 缩放公式为 `scaled = (raw_sum * 255 + 480) // 960`。

```
pop = popcount(wl_latched)
正列 (j < 10):  bl_data[j] = (pop * 2 + j) & 8'hFF
负列 (j >= 10): bl_data[j] = (pop / 2 + (j-10)) & 8'hFF
```
- `popcount` 统计锁存后 `wl_latched` 中 1 的个数（0..64）。
