# GPT 复审 prompt — `feature/v2-arm-fpga-demo` Phase A/B/C0 全方面检查

**Context for you (GPT) — read carefully before starting**

此任务是对一个 **evidence branch** 的**事无巨细**全方面检查，不是过场。此分支**不会 merge 回 v2**，但它即将驱动一块 ZCU102 板子跑 Fashion-MNIST 推理，是 paper 里要引用的实物证据。上板前能靠你在代码/脚本/文档里查出来的 bug，上板后就是"烧了 bitstream 在板子上 debug JTAG"，时间成本 10x-100x。**所以这次 review 的价值比平时大很多。**

**Scope rule**：
- 只 touch `feature/v2-arm-fpga-demo` 分支（本分支）
- **不修改** `rtl/top/snn_soc_v2b_top.sv` / `stage_engine_v2.sv` / `cim_mac_behavioral_v2.sv` / `input_stream_sram.sv` / `stream_buffer_v2.sv` / `tile_partial_buf.sv` 这些 V2.B accelerator core
- **不修改** `tb/v2b_soc_top_parity_tb.sv` / `fw_cosim_resident_14x14_tb.sv` 这些 parity 合约 TB
- **不 merge 到 v2**，**不 touch main**
- `rtl/top/snn_soc_pkg.sv` / `rtl/bus/axi2simple_bridge.sv` 可以 additive 改，但都是 branch-local

---

## 1. 背景摘要（120 秒了解）

### 1.1 项目
SNN SoC，两条平行线路：
- `main`：V1 单层 64→10 tapeout-ready，前一次 round-3 GPT APPROVE
- `v2`：V2.B streamed-rate multilayer paper/FPGA 线，前一次 round-3 GPT APPROVE_WITH_MINOR_FIX（已修完 RISK-01 + doc mismatches）

### 1.2 本 evidence branch 的任务
把 `snn_soc_v2b_top.sv` 包装成 AXI-Lite slave，让 ZCU102 Cortex-A53 PS 通过 MMIO 驱动 V2.B accelerator 跑 10 个 Fashion-MNIST 14x14 样本 bit-exact。

### 1.3 三个 Phase 划分
- **Phase A**：仿真 + RTL wrapper。已 commit `8301c226`，17 个 TB + 84 pytest 全 PASS。
- **Phase B**：ARM firmware 交叉编译。已 commit `f7625ddf`，Gate B PASS（ELF 链接干净，零 undefined）。
- **Phase C0 静态 sanity**：Vivado TCL/XDC + xsct 脚本 + BD 脚本。**本地静态 check 通过**：OOC synth PASS（WNS 9.281 ns @ **50 MHz** — 项目 baseline，和 `fpga_synth/synth_v2b.tcl` / CLAUDE.md / doc 一致）、BD creation/validate/save PASS、地址 0xA0000000 @ HPM0_FPD 绑定正确。**bitgen + 上板 smoke 尚未执行**（等有板子的机器）。
  - ⚠️ **Frequency correction note**：初版 commit `f7625ddf` 里我误用了 100 MHz pl_clk0（偏离项目 50 MHz baseline）。Qingan 指出后已在一个 `gpt-fix` 级别的 commit 里改回 50 MHz（见 `git log --oneline`）。**你 review 时以 HEAD 的 50 MHz 版本为准。**
- **Phase C0/C1 board smoke**：还没做。

### 1.4 本次 review 的边界
你要审的是**Phase A/B/C0 已 commit 的全部产出**（`17693e4f..HEAD` 的 diff，~6280 行增量）。不审 V2.B core datapath（冻结不动）。

---

## 2. 仓库路径 & 工具链

- 仓库：`d:/SoC Design/audit-v2/`
- 分支：`feature/v2-arm-fpga-demo`
- 起点：commit `17693e4f`（v2 round-3 approved 的 tag）
- 目前 HEAD：`f7625ddf`（Phase B + C0 static）
- Vivado：`D:\Xilinx\Vivado\2022.2\bin\vivado.bat`
- Vitis aarch64-none-elf toolchain：`D:\Xilinx\Vitis\2022.2\gnu\aarch64\nt\aarch64-none\bin\aarch64-none-elf-gcc.exe`
- Icarus Verilog 用于所有 RTL 回归（sim/run_*.sh）
- 注意：**workspace 路径含空格**（`SoC Design`）—— 所有 Vivado/gcc 调用必须用 DOS 8.3 form（`D:\SOCDES~1\audit-v2`）；相关 shell 脚本里已做 cygpath -dw 转换

