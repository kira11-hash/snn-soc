# feature/axi-lite 分支开发记录

> 分支名：`feature/axi-lite`
> 基于 main 分支创建（2026-03-01）
> main 分支已冻结（全量 smoke test 通过，代码封存），本分支完全独立，随时可回退。

---

## 一、背景与目标

### 为什么要做 AXI-Lite 骨架？

当前 SNN SoC 的总线结构（`bus_simple_if` + `bus_interconnect`）是一套自定义简化总线，Testbench 通过层级引用（`dut.bus_if.m_valid`）直接驱动，属于"裸驱动"方式。

后续集成 E203 RISC-V CPU 时，E203 的对外主机接口是 **AXI4-Lite**，无法直接驱动自定义简单总线。因此需要在两者之间插入一个协议转换桥（Bridge）。

### 本次迭代目标

1. 定义 AXI4-Lite 接口规范（`axi_lite_if.sv`）
2. 实现 AXI-Lite slave → bus_simple master 的桥接模块（`axi2simple_bridge.sv`）
3. 写 Testbench 端到端验证整条通路（`axi_bridge_tb.sv`）
4. **不触碰 main 分支任何文件**，保证可随时回退

---

## 二、新增文件清单

| 文件路径 | 类型 | 说明 |
|---------|------|------|
| `rtl/bus/axi_lite_if.sv` | RTL（接口定义） | AXI4-Lite SystemVerilog interface |
| `rtl/bus/axi2simple_bridge.sv` | RTL（核心模块） | AXI-Lite slave → bus_simple master 桥接 FSM |
| `tb/axi_bridge_tb.sv` | Testbench | T1~T7 端到端测试，含 BFM tasks |
| `sim/sim_axi_bridge.f` | 仿真文件列表 | Icarus 编译文件列表 |
| `sim/run_axi_bridge_icarus.sh` | 脚本 | 一键编译 + 运行 + 结果判断 |
| `new_branchnotes/axi-lite.md` | 文档 | 本文件，分支开发记录 |

**修改的文件：**

| 文件路径 | 变更内容 |
|---------|---------|
| `CLAUDE.md` | 新增 "AXI-Lite 分支状态" 段，记录已完成/待做项 |

---

## 三、各文件详细说明

### 3.1 `rtl/bus/axi_lite_if.sv` — AXI4-Lite 接口定义

**目的**：定义标准 AXI4-Lite 信号集合和 modport，供 VCS 仿真及将来 E203 接入使用。

**包含的通道和信号：**

| 通道 | 信号 | 方向（从 Master 视角）|
|------|------|----------------------|
| 写地址 AW | AWVALID, AWREADY, AWADDR[31:0], AWPROT[2:0] | 发出/接收/发出/发出 |
| 写数据 W | WVALID, WREADY, WDATA[31:0], WSTRB[3:0] | 发出/接收/发出/发出 |
| 写响应 B | BVALID, BREADY, BRESP[1:0] | 接收/发出/接收 |
| 读地址 AR | ARVALID, ARREADY, ARADDR[31:0], ARPROT[2:0] | 发出/接收/发出/发出 |
| 读数据 R | RVALID, RREADY, RDATA[31:0], RRESP[1:0] | 接收/发出/接收/接收 |

**两个 modport：**
- `master`：CPU / BFM 使用，驱动地址/数据通道，接收响应
- `slave`：`axi2simple_bridge` 使用，接收地址/数据，驱动响应

**V1 简化约定：**
- AWPROT / ARPROT 在 V1 中忽略（无访问控制）
- 无 burst（AXI-Lite 本身不支持 burst）
- 无 ID

---

### 3.2 `rtl/bus/axi2simple_bridge.sv` — 核心桥接模块

**目的**：在 AXI4-Lite 协议和项目已有的 bus_simple 协议之间做转换，使得 E203 CPU 可以通过 AXI-Lite 访问 SNN SoC 的所有从机（寄存器、DMA、SRAM 等）。

