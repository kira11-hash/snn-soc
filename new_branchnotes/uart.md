# UART 分支开发说明（中文详细版）

## 1. 文档目的
本文件记录 `feature/uart-tx` 分支中 UART 控制器的开发目标、实现细节、验证方法、已知边界与后续集成步骤。

适用对象：
- RTL 开发同学：快速理解模块行为与关键时序
- 固件同学：确认寄存器语义和软件访问方式
- 集成同学：明确如何替换 `uart_stub` 并接入 SoC

---

## 2. 分支目标与范围

### 2.1 分支目标
将 `rtl/periph/uart_stub.sv` 的占位能力升级为可用的 UART TX 控制器，满足 V1 bring-up 打印需求。

### 2.2 范围边界（V1）
本分支只实现：
- UART TX（8N1）
- 波特率可配置
- 状态可读（`tx_busy`）

本分支不实现：
- UART RX
- TX FIFO / RX FIFO
- UART 中断
- 硬件流控 RTS/CTS

---

## 3. 文件清单

### 3.1 新增文件
1. `rtl/periph/uart_ctrl.sv`
2. `tb/uart_tb.sv`
3. `sim/sim_uart.f`
4. `sim/run_uart_icarus.sh`
5. `new_branchnotes/uart.md`

### 3.2 保留文件
1. `rtl/periph/uart_stub.sv` 保留不动（用于主线回退和风险隔离）

---

## 4. 模块设计说明（uart_ctrl.sv）

## 4.1 模块定位
`uart_ctrl` 是一个内存映射外设，软件通过写寄存器触发发送字节，硬件按 8N1 协议输出串行波形。

## 4.2 寄存器映射（基址 0x4000_0200）

| Offset | 寄存器 | 位域 | 权限 | 说明 |
|---|---|---|---|---|
| `0x00` | `TXDATA` | `[7:0]` | R/W | 写入触发发送，忙时写入忽略；可读回影子值 |
| `0x04` | `RXDATA` | `[7:0]` | RO | V1 占位，返回 0 |
| `0x08` | `STATUS` | `[0]=tx_busy` | RO | 1=发送中，0=空闲 |
| `0x0C` | `CTRL` | `[15:0]=baud_div` | R/W | 波特率分频，默认对应 115200@100MHz |

以上 offset 与 `uart_stub.sv` 完全一致，替换集成时固件地址无需改动。

## 4.3 协议与帧格式
- 协议：UART 8N1
- 帧结构：`Start(0) + D0..D7 + Stop(1)`
- 数据位顺序：LSB first

## 4.4 状态机
状态定义：
- `ST_IDLE`：空闲等待写 `TXDATA`
- `ST_START`：发送起始位（低电平）
- `ST_DATA`：发送 8 个数据位
- `ST_STOP`：发送停止位（高电平）

转移规则：
- `IDLE -> START`：写 `TXDATA` 且 `!tx_busy`
- `START -> DATA`：起始位时间到
- `DATA -> STOP`：第 8 位发送完毕
- `STOP -> IDLE`：停止位时间到

## 4.5 关键实现点
1. 波特分频计数：
- 每个 bit 持续 `baud_div` 个系统时钟
- 计数到期后切换到下一位/下一状态

2. 忙保护：
- 发送期间 `tx_busy=1`
- 忙时写 `TXDATA` 被忽略（防止打断正在发送的数据）

3. Icarus 兼容：
- 避免在 `always` 中使用某些不兼容位选写法
- 使用 `assign` + 中间 wire 的保守写法提高仿真器兼容性

---

## 5. 测试平台说明（uart_tb.sv）

## 5.1 测试目标
验证 UART TX 控制器最小可用闭环：
- 控制寄存器可配置
- 字节发送正确
- 忙状态正确
- 忙时写保护生效

## 5.2 测试用例
1. T1：写 `CTRL(baud_div)` 并读回
2. T1b：读 `RXDATA` 占位寄存器，返回 0（地址兼容性）
3. T2：发送 `0x55` 并解码校验
4. T3：发送 `0xA5` 并解码校验
5. T4：发送 `0xFF` 并解码校验
6. T5：发送 `0x00` 并解码校验
7. T6：发送中读取 `STATUS.tx_busy=1`，发送后为 `0`
8. T7：忙时写入忽略，空闲后再发字节验证

通过判据：
- 所有检查点 PASS
- 打印 `UART_SMOKETEST_PASS`

---

## 6. 仿真方法

## 6.1 文件列表
`sim/sim_uart.f`：
- `../rtl/periph/uart_ctrl.sv`
- `../tb/uart_tb.sv`

## 6.2 命令（PowerShell）
```powershell
cd sim
iverilog -g2012 -gno-assertions -o uart_test -f sim_uart.f
vvp .\uart_test
```

## 6.3 命令（bash）
```bash
cd sim
bash run_uart_icarus.sh
```

---

## 7. 设计决策说明

1. V1 只做 TX：
- 与项目定位一致（bring-up 日志输出）
- 降低 RTL 复杂度和联调风险

2. 忙时写丢弃而非排队：
- 不引入 FIFO，状态机简单
- 软件可通过轮询 `tx_busy` 控制发送节奏

3. 保留 `uart_stub.sv`：
- 新旧并存，便于回退
- 集成可分阶段推进（先 IP 级、再系统级）

---

## 8. 当前状态

已完成：
1. `uart_ctrl` RTL 实现
2. `uart_tb` 独立验证
3. Icarus 烟雾测试通过（PASS=9, FAIL=0）

未完成（下一阶段）：
1. 顶层 `snn_soc_top.sv` 替换 `uart_stub -> uart_ctrl`
2. SoC 级联调（CPU/总线访问 UART）

---

## 9. 后续建议

1. 若作为 V1 调试口：
- 保持 TX-only 设计，不继续膨胀功能

2. 若升级到 V2 正式通信：
- 增加 RX 路径
- 增加 FIFO
- 增加中断与错误状态位（framing/parity/overrun）

---

## 10. 结论
`feature/uart-tx` 当前结果可视为“IP 级完成”，能够承担 V1 bring-up 日志输出职责；在接入 SoC 顶层前，主线代码可保持不受影响。
