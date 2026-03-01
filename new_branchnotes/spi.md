# SPI 分支开发说明（详细版）

## 1. 文档定位与用途
本文件用于记录 `feature/spi` 分支中 SPI 控制器的完整开发过程、设计取舍、验证结果与后续集成计划。

适用对象：
- 数字 RTL 开发同学（需要快速理解模块实现）
- 固件同学（需要知道寄存器语义和使用方式）
- 后续集成同学（需要知道何时替换 top 的 `spi_stub`）
- 回归维护同学（需要知道本分支改动边界、风险和回退策略）

本文件是“分支级开发记录”，不是最终 SoC 总体规范文档。最终对外版本请以主线文档与寄存器映射文档为准。

---

## 2. 分支信息与目标

### 2.1 分支信息
- 分支名：`feature/spi`
- 开发目标：新增可独立验证的 SPI Master 控制器，支持基础 Flash 读链路 bring-up
- 改动边界：
  - 新增 `spi_ctrl.sv`（不改 `spi_stub.sv`）
  - 新增 SPI 独立 TB 与 Flash 行为模型
  - 新增 Icarus 编译/运行入口
  - 新增本开发说明文档

### 2.2 一句话目标
在不破坏现有主线可回归性的前提下，先把 SPI IP 级功能做完整并验证通过，为后续顶层替换与 SoC 联调做准备。

---

## 3. 本次新增文件清单

1. `rtl/periph/spi_ctrl.sv`
2. `tb/spi_flash_model.sv`
3. `tb/spi_tb.sv`
4. `sim/sim_spi.f`
5. `sim/run_spi_icarus.sh`
6. `new_branchnotes/spi.md`

---

## 4. 设计背景与系统定位

### 4.1 SPI 在当前 SoC 的定位
SPI 在本项目中定位为“外部数据搬运入口”，核心服务对象是 Flash 存储器，而不是人机交互。

典型链路（V1 目标）为：
- 外部 Flash（存图片/参数）
- SPI 控制器读出数据
- CPU 固件将数据写入 data_sram
- DMA 从 data_sram 继续搬运到计算链路（例如 input_fifo）

### 4.2 与 UART 的角色区分
- UART（当前策略）偏向调试日志输出
- SPI（本分支）偏向批量数据读取入口

二者功能定位不同，不应混用。

---

## 5. SPI 控制器实现说明（`spi_ctrl.sv`）

## 5.1 接口兼容策略
为了后续“低风险替换” `spi_stub`，`spi_ctrl` 采用与 `spi_stub` 同构的端口风格：

- 总线输入：`req_valid/req_write/req_addr/req_wdata/req_wstrb`
- 总线输出：`rdata`
- SPI 物理口：`spi_cs_n/spi_sck/spi_mosi/spi_miso`

这样做的好处：
- 顶层实例替换时端口可一一对应
- 总线互连地址译码逻辑不需要同步重构
- 缩短联调路径，降低一次性大改引入回归的概率

## 5.2 寄存器映射（相对 SPI base 偏移）

| 偏移 | 名称 | 访问属性 | 位域 | 复位值 | 说明 |
|---|---|---|---|---|---|
| `0x00` | `CTRL` | R/W | `[0] spi_en` `[3:1] clk_div` `[8] cs_force` | `0` | 使能、分频、软件控 CS |
| `0x04` | `STATUS` | RO | `[0] busy` `[1] rx_valid` | `0` | 传输忙标志、接收有效标志 |
| `0x08` | `TXDATA` | W（读回 shadow） | `[7:0] tx_byte` | `0` | 写入后触发一次 8bit 传输 |
| `0x0C` | `RXDATA` | RO | `[7:0] rx_byte` | `0` | 最近一次接收数据；读取后清 `rx_valid` |

补充语义：
- 当 `spi_en=0` 时写 `TXDATA` 不启动传输
- `rx_valid` 在收到完整 8bit 后置位
- `rx_valid` 在读取 `RXDATA` 的那个总线读操作后清零（消费语义）

## 5.3 SPI 模式与位序
当前实现固定：
- Mode 0（CPOL=0, CPHA=0）
- MSB first
- 8-bit 一次事务

边沿规则：
- 在 SCK 上升沿采样 `MISO`
- 在 SCK 下降沿更新下一位 `MOSI`

## 5.4 时钟分频
`CTRL[3:1]=clk_div_sel (0~7)`，内部映射如下：