#### 端口设计

- **左侧（AXI-Lite slave）**：平铺信号，`s_*` 前缀，兼容 Icarus/VCS
- **右侧（bus_simple master）**：`m_*` 前缀，直接连接 `bus_interconnect` 的主机端口

使用平铺信号（而非 interface modport）是为了**Icarus 兼容性**——Icarus 对 interface modport 在模块端口的支持有限制。

#### FSM 设计（5 个状态）

```
ST_IDLE
  ├─ 写地址/写数据均齐备 ──→ ST_WR_PEND （发 m_valid=1 写请求）
  └─ 读地址有效（无写挂起）→ ST_RD_PEND （发 m_valid=1 读请求）

ST_WR_PEND（等 m_ready，固定 1 拍）
  └─ m_ready=1 ──────────→ ST_WR_RSP

ST_WR_RSP（BVALID=1，等 master BREADY）
  └─ s_bready=1 ─────────→ ST_IDLE

ST_RD_PEND（等 m_rvalid，固定 1 拍）
  └─ m_rvalid=1 ─────────→ ST_RD_RSP  （同拍捕获 rdata_reg）

ST_RD_RSP（RVALID=1，等 master RREADY）
  └─ s_rready=1 ─────────→ ST_IDLE
```

#### 关键时序（写事务）

```
Cycle N  : IDLE，写地址+写数据均已齐备 → m_valid=1（组合驱动）
           → AWREADY=1, WREADY=1（组合，与 m_valid 同拍）
           → state 寄存器 clock edge 更新为 ST_WR_PEND

Cycle N+1: ST_WR_PEND，m_valid=0
           bus_interconnect 的 req_valid=1（从 m_valid 寄存一拍得到）
           → m_ready=1（组合，来自 bus_interconnect）
           → state 更新为 ST_WR_RSP

Cycle N+2: ST_WR_RSP，BVALID=1（组合，state==ST_WR_RSP）
           → 若 BREADY=1，state 更新为 ST_IDLE

总写延迟：从 AWREADY/WREADY 握手到 BVALID 出现 = 2 clock cycles
```

#### 关键时序（读事务）

```
Cycle N  : IDLE，ARVALID=1 → ARREADY=1，m_valid=1，state→ST_RD_PEND
Cycle N+1: ST_RD_PEND，m_rvalid=1 → rdata_reg=m_rdata，state→ST_RD_RSP
Cycle N+2: ST_RD_RSP，RVALID=1，RDATA=rdata_reg
           → 若 RREADY=1，state→ST_IDLE

总读延迟：从 ARREADY 握手到 RVALID 出现 = 2 clock cycles
```

#### AW/W 错拍支持（重要设计决策）

AXI4-Lite 规范允许写地址（AW）和写数据（W）通道**独立握手，不要求同拍到达**。

初版设计要求两者同拍才接受（`accept_wr = AWVALID && WVALID`）。更新后改为支持错拍，增加了 **1-entry pending buffer**：

```systemverilog
logic aw_pending, w_pending;          // 暂存标志
logic [31:0] awaddr_pending;          // 暂存写地址
logic [31:0] wdata_pending;           // 暂存写数据
logic [3:0]  wstrb_pending;           // 暂存字节使能
```

逻辑：
- 若 AW 先到，且 W 还未到：缓存地址到 `awaddr_pending`，设 `aw_pending=1`，等待 W
- 若 W 先到，且 AW 还未到：缓存数据到 `wdata_pending/wstrb_pending`，设 `w_pending=1`，等待 AW
- 当地址和数据均齐备（来自 pending 或本拍握手）时：`fire_wr=1`，发 m_valid 写请求

这使得桥接模块**完全符合 AXI4-Lite 规范**，E203 CPU 可以用任意顺序发送 AW/W。

#### 写优先 + 读封锁逻辑

读通道在以下情况**不接受新读请求**：
```systemverilog
assign s_arready = (state == ST_IDLE) && !aw_pending && !w_pending
                   && !s_awvalid && !s_wvalid;
```

