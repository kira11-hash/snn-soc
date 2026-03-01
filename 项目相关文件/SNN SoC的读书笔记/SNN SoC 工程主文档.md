## 一、版本迭代安排
## ✅ 推荐路线（V1 → V2 → V3）

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
## ✅ 基于 Excel 统计“共性痛点”的总体判断

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

## ✅ V1（这次 6/30 数字单独流片）

**原则：低风险、易验证、能在论文里说清楚**

---

### 1) 逻辑 64×16，物理 49×10 的映射
**添加时机**：V1 任意阶段（不依赖 CPU/AXI，最早即可加）

**为什么值得做？**

- 逻辑维度用 2 的幂次方（64×16）后，地址映射可以用简单位移完成
- 软件写固件时省掉大量 if (col >= 49) 判断
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
- Shadow Buffer 把 49 个结果集中存起来，CPU 只读一次

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

# ✅ V2 & V3（等模拟宏 + RRAM 成熟后再上）

**原则：价值高，但风险高、强依赖模拟**

---

### 1) Program‑and‑Verify FSM（自动写‑读‑验）
**添加时机**：V2（模拟宏 + ADC 稳定之后）

**为什么这条不要本次做？**

- 2D RRAM 不稳定，需要写入后再读出验证
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
- 但你可以做 **神经元状态/阈值的寄存器缓存**
- **V2 可做**，V1 只写“启发来源”即可

## 三、当前V1版本的内部迭代思路

# V1 改进路线

  

> **注意**：本文件为早期规划草稿。正式的时间规划和学习路径请参见：

> - [doc/07_tapeout_schedule.md](../../doc/07_tapeout_schedule.md) - **流片时间规划（V1完整路线图）**

> - [doc/06_learning_path.md](../../doc/06_learning_path.md) - **学习路径（新手必读）**

## 📊 当前 MVP vs V1 设计文档对比

  

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

| ⑩ | 输入 Spike FIFO 256×49bit | ✅ 有 | ✅ 匹配 |

| ⑪ | 输出 Spike FIFO 256×4bit | ✅ 有 | ✅ 匹配 |

| ⑫ | CIM 阵列控制器 | ✅ 有 | ✅ 匹配 |

| ⑬ | DAC 控制器 | ✅ 有 | ✅ 匹配 |

| ⑭ | ADC 控制器 | ✅ 有 | ✅ 匹配 |

| ⑮ | CIM Macro 黑盒 | ✅ 有 | ✅ 匹配 |

| ⑯ | 数字神经元 (10×LIF) | ✅ 有 | ✅ 匹配 |

| - | 系统总线 | bus_simple_if | 🔴 需升级 AXI |

  

---

  

## 🎯 需要改进的 6 个方面（按优先级排序）

  

### **改进 1：UART 控制器** 🟢 优先级最高

**原因**：V2 的核心数据流是 `PC → UART → CPU → SRAM`，没有 UART 就无法与外部通信

  

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

  

### **改进 5：RISC-V Core 集成 (E203)** 🔴 优先级低（最后做）

**原因**：需要先完成总线升级，否则无法连接

**添加时机**：阶段 5（AXI-Lite 完成之后；依赖前面 1–4 阶段打底）

  

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

  

## 📋 建议的改进顺序

  

```

阶段 0: 理解当前 MVP（你现在的位置）

   ↓

阶段 1: UART 控制器 ⭐⭐

   │    - 实现完整的 UART TX/RX

   │    - 用 TB 验证收发功能

   ↓

阶段 2: SPI 控制器 ⭐⭐

   │    - 实现 SPI Master

   │    - 连接外部 Flash 模型验证

   ↓

阶段 3: DMA 扩展 ⭐⭐

   │    - 支持多目标选择

   │    - 支持 SPI→SRAM 路径

   ↓

阶段 4: 总线升级 AXI-Lite ⭐⭐⭐

   │    - 设计 AXI interconnect

   │    - 保持 slave 接口兼容

   ↓

阶段 5: E203 集成 ⭐⭐⭐⭐

   │    - 集成 RISC-V Core

   │    - 编写 bootloader

   │    - 编写驱动固件

   ↓

完成 V1 架构 🎉

```

  

---

  

## 🔧 每个阶段的验收标准

  

| 阶段 | 验收标准 |

|------|----------|

| 1 | TB 通过 UART 发送 "Hello"，能正确回显 |

| 2 | TB 通过 SPI 读取 Flash 模型中的数据 |

| 3 | DMA 能从 SPI 搬数据到 SRAM，从 SRAM 搬到 Weight Buffer |

| 4 | 用 AXI VIP 或简单 AXI Master TB 完成读写测试 |

| 5 | E203 执行固件，通过 UART 输出 "Boot OK"，完成一次推理 |

  

