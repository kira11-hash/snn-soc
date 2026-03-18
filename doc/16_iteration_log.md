# 16_iteration_log

本文档记录每次迭代的变更摘要、验证结果与后续计划，按时间倒序追加。

---

## Iteration 1 — AXI-Lite 基础骨架接入（2026-03-18）

### 变更内容

将 `feature/axi-lite` 分支的 AXI-Lite 协议转换桥移植到 `main` 分支。

**新增文件（5 个 RTL/TB/脚本，未改动任何现有文件）：**

| 文件 | 说明 |
|------|------|
| `rtl/bus/axi_lite_if.sv` | AXI4-Lite SystemVerilog interface 定义，含 master/slave modport |
| `rtl/bus/axi2simple_bridge.sv` | AXI-Lite slave → bus_simple master 协议转换桥，5 态 FSM |
| `tb/axi_bridge_tb.sv` | T1~T13 端到端测试（含字节写使能、AW/W 错拍、背压、DECERR、未对齐访问） |
| `sim/sim_axi_bridge.f` | Icarus 编译文件列表 |
| `sim/run_axi_bridge_icarus.sh` | Icarus 运行脚本，通过标准 `AXI_BRIDGE_SMOKETEST_PASS` |

### 集成策略

采用 **"interconnect 内部转换，slave 保持 simple 接口"** 方案：

- `axi2simple_bridge` 作为独立协议转换模块，不集成进 `snn_soc_top.sv`（E203 接入时再挂载）
- `bus_interconnect` 和所有下游 slave（reg_bank、dma_engine 等）接口不变
- 现阶段 `snn_soc_top.sv` 的主机仍是 `top_tb` 的 `bus_simple`，不影响任何现有测试

### 验证结果

```
AXI Bridge:   T1~T13 全部 PASS（13/13）  → AXI_BRIDGE_SMOKETEST_PASS
主链路回归:   OUT_FIFO_COUNT=100         → LIGHT_SMOKETEST_PASS（无回归）
```

### 桥时序

```
写事务：Cycle N (m_valid) → N+1 (m_ready) → N+2 (BVALID)，总 2 cycle
读事务：Cycle N (m_valid) → N+1 (m_rvalid) → N+2 (RVALID)，总 2 cycle
AW/W 错拍：先缓存先到的一侧（1-entry pending），另一侧到达后发 m_valid
```

### 未映射地址处理

`axi2simple_bridge` 内含地址校验逻辑，既覆盖 pkg.sv 的全部 8 个地址区间，也检查 4B 对齐约束。访问未映射地址或未对齐地址时，桥接层都直接返回 `DECERR`（2'b11），不发 simple bus 请求，防止下游 bus_interconnect 收到非法路由。

---

## 后续迭代计划（Phase 4）

| 迭代 | 内容 | 验证标准 |
|------|------|---------|
| Iter 2 | UART stub → uart_ctrl（TX only）集成 | `UART_SMOKETEST_PASS` + `LIGHT_SMOKETEST_PASS` |
| Iter 3 | SPI stub → spi_ctrl 集成 | `SPI_SMOKETEST_PASS` + `LIGHT_SMOKETEST_PASS` |
| Iter 4 | DMA 扩展（SPI→SRAM 通路）| DMA smoke + `LIGHT_SMOKETEST_PASS` |
| Iter 5 | E203 接入（AXI-Lite master → axi2simple_bridge → interconnect）| 端到端固件验证 |

每次迭代完成后在本文档追加一节记录。
