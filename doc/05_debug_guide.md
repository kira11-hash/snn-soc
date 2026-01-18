# 05_debug_guide

## Verdi 推荐观察信号列表
- 总线：`bus_if.m_valid/m_write/m_addr/m_wdata/m_ready/m_rvalid/m_rdata`
- DMA：`u_dma.state/addr_ptr/words_rem/done_sticky/err_sticky/in_fifo_push`
- FIFO：`u_input_fifo.count/empty/full`、`u_output_fifo.count/empty/full`
- CIM 控制器：`u_cim_ctrl.state/timestep_counter/wl_valid_pulse/cim_start_pulse/adc_kick_pulse`
- Macro：`u_macro.dac_valid/dac_ready/cim_start/cim_done/adc_start/adc_done/bl_data`
- LIF：`u_lif.membrane[*]/out_fifo_push/out_fifo_wdata`

## 常见 bug 与现象
1. DONE 不来：可能卡在 STEP_DAC/STEP_CIM/STEP_ADC。
2. input_fifo 空：DMA 没启动或 DMA_LEN_WORDS 写错。
3. bus_read 卡住：m_rvalid 没拉高，可能时序没对齐。
4. DMA err：DMA_LEN_WORDS 为奇数。

## 如何定位
- DONE 不来：看 `u_cim_ctrl.state` 是否卡住；再看 `dac_done_pulse/cim_done/adc_done` 是否产生。
- FIFO 空：检查 `u_dma.state` 是否在 ST_RD0/ST_RD1/ST_PUSH；检查 `in_fifo_push` 是否发生。
- 总线读写异常：观察 `bus_if.m_valid` 到 `m_ready/m_rvalid` 的 1-cycle 响应是否匹配。
- DMA err：检查 `dma_len_words` 最低位。
