# SNN SoC 完整学习指南

**适用对象**: 研一新生，首次接触系统级数字 IC 设计
**前置知识**: Verilog/SystemVerilog 基础语法，数字电路基础
**学习目标**: 完全理解 MVP 架构、能独立修改和扩展，为 V1 开发做准备

**参数口径**：本文涉及的默认参数与时序数值以 `rtl/top/snn_soc_pkg.sv` 为准，若与文档不一致以 pkg 为准。

---

## 第一部分：项目评估

### 这份 SoC 作为入门材料怎么样？

**评价：非常适合，属于"麻雀虽小五脏俱全"的教学级项目**

| 评估维度 | 评分 | 说明 |
|----------|------|------|
| 完整性 | ⭐⭐⭐⭐⭐ | 包含总线、存储、DMA、控制器、数据通路完整链路 |
| 复杂度 | ⭐⭐⭐ | 约 2000 行 RTL，适中，不会 overwhelming |
| 规范性 | ⭐⭐⭐⭐ | 模块划分清晰，命名规范，有完整文档 |
| 可扩展性 | ⭐⭐⭐⭐ | 预留了 UART/SPI/JTAG 接口，易于迭代到 V1 |
| 实用性 | ⭐⭐⭐⭐⭐ | 直接对应真实流片需求（6.30 数字单独流片 + 片外混合集成验证） |

**与其他入门项目对比**:
```
简单计数器/FIFO     ← 太简单，缺乏系统视角
你的 SNN SoC MVP   ← ✓ 正好，系统完整但不过于复杂
完整 RISC-V SoC     ← 太复杂，容易迷失
```

### 学习建议

- "看懂 → 能改 → 能从头写"是正确的学习路径
- 每读完一个模块就手画框图或时序图
- 不要急于求成，每个阶段都要验证理解

---

# Part A: MVP 基础学习

**总时长**: 约 2 周（每天 3-4 小时）

---

## 阶段 A：鸟瞰全局（Day 1-2）

**目标**: 建立整体印象，知道"有什么"

### 阅读顺序

```
1. doc/00_overview.md          ← 整体架构说明
2. doc/01_memory_map.md        ← 地址空间划分
3. doc/02_reg_map.md           ← 寄存器定义（重要！）
4. rtl/top/snn_soc_pkg.sv      ← 全局参数和地址常量
5. rtl/top/snn_soc_top.sv      ← 顶层连接（先看模块列表，不看细节）
```

### 学习方法

- **拿纸画出模块框图**（必须手画！工具画的记不住）
- 标注每个模块的输入输出
- 理解地址空间划分的意义

### 重点理解

```
Q: 数据从哪里来，到哪里去？
A: data_sram → DMA → input_fifo → DAC → CIM → ADC → LIF → output_fifo

Q: 为什么分成多个地址段？
A: 便于地址译码，不同设备类型用不同地址前缀

Q: 一帧图像包含多少个子时间步？
A: 8 个（PIXEL_BITS = 8，每个 bit 是一个子时间步）

Q: 数据流和控制流如何分离？
A: 数据流走固定通路（data_sram → DMA → input_fifo → CIM → output_fifo），
   控制流由 CPU 负责寄存器配置/启动/读结果，二者分离便于验证与扩展。
```

### 关键参数（务必记住！）

| 参数 | 值 | 含义 |
|------|------|------|
| NUM_INPUTS | 64 | 输入维度（8×8 离线投影后特征） |
| NUM_OUTPUTS | 10 | 输出类别数（0-9 数字分类） |
| PIXEL_BITS | 8 | 每像素位宽，决定子时间步数 |
| ADC_BITS | 8 | ADC 输出位宽 |
| ADC_CHANNELS | 20 | ADC 通道数（Scheme B: 10 正 + 10 负） |
| NEURON_DATA_WIDTH | 9 | 有符号差分输出位宽（ADC_BITS+1） |
| LIF_MEM_WIDTH | 32 | LIF 膜电位位宽（建议 >= ADC_BITS + PIXEL_BITS） |
| ADDR_DATA_BASE | 0x0001_0000 | 数据存储起始地址 |
| ADDR_REG_BASE | 0x4000_0000 | 寄存器起始地址 |

### 检验标准

- [ ] 能画出包含所有模块的框图（不看代码）
- [ ] 能说出数据从输入到输出经过哪些模块
- [ ] 能说出每个地址段对应什么外设
- [ ] 能解释为什么 LIF 膜电位需要 32 位

---

## 阶段 B：理解总线和数据搬运（Day 3-4）

**目标**: 理解 CPU/TB 如何与外设通信

### 阅读顺序

