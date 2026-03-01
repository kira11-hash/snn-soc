# feature/uart-tx 分支开发记录

## 背景与目标

本分支从 `main` 分支切出，目标是将 `rtl/periph/uart_stub.sv`（占位模块）
升级为真实可用的 **UART TX 控制器**（uart_ctrl.sv），实现标准 8N1 帧格式，
支持波特率软件配置，并通过 Icarus 烟雾仿真验证所有功能路径。

这是项目迭代计划第 2 步（AXI-Lite 骨架完成后），为 bring-up 阶段提供最小可用 UART 打印通路。

---

## 新增/修改文件清单

| 文件路径 | 类型 | 状态 | 说明 |
|---------|------|------|------|
| `rtl/periph/uart_ctrl.sv` | RTL | **新增** | UART TX 8N1 控制器（替换 uart_stub） |
| `tb/uart_tb.sv` | TB | **新增** | 独立测试台，T1-T7 共 8 项测试 |
| `sim/sim_uart.f` | SIM | **新增** | Icarus 文件列表 |
| `sim/run_uart_icarus.sh` | SIM | **新增** | 一键烟雾测试脚本 |
| `new_branchnotes/uart.md` | DOC | **新增** | 本文件 |

> `uart_stub.sv` **保留不动**，`uart_ctrl.sv` 是新文件；顶层集成时将实例替换即可。

---

## rtl/periph/uart_ctrl.sv — 详细说明

### 功能定位

替代 `uart_stub.sv`，实现真实的 UART TX 8N1 帧发送：

- **帧格式**：1 起始位（低） + 8 数据位（LSB 优先） + 1 停止位（高）= 10 bit/frame
- **波特率**：通过 CTRL 寄存器的 `baud_div` 字段配置，默认 868（= 100MHz / 115200）
- **接口**：与 `uart_stub` 完全一致（bus_simple slave），可直接替换

### 寄存器映射（base = 0x4000_0200）

| Offset | 名称 | 位域 | 权限 | 说明 |
|--------|------|------|------|------|
| 0x00 | TXDATA | [7:0] | R/W | 写入触发发送；忙时写入忽略；读回影子值 |
| 0x04 | STATUS | [0]=tx_busy | RO | 1=正在发送，0=空闲 |
| 0x08 | CTRL | [15:0]=baud_div | R/W | 每 baud 周期时钟数，默认868 |
| 0x0C | RXDATA | [7:0] | RO | V1 占位，读返回 0 |

### TX 状态机（4 状态）

```
ST_IDLE ──(write TXDATA, !busy)──→ ST_START ──(baud 到期)──→ ST_DATA
                                                                  │
                                   ST_IDLE ←─(baud 到期)── ST_STOP
                                                              ↑
                                              (bit_cnt==7, baud 到期)
```

| 状态 | uart_tx | 持续时间 | 说明 |
|------|---------|---------|------|
| ST_IDLE | 1 | 无限 | 等待 TXDATA 写入 |
| ST_START | 0 | baud_div 个时钟 | 起始位（低） |
| ST_DATA | tx_shift[0] | baud_div × 8 | 8 个数据位，LSB 先发 |
| ST_STOP | 1 | baud_div 个时钟 | 停止位（高），完成后 tx_busy=0 |

### 关键实现细节

**波特计数器（baud_cnt）**：
- 进入新状态时装载 `baud_div_reg - 1`（保证持续恰好 baud_div 个时钟）
- 每拍减一，到 0（`baud_last`）时切换到下一状态

**移位寄存器（tx_shift）**：
- 进入 ST_START 时将发送字节加载到 `tx_shift`
- 每个数据位结束时：`tx_shift <= tx_shift >> 1`（逻辑右移，MSB 补 0）
- 输出取 `tx_shift[0]`（LSB）→ 实现 LSB-first 发送

**忙保护（tx_busy）**：
- 进入 ST_START 时置 1，ST_STOP 结束时清 0
- 寄存器写逻辑中：`if (!tx_busy) txdata_shadow <= ...`，忙时写入直接丢弃

**Icarus 兼容性修正**：
- Icarus 不支持 `always_*` 块内的常量位选（如 `tx_shift[0]`, `tx_shift[7:1]`）
- `tx_shift[0]` 提取为 `wire tx_data_bit = tx_shift[0];`，在 `assign` 中使用
- `{1'b0, tx_shift[7:1]}` 改写为 `tx_shift >> 1`（等价，Icarus 接受）
- uart_tx 输出由 `always_comb` 改为 `assign` 三目表达式

---

## tb/uart_tb.sv — 详细说明

### 测试架构

```
    ┌──────────────────────────────────────────────────────┐
    │  uart_tb                                              │
    │                                                       │
    │  BFM (bus_write/bus_read tasks)                       │
    │       │  req_valid/write/addr/wdata/wstrb             │
    │       ▼                                               │
    │  ┌────────────┐                                       │
    │  │ uart_ctrl  │ ──uart_tx──→ uart_decode task         │
    │  │   (DUT)    │                                       │
    │  └────────────┘                                       │
    │                                                       │
    └──────────────────────────────────────────────────────┘
```

- 直接驱动 `req_*` 信号，不经过 `bus_interconnect`（独立验证）
- `uart_decode` 任务监控 `uart_tx` 引脚的下降沿，按 baud 周期在每位中点采样，解码 8 位字节
- 仿真用 `baud_div=8`（8 个时钟/bit，加速仿真）

### 测试用例

