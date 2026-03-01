Smoke test 是"冒烟测试"（点火后不冒烟就算过），但要保证质量，必须逐模块深入验证。这也是为什么 `doc/06_learning_path.md` 中建议做模块级仿真的原因。

**参数口径**：默认参数与时序常量以 `rtl/top/snn_soc_pkg.sv` 为准，本文数值仅作说明，若不一致以 pkg 为准。

工程顺序：

1. RTL
2. TB + 仿真回归
3. Lint+FPGA
4. DC（综合）
5. LEC（RTL ↔ Netlist）
6. P&R
7. PT（后端时序，含多角）
8. LEC（Netlist ↔ P&R netlist，可选但常做）
9. DRC / LVS（签核）

要点

- LEC 通常做两次：综合后一次、布局布线后一次。
- PT 一般在 P&R 后做（或在 P&R 过程中反复跑）。
- DRC/LVS 放最后。 
## 前言：先完成V1基础功能，再加创新点

```
阶段1 (2周)：跑通smoke test + 学习06文档 ✅
阶段2 (3周)：添加UART + SPI控制器
阶段3 (3周)：DMA扩展（多目标支持）
阶段4 (3周)：AXI-Lite总线升级
阶段5 (4周)：E203集成 + bootloader + 固件验证  ← 这里是V1最低可流片版本
阶段6a (2周)：挑选低风险创新点逐个添加（64×16映射、活动检测、时钟门控）- 每个创新点都要有对比测试（加前 vs 加后）
阶段6b (4周)：综合 + 时序优化 + 数字后端 + 流片
```

**优势**：

- ✅ 确保6.30前有**可流片的完整V1**（即使创新点来不及也能流片）
- ✅ E203集成后，创新点的软件验证环境已具备
- ✅ 每个阶段独立，问题隔离性好
- ✅ 符合工程界"先跑通、再优化"的最佳实践
- 每个创新点都要有对比测试（加前 vs 加后）
### 为什么这些创新点可以后置？

#### 核心原因：**模块化设计 + 非侵入式优化**

|创新点|类型|对核心架构影响|可否独立开关|
|---|---|---|---|
|64×16映射|数据重排|仅DMA取数顺序|✅ 可用参数控制|
|Shadow Buffer|侧挂模块|零影响|✅ 可选例化|
|稀疏检测|FSM分支|FSM加判断|✅ 可用ifdef控制|
|活动检测|FSM分支|FSM加计数器|✅ 可用ifdef控制|
|时钟门控|功耗优化|零功能影响|✅ 综合时可选|
#### 设计优势

1. **风险隔离**：每个创新点独立，不会相互干扰
2. **A/B测试**：可以用参数控制开关，对比有无优化的性能差异
3. **渐进式验证**：先跑通基础功能，再逐个加优化，每次都能回退
4. **时间灵活**：基础功能是硬deadline，创新点是加分项
#### 分支管理策略

```bash
main                    # 主分支：始终保持可流片状态
├── feature/64x16       # 功能分支：64×16映射
├── feature/shadow-buf  # 功能分支：Shadow Buffer
└── feature/sparsity    # 功能分支：稀疏检测
```

每个创新点在自己的分支开发，验证通过后合入main，**main分支随时可流片**。
#### 与模拟团队的协调流程

1. **现在（数字侧）**：
    
    - 按照估算值（5/10/5）完成数字设计
    - 接口信号定义已冻结 ✅
    - 接口协议（握手时序）已冻结 ✅
2. **模拟侧开发**：
    
    - 按照doc/08的**信号定义**和**握手协议**设计CIM macro
    - 时序参数（延迟周期）可以暂时参考估算值
3. **联调阶段**（模拟设计完成后）：
    
    - 模拟团队提供实际时序：
        - DAC实际需要X周期建立
        - CIM实际计算需要Y周期
        - ADC实际转换需要Z周期
    - 数字侧**只需修改3个参数**，重新仿真验证
    - **不需要改任何接口信号定义** ✅
## 一、版本迭代安排

### ✅ 推荐路线（V1 → V2 → V3）

### **V1（6/30 这次）**

- **数字 SoC 单独流片**
- 目标：时序正确、功能跑通、E203 + DMA + FIFO + 控制器全稳定
- 这一步风险最小、最容易成功
### 与此同时，与数字SoC V1同时进行，其他同学负责：模拟CIM MACRO的设计与流片（阵列采用二维材料RRAM）

单独TAPE OUT: 模拟宏 + RRAM后道集成（二维材料RRAM作为CIM MACRO的阵列）

- 目标：验证器件稳定性、写读一致性、ADC/DAC 可靠性
- 不牵扯整个 SoC，便于定位问题
### **数字和模拟部分分别测试成功后，进行：片外数模混合集成**

- 在前两步都成熟的前提下，做 **系统级混合集成**
- 这一步成功率最高，风险最可控
### **这次 V1（6/30）**

- 只做**难度低、风险小**的数字创新点
- 目标：**能稳定跑通、能解释清楚、可复现**
### **V2 / V3等**

- 等数字和模拟都验证成功后
- 再上**复杂创新点**（比如事件驱动、自动校准、智能搬运等）
- 数字部分和模拟部分分别再流一次验证-----V2
- 最后做数模片上混合集成----V3
---
## 二、创新点规划
### ✅ 基于 Excel 统计“共性痛点”的总体判断

（放在这里，作为后续创新点的依据）

- **数据搬运与存储访问是系统级主要瓶颈**  
    多篇论文明确指出 L2/L1/SRAM 访问频繁、搬运能耗占比高（DIANA、SENECA、C‑DNN、ODIN）。
    
- **CPU 参与度过高是吞吐与能效问题的根源之一**  
    vMCU 类论文指出中断/轮询造成瓶颈，事件 FIFO 频繁打断 CPU。
    
- **系统级指标经常不完整**  
    只给峰值能效但缺少端到端数据流瓶颈分析。
    
- **模拟 CIM 可靠性与漂移是核心痛点**  
    RRAM 误码、漂移、温度敏感，在 ISSCC 2023 等文章中是系统级问题。
    
- **可扩展性受存储容量/互连带宽限制**  
    Darwin/SENECA 等强调 NoC/SRAM 成为规模瓶颈。

### ✅ V1（这次 6/30 数字单独流片）

**原则：低风险、易验证、能在论文里说清楚**

已经做的：

1. ✅ **单张图多次呈现**（多帧重复输入）- 通过 TIMESTEPS/THRESHOLD 调节
2. ✅ **单张图单次推理** - 最快，但需降低阈值（如50-100）
3. ✅ **视频/时序识别** - 利用LIF累积特性，记住时序信息

**只需调整**：

- `TIMESTEPS` 寄存器值
- `THRESHOLD` 寄存器值
- testbench中的输入数据

**硬件完全通用，无需修改RTL代码。**

---
### 1) 逻辑 64×16，物理 64×20（Scheme B 差分窗口）的映射
**添加时机**：V1 任意阶段（不依赖 CPU/AXI，最早即可加）

**为什么值得做？**

- 逻辑维度用 2 的幂次方（64×16）后，地址映射可以用简单位移完成
- 软件写固件时省掉大量 `if (col >= 64)` 判断
- 总线访问效率更高，调试成本更低

**你做了什么创新？**

- 提出“**逻辑地址空间对齐 + 越界过滤**”策略
- 这属于 SoC 数字接口层面的工程优化创新

**解决的痛点（来自 Excel 统计）**

- 多篇论文指出 **数据搬运与地址管理复杂** 是系统瓶颈
- 你把复杂地址处理变成固定映射，从源头降低出错率

✅ **本次必做**（风险极低，收益很大）

---
### 2) 轻量版 Shadow Buffer（只做寄存器缓冲 + done 标志）
**添加时机**：V1 早期可做缓冲本体；若要“中断通知/CPU 协同”，放到 V1 后期（E203 集成后）

**注意：这里不是“做 DMA”，而是“结果集中读”**

**为什么值得做？**

- 当前 ADC 是单通道时分复用
- 结果产生在多个时刻，如果 CPU 轮询，会浪费大量周期
- Shadow Buffer 把 10 个结果集中存起来，CPU 只读一次

**你做了什么创新？**

- **“集中结果缓冲 + 一次性读取”**
- 属于 SoC 级数据整理优化

**解决的痛点（来自 Excel 统计）**

- vMCU 类论文痛点：**CPU 轮询/中断负担大**
- 你的方案直接减轻 CPU 读寄存器次数

✅ **本次可以做（难度中、收益明显）**

---
### 3) 稀疏性检测
**添加时机**：V1 任意阶段即可（统计功能与 CPU 无关；策略控制放 V2）

**稀疏性统计 / 监控**

- 在 DMA/输入 FIFO 旁做一个**“非零计数器”**
- 统计输入是否稀疏
- 作为系统能耗监控的量化指标
- **V1 可做（很轻）**，但“用于策略控制”放到 V2

**对应痛点（来自 Excel 统计）**

- 多篇论文强调 **系统级能耗缺少数据证据**
- 你通过稀疏统计提供“系统级证据”

✅ **本次推荐**

---
### 4) 活动检测 + 计算跳过
**添加时机**：V1 任意阶段即可（改 FSM 逻辑，不依赖 CPU/AXI）

**做法** 
当 input_fifo 为空、或某个 bit‑plane 全 0 时，**不触发 CIM/ADC/LIF**。  
这就是“同步版 HUS（跳过无效计算）”。

**对应痛点（来自 Excel 统计）**

- 多篇论文提到 **无效计算导致能耗高**
- 你的方案是最简单、最可解释的能效优化之一

✅ **本次推荐**

---
### 5) 层级使能门控（简化版）
**添加时机**：V1 任意阶段即可（同步 enable/clock‑enable，不依赖 CPU）

**做法**  
不是异步电路，只是同步下的 enable/clock-enable。  
空闲时关闭 CIM/ADC/LIF 的时钟或使能，节能好讲故事。

**对应痛点（来自 Excel 统计）**

- 多篇论文指出空闲功耗高、控制逻辑复杂
- 你的门控策略是低风险的节能亮点

✅ **本次推荐**

---
### ✅ V2 & V3（等模拟宏 + RRAM 成熟后再上）

**原则：价值高，但风险高、强依赖模拟**

---
### 1) Program‑and‑Verify FSM（自动写‑读‑验）
**添加时机**：V2（模拟宏 + ADC 稳定之后）

**为什么这条不要本次做？**

- RRAM 不稳定，需要写入后再读出验证
- 该流程必须依赖模拟宏 + ADC 支持
- 模拟宏没稳定时做会增加系统风险

**你做了什么创新？**

- **把写‑读‑验循环从 CPU 卸载到硬件 FSM**
- 这是 SoC 层面的系统级创新点

**解决的痛点（来自 Excel 统计）**

- RRAM 误码与漂移是多个论文的系统级问题
- 你的 FSM 直接对应“可靠性控制路径”

✅ **建议下次做**

---
### 2) Reference Column + 动态校准
**添加时机**：V2/V3（需要宏物理结构支持，建议在混合集成前完成）

**为什么不要本次做？**

- 需要模拟宏物理结构支持（多 1–2 列）
- 校准模型与模拟偏移紧密耦合
- 初次流片风险极高

**你做了什么创新？**

- **数字侧自动动态补偿**
- 作为系统级鲁棒性创新点

**解决的痛点（来自 Excel 统计）**

- RRAM 漂移与温漂导致输出不稳定
- 你的方案用于长期可靠性

✅ **建议下次做**

---
### 3) CPU 层面的创新

#### ✅ 创新点 A：保持无 FPU，禁止浮点解码路径
**添加时机**：V1（E203 集成阶段即可配置）

**痛点**：SNN/TinyML 不用浮点，但通用 CPU 的浮点单元面积和功耗高  
**创新点**：明确配置禁用 FPU，并在能效分析里说明“无浮点 CPU 路线”  
**价值**：面积与静态功耗降低，控制路径更简单  
**备注**：你当前配置已经无 FPU，可以作为设计选择写进论文。

---
#### ✅ 创新点 B：基于 NICE 的 SNN 专用算术指令
**添加时机**：V1 后期或 V2（E203 集成后再做，工作量较大）

**痛点**：SNN 在 CPU 上做 bit‑plane / popcount / threshold 很慢  
**创新点**：在 E203 的 NICE 接口加专用算术单元  
**价值**：降低软件开销，提高吞吐/能效

---
#### ✅ 创新点 C：轻量 SIMD / packed 操作
**添加时机**：V2（E203 集成后，作为扩展执行单元）

**痛点**：大量低比特运算，普通 32‑bit ALU 效率低  
**创新点**：支持 8bit/4bit packed 运算  
**价值**：同频吞吐更高

---
#### ✅ 创新点 D：结果 buffer + 中断机制
**添加时机**：V1 后期或 V2（E203 集成且中断通路打通后）

**痛点**：CPU 轮询 ADC/FIFO 浪费能量  
**创新点**：结果缓冲区 + 完成中断  
**价值**：降低控制能耗，提高系统效率

---
#### ✅ 创新点 E：关闭不必要的多周期单元
**添加时机**：V1（E203 集成阶段可直接配置裁剪）

**痛点**：Mul/Div 对 SNN 价值不大  
**创新点**：关掉 MULDIV 或共享模式  
**价值**：减少面积与动态功耗

---
### 4) 权重复用（迁移思路）
**添加时机**：V2（DMA/权重 Buffer 路径稳定后再做缓存优化）

**原始来源（C‑DNN）：** 寄存器缓存权重窗口，节省 SRAM 访问能耗  
**你的迁移方式：**

