# 07_tapeout_schedule - SNN SoC V1 流片时间规划

> **阅读指南**：本文主体（Phase 1–6）写于 2026-01-30 的**初始计划**，保留作为历史参考。
> **实际进度**远超原计划——截至 2026-03-20，Phase 1–5 及大部分 Phase 6 前置工作已全部完成。
> **请以文末 "2026-03-21 Status Sync" 节为当前真实状态**；主体中未勾选的 `[ ]` checkbox 大多已实际完成，不代表当前进度。

**项目目标**：2026年6月30日前完成 V1 版本流片
**起始日期**：2026年1月30日
**总工期**：5个月（22周）
**时钟频率目标**：50MHz
**流片类型**：V1 数字 SoC 单独流片 + 片外混合集成验证（V2/V3 再做片上数模混合集成）

---

## 重要说明

### 片外混合集成（V1）与片上集成（V2/V3）
V1 先完成数字 SoC 单独流片，并进行片外混合集成验证；V2/V3 再进行片上数模混合集成：
- 数字部分：本项目的RTL（SoC控制器、DMA、LIF神经元等）
- 模拟部分：真实CIM Macro（由其他同学提供版图）
- 片外验证方式：板级连接，接口时序与功能验证
- 片上集成方式：用真实CIM Macro替换 `cim_macro_blackbox` 行为模型
- 接口约定：保持 `cim_macro_blackbox.sv` 的端口定义不变

### 时钟频率
- 目标频率：**50MHz**（20ns周期）
- 选择原因：数模混合需要保守的时序裕量
- 综合约束：建议使用60MHz约束，留10%裕量

---

## V1 版本目标 vs 当前 MVP

| 模块 | V1 设计要求 | 当前状态（2026-03-21） | 完成阶段 |
|:---|:---|:---|:---:|
| RISC-V Core (E203) | 需要 | ✅ 已接入（最小面积裁剪，ICB→simple 直桥） | Iter 5-6 |
| 指令 SRAM 16KB | 需要 | ✅ 有 | MVP |
| 数据 SRAM 16KB | 需要 | ✅ 有 | MVP |
| 权重 Buffer 16KB | 需要 | ✅ 已改造（DMA 多目标写入） | Iter 4 |
| DMA 引擎 | 多目标 | ✅ 已支持 INPUT_FIFO / WEIGHT_SRAM / INSTR_SRAM | Iter 4 |
| 寄存器 Bank | 需要 | ✅ 有 | MVP |
| **SPI 控制器** | 需要 | ✅ 已集成 `spi_ctrl`（Mode 0，软件控 CS） | Iter 3 |
| **UART 控制器** | 需要 | ✅ 已集成 `uart_ctrl`（TX only，RX V1 占位） | Iter 2 |
| JTAG 接口 | 需要 | ✅ 已有最小 rescue JTAG（独立于 vendor DM） | Iter 7 |
| 输入 Spike FIFO | 需要 | ✅ 有 | MVP |
| 输出 Spike FIFO | 需要 | ✅ 有 | MVP |
| CIM 子系统 | 需要 | ✅ 有 | MVP |
| **系统总线** | AXI-Lite | ✅ AXI-Lite bridge 已独立验证，ICB→simple 主路径贯通 | Iter 1, 5 |

---

## 时间线总览

```
1月         2月              3月              4月              5月              6月
|--Phase 1--|----Phase 2----|----Phase 3----|----Phase 4----|----Phase 5----|--Phase 6--|Buffer|
  MVP学习     UART/SPI        DMA/总线扩展      AXI升级         E203集成        综合后端    片外集成
  (2周)       (3周)           (3周)            (3周)           (4周)          (4周)      (2周)
```

---

## Phase 1: MVP 学习和理解（2周）
**时间：1月30日 - 2月13日**

### 目标
- 完全理解当前 MVP 代码和架构
- 能独立修改参数并跑通仿真
- 理解 bit-serial 架构原理

