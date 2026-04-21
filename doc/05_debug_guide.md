# 05_debug_guide

## 1. 调试入口先分流

- 正常启动链路：`CPU -> bootloader -> SPI flash -> firmware`
- 救援链路：`JTAG rescue loader -> SRAM -> CPU 最小重启`

当前 `main` 分支上的 JTAG 不是 OpenOCD/GDB 调试链路，而是独立于 E203 vendor debug module 的最小救援通路：

- 只开放 `instr_sram / data_sram / weight_sram`
- 不开放 MMIO
- 支持 `cpu_reset_hold`
- `cpu_reset_hold` 只复位 CPU 核和 CPU 侧 `icb2simple_bridge`
- 不复位 SRAM / DMA / FIFO / SNN / UART / SPI / JTAG loader

## 2. Rescue JTAG 关键事实

- IR 宽度固定 `4`
- 指令固定：
  - `IDCODE = 4'h1`
  - `MEMACC = 4'h2`
  - `CPUCTL = 4'h3`
  - `BYPASS = 4'hF`
- `IDCODE` 固定返回 `0xE2030001`
- `MEMACC` 只允许访问：
  - `0x0000_0000 ~ 0x0000_3FFF` (`instr_sram`)
  - `0x0001_0000 ~ 0x0001_3FFF` (`data_sram`)
  - `0x0003_0000 ~ 0x0003_3FFF` (`weight_sram`)
- 所有 MMIO / 未映射地址统一返回 `done=1, err=1, rdata=0`
- JTAG 保持 4-wire，不新增 `TRST_n`

## 3. 主机工具

主机侧固定使用 [`scripts/jtag_rescue.py`](../scripts/jtag_rescue.py)。

常用命令：

```bash
python scripts/jtag_rescue.py idcode
python scripts/jtag_rescue.py hold-cpu
python scripts/jtag_rescue.py read 0x00000000 4
python scripts/jtag_rescue.py write 0x00010000 0x4A544147
python scripts/jtag_rescue.py load-imem fw/out/jtag_rescue_imem.hex
python scripts/jtag_rescue.py rescue-load fw/out/jtag_rescue_imem.hex
python scripts/jtag_rescue.py release-cpu
```

说明：

- 默认后端是 `pyftdi` bit-bang，需要主机安装 `pyftdi`
- 默认 `--idle-cycles=2048`
  - 这是覆盖硬件 `256 clk` 超时阈值的保守值
  - 目的是避免“读响应本身又形成新的 `UPDATE_DR`”带来的误判
- `cpu-state` 的读回会回写当前脚本维护的 `cpu_reset_hold` 状态，避免读操作带副作用

## 4. 推荐回归入口

- `cd sim && bash run_jtag_loader_icarus.sh`
  - 覆盖 `jtag_mem_loader` 单体 TAP/CDC/MEMACC/CPUCTL 协议
- `cd sim && bash run_jtag_rescue_top_icarus.sh`
  - 覆盖 rescue load、运行中 `weight_sram` 访问、`cpu_bridge_busy` 超时恢复、CPU 重启后 UART 输出
- `cd sim && bash run_e203_icarus.sh`
  - 覆盖正常 `SPI boot -> firmware` 主路径

## 5. 常见问题速查

### 5.1 `idcode` 不对

- 先确认 4-wire 接线：`TCK/TMS/TDI/TDO`
- 当前没有 `TRST_n` pad，复位 TAP 依赖 `TMS=1` 连续至少 5 个 TCK
- 项目 IDCODE 是自定义值 `0xE2030001`，不是官方厂商编码

### 5.2 `MEMACC` 一直超时

- 先提高 `--idle-cycles`
- 若 CPU 正在持续占用 bridge，硬件会在 `256 clk` 后自动触发 `jtag_timeout_force`
- 如果你只是灌程序，直接先执行 `hold-cpu`

### 5.3 写完 `instr_sram` 后 CPU 没从头启动

- 检查是否执行了 `hold-cpu -> load/verify -> release-cpu`
- 检查 `instr_sram` 是否从 `0x0000_0000` 开始写
- 检查启动依赖的数据区是否也一起写入，例如 `data_sram`

### 5.4 JTAG 能写 SRAM，但系统行为不对

- `weight_sram` 只保证可读写，不保证 CPU 立即消费新权重
- JTAG 不复位 DMA / FIFO / SNN 状态；这是设计目标，不是 bug
- 如果需要全局“干净环境”，应由重新启动后的固件做软件初始化

### 5.5 正常主线问题

- `neuron_in_data` 出现 `X`
  - 检查 `input_fifo` 是否为空
  - 确认 `data_sram` 已按 bit-plane 写入
- DMA 报错
  - 检查 `DMA_LEN_WORDS`
  - 检查 `DMA_SRC_ADDR` 是否 4B 对齐且落在 `data_sram`
- 推理流程不推进
  - 检查 `CIM_CTRL.START`
  - 检查 `STATUS.BUSY`
  - 检查 `timestep_counter`

## 6. 推荐观察信号

- JTAG rescue：`u_jtag_loader.*`、`jtag_req_pending`、`jtag_grant`、`jtag_timeout_force`
- CPU 局部复位：`cpu_reset_hold_effective`、`cpu_local_rst_n`、`cpu_bridge_busy`
- DMA：`u_dma.state/addr_ptr/words_rem/done_sticky/err_sticky/in_fifo_push`
- CIM 控制：`u_cim_ctrl.state/bitplane_shift/timestep_counter/busy/done_pulse`
- ADC：`u_adc.state/bl_sel/neuron_in_valid/adc_sat_high/adc_sat_low`
- LIF：`u_lif.membrane[*]`

## 7. V2 新增模块调试信号

### CIM 编程（`cim_program_ctrl`）

| 信号 | 说明 |
|------|------|
| `u_prog_ctrl.state` | 编程 FSM 状态（IDLE/SET/RESET/VERIFY/RETRY/DONE） |
| `u_prog_ctrl.prog_en` | 写入使能输出 |
| `u_prog_ctrl.erase_en` | 擦除使能输出 |
| `u_prog_ctrl.verify_en` | 验证使能输出 |
| `u_prog_ctrl.retry_cnt` | 当前重试计数 |
| `u_arbiter.grant` | 仲裁授权信号（0=推理，1=编程） |

### 多层调度（`layer_sequencer`）

| 信号 | 说明 |
|------|------|
| `u_layer_seq.state` | 调度 FSM 状态 |
| `u_layer_seq.current_layer` | 当前正在执行的层号 |
| `u_layer_seq.layer_done` | 当前层推理完成脉冲 |
| `u_lif_alu.neuron_idx` | LIF ALU 当前处理的神经元索引 |
| `u_lif_alu.running` | LIF ALU 正在遍历神经元 |
| `u_lif_alu.spike_mask` | 当前层 spike 输出掩码 |
| `u_lif_alu.spike_mask_valid` | spike_mask 有效脉冲 |
| `u_spike_fb.push` | spike_feedback 正在向 input_fifo 回注 |

### 多层推理问题排查

| 症状 | 可能原因 | 排查方法 |
|------|---------|---------|
| 第 0 层有输出但第 1 层无输出 | spike_feedback 回注失败 | 查 `u_spike_fb.push` 和 input_fifo count |
| 所有层输出为 0 | 层描述符配置错误 | 查 `u_layer_seq.current_layer` 和 lif_alu threshold |
| `MULTILAYER_SMOKE_PASS` 失败 | DMA word count 不足 | 确认 DMA_LEN_WORDS = frames × PIXEL_BITS × 2 |