| `clk_div_sel` | 内部半周期计数上限 `div_limit` | 近似分频 | `sys_clk=100MHz` 时 SPI 频率 |
|---|---:|---:|---:|
| 0 | 0 | ÷2 | 50 MHz |
| 1 | 1 | ÷4 | 25 MHz |
| 2 | 3 | ÷8 | 12.5 MHz |
| 3 | 7 | ÷16 | 6.25 MHz |
| 4 | 15 | ÷32 | 3.125 MHz |
| 5 | 31 | ÷64 | 1.5625 MHz |
| 6 | 63 | ÷128 | 0.78125 MHz |
| 7 | 127 | ÷256 | 0.390625 MHz |

安全策略（已在 RTL 落地）：
- 当软件写 `CTRL` 时若 `spi_en=1` 且 `clk_div_sel=0`，硬件会自动钳位到 `clk_div_sel=2`（12.5MHz）。
- 目的是避免 bring-up 阶段误配到 50MHz，提升外部 Flash 与板级连线容差。

建议 bring-up 默认用中低速（例如 12.5MHz 或更低），先保功能稳定。

## 5.5 CS 控制策略
采用纯软件控 CS（`CTRL[8]=cs_force`）：
- `1`：强制片选有效（`spi_cs_n=0`）
- `0`：片选释放（`spi_cs_n=1`）

不做自动 CS 的原因：
- 固件更容易精确控制命令边界（例如 RDID、READ 连续事务）
- RTL 简化、状态机复杂度更低
- 便于先把最小可用链路打通

## 5.6 状态机设计
状态定义：
- `ST_IDLE`：空闲等待写 `TXDATA`
- `ST_SHIFT`：8bit 移位传输（按分频翻转 SCK）
- `ST_DONE`：传输收尾 1 拍，随后回到 `ST_IDLE`

状态转移条件：
- `IDLE -> SHIFT`：`write TXDATA && spi_en`
- `SHIFT -> DONE`：第 8 bit 在上升沿采样完成
- `DONE -> IDLE`：下一拍回空闲

关键信号语义：
- `busy`：仅表示当前正在进行 8bit 事务
- `rx_valid`：表示 `RXDATA` 有新值可读

## 5.7 关键实现细节（避免踩坑）
1. 最后一位采样与 `busy` 拉低时机
- 早期实现出现过“最后位边沿被门控”问题（最终字节为 0）
- 已修复为：完成最后位采样后先进入 `ST_DONE`，再拉低 `busy`

2. `RXDATA` 读取即消费
- 在总线读 `RXDATA` 时清 `rx_valid`
- 这样固件可以用 `rx_valid` 判断“是否有新字节未取走”

3. `req_wstrb` 在当前版本未细分支持
- 当前按整字写处理，字节写掩码在本版本忽略
- 这与当前大多数外设 stub/早期实现风格一致

---

## 6. Flash 行为模型说明（`spi_flash_model.sv`）

## 6.1 作用
用于 SPI 控制器独立单测，不依赖真实外设模型，快速验证协议时序与读通路。

## 6.2 支持命令
- `0x9F`：RDID，返回 `EF 40 16`
- `0x03`：READ，后接 24bit 地址，随后按字节流返回数据

## 6.3 内存内容
模型内置 `mem[0..65535]`（64KB 窗口），初始化为：
- `mem[i] = i[7:0]`

READ 的 24-bit 地址在模型中取低 16-bit 作为窗口地址，足够覆盖当前单测与 bring-up 读路径，避免早期 256B 模型的快速回绕问题。

## 6.4 时序约定
与 DUT 对齐 Mode0：
- 在 SCK 下降沿驱动 `MISO`
- 在 SCK 上升沿由主机采样

---

## 7. 测试平台说明（`spi_tb.sv`）

## 7.1 TB 架构
- DUT：`spi_ctrl`
- 从设备模型：`spi_flash_model`
- 激励方式：通过简化总线读写任务访问寄存器

## 7.2 覆盖用例
T1 控制寄存器回读：
- 写 `CTRL`，验证读回一致

T1b 安全分频钳位：
- 写 `CTRL=0x0000_0001`（`spi_en=1, clk_div=0`）
- 读回应被钳位为 `0x0000_0005`（`clk_div=2`，12.5MHz）

T2 RDID 命令链路：
- 拉低 CS
- 发送 `0x9F`
- 连续发 3 个 dummy byte 收回 3 字节 ID
- 期望 `EF 40 16`

