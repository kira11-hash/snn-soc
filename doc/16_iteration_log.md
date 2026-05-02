# 16_iteration_log

本文档记录每次迭代的变更摘要、验证结果与后续计划，按时间倒序追加。

---

## Iteration 12 — 2026-05-02 ARM ZCU102 LeNet-5 联调复盘（时序口径 + preload 根因）

### 背景

- 本节记录 `feature/v2-arm-fpga-demo-conv` 分支上，把原先“ARM PS 经 AXI-Lite 驱动 V2.B、只跑 bypass / scheduler”的板级链路，扩到“真 `conv1 -> conv2 -> fc1 -> fc2 -> fc3`”过程中踩到的几类坑。
- 之所以把这段经验写回主线日志，是因为这次暴露出来的两个核心问题都不是 LeNet-5 独有问题，而是以后很容易重演的**系统级错误**：
  - 一个是 **PS-PL 时钟口径和项目 baseline 不一致**
  - 另一个是 **firmware preload 写地址语义和 RTL auto-inc 时序语义不一致**
- 后者尤其值得反复提醒：当时功能长时间不对，很容易先怀疑卷积算法、权重映射、ARM cache、AXI 读写或者 stage 调度；但最后锁到的根因，其实是 **`conv fmap preload` 地址递增时机错了**，导致 feature map 没被写到 firmware 以为的地址上。

### 现象时间线（按当时真实排障顺序）

- **第一阶段：先解决“板子能不能稳定跑起来”**
  - ARM-hosted V2.B 这条线最开始的重点不是卷积，而是先把 `PS -> AXI-Lite -> wrapper -> v2b_top` 整条控制链在板上拉通。
  - 这个阶段最先暴露出来的是**时钟口径不统一**：脚本里有一部分默认按 `100 MHz` 写，项目整体却长期以 `50 MHz` 为 baseline。
  - 表面上看，100 MHz 也许“还能过综合/实现”，但它会让后面所有关于 pulse width、延迟预算、板级 smoke 速度、以及“为什么某个等待 guard 太短/太长”的判断都失去统一尺子。

- **第二阶段：把 ARM bring-up 做到“出问题时能说人话”**
  - 一旦从纯仿真进入 ZCU102 板级联调，最怕的不是结果错，而是“直接没输出、卡死、没法判断停在哪”。
  - 所以当时先补的是 `psu_init.tcl` 依赖、`xsct` 脚本失败即停、MMIO self-test、stage poll timeout、progress code 这类设施。
  - 这些设施本身不产生功能正确性，但它们决定了后面排障是“有抓手地缩小范围”，还是“无声瞎猜”。

- **第三阶段：native conv1 打开后，现象是“不是完全不通，而是结果稳定地不对”**
  - 这类 bug 最麻烦，因为它说明主链路不是全坏的：AXI 还能通，寄存器还能读写，stage 还能启动，后半段也能跑出东西。
  - 也正因为不是“完全不通”，当时很容易把注意力放到更复杂的地方，比如：
    - `conv1` 参数是不是配错了
    - 权重 tile / 稀疏加载是不是错了
    - ARM cache / barrier 有没有把 MMIO preload 搞乱
    - scheduler 在 conv/fc 混合路径上是不是有状态残留
  - 但这类方向都很重，一头扎进去会拖很久。

- **第四阶段：用 workaround 故意绕开 conv1，把问题切成前后两半**
  - 一旦改成“sample index -> 直接 preload 参考 conv1 输出”，板上后半段链路能恢复到 PASS，这件事非常关键。
  - 它相当于给出一个强结论：
    - `conv2 -> fc3` 主体大概率没坏
    - ARM MMIO / AXI-Lite / wrapper / scheduler 主骨架大概率没坏
    - 问题大概率集中在“原始输入 feature map 如何进入 conv 路径”这件事上
  - 这一步让排障从“全系统怀疑”变成“重点审 preload 路径”。

- **第五阶段：最终锁到 preload 地址合同，再做 RTL + firmware 成对修复**
  - 真正的根因不是算法参数，而是 `CONV_FMAP_WR_*` 这组寄存器接口的地址推进合同没有被软件和 RTL 以同一种方式理解。
  - 一边以为是“本次写当前地址、然后地址加一”，另一边实际表现更接近“提交脉冲和地址递增耦合得太早”，最终把 preload 写偏。
  - 这也是为什么当时会出现一种很迷惑的感受：很多东西看起来都像对的，但最终结果就是老不对。

### 关键提交链（按时间）

- `7e6f24ef` — `fixup: PL fabric clock 100 MHz → 50 MHz to match project baseline`
- `24951bb3` — `gpt-fix: harden ARM board bring-up review findings`
- `dea06766` — `Add ARM ZCU102 LeNet-5 bring-up flow`
- `5beca16b` — `Work around conv1 path for ARM board pass`
- `3719c3e7` — `Checkpoint before native conv1 root-cause fix`
- `48958da0` — `Fix conv fmap preload address increment`

### 最终根因一句话版

- **不是卷积计算本身先错，而是 `conv fmap preload` 这条“软件写地址 + RTL auto-inc”接口合同没对齐，导致 feature map 实际落点和软件预期落点发生偏移。**

### 为什么当时会卡很久

- **因为它不像“完全死机”那样直接暴露层级**
  - 如果是 `psu_init.tcl` 丢了、AXI base address 错了、PL reset 没放开，往往会直接无输出或超时，定位反而比较快。
  - 这次不是。系统能跑、寄存器能读、后级能工作、甚至换一种输入喂法还能 PASS，所以它会伪装成“算法细节错误”。

- **因为 workaround 会让人误以为 conv 核心一定没问题**
  - 实际上 workaround 证明的是“后半段可以独立成立”，不等于“前半段 native 路径没风险”。
  - 如果忘了这点，就可能把“绕过去能跑通”错误理解成“native preload 语义肯定也没问题”。

- **因为 auto-inc 类接口天然有一层时序错觉**
  - 软件工程师脑中常见的模型是：
    1. 先把 `ADDR` 写成 `i`
    2. 把 `DATA` 写进去
    3. `COMMIT`
    4. 硬件“事后”把地址加一
  - 但 RTL 真正怎么实现，要看寄存器在哪拍更新、下游 SRAM 在哪拍采样、`COMMIT` 和 `ADDR` 是否共用一个时序块。
  - 只要这三件事里有一件和软件脑中的顺序不一致，就会出现“看起来只差一拍，结果整个 preload 地址都漂了”的问题。

### 这次我实际做的几类改动

