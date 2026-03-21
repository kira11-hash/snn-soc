# 04_walkthrough

**参数口径**：默认参数与时序常量以 `rtl/top/snn_soc_pkg.sv` 为准，本文中的数值与示例仅作说明。

## Bit-plane 输入与时序
- V1 输入为离线预处理后的 64 维特征向量；当前默认口径为 `avgpool8x8`，但 RTL 本身仅约束为 64 维、每维 8bit，不在硬件中绑定具体前处理算法。
- 同一子时间步并行送 64 维特征的第 x 位（NUM_INPUTS=64），顺序 MSB->LSB。
- `bitplane_shift` 表示当前位平面（MSB=7 ... LSB=0）。

## 三条常用执行路径

### 1. 纯 TB 直驱路径

- 入口：`run_icarus_light.sh`、`run_icarus_weighted.sh`、`run_sample_align.sh`
- 特点：TB 直接发总线写 MMIO / SRAM，不依赖 E203 先跑起来。
- 用途：最快验证 DMA、CIM 控制器、ADC、LIF 和输出 FIFO。

### 2. E203 启动链路径

- 入口：`run_e203_icarus.sh`
- 流程：`bootloader @ instr_sram -> SPI RDID / READ -> app load to data_sram -> jump -> UART printf -> firmware 配置 DMA + 推理`
- 用途：验证 CPU、SPI 启动、固件寄存器访问和推理链是否贯通。

### 3. JTAG rescue 路径

- 入口：`run_jtag_rescue_top_icarus.sh`
- 流程：Python/主机侧协议 -> `jtag_mem_loader` -> 写 `instr_sram / data_sram / weight_sram` -> 可选释放 CPU 局部复位 -> 观察 UART / 读回校验
- 用途：验证“无正常 SPI boot 时仍能救援”的系统级可恢复性。

## 一次完整推理流程（寄存器 / DMA / FSM 视角）

1. 复位释放。
2. 配置主寄存器：
   - 写 `THRESHOLD`
   - 写 `TIMESTEPS`
   - 必要时写 `RESET_MODE`
   - 若做纯数字链路自检，可写 `CIM_TEST`
3. 写 `data_sram`：
   - 每个 bit-plane 为 64-bit（NUM_INPUTS=64），拆成 2 个 32-bit word 写入。
   - 写入顺序：frame0 的 MSB->LSB，再 frame1 的 MSB->LSB。
   - **MVP / 直驱 TB**：由 TB 直接写入 data_sram。
   - **E203 路径**：CPU 通过 SPI 从外部 Flash 读数据，再写入 data_sram（当前为 PIO，后续可升级为 SPI→DMA→SRAM）。
4. 启动 DMA：
   - `DMA_SRC_ADDR` 指向 data_sram 基址
   - `DMA_LEN_WORDS = frames * PIXEL_BITS * 2`
   - `DMA_DST_SEL = INPUT_FIFO`
   - 写 `DMA_CTRL.START`
5. 轮询 DMA 完成：
   - 观察 `DMA_CTRL.DONE / ERR / BUSY`
   - 必要时读 `IN_FIFO_COUNT`，确认 bit-plane 已经入队
6. 写 `CIM_CTRL.START` 启动推理。
7. `cim_array_ctrl` 状态机循环：
   - `ST_FETCH`：从 input_fifo 取 1 个 bit-plane
   - `ST_DAC`：锁存 `wl_spike`，等待固定 `DAC_LATENCY_CYCLES`（无 `dac_ready` 握手）
   - `ST_CIM`：等待 `cim_done`
   - `ST_ADC`：按 20 通道触发 ADC，等待每次 `adc_done`；ADC 控制器完成数字差分减法后产生 `neuron_in_valid`
   - `ST_INC`：`bitplane_shift--`；若到 LSB 则帧计数++
8. 推理结束后观察：
   - `CIM_CTRL.DONE` sticky
   - `STATUS.BUSY=0`
   - `OUT_FIFO_COUNT`
   - `ADC_SAT_COUNT`
   - `DBG_CNT_0 / DBG_CNT_1`
9. 软件或 TB 读取 `OUT_FIFO_DATA` 取走 spike 序列。

**补充**：当 `TIMESTEPS=0` 时，控制器立即 done，不进入推理流程。

## DMA 2 word 拼接 64-bit
- word0 = wl[31:0]
- word1 = wl[63:32]

## LIF 累加（Scheme B 有符号）
- `neuron_in_valid` 到来时：
  - `signed_in = $signed(neuron_in_data[i])` （9-bit 有符号差分值）
  - `addend = sign_extend(signed_in, 32) <<< bitplane_shift`（算术左移）
  - 累加到有符号膜电位，超过正阈值产生 spike
- 膜电位复位行为由 `RESET_MODE`（reg offset 0x10）配置：
  - `0`（soft，默认）：`V = V - Vth`，保留残余电位，当前工程冻结默认
  - `1`（hard）：`V = 0`，可选项，经建模验证与 soft 等效（见 README §建模定版补充）

## bring-up 时最值得看的观察点

- DMA 不结束：先查 `DMA_SRC_ADDR` 是否 4B 对齐，再查 `DMA_LEN_WORDS` 是否满足 `INPUT_FIFO` 的偶数字要求。
- DMA 结束但 `OUT_FIFO_COUNT=0`：优先切到 `CIM_TEST` 模式，用已知 `test_data_pos != test_data_neg` 的假响应排除模拟宏与权重因素。
- `ADC_SAT_COUNT` 明显增大：说明当前模拟/数字接口接近满量程，阈值与 ADC 动态范围需要重新核。
- `DBG_CNT_0.cim_cycle_cnt` 异常偏大：优先检查 `cim_done`、`adc_done` 和 `input_fifo` 是否出现等待。
- 读 `OUT_FIFO_DATA` 时要记住“单次总线读请求 = 消费一个条目”；它不是静态观察寄存器。

## 对应验证入口

- 看纯数字主链：`run_icarus_light.sh`
- 看真实权重与样本对齐：`run_icarus_weighted.sh`、`run_sample_align.sh`
- 看 CPU + 启动链：`run_e203_icarus.sh`
- 看救援路径：`run_jtag_rescue_top_icarus.sh`