### 第1周（1.30-2.6）：代码学习
| 日期 | 任务 | 交付物 |
|:---:|:---|:---|
| 1.30-1.31 | 阅读文档、理解系统架构 | 手绘系统框图 |
| 2.1-2.2 | 学习参数包、顶层、存储模块 | 参数笔记 |
| 2.3-2.4 | 学习总线、寄存器、DMA | 地址映射表 |
| 2.5-2.6 | 学习CIM子系统（重点） | 数据流笔记 |

### 第2周（2.7-2.13）：仿真实践
| 日期 | 任务 | 交付物 |
|:---:|:---|:---|
| 2.7-2.8 | 搭建仿真环境、跑通TB | 仿真log |
| 2.9-2.10 | Verdi波形分析 | 关键信号截图 |
| 2.11-2.12 | 理解bit-serial时序 | 时序分析文档 |
| 2.13 | 总结 & Phase 1 报告 | 学习报告 |

### 里程碑 M1（2月13日）
- [ ] 能画出完整系统框图（不看代码）
- [ ] 能解释 bit-serial 架构原理
- [ ] 仿真跑通，理解每个信号含义
- [ ] 能手算简单输入的预期输出

---

## Phase 2: UART 和 SPI 控制器（3周）
**时间：2月14日 - 3月6日**

### 目标
- 实现 UART 控制器（当前 main 已完成 TX only，若需要再补 RX FIFO/增强功能）
- 实现完整的 SPI 控制器（当前 main 已完成 V1：`spi_ctrl.sv`，Mode 0）
- 当前 `main` 已接入 `uart_ctrl.sv`（TX only）与 `spi_ctrl.sv`（Mode 0）；Phase 2 的收口标准调整为 UART/SPI 主线接入完成并通过回归，剩余增强项按需继续迭代。
- UART 和 SPI 可以并行开发

### 第3周（2.14-2.20）：UART 控制器
| 任务 | 预计时间 | 难度 |
|:---|:---:|:---:|
| 设计 UART TX FSM 和 FIFO | 2天 | ⭐⭐ |
| 设计 UART RX FSM 和 FIFO | 2天 | ⭐⭐ |
| 寄存器接口（DATA, STATUS, CTRL） | 1天 | ⭐ |
| Testbench 验证 | 2天 | ⭐⭐ |

**UART 规格**：
```
- 波特率：115200（50MHz时钟，分频系数=434）
- 数据格式：8N1（8数据位，无校验，1停止位）
- TX/RX FIFO：各16字节深度
- 寄存器：UART_DATA(0x00), UART_STATUS(0x04), UART_CTRL(0x08)
```

### 第4周（2.21-2.27）：SPI 控制器
| 任务 | 预计时间 | 难度 |
|:---|:---:|:---:|
| 设计 SPI Master FSM | 2天 | ⭐⭐ |
| TX/RX 移位寄存器 | 1天 | ⭐⭐ |
| 支持 Mode 0/3 | 1天 | ⭐⭐ |
| Testbench + Flash模型验证 | 2天 | ⭐⭐ |

**SPI 规格**：
```
- 模式：Master Only
- 支持：Mode 0 (CPOL=0, CPHA=0) 和 Mode 3 (CPOL=1, CPHA=1)
- 时钟：可配置分频（默认 SPI_CLK = 12.5MHz）
- 接口：CS, SCLK, MOSI, MISO
```

### 第5周（2.28-3.6）：集成与验证
| 任务 | 预计时间 |
|:---|:---:|
| UART/SPI 集成到顶层 | 2天 |
| 地址映射更新 | 1天 |
| 联合验证 | 3天 |
| 文档更新 | 1天 |

### 里程碑 M2（3月6日）
- [ ] UART：TB 发送 "Hello"，能正确回显
- [ ] SPI：TB 通过 SPI 读取 Flash 模型数据
- [ ] 两者集成到顶层，地址映射正确

### 验收标准
```systemverilog
// UART 验收：回显测试
uart_write(8'h48); // 'H'
uart_write(8'h69); // 'i'
assert(uart_read() == 8'h48);
assert(uart_read() == 8'h69);

// SPI 验收：读 Flash ID
spi_cmd(8'h9F); // JEDEC ID
assert(spi_read() == 8'hEF); // Winbond
```

