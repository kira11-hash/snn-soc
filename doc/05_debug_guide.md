# 05_debug_guide

## 常见问题速查
1. **neuron_in_data 出现 X**
   - 检查 input_fifo 是否为空（DMA 未启动或长度错误）。
   - 确认 data_sram 已按 bit-plane 写入（2 word/plane）。
   - 看 TB 断言：`neuron_in_valid` 有效拍不应包含 X。

2. **DMA 报错（ERR 置位）**
   - `DMA_LEN_WORDS` 为奇数。
   - `DMA_LEN_WORDS` 为 0 时会直接 DONE。
   - `DMA_SRC_ADDR` 未 4B 对齐。
   - `DMA_SRC_ADDR` 应落在 data_sram 区间。
   - `SRC+LEN-1` 越界 data_sram。

3. **推理流程不推进**
   - `CIM_CTRL.START` 是否写 1。
   - `STATUS.BUSY` 是否拉高。
   - `timestep_counter` 是否随帧递增。

4. **bit-plane 顺序错误**
   - 观察 `bitplane_shift` 应从 7 递减到 0。
   - data_sram 的写入顺序应为 MSB->LSB。

5. **ADC 时分复用异常（Scheme B）**
   - 检查 20 个通道是否都有 `adc_start`/`adc_done`。
   - `bl_sel` 应随通道递增 0..19（ADC_CHANNELS=20）。
   - 差分结果：`neuron_in_data[i]` 为有符号 9-bit 值。

6. **ADC 饱和诊断**
   - 推理完成后读取 `REG_ADC_SAT_COUNT`（0x4000_0028）。
   - `[15:0]` = sat_high（bl_data == 0xFF 次数），`[31:16]` = sat_low（bl_data == 0 次数）。
   - 若 sat_high 或 sat_low 偏多，说明模拟前端增益偏大/偏小，需调整。
   - 每次推理启动时自动清零，无需手动复位。

7. **TIMESTEPS=0 行为**
   - 期望立即 done，不进入推理流程。

## 推荐观察信号
- DMA：`u_dma.state/addr_ptr/words_rem/done_sticky/err_sticky/in_fifo_push`
- CIM 控制：`u_cim_ctrl.state/bitplane_shift/timestep_counter/busy/done_pulse`
- ADC：`u_adc.state/bl_sel/neuron_in_valid/adc_sat_high/adc_sat_low`
- LIF：`u_lif.membrane[*]`（必要时）
