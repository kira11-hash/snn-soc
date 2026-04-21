# 03_cim_if_protocol

**版本**：v3.0（V2 编程接口补全）
**日期**：2026-04-18
**模块**：`cim_macro_blackbox`（推理）、`cim_program_ctrl`（V2 编程）
**参数口径**：与时序相关的默认参数以 `rtl/top/snn_soc_pkg.sv` 为准，本文数值仅作说明，若不一致以 pkg 为准。
**架构说明**：本文描述的是数字芯片内部的 `snn_soc_top` 与行为模型 `cim_macro_blackbox` 之间的**内部并行接口**。实际流片后，数字芯片与模拟 CIM 芯片为独立封装，通过 PCB 互联，使用 `wl_mux_wrapper` 提供的**外部复用接口**（数字芯片 72-pad 预算中的 V1 baseline 子集）。详见 `doc/08_cim_analog_interface.md` §1.3 与 `doc/15_asic_pad_map.md`。

## 接口信号
| 方向 | 信号 | 位宽 | 类型 | 说明 |
|---|---|---:|---|---|
| input | wl_spike | NUM_INPUTS(=64) | 数据 | 单个 bit-plane（64 路并行），同一子时间步的特征向量第 x 位 |
| input | dac_valid | 1 | 脉冲 | 单拍触发信号；行为模型在该拍锁存 `wl_spike`（真实芯片由 `wl_latch` 时序控制） |
| input | cim_start | 1 | 脉冲 | CIM 计算启动 |
| output | cim_done | 1 | 脉冲 | CIM 计算完成 |
| input | adc_start | 1 | 脉冲 | ADC 启动（**仅内部仿真接口**，不在外部 pad 接口中；流片后由 `snn_soc_top` 内部固定延迟生成 `adc_done`） |
| output | adc_done | 1 | 脉冲 | ADC 完成（**仅内部仿真接口**，同上） |
| input | bl_sel | $clog2(MAX_BL_SCAN)(=7) | 控制 | bitline 选择。**V1 默认扫描 20 路**（`bl_scan_count=ADC_CHANNELS=20, use_scan_cfg=0`，Scheme B: 0-9 正列, 10-19 负列）；**V2 可配置最大扫描 128 路**（`use_scan_cfg=1` 时由 `bl_scan_count` 寄存器/层描述符决定，Scheme B 要求 bl_count 为偶数，输出神经元数 = bl_count/2） |
| output | bl_data | ADC_BITS(=8) | 数据 | 当前通道的 8-bit ADC 输出 |

## 时序与触发
1. `wl_mux_wrapper` 用 `wl_latch` 完成 8 组 WL 复用发送。
2. `dac_ctrl` 在 `wl_valid_pulse` 到来后锁存 `wl_bitmap` 到 `wl_spike`，并发出 `dac_valid` 单拍。
3. 行为模型在 `dac_valid` 单拍时锁存 `wl_spike`；真实芯片侧不依赖 `dac_ready`，采用固定时序。
4. 控制器等待固定 `DAC_LATENCY_CYCLES` 后发出 `cim_start`，Macro 经过 `CIM_LATENCY_CYCLES` 后拉高 `cim_done`。
5. 控制器发出 `adc_start`，进入 ADC 时分复用采样。

## ADC 时分复用（Scheme B）

### V1 默认（`use_scan_cfg=0`）
- `bl_sel` 依次为 0..ADC_CHANNELS-1（共 20 通道）。
- 每次切换后等待 `ADC_MUX_SETTLE_CYCLES`。
- 对每个通道触发一次 `adc_start`，等待 `adc_done` 后锁存该通道的 `bl_data`。
- 20 路原始数据齐全后，ADC 控制器执行数字差分减法：`diff[i] = raw[i] - raw[i+10]`（i=0..9）。
- 输出 10 路有符号差分数据（NEURON_DATA_WIDTH=9 bit）+ `neuron_in_valid`。