T3 READ 命令链路：
- 拉低 CS
- 发送 `0x03 + 24bit 地址 0x000010`
- 连续读 4 字节
- 期望 `10 11 12 13`

T4 `rx_valid` 消费语义：
- 在每次读 `RXDATA` 后检查 `STATUS.rx_valid` 已清零

## 7.3 通过判据
- 所有检查点无失败
- 打印 `SPI_SMOKETEST_PASS`

---

## 8. 仿真入口与执行方法

## 8.1 文件列表
- `sim/sim_spi.f`：SPI 单测编译列表
- `sim/run_spi_icarus.sh`：一键脚本（Linux/bash 环境）

## 8.2 手动命令（Windows / PowerShell）
在 `sim/` 目录下执行：

```powershell
iverilog -g2012 -gno-assertions -o spi_test -f sim_spi.f
vvp .\spi_test
```

## 8.3 手动命令（Linux / bash）
在 `sim/` 目录下执行：

```bash
iverilog -g2012 -gno-assertions -o spi_test -f sim_spi.f
vvp ./spi_test
```

---

## 9. 本分支实测结果

本次本地复测结果：
- `PASS=9 FAIL=0`
- `SPI_SMOKETEST_PASS`

说明：
- SPI 控制器最小可用路径（RDID + READ）已在 IP 级闭环通过
- 当前结果仅代表“模块级 + 行为模型级”可用
- 还不代表“顶层 SoC 级 + 固件级”已完成

---

## 10. 发现过的问题与修复

问题现象：
- 早期版本 RDID/READ 全部读回 `0x00`

根因：
- 最后一个 bit 的采样周期内 `busy` 提前拉低，`spi_sck = busy ? sck_int : 0` 的门控逻辑抑制了关键边沿

修复：
- 在最后位采样后进入 `ST_DONE`
- 在 `ST_DONE` 再清 `busy`

结果：
- RDID 与 READ 用例恢复正常，回归通过

---

## 11. 为什么保留 `spi_stub.sv` 不改

这是刻意的工程策略，不是遗漏。

原因 1：保留可回退基线
- 若新 SPI 控制器在系统集成阶段出现问题，可立即切回 stub 保证主线可跑

原因 2：解耦“IP 开发”和“SoC 集成”
- 先完成独立模块验证，再做顶层替换，问题定位更清晰

原因 3：降低一次性改动风险
- 若同步修改 stub、top、总线、文档，回归面会显著扩大

原因 4：与 UART 分支策略一致
- `uart_stub` 保留，`uart_ctrl` 独立开发验证后再集成

结论：
- `spi_stub` 保留是为了风险控制和工程可维护性，不影响后续将 `spi_ctrl` 接入主线。

---

## 12. 当前限制与已知边界

当前版本已支持：
- Mode0
- 8bit 全双工事务
- RDID/READ 场景可跑通

当前版本未覆盖：
- Mode1/2/3
- Quad SPI / Dual SPI
- 写使能、页编程、擦除等写命令
- DMA 直连 SPI（当前仍建议 CPU 中转）
- 中断机制（当前用轮询 `STATUS`）

---

## 13. 后续集成建议（不在本次提交中）

步骤 1：顶层替换实例
- 在 top 中把 `spi_stub` 实例替换为 `spi_ctrl`，保持端口一一对应

步骤 2：系统级联调
- 通过总线访问 `SPI base`，验证寄存器可读写
- 在 SoC TB 中引入 Flash 模型或等价激励

步骤 3：固件最小流程
- `CS low -> 0x9F -> 读ID -> CS high`
- `CS low -> 0x03 + addr -> 连续读数据 -> CS high`

步骤 4：与 data_sram / DMA 流程串联
- CPU 将 SPI 读出数据写入 data_sram
- DMA 从 data_sram 搬到后级 FIFO

步骤 5：更新主线文档
- 在 `reg_map` / `主文档` 中补齐 SPI 当前实现范围与限制

---

## 14. 结论

本分支已经完成“SPI 控制器 IP 级最小可用闭环”：
- 有独立 RTL
- 有可重复执行的单元仿真
- 有明确通过标志
- 有已知问题与修复记录

可以进入下一阶段：
- 顶层替换与系统级联调
- 固件读 Flash 路径打通
- 与 DMA/计算链路端到端串联