- **先把 PL 时钟口径从 100 MHz 拉回 50 MHz，避免一开始就在错误 baseline 上看时序**
  - 改动文件集中在 `fpga_synth/zcu102_arm_demo.tcl`、`fpga_synth/bd_sanity_zcu102_arm_demo.tcl`、`fpga_synth/ooc_v2b_arm_demo.tcl`、`rtl/top/v2b_axi_wrapper_bd.v` 和分支内 `doc/arm-fpga-demo/00_architecture.md`。
  - 具体动作是把 `pl_clk0` 从 `100 MHz` 改回项目统一口径 `50 MHz`，并把 OOC pseudo-constraint 从 `10 ns` 改成 `20 ns`，输入/输出 delay 也跟着按 50 MHz 重算。
  - 这样做不是“保守一点而已”，而是为了和项目里所有依赖 `50 MHz` 标尺的东西保持一致，包括 `cim_program_ctrl` 里按 50 MHz 标定的脉宽、已有 synth 脚本、学习路径和 bring-up 文档的默认口径。
  - 这一步做完后，OOC 时序余量从“虽然能过、但口径不对”变成“和项目真实目标一致的 PASS”，也避免后续把功能问题误判成纯 timing 问题。

- **把 ARM first-light / board bring-up 基建补结实，避免板上直接无声卡死**
  - `fw/arm/src/crt0_aarch64.S` 的注释和假设被改正为：当前 `xsct` 直灌 ELF 路线依赖 `psu_init.tcl` 完成 DDR、PS、PL isolation / reset 初始化，`crt0` 本身并不负责 MMU / cache / BSP 初始化。
  - `scripts/program_zcu102_c0.tcl` / `scripts/program_zcu102_c1.tcl` 被改成：找不到 `psu_init.tcl` 直接 `FATAL` 退出，而不是继续往下跑，防止“DDR 根本没 init 却还 download ELF”这种假成功。
  - `fw/src/v2b_scheduler.c` 增加 stage poll timeout，板上如果时钟、复位、地址映射或响应链路有问题，会返回 firmware-visible error，而不是一直 spin。
  - `fw/arm/src/arm_main.c` 的 MMIO self-test 也从“读写保留寄存器”修成“读写真实 CFG1 threshold 寄存器”，避免自测本身不严谨。
  - 这些改动的价值不是提高性能，而是把“哪里没通”尽快暴露出来，缩短 ARM 板级联调时的盲调时间。

- **在根因没锁死前，先做一个只绕过 `conv1` 的临时 workaround，把问题范围迅速缩小**
  - `5beca16b` 这步没有直接硬猜 root cause，而是先加了 `conv1_ref_all_samples.h`、`sample0_conv1_ref_sparse.h`、`sample0_conv2_ref_sparse.h` 等参考数据，把 `fw/src/v2b_conv_scheduler.c` 暂时改成：不走 live `conv1` 输入展开，而是按 sample index 直接 preload 参考 `conv1` 输出。
  - `fw/arm/src/arm_main.c` 里新增 `g_arm_current_sample_idx`，就是为了让 scheduler 知道当前在跑第几个 sample，从而选对那份参考 feature map。
  - 这个 workaround 的意义非常大：如果绕过 `conv1` 后 `conv2 -> fc3` 整条链能在板上 PASS，那就说明 AXI-Lite 主通路、ARM MMIO、后半段 scheduler、输出计数、golden compare 都大概率是好的，问题应当收缩到“原始输入 feature map 如何 preload 到 conv 路径”这件事上。
  - 也就是说，它不是最终方案，而是一个**定位用的隔离实验**，专门用来证明 bug 在 `conv1` 之前，而不在整个 ARM host 架构本身。

- **最后的正式修复不是“卷积参数调一下”，而是修 `conv fmap preload` 的地址语义**
  - 真正回收 workaround、恢复原生 `conv1` 路径的是 `48958da0`。这次修复同时动了 firmware 和 RTL，两边缺一不可。
  - firmware 侧：`fw/src/v2b_conv_scheduler.c`
  - 原来 `v2b_load_input_fmap_words()` 是按 dense 流程从 `0..word_count-1` 连续写，并假设 `A_CONV_FMAP_WR_CTRL` 的 `AUTO_INC + COMMIT` 会让下一笔数据自然落到下一个地址。
  - 修后改成“先 clear 目标 bank，再跳过连续 0，只对非零段写入；每遇到一段新的非零 run，先显式把 `V2B_SOC_CONV_FMAP_WR_ADDR` 设成源数据的绝对地址 `i`，再连续提交这一段 non-zero words”。
  - 这么改有两个目的：第一，减少 ARM 侧无意义 MMIO 写流量；第二，更重要的是把“当前写入的绝对地址”暴露得更明确，方便确认 preload 究竟写到了哪。
  - RTL 侧：`rtl/top/snn_soc_v2b_top.sv`
  - 新增 `reg_conv_fmap_wr_inc_pending`，把原先“`COMMIT` 当拍就直接 `addr <= addr + 1`”改成“`COMMIT` 当拍只记一个 pending，下一拍再真正做地址加一”。
  - 这是本次 root cause 的关键。原先 firmware 以为自己是在“先按当前地址写，再自增到下一地址”；但 RTL 的实现等价于“这笔提交触发后，下一次真正被消费的写地址已经提前变成了加一后的值”。结果就是 preload 内容整体发生地址漂移，后面 `conv1` 读到的 feature map 和 Python / firmware 以为自己写进去的根本不是一回事。
  - 所以当时“功能一直不对”的真正解释，不是 `conv1` 算法错了，不是权重 tile 错了，也不是 ARM cache 把数据吃掉了，而是 **preload 的写地址合同没对齐**。
  - 同一个提交里还把前面 workaround 用到的 sample-index 全局变量、参考 header 和 bypass 路径删掉，恢复成真正走 `input_words -> conv1 -> conv2 -> fc` 的正式实现。这一点也很重要，因为 workaround 如果不及时回收，后面很容易把临时路径误当成正式架构。

### preload 接口到底哪里容易错（把合同写死）

- firmware 预期的理想合同是：
  1. 先写 `V2B_SOC_CONV_FMAP_WR_ADDR = i`
  2. 再写 `V2B_SOC_CONV_FMAP_WR_CTRL = AUTO_INC | bank_sel`
  3. 再写 `V2B_SOC_CONV_FMAP_WR_DATA = words[i]`
  4. 最后写 `V2B_SOC_CONV_FMAP_WR_CTRL = AUTO_INC | bank_sel | COMMIT`
  5. 本次 `COMMIT` 应该把 `DATA` 落到“当前地址 i”
  6. 只有本次写已经被消费之后，内部地址才前进到 `i+1`

- 这次 bug 的本质，就是第 `5` / `6` 条在实现里没有和软件脑内模型完全重合。

- 以后凡是看到这种寄存器组合，都要把下面三件事单独问清楚：
  - **地址寄存器在哪一拍更新**
  - **写入有效脉冲在哪一拍产生**
  - **真正落 SRAM 的地址是更新前的，还是更新后的**

- 如果这三件事没有被文档写死，就不要默认“肯定和普通软件循环想的一样”。

### 这次 workaround 和正式修复的角色区别