---

## Phase 3: DMA 扩展和权重 Buffer（3周）
**时间：3月7日 - 3月27日**

### 目标
- DMA 支持多目标选择
- 实现独立的权重 Buffer
- 支持 SPI→SRAM 路径

### 第6周（3.7-3.13）：DMA 多目标支持
| 任务 | 预计时间 |
|:---|:---:|
| 新增 DMA_DST_SEL 寄存器 | 1天 |
| 支持 Input FIFO 目标 | 已有 |
| 支持 Weight Buffer 目标 | 2天 |
| 支持 Instruction SRAM 目标 | 2天 |
| 更新 Testbench | 2天 |

**DMA 目标选择**：
```systemverilog
localparam DST_INPUT_FIFO  = 2'b00;  // 当前已有
localparam DST_WEIGHT_BUF  = 2'b01;  // 新增
localparam DST_INSTR_SRAM  = 2'b10;  // 新增（从SPI加载固件用）
```

### 第7周（3.14-3.20）：权重 Buffer
| 任务 | 预计时间 |
|:---|:---:|
| 设计 16KB Weight Buffer | 2天 |
| 与 CIM 子系统连接 | 2天 |
| 地址映射更新 | 1天 |
| 验证 | 2天 |

### 第8周（3.21-3.27）：集成与稳定化
| 任务 | 预计时间 |
|:---|:---:|
| DMA + SPI 联合测试 | 3天 |
| 边界条件测试 | 2天 |
| 代码 Review | 1天 |
| 文档更新 | 1天 |

### 里程碑 M3（3月27日）
- [ ] DMA 能从 SPI 搬数据到 SRAM
- [ ] DMA 能从 SRAM 搬数据到 Weight Buffer
- [ ] DMA 能从 SRAM 搬数据到 Input FIFO（原有功能保持）

---

## Phase 4: AXI-Lite 总线升级（3周）
**时间：3月28日 - 4月17日**

### 目标
- 设计 AXI-Lite interconnect
- 现有 slave 保持 simple 接口（使用桥接）
- 为 E203 集成做准备

### 第9周（3.28-4.3）：AXI-Lite 接口设计
| 任务 | 预计时间 |
|:---|:---:|
| 定义 axi_lite_if.sv 接口 | 2天 |
| 设计 AXI-Lite interconnect | 3天 |
| 单元测试 | 2天 |

**AXI-Lite 信号**：
```systemverilog
// Write Address Channel
logic        awvalid, awready;
logic [31:0] awaddr;
// Write Data Channel
logic        wvalid, wready;
logic [31:0] wdata;
logic [3:0]  wstrb;
// Write Response Channel
logic        bvalid, bready;
logic [1:0]  bresp;
// Read Address Channel
logic        arvalid, arready;
logic [31:0] araddr;
// Read Data Channel
logic        rvalid, rready;
logic [31:0] rdata;
logic [1:0]  rresp;
```

### 第10周（4.4-4.10）：桥接与集成
| 任务 | 预计时间 |
|:---|:---:|
| 设计 axi2simple_bridge.sv | 3天 |
| 替换 bus_interconnect.sv | 2天 |
| 保持现有 slave 兼容 | 2天 |

### 第11周（4.11-4.17）：验证与稳定化
| 任务 | 预计时间 |
|:---|:---:|
| AXI VIP 或简单 Master TB 测试 | 3天 |
| 完整回归测试 | 2天 |
| 文档更新 | 2天 |

### 里程碑 M4（4月17日）
- [ ] AXI-Lite interconnect 设计完成
- [ ] 所有现有功能通过回归测试
- [ ] 准备好接入 E203

---

## Phase 5: E203 RISC-V Core 集成（4周）
**时间：4月18日 - 5月15日**

### 目标
- 集成蜂鸟 E203 RISC-V Core
- 编写 bootloader 和驱动固件
- 实现完整的 CPU 控制推理流程