### V2 可配扫描（`use_scan_cfg=1`）
- 数字侧扫描通道数 `eff_scan_count = bl_scan_count`（来自 layer_sequencer 的 `ctrl_bl_scan_count`），最大 `MAX_BL_SCAN=128`；固件应配置偶数 bl_count，保证 pos/neg 成对。
- `bl_sel` 依次为 0..eff_scan_count-1，达到 `eff_scan_count-1` 时进入 ST_DONE。
- 差分减法：`diff[i] = raw[i] - raw[i + eff_scan_count/2]`，i=0..(eff_scan_count/2 - 1)，写入 `neuron_in_data_wide[i]`，其余填 0。
- 支持多层网络按层切换扫描数，例如 64→32→16→10 网络分别需要 bl_scan_count = 64/32/20/20。

**行为模型说明**：当前 CIM 行为模型在 `adc_done` 时更新所有 20 通道的内部结果，`bl_data` 由 `bl_sel` 选择输出。正列 (0..9) 产生较高值，负列 (10..19) 产生较低值。`adc_done` 的延迟由 `ADC_SAMPLE_CYCLES` 决定。

## 行为模型 bl_data 生成规则

> **注**：以下规则仅适用于数字芯片内的仿真行为模型（`cim_macro_blackbox.sv`）。流片后真实模拟芯片返回的 `bl_data` 由 RRAM 阵列的物理权重决定，公式不同。带权重仿真使用 `sim/models/cim_macro_blackbox_weighted_icarus.sv`，其 ADC 缩放公式为 `scaled = (raw_sum * 255 + 480) // 960`。

```
pop = popcount(wl_latched)
正列 (j < 10):  bl_data[j] = (pop * 2 + j) & 8'hFF
负列 (j >= 10): bl_data[j] = (pop / 2 + (j-10)) & 8'hFF
```
- `popcount` 统计锁存后 `wl_latched` 中 1 的个数（0..64）。

## V2 CIM 编程接口（`cim_program_ctrl`）

> 以下接口用于 RRAM 阵列的写入/擦除/验证，由 V2 `cim_program_ctrl` 模块驱动。通过 `cim_macro_arbiter` 与推理路径互斥访问 CIM macro。

### 编程控制信号（V2 当前接口，与 `rtl/snn/cim_program_ctrl.sv` 一致）

| 方向 | 信号 | 位宽 | 说明 |
|---|---|---:|---|
| output | prog_wl_spike | 64 | 字线向量（逐 cell：one-hot；全阵列擦除：全 1） |
| output | prog_dac_valid | 1 | 编程脉冲期间保持高（自计时，由 `ST_PULSE_HOLD` 控制） |
| output | prog_cim_start | 1 | CIM 启动脉冲（单拍） |
| input  | prog_cim_done | 1 | CIM 完成反馈（自计时模式下不使用） |
| output | prog_adc_start | 1 | 验证读回 ADC 启动 |
| input  | prog_adc_done | 1 | 验证读回 ADC 完成 |
| output | prog_bl_sel | $clog2(MAX_BL_SCAN)=7 | 目标列（V2 与 arbiter/ADC 同宽） |
| input  | prog_bl_data | 8 | 读回电导量化值（ADC） |
| output | prog_en | 1 | 写入使能（SET，正向电压） |
| output | erase_en | 1 | 擦除使能（RESET，反向电压） |
| output | verify_en | 1 | 验证使能（小电压读回） |

> **去除的旧信号**：`prog_done` 和 `verify_pass` 已不再作为模拟侧反馈——脉冲宽度由数字侧寄存器 `REG_PROG_PULSE_WIDTH`/`REG_PROG_ERASE_WIDTH` 自计时控制；验证判据由数字侧基于 `prog_bl_data` 与 `target_level` 窗口比较产生，无需模拟侧返回 pass/fail。
>
> **V2 新引出到 chip_top pad 的使能信号**：`prog_en_pad` / `erase_en_pad` / `verify_en_pad`，用于告知模拟侧当前操作类型（见 `rtl/top/chip_top.sv`）。

### 编程时序（自计时 + Write-Verify 循环）

