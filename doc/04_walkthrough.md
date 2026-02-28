# 04_walkthrough

**参数口径**：默认参数与时序常量以 `rtl/top/snn_soc_pkg.sv` 为准，本文中的数值与示例仅作说明。

## Bit-plane 输入与时序
- V1 输入为离线预处理后的 64 维特征向量（proj_sup_64: 784→64），每维 8bit。
- 同一子时间步并行送 64 维特征的第 x 位（NUM_INPUTS=64），顺序 MSB->LSB。
- `bitplane_shift` 表示当前位平面（MSB=7 ... LSB=0）。

## 一次完整推理流程（TB 视角）
1. 复位释放。
2. 配置寄存器：写 `THRESHOLD`、写 `TIMESTEPS`（帧数）。
3. 写 data_sram：
   - 每个 bit-plane 为 64-bit（NUM_INPUTS=64），拆成 2 个 32-bit word 写入。
   - 写入顺序：frame0 的 MSB->LSB，再 frame1 的 MSB->LSB。
   - **MVP**：由 TB 直接写入 data_sram。
   - **V1**：CPU 通过 SPI 从外部 Flash 读数据，再写入 data_sram（PIO），后续可升级为 SPI→DMA→SRAM。
4. 启动 DMA：
   - `DMA_SRC_ADDR` 指向 data_sram 基址
   - `DMA_LEN_WORDS = frames * PIXEL_BITS * 2`
   - 写 `DMA_CTRL.START`
5. DMA 将 bit-plane 依次写入 input_fifo。
6. 写 `CIM_CTRL.START` 启动推理。
7. cim_array_ctrl 状态机循环：
   - `ST_FETCH`：从 input_fifo 取 1 个 bit-plane
   - `ST_DAC`：锁存 wl_spike，等待固定 `DAC_LATENCY_CYCLES`（无 `dac_ready` 握手）
   - `ST_CIM`：等待 cim_done
   - `ST_ADC`：按 20 通道触发 ADC，等待每次 adc_done；ADC 控制器完成数字差分减法后产生 neuron_in_valid
   - `ST_INC`：bitplane_shift--；若到 LSB 则帧计数++
8. done_sticky 置 1 后结束。

**补充**：当 `TIMESTEPS=0` 时，控制器立即 done，不进入推理流程。

## DMA 2 word 拼接 64-bit
- word0 = wl[31:0]
- word1 = wl[63:32]

## LIF 累加（Scheme B 有符号）
- `neuron_in_valid` 到来时：
  - `signed_in = $signed(neuron_in_data[i])` （9-bit 有符号差分值）
  - `addend = sign_extend(signed_in, 32) <<< bitplane_shift`（算术左移）
  - 累加到有符号膜电位，超过正阈值产生 spike