### 第12周（4.18-4.24）：E203 下载与理解
| 任务 | 预计时间 |
|:---|:---:|
| 下载 E203 RTL | 1天 |
| 理解 E203 接口 | 3天 |
| 规划集成方案 | 2天 |
| 更新顶层设计 | 1天 |

**E203 资源**：
- GitHub: https://github.com/SI-RISCV/e200_opensource
- 文档: https://github.com/SI-RISCV/e200_opensource/tree/master/doc

### 第13周（4.25-5.1）：E203 集成
| 任务 | 预计时间 |
|:---|:---:|
| 修改顶层连接 E203 | 3天 |
| 连接 AXI 总线 | 2天 |
| 连接 JTAG（E203自带） | 1天 |
| 基础验证 | 1天 |

### 第14周（5.2-5.8）：Bootloader 开发
| 任务 | 预计时间 |
|:---|:---:|
| 编写 startup.S | 2天 |
| 编写 bootloader.c | 3天 |
| 链接脚本和 Makefile | 1天 |
| 验证启动流程 | 1天 |

**Bootloader 功能**：
```c
void main() {
    uart_puts("Boot OK\n");
    // 1. 初始化 DMA
    // 2. 从 Flash 加载数据到 SRAM
    // 3. 配置 SNN 寄存器
    // 4. 启动推理
    // 5. 读取结果
}
```

### 第15周（5.9-5.15）：驱动固件开发
| 任务 | 预计时间 |
|:---|:---:|
| SNN 驱动（寄存器操作） | 2天 |
| DMA 驱动 | 2天 |
| 完整推理测试 | 2天 |
| Bug 修复 | 1天 |

### 里程碑 M5（5月15日）
- [ ] E203 集成完成，能执行固件
- [ ] UART 输出 "Boot OK"
- [ ] CPU 控制完成一次完整推理
- [ ] 代码冻结（Code Freeze）

---

## Phase 6: 综合、后端与片外集成准备（6周）
**时间：5月16日 - 6月30日**

### 第16-17周（5.16-5.29）：综合（DC）
| 任务 | 预计时间 | 交付物 |
|:---|:---:|:---|
| DC 环境搭建 | 2天 | setup脚本 |
| 初次综合（50MHz约束） | 2天 | 初步网表 |
| 时序分析和优化 | 4天 | 时序报告 |
| 面积分析和优化 | 2天 | 面积报告 |
| DFT 插入（可选） | 2天 | DFT网表 |
| 综合签收 | 2天 | 最终网表 |

**综合约束示例**：
```tcl
create_clock -name clk -period 20.0 [get_ports clk]  # 50MHz
set_clock_uncertainty 0.5 [get_clocks clk]
set_input_delay 2.0 -clock clk [all_inputs]
set_output_delay 2.0 -clock clk [all_outputs]
```

### 第18-19周（5.30-6.12）：布局布线（ICC/Innovus）
| 任务 | 预计时间 | 交付物 |
|:---|:---:|:---|
| 后端环境搭建 | 2天 | setup脚本 |
| Floorplan | 2天 | DEF文件 |
| Placement | 2天 | 布局结果 |
| CTS | 2天 | 时钟树报告 |
| Routing | 3天 | 布线结果 |
| 时序收敛 | 3天 | 时序签收 |

### 第20-21周（6.13-6.26）：片外混合集成准备与验证
| 任务 | 预计时间 | 交付物 |
|:---|:---:|:---|
| 数模接口时序确认 | 2天 | 接口匹配报告 |
| 板级连接方案与测试计划 | 2天 | 测试计划 |
| 片外验证用的仿真/脚本准备 | 2天 | 仿真报告 |
| DRC/LVS 检查 | 4天 | DRC/LVS报告 |
| Metal Fill | 1天 | 最终GDS |
| GDSII 生成 | 1天 | GDSII文件 |
| Final Review | 2天 | 签收报告 |

### Buffer Week（6月27日 - 6月30日）
**预留4天应对突发问题**