```
1. rtl/bus/bus_simple_if.sv         ← 接口定义（5分钟）
2. rtl/bus/bus_interconnect.sv      ← 地址译码（重点）
3. tb/tb_lib/bus_master_tasks.sv    ← 读写时序（重点）
4. rtl/mem/sram_simple.sv           ← 最简单的 slave
5. rtl/mem/sram_simple_dp.sv        ← 带 DMA 端口的 SRAM
6. rtl/dma/dma_engine.sv            ← DMA 状态机（重点）
7. rtl/mem/fifo_sync.sv             ← 同步 FIFO
```

### 学习方法

- 对照 bus_simple_if 的信号，在纸上画时序图
- 理解 "1-cycle 响应" 的含义
- 跟踪 DMA 状态机的每个状态转换

### 总线时序图（手画这个！）

**写操作时序**:
```
clk     : _/‾\_/‾\_/‾\_/‾\
m_valid : ___/‾‾‾\________
m_write : ___/‾‾‾\________
m_addr  : ---<ADDR>-------
m_wdata : ---<DATA>-------
m_ready : ______/‾‾‾\_____   ← T+1 响应
```

**读操作时序**:
```
clk      : _/‾\_/‾\_/‾\_/‾\
m_valid  : ___/‾‾‾\________
m_write  : ___________      ← 保持低
m_addr   : ---<ADDR>-------
m_rvalid : ______/‾‾‾\_____  ← T+1 响应
m_rdata  : ------<DATA>----
```

### 重点理解

```
Q: 为什么 DMA 需要 ST_SETUP 状态？
A: 因为 addr_ptr <= src_addr_reg 是非阻塞赋值，
   需要等一拍才能让组合逻辑 dma_rd_addr = addr_ptr 读到正确地址

Q: bus_interconnect 为什么要打一拍？
A: 为了保证固定 1-cycle 响应，让时序可预测

Q: 64-bit 数据怎么存储在 32-bit SRAM 中？
A: 用 2 个 word：word0[31:0] + word1[31:0] = 64 bit（整打包，无废 bit）
```

### DMA 状态机详解

```
ST_IDLE ──start_pulse──> ST_SETUP
   ↑                        │
   │                        ▼
   │                     ST_RD0 ──────> 读 word0 (低 32 位)
   │                        │
   │                        ▼
   │                     ST_RD1 ──────> 读 word1 (高 32 位)
   │                        │
   │                        ▼
   │      还有数据?      ST_PUSH ──────> 拼接成 64-bit 写入 FIFO
   │        ├─Yes──────────┘
   │        │
   └─No─────┘
```

### 检验标准

- [ ] 能手画 bus_write32 和 bus_read32 的时序图
- [ ] 能解释 DMA 的 5 个状态各自做什么
- [ ] 能说出为什么 push 和 pop 是单拍信号
- [ ] 能解释 DMA_LEN_WORDS 为什么必须是偶数

---

## 阶段 C：理解 SNN 核心流水线（Day 5-7）

**目标**: 理解推理的完整数据流，这是项目最核心的部分！

### 阅读顺序（按数据流方向）

```
1. rtl/snn/cim_array_ctrl.sv     ← 主 FSM（最重要！）
2. rtl/snn/wl_mux_wrapper.sv     ← WL 时分复用（64-bit→8×8 分组发送）
3. rtl/snn/dac_ctrl.sv           ← DAC 握手
4. doc/03_cim_if_protocol.md     ← CIM 接口协议
5. rtl/snn/cim_macro_blackbox.sv ← 行为模型
6. rtl/snn/adc_ctrl.sv           ← ADC 时分复用（重点）
7. rtl/snn/lif_neurons.sv        ← LIF 神经元（重中之重！）
```

### 学习方法

- 画出 cim_array_ctrl 的状态转移图
- 标注每个状态的进入条件和退出条件
- 理解 pulse vs level 的区别

### 主控状态机流转图（必须手画！）

```
            start_pulse
                │
                ▼
    ┌─────► ST_IDLE ◄─────────────────┐
    │                                  │
    │       ST_FETCH ─────────────────►│  ← 从 FIFO 取数据
    │           │                      │
    │           ▼                      │
    │       ST_DAC ──► dac_done_pulse  │  ← wl_mux(10拍) + DAC 转换
    │           │                      │
    │           ▼                      │
    │       ST_CIM ──► cim_done_pulse  │  ← CIM 计算
    │           │                      │
    │           ▼                      │
    │       ST_ADC ──► neuron_in_valid │  ← ADC 采样 20 通道后做差分
    │           │                      │
    │           ▼                      │
    │       ST_INC ────────────────────┤  ← 更新计数器
    │           │                      │
    │     ts < max?                    │
    │      │    │                      │
    │     Yes   No                     │
    │      │    └──► ST_DONE ──────────┘
    │      │
    └──────┘
```

### bitplane_shift 变化规律