这确保：
1. 有写事务挂起时不插入读（避免乱序）
2. 写优先（当写/读同时发起时，写先行）

#### SVA 断言（VCS 环境）

在 `` `ifndef SYNTHESIS `` / `` `ifdef VCS `` 内置了 4 条并发断言：

| 断言名 | 验证内容 |
|--------|---------|
| `a_ready_in_wr_pend` | m_ready 只能在 ST_WR_PEND 状态出现 |
| `a_rvalid_in_rd_pend` | m_rvalid 只能在 ST_RD_PEND 状态出现 |
| `a_bvalid_in_wr_rsp` | BVALID 只在 ST_WR_RSP 拉高 |
| `a_rvalid_in_rd_rsp` | RVALID 只在 ST_RD_RSP 拉高 |

Icarus 使用 `-gno-assertions` 跳过，与其他模块的 SVA 保护方式一致。

---

### 3.3 `tb/axi_bridge_tb.sv` — 端到端测试

**测试架构：**

```
TB BFM（平铺 AXI-Lite 信号）
     ↓ AXI-Lite 协议
axi2simple_bridge（DUT）
     ↓ bus_simple 协议
bus_interconnect（地址译码路由）
     ↓
test_regs[0:7]（8 × 32-bit 内置寄存器，挂载于 ADDR_REG_BASE=0x4000_0000）
其余从机（INSTR/DATA/WEIGHT SRAM，DMA，UART，SPI，FIFO）→ rdata 恒 0
```

**7 个测试项：**

| 测试 | 地址 | 操作 | 验证内容 |
|------|------|------|---------|
| T1 | REG_BASE+0x00 | 写 `0xDEAD_BEEF`，读回 | 基本写读通路 |
| T2 | REG_BASE+0x04 | 写 `0xCAFE_1234`，读回 | 不同地址写读 |
| T3 | REG_BASE+0x10 | 写 `0x0000_27D8`（=10200，THRESHOLD_DEFAULT），读回 | 较高偏移地址 |
| T4 | REG_BASE+0x00 | 仅读 | 验证 T2/T3 写入未破坏 reg[0] |
| T5 | REG_BASE+0x08 | 先全写 `0xFFFFFFFF`，再用 `wstrb=4'b0001` 写 `0xAB`，读回期望 `0xFFFFFFAB` | 字节写使能路径 |
| T6 | REG_BASE+0x0C | AW 先到，W 后到（用 `axi_write_aw_first` task）| AW/W 错拍支持 |
| T7 | REG_BASE+0x14 | W 先到，AW 后到（用 `axi_write_w_first` task）| AW/W 错拍支持（反向）|

**3 个 BFM task：**

| Task | 参数 | 说明 |
|------|------|------|
| `axi_write(addr, data, strb)` | 地址、数据、字节使能 | 同时驱动 AW+W，等 AWREADY&&WREADY，等 BVALID |
| `axi_read(addr, data)` | 地址、输出数据 | 驱动 AR，等 ARREADY，等 RVALID，捕获 RDATA |
| `axi_write_aw_first(addr, data, strb)` | 同上 | 先发 AW 再发 W（用于 T6）|
| `axi_write_w_first(addr, data, strb)` | 同上 | 先发 W 再发 AW（用于 T7）|

**测试寄存器堆（TB 内置）：**

```systemverilog
logic [31:0] test_regs [0:7];  // 8 个 32-bit 寄存器
// 寻址：reg_req_addr[4:2] = word index，支持字节写使能
```

寄存器堆挂在 `ADDR_REG_BASE` 地址空间，通过 `bus_interconnect` 的 `reg_req_*` 信号驱动。

**通过标准：**
```
AXI_BRIDGE_SMOKETEST_PASS  （所有 7 个测试项均 PASS）
```

