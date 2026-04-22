# ZCU102 Firmware 路线决策备忘

日期：2026-04-22
状态：**待 Qingan 拍板**（GPT round-3 audit Q1）
作者：Claude（基于仓库当前状态 + GPT 风险列表自动起草）

---

## 1. 决策触发背景

GPT round-3 review 指出：

> `v2b_scheduler.c` 目前是 standalone V2B SoC top 的 reference C，TB 是 SV mirror；没有 E203 或 ARM 的 build/link target。`snn_soc_v2b_top` 也是 simple bus top，不含 CPU。

也就是说：**当前 V2.B firmware 只在 SV co-sim 里 bit-exact 跑通，还没被真正编译成可跑在 CPU 上的 binary**。Phase C 上 ZCU102 之前必须先选好 CPU。

两条候选路线：
- **A**：E203 软核放进 PL（RV32，现有 main 同款）
- **B**：Zynq UltraScale+ 板上自带的 Cortex-A53 硬核（PS 区域，通过 PL-AXI 桥到 accelerator）

---

## 2. 路线 A：E203-in-PL（RV32 软核）

### 优点

1. **和 main 流片 CPU 一致**：`fw/main.c` / `fw/crt0.S` / `fw/link.ld` / `build_e203_firmware.sh` 工具链完全复用。
2. **Bit-exact 潜力最大**：main 的 E203 SoC 已经有 `run_e203_icarus.sh` PASS 的完整 SV 仿真 reference，上板只是换 CIM macro 的物理连接。
3. **Paper 卖点强**：论文能干净声称 "integrated RISC-V CPU + RRAM CIM SoC"，不用解释为什么 FPGA 和流片用不同 CPU。
4. **流片路径短**：ZCU102 demo 验证的 firmware 可以**一行不改**搬到流片芯片里。

### 缺点

1. **占 PL 资源**：E203 大约 ~8-15K LUT + ~10-20 BRAM18（视配置），ZCU9EG 274K LUT 够用但要留 SNN 主体 ~50K LUT 余量；当前 `snn_soc_v2b_top` synth 占 ~36K LUT，加 E203 + AXI wrapper 估总 ~55K，**够**。
2. **Performance 偏弱**：E203 @ 50 MHz vs A53 @ 1.2 GHz，DMA setup / polling overhead ~24 倍差距。但 V2.B 推理是 CIM-bound（200-400 µs 每样本），CPU 那点 overhead 可忽略。
3. **需要加 E203 ↔ snn_soc_v2b_top 的总线桥**：现在 `snn_soc_v2b_top` 的 bus 是自定义 cmd/rsp，不是 E203 的 ICB。需要写一个 ICB → v2b_bus bridge（~200 行 SV，工作量 1-2 天）。
4. **Boot flow 要从头搭**：SPI flash loader / JTAG rescue / reset vector — main 已经有这套，但要为 V2.B reg_bank 适配。

### 工作量估算

| 任务 | 工作量 |
|---|---|
| 写 ICB↔v2b_bus bridge + TB | 1-2 天 |
| `fw/src/v2b_scheduler.c` port 到 E203 linker script（main.c 模板套） | 0.5 天 |
| build_v2b_e203_firmware.sh + bootloader hook | 0.5 天 |
| co-sim TB 用真 compiled `v2b_scheduler.o`（替代当前 SV mirror）| 1 天 |
| ZCU102 Vivado 顶层集成 + 烧板 bringup | 2-3 天 |
| **合计** | **5-7 天** |

---

## 3. 路线 B：Cortex-A53 ARM（Zynq PS 硬核）

### 优点

1. **PL 资源完全给 SNN**：A53 在 PS 上，PL 部分不用放 CPU，`snn_soc_v2b_top` 的 ~36K LUT 无压力，还能加 debug probe、logic analyzer 等。
2. **Linux / bare-metal 工具链成熟**：aarch64-none-elf-gcc / petalinux / Xilinx SDK 全套。可以用 printf 输出实时 debug，甚至挂 GDB on-target。
3. **性能爆表**：A53 @ 1.2 GHz，DMA / polling overhead 可忽略。如果未来要跑在线学习 (online training) 或更复杂 orchestration，A53 绰绰有余。
4. **Xilinx 生态兼容**：现成的 AXI DMA / AXI Lite 模板，不用手写总线桥。PS-PL 接口是 Zynq 本身标准，绝大多数 tutorial 都能直接套用。