- `5beca16b` 的角色是：**缩小问题范围**
  - 它回答的问题是：“后半段链路是不是本来就坏了？”
  - 它不是最终架构，也不该长期保留。

- `48958da0` 的角色是：**恢复正式语义**
  - 它回答的问题是：“native 输入路径怎样才能按正式合同工作？”
  - 它必须把 workaround 删掉，否则项目里会同时存在“临时旁路正确”和“正式路径语义不清”两种状态，未来更危险。

### 如果下次再遇到类似现象，推荐的最短排障路径

- 第一步：先问是不是**口径问题**
  - `pl_clk0` 是不是还是 `50 MHz`
  - OOC / BD / doc / firmware 注释是不是在说同一个频率
  - timeout / pulse width / delay 预算是不是还沿用旧值

- 第二步：再问是不是**链路死了**
  - `psu_init.tcl` 有没有真正 source
  - MMIO self-test 能不能过
  - stage poll 是不是直接超时
  - progress code 能不能推进到预期段落

- 第三步：如果链路没死但结果不对，优先做**前后半段切割**
  - native 输入错不等于后半段错
  - 先喂参考 `conv1` / `conv2` feature map，把问题分割成 preload 之前和 preload 之后两段

- 第四步：一旦怀疑 preload，直接检查**地址合同**
  - 不要先看最终分类
  - 先看 `ADDR / CTRL / DATA / COMMIT`
  - 再看 RTL 内部 auto-inc 是“同拍改地址”还是“下一拍改地址”
  - 最后才去怀疑卷积参数、稀疏权重或算法映射

### 这次排障最值得记住的结论

- **ARM 板级联调先看口径，再看算法**。只要分支上出现了和主线不一样的 PL 时钟、约束周期、脉宽假设，就先把这些统一；否则 timing 报告和功能现象都会失真。
- **遇到“前半段开真数据就错，后半段喂参考数据却对”的情况，第一怀疑对象应该是 preload / address generation，而不是后级计算本身。**
- **凡是带 `COMMIT/W1P/AUTO_INC` 的 MMIO 预加载接口，都要明确“地址在哪一拍生效、在哪一拍自增、SRAM 在哪一拍真正采样”**。这个合同如果没写清楚，软件和 RTL 很容易各自“觉得自己是对的”，最后系统整体却错。
- **临时 workaround 要故意做成“隔离实验”，然后在 root-cause fix 落地后及时删掉。** 这次 `5beca16b` 有价值，但如果 `48958da0` 后不回收，就会把 future debug 带偏。

### 以后再碰 ARM 路线，建议优先检查的顺序

- 先确认 `pl_clk0`、OOC constraint、文档口径是不是都还是 `50 MHz`，不要默认沿用旧脚本。
- 如果板上“能读写寄存器，但真跑 scheduler 结果不对”，先做最小隔离：绕过 `conv1` 或只喂后级参考 feature map，看问题是在 preload 之前还是之后。
- 一旦怀疑 preload，不要只看最终分类结果，直接看 `CONV_FMAP_WR_ADDR / CTRL / DATA` 的写入序列，以及 RTL 内部 auto-inc 是否比 SRAM consume 早一拍。
- 对 ARM firmware 里的“为了调试先加的 sample-index / 参考 header / bypass path”保持警惕，板子跑通之后要尽快删回正式路径。

---

## Iteration 9 — 2026-03-31 main 分支再审计与 WL wrapper 边界修正

### 本次复核范围

- 重新执行当前 `doc/09_smoke_test_checklist.md` 主线回归矩阵，包括：
  `JTAG_PYHOST_SELFTEST_PASS`、UART/SPI/DMA/AXI-Lite bridge、light smoke、weighted smoke、
  `sample_align 100/100`、ADC saturation、JTAG loader、JTAG rescue top、E203 smoke、
  `chip_top` Icarus 编译门禁、`chip_top` Verilator lint、旧 `top_tb` 入口、
  shell/python 语法门禁
- 复查 `rtl/top/chip_top.sv`、`rtl/top/snn_soc_top.sv`、`rtl/snn/wl_mux_wrapper.sv`
  的 TO 路径与 WL 协议边界语义
- 检查 `doc/06_learning_path.md` 当前阅读顺序口径是否仍与主线现状一致

### 代码修正

- `rtl/snn/wl_mux_wrapper.sv`
  - 修正 `wl_busy` 在 `ST_DONE` 拍提前拉低的问题，改为 **直到回到 `ST_IDLE` 前都保持 busy=1**
  - 修正后，`dbg_wl_stall_cnt` 不会漏记“新 `wl_valid_pulse_in` 恰好撞在 `ST_DONE` 拍”的协议违规输入
  - 此修改不改变主功能时序，不影响 `wl_latch` / `wl_valid_pulse_out` 语义，只补齐 wrapper 边界可观测性

### 文档修订

- `doc/09_smoke_test_checklist.md`
  - 补充 `u_wl_mux_wrapper.wl_busy` 的波形观察口径，明确其在 `SEND` 和 `DONE` 期间都应保持为 1
- `doc/16_iteration_log.md`
  - 追加本轮复核与修正记录，保持正式日志与当前主线一致

### 结果摘要

```text
JTAG_PYHOST_SELFTEST_PASS
UART_SMOKETEST_PASS
SPI_SMOKETEST_PASS
DMA_SMOKETEST_PASS
AXI_BRIDGE_SMOKETEST_PASS
LIGHT_SMOKETEST_PASS
WEIGHTED_SIM_PASS
SAMPLE_ALIGN_PASS (100/100)
ADC_SAT_COUNTER_PASS
JTAG_MEM_LOADER_PASS
JTAG_RESCUE_TOP_PASS
E203_SMOKETEST_PASS
chip_top Icarus compile gate 通过
chip_top Verilator lint 通过
legacy top_tb 入口通过
shell / python 语法门禁通过
```

### 学习路径口径复核

- `doc/06_learning_path.md` 当前结论仍成立：
  - 想“反向吃透当前项目现状”，**不要**只按 06 从头顺排到尾
  - 更高效的顺序仍是先看 `09/15/08/11/07` 收口现状，再回到 06 作为代码解剖路线图

---

## Iteration 8 — main 分支全量复核刷新（2026-03-24）

### 本次复核范围

- 重新执行 `doc/09_smoke_test_checklist.md` 中登记的主线验证矩阵
- 复跑 `sample_align 100/100`、JTAG rescue、E203 启动链、`chip_top` 编译/lint 和旧 `top_tb` 入口
- 复查正式文档中的仓库内文件链接，修正 Windows 本地绝对路径引用

### 结果摘要