- CIM 权重在宏里，不适合照搬
- 但你可以做 **神经元状态/阈值的寄存器缓存**
- **V2 可做**，V1 只写“启发来源”即可

---
### 5) 数锁相（数字PLL）
**添加时机**：V2/V3（多时钟域或低功耗动态调频需求出现后再做）

**痛点**：固定时钟导致空闲功耗浪费，ADC/控制逻辑对时钟频率需求不一致  
**创新点**：引入数字PLL，实现工作/空闲双频或多时钟域协同  
**价值**：降低动态功耗，提升系统频率灵活性与可扩展性

## 三、当前V1版本的内部迭代思路

### V1 改进路线

> **注意**：本文件为早期规划草稿。正式的时间规划和学习路径请参见：

> - [doc/07_tapeout_schedule.md](doc/07_tapeout_schedule.md) - **流片时间规划（V1完整路线图）**

> - [doc/06_learning_path.md](doc/06_learning_path.md) - **学习路径（新手必读）**

### 📊 当前 MVP vs V1 设计文档对比

| 模块编号 | V1 设计要求 | 当前 MVP 状态 | 差距 |

|---------|-------------|---------------|------|

| ① | RISC-V Core (蜂鸟 E203) | ❌ 无，TB模拟 | 🔴 新增 |

| ② | 指令 SRAM 16KB | ✅ 有 (16384B) | ✅ 匹配 |

| ③ | 数据 SRAM 16KB | ✅ 有 (16384B) | ✅ 匹配 |

| ④ | 权重 Buffer 16KB | ⚠️ 有 weight_sram，但非独立 Buffer | 🟡 改造 |

| ⑤ | DMA 引擎 | ✅ 有 | 🟡 需扩展目标 |

| ⑥ | 寄存器 Bank | ✅ 有 | ✅ 基本匹配 |

| ⑦ | SPI 控制器 (连Flash) | ❌ 仅 stub | 🔴 新增 |

| ⑧ | UART 控制器 (与PC通信) | ❌ 仅 stub | 🔴 新增 |

| ⑨ | JTAG 接口 | ❌ 仅 stub | 🟡 可后期 |

| ⑩ | 输入 Spike FIFO 256×64bit | ✅ 有 | ✅ 匹配 |

| ⑪ | 输出 Spike FIFO 256×4bit | ✅ 有 | ✅ 匹配 |

| ⑫ | CIM 阵列控制器 | ✅ 有 | ✅ 匹配 |

| ⑬ | DAC 控制器 | ✅ 有 | ✅ 匹配 |

| ⑭ | ADC 控制器 | ✅ 有 | ✅ 匹配 |

| ⑮ | CIM Macro 黑盒 | ✅ 有 | ✅ 匹配 |

| ⑯ | 数字神经元 (10×LIF) | ✅ 有 | ✅ 匹配 |

| - | 系统总线 | bus_simple_if | 🔴 需升级 AXI |

---
### 🎯 需要改进的 6 个方面（按优先级排序）

### **改进 1：UART 控制器** 🟢 优先级最高

**原因**：V1 的核心数据流是 `PC → UART → CPU → SRAM`，没有 UART 就无法与外部通信

**当前状态**：`uart_stub.sv` 只是空壳

**添加时机**：阶段 1（现在就可以做，不依赖 CPU/AXI；可先用 TB 验证收发）

**需要实现**：

```

rtl/periph/uart_ctrl.sv  ← 替换 uart_stub.sv

├── 波特率配置 (115200 default)

├── TX FIFO + 发送FSM

├── RX FIFO + 接收FSM

└── 寄存器接口 (DATA, STATUS, CTRL)

```

**工作量**：~200 行，难度 ⭐⭐

---
### **改进 2：SPI 控制器** 🟢 优先级高

**原因**：启动路径是 `Flash → SPI → DMA → 指令SRAM`，没有 SPI 无法加载固件

**当前状态**：`spi_stub.sv` 只是空壳

**添加时机**：阶段 2（现在就可以做，不依赖 CPU/AXI；与 UART 可并行）

**需要实现**：

```

rtl/periph/spi_ctrl.sv  ← 替换 spi_stub.sv

├── SPI Master 模式

├── 支持 Mode 0/3

├── CS/CLK/MOSI/MISO 控制

├── TX/RX FIFO

└── 寄存器接口

```

**工作量**：~250 行，难度 ⭐⭐

---
### **改进 3：DMA 引擎扩展** 🟡 优先级中

**原因**：V2 需要 DMA 支持多个目标（Input FIFO / 权重 Buffer / SRAM）

**当前状态**：只支持 `data_sram → input_fifo`

**添加时机**：阶段 3（依赖 SPI 作为数据源；不依赖 CPU）

**需要扩展**：

```systemverilog

// dma_engine.sv 修改

// 新增 DMA_DST_SEL 寄存器

localparam DST_INPUT_FIFO  = 2'b00;  // 当前已有

localparam DST_WEIGHT_BUF  = 2'b01;  // 新增

localparam DST_INSTR_SRAM  = 2'b10;  // 新增 (从SPI加载固件)

```

**工作量**：~100 行修改，难度 ⭐⭐

---
### **改进 4：总线升级 (AXI-Lite)** 🔴 优先级中

**原因**：E203 使用 AXI 接口，当前 `bus_simple_if` 不兼容

**当前状态**：自定义简化总线

**添加时机**：阶段 4（必须在 E203 集成之前完成）

**需要实现**：

```

rtl/bus/axi_lite_if.sv       ← 新增 AXI-Lite 接口定义

rtl/bus/axi_interconnect.sv  ← 替换 bus_interconnect.sv

rtl/bus/axi2simple_bridge.sv ← 可选：桥接现有slave

```

**策略选择**：

- **方案A**：全部 slave 改成 AXI 接口（工作量大）

- **方案B**：interconnect 内部转换，slave 保持 simple 接口（推荐）

**工作量**：~400 行，难度 ⭐⭐⭐

---
### **改进 5：RISC-V Core 集成 (E203)** 🔴 优先级低（最后做）（要对面积进行压缩）

**原因**：需要先完成总线升级，否则无法连接

**添加时机**：阶段 5（AXI-Lite 完成之后；依赖前面 1–4 阶段打底）

配置精简
|关 cache / MULDIV / debug / optional CSR
✅ 这也是“减实体”的核心手段

**步骤**：

```

1. 下载 E203 RTL：https://github.com/SI-RISCV/e200_opensource

2. 集成到顶层，连接 AXI 总线

3. 编写启动代码 (bootloader)

4. 编写驱动程序 (C代码控制DMA、读写寄存器)

```

**工作量**：~500 行集成 + 固件开发，难度 ⭐⭐⭐⭐

---
### **改进 6：JTAG 调试接口** 🟢 优先级最低

**原因**：E203 自带 JTAG，集成 Core 时一并处理即可

**当前状态**：`jtag_stub.sv` 空壳

**添加时机**：阶段 5（与 E203 集成同步处理）

**处理方式**：集成 E203 时直接使用其 JTAG 模块

---
### **改进 7：中断支持 (IRQ)** 🟡 优先级中（E203 集成阶段同步添加）

**原因**：当前 CIM done / DMA done 均需 CPU 轮询寄存器检测（`while(!(ctrl & DONE_BIT))`），E203 集成后每次推理期间 CPU 白白空转，浪费功耗。加入 IRQ 后 CPU 进入 WFI 休眠等中断唤醒，是论文能效对比的标准做法，也是"创新点 D：结果 buffer + 中断机制"的 RTL 实现部分。

**当前状态**：`reg_bank.sv` 有 `done_sticky_cim` / `dma_engine.sv` 有 `done_sticky`，但无 IRQ 输出引脚。

**添加时机**：阶段 5（E203 集成时同步添加，~30 行 RTL，不依赖其他新 IP）

**需要修改的文件**：

```
rtl/reg/reg_bank.sv     ← 新增 irq_cim / irq_dma 输出端口（done_sticky 上升沿检测）
rtl/top/snn_soc_top.sv  ← 将 irq_cim | irq_dma 汇总后连接 E203 外部中断输入
```

**RTL 实现要点（约 30 行）**：

```systemverilog
// reg_bank.sv 新增端口与逻辑（示意）
output logic irq_cim,   // CIM 推理完成中断（上升沿单拍脉冲）
output logic irq_dma,   // DMA 传输完成中断（上升沿单拍脉冲）

// done_sticky 上升沿检测 → 单拍 IRQ 脉冲
logic done_cim_r, done_dma_r;
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin done_cim_r <= 1'b0; done_dma_r <= 1'b0; end
  else        begin done_cim_r <= done_sticky_cim; done_dma_r <= done_sticky_dma; end
end
assign irq_cim = done_sticky_cim & ~done_cim_r;  // 上升沿 → 1 拍高
assign irq_dma = done_sticky_dma & ~done_dma_r;

// snn_soc_top.sv：汇总到 E203 的单根外部中断线
// 注意：低/高有效极性请以 E203 实例端口定义为准
assign ext_irq_n = ~(irq_cim | irq_dma);  // 低有效示例
```

**固件侧（C 代码，约 20 行）**：

```c
// 使能外部中断，设置中断向量
ECLIC_SetVector(IRQ_EXT, snn_done_isr);
ECLIC_EnableIRQ(IRQ_EXT);
__asm volatile("csrsi mstatus, 0x8"); // mstatus.MIE = 1

// 启动推理后进入低功耗等待
reg_write(REG_CIM_CTRL, 0x1);  // START
__asm volatile("wfi");          // 等中断唤醒（比轮询省电）

// 中断处理函数
void snn_done_isr(void) {
    // W1C 清 done_sticky，防止重复触发
    reg_write(REG_CIM_CTRL, reg_read(REG_CIM_CTRL) | (1u << 7));
    // 读取推理结果
    uint32_t cnt = reg_read(REG_OUT_COUNT);
    for (uint32_t i = 0; i < cnt; i++) spike_buf[i] = reg_read(REG_OUT_DATA);
}
```

**工作量**：~30 行 RTL + ~50 行固件，难度 ⭐⭐

---
### 📋 建议的改进顺序

```

1. AXI-Lite 基础骨架先上
    - 先做 axi_lite_if + interconnect + axi2simple_bridge，用 TB master 验证读写通路。
    - 原因：E203 后接入都依赖它。
2. UART
    - 先实现最小可用（TX/RX + 状态寄存器），用于后续 bring-up 打印日志。
3. SPI
    - 先做 Flash 读路径（读 ID + 连续读），暂不追求复杂模式。
    - 为 boot/data load 做准备。
4. DMA 扩展
    - 先打通 SPI -> SRAM，再 SRAM -> input_fifo。
    - 每条路径单独写 TB，确认 done/err/busy。
5. E203 最后接入

- 先跑最小固件：UART 打印 -> SPI 读 -> DMA 搬运。
- 这样出问题容易定位（不是全系统一起炸）。
```

---
### 🔧 每个阶段的验收标准

| 阶段 | 验收标准 |

|------|----------|

| 1 | TB 通过 UART 发送 "Hello"，能正确回显 |

| 2 | TB 通过 SPI 读取 Flash 模型中的数据 |

| 3 | DMA 能从 SPI 搬数据到 SRAM，从 SRAM 搬到 Weight Buffer |

| 4 | 用 AXI VIP 或简单 AXI Master TB 完成读写测试 |

| 5 | E203 执行固件，通过 UART 输出 "Boot OK"，完成一次推理 |

---
### 💡 我的建议

1. **阶段 1-2 可以并行开发**，UART 和 SPI 相互独立

2. **阶段 3 依赖阶段 2**，因为需要 SPI 作为 DMA 的数据源

3. **阶段 4-5 是大工程**，建议在前 3 个阶段稳定后再进行

4. **如果时间紧张**，可以先跳过 SPI，用 TB 直接初始化 SRAM 内容（仿真够用）

## FPGA 测试流程（历史展开，执行以 doc/12 为准）

> 本节保留历史展开说明；当前执行口径请优先使用 `doc/12_fpga_validation_guide.md`（详细）与 `doc/09_smoke_test_checklist.md`（冒烟步骤）。
> 若与本文其他旧描述冲突，以 `doc/12`、`doc/09` 和 `rtl/top/snn_soc_pkg.sv` 为准。

你的理解大方向对，但有几个关键细节：

### 1. 整体流程

```
                        开发机 (PC)
                           │
         ┌─────────────────┼──────────────────┐
         │                 │                  │
    ① Vivado          ② 固件编译        ③ 运行/调试
    综合+实现          RISC-V GCC          UART 串口
    生成 bitstream     生成 .bin/.hex       观察结果
         │                 │                  │
         ▼                 ▼                  ▼
    ┌────────────────────────────────────────────┐
    │              FPGA 板                        │
    │  ┌───────┐  ┌──────┐  ┌────┐  ┌─────────┐ │
    │  │E203   │─►│AXI   │─►│UART│─►│ TX pin  │──── PC 串口
    │  │CPU    │  │Lite  │  └────┘  └─────────┘ │
    │  │       │  │ bus  │─►┌────┐              │
    │  │(ROM有 │  │      │  │SPI │              │
    │  │bootldr│  │      │─►├────┤              │
    │  └───────┘  │      │  │DMA │              │
    │             │      │─►├────┤              │
    │             │      │  │SNN │              │
    │             │      │  │ctrl│              │
    │             └──────┘  └─┬──┘              │
    │                         │                 │
    │              ┌──────────┴──────────┐      │
    │              │CIM behavioral model │      │
    │              │(FPGA 用 BRAM 模拟   │      │
    │              │ 权重查找表)          │      │
    │              └─────────────────────┘      │
    └────────────────────────────────────────────┘
```

