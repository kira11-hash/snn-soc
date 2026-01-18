# 02_reg_map

## 寄存器语义说明（W1P / W1C）
- W1P（Write-1 Pulse）：写 1 产生单拍脉冲，硬件自动清 0。
- W1C（Write-1 Clear）：写 1 清除 sticky 位；读取不会清零。

## reg_bank（base = 0x4000_0000）
| Offset | 名称 | 字段 | 位 | 读写 | 默认值 | 说明 |
|---|---|---|---|---|---|---|
| 0x00 | NEURON_THRESHOLD | threshold | [15:0] | RW | 16'd200 | LIF 阈值 |
| 0x04 | TIMESTEPS | timesteps | [7:0] | RW | 8'd20 | 推理时步数 |
| 0x08 | NUM_INPUTS | num_inputs | [15:0] | RO | 16'd49 | 输入维度 |
| 0x0C | NUM_OUTPUTS | num_outputs | [7:0] | RO | 8'd10 | 输出类别 |
| 0x10 | RESET_MODE | reset_mode | [0] | RW | 1'b0 | 0=soft reset, 1=hard reset |
| 0x14 | CIM_CTRL | START | [0] | W1P | 0 | 写 1 启动一次推理 |
|  |  | RESET | [1] | W1P | 0 | 写 1 软复位内部状态 |
|  |  | DONE | [7] | RO/W1C | 0 | 推理结束置 1，写 1 清零 |
| 0x18 | STATUS | BUSY | [0] | RO | 0 | 控制器忙标志 |
|  |  | IN_FIFO_EMPTY | [1] | RO | 0 | 输入 FIFO 空 |
|  |  | IN_FIFO_FULL | [2] | RO | 0 | 输入 FIFO 满 |
|  |  | OUT_FIFO_EMPTY | [3] | RO | 0 | 输出 FIFO 空 |
|  |  | OUT_FIFO_FULL | [4] | RO | 0 | 输出 FIFO 满 |
|  |  | timestep_counter | [15:8] | RO | 0 | 当前时步计数 |
| 0x1C | OUT_FIFO_DATA | spike_id | [3:0] | RO | 0 | 读一次弹出一个 spike_id，空则返回 0 |
| 0x20 | OUT_FIFO_COUNT | count | [15:0] | RO | 0 | 输出 FIFO 当前计数 |

## dma_regs（base = 0x4000_0100）
| Offset | 名称 | 字段 | 位 | 读写 | 默认值 | 说明 |
|---|---|---|---|---|---|---|
| 0x00 | DMA_SRC_ADDR | addr | [31:0] | RW | 0 | DMA 源地址（byte） |
| 0x04 | DMA_LEN_WORDS | len | [31:0] | RW | 0 | 以 32-bit word 计数，必须为偶数 |
| 0x08 | DMA_CTRL | START | [0] | W1P | 0 | 写 1 启动 DMA |
|  |  | DONE | [1] | RO/W1C | 0 | 传输完成置 1，写 1 清零 |
|  |  | ERR | [2] | RO/W1C | 0 | 长度为奇数时置 1，写 1 清零 |
|  |  | BUSY | [3] | RO | 0 | DMA 正在运行 |

## fifo_regs（base = 0x4000_0400）
| Offset | 名称 | 字段 | 位 | 读写 | 默认值 | 说明 |
|---|---|---|---|---|---|---|
| 0x00 | IN_FIFO_COUNT | count | [15:0] | RO | 0 | 输入 FIFO 计数 |
| 0x04 | OUT_FIFO_COUNT | count | [15:0] | RO | 0 | 输出 FIFO 计数 |
| 0x08 | FIFO_STATUS | in_empty | [0] | RO | 0 | 输入 FIFO 空 |
|  |  | in_full | [1] | RO | 0 | 输入 FIFO 满 |
|  |  | out_empty | [2] | RO | 0 | 输出 FIFO 空 |
|  |  | out_full | [3] | RO | 0 | 输出 FIFO 满 |