```text
JTAG_PYHOST_SELFTEST_PASS
UART_SMOKETEST_PASS
SPI_SMOKETEST_PASS
DMA_SMOKETEST_PASS
AXI_BRIDGE_SMOKETEST_PASS
LIGHT_SMOKETEST_PASS
WEIGHTED_SIM_PASS
SAMPLE_ALIGN_PASS (100/100)
ADC_SAT_COUNTER_PASS
JTAG_MEM_LOADER_PASS
JTAG_RESCUE_TOP_PASS
E203_SMOKETEST_PASS
chip_top Icarus compile gate 通过
chip_top Verilator lint 通过
legacy top_tb 入口通过
shell / python 语法门禁通过
```

### 文档修订

- 将 `doc/00_overview.md`、`doc/05_debug_guide.md`、`doc/08_cim_analog_interface.md`、`doc/11_analog_handoff_execution_plan.md`、`doc/15_asic_pad_map.md`、`SNNSoC工程主文档.md` 中的本地绝对路径链接改为仓库相对路径，避免 GitHub/跨机器阅读时跳转失效
- 将 `README.md` 与 `doc/09_smoke_test_checklist.md` 的全量复核日期刷新为 `2026-03-24`

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

## Iteration 2 — UART stub → uart_ctrl 集成（2026-03-18）

### 变更内容

将 `feature/uart-tx` 分支的 UART TX 控制器移植到 `main` 分支，替换 uart_stub。

**新增文件（4 个 RTL/TB/脚本）：**

| 文件 | 说明 |
|------|------|
| `rtl/periph/uart_ctrl.sv` | UART TX 控制器（8N1，4态FSM，baud_div可配置，RX V1占位） |
| `tb/uart_tb.sv` | T1~T8 独立烟雾测试（含 baud_div 读写、多字节发送解码、STATUS、忙时忽略、CTRL 锁存） |
| `sim/sim_uart.f` | Icarus 编译文件列表 |
| `sim/run_uart_icarus.sh` | Icarus 运行脚本，通过标准 `UART_SMOKETEST_PASS` |

**修改文件（6 处）：**

| 文件 | 变更 |
|------|------|
| `rtl/top/snn_soc_top.sv` | `uart_stub u_uart` → `uart_ctrl u_uart`（端口完全兼容，仅改实例模块名） |
| `sim/sim_icarus_light.f` | `uart_stub.sv` → `uart_ctrl.sv` |
| `sim/sim_icarus_weighted.f` | `uart_stub.sv` → `uart_ctrl.sv` |
| `sim/sim.f` | `uart_stub.sv` → `uart_ctrl.sv`，保证默认 top_tb filelist 可编译 |
| `sim/sim_sample_align.f` | `uart_stub.sv` → `uart_ctrl.sv`，保证 sample-align 回归可编译 |
| `sim/sim_adc_sat_counter.f` / `sim/rtl_with_chip_top_check.f` | `uart_stub.sv` → `uart_ctrl.sv`，保证 ADC 饱和回归与 chip_top lint 可编译 |

### 功能说明

| 特性 | 实现状态 |
|------|---------|
| TX：8N1 帧格式（1起始+8数据+1停止） | ✅ 4态FSM（IDLE/START/DATA/STOP） |
| 波特率配置（CTRL.baud_div，默认434=115200@50MHz） | ✅ 帧间热更新，发送中改配下帧生效 |
| baud_div=0 防御（钳位到1，防止倒计数异常） | ✅ |
| 忙时写 TXDATA 忽略（tx_busy=1 时不加载新字节） | ✅ |
| STATUS[0]=tx_busy 可读 | ✅ |
| TXDATA 影子寄存器可读回 | ✅ |
| RX 路径 | V1 占位（读回0），V2 实现 |

### 验证结果

```
UART独立TB:   T1~T8 全部 PASS（12/12）  → UART_SMOKETEST_PASS
黑盒smoke回归: OUT_FIFO_COUNT=100       → LIGHT_SMOKETEST_PASS（无回归）
带权重回归:   OUT_FIFO_COUNT=55         → WEIGHTED_SIM_PASS（无回归）
```

---

## Iteration 3 — SPI stub → spi_ctrl 集成（2026-03-18）

### 变更内容

将 `feature/spi` 分支的 SPI Master 控制器移植到 `main` 分支，替换 spi_stub。

**新增文件（5 个 RTL/TB/脚本）：**

| 文件 | 说明 |
|------|------|
| `rtl/periph/spi_ctrl.sv` | SPI Master 控制器（Mode 0，8-bit 全双工，3态FSM，软件控 CS，baud_div 7级） |
| `tb/spi_flash_model.sv` | SPI Flash 行为模型（支持 RDID/READ 命令，64KB 窗口） |
| `tb/spi_tb.sv` | T1~T3 + T1b 烟雾测试（CTRL读写、clamp、RDID、READ 4字节、rx_valid清零） |
| `sim/sim_spi.f` | Icarus 编译文件列表 |
| `sim/run_spi_icarus.sh` | Icarus 运行脚本，通过标准 `SPI_SMOKETEST_PASS` |

**修改文件（5 处）：**

| 文件 | 变更 |
|------|------|
| `rtl/top/snn_soc_top.sv` | `spi_stub u_spi` → `spi_ctrl u_spi`（端口完全兼容，仅改实例模块名） |
| `sim/sim_icarus_light.f` | `spi_stub.sv` → `spi_ctrl.sv` |
| `sim/sim_icarus_weighted.f` | `spi_stub.sv` → `spi_ctrl.sv` |
| `sim/sim.f` / `sim/sim_sample_align.f` | `spi_stub.sv` → `spi_ctrl.sv`，补齐默认 top_tb 与 sample-align filelist |
| `sim/sim_adc_sat_counter.f` / `sim/rtl_with_chip_top_check.f` | `spi_stub.sv` → `spi_ctrl.sv`，补齐 ADC 饱和回归与 chip_top lint filelist |

### 功能说明

| 特性 | 实现状态 |
|------|---------|
| SPI Master，Mode 0（CPOL=0, CPHA=0） | ✅ 3态FSM（IDLE/SHIFT/DONE） |
| 8-bit 全双工（MOSI/MISO 同步收发） | ✅ |
| CS 软件控制（CTRL[8]=cs_force） | ✅ |
| baud_div 7级可配（÷2~÷256，CTRL[3:1]） | ✅ |
| clk_div=0+spi_en=1 安全钳位→clk_div=2 | ✅（防止 25MHz SCK 损坏 Flash） |
| rx_valid 读 RXDATA 后自动清零 | ✅ |
| TX/RX 1-deep shadow buffer | ✅ |
| Mode 3 | V1 仅 Mode 0，V2 扩展 |

### 验证结果

```
SPI独立TB:    T1~T3+T1b 全部 PASS（9/9）  → SPI_SMOKETEST_PASS
黑盒smoke回归: OUT_FIFO_COUNT=100          → LIGHT_SMOKETEST_PASS（无回归）
带权重回归:   OUT_FIFO_COUNT=55            → WEIGHTED_SIM_PASS（无回归）
sample-align: 100/100 samples matched       → SAMPLE_ALIGN_PASS
ADC饱和回归:   pass                         → ADC_SAT_COUNTER_PASS
chip_top lint: pass                         → verilator lint clean
```