### 2. 具体步骤

**Step 1: Vivado 工程**

- 所有 RTL（含 E203）加入 Vivado 工程
- CIM macro blackbox 用 **FPGA 版行为模型**替代（当前的 behavioral model 就可以用，或者用 BRAM 做权重 LUT）
- 加约束文件（.xdc）：时钟、引脚分配、UART TX/RX 对应板子的物理 pin
- 综合 → 实现 → 生成 bitstream

**Step 2: 固件编译**

```bash
# RISC-V 交叉编译
riscv32-unknown-elf-gcc -march=rv32imc -O2 -o snn_test.elf snn_test.c
riscv32-unknown-elf-objcopy -O binary snn_test.elf snn_test.bin
```

**Step 3: 烧录与运行**

- 方式 A：**JTAG 加载** — 通过 JTAG 把 bitstream 烧到 FPGA，再通过 JTAG/OpenOCD 把固件写入 SRAM
- 方式 B：**UART Bootloader** — E203 ROM 里放一个小 bootloader，上电后通过 UART 接收 .bin 文件写入 SRAM，然后跳转执行
- 方式 C（最简单）：**固件直接打包进 bitstream** — 用 `$readmemh` 把 .hex 文件预加载到 SRAM 的初始值，这样 FPGA 一上电就直接运行，不需要额外加载步骤

**Step 4: 观察结果**

- UART 输出推理结果到 PC 串口终端
- Vivado ILA（集成逻辑分析仪）抓内部波形，替代仿真里的 `$display`
- 可以对比：FPGA 跑出来的 spike 结果 vs RTL 仿真结果 vs Python 模型结果

### 3. CIM macro 在 FPGA 上怎么处理

这是关键问题——RRAM 阵列无法在 FPGA 上实现。两种方案：

|方案|做法|优劣|
|---|---|---|
|**A. 行为模型**|直接用当前 `cim_macro_blackbox.sv` 的仿真模型（去掉 `ifdef SYNTHESIS`）|最简单，但不能验证真实权重|
|**B. BRAM 权重表**|用 FPGA BRAM 存一份预训练好的 10×64 权重矩阵，CIM 计算改为矩阵乘法查表|更真实，能跑真实 MNIST 图片验证准确率|

**建议用方案 B**，把 Python 训练好的量化权重（4-bit, 10×64）导出为 `.hex` 文件，加载到 BRAM，FPGA 上的 CIM 模块做数字乘累加。这样你能在 FPGA 上验证：

- 完整数据通路正确性
- 真实 MNIST 图片的分类结果
- UART 上位机交互

唯一验不了的是模拟特性（IR drop、ADC 非理想性、RRAM 变异性），这些必须等流片后测。

### 4. 你需要准备的 FPGA 板子

选一块有 UART 接口的 Xilinx FPGA 即可，常见选择：

- **Digilent Arty A7** (Artix-7) — 最流行的 RISC-V 开发板，E203 官方就有 Arty 移植
- **Nexys A7** — 资源更多，带更多 IO

E203 官方项目（蜂鸟 E203）就有 Arty A7 的参考设计，可以直接参考它的引脚约束和时钟配置。

整体是准的，能直接用。只有 3 个点我建议你修正一下口径，避免后面踩坑：

1. “建议用方案 B（BRAM 权重表）”这句要改成“V1 bring-up 先 A，再 B”  
- 先用行为模型 A 验证 SoC 控制链路（最快、最稳）。  
- 再上 B 做“近真实算法”验证。  
- 你现在目标是先把系统跑通，不是先追算法精度。

2. “E203 ROM 里放 bootloader”不是必须  
- 对首次 FPGA 联调，最省事是他说的方式 C：`$readmemh` 预加载。  
- JTAG/UART bootloader 放到第二阶段再做，不然调试面太大。

3. “FPGA 上 CIM 做数字乘累加”要明确这是替代模型，不等价模拟宏  
- 可验证数据流/控制流/固件流程。  
- 不可替代模拟非理想（IR drop、噪声、漂移）验证。  
- 这点你组会上要讲清楚，避免别人误解“FPGA 已验证 CIM”。

结论：Claude 这版流程可执行，技术上基本正确。你按它做没问题，但建议执行顺序用“先通路后精度”的两阶段策略。
## 四、看论文的方法
### 1) 只看 “SoC / 系统数字部分” 的阅读顺序（从系统到细节）

**优先级 1（系统级 SoC 视角，必读）**

1. A_RISC-V_Neuromorphic_Micro-Controller_Unit_vMCU...pdf
2. DIANA_An_End-to-End_Hybrid_DIgital_and_ANAlog_Neural_Network_SoC...pdf
3. SENECA building a fully digital neuromorphic processor...pdf
4. Darwin__A neuromorphic hardware co-processor...pdf / darwin3.pdf
5. ODIN (UCLouvain).pdf

**优先级 2（SoC 集成 + 能耗表格有价值）**  
6) ANP-I_A_28-nm_1.5-pJ_SOP...pdf  
7) C-DNN_An_Energy-Efficient...pdf  
8) A_73.53TOPS_W...SoC...pdf

> **注意**：CIM 类论文你只关注**系统级功耗/数据搬运/控制/缓存结构**，跳过宏电路细节。

**从 6/30 流片的节奏来看，把截图里的这些文章吃透就够了**，然后就应该**尽快确定创新点并开始工程实现**，而不是无限扩展阅读。

---
### 为什么“读这些就够了”

- 你现在的目标是 **V1 可流片、能解释、能写论文**
- 你负责的是 **SoC 数字系统部分**
- 截图里的文章已经覆盖了：
    - SoC 架构
    - 系统级能耗瓶颈
    - 典型系统级设计思路

继续加论文只会**增加阅读负担，不一定增加创新点**。

---
### 推荐节奏（最现实）

### ✅ 1）只精读截图里的 8 篇

重点只做“问题提炼表”。  
**每篇只要 30–60 分钟**，不要陷进去。

### ✅ 2）用这 8 篇确定 2–3 个创新点

就可以开始工程实现了。

### ✅ 3）后续再补读

如果你发现创新点不够强，**再补读一两篇**即可。

---
### 我的建议总结

✅ **是的：这 8 篇足够支撑你确定创新点并开干**  
✅ **不要陷在无止境扩展阅读**  
⚠️ 若后续写论文发现引用不够，再补 1–2 篇

---
## 五、文章必要准备

1. **降采样方式对比**：列出平均池化 / 最大池化 / 双线性 / 最近邻等降采样方式，用 Python 建模仿真对比准确率，选择准确率最高的一种作为固定预处理方案，并在文中解释选择理由。  
2. **ADC 位数评估**：建立量化建模流程，扫描 8/10/12/14-bit 等不同 ADC 精度，评估准确率变化曲线，确定“满足算法要求的最低 ADC 位数”，并写入系统设计参数选择依据。
## 各 Phase 详解

### Phase 1：数据准备

```
MNIST 原图 28×28
    ↓ resize（双线性插值）
  8×8 = 64 维
    ↓ 保留为 [0, 255] 整数
  作为输入（不要归一化到 float！）

原因：后面 bit-plane 分解需要整数
```

---
### Phase 2：ANN 训练（float 基线）

```
网络：y = softmax(W × x)
      W: [10, 64]（权重矩阵）
      x: [64]（输入，这里先用 float 的 x/255.0）
      bias：关闭（PyTorch: nn.Linear(64, 10, bias=False)）

训练后记录：
  - W（float 权重）
  - 基线准确率（float 精度下的天花板）
```

这一步就是标准 PyTorch 训练，不涉及任何 SNN 逻辑。
**注意**：这里显式关闭 bias，是为了与 Phase 3 的硬件等价推理保持一致，
否则 Phase 2 与 Phase 3 的 argmax 会因偏置项不同而失配。

---
### Phase 3：SNN 推理仿真 ⭐核心

这里要**精确模拟你硬件做的事情**。每一步都对应一个硬件模块：

```
输入像素 x[i] ∈ [0,255]
    ↓
bit-plane 分解（对应数字侧 TB 写 data_sram 的方式）
    b[i][k] = (x[i] >> k) & 1    (k = 7,6,...,0, MSB first)
    ↓
对每个 bit-plane k（共 8 步）：
    ↓
  CIM MAC（对应 cim_macro_blackbox）
    mac[j] = Σ_i  b[i][k] × W[j][i]     ← 这是实际的模拟计算
    ↓
  ⭐ ADC 量化（这是要枚举的点）
    mac_q[j] = quantize(mac[j], ADC_BITS)
    ↓
  LIF 累加（对应 lif_neurons）
    membrane[j] += mac_q[j] << k          ← 数字侧精确累加，不量化
    ↓
8 步跑完后：
    分类结果 = argmax(membrane[j])
```

---
### ⭐ 关于"单层精确等价"的事实

单层网络有一个很好的特性，值得注意：

```
ANN 的计算：
  output[j] = Σ_i x[i] × W[j][i]
            = Σ_i (Σ_k b[i][k] × 2^k) × W[j][i]
            = Σ_k 2^k × (Σ_i b[i][k] × W[j][i])
            = Σ_k 2^k × mac_k[j]

↕ 完全等价（float 精度下）

SNN 的计算：
  membrane[j] = Σ_k mac_k[j] << k
              = Σ_k mac_k[j] × 2^k
```

**结论：float 精度下 SNN 推理结果和 ANN 完全一样。**

所以 Phase 3 在不量化时应该复现 Phase 2 的准确率。如果不一样，说明代码写错了。**这是你的自动校验机制。**

---
### Phase 4：量化实验

```
枚举矩阵：

              ADC bit
              8    10   12   14
权重bit  4  [ ]  [ ]  [ ]  [ ]
         6  [ ]  [ ]  [ ]  [ ]
         8  [ ]  [ ]  [ ]  [ ]

每格填入：测试集准确率

权重量化方式：
  W_q[j][i] = round(W[j][i] × 2^(W_bit-1)) / 2^(W_bit-1)
  （先确认和模拟团队权重范围，再定具体量化方式）

ADC 量化方式：
  满偏值 = 64 × max(|W_q|)   ← 权重有正负，需考虑全量程
  step   = 满偏值 / (2^ADC_BITS - 1)
  mac_q  = round(mac / step) × step
  说明：
  - 若 CIM 支持双极性读出，量化范围可设为 [-满偏值, +满偏值]。
  - 若实际阵列为无符号，需要与模拟团队确认 offset/mapping 策略后再定量化范围。
```

**注意量化误差是累积的：** 每帧 8 个 bit-plane，每次 ADC 采样都引入误差，8 次累加到 membrane。如果跑 20 帧，就是 160 次累积。低 bit ADC 的影响会放大。

---
### Phase 5：结论输出

```
从热图中找：
  准确率开始明显下降的拐点 → 左边那一挡就是最低可用 ADC bit

例如如果曲线长这样（假设权重 6-bit）：
  ADC 8-bit:  85%
  ADC 10-bit: 91%  ← 接近基线
  ADC 12-bit: 92%  ← 基线附近
  ADC 14-bit: 92%  ← 和 12 没区别

结论：10-bit 就够，12-bit 留裕量

输出给模拟团队：
  - 需要的 ADC bit 范围
  - 对应的权重位数假设
  - 准确率曲线截图
```

---
## 工具栈

```
数据：torchvision.datasets.MNIST
训练：PyTorch（标准）
量化仿真：NumPy 就够（Phase 3-4 不需要梯度）
画图：matplotlib
```

---
## 执行顺序建议

```
先做：Phase 1 + Phase 2（标准训练，半天事情）
然后：Phase 3（不量化版本，验证和ANN等价）← 必须先过这关
最后：Phase 4（枚举实验）
```

Phase 3 不量化时和 Phase 2 准确率一致，这个校验过了你才能放心后面量化实验的结果是真实的。
## 六、若干问题的修改

## 1、CPU存在的意义是？不就是个控制器吗？ALU的作用是？

1) 软硬协同里，“软”到底是什么？
你这个 SoC 里，硬件负责跑数据链路，软件负责“配置、调度、收结果”。
具体到你项目，软件（E203 固件）干这些事：

软件做的事

初始化与配置
写寄存器：TIMESTEPS / THRESHOLD / RESET_MODE / DMA_LEN_WORDS / DMA_SRC_ADDR
喂数据
从 UART/SPI/外部Flash 读取输入帧
写入 data_sram
启动推理流程
启动 DMA → input_fifo → DAC → CIM → ADC → LIF
取结果 & 解释
读 OUT_FIFO_COUNT / OUT_FIFO_DATA
做简单分类（例如 argmax）
参数可调
同一硬件，换阈值/帧数/编码方式即可跑不同实验
硬件做的事

DMA 搬运
CIM 控制
ADC 时分复用
LIF 累加与 spike 输出
✅ 这就是“软硬协同”：硬件是“流水线”，软件是“调度器 + 配置器 + 结果解释器”。

2) CPU 在 V1 里“只是控制器”，那为什么还需要？
需要的理由很现实：

(1) 可编程性
FSM 固定死流程，任何改动都要改 RTL。
CPU 可以只改固件，你就能：

改阈值
改 timesteps
改输入格式
改推理流程
(2) 外部接口桥梁
你要接 UART/SPI/Flash，必须有一个软件层能解析数据并写寄存器。
没有 CPU，就得靠 FPGA 或外部 MCU 控制，工程复杂度更高。

(3) 为 V2/V3 打基础
后面创新点（动态校准 / DMA调度 / 指令扩展）都需要 CPU 配合
V1 集成 CPU = 给后续版本留接口