| 编号 | 内容 | 验证点 |
|------|------|--------|
| T1 | 写 CTRL baud_div=8，读回 | 寄存器读写正确性 |
| T2 | 发送 0x55（01010101）| 交替模式，LSB 优先解码 |
| T3 | 发送 0xA5（10100101）| 非对称模式 |
| T4 | 发送 0xFF（全 1）| 全高数据位 |
| T5 | 发送 0x00（全 0）| 全低数据位（连续 0 和起始/停止区分）|
| T6a | 发送中读 STATUS.tx_busy | 应为 1（忙） |
| T6b | 发送完后读 STATUS.tx_busy | 应为 0（空闲）|
| T7 | 忙时写 TXDATA（应忽略）+ 空闲后发 0x3C | 忙保护 + 正常发送 |

**通过标准**：8 项全 PASS，无 FAIL → 打印 `UART_SMOKETEST_PASS`

### 仿真结果（已验证）

```
[INFO] UART TX Smoke Test Start
[PASS] T1_CTRL : got=0x00000008
[PASS] T2_0x55 : got=0x00000055
[PASS] T3_0xA5 : got=0x000000a5
[PASS] T4_0xFF : got=0x000000ff
[PASS] T5_0x00 : got=0x00000000
[PASS] T6_BUSY : got=0x00000001
[PASS] T6_IDLE : got=0x00000000
[PASS] T7_0x3C : got=0x0000003c
[RESULT] PASS=8  FAIL=0
UART_SMOKETEST_PASS
```

---

## sim 文件说明

### sim/sim_uart.f

仅两个文件：`uart_ctrl.sv` + `uart_tb.sv`，无需 `snn_soc_pkg` 或 `bus_interconnect`。

### sim/run_uart_icarus.sh

```bash
iverilog -g2012 -gno-assertions -o uart_test -f sim_uart.f
vvp uart_test | tee uart_sim.log
grep "UART_SMOKETEST_PASS" uart_sim.log
```

- `-gno-assertions`：跳过 SVA（VCS 专用，Icarus 不支持）
- `vvp uart_test`：Windows 上 Icarus 输出 VVP 格式，需用 `vvp` 运行

---

## 设计决策记录

| 决策 | 方案 | 原因 |
|------|------|------|
| 不实现 RX | 占位返回 0 | V1 只需打印调试信息，RX 留 V2 |
| 忙时写丢弃 | `if (!tx_busy)` 保护 | 简单可靠，避免 FIFO 复杂度；V2 可加 TX FIFO |
| baud_div 默认值 868 | 868 = 100MHz / 115200 | 与系统时钟和常用调试波特率匹配 |
| TX 输出用 assign | 替代 always_comb | Icarus 12 不支持 always 内常量位选，assign 兼容 |
| 移位用 >> 1 | 替代 `{1'b0, x[7:1]}` | 同上，消除 Icarus always_ff 内常量部分位选错误 |
| SVA 在 ifdef VCS | `ifndef SYNTHESIS/ifdef VCS` | 与项目其他模块保持一致，Icarus 用 -gno-assertions |
| 独立 TB（不接 bus_interconnect）| 直连 req_* 信号 | 减少依赖，快速隔离验证 uart_ctrl 本体 |

---

## 待完成事项

- [ ] **顶层集成**：在 `snn_soc_top.sv` 中将 `uart_stub` 实例替换为 `uart_ctrl`
- [ ] **VCS 仿真**：同步到 Linux 服务器后用 `bash run_uart_icarus.sh` 或接入 `run_vcs.sh`
- [ ] **RX 路径（V2）**：接收 FIFO + 8N1 采样，用于 JTAG-less 调试
- [ ] **TX FIFO（V2）**：多字节 TX 缓冲，避免软件 busy-wait

---

## 与后续迭代的关系

```
AXI-Lite 骨架（已完成，feature/axi-lite）
       ↓
UART TX（本分支）← 当前位置
       ↓
SPI（feature/spi-flash）← 下一步：Flash 读 ID + 连续读
       ↓
DMA 扩展 → E203 接入
```

UART TX 完成后，CPU（E203）可通过写 TXDATA 寄存器将调试字符串输出到串口，
这是 bring-up 阶段最重要的诊断工具。

---

## 回滚方法

```bash
git checkout main
```

`main` 分支保持冻结状态（仅 `uart_stub.sv` 占位），本分支所有改动隔离在 `feature/uart-tx`。

如需放弃本分支：
```bash
git branch -D feature/uart-tx
```

---

## 功能定位决策（已确认锁定）

### 结论：V1 UART = 调试打印口（TX only），不做正式通信接口

E203 自带 JTAG，所有正式工作（寄存器读写、固件加载、断点调试）走 JTAG，UART TX 只负责 `printf` 输出日志。

| 维度 | 调试打印口（当前） | 正式通信接口（不做）|
|------|-----------------|------------------|
| 速度 | 115200 baud ≈ 11.5 KB/s，够打印字符串 | 下发像素/权重需高吞吐，UART 太慢 |
| 命令/参数下发 | 不适合 | 走 AXI-Lite → reg_bank（直接寄存器读写）|
| 状态回读 | 打印 STATUS/FIFO count 即可 | 软件直接读 reg_bank 更快 |
| RX 需要吗 | 不需要 | 正式接口必须有 RX |
| CLAUDE.md 定义 | "用于 bring-up 打印日志" | — |

正式命令下发路径：**Host PC → JTAG → E203 → AXI-Lite → reg_bank**，不经过 UART。

### V1 实现边界（不可越界）

- ✅ TX 8N1，波特率软件配，tx_busy 状态位
- ✅ 忙时写入丢弃（无 TX FIFO，由软件 poll tx_busy 控制节奏）
- ❌ RX — 不做，留 V2
- ❌ TX FIFO — 不做，留 V2
- ❌ 中断 — 不做，软件 poll 足够
- ❌ 流控（RTS/CTS）— 不做

当前 `uart_ctrl.sv` 的实现刚好覆盖且仅覆盖上述 V1 边界，无需修改。