---

## Iteration 4 — DMA 引擎多目标扩展（2026-03-18）

### 变更内容

扩展 `dma_engine.sv`，新增 `REG_DST_SEL` 寄存器支持多目标路由；同步新增 `sram_simple.sv` DMA 写端口，更新 `snn_soc_top.sv` 连线。

**修改文件（3 个 RTL）：**

| 文件 | 变更 |
|------|------|
| `rtl/dma/dma_engine.sv` | 新增 `REG_DST_SEL`（offset 0x0C，2-bit）、`ST_WR` 状态、`weight_wr_*` / `instr_wr_*` 输出端口；奇数长度约束仅对 `DST_INPUT_FIFO` 生效；busy 期间忽略 `DST_SEL` 改写，`2'b11` 非法值直接报错 |
| `rtl/mem/sram_simple.sv` | 新增 `dma_wr_en/addr/data/strb` DMA 写端口（Port B），供 `instr_sram` / `weight_sram` 接收 DMA 写 |
| `rtl/top/snn_soc_top.sv` | 连接 `dma_engine` 的新端口到 `u_weight_sram` 和 `u_instr_sram` 的 DMA 写端口 |

**新增文件（3 个 TB/脚本）：**

| 文件 | 说明 |
|------|------|
| `tb/dma_tb.sv` | T1~T10 独立烟雾测试（含三路目标、奇数长度、对齐错误、W1C、背压、busy 期间写保护、非法 DST_SEL） |
| `sim/sim_dma.f` | Icarus 编译文件列表 |
| `sim/run_dma_icarus.sh` | Icarus 运行脚本，通过标准 `DMA_SMOKETEST_PASS` |

### DST_SEL 功能说明

| `DST_SEL[1:0]` | 目标 | 行为 |
|----------------|------|------|
| `2'b00` (`DST_INPUT_FIFO`) | `input_fifo` | 每两个 word 拼成 64-bit push（原有行为，兼容） |
| `2'b01` (`DST_WEIGHT_BUF`) | `weight_sram` DMA 写端口 | 逐 word 写入，允许奇数长度 |
| `2'b10` (`DST_INSTR_SRAM`) | `instr_sram` DMA 写端口 | 逐 word 写入，允许奇数长度 |

源地址始终来自 `data_sram`（`addr_ptr = src - ADDR_DATA_BASE`）；目标偏移与源偏移相同，保持相对位置一致。SPI→SRAM 通路：固件通过 SPI 读数据写入 `data_sram`，再由 DMA 以 `DST_INSTR_SRAM` / `DST_WEIGHT_BUF` 搬运。

### FSM 扩展

```
DST_INPUT_FIFO：IDLE → SETUP → RD0 → RD1 → PUSH → (RD0 or IDLE)   [原有，兼容]
DST_WEIGHT/INSTR：IDLE → SETUP → RD0 → WR → (RD0 or IDLE)          [新增 ST_WR]
```

### 验证结果

```
DMA 独立 TB:  T1~T10 全部 PASS（39/39） → DMA_SMOKETEST_PASS
黑盒 smoke:  OUT_FIFO_COUNT=100         → LIGHT_SMOKETEST_PASS（无回归）
带权重回归:  OUT_FIFO_COUNT=55          → WEIGHTED_SIM_PASS（无回归）
```

---

## Iteration 5 — E203 最小面积接入（2026-03-18）

### 变更内容

将 E203 以“最小侵入、最小面积”的方式接入 `main`：

- 顶层不走 `ICB -> AXI -> simple bus` 双桥路径，而是直接新增 `ICB -> simple bus` 轻量桥，减少一层协议转换面积和时序负担。
- `snn_soc_top.sv` 新增 `ENABLE_E203` 参数，默认仍由 `bus_if` 驱动；只有在专用 E203 TB 中才切换到 CPU 主控，因此原有主线回归无需改测试用例。
- 新增 `e203_min_wrap.sv` 包装层，仅暴露 `mem_icb` 到 SoC fabric；PPI / CLINT / PLIC / FIO 一律接到错误应答从设备，避免为了 V1 bring-up 额外引入不必要外设。
- 裁剪 vendor `config.v`：关闭 `JTAG / ITCM / DTCM / NICE / ECC / AMO / share-muldiv`，保留 RV32I 主路径与 `mem_icb`。  
  说明：`MCYCLE/MINSTRET` 原本也尝试关闭，但 vendor `e203_exu_csr.v` 对这组信号有非对称 ifdef 依赖，直接关闭会导致编译失败，因此本轮保留这组 CSR，避免在 vendor RTL 内做高风险手术。

### 新增 / 修改文件

| 文件 | 变更 |
|------|------|
| `rtl/bus/icb2simple_bridge.sv` | 新增 E203 `mem_icb` 到 `bus_simple` 的轻量桥；单 outstanding；SRAM 区允许 byte/halfword 访问，MMIO 区强制 4B 对齐，非法访问返回 error |
| `rtl/bus/icb_err_slave.sv` | 新增 ICB 错误应答从设备，供 PPI / CLINT / PLIC / FIO 占位 |
| `rtl/top/e203_min_wrap.sv` | 新增 E203 最小包装层；内部 tie-off debug/interrupt/TCM 电源控制，并将未使用 ICB 口接到 `icb_err_slave` |
| `rtl/top/snn_soc_top.sv` | 新增 `ENABLE_E203` 参数，加入 E203 wrapper + `icb2simple_bridge`，并将 bus fabric 改成“外部 TB / E203 二选一” |
| `项目相关文件/未添加的IP的源代码/e203_hbirdv2-master/rtl/e203/core/config.v` | 裁剪 E203 配置，关闭不需要的大块功能，仅保留本轮用到的最小子集 |
| `fw/crt0.S` / `fw/main.c` / `fw/link.ld` | 新增 E203 最小 bare-metal C 固件工程 |
| `fw/build_e203_firmware.sh` / `fw/bin_to_readmemh.py` | 新增固件构建脚本与 binary→`$readmemh` 转换脚本，输出 `fw/out/firmware.hex` |
| `tb/e203_tb.sv` | 新增 E203 专用 Icarus 烟测 TB：预加载 `instr_sram`，预填 `data_sram` 输入模式，检查签名 / UART / `OUT_FIFO_COUNT` |
| `sim/sim_e203.f` | 新增 E203 专用 filelist，使用 `rtl/vendor_e203` 本地 ASCII 映射规避 Icarus 对 vendor 路径的读取问题 |
| `sim/run_e203_icarus.sh` | 新增 E203 专用运行脚本，PASS 标准为 `E203_SMOKETEST_PASS` |
| `sim/sim*.f` / `sim/rtl_with_chip_top_check.f` | 补齐 `icb2simple_bridge.sv`、`icb_err_slave.sv`、`e203_min_wrap.sv`，保证原有 top 相关回归仍可编译 |