### 里程碑 M6（6月30日）
- [ ] 综合完成，时序收敛（50MHz）
- [ ] 布局布线完成
- [ ] 片外混合集成准备完成
- [ ] DRC/LVS clean
- [ ] GDSII 提交

---

## 关键里程碑总表

| 日期 | 里程碑 | 检查点 |
|:---:|:---|:---|
| 2月13日 | M1: Phase 1完成 | 理解MVP代码和架构 |
| 3月6日 | M2: Phase 2完成 | UART/SPI 实现并验证 |
| 3月27日 | M3: Phase 3完成 | DMA扩展，权重Buffer |
| 4月17日 | M4: Phase 4完成 | AXI-Lite总线升级 |
| **5月15日** | **M5: Code Freeze** | **E203集成，代码冻结** |
| **6月30日** | **M6: Tapeout** | **GDSII提交** |

---

## 每周汇报机制

### 周报内容
1. 本周完成任务
2. 遇到的问题和解决方案
3. 下周计划
4. 风险预警

### 汇报时间
- 每周五下午提交周报
- 每两周一次进度 review 会议（建议周一）

---

## 风险评估

| 风险类别 | 风险项 | 概率 | 影响 | 缓解措施 |
|:---|:---|:---:|:---:|:---|
| 技术 | AXI总线复杂度 | 中 | 高 | 使用桥接方案，保持slave简单 |
| 技术 | E203集成困难 | 中 | 高 | 提前研究E203文档 |
| 技术 | 时序不收敛 | 中 | 高 | 保守目标50MHz |
| 技术 | 数模接口不匹配 | 低 | 高 | 提前与模拟团队对接 |
| 资源 | 工具license | 低 | 中 | 提前申请 |
| 进度 | 学习曲线陡峭 | 中 | 中 | 预留学习时间 |
| 进度 | 需求变更 | 低 | 高 | 控制scope |

---

## 应急预案

### 如果进度落后1周
- 减少功能增强范围（SPI可用TB模拟）
- 加班追赶
- 简化验证（减少边界测试）

### 如果进度落后2周以上
- 考虑简化 E203 集成（使用 picorv32 等更简单的核）
- 或者降级为 MVP+UART 版本流片
- 与导师讨论调整方案

### 数模集成风险
- 提前（4月底）与模拟团队确认接口时序
- 获取 CIM Macro 的 Liberty/LEF 文件
- 准备好 fallback 方案（仅数字部分流片）

---

## 成功标准

### 最低要求（必须完成）
- [ ] V1 功能完整（E203 + UART + SPI + AXI）
- [ ] 后仿真通过
- [ ] DRC/LVS clean
- [ ] GDSII 提交

### 理想目标
- [ ] 时钟频率达到 50MHz
- [ ] 面积 < 2mm^2（不含 CIM Macro）
- [ ] 功耗 < 20mW

### 加分项
- [ ] DFT 支持（scan chain）
- [ ] 完整的测试覆盖率报告
- [ ] 详细的设计文档

---

## 与早期草稿的关系

早期 `develop docs` 草稿目录已从仓库移除，原先文档内容已整合为当前正式版本：
- `CIM_Macro_Interface_Specification.md` → 已整合到 `03_cim_if_protocol.md`
- `MVP_Learning_Guide.md` → 已整合到 `06_learning_path.md`
- `Tapeout_Schedule.md` → 已整合到本文档

后续请以 `doc/*.md` 作为正式文档；若需要查看历史演进，请直接查询 Git 历史而不是依赖仓库内保留目录。

---

*初始版本：2026-01-30 / 最后更新：2026-03-21*

**注意**：Phase 1–5 已全部完成，当前处于 Phase 6 综合后端阶段。以文末 **2026-05-02 Status Sync** 为当前状态真源（覆盖 2026-03-31）。

## 2026-03-21 Status Sync（历史备份，已被上方 2026-03-31 节覆盖）

本文件主体仍保留原始阶段计划属性。**当前实际进度以本节为准，主体中带 `[ ]` 的里程碑大多已实际完成，请勿以主体 checkbox 状态判断当前进度。**