```
帧0: bitplane_shift = 7,6,5,4,3,2,1,0 (8个子时间步)
帧1: bitplane_shift = 7,6,5,4,3,2,1,0
...
帧N-1: bitplane_shift = 7,6,5,4,3,2,1,0

总子时间步数 = TIMESTEPS × PIXEL_BITS = 10 × 8 = 80（定版 T=10）
```

### ADC 时分复用详解

```
20 个通道输出（Scheme B: 10 正 + 10 负），只用 1 个 8-bit ADC：

bl_sel: 0 → 1 → 2 → ... → 19（前 10 正列，后 10 负列）

每个通道的采样流程:
1. 设置 bl_sel (5-bit)
2. 等待 settle（稳定）
3. adc_start 脉冲
4. 等待 adc_done 脉冲
5. 锁存 bl_data[7:0] 到 raw_data[bl_sel]
6. bl_sel++

20 个通道全部采完后，数字差分减法：
- diff[i] = raw_data[i] - raw_data[i+10]（i=0..9）
- neuron_in_valid 拉高一拍
- neuron_in_data = 10 路 signed 9-bit 差分结果
```

### LIF 神经元算法（核心！）

```systemverilog
// 移位累加（bit-serial 核心，Scheme B 有符号）
signed_in = $signed(neuron_in_data[i]);           // 9-bit signed
addend = sign_extend(signed_in, 32) <<< bitplane_shift;  // 算术左移
new_mem = membrane[i] + addend;                   // signed 32-bit 累加

// 有符号阈值比较 + spike 产生
if (new_mem >= $signed(threshold)) begin
    spike = 1'b1;
    membrane[i] = (reset_mode) ? 0 : (new_mem - threshold);
end else begin
    membrane[i] = new_mem;
end
```

**位权计算示例**：
| bitplane_shift | 权重 | 说明 |
|----------------|------|------|
| 7 | 128 | MSB，最高权重 |
| 6 | 64 | |
| ... | ... | |
| 1 | 2 | |
| 0 | 1 | LSB，最低权重 |

### 重点理解

```
Q: cim_array_ctrl 在 FIFO 为空时会怎样？
A: 使用全 0 的 wl_bitmap，不会卡死

Q: 为什么 adc_ctrl 需要 20 次循环？
A: Scheme B 时分复用架构，1 个 ADC 依次采样 20 个通道（10 正列 + 10 负列）

Q: neuron_in_valid 是在哪个模块产生的？
A: adc_ctrl，在 20 路数据采样完成并执行数字差分减法后产生单拍脉冲

Q: 为什么用 MSB-first（bitplane_shift 从 7 开始）？
A: 高位权重大，先处理高位可以更早判断是否超过阈值

Q: 膜电位为什么不会溢出？
A: 定版（T=10）：10帧 × 8步 × 255（8-bit ADC max）= 20400，约需 15 位；32 位有符号留有充足余量
   即使 T=20：20 × 8 × 255 = 40800，约需 16 位；使用 32 位留有充足余量
```

### 检验标准

- [ ] 能画出 cim_array_ctrl 完整状态图
- [ ] 能解释 wl_mux_wrapper 如何将 64-bit 并行信号拆成 8 组 × 8-bit 串行发送（10 cycles）
- [ ] 能解释每个 pulse 信号的产生者和消费者
- [ ] 能说出一个子时间步需要多少时钟周期（~125 cycles: WL复用10 + DAC5 + CIM10 + ADC100）
- [ ] 能解释 LIF 的移位累加原理
- [ ] 能说出 soft reset 和 hard reset 的区别

---

## 阶段 D：理解寄存器和控制（Day 8）

**目标**: 理解软件如何配置硬件

### 阅读顺序

```
1. doc/02_reg_map.md            ← 对照文档
2. rtl/reg/reg_bank.sv          ← 实现
3. rtl/reg/fifo_regs.sv         ← FIFO 状态
```

### 寄存器类型详解

| 类型 | 含义 | 示例 |
|------|------|------|
| RW | 可读可写 | THRESHOLD、TIMESTEPS |
| RO | 只读 | NUM_INPUTS、NUM_OUTPUTS |
| W1P | 写1产生脉冲，自动清0 | CIM_CTRL.START |
| W1C | 写1清除sticky位 | CIM_CTRL.DONE |

### 重点寄存器

| 地址 | 名称 | 关键位段 |
|------|------|----------|
| 0x4000_0000 | THRESHOLD | [31:0] 阈值，默认 THRESHOLD_DEFAULT = 10200（4×255×10，定版） |
| 0x4000_0004 | TIMESTEPS | [7:0] 帧数，默认 10（定版） |
| 0x4000_0014 | CIM_CTRL | bit0=START(W1P), bit1=SOFT_RESET(W1P), bit7=DONE(W1C) |
| 0x4000_0018 | STATUS | bit0=BUSY(RO), bit[15:8]=TIMESTEP_CNT(RO) |
| 0x4000_0024 | THRESHOLD_RATIO | [7:0] 阈值比例，默认 4 (ratio_code=4, 4/255≈0.0157, 定版) |
| 0x4000_0028 | ADC_SAT_COUNT | [15:0]=sat_high, [31:16]=sat_low (RO) |