```
1. 软件写 REG_PROG_ROW / REG_PROG_COL / REG_PROG_PULSE_WIDTH /
           REG_PROG_ERASE_WIDTH / REG_PROG_CTRL（LEVEL、ERASE、FULL_ARRAY、START）
2. cim_program_ctrl 锁存 prog_row/prog_col/prog_level/脉宽（D1-003）并进入 ST_SETUP
3. ST_SETUP → ST_PULSE：拉 prog_cim_start，加载 pulse_width_cnt=latched_pulse_width
4. ST_PULSE_HOLD：prog_dac_valid 保持高，倒计时到 0
5. 全阵列擦除路径：跳过 verify，直接 ST_PASS → ST_DONE
   逐 cell 路径：
   5a. ST_READBACK：发 prog_adc_start、verify_en=1
   5b. ST_RB_WAIT：等 prog_adc_done，捕获 prog_bl_data 到 readback_val
   5c. ST_VERIFY：
        - 擦除：readback_val ≤ 1 → ST_PASS，否则 ST_RETRY
        - 写入：|readback_val - target_level * 16| ≤ 2 → ST_PASS，否则 ST_RETRY（D1-001）
   5d. ST_RETRY：retry_count < target_retry_limit 则回 ST_SETUP；否则 ST_FAIL
6. ST_DONE：prog_done_pulse=1（单拍），PROG_STATUS.DONE sticky=1
```

**地址越界保护（D1-004 + D2-006 + D3-FIX）**：
- 全阵列擦除（`prog_full_array=1`）：忽略 `prog_row` / `prog_col`，直接驱动全 WL 高电平
- 逐 cell 操作（写入 or 逐 cell 擦除）：若 `prog_col ≥ PROG_COLS(=20)` **或** `prog_row ≥ PROG_ROWS(=64)`，直接跳 ST_FAIL
- 内部使用 `int'()` 强制转换避免位宽截断（见 D3-FIX：`6'(PROG_ROWS)=6'(64)` 会被截断成 0）
**D1-005 互锁**：`REG_CIM_CTRL.START` 在 `prog_busy=1` 时被屏蔽；`REG_PROG_CTRL.START` 在 `snn_busy=1` 时被屏蔽。

### 仲裁策略（`cim_macro_arbiter`）

- 推理路径和编程路径互斥：同一时刻只有一方可访问 CIM macro
- 默认推理优先：推理进行中的编程请求被挂起，推理完成后自动授权
- 编程期间推理请求被阻塞，直到编程完成释放

### 仲裁超时行为

`cim_macro_arbiter` 基于 `prog_busy` 信号进行仲裁，**不存在超时机制**。编程路径在 `prog_busy=1` 期间独占 CIM macro，推理路径被完全屏蔽（`infer_grant=0`）。仲裁切换完全由 `cim_program_ctrl` 的 FSM 状态驱动：当 FSM 离开编程/验证状态并释放 `prog_busy` 后，仲裁器才重新允许推理路径访问。由于 `prog_busy` 和 `infer_req` 在同一时钟域内采样，不可能出现同时授权两方的情况。

> 如果软件侧需要防止编程挂死（例如模拟侧 `prog_done` 永远不返回），应由固件层实现看门狗超时并通过 `SOFT_RESET`（`CIM_CTRL[1]`）复位整条链路，硬件侧不做超时保护。

### Verify 重试耗尽场景

当 `cim_program_ctrl` 的 Write-Verify 循环中 `verify_pass` 持续为 0，且重试次数达到 `retry_limit`（由 `PROG_CTRL[10:8]` 配置，默认 3）后，FSM 转入 `ST_DONE` 状态，输出：

- `prog_pass = 0`
- `prog_fail = 1`
- `PROG_STATUS[7]`（DONE）置 1

软件通过读 `PROG_STATUS`（地址 `0x4000_0044`）检测结果：

| 位域 | 含义 |
|------|------|
| `[1]` PASS | 编程+验证成功 |
| `[2]` FAIL | 重试耗尽仍未通过 |
| `[5:3]` RETRY_COUNT | 实际重试次数 |
| `[7]` DONE | 操作完成（W1C） |

当检测到 `FAIL=1` 时，软件需采取补救措施，例如：

1. 对同一单元重新发起编程请求（可调大 `RETRY_LIMIT` 或更换 `LEVEL`）
2. 若反复失败，标记该单元为坏单元（defect map），在权重映射时绕过
3. 记录失败日志，供后续良率分析使用
