# 03_cim_if_protocol

## 接口端口列表
模块：`cim_macro_blackbox`

| 方向 | 端口 | 位宽 | 说明 |
|---|---|---:|---|
| input | clk | 1 | 时钟 |
| input | rst_n | 1 | 低有效复位 |
| input | wl_spike | NUM_INPUTS | 写线脉冲/位图 |
| input | dac_valid | 1 | DAC handshake：valid（保持到 ready） |
| output | dac_ready | 1 | DAC handshake：ready（为 1 表示锁存 wl_spike） |
| input | cim_start | 1 | CIM 计算启动脉冲 |
| output | cim_done | 1 | CIM 计算完成脉冲 |
| input | adc_start | 1 | ADC 启动脉冲 |
| output | adc_done | 1 | ADC 完成脉冲 |
| input | bl_sel | $clog2(NUM_OUTPUTS) | bitline 选择信号（时分复用 MUX 选择，0..NUM_OUTPUTS-1） |
| output | bl_data | 8 | 当前选中通道的 bitline 数据（单个 8 位值，由 bl_sel 选择） |

## pulse / level 定义
- dac_valid/dac_ready：**电平握手**。dac_valid 需保持为 1 直到 dac_ready 为 1。
- cim_start/adc_start：**单拍脉冲**，由控制器发出。
- cim_done/adc_done：**单拍脉冲**，由 Macro 返回。

## 典型时序（文字步骤）
1. 控制器拉高 dac_valid，wl_spike 同时稳定。
2. Macro 看到 dac_valid && dac_ready 后锁存 wl_spike。
3. 控制器在适当时机发出 cim_start 脉冲。
4. 等待 CIM_LATENCY_CYCLES 后，Macro 拉高 cim_done 单拍。
5. 控制器发出 adc_start 脉冲，开始时分复用 ADC 采样：
   - ADC 控制器循环设置 bl_sel = 0..NUM_OUTPUTS-1
   - 每次切换 bl_sel 后，等待 ADC_MUX_SETTLE_CYCLES（MUX 建立时间）
   - 然后采样 ADC_SAMPLE_CYCLES 个周期
   - Macro 根据 bl_sel 输出对应通道的 bl_data
   - 重复 NUM_OUTPUTS 次，完成所有通道采样
6. 所有通道采样完成后，ADC 控制器拉高 neuron_in_valid 并输出完整的 neuron_in_data。

## 行为模型 bl_data 生成规则
为保证仿真可重复，行为模型使用以下规则：

```
pop = popcount(wl_spike)
bl_data[j] = (pop + j*3) & 8'hFF
```

- popcount 统计 wl_spike 中 1 的个数。
- j 为输出通道索引 0..9。