(4) 论文合理性
SoC 论文里必须有可编程控制路径，否则很难解释“系统级可复现”。

3) 创新点是什么？为什么需要 CPU 配合？
下面是你现有创新点与 CPU 的关系（对外解释最清楚的一版）：

✅ 逻辑 64×16 映射
创新点：地址映射简化，避免软件复杂判断
CPU作用：固件写权重/配置时直接用 shift 计算地址

✅ Shadow Buffer + 中断
创新点：ADC 结果集中缓存，减少轮询
CPU作用：CPU 只在中断时读数据，降低功耗

✅ 稀疏性统计
创新点：硬件统计输入稀疏度
CPU作用：CPU 根据统计值调阈值/调帧数

✅ 活动检测 + 计算跳过
创新点：无效输入不触发推理
CPU作用：CPU 设定策略开关、读状态判断

✅ 后续高阶（Program‑and‑Verify / 校准）
创新点：硬件 FSM 做写‑读‑验
CPU作用：下发目标权重/容差，接收 done/err

4) 加 E203 后面积是否还够？
结论：有机会够，但要保持“低配”配置。

你现在的配置已经压到了：

instr_sram：16KB
data_sram：16KB
input_fifo：256 深度
weight_sram：16KB（暂留）
在 55nm / 1×1 mm 内：

SRAM 仍是最大风险
E203 不带 cache/MULDIV 才有希望
建议

E203：无 cache / 无 MULDIV / 无 FPU
weight_sram：能删就删
input_fifo：256 已合理（覆盖一次性灌入 160 个 bit-plane）
最终是否“够”，仍需要 SRAM macro 面积或综合估算确认。

E203 在 V1 里确实像控制器，但它带来的不是算力，而是可编程性、外部接口、复现能力，以及 V2/V3 创新点的基础。如果不用 CPU，就得靠外部系统控制，工程复杂度更高。面积上只要 CPU 低配 + SRAM 缩小，就有机会塞进 1×1 mm，但必须以 SRAM macro 面积为准

MCU vs 当前 E203 的对比（工程视角）
✅ MCU 方案的优点
集成度高
MCU 通常自带 UART/SPI/Timer/中断等，省 RTL 开发
上手快
固件和启动链路成熟，软件生态完善
系统稳定
一般功能边界清晰，调试成本低
⚠️ MCU 方案的缺点
可定制性差
很难加你自己的 SNN 专用指令/硬件协同
授权与成本
商业 MCU IP 多数是授权制，不好拿到
面积/功耗不一定更省
MCU 往往包含你用不到的功能
你当前 E203 的优势
高度可裁剪
可关 cache / MULDIV / debug，压面积
可扩展
未来可加 NICE 指令、DMA 调度等
更适合“研究型 SoC”
论文里更好讲“可编程控制路径 + 硬件协同”
放在你项目里怎么选
V1 目标是流片可行 + 功能跑通
→ E203 低配 + 简化外设最稳
MCU 只有在“你不想自己写外设/总线”的情况下才更省事
但你现在已经在做 SoC，所以 MCU 反而会限制你


ALU 不是做矩阵计算的，但它是固件执行的基础：地址计算、寄存器配置、循环控制、DMA 启动、数据搬运都要用 ALU。没有 ALU 就不是 CPU 了，只能退化成固定 FSM，灵活性没了

CPU 不是算力主角，是控制面

E203 负责初始化、配置寄存器、DMA 调度、读取结果

这些都是 ALU 在做的：地址加减、循环计数、条件判断
硬件 FSM 固定，CPU 灵活

你今天改阈值/帧数/输入格式，只要改固件

没 ALU → 不能写固件 → 只能改 RTL/流片
“没用到”只是误解

ALU 不做 MAC，但它是 load/store + 控制流的核心
只要有固件，ALU 就一定在用

面积/功耗担心可以优化

关掉 MULDIV/FPU、去 cache、缩小寄存器、低频运行
让 CPU 成为“最小可编程控制器


“是的，它在 V1 里主要是控制器，但它是可编程控制器，不是固定 FSM。可编程意味着流程可改、参数可调、实验可复现，这是系统级 SoC 必须的。”

展开版（更稳）

控制器≠CPU

FSM 固定流程，改一次就要改 RTL
CPU 是可编程控制器，固件可随时更新
科研需要可重复性和可调性

你要改阈值、帧数、编码方式、DMA 策略
这些都靠软件改，不用动硬件
为 V2/V3 提前铺路

后续创新点（动态校准、程序化调度、NICE 指令）都要 CPU
系统级合理性

SoC 论文必须有可编程控制面
否则只是“硬核加速器”，不是完整 SoC
你可以用这句话结束：

“它确实承担控制器角色，但关键差别是可编程。V1 是控制器，V2/V3 才是系统扩展的核心入口。”


### 2、面积的修改

对 SRAM / FIFO 等进行了压缩。

### 3、DMA & FIFO 存在的意义？

✅ 关于“这算不算 DMA？”
算，但是“最小化单通道 DMA”，不是通用 DMA。

为什么仍叫 DMA：

Direct：CPU 只配置寄存器，不参与逐字节搬运
Memory：源端是 data_sram
Access：DMA 有独立读口，自动搬运到 input_fifo
准确表述：

“这是 data_sram → input_fifo 的单通道 DMA/搬运引擎，用于固定路径的数据搬运。”

✅ 数据流（V1 完整版）
Flash → SPI → CPU（E203）→ data_sram → DMA → input_fifo → DAC → CIM → ADC → LIF → output_fifo

具体细节
1) Flash → SPI
外部 Flash 通过 SPI 与 SoC 相连
CPU 通过 SPI 控制器发读指令（read / addr）
2) SPI → CPU
SPI 控制器把读出的数据放入 RX 寄存器/FIFO
CPU 轮询或中断读取（PIO）
3) CPU → data_sram
CPU 把 SPI 读出的数据写入 data_sram（存到正确地址）
4) data_sram → DMA → input_fifo
CPU 配好 DMA 源地址/长度
DMA 开始搬运 bit‑plane 数据到 input_fifo
后续链路自动运行
✅ 未来升级路径（更“正宗”的 DMA）
如果你后续扩展 DMA 支持 SPI → SRAM，那么会变成：

Flash → SPI → DMA → data_sram → DMA → input_fifo

这样 CPU 参与更少，更符合“DMA”的概念。

✅ 关于 FIFO 的意义  
FIFO 在 V1 完整版是必须的，不是可选项。原因是：

速率解耦  
DMA 搬运是突发；CIM/ADC 是时序驱动、间歇消费；FIFO 吸收速度不匹配。

稳定性  
没有 FIFO 就必须严格同步 DMA 与 CIM，验证复杂度大幅上升。

输出缓冲  
spike 是事件型输出，CPU 不能每拍读，必须用 FIFO 暂存。

准确表述：  
“FIFO 是速率解耦器 + 事件缓冲器，没有它会导致系统耦合过紧、吞吐下降、验证困难。”

合并的代价  
丢掉“速率解耦”。DMA 和 CIM/ADC 的速度不同，FIFO 是缓冲器。  
合并后变成“边读边算”，一旦 ADC/CIM 慢下来就卡住，验证更难（时序耦合更强）。

**原则补充**：若无必要，勿增实体；但若**删掉后破坏了速率解耦/可验证性**，就不该合并。

### 4、数据流想好流向，控制流严格分离
这个建议是高级工程师的思维，而且非常正确。

在你系统里体现为：
数据流：data_sram → DMA → input_fifo → CIM → output_fifo
控制流：CPU 只负责寄存器配置 / 启动 / 读取结果
如果你混在一起（比如控制信号和数据一起走同一通道），会造成：

状态机爆炸
验证复杂度飙升
很难扩展

---

## 七、已完成的更改 & 待做清单

### 已完成的更改
（已从"改动纪要"整理，便于对齐与回顾）

> 注：本节按时间顺序保留历史记录，包含旧参数（如 `T=1 / ratio=0.40 / 91.24%`）。
> 当前定版口径请以“关键决策点”“参数定版表”以及 `snn_soc_pkg.sv` 为准（`T=10 / ratio_code=4 / THRESHOLD_DEFAULT=10200`）。

1) **建模路线与论文准备落地**
   - 明确 Phase 1~5 建模流程与"Phase 2/3 等价校验"
   - Phase 2 训练关闭 bias（`bias=False`），保证与 Phase 3 等价
   - 量化满偏值改为 `64 × max(|W_q|)`，兼容正负权重
   - 补充降采样对比与 ADC 位数扫参的"论文准备事项"
   - 新增阈值建议脚本：`doc/threshold_recommend.py`

2) **参数口径统一与文档对齐**
   - 文档统一"以 pkg 为准"
   - `doc/00/01/02/04/06` 等文档更新到当前参数口径
   - 强化"数据流/控制流分离"原则

3) **面积压缩（SRAM/FIFO）**
   - instr/data/weight SRAM 统一为 16KB，集中管理参数
   - INPUT_FIFO_DEPTH 恢复为 256（避免 TB 灌满导致死锁）
   - 文档/表格同步更新

4) **接口与行为模型一致性修复**
   - CIM 行为模型参数名统一（避免 lint 变量遮蔽）
   - reg_bank 导入方式修正（lint clean）

5) **质量保障**
   - Verilator lint 通过
   - smoke test 清单与排查说明完善

6) **RTL 全面复查（最新一轮）**
   - 全部 17 个 RTL/TB 文件逐文件检查，无 bug / 无参数不一致
   - 地址空间无重叠、延迟计数器 N-1 模式正确、位宽一致、FSM 完备
   - 代码可以放心跑 Smoke Test

7) **Python 全量建模完成（2026-02-08）**
   - 运行 `run_all.py` 全量扫描，耗时 141.4 分钟
   - 扫描 900 组参数组合（9 methods × 4 ADC × 5 W × 5 T × 1 scheme）
   - Device backend: plugin mode（17 电导电平，memristor_plugin.py 加载成功）
   - 器件模型参数实测：R_off=4.18e+11 Ω, R_on=2.34e+08 Ω, 开关比(plugin)=1786:1
   - **最佳配置（val 选参 → test 报告）**：
     - 方法: proj_sup_64（监督式投影 784→64 维）
     - 方案: B（数字侧差分）
     - ADC: 8-bit, 权重: 4-bit, 帧数: T=1, 阈值比率: 0.40
     - Val 准确率: 90.78%, **Test 准确率: 91.24%**
   - ANN 基线：float=86.74%, QAT quantized=90.57%
   - 理想 SNN 等价校验通过（全部方法 SNN_ideal ≈ ANN float）
   - ADC 扫描: 6-bit(90.10%), **8-bit(90.78%)**, 10-bit(90.62%), 12-bit(90.68%)
   - 权重扫描: 2-bit(80.22%), 3-bit(78.02%), **4-bit(90.78%)**, 6-bit(86.76%), 8-bit(86.12%)
   - 帧数扫描: T=1~20 全部 90.78%（T=1 最低成本，等价精度）
   - 噪声影响: 理想 90.78%, 含噪 90.41%±0.31%, 退化仅 0.37%
   - 决策规则: spike=90.78%, membrane=90.78%（等价，spike 对齐 RTL）
   - 自适应阈值: 固定=90.78%, 自适应=88.98%, **下降 1.80%，不推荐**
   - Multi-seed 复跑: 5 seeds, clean=91.24%±0.00%, noisy=90.98%±0.12%
   - 复位模式对比（2026-02-10）: soft/hard 在 noisy test 上均为 90.98%±0.12%，当前推荐配置下等效；继续沿用 soft 口径
   - 生成 7 张对比图 (fig1~fig7)
   - config.py 更新：记录会议确认参数 + 建模推荐常量

8) **器件/模拟团队会议确认（2026-02-06）**
   - D1: 4-bit 权重精度确认，性能无问题
   - D2: 开关比确认 5000:1（plugin 百分位提取值 1786:1 更保守，不影响建模结论）
   - D3: D2D 5%±1%, C2C 3%±1%（实测估计值，建模已覆盖）
   - D4: 读电压确认 1.5V（不影响归一化建模，仅影响模拟侧 Vref）
   - D5: IR drop 可按阵列规模 scaling（模型已支持）
   - D6: 集成后无需初始化
   - A1: **确认方案 B（数字侧差分减法）** → ADC 通道数 = 20
   - A2: **确认 ADC 8-bit**
   - A3: 1 ADC × 20 MUX（推荐方案，模拟团队接受）
   - J1: **不做自适应阈值**（建模证明无益 -1.80%）
   - J2: **在 reg_bank 新增 8-bit THRESHOLD_RATIO 寄存器**，定版默认 4（ratio_code=4，4/255≈0.0157），UART 可覆写（原会议确认值 102 已由 2026-02-27 定版更新取代）

9) **RTL 参数更新完成（2026-02-06）**
   - 4a. `snn_soc_pkg.sv`: NUM_INPUTS=64, ADC_BITS=8, ADC_CHANNELS=20, TIMESTEPS=10, THRESHOLD_RATIO_DEFAULT=4, THRESHOLD_DEFAULT=10200, NEURON_DATA_WIDTH=9（2026-02-27 定版更新）
   - 4b. `adc_ctrl.sv`: 20通道 MUX + 数字差分减法（Scheme B），signed 9-bit 输出
   - 4c. `lif_neurons.sv`: signed 膜电位 + 符号扩展 + 算术左移 + signed 阈值比较
   - 4d. `reg_bank.sv`: 新增 REG_THRESHOLD_RATIO (0x24, 8-bit, 默认4)，双寄存器模式（2026-02-27 定版）
   - 4e. `cim_macro_blackbox.sv`: P_ADC_CHANNELS=20，Scheme B 行为模型（正列/负列公式）
   - 4f. `dma_engine.sv`: 64-bit 打包（2×32 整拼接，word1_reg 扩展为 32-bit）
   - 4g. `snn_soc_top.sv`: bl_sel 位宽→$clog2(ADC_CHANNELS)=5, neuron_in_data 位宽→NEURON_DATA_WIDTH
   - TB: `top_tb.sv` 适配新参数（64-bit patterns, T=10, signed diff 显示, THRESHOLD_RATIO 读回测试）
   - **全部文档同步更新**：00_overview, 01_memory_map, 02_reg_map, 03_cim_if_protocol, 04_walkthrough, 05_debug_guide, 08_cim_analog_interface