### 重点理解

```
Q: W1P 和 W1C 有什么区别？
A: W1P (Write-1 Pulse): 写1产生单拍脉冲，自动清0
   W1C (Write-1 Clear): 写1清除sticky位，读不清

Q: OUT_FIFO_DATA 读取时为什么要延迟一拍 pop？
A: 避免读数据和弹出在同一拍，防止时序竞争

Q: 如何启动一次推理？
A: 1. 写 THRESHOLD
   2. 写 TIMESTEPS
   3. DMA 传输数据
   4. 写 CIM_CTRL.START = 1
```

### 检验标准

- [ ] 能从文档找到任意寄存器的地址和位定义
- [ ] 能解释 start_pulse 是如何产生的
- [ ] 能说出 done_sticky 的置位和清除条件
- [ ] 能写出完整的软件操作流程

---

## 阶段 E：理解 Testbench（Day 9）

**目标**: 理解验证流程，能修改测试

### 阅读文件

```
1. tb/tb_lib/bus_master_tasks.sv ← 总线读写任务
2. tb/top_tb.sv                  ← 测试流程
```

### 测试流程分解

```
Step 1: 配置寄存器
        ├─ 写 THRESHOLD = 200（低阈值，易触发 spike）
        └─ 写 TIMESTEPS = 5

Step 2: 准备数据
        └─ 写入 data_sram（5 个 timestep × 2 word = 10 word）

Step 3: 启动 DMA
        ├─ 写 DMA_SRC_ADDR = 0x0001_0000
        ├─ 写 DMA_LEN_WORDS = 10
        ├─ 写 DMA_CTRL.START = 1
        └─ 轮询 DMA_CTRL.DONE

Step 4: 启动推理
        ├─ 写 CIM_CTRL.START = 1
        └─ 轮询 CIM_CTRL.DONE（超时保护）

Step 5: 读取结果
        ├─ 读 OUT_FIFO_COUNT
        └─ 循环读 OUT_FIFO_DATA（每读一次自动 pop）
```

### 波形 Dump

```systemverilog
$fsdbDumpfile("waves/snn_soc.fsdb");
$fsdbDumpvars(0, top_tb);
```

### 检验标准

- [ ] 能说出 TB 的 5 个步骤
- [ ] 能修改 wl_vec 数据观察不同输出
- [ ] 理解 do-while 轮询的作用
- [ ] 能解释为什么 DMA_LEN_WORDS = 10（5 帧 × 2 word/帧）

---

## 第三部分：仿真实战

### 实验 1：基础仿真（必做）

**目标**: 跑通仿真，生成波形

**步骤**:
```bash
cd sim
./run_vcs.sh          # 编译并运行
./run_verdi.sh        # 打开波形查看器
```

**预期结果**:
```
- vcs.log 无 Error
- sim.log 出现 "[TB] Simulation finished."
- sim.log 出现 "[TB] OUT_FIFO_COUNT = N"（N 可能为 0）
- waves/snn_soc.fsdb 文件生成
```

**Verdi 查看重点**:
1. 添加 `u_cim_ctrl.state` 信号，观察状态流转
2. 添加 `u_adc.bl_sel` 信号，观察 0-19 循环（Scheme B：前10正列，后10负列）
3. 添加 `u_lif.membrane[0]` 信号，观察膜电位累加
4. 添加 `u_cim_ctrl.bitplane_shift` 信号，观察 7→0 变化

---

### 实验 2：参数修改实验（必做）

**目标**: 理解参数对行为的影响

**实验 2.1**: 修改时间步数
```systemverilog
// tb/top_tb.sv
bus_write32(bus_vif, 32'h4000_0004, 32'd3, 4'hF);  // TIMESTEPS = 3
```
预期：推理更快完成，输出 spike 更少

**实验 2.2**: 修改阈值
```systemverilog
// tb/top_tb.sv
bus_write32(bus_vif, 32'h4000_0000, 32'd50, 4'hF);  // THRESHOLD = 50
```
预期：更容易触发 spike，输出更多

**实验 2.3**: 修改 ADC 延迟
```systemverilog
// rtl/top/snn_soc_pkg.sv
parameter int ADC_SAMPLE_CYCLES = 10;  // 改成 10
```
预期：每个 timestep 时间变长

---

### 实验 3：调试实验（推荐）

**目标**: 学会定位问题

**故意引入 bug**:
```systemverilog
// rtl/snn/cim_array_ctrl.sv ST_ADC 状态
// 把 neuron_in_valid 改成 cim_done（错误的信号）
if (cim_done) begin  // 原本是 neuron_in_valid
  state <= ST_INC;
end
```