### 缺点

1. **和流片 CPU 不一致**：流片用 E203，FPGA demo 用 A53。审稿人会问 "firmware 到底跑在哪个 CPU 上？"，需要在 paper 里解释"FPGA prototype 用主机 CPU 验证 accelerator 功能，流片版用 E203"——不是致命缺陷，但叙事不如路线 A 干净。
2. **`v2b_scheduler.c` 需要 port**：寄存器 offset 基址不同（PS-AXI 映射下 V2B_SOC_BASE 要改），数据类型要在 `volatile uint32_t *` 和 ARM cache-coherency 间调协。工作量比 A 稍大，但有 Xilinx BSP 兜底。
3. **流片硅片上跑的 firmware 是另一套**：路线 B 等于 FPGA firmware 和流片 firmware 是两份 codebase。Maintenance 负担 ×2。
4. **需要 petalinux/Vitis 环境**：VM 占用 + 工具链 setup 成本高；Claude / 同学电脑上可能没有。

### 工作量估算

| 任务 | 工作量 |
|---|---|
| Vivado block design: Zynq UltraScale+ PS + AXI Lite → v2b_bus | 0.5 天 |
| Vitis bare-metal 项目配置（linker / BSP / xparameters.h） | 1 天 |
| `v2b_scheduler.c` port 到 ARM：volatile cast / cache-flush | 0.5-1 天 |
| 调试：第一轮 PS↔PL 通路 debug（DMA cache 一致性最容易踩坑） | 1-2 天 |
| bit-exact 验证（能跑出和 SV TB 同样 spike 输出） | 1 天 |
| **合计** | **4-5.5 天** |

---

## 4. 比较矩阵

| 维度 | A: E203-in-PL | B: Cortex-A53 PS |
|---|---|---|
| 和流片 CPU 一致 | ✅ 完全一致 | ❌ 不一致 |
| PL 资源 | ✅ ~55K/274K LUT 够用 | ✅✅ ~36K/274K，余量大 |
| Performance（相对 CIM） | ✅ 过剩 | ✅✅ 远过剩 |
| 工具链成熟度 | 🟡 riscv-gnu-toolchain OK，但 debug 弱 | ✅✅ Xilinx Vitis + GDB 完备 |
| 上板工作量 | 🟡 5-7 天 | 🟡 4-5.5 天 |
| Maintenance 负担 | ✅ 单一 firmware codebase | ❌ 两套 firmware |
| Paper 叙事 | ✅ 干净："integrated RV32 + CIM SoC" | 🟡 需解释 FPGA/流片分工 |
| Bit-exact to tapeout | ✅ 同一份 `main.c` 风格 | 🟡 需维护两份"逻辑等价但实现不同"firmware |
| 器件 bring-up 灵活度 | 🟡 中等（E203 debug 工具少） | ✅ 高（Vitis debug + AXI ILA） |

---

## 5. Claude 的建议（仅供参考，不替 Qingan 做决定）

如果论文**主卖点是 "RISC-V + CIM SoC 集成"**：选 **A**。FPGA demo 和流片版用同一份 firmware，审稿人不可能挑刺。

如果论文**主卖点是 "可配置 CIM accelerator"**（CPU host 相对次要）、或者你希望 FPGA demo 快速出结果：选 **B**。工作量略小，性能空间大，debug 体验好。如果走 B，paper 里诚实写 "FPGA prototype uses on-chip ARM host for control; tape-out SoC integrates E203 RISC-V core (verified bit-exact in RTL)"，审稿人不太会为此拒稿。

**如果两个都想保留**（精力允许）：先走 B 快速验证 FPGA bit-exact parity（这是 paper hard gate），再补 A 证明 E203 集成可行（paper 加一张对比图）。但这等于做两遍，只推荐 Phase C 有富余时间才做。

---

## 6. 决策回填

Qingan 醒来后请在此处标注：

- [ ] 路线 A (E203-in-PL)
- [ ] 路线 B (Cortex-A53 PS)
- [ ] A + B 都保留（ablation demo）
- [ ] 其他（请说明）

决策后 Claude 会：
1. 更新 `doc/17_v2_roadmap.md` 的 Phase C 工作项
2. 为所选路线补 `build_v2b_{e203,arm}_firmware.sh` + linker/BSP
3. 补一个真实 compiled firmware 的 co-sim TB（代替当前 SV mirror）
4. 更新 `CLAUDE.md` 的 Phase C 状态