10) **V1 输入说明修订（2026-02-06）**
    - **V1 芯片输入是离线预处理后的 64 维特征向量**（proj_sup_64: 784→64），不是原始 28×28 像素
    - 预处理在 PC/MCU 端完成，芯片只负责 SNN 推理
    - 这意味着 V1 不需要片上降采样/投影硬件

11) **双寄存器阈值模式（2026-02-06）**
    - REG_THRESHOLD (0x00, 32-bit): 绝对阈值，直接用于 LIF 比较
    - REG_THRESHOLD_RATIO (0x24, 8-bit): 阈值比率（默认 4/255≈0.0157），供固件计算绝对阈值
    - THRESHOLD_DEFAULT = THRESHOLD_RATIO_DEFAULT × (2^PIXEL_BITS - 1) × TIMESTEPS_DEFAULT = 4 × 255 × 10 = 10200
    - 固件可: (a) 直接写 THRESHOLD 绝对值, 或 (b) 读 RATIO 计算后写 THRESHOLD

12) **ADC 饱和计数器（2026-02-06）**
    - `adc_ctrl.sv`: 新增 `adc_sat_high[15:0]` / `adc_sat_low[15:0]` 输出端口，每次推理自动清零
    - `reg_bank.sv`: 新增 `REG_ADC_SAT_COUNT`（0x28, RO），`[15:0]=sat_high`, `[31:16]=sat_low`
    - `snn_soc_top.sv`: 连线 adc→reg_bank
    - `top_tb.sv`: 推理完成后读回 ADC_SAT_COUNT 并显示
    - 用途：bring-up 时诊断模拟前端增益是否合适（饱和过多 → 调 Vref/增益）

13) **CIM Test Mode + Debug 计数器 + FIFO 断言（2026-02-08）**
    - **CIM Test Mode**：`snn_soc_top.sv` 新增测试模式 MUX + 响应生成器
      - `reg_bank.sv` 新增/增强 `REG_CIM_TEST`（0x2C），bit[0]=test_mode, bits[15:8]=test_data_pos, bits[23:16]=test_data_neg
      - `cim_test_mode=1` 时旁路 `cim_macro_blackbox` 的 3 个输出（cim_done/adc_done/bl_data）
      - 数字侧生成 fake 响应：cim_done 延迟 2 拍, adc_done 延迟 1 拍, bl_data 按 bl_sel 分路返回 pos/neg（`dac_ready` 已移除，DAC 走固定时序）
      - 用途：硅上验证数字逻辑完整性，不依赖真实 RRAM 宏
    - **Debug 计数器**（4 路 16-bit 饱和计数器，在 `snn_soc_top.sv` 内采样现有信号，无需改子模块端口）
      - `REG_DBG_CNT_0`（0x30）：[15:0]=dma_frame_cnt（DMA FIFO push 次数），[31:16]=cim_cycle_cnt（CIM busy 周期数）
      - `REG_DBG_CNT_1`（0x34）：[15:0]=spike_cnt（LIF spike 总数），[31:16]=wl_stall_cnt（WL mux 重入告警次数）
      - 仅 rst_n 清零，16-bit 饱和（到 0xFFFF 停止）
    - **FIFO Power-of-2 断言**：`fifo_sync.sv` 新增 `initial` 块，DEPTH 不为 2 的幂则 `$fatal`
    - `top_tb.sv`：推理完成后读回 DBG_CNT_0/1 和 CIM_TEST 并显示
    - `doc/02_reg_map.md`：新增 3 个寄存器条目 + 使用说明

---

### 待做清单（建议顺序）

> **核心原则**：建模已完成，参数已定版。接下来按优先级执行 RTL 改动 + 回归测试。
> （原则：代码先跑通 → 人先看懂 → 建模定参数 → 再改 RTL。前三步已完成。）

#### 0) 跑通 Smoke Test（立即，~1 小时）
- 在 VCS/Verdi 环境下运行 `sim/run_vcs.sh`
- 确认 vcs.log 无 Error、sim.log 出现 `[TB] Simulation finished.`
- 在 Verdi 中打开波形，确认 FSM 状态流转正常（ST_IDLE → ST_FETCH → ... → ST_DONE）
- 确认 `bitplane_shift` 从 7→0 正确递减
- 确认 `membrane` 累加正常、`out_fifo_count > 0`
- **通过标准**：仿真正常结束 + 波形可观察 + 无 $fatal / assertion 失败

#### 1) 学习并理解当前代码（立即开始，与建模可并行）

> 按 `doc/06_learning_path.md` Part A 的阶段顺序。**在改 RTL 之前必须完成至少阶段 A-C**。

**第一周（与 Python 建模并行）**：
- **阶段 A（Day 1-2）**：鸟瞰全局
  读 `doc/00~02` + `snn_soc_pkg.sv` + `snn_soc_top.sv`；手画模块框图
- **阶段 B（Day 3-4）**：总线和数据搬运
  读 `bus_simple_if` / `bus_interconnect` / `sram_*` / `dma_engine` / `fifo_sync`；手画 DMA 状态机
- **阶段 C（Day 5-7）**：SNN 核心流水线（最重要）
  读 `cim_array_ctrl` / `dac_ctrl` / `cim_macro_blackbox` / `adc_ctrl` / `lif_neurons`
  手画主控 FSM 状态图、理解 bit-plane shift-and-accumulate

**第二周（建模出初步结果后）**：
- **阶段 D（Day 8）**：寄存器和控制
  读 `reg_bank` / `fifo_regs`；理解 W1P/W1C/RO 机制
- **阶段 E（Day 9）**：Testbench
  读 `top_tb.sv` / `bus_master_tasks.sv`；理解 5 步测试流程
- **仿真实验（Day 10-12）**：参数修改实验
  改 THRESHOLD/TIMESTEPS/ADC 延迟，观察波形变化
- **模块级仿真（Day 13-18，推荐）**：
  按 FIFO → SRAM → DMA → reg_bank → LIF → ADC → CIM_CTRL 顺序做模块级 TB

**为什么现在就学**：
- 不理解代码就无法有效指导建模（建模必须精确匹配硬件行为）
- 后续改 RTL（输入维度、差分、行列选通）前必须看懂现有实现
- 阶段 A-C 的学习不会阻塞 Python 建模（可并行）

#### 2) ✅ Python 建模与参数决策（已完成 2026-02-08）

> 全量建模已完成。结果见上方"已完成的更改"第 7 项。
> 参数已定版（2026-02-27 更新）：proj_sup_64, Scheme B, ADC=8, W=4, T=10, ratio_code=4 (4/255≈0.0157), test=90.42%（纯 spike，zero-spike=0.00%）
> （原旧配置 T=1, ratio=0.40, test=91.24% 使用 hybrid metric，含 96% membrane fallback，不代表硬件对齐精度）

#### 3) ✅ 器件/模拟团队会议确认（已完成 2026-02-06）

> 会议结果见上方"已完成的更改"第 8 项。所有架构级问题已确认。
> - 差分方案: 方案 B（数字侧差分，20 通道）
> - ADC: 8-bit
> - 自适应阈值: 不做
> - THRESHOLD_RATIO: 8-bit 寄存器，定版默认 4（ratio_code=4，4/255≈0.0157）

#### 4) ✅ RTL 参数更新（已完成 2026-02-06）

> **参数已定版（2026-02-27 更新）**：NUM_INPUTS=64, ADC_BITS=8, ADC_CHANNELS=20, TIMESTEPS=10, ratio_code=4, Scheme B
> **注意**：修改顺序很重要，pkg 是上游，其余模块依赖 pkg 参数。

**4a. `snn_soc_pkg.sv`（最先改，所有参数的源头）**
- [x] `NUM_INPUTS` = 49 → **64**
- [x] `ADC_BITS` = 12 → **8**
- [x] 新增 `ADC_CHANNELS` = **20**（Scheme B: 10 pos + 10 neg）
- [x] `TIMESTEPS_DEFAULT` = 20 → **1** → **10**（2026-02-27 定版更新）
- [x] 新增/更新 `THRESHOLD_RATIO_DEFAULT` = ~~102（0x66, ratio=0.40）~~ → **4**（ratio_code=4, 4/255≈0.0157，定版）
- [x] 更新 `THRESHOLD_DEFAULT` 计算公式（适配 ADC=8, T=10, ratio_code=4）→ **10200**
- [x] 更新 `ADC_PEAK_EST` 和 `THRESHOLD_REPEAT_FRAMES` = 1
- [x] `LIF_MEM_WIDTH` 保持 32（重新验算：T=1 × 8bp × 255(8-bit ADC) × 128(shift7) = 261120，约需 18 bit，32-bit signed 足够）
- [x] 新增 `NEURON_DATA_WIDTH` = ADC_BITS + 1 = **9**（signed，用于 Scheme B 差分结果）

**4b. `adc_ctrl.sv`（Scheme B 核心改动）**
- [x] MUX 通道数：NUM_OUTPUTS(10) → ADC_CHANNELS(20)
- [x] `bl_sel` 位宽：$clog2(10)=4 → $clog2(20)=**5**
- [x] 扫描 20 路后做数字差分减法：`diff[i] = data_reg[i] - data_reg[i + NUM_OUTPUTS]`（i=0..9）
- [x] 输出 `neuron_in_data` 改为 **signed [NEURON_DATA_WIDTH-1:0]**（9-bit signed，范围 [-255, +255]）
- [x] BL 通道映射约定：channels 0~9 = 正差分列(pos)，channels 10~19 = 负差分列(neg)

**4c. `lif_neurons.sv`（signed 膜电位）**
- [x] `neuron_in_data` 输入改为 **signed** 类型（NEURON_DATA_WIDTH bits）
- [x] `membrane` 改为 **signed** [MEM_W-1:0]（2's complement）
- [x] `addend` 做 **符号扩展** 后左移（sign-extended shift）
- [x] 阈值比较：signed membrane >= positive threshold（需正确处理 signed/unsigned 比较）
- [x] 软复位：signed 减法 `membrane[i] -= threshold_ext`

**4d. `reg_bank.sv`（新增 THRESHOLD_RATIO 寄存器）**
- [x] 新增 `REG_THRESHOLD_RATIO` at offset **0x24**（8-bit, R/W）
- [x] 默认值 = `THRESHOLD_RATIO_DEFAULT`（4 = 0x04，定版）
- [x] 新增 output port `threshold_ratio [7:0]`
- [x] 读回逻辑 + 写入逻辑（仅 byte 0 有效）

**4e. `cim_macro_blackbox.sv`（适配新参数）**
- [x] NUM_INPUTS 49→64 自动跟随 pkg
- [x] 如有内部 ADC 行为模型，ADC_BITS 12→8 自动跟随
- [x] 输出通道：确认支持 20 路 BL 输出（ADC_CHANNELS）

**4f. `dma_engine.sv`（64-bit 打包简化）**
- [x] 49-bit splice → 64-bit（2×32 整打包，直接取低 64 位）
- [x] 实际上 64 = 2 × 32，DMA 只需搬 2 个 word 即可组成一个完整 bit-plane

**4g. `snn_soc_top.sv`（端口适配）**
- [x] 新增 `threshold_ratio` 信号连接 reg_bank → 外部（或仅内部）
- [x] 更新 `bl_sel` 位宽 4→5
- [x] 确认所有子模块端口与 pkg 参数一致

#### 5) 集成方案确认（与项 4 并行推进）

- 片外混合集成优先"同板双芯"，确定连接器/走线/时钟与复位方案
- **引脚预算**（更新后的估算）：
  - 推理模式：wl_spike×64 + dac_valid×1 + cim_start/done×2 + bl_sel×5 + adc_start/done×2 + bl_data×8 + clk + rst_n + mode ≈ **85 pin**
  - 编程模式（复用推理引脚）：row_addr + col_addr + write_data + 控制 → 可复用上述引脚
  - 加电源/地/参考/偏置 → 总计可能 **100-120 pin**
  - 需要评估封装/PCB 可行性（QFP-128 or BGA）
- 口径说明：**86 pin** 是“无复用裸接口”的连线规模估算；**45 pin** 是 V1 定版采用时分复用/引脚复用后的实现口径，两者不冲突。
- 若 pin 过多：评估 pin reduction（串行化 WL 驱动、分时复用）

#### 5a) chip_top / pad-wrapper 落地（后端前必做）

- 已新增骨架文件：`rtl/top/chip_top.sv`（当前仅占位，不改变现有 `snn_soc_top` 行为）
- 当前状态说明（避免误解）：`chip_top` 里复用相关 pad 信号仍是占位常量，**不是最终 pad 级连线实现**；Tapeout 前必须完成真实连接与 pad cell 实例化。
- 后端前必须完成以下收口：
  - 在 `chip_top.sv` 内把外部复用信号（`wl_data/wl_group_sel/wl_latch/cim_start/bl_sel`）连接到内部协议源
  - 统一 pad 口径：确定 45-pin 方案的最终引脚表、方向、电平和复位策略
  - 完成 pad ring 实例化与约束（时序/电气）
  - 与模拟团队二次对齐 `doc/08_cim_analog_interface.md`（去掉“待确认”项）
