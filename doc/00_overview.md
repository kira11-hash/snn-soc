# 00_overview

## 项目一句话目标
构建一个最小可用的 SNN SoC（MVP），从配置寄存器到完成推理全流程可仿真跑通，并可在 Verdi 观察关键波形。

## 分层结构（文字 + ASCII 图）
分层目录与模块关系：

```
顶层 snn_soc_top
├─ bus/        简化总线与地址译码
├─ mem/        SRAM + FIFO
├─ reg/        寄存器 bank + FIFO 状态窗口
├─ dma/        DMA 引擎（data_sram -> input_fifo）
├─ snn/        CIM 控制器 + DAC/ADC + LIF 神经元 + CIM 行为模型
└─ periph/     UART/SPI/JTAG stub
```

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

## 时序流（简述）
1. 软件/测试台写寄存器，配置阈值与 timesteps。
2. DMA 从 data_sram 读取 2 个 word 拼成 49-bit wl_bitmap，写入 input_fifo。
3. cim_array_ctrl 启动后，每个 timestep 依次完成：DAC -> CIM -> ADC。
4. LIF 神经元更新膜电位并产生 spike，写入 output_fifo。
5. 软件/测试台从 output_fifo 读取 spike_id。

## 真实实现 vs stub/行为模型
- 真实实现：总线、SRAM、FIFO、寄存器、DMA、SNN 控制与 LIF 神经元。
- 行为模型：CIM Macro（仿真用可重复规则生成 bl_data）。
- Stub：UART/SPI/JTAG，无真实协议，仅占位并可读写寄存器。

## 关键参数表
| 参数 | 值 | 说明 |
|---|---:|---|
| NUM_INPUTS | 49 | 输入维度（7x7） |
| NUM_OUTPUTS | 10 | 输出类别数 |
| TIMESTEPS_DEFAULT | 20 | 默认时步 |
| DAC_LATENCY_CYCLES | 5 | DAC 延迟（仿真） |
| CIM_LATENCY_CYCLES | 10 | CIM 延迟（仿真） |
| ADC_LATENCY_CYCLES | 5 | ADC 延迟（仿真） |