---

## 3. 本次你要审的全部文件（新增 + 修改）

### Phase A（已 commit 8301c226）
```
rtl/bus/simple2v2btop_adapter.sv           新增 190 行   bus_simple → v2b_top cmd/rsp 适配 FSM
rtl/top/v2b_axi_wrapper.sv                 新增 152 行   打包 bridge + adapter + v2b_top
rtl/top/v2b_arm_demo_top.sv                新增  65 行   OOC synth sanity top（无逻辑）
rtl/bus/axi2simple_bridge.sv               additive +1 行 addr_mapped() 加 V2B window 白名单
rtl/top/snn_soc_pkg.sv                     additive +14 行 ADDR_V2B_BASE/END localparam
tb/axi_arm_cosim_resident_14x14_tb.sv      新增 390 行   AXI cosim TB
sim/sim_axi_arm_cosim_resident_14x14.f     新增
sim/run_axi_arm_cosim_resident_14x14.sh    新增
doc/arm-fpga-demo/00_architecture.md       新增 269 行
```

### Phase B（已 commit f7625ddf）
```
fw/include/v2b_soc_regs.h                  修改 +4-1 行  uintptr_t cast (32/64 port)
fw/arm/include/platform.h                  新增  39 行
fw/arm/include/uart_ps.h                   新增  13 行
fw/arm/include/golden_fashion10.h          新增  36 行   auto-generated
fw/arm/src/crt0_aarch64.S                  新增  59 行
fw/arm/src/uart_ps.c                       新增  97 行
fw/arm/src/v2b_scheduler_arm.c             新增  15 行
fw/arm/src/arm_main.c                      新增 202 行
fw/arm/src/golden_fashion10.c              新增 3365 行  auto-generated (10 samples + weights)
fw/arm/link_arm.ld                         新增  72 行
fw/arm/scripts/gen_golden_header.py        新增 256 行
fw/arm/build_arm_firmware.sh               新增 186 行
```

### Phase C0（已 commit f7625ddf）
```
rtl/top/v2b_axi_wrapper_bd.v               新增  86 行  Verilog shim for Vivado BD
fpga_synth/zcu102_arm_demo.tcl             新增 200 行  full BD + synth + impl + bitgen + XSA
fpga_synth/ooc_v2b_arm_demo.tcl            新增 135 行  quick OOC sanity
fpga_synth/bd_sanity_zcu102_arm_demo.tcl   新增 114 行  quick BD validate sanity (~30s)
fpga_synth/zcu102_arm_demo.xdc             新增  16 行  empty placeholder
scripts/build_zcu102_arm_demo.sh           新增  74 行  bash driver
scripts/program_zcu102_c0.tcl              新增 104 行  xsct JTAG loader
scripts/program_zcu102_c1.tcl              新增  69 行  xsct JTAG loader (same ELF)
```

### Phase B/C0 doc 更新
```
doc/arm-fpga-demo/00_architecture.md       +200 行  §8/§9/§10（Phase B/C0 details + paper wording）
.gitignore                                 +9 行   fw/arm/out + fpga_synth/zcu102_*
```

---

## 4. 已通过的 Gate（你应该独立**重跑一遍验证**，不要盲信）

### Gate A（仿真）
```bash
cd d:/SoC\ Design/audit-v2/sim
bash run_v2b_soc_top_parity.sh              # V2B_SOC_TOP_PARITY_TB_PASS
bash run_fw_cosim_resident_14x14.sh         # FW_COSIM_RESIDENT_14X14_TB_PASS
bash run_axi_arm_cosim_resident_14x14.sh    # AXI_ARM_COSIM_RESIDENT_14X14_TB_PASS  ←★本分支新增
# 11 V2.B unit TB
bash run_tile_partial_buf.sh
bash run_stream_buffer_v2.sh
bash run_input_stream_sram.sh
bash run_lif_neuron_alu.sh
bash run_cim_mac_v2_dim_edge.sh
bash run_streamed_stage_parity.sh
bash run_tile_accumulator_parity.sh
bash run_stage_engine_v2.sh
bash run_multilayer_sample_parity.sh
bash run_stage_engine_v2_invalid_cfg.sh
bash run_v2b_primitive_reg_contract.sh
# V1 smoke on v2
bash run_icarus_light.sh
bash run_multilayer.sh
bash run_multilayer_scan_ext.sh
# Python
cd d:/SoC\ Design/audit-v2
python -m pytest python_multilayer/tests -q   # 84 passed, 2 skipped
```