**观察现象**: 仿真卡死在某个状态

**调试方法**:
1. 在 Verdi 中添加 `state` 信号
2. 观察卡在哪个状态（应该是 ST_ADC）
3. 检查该状态的退出条件
4. 发现 cim_done 已经过去，等不到了
5. 定位到错误信号

---

### 实验 4：添加调试输出（推荐）

**目标**: 学会使用 $display 调试

```systemverilog
// 在 cim_array_ctrl.sv 添加
always_ff @(posedge clk) begin
  if (rst_n && state != $past(state))
    $display("[%0t] CIM FSM: %s -> %s, ts=%0d, bp=%0d",
             $time, $past(state).name(), state.name(),
             timestep_counter, bitplane_shift);
end
```

---

### 模块级仿真实战（推荐）

**目标**: 深入理解每个模块的行为，建立系统性的验证思维

**为什么要做模块级仿真**:
1. **理解更深刻** - 专注单个模块，观察每个信号变化
2. **调试更容易** - 问题定位更精准
3. **测试更全面** - 可以覆盖各种边界情况
4. **信心更足** - 每个模块都验证通过，集成时更放心

#### 建议的仿真顺序（从简单到复杂）

**阶段 1：基础模块（1-2天）**

1. **FIFO** ([rtl/mem/fifo_sync.sv](rtl/mem/fifo_sync.sv))
   - 测试场景：满、空、同时读写、计数器
   - 最简单，先练手

2. **SRAM** ([rtl/mem/sram_simple.sv](rtl/mem/sram_simple.sv))
   - 测试场景：读写、地址边界

**阶段 2：控制逻辑（2-3天）**

3. **DMA 引擎** ([rtl/dma/dma_engine.sv](rtl/dma/dma_engine.sv))
   - 测试场景：正常搬运、越界、奇数长度
   - 重点观察状态机流转

4. **寄存器组** ([rtl/reg/reg_bank.sv](rtl/reg/reg_bank.sv))
   - 测试场景：读写、W1C、只读寄存器

**阶段 3：SNN 核心（3-4天）**

5. **LIF 神经元** ([rtl/snn/lif_neurons.sv](rtl/snn/lif_neurons.sv))
   - 测试场景：membrane 累加、超过阈值发放 spike
   - 测试不同输入值、不同阈值

6. **ADC 控制** ([rtl/snn/adc_ctrl.sv](rtl/snn/adc_ctrl.sv))
   - 测试场景：时分复用、bl_sel 切换

7. **CIM 阵列控制** ([rtl/snn/cim_array_ctrl.sv](rtl/snn/cim_array_ctrl.sv))
   - 测试场景：完整推理流程、bitplane 顺序、timestep 计数
   - 最复杂，留到最后

**阶段 4：集成测试**

8. **顶层 smoke test**（已有）
   - 验证所有模块协同工作

#### 模块测试框架示例

```systemverilog
// 示例：FIFO 模块测试
module fifo_tb;
  // 1. 信号声明
  logic clk, rst_n;
  logic push, pop;
  logic [31:0] push_data, rd_data;
  logic empty, full;
  logic [4:0] count;

  // 2. 实例化 DUT
  fifo_sync #(.WIDTH(32), .DEPTH(16)) dut (
    .clk(clk),
    .rst_n(rst_n),
    .push(push),
    .push_data(push_data),
    .pop(pop),
    .rd_data(rd_data),
    .empty(empty),
    .full(full),
    .count(count)
  );

  // 3. 时钟生成
  initial begin
    clk = 0;
    forever #10 clk = ~clk;  // 50MHz
  end

  // 4. 测试场景
  initial begin
    // 复位
    rst_n = 0; push = 0; pop = 0;
    #100 rst_n = 1;

    // 测试1：写满 FIFO
    $display("[Test 1] Fill FIFO");
    repeat(16) begin
      @(posedge clk);
      push = 1;
      push_data = $random;
    end
    @(posedge clk);
    push = 0;

    // 检查 full 信号
    if (!full) $error("FIFO should be full!");

    // 测试2：读空 FIFO
    $display("[Test 2] Drain FIFO");
    repeat(16) begin
      @(posedge clk);
      pop = 1;
    end
    @(posedge clk);
    pop = 0;

    // 检查 empty 信号
    if (!empty) $error("FIFO should be empty!");

    // 测试3：同时读写
    $display("[Test 3] Simultaneous push/pop");
    // ...

    $display("[Test] All tests passed!");
    $finish;
  end

  // 5. 波形记录
  initial begin
    $fsdbDumpfile("waves/fifo_test.fsdb");
    $fsdbDumpvars(0, fifo_tb);
  end
endmodule
```