### 固件 / 验证策略

本轮 E203 bring-up 已切换到真实 **C 固件 + WSL toolchain** 流程：

- 使用 WSL 内的 `riscv64-unknown-elf-gcc / objcopy`，编译 `fw/crt0.S + fw/main.c + fw/link.ld`
- 通过 `fw/build_e203_firmware.sh` 生成 `fw/out/firmware.elf / firmware.dump / firmware.hex`
- `sim/run_e203_icarus.sh` 会先自动构建固件，再跑 Icarus
- 当前固件只依赖 RV32I：写签名到 `data_sram`、配置 UART、启动 DMA、轮询 `DONE`、启动 SNN、读取 `OUT_FIFO_COUNT` 并写回 SRAM

### 验证结果

```
E203 专用 smoke: Signature/UART/SNN 全部通过      -> E203_SMOKETEST_PASS
黑盒 smoke 回归: OUT_FIFO_COUNT=100               -> LIGHT_SMOKETEST_PASS
带权重回归:     OUT_FIFO_COUNT=55                -> WEIGHTED_SIM_PASS
sample-align:   100/100 samples matched          -> SAMPLE_ALIGN_PASS
ADC 饱和回归:   pass                             -> ADC_SAT_COUNTER_PASS
chip_top lint:  pass                             -> verilator lint clean
```

---

## Iteration 6 — Bootloader / SPI 启动 + UART printf（2026-03-19）

### 变更内容

在已有 E203 最小接入的基础上，补齐了真实上电启动链：

- `bootloader` 预加载在 `instr_sram`，上电后先运行引导程序
- `bootloader` 通过 `spi_ctrl` 访问外部 SPI Flash 模型，读取应用镜像头和 payload
- `bootloader` 将 `app` 装载到 `data_sram @ 0x0001_0000`，执行 `fence.i` 后跳转
- `app` 运行后通过 `UART printf` 输出阶段日志，并继续完成 DMA + SNN 推理
- 同步收口 TO 路径上的两个关键问题：`chip_top` 现在默认显式启用 E203，并将外部 CIM 接口（`wl_data/group_sel/latch`、`cim_start/done`、`bl_sel/bl_data`）真正贯通到 `snn_soc_top`

### 新增 / 修改文件

| 文件 | 变更 |
|------|------|
| `fw/include/soc_regs.h` | 统一定义 E203 / DMA / UART / SPI / marker 地址和启动常量 |
| `fw/include/uart_printf.h` / `fw/uart_printf.c` | 新增最小 `uart_printf` 实现，支持 `%c / %s / %x / %u`，供 bootloader 和 app 共用 |
| `fw/boot_main.c` | 新增 bootloader：读 `RDID`、读取镜像头、SPI 逐字节搬运 app、写 boot marker、跳转到 app |
| `fw/main.c` | 切换为 app 固件：生成 DMA 输入、运行推理、用 UART 输出 `APP start` / `APP inference done count=...` |
| `fw/link.ld` | 调整为 bootloader 链接脚本，`DMEM` 仅保留高地址小窗口，避免与 app 装载区冲突 |
| `fw/app_link.ld` | 新增 app 链接脚本，app 代码运行在 `data_sram @ 0x0001_0000` |
| `fw/build_flash_image.py` | 新增 SPI Flash 镜像生成脚本：写入 boot header（magic/size/load/entry）+ app payload |
| `fw/build_e203_firmware.sh` | 扩展为同时生成 `bootloader.hex`、`app.elf/bin/dump`、`flash_image.hex` |
| `tb/spi_flash_model.sv` | 支持通过参数加载外部 `flash_image.hex`，默认行为仍兼容原 SPI 单测 |
| `tb/e203_tb.sv` | 切换到 bootloader/SPI 启动路径，实例化 flash model，检查 boot marker / app signature / result / done，并打印 UART 日志 |

### 启动流程

```
reset
  -> bootloader @ instr_sram
  -> UART: "BL start"
  -> SPI RDID
  -> SPI READ header + app payload
  -> app load to data_sram @ 0x0001_0000
  -> write boot marker
  -> jump to app
  -> UART: "APP start"
  -> DMA + SNN inference
  -> UART: "APP inference done count=100"
  -> write app signature / result / done marker
```

### 验证结果

```
bootloader / SPI 启动 / UART printf: 通过 -> E203_SMOKETEST_PASS
黑盒 smoke 回归: OUT_FIFO_COUNT=100  -> LIGHT_SMOKETEST_PASS
带权重回归:     OUT_FIFO_COUNT=55   -> WEIGHTED_SIM_PASS
sample-align:   100/100 matched      -> SAMPLE_ALIGN_PASS
SPI 单测回归:                        -> SPI_SMOKETEST_PASS
ADC 饱和计数器回归:                   -> ADC_SAT_COUNTER_PASS
chip_top Verilator lint:             -> 通过
```

---

## Iteration 7 — JTAG 救援通路（jtag_mem_loader）（2026-03-20）

### 变更内容

新增独立于 E203 debug module 的最小 JTAG 救援通路，满足 CPU/bootloader/SPI 启动失败时仍能直写 SRAM 并重启 CPU。

**新增文件（6 个 RTL/TB/脚本/工具）：**

| 文件 | 说明 |
|------|------|
| `rtl/periph/jtag_mem_loader.sv` | 自定义 4-wire JTAG TAP + MEMACC/CPUCTL 协议，含 TCK↔CLK CDC（req/rsp toggle + 2-FF sync），SRAM-only 地址过滤 |
| `tb/jtag_mem_loader_tb.sv` | 单元测试：TAP reset / IDCODE / MEMACC 读写三块 SRAM / 非法地址 err / outstanding 请求拒绝 |
| `tb/jtag_rescue_top_tb.sv` | 系统级测试：CPUCTL hold → JTAG 灌 instr_sram → release → CPU 启动 → UART 输出验证 |
| `sim/sim_jtag_loader.f` / `sim/run_jtag_loader_icarus.sh` | 单元测试 filelist 和运行脚本 |
| `sim/sim_jtag_rescue_top.f` / `sim/run_jtag_rescue_top_icarus.sh` | 系统测试 filelist 和运行脚本 |
| `scripts/jtag_rescue.py` / `scripts/test_jtag_rescue.py` | Python 主机侧工具（TAP 状态机、IDCODE、MEMACC 批量读写、CPUCTL hold/release、rescue-load 流程）及其自测脚本 |
| `fw/jtag_rescue_main.c` / `fw/build_jtag_rescue_firmware.sh` | JTAG 救援专用最小固件及构建脚本 |

**修改文件：**