### Gate B（Phase B 交叉编译）
```bash
cd d:/SoC\ Design/audit-v2
bash fw/arm/build_arm_firmware.sh            # PHASE_B_GATE_PASS
# Expected: ELF 67 KB text / 4 KB bss, 0 undefined refs, all symbols present
```

### Gate C0 sanity（Phase C0 静态）
```bash
cd d:/SoC\ Design/audit-v2/fpga_synth
ROOT=$(cygpath -dw "/d/SoC Design/audit-v2" | tr '\\' '/')
# OOC synth sanity (~30s)
/d/Xilinx/Vivado/2022.2/bin/vivado.bat -mode batch \
  -source ooc_v2b_arm_demo.tcl -log ooc.log -tclargs "$ROOT"
# BD sanity (~30s)
/d/Xilinx/Vivado/2022.2/bin/vivado.bat -mode batch \
  -source bd_sanity_zcu102_arm_demo.tcl -log bd_sanity.log -tclargs "$ROOT"
# Expected: "TIMING_STATUS : PASS" + "ZCU102_BD_SANITY_PASS"
```

### Gate C0 full bitgen（还没跑，~35 min）
```bash
bash scripts/build_zcu102_arm_demo.sh        # 预期 PHASE_C0_BITGEN_PASS + .xsa
```

---

## 5. 你的任务：三轮事无巨细审查

### Round 1: 每个文件单独审（按下面 5 个子域分别过一遍）

#### A. Phase A RTL（`simple2v2btop_adapter.sv`、`v2b_axi_wrapper.sv`、`v2b_arm_demo_top.sv`、`axi2simple_bridge.sv` 的 addr_mapped 改动、`snn_soc_pkg.sv` 的 additive localparam）
特别关注：
- `simple2v2btop_adapter` 的 4-state FSM（IDLE → WR_ACK / RD_WAIT → RD_DONE）的时序。文件 header 里有一大段关于 "N+2 vs N+3 read sample"的推导，我认为这个分析是对的。**你要审：推导是否正确；边界 case 会不会出问题（背靠背读、读后紧跟写、reset during transaction）**。
- `q_addr / q_write / q_wdata / q_wstrb` latch 机制：为什么需要"粘住 cmd_addr"？文件 header 里 §"关键细节"解释了。请独立判断这是不是唯一/最简解，有没有更干净方案。
- `axi2simple_bridge.sv:104-117` 的 addr_mapped 新增一行对 V2B window 的白名单：branch-local 改动是否会在 merge 时误伤 V1？
- `v2b_axi_wrapper.sv` 里 bridge/adapter/v2b_top 的 wire 连接是否和 Phase A 的 AXI cosim TB 跑过的版本一致（你要对照 TB 的连线检查）。

#### B. Phase A TB（`tb/axi_arm_cosim_resident_14x14_tb.sv`）
- `axi_write` / `axi_read` 两个 task 的 AXI-Lite 5-channel handshake 对 AW/W 错拍、B/R 背压的处理对不对？
- TB 使用 **per-sample 重载权重** 而不是 plan REV 2 §D5 声称的 "boot-once resident"。header 里有解释（和 parity TB `fw_cosim_resident_14x14_tb.sv::sw_infer_from_golden_wl` 保持一致）。**你要审：这个"放弃 resident 语义追求 parity 对齐"的决策是不是合理？**还是说应该改 V2.B RTL 来真正支持 resident？（注意：本分支不动 V2.B core）
- TB 开头的 `axi_write(CFG1, 0xDEADBEEF) + axi_read(CFG1)` self-test：如果 round-trip 失败就 $finish，行为是否严谨？