#### 测试要点

**每个模块测试应该包含**:
1. **正常功能** - 验证基本读写、状态转换
2. **边界条件** - 满、空、最大值、最小值
3. **异常情况** - 错误输入、超时、X/Z 值
4. **时序检查** - valid/ready 握手、脉冲宽度

**波形观察重点**:
- 状态机：每个状态停留时间、转换条件
- 握手信号：valid 和 ready 的时序关系
- 计数器：是否正确递增/递减
- 数据通路：数据是否正确传递

#### 学习建议

**边学边测的流程**:
```
读代码 → 理解功能 → 写测试 → 跑仿真 → 看波形 → 理解透彻
  ↑                                                      ↓
  └───────────────── 发现问题，回到代码 ─────────────────┘
```

**重要提醒**:
1. **保留 smoke test** - 模块测试通过后，还是要跑整体测试
2. **写测试文档** - 每个模块测试什么、结果如何，记录下来
3. **边界条件优先** - 不只测正常情况，要测边界（0、最大值、X/Z等）
4. **波形对比** - 和预期行为对比，理解每个信号的含义

通过这样系统化的模块级测试，你对整个系统的理解会比只跑 smoke test 深刻 10 倍！

---

## 第四部分：知识检验清单

### 基础层（必须全部掌握）

- [ ] 能画出 SoC 整体框图（不看代码）
- [ ] 能说出地址 0x4000_001C 对应什么寄存器
- [ ] 能解释 valid/ready 握手协议
- [ ] 能说出 DMA 状态机的 5 个状态
- [ ] 能画出 cim_array_ctrl 状态转移图
- [ ] 能解释 pulse 和 level 的区别
- [ ] 能独立运行仿真并查看波形

### 进阶层（应该掌握）

- [ ] 能解释 bus_interconnect 为什么打一拍
- [ ] 能解释 OUT_FIFO pop 为什么延迟一拍
- [ ] 能计算一次完整推理需要多少时钟周期
- [ ] 能修改 TB 参数观察不同结果
- [ ] 能定位简单的时序 bug
- [ ] 能解释 LIF 膜电位的位宽为什么是 32 位

### 高级层（加分项）

- [ ] 能独立添加新的寄存器
- [ ] 能修改 FSM 添加新状态
- [ ] 能写简单的 assertion 检查
- [ ] 理解为什么用非阻塞赋值
- [ ] 能解释片外/片上数模混合集成的注意事项

---

## 第五部分：常见问题 FAQ

### Q1: 看不懂 SystemVerilog 语法怎么办？
```
推荐资源:
- 《SystemVerilog for Verification》第1-3章
- CSDN/知乎搜索 "SystemVerilog always_ff always_comb"
- 夏宇闻《Verilog 数字系统设计教程》
```

### Q2: 仿真跑不起来怎么办？
```
检查清单:
1. VCS 和 Verdi 环境变量是否设置（VERDI_HOME）
2. sim.f 文件路径是否正确
3. vcs.log 中的第一个 Error 是什么
4. 确保在 Linux 环境下运行（Windows 需要 WSL 或服务器）
```

### Q3: 波形太多信号，不知道看哪个？
```
优先看:
1. clk, rst_n（确认时钟和复位正常）
2. 各模块的 state 信号
3. 关键握手信号（valid/ready/done_pulse）
4. 数据通路信号（fifo count, membrane 等）
5. bitplane_shift（观察 7→0 变化）
```

### Q4: 理解了代码但记不住怎么办？
```
方法:
1. 手画框图和时序图（别用工具，手画记忆深刻）
2. 尝试给别人讲解（费曼学习法）
3. 动手改代码观察效果
4. 写学习笔记，整理关键点
```

### Q5: 为什么用 bit-serial 架构？
```
减少 CIM Macro 的面积和连线：
- 并行送 8bit 需要 64×8=512 根线
- bit-serial 只需 64 根线，每 bit 逐位送入
- 代价是速度变慢 8 倍，但面积大幅减小
```

### Q6: bitplane_shift 为什么从 7 开始？
```
MSB-first 设计：
- bit7 是最高位，权重最大 (128)
- 先处理高位可以更早判断是否超过阈值
- 也便于实现早停优化（future work）
```

### Q7: CIM Macro 行为模型的输出有什么含义？
```
Scheme B 行为模型（20 通道：前 10 正列 + 后 10 负列）：
pop = popcount(wl_spike)  // 0-64
正列 (j<10): bl_data[j] = (pop * 2 + j) & 0xFF
负列 (j>=10): bl_data[j] = (pop/2 + (j-10)) & 0xFF

- popcount: 输入 64 位中 1 的个数
- 数字侧差分: diff[i] = raw[i] - raw[i+10] (i=0..9)
- 真实 CIM 会输出实际的 MAC 结果
```