### 已完成

- ✅ `UART / SPI / DMA（多目标）/ AXI-Lite bridge` 已完成主线接入并通过独立 TB 与主链回归（对应 Iteration 1~4，2026-03-18）
- ✅ `E203` 已完成最小面积接入：裁剪 vendor config，ICB→simple 直接桥，不走 AXI 双桥路径（Iteration 5，2026-03-18）
- ✅ `bootloader / SPI 启动 / UART printf` 已在专用 E203 Icarus 仿真链路中跑通（Iteration 6，2026-03-19）
- ✅ `JTAG rescue loader` 已完成：自定义 4-wire TAP（IDCODE/MEMACC/CPUCTL），TCK↔CLK CDC 安全，SRAM-only 访问过滤，Python 主机工具及 256-cycle timeout 自动恢复（Iteration 7，2026-03-20）
- ✅ `chip_top` 已完成 tapeout-intent 信号直连（ENABLE_E203=1，ENABLE_EXT_CIM_IF=1），外部 CIM pad 接口已贯通
- ✅ 全量仿真回归：`LIGHT_SMOKETEST_PASS` / `WEIGHTED_SIM_PASS` / `SAMPLE_ALIGN_PASS(100/100)` / `E203_SMOKETEST_PASS` / `JTAG_MEM_LOADER_PASS` / `JTAG_RESCUE_TOP_PASS` 均通过

### 还未闭环的事项

- `chip_top` pad 级工艺 pad cell 实例化（ESD/drive strength/IO type 配置）
- TO 版本是否默认启用 E203 的冻结决策（当前 `chip_top` 显式置 `ENABLE_E203=1`，`snn_soc_top` 默认仍为 0，保护主回归）
- 综合 / PPA / 后端 P&R / DFT scan chain 插入 / STA 签核
- 板级 bring-up：boot image 格式完善 / JTAG rescue 实测 / 真实 SPI Flash 验证

## 2026-05-02 Status Sync（当前最新，DOC-C5 audit 追加）

### 已完成（自 03-31 sync 之后）

- ✅ **Iteration 10**（2026-04-22 ~ 04-23）：CIM 编程 (cim_program_ctrl + cim_macro_arbiter +
  prog_pulse_cfg) 完整集成；silicon_bringup firmware infra（PROG_CTRL.BYPASS_HANDSHAKE +
  silicon_bringup.c + boot_rom + fpga_bringup_capture.sh）落地
- ✅ **Iteration 11**（2026-04-24）：方案 α' 外部编程接口冻结；pad 总数从 48 升 55
  （46 signal + 6 power + 3 ESD-reserved），新增 `prog_op[2:0]` + `prog_level[3:0]`
  共 7 个 pad；boot_rom OOB / RETRY_LIMIT preserve / in-flight prog reg lock 三处加固
- ✅ **alpha tag 板级冻结**：`main-fpga-e203-alpha-passed @ 2adc327b` 已通过
  CIM_PROGRAM_CTRL（8 子测试）+ PROG_PULSE_CFG + PROG_INFLIGHT_LOCK + BOOT_ERASE_E2E
  四个新 sim gate
- ✅ **2026-05-02 pre-tape-out hard audit**（详见 doc/16_iteration_log.md Iter 13）：
  抓出 9 BLOCKER + 15 CONCERN + 15 MINOR，5 个 scoped commit 全部修复 + push origin/main
  - RTL B-1：chip_top BOOT_ROM_INIT_FILE 默认空 → 改 `fw/boot_rom/out/boot_rom.hex`
  - RTL B-2：cim_program_ctrl level=0/15 verify 窗口漏判 → 32-bit clamp [0,255]
  - FW B1：silicon_bringup 链接 0x0 → `link_app.ld` (0x1000)，与硅片 boot_rom 一致
  - FW C4：silicon_bringup hang() 加 uart_wait_idle 防 PASS marker 末字节丢
  - DOC B1：doc/06 prog_op 编码错（与 RTL 完全不一致）
  - 等等（详见 commits 1572b434 / fbbf84e8 / c1fda8e8 / f3970cbb / 95966e9b）