#### C. Phase B C 代码（`arm_main.c`、`uart_ps.c`、`v2b_scheduler_arm.c`、`crt0_aarch64.S`、`link_arm.ld`、`platform.h`、`uart_ps.h`、`golden_fashion10.[hc]`）
特别关注：
- **`uart_ps.c` 的 BRGR / BAUDDIV 计算**：我用 100 MHz uart_ref_clk，BRGR=124, BAUDDIV=6 得 115207 baud。你核对 Zynq US+ UG1085 §21.2.1 baud rate formula: `baud = sel_clk / (BRGR × (BAUDDIV + 1))`。正确吗？board 上 PS UART 实际 sel_clk 可能是多少（100 MHz reference 还是经过了 /N 预分频）？
- **`crt0_aarch64.S` 没做 MMU/cache 初始化**：reset 默认 `SCTLR_EL1.M=0, I=0, C=0`，所有 memory 当 strongly-ordered（Device-nGnRnE）。我的判断是 MMIO 能正常工作（因为默认是 strongly ordered，每次 access 都打通 AXI），但 instruction/rodata fetch 不 cache → 慢。我估算 10 sample 上板总时间 < 30 秒。**这个估算你同意吗？有没有 Cortex-A53 在 MMU off 下你知道的 footguns？**
- **`arm_main.c` MMIO self-test 用 CFG1 而不是 CFG4**：我 Round 1 发现 CFG4 在 `snn_soc_v2b_top.sv` 里根本没 connect 到任何 register（write drop, read 0），所以原先用 CFG4 self-test 会 false-fail。改成了 CFG1 (threshold)，每次 `sw_run_stage` 会覆写，clobber 无后果。你同意？有没有更好的 self-test 寄存器？
- **`arm_main.c` 的 uart_puts(...) 组合式输出**：多个 uart_puts/put_dec 串联，是否有 re-entrancy / printf-vs-signal 问题？
- `link_arm.ld` 把 `.text` 放在 DDR @ 0x100000，16 MB 区域，64 KB stack NOLOAD。`.stack (NOLOAD)` 在 size 报告里被算入 bss（`bss=69680`），这是因为 NOLOAD section type=NOBITS 和 bss 同类。没问题吗？
- **`v2b_scheduler_arm.c` 只有 2 行**（define V2B_SOC_BASE + include `../../src/v2b_scheduler.c`）。这种 "include 源文件" 是正当做法还是反模式？跨 E203 和 ARM 重用 `v2b_scheduler.c` 的做法 OK 吗？
- `golden_fashion10.c` 是 auto-generated 3365 行 C 代码。check：生成的数据量是否正确（10 samples × (pixel 196 + encoded_stream 64*8*4 + counts 10*4 + class) ≈ 2.3KB each；weights 12544 + 640 bytes packed + 同量 raw pos/neg；总 rodata ~34 KB）。
- **`v2b_soc_regs.h` 加了 `(uintptr_t)` cast**：这是一个冻结了一段时间的 header。我加这个是为了 AArch64 的 32-bit→pointer 转换。E203 的 build 会不会炸？（我看了 `fw/build_e203_firmware.sh` 不编译 `v2b_scheduler.c`，所以应该没影响，但你再核对一下。）

#### D. Phase C0 Vivado/xsct 脚本（`zcu102_arm_demo.tcl`、`ooc_v2b_arm_demo.tcl`、`bd_sanity_zcu102_arm_demo.tcl`、`build_zcu102_arm_demo.sh`、`program_zcu102_c0.tcl`、`program_zcu102_c1.tcl`、`v2b_axi_wrapper_bd.v`）
特别关注：
- **HPM0_FPD vs HPM0_LPD 选择**：plan REV 2 里最初写 LPD。实际 0xA000_0000 地址在 FPD aperture（LPD 只到 0x9FFF_FFFF）。我改成 FPD。你同意这个改动？FPD 是 128-bit 原生，SmartConnect 做 width convert 到 32-bit AXI-Lite。性能上是否合理？
- **`v2b_axi_wrapper_bd.v` 的存在动机**：Vivado BD 拒绝 .sv 作为 module reference 的 top（filemgmt 56-195）。我写了一个 plain Verilog shim，放 X_INTERFACE_INFO 属性让 BD 自动推断 `s_axi` interface。**你审：这是正确做法吗？有没有更干净的方案（如 ipx::package_project 完整 IP 化）？现在这个 .v 和 .sv 两份维护，未来 drift 风险多大？**
- **`psu_init.tcl` 路径**：`program_zcu102_c0.tcl` 里 `glob`匹配 `fpga_synth/zcu102_arm_demo/.../hw_handoff/psu_init.tcl`。Vivado 2022.2 生成此文件的实际路径可能和我猜的不一样。你查 Vivado 文档或举例核对。
- **没有 FSBL**：我的 xsct 流程直接 `fpga -file bit → source psu_init.tcl → dow elf → con`，跳过 FSBL。DDR 初始化靠 psu_init.tcl 的 proc。这个做法是 ZCU102 bringup 的标准 bare-metal 路线吗？还是应该先跑 Vitis-generated FSBL？
- **没有 I-cache enable**：crt0 没开 I-cache 也没开 MMU。ELF 会在 DDR 里 uncached 跑。你审：是否需要在 crt0 里至少开 I-cache 以提高性能？D-cache 没 MMU 不能开，会让 MMIO 错乱。
- `ooc_v2b_arm_demo.tcl` 只做 OOC synth，没做 impl。是 Phase C0 sanity 充分还是不够？
- `bd_sanity_zcu102_arm_demo.tcl` 只 validate + save BD 不跑 synth。是充分还是不够？
- `zcu102_arm_demo.tcl` 的 address assignment `assign_bd_address -offset 0xA0000000 -range 4K`：verified by bd_sanity.log 在 `<0xA000_0000 [ 4K ]>` 上。但 full bitgen 时会不会某个 step 重新 assign 到默认 aperture？