| 文件 | 变更 |
|------|------|
| `rtl/top/snn_soc_top.sv` | 集成 `jtag_mem_loader`；fabric 二选一 → 三路仲裁（JTAG / E203 / bus_if）；新增 `cpu_reset_hold_effective`、`jtag_timeout_force`（256 周期超时恢复）；`cpu_bus_m_valid` 在 JTAG 活跃或 CPU reset hold 时被 gate |
| `rtl/top/chip_top.sv` | JTAG pad 从 `jtag_stub` 切换到 `jtag_mem_loader` 路径 |
| `rtl/top/e203_min_wrap.sv` | 新增 `cpu_local_rst_n` 输入，只复位 CPU 核，不波及 SRAM 和外设 |
| `rtl/bus/icb2simple_bridge.sv` | 新增 `busy_o` 输出（bridge 非 IDLE 时拉高），供 JTAG 仲裁逻辑判断 CPU 事务是否在途 |
| `sim/sim_e203.f` 等主线 filelist | 补齐 `jtag_mem_loader.sv` |

### JTAG 协议定义

| IR (4-bit) | 名称 | DR 宽度 | 说明 |
|---|---|---|---|
| `4'h1` | IDCODE | 32 | 返回 `32'hE203_0001`（项目自定义 ID） |
| `4'h2` | MEMACC | 69 | `[0]=write, [32:1]=addr, [36:33]=wstrb, [68:37]=wdata`；响应：`[31:0]=rdata, [32]=err, [33]=done` |
| `4'h3` | CPUCTL | 2 | `[0]=cpu_reset_hold, [1]=reserved`；hold=1 时只复位 CPU+bridge，SRAM/SNN/外设不复位 |
| `4'hF` | BYPASS | 1 | 标准 bypass |

可访问地址范围仅限 `instr_sram / data_sram / weight_sram`，MMIO 一律返回 `err=1`。

### 仲裁策略

- JTAG 请求到来时，等待 `cpu_bridge_busy=0` 后接管 fabric（不硬抢占）
- 若 `cpu_bridge_busy` 持续 256 周期不释放，自动触发 `jtag_timeout_force`：局部复位 CPU+bridge 后接管
- CPU 暂停为总线级 gate（`cpu_bus_m_valid & ~jtag_grant & ~cpu_reset_hold`），不做时钟门控

### 验证结果

```
JTAG 单元测试:   全部 PASS  → JTAG_MEM_LOADER_PASS
JTAG 系统测试:   全部 PASS  → JTAG_RESCUE_TOP_PASS
Python 自测:     全部 PASS  → JTAG_PYHOST_SELFTEST_PASS
黑盒 smoke 回归: OUT_FIFO_COUNT=100  → LIGHT_SMOKETEST_PASS
带权重回归:      OUT_FIFO_COUNT=55   → WEIGHTED_SIM_PASS
sample-align:    100/100 matched     → SAMPLE_ALIGN_PASS
E203 启动回归:                       → E203_SMOKETEST_PASS
SPI 单测回归:                        → SPI_SMOKETEST_PASS
ADC 饱和回归:                        → ADC_SAT_COUNTER_PASS
chip_top lint:                       → verilator lint clean
```

---

## Iteration 10 — V1.1 silicon bring-up 收尾 + boot_rom 集成（2026-04-23）

**背景**：feature/main-fpga-e203 在 ZCU102 上 Phase C 全过后，回 main 做流片前最后一轮前端收尾。

### 8 个 Stage 概览

1. **Stage 1** — 两个 CRITICAL WARNING 修复
   - XDC `set_false_path -from *mmcm_locked*` 打不到 cell → 改成 `-to rst_sync_reg[0]`
   - `uart_ctrl.sv` `baud_div_active` 多驱动 → 全部合并到 TX FSM
2. **Stage 2** — `PROG_CTRL[3] = BYPASS_HANDSHAKE` 新增（test_mode 扩到编程 FSM）
   - bypass=1 时注入 fake prog_adc_done + 理想 prog_bl_data，verify 永远 PASS
   - START 时锁存，busy 期间改 PROG_CTRL 不影响 in-flight
3. **Stage 3+4** — `fw/silicon_bringup/` 数字自检固件 + Icarus TB
   - Stage A test_mode 推理对齐 + Stage B BYPASS_HANDSHAKE 编程 FSM
   - `SILICON_BRINGUP_DIGITAL_PASS` / `_FAIL_<stage>` tag
4. **Stage 5** — `rtl/mem/boot_rom.sv` 独立模块 + TB（23/23 PASS）
5. **Stage 6** — `scripts/fpga_bringup_capture.sh` xsct+pyserial 自动化
6. **Stage 7** — FPGA 板上验证 test_mode，COM3 收到 `SILICON_BRINGUP_DIGITAL_PASS`
7. **Stage 8** — 文档（`silicon_bringup_plan.md` + `silicon_bringup_guide.md`）

### V1.1 — boot_rom 真正连进 SoC（2026-04-23 下午）

- `bus_interconnect.sv`：ENABLE_BOOT_ROM=1 时地址解码把 0x0000..0x0FFF 指向 ROM，
  INSTR_SRAM 从 0x0 往上 shift 0x1000，容量保持 16 KB
- `snn_soc_top.sv`：新增 `ENABLE_BOOT_ROM` 参数 + 条件实例化 boot_rom
- `chip_top.sv`：tape-out 路径打开 `ENABLE_BOOT_ROM=1` + `BOOT_ROM_INIT_FILE` 可注入
- `fw/boot_rom/boot_rom_main.c`：完整 SPI flash bootloader
  （RDID + 读 header + 验 magic `0x544F4F42`='BOOT' + 搬运 + 跳转）
- `fw/boot_rom/link_boot_rom.ld` / `build_boot_rom.sh`：text @ 0x0，ROM 4 KB
- `fw/link_app.ld`：应用固件链接地址 0x0 → 0x1000
- `scripts/make_boot_image.py`：生成 16B header + app bin 的 flash 镜像
- `tb/chip_top_rom_smoke_tb.sv`：端到端 ROM → SPI flash model → SRAM → app
- `tb/prog_bypass_latch_tb.sv`：BYPASS_HANDSHAKE latch 专测

### Gate A 回归（14/14 全绿）

```
LIGHT_SMOKETEST_PASS            DMA_SMOKETEST_PASS
CIM_PROGRAM_CTRL_PASS           UART_SMOKETEST_PASS
SPI_SMOKETEST_PASS              AXI_BRIDGE_SMOKETEST_PASS
PROG_PULSE_CFG_TB_PASS          PROG_START_INTERLOCK_TB_PASS
BOOT_ROM_TB_PASS (23/23)        SILICON_BRINGUP_TB_PASS
E203_SMOKETEST_PASS             CHIP_TOP_ROM_SMOKE_PASS
PROG_BYPASS_LATCH_TB_PASS       WEIGHTED_SIM_PASS
```

### 关键 commit（新增到 main）

