# CIM Macro 接口规格（简化版）

> **⚠ 本文件为早期草稿，已过时。权威接口文档请参考 `doc/03_cim_if_protocol.md` 和 `doc/08_cim_analog_interface.md`。**
> **以下内容已更新至 2026-02-06 版本，与 RTL 代码一致。**

本文件描述 cim_macro_blackbox 的数字接口与仿真行为，内容与当前代码保持一致。
**参数口径**：接口位宽与时序参数以 `rtl/top/snn_soc_pkg.sv` 为准，若与文档不一致以 pkg 为准。

---

## 1. 接口信号
| 信号 | 方向 | 位宽 | 说明 |
| --- | --- | --- | --- |
| clk | 输入 | 1 | 系统时钟 |
| rst_n | 输入 | 1 | 异步复位，低有效 |
| wl_spike | 输入 | 64 | 单个 bit-plane，64 维特征并行（8×8 离线投影后） |
| dac_valid | 输入 | 1 | DAC 握手 valid |
| dac_ready | 输出 | 1 | DAC 握手 ready，表示可锁存 wl_spike |
| cim_start | 输入 | 1 | CIM 计算启动脉冲 |
| cim_done | 输出 | 1 | CIM 计算完成脉冲 |
| adc_start | 输入 | 1 | ADC 单通道采样启动 |
| adc_done | 输出 | 1 | ADC 单通道采样完成 |
| bl_sel | 输入 | 5 | 通道选择 0..19（Scheme B: 0-9 正列, 10-19 负列） |
| bl_data | 输出 | 8 | 当前通道 8-bit ADC 输出 |

---

## 2. 时序流程
1. 数字侧拉高 dac_valid，同时保持 wl_spike 稳定。
2. 当 dac_valid 与 dac_ready 同时为 1 时，宏锁存 wl_spike。
3. 数字侧发出 cim_start，宏在固定延迟后给出 cim_done。
4. ADC 时分复用（Scheme B，20 通道）：
   - 对每个通道依次设置 bl_sel（0..19）
   - 等待 MUX 建立时间
   - 触发 adc_start
   - 等待 adc_done（延迟由 ADC_SAMPLE_CYCLES 决定）
   - 读取该通道的 bl_data[7:0]
5. 20 路原始数据齐全后，ADC 控制器执行数字差分减法：diff[i] = raw[i] - raw[i+10]（i=0..9）

---

## 3. wl_spike 数据格式
- wl_spike 表示同一子时间步的 64 维特征的某一 bit-plane。
- bit[i]=1 表示第 i 维特征在该位为 1。
- 一帧共有 8 个 bit-plane，顺序为 MSB 到 LSB。
- V1 输入是离线预处理后的 64 维特征向量（proj_sup_64: 784→64），不是原始像素。

---

## 4. 行为模型规则（仿真）
当前行为模型不使用真实权重矩阵，采用可复现的简化规则（Scheme B）：

```
pop = popcount(wl_spike)  // 0-64
正列 (j < 10):  bl_data[j] = (pop * 2 + j) & 8'hFF
负列 (j >= 10): bl_data[j] = (pop/2 + (j-10)) & 8'hFF
```

含义：
- popcount 统计 64 维输入中 1 的数量。
- Scheme B 差分结构：正列产生较高值，负列产生较低值。
- 数字侧在 ADC 控制器中执行差分减法：diff[i] = raw[i] - raw[i+10]（i=0..9），输出 10 路 signed 9-bit 值。

---

## 5. 注意事项
- 行为模型在 adc_done 时更新内部结果，bl_data 由 bl_sel 选择输出。
- 将来替换真实 CIM 宏时，接口保持不变即可。