### 还未闭环的事项（Phase 6 后端 + 流片前 follow-up）

- `chip_top` pad cell 实例化（工艺库 pad cell / ESD / drive strength / IO type 配置）
- 综合 / PPA / 后端 P&R / DFT scan chain 插入 / STA 签核
- silicon_bringup_tb 切换到 chip_top + ENABLE_BOOT_ROM=1（FW B1 fix 后 TB false-negative，
  本次 audit 已切到 chip_top + stub ROM 路径）
- BYPASS_HANDSHAKE efuse/lock 决策（die 上是否有 OTP）
- DMA push 超时阈值（V2B_DMA_PUSH_TIMEOUT_CYCLES = 1M cycles，audit 加上后未做硅片测算）
- 流片目标日期：2026-06-30

### 风险评估

- 数字 RTL 功能已冻结，pre-tape-out audit 已修 9 个 BLOCKER；剩余 follow-up 都是
  validation / TB infra / fw 配套，不影响 RTL 冻结
- JTAG rescue + boot_rom mask ROM 双路径提供硅上 bring-up 保险
- CIM 模拟侧 pad 参数冻结于 doc/08 v3.0（2026-03-16），数字侧 2026-04-24 升 α'
  已与模拟同学 handoff（详见 doc/17_cim_macro_handoff_cover.md）
- silicon_bringup.elf 链接基址 fix（FW B1）后已自动重 build；硅片真实路径与 TB
  路径在本 audit 后首次对齐

---

## 2026-03-31 Status Sync（已被 2026-05-02 节覆盖，保留作历史）

### 已完成

- ✅ Phase 1–5 所有功能全部完成（Iteration 1–7），Phase 4 全量外设集成已通过独立 TB 与主链回归
- ✅ Iteration 8（2026-03-24）全量回归基线刷新，13 项仿真 + chip_top 编译/lint + 脚本语法门禁全部通过
- ✅ 2026-03-31 全面交叉审计（RTL / TB / sim scripts / 文档）：
  - 参数一致性 100%（snn_soc_pkg ↔ 文档 ↔ TB ↔ CLAUDE.md）
  - 寄存器地址 100% 正确（reg_bank / dma_engine / doc/02）
  - 所有 filelist 引用文件均存在，PASS 标准与 CLAUDE.md 完全一致
  - 无发现硬件阻塞级 bug
- ✅ **E203 冻结决策已明确**：`chip_top` 显式 `ENABLE_E203=1` + `ENABLE_EXT_CIM_IF=1`；`snn_soc_top` 默认值保持 `0` 以保护主回归

### 还未闭环的事项（Phase 6 后端）

- `chip_top` pad cell 实例化（工艺库 pad cell / ESD / drive strength / IO type 配置）
- 综合 / PPA / 后端 P&R / DFT scan chain 插入 / STA 签核
- 板级 bring-up：boot image 格式完善 / JTAG rescue 实测 / 真实 SPI Flash 验证
- 流片目标日期：2026-06-30

### 风险评估

- 数字 RTL 功能已冻结，无新增 feature；后端工作为主要时间消耗项
- JTAG rescue 提供了硅上救援路径，降低首次 bring-up 风险
- CIM 模拟侧 pad 参数冻结于 doc/08 v3.0（2026-03-16），数字侧无变更

---

## 2026-03-19 Status Sync（历史备份，已被上方覆盖）

- `UART / SPI / DMA / AXI-Lite bridge` 已完成主线接入并通过独立 TB 与主链回归
- `E203` 已完成最小面积接入
- `bootloader / SPI 启动 / UART printf` 已在专用 E203 仿真链路中跑通
- 当前真正还未闭环的是：
  - `chip_top` pad 级真实集成
  - TO 版本是否默认启用 E203 的冻结
  - 综合 / 后端 / DFT / 签核

因此，本文件中凡是把 `E203 / bootloader / SPI 启动` 写成“未来待做”的周计划，应理解为历史计划项，而不是当前真实状态。
