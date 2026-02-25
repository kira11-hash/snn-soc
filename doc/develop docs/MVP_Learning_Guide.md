# SNN SoC MVP 学习指南

适用对象：第一次接触 SoC 或 SNN 的同学  
前置知识：Verilog 或 SystemVerilog 基础，数字电路基础  
目标：读懂架构，能修改并验证功能  

**参数口径**：本文涉及的默认参数与时序数值以 `rtl/top/snn_soc_pkg.sv` 为准，若与文档不一致以 pkg 为准。  

---

## 学习顺序
1. README.md（整体概念与运行方式）
2. doc/00_overview.md（架构与数据流）
3. doc/01_memory_map.md（地址映射与 data_sram 布局）
4. doc/02_reg_map.md（寄存器与控制流程）
5. doc/03_cim_if_protocol.md（CIM 接口时序）
6. doc/04_walkthrough.md（完整推理流程）
7. doc/05_debug_guide.md（常见问题排查）

---

## 阶段 A：整体认知（Day 1）
阅读并回答：
- SNN SoC 的完整数据流是什么？
- TIMESTEPS 的含义是什么？为什么是“帧数”？
- bit-plane 是什么？为什么要 MSB 到 LSB？

检验标准：
- 能写出 data_sram -> DMA -> input_fifo -> DAC -> CIM -> ADC -> LIF -> output_fifo
- 能解释 TIMESTEPS=0 时立即 done 的行为

---

## 阶段 B：理解关键模块（Day 2-3）
按顺序读代码：
1. rtl/top/snn_soc_pkg.sv（参数）
2. rtl/top/snn_soc_top.sv（连线）
3. rtl/reg/reg_bank.sv（寄存器）
4. rtl/dma/dma_engine.sv（DMA）
5. rtl/snn/cim_array_ctrl.sv（控制 FSM）
6. rtl/snn/adc_ctrl.sv（通道轮询与 adc_done）
7. rtl/snn/lif_neurons.sv（膜电位累加）

检验标准：
- 能画出 cim_array_ctrl 状态机
- 能说明 adc_ctrl 为什么需要等待每个通道的 adc_done
- 能指出 DMA 的对齐与越界检查条件

---

## 阶段 C：理解 Testbench（Day 4）
阅读文件：
- tb/top_tb.sv
- tb/tb_lib/bus_master_tasks.sv

当前默认流程：
1) 写 THRESHOLD（示例：THRESHOLD_DEFAULT）  
2) 写 TIMESTEPS = 5（frames）  
3) 写 data_sram（frames * PIXEL_BITS 个 bit-plane）  
4) 启动 DMA（DMA_LEN_WORDS = frames * PIXEL_BITS * 2）  
5) 启动 CIM 推理  
6) 读取输出 FIFO  

检验标准：
- 能解释 data_sram 的 2 word 拼接规则
- 能算出 DMA_LEN_WORDS

---

## 实验（推荐）
实验 1：修改帧数  
- 把 TIMESTEPS 改为 3  
- 预期：推理更快完成，输出 spike 可能更少  

实验 2：修改阈值  
- 把 THRESHOLD 改为 4096 或 16384  
- 预期：阈值低更容易产生 spike，阈值高更不容易产生 spike  

实验 3：修改 ADC settle  
- 修改 ADC_MUX_SETTLE_CYCLES  
- 预期：单通道采样流程变慢或变快  

---

## 常见问题排查
- neuron_in_data 出现 X：DMA 未写入或 FIFO 为空
- DMA 报错：长度为奇数，或地址不对齐，或越界
- 推理不推进：CIM_CTRL.START 未拉高，或 TIMESTEPS=0

---

## 学习方法建议
- 每看完一个模块，写下三句话：输入是什么、输出是什么、关键时序是什么
- 读完一个阶段，再跑一次仿真验证理解