#### E. 文档 `doc/arm-fpga-demo/00_architecture.md`
- §5.2 adapter FSM 时序表的 N+2 vs N+3 分析是否严谨？
- §8.5 cache/MMU 策略段是否准确描述了 Cortex-A53 reset 默认行为？
- §9.3 HPM0_FPD aperture 分析（`<0xA000_0000 [ 256M ]>`）是否和 Xilinx 文档一致？
- 是否有 paper-wording 越界（写了不该写的"board-validated"之类）？

### Round 2: 跨模块 / 集成视角
- **Phase A → Phase B**：scheduler 流程（`v2b_scheduler.c`）在仿真里走 direct cmd/rsp，在 ARM 侧走 AXI-Lite → bridge → adapter → cmd/rsp。两个路径的时序差异是否完全被 `simple2v2btop_adapter` 吸收？AXI cosim TB 验证了 bit-exact — 上板会不会出现 cosim 覆盖不到的 corner（如 cold-start、FSM stall、AXI protocol 的 FIFO 背压）？
- **Phase B → Phase C0**：ELF 里 `V2B_SOC_BASE=0xA0000000`；Vivado BD 在 `0xA0000000 / 4K` 绑定 wrapper。如果 Vivado Address Editor 被人手动改到其他地址（如 0xB0000000），ELF 会访问错地址，DECERR。**当前有没有 checksum / 互锁机制来防止这种不一致？**或者至少文档里有明确提醒？
- **golden_fashion10.c 数据溯源**：gen_golden_header.py 从 `python_multilayer/.../fashion_multilayer_golden/` 读；AXI cosim TB 也从同目录读。两者用的是同一批 hex 文件。ELF 里内嵌了这批数据的 C 形式。如果未来 golden 更新，gen_golden_header.py 必须重跑。**是否应该在 build_arm_firmware.sh 里加一个 golden hex mtime 检查？**
- **CFG4 误用的盲区**：我在 Round 1 发现 CFG4 unwired，但这种"reserved register behavior"在 `v2b_soc_regs.h` 或 `v2b_stage_regs.h` 里**没有明确文档化**。有没有其他 register 同样隐含 unwired？你帮我枚举一下所有 `V2B_SOC_STAGE_CFG*` 的真实连接状态（grep v2b_top.sv:331-381 的 write case + :436-454 的 read_mux）。
- **Cortex-A53 上 `-mgeneral-regs-only` + `-ffreestanding` + 无 libc** 的代码组合是否有我没想到的 corner case？（比如 `<stdint.h>` 不能用等）
- **`crt0_aarch64.S` 的 `adrp + :lo12:` 对 `_stack_top` 的访问**：如果 linker 因为 `.stack (NOLOAD)` 放在 `.bss` 后面，`_stack_top` 会在更高地址。adrp 加载 page 地址，add 加 page offset，需要 address 在 ±4 GB 内。我们整个 text/data/bss/stack 都 < 100 KB 总大小，在 16 MB MEMORY 区间内。没问题吧？
- **`v2b_axi_wrapper_bd.v` 和 `v2b_axi_wrapper.sv` 的 port list drift**：如果未来有人改 .sv 的 port 但忘了同步 .v，BD synth 会 fail。**是否应该加一个 lint/ CI check？**