### Q8: soft reset 和 hard reset 怎么选？
```
- soft reset: 膜电位减去阈值，保留超出部分
  → 更接近生物神经元
- hard reset: 膜电位直接清零
  → 更简单，推荐 MVP 阶段使用 (reset_mode=1)
```

### Q9: 片外/片上数模混合集成需要注意什么？
```
1. 保持 cim_macro_blackbox.sv 的端口定义不变
2. 与模拟团队确认时序约束（见 doc/08_cim_analog_interface.md）
3. 时钟频率目标 50MHz（保守裕量）
4. 关注建立/保持时间要求
```

---

## 第六部分：时间规划

### Part A 推荐学习时间表

| 天数 | 内容 | 时长 | 关键交付物 |
|------|------|------|------------|
| Day 1-2 | 阶段 A：鸟瞰全局 | 4-6h | 手画系统框图 |
| Day 3-4 | 阶段 B：总线和数据搬运 | 6-8h | 手画总线时序图、DMA 状态机图 |
| Day 5-7 | 阶段 C：SNN 核心流水线 | 8-10h | 手画 cim_array_ctrl 状态图、LIF 算法理解 |
| Day 8 | 阶段 D：寄存器和控制 | 3-4h | 整理寄存器操作序列 |
| Day 9 | 阶段 E：Testbench | 2-3h | 理解 TB 流程 |
| Day 10-12 | 仿真实验 1-4 | 6-8h | 波形截图、参数修改实验记录 |
| Day 13-18 | 模块级仿真（推荐）| 12-16h | 各模块测试用例、波形分析 |
| Day 19-20 | 复习 + 知识检验 | 4h | 完成检验清单 |

**Part A 总计约 3 周**，每天投入 3-4 小时（包含模块级仿真）。
**如果跳过模块级仿真，约 2 周**。

---

# Part B: V1 进阶学习

完成 Part A 后，你已经掌握了 MVP。接下来学习 V1 版本需要的新知识。

**前置条件**: Part A 检验清单全部通过

---

## 阶段 9：UART 外设设计（Day 15-17）

**目标**: 理解 UART 协议原理，能设计实现完整的 UART 控制器

### 9.1 UART 协议基础

**数据帧格式（8N1）**:
```
空闲─┬─起始位─┬─D0─D1─D2─D3─D4─D5─D6─D7─┬─停止位─┬─空闲
     │   0   │        数据位          │   1   │
```

**关键公式**:
```
分频系数 = 时钟频率 / 波特率
例如：50MHz / 115200 = 434
```

### 9.2 UART TX 设计

**状态机**:
```
ST_IDLE ──tx_valid──> ST_START ──> ST_DATA(×8) ──> ST_STOP ──> ST_IDLE
```

**关键信号**:
- `tx_data[7:0]`: 待发送数据
- `tx_valid`: 发送请求
- `tx_ready`: 发送器空闲
- `uart_tx`: 串行输出

### 9.3 UART RX 设计

**关键设计点**:
- 起始位检测（下降沿）
- 采样点在位中心（半位时间延迟）
- RX FIFO 缓冲

### 检验标准

- [ ] 115200 波特率在 50MHz 时钟下的分频系数是多少？
- [ ] 为什么 RX 要在位中心采样？
- [ ] UART TX 发送一个字节需要多少个波特周期？

---

## 阶段 10：SPI 外设设计（Day 18-20）

**目标**: 理解 SPI 协议原理，能设计实现 SPI Master 控制器

### 10.1 SPI 四线接口

| 信号 | 方向 | 含义 |
|------|------|------|
| SCLK | Master→Slave | 时钟 |
| MOSI | Master→Slave | 主发从收 |
| MISO | Slave→Master | 从发主收 |
| CS | Master→Slave | 片选（低有效） |

### 10.2 SPI 模式

| 模式 | CPOL | CPHA | 常用场景 |
|:---:|:---:|:---:|:---|
| 0 | 0 | 0 | **Flash 常用** |
| 3 | 1 | 1 | **Flash 常用** |

**建议**: 先实现 Mode 0

### 10.3 SPI Master 状态机

```
ST_IDLE ──> ST_CS_LOW ──> ST_TRANSFER(×8) ──> ST_CS_HIGH ──> ST_IDLE
```

### 检验标准

- [ ] SPI Mode 0 和 Mode 3 的区别是什么？
- [ ] 为什么 SPI 比 UART 快？
- [ ] 如何读取 Flash 的 JEDEC ID？

---

## 阶段 11：AXI-Lite 总线（Day 21-24）

**目标**: 理解 AXI-Lite 协议，能设计 AXI-Lite Master 和 Slave

### 11.1 五个通道

| 通道 | 方向 | 用途 |
|:---|:---|:---|
| AW | Master→Slave | Write Address |
| W | Master→Slave | Write Data |
| B | Slave→Master | Write Response |
| AR | Master→Slave | Read Address |
| R | Slave→Master | Read Data |

