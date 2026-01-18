# 04_walkthrough

## 从 reset 到 done 的逐拍叙述（按模块）
1. `rst_n=0`：所有寄存器/FIFO/状态清零。
2. `rst_n=1`：寄存器保持默认值（threshold=200，timesteps=20）。
3. 软件或 TB 通过总线写入阈值与 timesteps。
4. TB 把 5 个 timestep 的 wl_bitmap 写入 data_sram（每个 timestep 占 2 个 word）。
5. TB 写 DMA_CTRL.START，DMA 读取 data_sram 并把 49-bit wl_bitmap 推入 input_fifo。
6. TB 写 CIM_CTRL.START，cim_array_ctrl 开始按 timesteps 循环。
7. 每个 timestep：
   - STEP_FETCH：读取 input_fifo（若空则用全 0）。
   - STEP_DAC：触发 DAC，等待 dac_done_pulse。
   - STEP_CIM：触发 cim_start，等待 cim_done。
   - STEP_ADC：触发 adc_start，等待 adc_done，并拉高 neuron_in_valid。
   - STEP_INC：timestep++，若到达终止则 DONE。
8. DONE：done_sticky 置 1，等待软件清零。

## cim_array_ctrl 状态做什么、等待什么
- IDLE：等待 start_pulse。
- STEP_FETCH：从 input_fifo 取 wl_bitmap。
- STEP_DAC：发 wl_valid_pulse，等 dac_done_pulse。
- STEP_CIM：发 cim_start_pulse，等 cim_done。
- STEP_ADC：发 adc_kick_pulse，等 neuron_in_valid。
- STEP_INC：timestep++，决定回到 STEP_FETCH 或进入 DONE。
- DONE：done_pulse 单拍，回 IDLE。

## DMA 如何拼 2 个 word 成 49-bit
- word0 = wl[31:0]
- word1 = wl[48:32] 放在 word1[16:0]
- DMA 每读取 2 个 word 后组合：
  `wl_bitmap = {word1[16:0], word0}`
- 拼好后 push 到 input_fifo。

## output_fifo 如何按顺序 push spike_id
- lif_neurons 在 neuron_in_valid 时计算 10 个膜电位。
- 若超过阈值产生 spike，按 i=0..9 的顺序写入内部队列。
- 之后每拍尝试从队列取 1 个 spike_id 写入 output_fifo，保持顺序。