- 验收标准：
  - `chip_top` lint 通过、无悬空关键接口
  - pad 表、约束文件、接口文档三者一致
  - 联调仿真中复用信号时序与文档冻结协议一致
- 明确电平标准与 IO 约束（VDD/AVDD/参考电压）

#### 5b) FPGA 系统验证（后端前强烈建议，粗略版）

- 目的：在不依赖后端/模拟芯片的情况下，先验证“软硬件端到端流程”可跑通，提前暴露系统级集成问题（复位、时钟、总线映射、固件流程、长时稳定性）。
- 边界：FPGA 验证不替代 DC/STA/LEC/DRC/LVS，也不替代真实模拟非理想验证（噪声、IR drop、漂移、器件波动）。
- 建议执行时机：UART/SPI/AXI/E203 集成完成后、正式进入后端前。
- 最小通过门槛（Go/No-Go）：
  - 寄存器读写与中断/轮询路径可用；
  - `data_sram -> DMA -> input_fifo -> CIM(替代模型) -> ADC(替代模型) -> LIF -> output_fifo` 全链路可重复跑通；
  - 与 RTL smoke 的关键计数器/状态机行为一致（允许时序拉长，但状态顺序一致）；
  - 连续回归（建议 >=1k 次短任务或 >=1h）无卡死、无不可恢复错误。
- 工程约束：FPGA 适配层与 ASIC 主线 RTL 解耦（board top、时钟/复位、IP wrapper、约束文件放独立目录），避免“为上板临时改动”回灌污染 tapeout 分支。
- 详细流程、脚本组织、风险清单与验收模板见：`doc/12_fpga_validation_guide.md`。

#### 6) ✅ 建模与参数定版（已完成 2026-02-08）

参数定版表：

| 参数 | 定版值 | 来源 |
|------|--------|------|
| 输入维度 | 64 (proj_sup_64) | 建模最佳 |
| ADC 位宽 | 8-bit | 建模 + A2 确认 |
| 权重位宽 | 4-bit | 建模 + D1 确认 |
| 差分方案 | B（数字侧） | A1 确认 |
| ADC 通道数 | 20 (10 pos + 10 neg) | Scheme B |
| 推理帧数 | T=10 | 建模定版（spike-only 90.42%，zero-spike=0.00%） |
| 阈值比率 | ratio_code=4（寄存器值 4，4/255≈0.0157） | 建模定版（纯 spike 标定） |
| 阈值自适应 | 不做 | 建模证明下降 1.80%, J1 确认 |
| 复位模式 | soft (V=V-Vth) | 建模对比（soft/hard 在当前推荐配置下等效）+ 与现有 RTL 路径一致 |
| 决策规则 | spike count | 与 RTL 对齐 |
| LIF_MEM_WIDTH | 32 | 验算足够 |

复位模式定版补充（2026-02-10）：

- 对比对象：`SPIKE_RESET_MODE=soft` vs `SPIKE_RESET_MODE=hard`，其余参数固定为推荐配置（`proj_sup_64, Scheme B, ADC=8, W=4, T=10, ratio_code=4`）。
- 对比入口：`run_all.py` 中 `[3f]`（噪声影响，`add_noise=True`）与 `[3l]`（test 多 seed noisy，`add_noise=True`）。
- soft（历史基线）：
  - val noisy mean：`90.41% +/- 0.0031`
  - test noisy（multi-seed）：`90.98% +/- 0.0012`
  - 证据：`Python建模/results/summary.txt`
- hard（2026-02-10 复跑）：
  - val noisy mean：`90.51% +/- 0.0034`
  - test noisy（multi-seed）：`90.98% +/- 0.0012`
  - 证据：`Python建模/results/summary.txt`、`run_all_skiptrain_hard_20260210_161450.log`
- 结论：
  - 当前推荐配置下，soft/hard 在 noisy test 指标上不可区分（数值完全一致）。
  - val 侧 `0.10%` 差异小于统计波动量级（`~0.31%-0.34%`），不具显著性。
  - V1 参数继续沿用 `soft`，理由是：与既有 RTL/文档口径一致、行为连续性更好、无需引入额外改动风险。

#### 7) 测试方案（参数定版后制定）

- 数字单测（V1）：UART/寄存器自检、SRAM memtest、DMA/FIFO/控制链路
- 模拟单测：IV/电导级分布、写入一致性、读噪声、漂移/耐写
- 片外混合集成：端到端推理、ADC code 稳定性、参数敏感度
- 形成 checklist（通过/失败判据明确）
- **[ ] Python 主机推理脚本**（UART 控制器完成后执行，约 50 行，依赖改进 1 UART 完成）
  - 工具：pyserial（`pip install pyserial`）
  - 功能：PC 端通过 USB-UART 写寄存器（THRESHOLD/TIMESTEPS）→ 触发 DMA → 触发 CIM → 轮询/等中断 → 读 OUT_FIFO_DATA → 打印预测类别
  - 价值：形成完整软硬件联调闭环，可直接用于芯片 bring-up 演示和论文 demo 视频
  - 文件建议：`sw/host/infer.py`

#### 8) 文档与接口同步更新（持续）

- 更新 `doc/08_cim_analog_interface.md`（新增行列选通、差分通道、编程接口、引脚复用）
- 更新 `doc/00_overview.md` / `doc/04_walkthrough.md` / `doc/06_learning_path.md`
  - 06 学习文档中的参数表需更新（NUM_INPUTS=64、可能的通道数变化）
- 更新本文档（口径/流程/参数/接口一致）
- 同步寄存器表/地址映射到最新设计
- **Phase 1~5 建模流程同步**：已更新为 32×32→8×8=64（2026-02-27）；历史 7×7=49 仅保留在变更记录中

#### 9) 辅助保障机制（可选但建议）

- ✅ CIM Test Mode — **已增强（2026-02-27）**：REG_CIM_TEST 新增 test_data_neg [23:16] 字段，支持正/负通道独立配置，令 pos≠neg 即可使 Scheme B 差分非零，实现含 LIF+输出FIFO 的完整数字链路自检（见下方"流片后硅上自检流程"）
- 行列选通固定窗口版（先跑通，再做可配置）— P0/P1 后再决定
- ✅ Debug counter/trace（DMA/ADC/LIF 关键计数器）— 已实现（2026-02-08）
- ✅ 阵列规模参数化（支持快速切换 64×10 / 64×20 / 128×128 等配置）— 已具备（pkg 参数化）

---

#### 🔬 流片后硅上自检流程（数字芯片独立验证，无需模拟 CIM 芯片）

> 适用场景：芯片回片后，模拟 RRAM 芯片尚未就绪（或模拟芯片疑似失效），需单独验证数字芯片功能是否正常。

**核心思路**：写 `test_mode=1` + `pos≠neg` → 数字侧产生 fake 差分响应 → LIF 积累 → spike 输出 → 如果 OUT_FIFO_COUNT > 0，则数字链路完全正常。

**自检步骤**（通过 UART 或 JTAG 执行）：

| 步骤 | 操作 | 预期结果 | 验证内容 |
|------|------|---------|---------|
| 1 | 读写任意寄存器（如 REG_THRESHOLD 写 0x2800、再读回） | 读回 = 写入值 | bus_interconnect + reg_bank 正常 |
| 2 | 写 data_sram 数据，再读回 | 读回一致 | SRAM 读写正常 |
| 3 | 配置 DMA 搬运 160 words，启动，轮询 DMA_CTRL[1]=1 | 约 200 拍后 DONE | DMA FSM + input FIFO 正常 |
| 4 | 写 `REG_CIM_TEST = 32'h0000_6401`（wstrb=4'b0111，neg=0, pos=100, mode=1）| 读回一致 | test_mode 寄存器可写 + 差分链路可激活 |
| 5 | 写 `REG_TIMESTEPS=10, REG_THRESHOLD=10200`，启动 CIM | 约 10000 拍后 DONE | CIM FSM 全状态流转正常 |
| 6 | 读 `REG_OUT_COUNT` | **非零（预期 >10）** | LIF 膜电位积累 + 输出 FIFO 正常 |
| 7 | 关闭 test_mode，接入模拟芯片，重跑推理 | OUT_FIFO_COUNT 非零 + 结果合理 | 模拟芯片可用 |

**步骤 6 失败但步骤 3 通过 → 数字芯片 LIF/输出FIFO 有问题**
**步骤 3 失败 → 数字芯片 DMA/总线 有问题**
**步骤 1-6 全通过但步骤 7 失败 → 模拟芯片问题，数字芯片完好**

**数值验证（步骤 6 预期值计算）**：
- 差分 = pos - neg = 100 - 0 = 100
- 每帧（PIXEL_BITS=8 bit-plane）累积 = 100 × (128+64+32+16+8+4+2+1) = 100 × 255 = 25,500
- T=10 帧后膜电位 ≈ 255,000（远超 THRESHOLD=10,200）
- 每次 spike 后软复位：255,000 ÷ 10,200 ≈ 25 次 spike/neuron × 10 neurons = ~250 个 spike
- OUT_FIFO_COUNT 可能填满 FIFO（256 深度），但任何 >0 值均可认为通过

**快速写法**（TB 或固件均可用）：
```systemverilog
// 同时写 test_mode=1, test_data_pos=100(0x64), test_data_neg=0
// wstrb=4'b0111 → 写 byte0/1/2，skip byte3
bus_write(REG_CIM_TEST, 32'h0000_6401);  // neg=0x00, pos=0x64, mode=1
```
- ### 五、已知的非阻断性技术债（记录备忘，不影响当前阶段）

1. DMA 无 abort — 阶段 4 扩展 DMA 时一并解决
2. ~~FIFO depth 无 power-of-2 断言~~ — ✅ 已加（2026-02-08，fifo_sync.sv initial 块）
3. bus_master_tasks 不符合 AXI 协议 — 阶段 3 换 AXI-Lite 时必须重写
4. `$warning`/`$fatal` 未加综合保护 — 不影响仿真，综合时工具会忽略

#### 5) SPI 片外 Flash “读很久”风险（新增，2026-03-01）

> 结论先行：**读得慢通常不会直接导致功能错误，但会导致启动变慢、吞吐下降，若软件无限轮询会表现为“系统卡死”。**

- **风险来源**
  - 片外链路天然慢于片内总线：Flash 器件访问时间 + IO pad + PCB 走线 + SPI 时钟分频
  - 早期 bring-up 若频率拉太高，可能出现边沿裕量不足，导致偶发读错或重试
  - 若固件用 `while(busy)` 无限等待且无超时，异常场景下会卡死

- **工程对策（必须落地）**
  1. **轮询加超时 + 错误码**（固件侧）
     - 所有 `busy/rx_valid/done` 轮询必须有最大循环次数
     - 超时后写错误码并退出，不允许无限等待
  2. **先低速跑通，再逐步提频**（硬件+固件协同）
     - bring-up 默认低速分频（如 SPI 6.25MHz / 12.5MHz）
     - 每次提频都要重跑读 ID、连续读、端到端 smoke
  3. **大数据走批量搬运，不走 CPU 按字节搬**（架构演进）
     - V1 可先接受 “SPI -> CPU -> data_sram -> DMA” 中转路径
     - V2 目标升级为 “SPI -> DMA -> SRAM” 直搬，降低 CPU 参与和等待时间

- **验收标准（建议加入回归）**
  - 低速配置下，连续 100 次读 ID/读块 0 错误
  - 任一轮询路径触发超时时，系统可恢复且有可观测错误码
  - 同一测试在低速通过后再做提频 sweep，记录最大稳定频率

#### 10) 风险提示与前置验证（贯穿全程）

- **🔴 0T1R 128×128 sneak path（最高风险）**
  0T1R 无选通管，阵列规模越大 sneak path 越严重（电流泄漏导致读出不准/写入扰动）。
  **若器件组无 128×128 规模的实测数据，强烈建议 fallback 到 64×64 或更小规模先跑通。**
  数字侧设计应参数化，支持快速切换阵列规模。
- **🔴 写/擦/验证复杂度容易低估**
  P&V + Erase 相当于在推理链路之外再造一整套控制子系统（DAC 控制写脉冲参数、ADC 读出验证、重试逻辑、失败处理）。
  **V1 只做推理，写/擦/验证放 V2**（详见下方"器件团队需求评估"）。
- **🟡 差分结构导致通道数×2**：时序/功耗评估必须先量化（取决于方案 A/B 确认）
- **🟡 输入 64 维带来的连锁修改**：pkg / DMA / FIFO / CIM_MACRO / LIF / TB / 全部文档
- **🟡 片外互联 pin 数**：90+ 功能 pin + 电源地 → 需要早评估封装可行性
- **🟢 行列选通建议先固定窗口**：避免一次性复杂化拖期
- **🟢 建模必须保留 baseline 与对比**：论文可解释性

---
### 器件团队需求评估（V1 接受 / V1 拒绝-延后到 V2）

> 器件组提出的需求不是全部都要在 V1 做。下面按"V1 是否接受"分类，附理由。

#### V1 接受（现在可以听他们的改）

| 需求 | 理由 | 改动量 |
|------|------|--------|
| **差分结构（正负权重）** | 标准方案，数字侧改动可控（ADC 通道数 or 数字相减）；不做正负就没法跑 MNIST | 中 |
| **输入 8×8=64（从 49 改）** | 合理调整，避免 49 这个尴尬数；DMA 打包反而更简单（64=2×32 整打包）；与阵列行列选通对齐 | 中（连锁改动多但不难） |
| **行列选通（固定窗口版）** | 128×256 阵列中只用 64×20 子区域，需要选通；先做固定窗口，寄存器可配放 V2 | 低 |
| **读操作支持** | 推理链路本身就是"读"（CIM MAC 输出通过 ADC 读出），已有 | 无（已支持） |
#### V1 拒绝 → 延后到 V2（向器件组说明理由）