### 11.2 握手协议

```
valid 和 ready 同时为 1 时传输完成
valid 一旦拉高，在 ready 之前不能撤销
```

### 11.3 AXI to Simple Bridge

**为什么需要桥接**:
- E203 使用 AXI 接口
- 现有 slave 使用 simple 接口
- 桥接器转换协议，保持 slave 不变

### 检验标准

- [ ] AXI-Lite 有几个通道？各有什么作用？
- [ ] valid/ready 握手的规则是什么？
- [ ] 为什么选择 AXI-Lite 而不是完整 AXI4？

---

## 阶段 12：E203 RISC-V Core（Day 25-27）

**目标**: 了解 E203 的架构和接口，理解如何将 E203 集成到 SoC

### 12.1 E203 概述

| 特性 | 说明 |
|------|------|
| 架构 | 32 位 RISC-V |
| 指令集 | RV32IMAC |
| 流水线 | 2 级 |
| 开源协议 | Apache 2.0 |

### 12.2 E203 集成架构

```
E203 Core
    ↓ (ICB)
ICB-to-AXI Bridge
    ↓ (AXI-Lite)
AXI Interconnect
    ↓
各个 Slave（SRAM、寄存器、外设）
```

### 12.3 启动流程

```
1. 上电复位
2. E203 从 0x0 取第一条指令
3. 执行 bootloader（初始化堆栈、BSS）
4. 跳转到 main()
5. main() 控制 SNN 推理
```

### 推荐资源

- E203 官方文档：https://github.com/SI-RISCV/e200_opensource
- 《手把手教你设计 CPU——RISC-V 处理器篇》

### 检验标准

- [ ] E203 支持哪些 RISC-V 指令集扩展？
- [ ] ICB 总线和 AXI 总线的区别是什么？
- [ ] E203 复位后从哪个地址开始执行？

---

## 阶段 13：嵌入式固件开发（Day 28-29）

**目标**: 了解 RISC-V 嵌入式开发流程，能编写简单的驱动和应用程序

### 13.1 开发环境

```bash
# 安装 RISC-V 工具链
sudo apt install gcc-riscv64-unknown-elf
```

### 13.2 寄存器访问

```c
#define REG32(addr) (*(volatile uint32_t *)(addr))

#define REG_BASE        0x40000000
#define REG_THRESHOLD   (REG_BASE + 0x00)
#define REG_TIMESTEPS   (REG_BASE + 0x04)
#define REG_CIM_CTRL    (REG_BASE + 0x14)
#define REG_STATUS      (REG_BASE + 0x18)
```

### 13.3 SNN 驱动示例

```c
void snn_init(uint32_t threshold, uint32_t timesteps) {
    REG32(REG_THRESHOLD) = threshold;
    REG32(REG_TIMESTEPS) = timesteps;
}

void snn_start(void) {
    REG32(REG_CIM_CTRL) = 1;  // START bit
}

int snn_wait_done(void) {
    while (!(REG32(REG_CIM_CTRL) & 0x80)) {
        // 等待 DONE bit (bit7)
    }
    return 0;
}
```

### 检验标准

- [ ] startup.S 的作用是什么？
- [ ] 如何通过 C 代码访问硬件寄存器？
- [ ] 为什么要用 volatile 关键字？

---

## Part B 时间规划

| 天数 | 内容 | 时长 |
|------|------|------|
| Day 15-17 | UART 设计 | 6-8h |
| Day 18-20 | SPI 设计 | 6-8h |
| Day 21-24 | AXI-Lite 总线 | 8-10h |
| Day 25-27 | E203 集成 | 6-8h |
| Day 28-29 | 固件开发 | 4-6h |

**Part B 总计约 2 周**，每天投入 3-4 小时。

---

## 学习资源汇总

### MVP 基础
- 项目文档：`doc/00_overview.md` ~ `doc/05_debug_guide.md`
- 接口文档：`doc/08_cim_analog_interface.md`（片外/片上数模混合集成用）
- 参考书：《Verilog HDL 高级数字设计》

### V1 进阶
- UART/SPI：搜索 "FPGA UART/SPI 设计"
- AXI：ARM AMBA AXI4-Lite 官方规范
- E203：https://github.com/SI-RISCV/e200_opensource
- RISC-V：《手把手教你设计 CPU——RISC-V 处理器篇》

### 工具
- VCS/Verdi：Synopsys 官方文档
- Design Compiler：综合工具
- OpenOCD/GDB：调试工具

---

*最后更新：2026-01-30*

**学习建议**：Part A 必须完全掌握后再开始 Part B。每个阶段学完后，尝试写一段代码或画一个图来验证理解。遇到问题及时记录，积极讨论。