```
5ab0223b gpt-fix: finalize main tapeout boot chain and ROM smoke
6c73d052 docs: add silicon_bringup_guide.md (Day 1/2/3 SOP + method B/C)
688bea8d feat(rtl): V1.1 — integrate boot_rom into SoC bus (ENABLE_BOOT_ROM)
10652709 gpt-fix: harden silicon bring-up bypass and capture flow
926b3ae6 feat+docs: Stage 6+8 — FPGA bring-up capture harness + silicon plan
d5a4e87d feat: Stage 5 — add boot_rom mask ROM module (standalone + TB)
58292120 feat: Stage 3+4 — silicon bring-up firmware + Icarus TB
f47fe738 feat(rtl+xdc): Stage 1+2 — critical warnings fixed + test_mode extended
```

### 当前 main 分支状态（tape-out 视角）

- **数字 RTL 功能**：全部 ready，tape-out-intent 路径
  （`ENABLE_PROGRAM_MODE=1` + `ENABLE_BOOT_ROM=1` + `ENABLE_EXT_CIM_IF=1`）
  仿真级 smoke 通过
- **固件物料**：`fw/boot_rom/`（ROM bootloader）+
  `fw/silicon_bringup/`（数字自检）+ `fw/e203_smoke/`（完整推理）都已就位
- **FPGA 证据**：feature/main-fpga-e203 分支 Phase C 三个 PASS tag 归档在
  commit `dc7c8903` + GPT 加固 `f985868b`
- **下一步（非前端）**：
  - 后端：DC 综合 / P&R / STA / DRC / LVS / ESD / 工艺 SRAM+ROM macro swap
  - 板级 / 器件老师：pad ring / VCCIO / 模拟接口 IO 电压定档
  - 前端如需改动只做 bug fix，不再加功能

---

## Iteration 11 — 外部编程合同 A8 冻结（方案 α'，2026-04-24）

**背景**：模拟 CIM macro 交接 handoff 前最后一步。推理接口已冻结，但外部 erase/write/verify
编程接口 (A8) 一直是 blocker，模拟同学无法按文档直接做。本轮由数字侧拍板并落地。

### 决定（方案 α'）

- 新增 **7 个 D→A pads**（pad 总数 48 → 55），承载编程操作类型和目标电导等级
- **不新增** A→D pad：verify PASS/FAIL 由数字侧对 `bl_data` 自己比对得出

| 新增 pad | 位宽 | 方向 | 语义 |
|---|---|---|---|
| `prog_op[2:0]` (pads 46..48) | 3 | D→A | 000 inference / 001 erase_cell / 010 write / 011 verify / 100 erase_full_array / 101..111 reserved |
| `prog_level[3:0]` (pads 49..52) | 4 | D→A | 目标电导等级 0..15，仅 write 时有效 |

### RTL 改动

- `rtl/top/snn_soc_top.sv`：新增 output ports `prog_op_ext[2:0]` + `prog_level_ext[3:0]`；加编码器逻辑（基于内部 `prog_busy`/`prog_en_sig`/`erase_en_sig`/`verify_en_sig`/`prog_full_array`/`prog_level`）
- `rtl/top/chip_top.sv`：新增 pad ports `prog_op_pad[2:0]` + `prog_level_pad[3:0]`，连接到 `snn_soc_top`
- 7 个 TB（`top_tb.sv` / `silicon_bringup_tb.sv` / `prog_bypass_latch_tb.sv` / `e203_tb.sv` / `jtag_rescue_top_tb.sv` / `top_tb_adc_sat_counter.sv` / `top_tb_icarus_light.sv` / `top_tb_icarus_weighted.sv` / `top_tb_sample_align.sv`）补 wire 声明

### 文档改动（全部已冻结）

- `doc/08_cim_analog_interface.md` §10 新增 "外部编程接口"——编码表、时序图、
  电气要求、不变量、回归覆盖
- `doc/03_cim_if_protocol.md` 末节新增 "编程协议"——协议 + RTL 入口 + 验证
- `doc/15_asic_pad_map.md`：pad 表扩 48→55；46..52 新增编程 pad；含编码子表
- `doc/11_analog_handoff_execution_plan.md` A8 从 "blocker" 标为 "已冻结"，
  保留冻结决策记录
- `doc/17_cim_macro_handoff_cover.md` 封面从 "编程 blocker" 改为 "编程 frozen"
- `doc/02_reg_map.md` CIM 编程寄存器节加 pad 映射注释
- `CLAUDE.md` 新增 "Pad 预算 + 外部编程合同" 段

### 回归（11/11 全绿）

```
LIGHT_SMOKETEST_PASS            DMA_SMOKETEST_PASS
CIM_PROGRAM_CTRL_PASS           UART_SMOKETEST_PASS
PROG_PULSE_CFG_TB_PASS          PROG_START_INTERLOCK_TB_PASS
BOOT_ROM_TB_PASS                SILICON_BRINGUP_TB_PASS
E203_SMOKETEST_PASS             CHIP_TOP_ROM_SMOKE_PASS
PROG_BYPASS_LATCH_TB_PASS
```

### 已知 follow-up（不阻塞 handoff，但影响 tape-out 完备性）

- `wl_mux_wrapper` 当前被 `cim_array_ctrl` 的推理 bitmap 独占；编程路径 `prog_wl_spike`
  还没经过 TDM 打上 `wl_data` pad（内部 macro 可见，外部 pad 不见）。follow-up 是让
  `wl_mux_wrapper.wl_bitmap_in` 在 `prog_busy=1` 时 mux 到 `prog_wl_spike`。
  ASIC 上模拟 die 需要看到 row 选择才能做单 cell program；这条 follow-up 不做完 tape-out 不能算完整支持外部编程，但不影响 analog 接口文档（pads + 协议）交付给器件老师。
- 模拟侧回填的电气参数（A4/A5/A6/A7 电压/时序/噪声）需要按冻结后的编程协议对齐

### 关键 commit（按时间）

- `rtl/top/snn_soc_top.sv` + `rtl/top/chip_top.sv` pad 扩容 + 文档集合（本次）

---

## 后续计划（Tapeout 准备）

| 项目 | 内容 | 说明 |
|------|------|------|
| Pad cell | 替换 chip_top 信号直连为工艺 pad cell 实例化 | ESD / drive / IO type 配置 |
| DC 综合 | 55nm 标准单元库综合 | 面积 / 时序 / 功耗报告 |
| DFT | Scan chain 插入 | 可测试性 |
| P&R | 布局布线 | 1×1mm die |
| Signoff | STA / DRC / LVS / ERC | 最终检查 |
| 板级 bring-up | boot image 格式完善 / JTAG rescue 实测 / 真实 SPI Flash | 仿真→板级过渡 |
| Foundry ROM macro swap | boot_rom.sv → TSMC ROM compiler macro | 流片前 mask data 交付 |
| Foundry SRAM macro swap | sram_simple → TS6N65LP（或等效）| 综合前对齐接口 |

每次迭代完成后在本文档追加一节记录。