| 需求                            | 拒绝理由                                                              | 建议                                  |
| ----------------------------- | ----------------------------------------------------------------- | ----------------------------------- |
| **写 / 写验证 / 擦除（P&V + Erase）** | 复杂度等同于再造一套控制子系统；V1 目标是推理链路跑通+流片，不是编程链路。而且写入依赖真实器件（行为模型无法验证写入正确性）。 | V1 权重用行为模型/预烧录；V2 在真实器件到手后做 P&V FSM |
| **写脉冲参数可配置**                  | 属于 P&V 子系统的一部分，同上延后                                               | V2 统一做                              |
| **0T1R 128×128 全阵列访问**        | sneak path 风险极高，没有实测数据就做全阵列数字控制是赌博                                | V1 数字侧支持可配阵列规模（参数化），物理上先在小阵列验证      |
| **阈值自适应硬件**                   | 必须先用 Python 建模验证收益；如果收益不够则不值得增加硬件复杂度                              | 先建模验证，有数据再定                         |
#### 建议的沟通话术（对器件组）

> "V1（6/30 流片）的核心目标是**推理链路跑通 + 数字 SoC 稳定流片**。差分读出、行列选通、8×8 输入维度我们这一版就会做。
> 写入/擦除/验证涉及完整的编程控制子系统，工程量相当于再做半个 SoC，而且行为模型无法验证写入正确性——**必须等真实器件到手后在 V2 做**。
> 数字侧设计已经参数化，后续支持不同阵列规模和通道数只需改参数，不会返工。"

### 备注
- 后续所有"核心 RTL 更改"应基于**建模定版参数 + 器件确认数据**再实施（否则容易返工）。
- 接口文档（`doc/08_cim_analog_interface.md`）需要随器件数据与功能变更同步更新。
- 学代码和建模可以并行：上午看代码 + 手画图，下午写 Python。
- 器件组的 Python 模型是重大利好——之前担心 SPICE 不能直接用于系统建模，现在有 Python 模型可以直接集成到端到端仿真中。

---
### IO Pad 方案（已确认：48 pad，3 ESD，45 可用）

#### 器件模型关键参数（来自 memristor_plugin.py）

| 参数 | 值 | 对数字设计的影响 |
|------|-----|-----------------|
| 阵列规模 | 128×256 | 确认差分结构 (128 row × 256 col) |
| 权重精度 | 4-bit (16电平，对数分布) | 不影响数字侧（权重在模拟域） |
| D2D 变化性 | 5% | Python建模需考虑 |
| C2C 变化性 | 3% | Python建模需考虑 |
| HRS 电阻 (读1.5V) | ~1 TΩ (电流~1.5 pA) | 读出电流极低，需灵敏TIA+ADC（D4确认1.5V） |
| LRS 电阻 (读1.5V) | ~200 MΩ (电流~7.5 nA) | 64输入全1时列电流~480 nA（D4确认1.5V） |
| 开关比 | ~5000:1 | 很好，分类精度有保障 |
| **模型内部ADC** | **8-bit** | 重大发现：器件团队目标就是8-bit，不是12-bit |
| IR drop | 0.5 Ω/cell | 由于电阻极高/电流极低，IR drop影响小 |

#### 推荐方案：8-bit ADC + 保留 JTAG + WL 时分复用（方案B 数字侧差分，会议确认）

| 类别 | 信号 | 方向 | Pin数 |
|------|------|------|-------|
| 时钟/复位 | clk, rst_n | in | **2** |
| UART | uart_tx, uart_rx | out/in | **2** |
| SPI | spi_sclk, spi_mosi, spi_miso, spi_cs_n | out/in | **4** |
| JTAG | jtag_tck, jtag_tms, jtag_tdi, jtag_tdo | in/out | **4** |
| 电源 | VDDCORE×2, VSSCORE×2, VDDIO, VSSIO | pwr | **6** |
| WL 时分复用 | wl_data[7:0] | out | 8 |
|  | wl_group_sel[2:0] | out | 3 |
|  | wl_latch | out | 1 |
| CIM 控制 | cim_start | out | 1 |
|  | cim_done | in | 1 |
| BL 读出 | bl_data[7:0] | in | 8 |
|  | bl_sel[4:0] | out | 5 |
| **合计** | | | **45** |
| **剩余** | 无（Scheme B 用完全部 45 pin） | | **0** |

> **为什么能放下**：关键节省——
> 1. **ADC 8-bit 而非 12-bit**（A2 确认），节省 4 pin
> 2. **方案B 数字侧差分**（A1 确认），bl_sel 需 5-bit（$clog2(20)=5）
>
> 8-bit ADC 节省 4 pin，方案B 比方案A 多用 1 pin（bl_sel 4→5），净节省 3 pin。
> 加回 JTAG(4 pin) 正好用完 45 pin（无 spare）。

> **备选方案**（如果后续建模证明需要 12-bit ADC）：砍掉 JTAG → 正好 45 pin（无余量）。
> 但从器件模型的 4-bit 权重 + 5000:1 开关比来看，8-bit ADC 的动态范围完全足够。

#### 简化握手协议（省掉 dac_valid/adc_start/adc_done，共省 3 pin）

```
数字侧：                                模拟侧：
  1. 逐组加载 WL（8拍）
     wl_data = spike[g*8+:8]
     wl_group_sel = g (0~7)
     wl_latch 脉冲 ──────────────→  锁存到对应组的 WL 驱动器
  2. 拉高 cim_start ──────────────→  开始 CIM MAC 计算 + ADC 转换
  3. 等待 cim_done=1 ←────────────  全部列计算+ADC完成
  4. 逐步设置 bl_sel = 0,1,...19（Scheme B: 0~9=pos, 10~19=neg）
     每步等固定 settle 周期
     采样 bl_data[7:0] ←──────────  MUX 选通对应 BL 的 ADC 结果
  5. 全部读完，释放 cim_start
```

#### WL 时分复用 FSM 改造要点

`cim_array_ctrl.sv` 中原 `S_DRIVE_WL` 状态拆分为 8 拍：
```
S_DRIVE_WL → S_WL_MUX (内部计数 g=0..7)
每拍: wl_data_out = wl_bitmap[g*8 +: 8]
      wl_group_sel_out = g
      wl_latch_out = 1
```

#### 对器件模型的额外观察

1. **电流极低(pA~nA)** → sneak path 问题可能比预期轻（好消息），但 ADC 灵敏度要求高（模拟侧需 TIA）
2. **IR drop 影响小** → 模型虽然建模了 IR drop，但由于电阻极高，实际影响可忽略
3. **漂移系数 0.005** → 长时间推理可能有精度退化，Python 建模时需评估
4. **模型可直接 import** → `from memristor_plugin import MemristorArraySimulator` 即可做端到端仿真

---

### 更新后的执行计划（融合 IO pad 方案 + 器件数据）

> 以下为确认 IO pad = 45 可用、获得器件 Python 模型后的更新版。已完成的打 ✅。

#### ✅ 已完成
1. ✅ RTL 全面 code review（17 个文件，全部正确）
2. ✅ 确认 foundry pad 数（48 pad，45 可用）
3. ✅ 确定 IO 方案：WL 8组×8 时分复用 + 8-bit ADC + 方案B 差分 + 保留 JTAG = 45 pin（会议后更新）
4. ✅ 获取器件 Python 模型（memristor_plugin.py + I-V.xlsx）
5. ✅ 分析器件参数：4-bit 权重、5000:1 开关比、8-bit ADC、pA~nA 级电流
6. ✅ Python 全量建模完成（初版 T=1, ratio=0.40, test=91.24%）→ **定版更新（2026-02-27）**: T=10, ratio_code=4, spike-only test=90.42%, zero-spike=0.00%
7. ✅ 器件/模拟团队会议确认：Scheme B, 8-bit ADC, 无自适应阈值, THRESHOLD_RATIO 寄存器
8. ✅ RTL 参数更新 + TB 适配 + 文档同步（2026-02-06）
9. ✅ CIM Test Mode + Debug 计数器 + FIFO 断言（2026-02-08）

#### 接下来要做的（按顺序）

| 序号 | 任务 | 前置依赖 | 说明 |
|------|------|----------|------|
| **0** | **Smoke Test** — 跑通当前 RTL 仿真（VCS），确认无编译/运行错误 | 无 | 半天 |
| **1** | **学代码** — 按 `doc/06_learning_path.md` Part A 顺序 (Stage A→E) 阅读并理解所有 RTL | 无（与0并行） | 1-2周 |
| **2** | **Python 建模** — 集成 `memristor_plugin.py` 做端到端 SNN 推理精度评估 | 理解代码后更好 | 1周 |
|  | 2a. 8×8 输入 (64维) + 差分权重 + 8-bit ADC 精度验证 | | |
|  | 2b. LIF 阈值推荐值重新计算 | | |
|  | 2c. 阈值自适应收益评估（zys 创新点） | | |
|  | 2d. sneak path 影响评估（用模型的 variation + noise 参数） | | |
| **3** | **器件会议 follow-up** — ✅ 确认方案B（数字侧差分）；确认 8-bit ADC 方案 | 建模初步结论 | 1次会议 |
|  | 3a. ✅ 向器件组确认：ADC 通道数=20（方案B）| 已确认 | |
|  | 3b. 向器件组确认：pin 方案（44 pin + 1 spare 的分配表） | | |
|  | 3c. 向器件组确认：WL 时分复用的时序是否可接受 | | |
| **4** | ✅ **RTL 参数更新**（已完成 2026-02-06） | 2 + 3 | ✅ |
|  | ✅ 4a. `snn_soc_pkg.sv`: NUM_INPUTS=64, ADC_BITS=8, ADC_CHANNELS=20, NEURON_DATA_WIDTH=9 | | ✅ |
|  | ✅ 4b. `dma_engine.sv`: 64-bit 整打包（2×32） | | ✅ |
|  | ✅ 4c. `cim_macro_blackbox.sv`: 20通道 Scheme B 行为模型 | | ✅ |
|  | ✅ 4d. `wl_mux_wrapper.sv` + `snn_soc_top.sv`: WL 时分复用协议原型（10 cycles）已落地；`chip_top` pad 级连接待后端前收口 | | ✅ |
|  | ✅ 4e. `adc_ctrl.sv`: 20通道 MUX + 数字差分减法 | | ✅ |
|  | ✅ 4f. `lif_neurons.sv`: signed 膜电位 + Scheme B 有符号累加 | | ✅ |
|  | ✅ 4g. `snn_soc_top.sv`: 端口位宽适配（bl_sel=5, neuron_data=9） | | ✅ |
| **5** | ✅ **TB 更新** — 已适配新参数 | 4 | ✅ |
| **6** | **回归测试** — 全流程 smoke test + 功能验证 | 5 | 1天 |
| **7** | ✅ **文档同步** — 已更新 doc/00~05, 08 | 6 | ✅ |
| **8** | **集成对接会** — 与器件/模拟组对齐接口文档 | 7 | 1次会议 |

#### 关键决策点（全部已定版 2026-02-08）

| 决策 | 定版结果 | 依据 |
|------|----------|------|
| ADC 位宽 | **8-bit** | 建模最优 (90.78%) + A2 确认 |
| 差分方案 | **B（数字侧减，20通道）** | A1 确认 |
| 阈值自适应 | **不做** | 建模下降 1.80% + J1 确认 |
| 阈值比率 | **ratio_code=4（寄存器值 4，4/255≈0.0157）** | 建模定版（纯spike标定）+ J2 确认 |
| 阵列规模 | **64×20 固定窗口**（V1） | 建模确认 + V2 可配 |
| 帧数 | **T=10** | 建模定版（spike-only 90.42%，zero-spike=0.00%） |

*(旧的 IO pad 行动项已合并到上方“更新后的执行计划”中)*

## 你需要问模拟团队的信息

按优先级排序：

### P0 — 现在就需要确认（本周内）

1. **ADC 接口时序**
    
    - `adc_start` → `adc_done` 的延迟是多少个时钟周期？（我们 RTL 假设 1 cycle，如果模拟 ADC 需要更多周期，需要调整状态机等待）
    - ADC 的采样保持时间要求？（`bl_data` 需要在 `adc_start` 之后稳定多久？）
2. **CIM array 建立时间**
    
    - WL 施加后到 BL 电流稳定需要多少 ns？（这决定 `cim_done` 的延迟）
    - 当前 blackbox 假设 CIM 计算是组合逻辑（同拍完成），实际模拟需要几个周期？
3. **确认引脚定义**
    
    - 确认 `bl_sel[4:0]` 选通 20 个 BL 通道的映射关系（哪个 sel 对应哪个物理列）
    - 确认 WL 时分复用方案（8 groups × 8 = 64 WL，`group_sel[2:0]` + `data[7:0]` + `latch`）
    - 确认差分列的物理排布（pos column 0-9 和 neg column 10-19 的对应关系）

### P1 — 两周内需要（RTL smoke test 通过后）

4. **模拟模型交付形式**
    
    - 他们能提供什么级别的模型？Verilog behavioral? Verilog-A? SPICE?
    - 预计什么时候能提供？（这决定联合仿真的时间点）
5. **电源/偏置需求**
    
    - CIM array 的读电压（我们建模用 1.5V）是否由片上 LDO 提供还是外部 pad？
    - ADC 的参考电压从哪来？