---

  

## 💡 我的建议

  

1. **阶段 1-2 可以并行开发**，UART 和 SPI 相互独立

2. **阶段 3 依赖阶段 2**，因为需要 SPI 作为 DMA 的数据源

3. **阶段 4-5 是大工程**，建议在前 3 个阶段稳定后再进行

4. **如果时间紧张**，可以先跳过 SPI，用 TB 直接初始化 SRAM 内容（仿真够用）

## 四、看论文的方法
## 一、只看 “SoC / 系统数字部分” 的阅读顺序（从系统到细节）

**优先级 1（系统级 SoC 视角，必读）**

1. [A_RISC-V_Neuromorphic_Micro-Controller_Unit_vMCU...pdf](https://file+.vscode-resource.vscode-cdn.net/c%3A/Users/24201/.vscode/extensions/openai.chatgpt-0.4.68-win32-x64/webview/# "A_RISC-V_Neuromorphic_Micro-Controller_Unit_vMCU...pdf")
2. [DIANA_An_End-to-End_Hybrid_DIgital_and_ANAlog_Neural_Network_SoC...pdf](https://file+.vscode-resource.vscode-cdn.net/c%3A/Users/24201/.vscode/extensions/openai.chatgpt-0.4.68-win32-x64/webview/# "DIANA_An_End-to-End_Hybrid_DIgital_and_ANAlog_Neural_Network_SoC...pdf")
3. [SENECA building a fully digital neuromorphic processor...pdf](https://file+.vscode-resource.vscode-cdn.net/c%3A/Users/24201/.vscode/extensions/openai.chatgpt-0.4.68-win32-x64/webview/# "SENECA building a fully digital neuromorphic processor...pdf")
4. [Darwin__A neuromorphic hardware co-processor...pdf](https://file+.vscode-resource.vscode-cdn.net/c%3A/Users/24201/.vscode/extensions/openai.chatgpt-0.4.68-win32-x64/webview/# "Darwin__A neuromorphic hardware co-processor...pdf") / [darwin3.pdf](https://file+.vscode-resource.vscode-cdn.net/c%3A/Users/24201/.vscode/extensions/openai.chatgpt-0.4.68-win32-x64/webview/# "darwin3.pdf")
5. [ODIN (UCLouvain).pdf](https://file+.vscode-resource.vscode-cdn.net/c%3A/Users/24201/.vscode/extensions/openai.chatgpt-0.4.68-win32-x64/webview/# "ODIN (UCLouvain).pdf")

**优先级 2（SoC 集成 + 能耗表格有价值）**  
6) [ANP-I_A_28-nm_1.5-pJ_SOP...pdf](https://file+.vscode-resource.vscode-cdn.net/c%3A/Users/24201/.vscode/extensions/openai.chatgpt-0.4.68-win32-x64/webview/# "ANP-I_A_28-nm_1.5-pJ_SOP...pdf")  
7) [C-DNN_An_Energy-Efficient...pdf](https://file+.vscode-resource.vscode-cdn.net/c%3A/Users/24201/.vscode/extensions/openai.chatgpt-0.4.68-win32-x64/webview/# "C-DNN_An_Energy-Efficient...pdf")  
8) [A_73.53TOPS_W...SoC...pdf](https://file+.vscode-resource.vscode-cdn.net/c%3A/Users/24201/.vscode/extensions/openai.chatgpt-0.4.68-win32-x64/webview/# "A_73.53TOPS_W...SoC...pdf")

> **注意**：CIM 类论文你只关注**系统级功耗/数据搬运/控制/缓存结构**，跳过宏电路细节。

**从 6/30 流片的节奏来看，把截图里的这些文章吃透就够了**，然后就应该**尽快确定创新点并开始工程实现**，而不是无限扩展阅读。

---

# 为什么“读这些就够了”

- 你现在的目标是 **V1 可流片、能解释、能写论文**
- 你负责的是 **SoC 数字系统部分**
- 截图里的文章已经覆盖了：
    - SoC 架构
    - 系统级能耗瓶颈
    - 典型系统级设计思路

继续加论文只会**增加阅读负担，不一定增加创新点**。

---

# 推荐节奏（最现实）

### ✅ 1）只精读截图里的 8 篇

重点只做“问题提炼表”。  
**每篇只要 30–60 分钟**，不要陷进去。

### ✅ 2）用这 8 篇确定 2–3 个创新点

就可以开始工程实现了。

### ✅ 3）后续再补读

如果你发现创新点不够强，**再补读一两篇**即可。

---

# 我的建议总结

✅ **是的：这 8 篇足够支撑你确定创新点并开干**  
✅ **不要陷在无止境扩展阅读**  
⚠️ 若后续写论文发现引用不够，再补 1–2 篇