### Round 3: 计划 vs 实现 vs 现实
对照 `C:\Users\24201\.claude\plans\noble-soaring-beaver.md`（REV 2）的每条 gate criterion / decision / file 列表，核对哪些条目是"按计划完成"，哪些是"偏离计划但有合理解释"，哪些是"遗漏 / 没落地"。
- 特别检查 §3 的文件清单 vs 实际产出
- §5 的风险矩阵每一条是否在代码里有对应的缓解
- §6 的 gate 命令清单是否都通了
- §8 的 paper wording 分级：`doc/arm-fpga-demo/00_architecture.md` §10 是否准确反映当前进度？有没有写过头？
- §10 的 REV 2 vs 原 plan 修订清单里每一条是否真的落地？

---

## 6. Review 输出格式

按以下模板回复（严格遵循）：

```markdown
# GPT Review: feature/v2-arm-fpga-demo Phase A/B/C0

## Verdict
[ ] APPROVE
[ ] APPROVE_WITH_MINOR_FIX
[ ] BLOCK

## Summary
<2-3 sentences, neutral>

## Findings

### BLOCK-level (必须上板前修)
(list 0..N items with file:line, description, root cause, proposed fix)

### HIGH-level (建议上板前修)
(list 0..N)

### MEDIUM-level (可以上板后修)
(list 0..N)

### LOW-level (nit / style / future)
(list 0..N)

## Re-validated gates
- Ran Gate A (sim) locally? [Y/N, tags observed]
- Ran Gate B (ELF) locally? [Y/N, size + symbols]
- Ran Gate C0 sanity (OOC + BD)? [Y/N, WNS + BD pass]

## Confidence
[ ] I am confident this branch is safe to bitgen + board-smoke AFTER fixing BLOCK/HIGH
[ ] I found gaps that need Qingan to answer before I can give final verdict (list them)
```

---

## 7. 重要约束（你的行动规则）

1. **你出问题 → 直接修复**（edit the file），然后在 finding 里注明 "fixed at [file:line] with [approach]"。不要写"建议 user 修"。
2. **不确定的 → 停下来问我（Qingan）**，不要自己替我做决定。
3. **不得修改 V2.B accelerator core**（`snn_soc_v2b_top.sv` / `stage_engine_v2.sv` / `cim_mac_behavioral_v2.sv` / `input_stream_sram.sv` / `stream_buffer_v2.sv` / `tile_partial_buf.sv`）和 parity TB（`v2b_soc_top_parity_tb.sv` / `fw_cosim_resident_14x14_tb.sv`）。
4. **不得 merge 到 v2 分支，不得 push 到 origin。**
5. 修复后必须**重跑对应的 Gate**确认没回归：
   - 改 RTL → 重跑 Phase A 17 个 TB + pytest
   - 改 C 代码 → 重跑 Gate B
   - 改 Vivado TCL → 重跑 ooc + bd sanity
6. 修复提交时用独立 commit（不要 amend 我的 f7625ddf），msg 前缀 `gpt-fix:` 方便我 review。

---

## 8. 速查表

| 问 | 答 |
|---|---|
| 目标板 | ZCU102 (xczu9eg-ffvb1156-2-e) |
| PL clock | **50 MHz** via pl_clk0（项目 baseline）；PS UART ref clock 独立 = 100 MHz (LPD) |
| V2B_SOC_BASE | `0xA000_0000` (4 KB) via HPM0_FPD |
| UART baseline | ZCU102 USB-UART @ 115200 8N1 |
| UART port on chip | PS UART0 @ 0xFF00_0000 |
| Golden topology | Fashion-MNIST 196_64_10, T=64, adc_bits=10 |
| PASS tag C0 | `ARM_FPGA_DEMO_ACCEL_FASHION10_PASS` |
| PASS tag C1 | `ARM_FPGA_DEMO_SCHEDULER_FASHION10_PASS` |
| Phase A commit | `8301c226` |
| Phase B/C0 commit | `f7625ddf` |
| plan file | `C:\Users\24201\.claude\plans\noble-soaring-beaver.md` |

---

**Start the review now.** 先 `git log 17693e4f..HEAD --stat` 看全部改动，然后按 Round 1/2/3 顺序做。期待你在 BLOCK/HIGH 里发现至少 3-5 个我漏掉的东西，因为我本人已经在写代码的 fatigue 状态，review 精度不保证。