### P2 — Tapeout 前需要（4 周内）

6. **版图约束**
    - CIM array 的物理尺寸和位置约束
    - 模拟-数字界面的 placement 要求

## 模拟团队现在能开工吗？

**可以初步开工。** 目前数字侧已经锁定的接口信息足够模拟团队开始：

- **CIM array 设计**：128×256 RRAM 阵列，0T1R 结构，差分列配置 — 这些是器件层面的，跟数字接口无关，可以直接开始
- **ADC 设计**：8-bit SAR ADC，20 通道时分复用共享 1 个 ADC — 可以开始 ADC 单元设计
- **WL 驱动电路**：8 组 × 8 的时分复用结构 — 可以开始驱动器设计

**但是**，在上面 P0 的 3 个问题确认之前，他们不应该锁定接口时序。建议你把 `doc/03_cim_if_protocol.md` 和 `doc/08_cim_analog_interface.md` 发给模拟团队，让他们基于这两份文档做初步设计，同时把 P0 问题的答案反馈给你，你这边相应调整 RTL 时序（主要是 `cim_macro_blackbox` 的行为模型和 `adc_ctrl` 的状态机等待周期）。
## 计划评价

| 阶段                                        | 评价                                                                     | 建议                                                                                            |
| ----------------------------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| **1.给文档，要数据， Smoke test + 学代码，然后根据数据改代码** | **完全正确。** 06 文档就是为此写的，按它走即可。等 P0/P1 信息是合理的并行策略。                        | 建议先跑 VCS 编译（不跑仿真），看有没有 syntax/port mismatch 错误，这是最快的 sanity check                             |
| **2. 加 UART/SPI/E203/DMA/AXI-Lite**       | **核心工作量在这里。** 目前 UART/SPI/JTAG 都是 stub，DMA 是简化版直连总线。升级为真实 IP 是 V1 必须的。 | 建议顺序：**E203 CPU → AXI-Lite bus → DMA → UART → SPI**。CPU 和总线是骨架，先搭好才能挂外设。每加一个模块写一个 unit TB 验证。 |
| **3. 创新点**                                | 合理的"锦上添花"定位                                                            | 看时间和精力，不要影响 tapeout deadline                                                                  |
| **4. FPGA 验证**                            | **强烈建议保留此步。** 这是 tapeout 前最后的全系统验证机会                                   | 需要提前选好 FPGA 板子（Xilinx/Intel），CIM macro 在 FPGA 上用 behavioral model 替代                          |
| **5. Backend**                            | 标准流程                                                                   | 通常需要 foundry PDK + 后端工具（Innovus/ICC2），确认学校/实验室有 license                                       |

**总体判断：计划可行，顺序合理。** 唯一的风险点是阶段 2 的工作量可能比预期大（E203 集成不简单），建议在阶段 1 就开始看 E203 的接口文档。

## 当前 SNN SoC 数据流

```
┌─────────────────────────────────────────────────────────────────────┐
│                        TB / CPU (未来 E203)                         │
│  ① 写 data_sram（bit-plane 格式）                                   │
│  ② 配置寄存器（threshold, timesteps, etc.）                         │
│  ③ 启动 DMA → 启动 CIM 推理 → 读取 spike 结果                      │
└──┬──────────────┬──────────────────────────────────────┬────────────┘
   │ bus_write     │ bus_write                           │ bus_read
   ▼              ▼                                     ▲
┌──────────┐  ┌──────────┐                         ┌──────────┐
│data_sram │  │ reg_bank │ ◄── adc_sat_high/low ── │ adc_ctrl │
│ (8KB)    │  │ (0x4000) │                         └──────────┘
└──┬───────┘  └──┬───────┘                              ▲
   │ dma_rd      │ threshold, timesteps,                │
   ▼             │ start_pulse, reset_mode              │
┌──────────┐     │                                      │
│dma_engine│     │                                      │
│ RD0→RD1  │     │                                      │
│ →PUSH    │     │                                      │
└──┬───────┘     │                                      │
   │{word1,word0}│                                      │
   │= 64-bit     │                                      │
   ▼             │                                      │
┌──────────┐     │                                      │
│input_fifo│     │                                      │
│ (64-bit  │     │                                      │
│  ×256)   │     │                                      │
└──┬───────┘     │                                      │
   │in_fifo_rdata│                                      │
   ▼             ▼                                      │
┌─────────────────────────────────────────┐             │
│         cim_array_ctrl (核心 FSM)        │             │
│                                         │             │
│  IDLE ──start──► FETCH ──► DAC ──► CIM ──► ADC ──► INC│
│   ▲                                                │  │
│   └── DONE ◄── (all planes & frames done) ◄────────┘  │
│                                                       │
│  控制信号输出:                                          │
│  • wl_bitmap + wl_valid_pulse → dac_ctrl              │
│  • cim_start_pulse → cim_macro                        │
│  • adc_kick_pulse → adc_ctrl ─────────────────────────┘
│  • bitplane_shift → lif_neurons (加权移位量)            │
│  • busy / done_pulse → reg_bank                       │
└─────────────────────────────────────────┘
   │              │              │
   ▼              ▼              ▼
┌────────┐  ┌───────────┐  ┌──────────┐
│dac_ctrl│  │cim_macro  │  │ adc_ctrl │
│        │  │(blackbox) │  │          │
│ latch  │  │           │  │ 扫描20ch │
│wl_bitmap│  │ wl_spike │  │bl_sel:   │
│        │  │  × weights│  │ 0→19     │
│dac_valid│─►│锁存触发点 │  │          │
│        │  │           │  │adc_start │
│dac_done│  │cim_start  │  │─►adc_done│
│  ◄─────│  │──►cim_done│  │          │
└────────┘  │           │  │ raw_data │
            │adc_start  │  │  [0..19] │
            │──►adc_done│  │          │
            │bl_sel─►   │  │ Scheme B │
            │  bl_data  │──►│ diff:    │
            └───────────┘  │pos-neg   │
                           │=signed   │
                           │ 9-bit×10 │
                           └──┬───────┘
                              │neuron_in_valid
                              │neuron_in_data[9:0]
                              ▼
                        ┌──────────┐
                        │lif_neurons│
                        │ (10路并行) │
                        │           │
                        │ membrane[i] += │
                        │  sign_ext(in[i])│
                        │   <<< bitplane  │
                        │                 │
                        │ if mem >= thresh│
                        │   → spike!      │
                        │   → spike_queue │
                        └──┬──────────────┘
                           │out_fifo_push
                           │spike_id[3:0]
                           ▼
                     ┌───────────┐
                     │output_fifo│
                     │ (4-bit    │
                     │  ×256)    │
                     └──┬────────┘
                        │ out_fifo_rdata
                        ▼
                     ┌──────────┐
                     │ reg_bank │  ──► TB/CPU 读取
                     │OUT_FIFO_ │      spike_id
                     │DATA 0x1C │
                     └──────────┘
```

## 具体数据变换过程（以单帧 T=1 子流程示例，非定版默认值）

|阶段|数据形态|位宽|说明|
|---|---|---|---|
|**1. TB 写 SRAM**|8-bit pixel × 64 → 拆成 8 个 bit-plane，每 plane 64-bit = 2×32-bit word|32-bit × 16 words|MSB plane 先写|
|**2. DMA 搬运**|每次读 2 个 32-bit word → 拼成 `{word1, word0}` = 64-bit|64-bit|push 到 input_fifo，共 8 次（8 planes）|
|**3. FETCH**|从 input_fifo pop 一个 64-bit wl_bitmap|64-bit|1 = 该像素该 bit 为 1|
|**4. DAC**|wl_bitmap → dac_ctrl 锁存 → wl_spike 输出到 CIM macro|64-bit|数字信号，实际芯片会转成模拟 WL 脉冲|
|**5. CIM 计算**|64 条 WL × 256 条 BL（RRAM 权重）→ BL 电流|模拟量|行为模型用 `popcount * scale + offset` 近似|
|**6. ADC 扫描**|20 个 BL 通道逐个采样，bl_sel 0→19|8-bit × 20|每次 adc_start → adc_done 采一个通道|
|**7. 差分运算**|`diff[i] = raw_data[i] - raw_data[i+10]`，i=0..9|**signed 9-bit** × 10|Scheme B 核心：正列减负列|
|**8. LIF 累加**|`membrane[i] += sign_ext(diff[i]) <<< bitplane_shift`|signed 32-bit|bit-plane 7 权重最大（×128），bit 0 权重最小（×1）|
|**9. 阈值判断**|`if membrane[i] >= threshold → spike`|1-bit × 10|spike 后 soft/hard reset membrane|
|**10. 输出**|spike_id (0~9) 入 output_fifo → CPU 读取|4-bit|哪个神经元 fire = 分类结果|

### 关键时序：一次完整推理循环

```
示例采用 T=1, PIXEL_BITS=8：共 8 个 bit-plane 子步（仅用于解释编码流程；定版实际为 T=10）

bitplane_shift:  7 → 6 → 5 → 4 → 3 → 2 → 1 → 0
                 ↑                                ↑
              MSB(×128)                        LSB(×1)

每个子步:
  FETCH(1clk) → DAC(~2clk) → CIM(~2clk) → ADC(20×~2=~40clk) → INC(1clk)
  ≈ 46 clk/sub-step × 8 planes ≈ 368 clk total ≈ 7.4μs @50MHz
```

这就是当前代码从输入到输出的完整数据流。核心特点是 **bit-plane 时分复用**：不一次送 8-bit 像素，而是拆成 8 个 1-bit 平面分别送入 CIM 阵列，LIF 神经元通过 `<<< bitplane_shift` 给每个平面的结果加上对应的二进制权重。

## GPT 修改审计结果

### 改了什么

GPT 做了 5 个文件的修改：

|文件|修改内容|
|---|---|
|`snn_soc_pkg.sv`|+2 行：`WL_GROUP_WIDTH=8`, `WL_GROUP_COUNT=8`|
|`wl_mux_wrapper.sv`|**新建**，118 行，WL 时分复用 FSM|
|`snn_soc_top.sv`|新增 wire 声明 + wrapper 实例 + dac_ctrl 改接 wrapped 信号|
|`sim.f`|加了 `wl_mux_wrapper.sv`|
|`08_cim_analog_interface.md`|加了协议冻结条款、责任归属、时序更新|
### 逐项检查

**1. wl_mux_wrapper.sv — FSM 逻辑**

功能正确，但有一个**时序问题需要你注意**（不是 bug，是设计选择）：

```
ST_IDLE → 收到 wl_valid_pulse_in → 锁存 wl_buf → ST_SEND
ST_SEND → 连续 8 拍（grp_idx 0→7），每拍 wl_latch=1 → ST_DONE  
ST_DONE → 发出 wl_valid_pulse_out → ST_IDLE
```

实际拍数：`1(锁存) + 8(发送) + 1(DONE) = 10 拍`，不是文档写的 8 拍。这是因为 ST_IDLE→ST_SEND 过渡 1 拍 + ST_DONE 1 拍。文档写"8 cycles"指的是 ST_SEND 阶段本身，但总 overhead 是 10 cycles。**这不影响功能正确性**，只是文档说的 `123 cycles/sub-step` 实际应该是 `125 cycles`，差 2 拍，可以忽略。

**2. snn_soc_top.sv — 数据通路接入**

```
原来：cim_array_ctrl → wl_bitmap → dac_ctrl
现在：cim_array_ctrl → wl_bitmap → wl_mux_wrapper → wl_bitmap_wrapped → dac_ctrl
```

接入正确。wrapper 的输出 `wl_bitmap_out` 就是内部缓存的 `wl_buf`（= 原始 `wl_bitmap_in` 的锁存副本），所以 dac_ctrl 收到的数据内容不变，只是延迟了 ~10 拍。

外部复用信号（`wl_data`, `wl_group_sel`, `wl_latch`, `wl_mux_busy`）当前被 `_unused_wl_mux` 消掉了 lint 警告 — 合理，因为现在还没有 chip_top 来消费它们。

**3. snn_soc_pkg.sv — 新参数**

```systemverilog
parameter int WL_GROUP_WIDTH = 8;
parameter int WL_GROUP_COUNT = (NUM_INPUTS / WL_GROUP_WIDTH);  // = 8
```

干净，无副作用。

**4. sim.f — 编译顺序**

`wl_mux_wrapper.sv` 排在 `cim_macro_blackbox.sv` 前面、`cim_array_ctrl.sv` 后面。顺序正确（wrapper 依赖 pkg，被 snn_soc_top 使用）。

**5. 08_cim_analog_interface.md — 文档**

新增的 1.3 节（协议冻结）、1.3.1（字段表）、1.3.2（责任归属）内容准确，与 RTL 一致。

### 有没有引入新问题？

| 检查项     | 结果                                                                                   |
| ------- | ------------------------------------------------------------------------------------ |
| 端口匹配    | OK — wrapper 的输入/输出与 snn_soc_top 声明的 wire 位宽完全匹配                                     |
| 功能等价性   | OK — wrapper 是透传（wl_bitmap_out = wl_buf = wl_bitmap_in 的锁存），对内部数据通路**只加了延迟，不改数据**    |
| lint 兼容 | OK — 未使用的外部复用信号已做 `_unused` 处理                                                       |
| 编译顺序    | OK — sim.f 已包含新模块                                                                    |
| TB 兼容性  | **需注意** — TB 没改，但由于 wrapper 增加了约 10 拍延迟，推理总延迟会变长。TB 是轮询 DONE 的，所以不会出错，只是仿真时间多了一些。OK。 |

---