**Icarus 兼容性措施：**
- 不使用 `automatic` 关键字（顺序执行不需要）
- 不使用 interface modport 在模块端口（用平铺信号）
- `for` 循环用 `integer` 变量（非 `int`）
- 超时 Watchdog：`#500_000` 后强制 `$finish`

---

### 3.4 `sim/sim_axi_bridge.f` — 仿真文件列表

```
../rtl/top/snn_soc_pkg.sv       # 地址常量（ADDR_REG_BASE 等）
../rtl/bus/bus_simple_if.sv     # 简单总线接口
../rtl/bus/bus_interconnect.sv  # 地址译码路由
../rtl/bus/axi_lite_if.sv       # AXI-Lite 接口定义
../rtl/bus/axi2simple_bridge.sv # 桥接 DUT
../tb/axi_bridge_tb.sv          # 测试顶层
```

编译命令：
```bash
iverilog -g2012 -gno-assertions -o axi_bridge_test -f sim_axi_bridge.f
```

---

### 3.5 `sim/run_axi_bridge_icarus.sh` — 运行脚本

```bash
cd sim && bash run_axi_bridge_icarus.sh
```

脚本流程：
1. `iverilog` 编译，输出日志到 `axi_bridge_compile.log`
2. 运行 `./axi_bridge_test`，输出日志到 `axi_bridge_sim.log`
3. `grep AXI_BRIDGE_SMOKETEST_PASS`，给出 PASS/FAIL 结论

---

## 四、设计决策记录

| 决策点 | 选择 | 原因 |
|--------|------|------|
| 桥接模块端口用平铺信号还是 interface modport | 平铺信号 | Icarus 兼容性；interface modport 在模块端口上 Icarus 支持有限 |
| AW/W 是否要求同拍到达 | 不要求（1-entry pending buffer）| AXI4-Lite 规范允许错拍；E203 可能不保证同拍 |
| 写优先还是读优先 | 写优先 | 更安全：避免读事务插在未完成写事务之前造成乱序 |
| bus_simple 时序假设 | 固定 1-cycle 延迟 | bus_interconnect 设计如此，WR_PEND/RD_PEND 各等 1 拍即可 |
| SVA 断言放哪里 | `ifndef SYNTHESIS / ifdef VCS` | 与全项目其他断言保持一致的宏保护风格 |
| rdata 捕获时机 | m_rvalid=1 的同拍（always_ff 捕获）| m_rvalid 是组合信号，下一拍消失；必须当拍捕获到 rdata_reg |

---

## 五、未完成 / 待做

| 项目 | 优先级 | 说明 |
|------|--------|------|
| 实际跑通 Icarus 仿真 | 高 | 需要 Icarus 环境，运行 `bash run_axi_bridge_icarus.sh` |
| `axi_lite_interconnect.sv`（1主N从 AXI 仲裁） | 低 | E203 接入前不急；当前只有 1 个 AXI master |
| 集成进 `snn_soc_top.sv` | 中 | E203 接入时需要：在顶层暴露 AXI-Lite slave 端口，将 bridge 与 bus_interconnect 主机端连接 |
| 与真实 `reg_bank` 做集成测试 | 中 | 当前 TB 用 8 个简单测试寄存器，后续可替换为真实 reg_bank |

---

## 六、回退方法

```bash
# 回到封存的 main 分支
git checkout main

# 回到 AXI-Lite 分支继续开发
git checkout feature/axi-lite
```

main 分支完全未被修改，可随时回退。

---

## 七、与后续迭代的关系

```
feature/axi-lite（本分支）
  └─ 验证通过后合并 main
       └─ feature/uart（UART TX/RX + 寄存器）
            └─ feature/spi（Flash 读 ID + 连续读）
                 └─ feature/dma-ext（SPI→SRAM→input_fifo）
                      └─ feature/e203（最后接入 CPU）
```

AXI-Lite 骨架是后续所有步骤的**基础设施**——E203 的所有内存访问、寄存器读写、DMA 配置都将通过 AXI-Lite 接口进行，因此本模块必须先于其他步骤完成和验证。
