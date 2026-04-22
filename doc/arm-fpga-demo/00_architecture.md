# feature/v2-arm-fpga-demo — Architecture

**Status**:
- **Phase A（仿真 + RTL wrapper）—✅ ALL GATES PASS**（commit `8301c226`）
- **Phase B（ARM firmware cross-build）—✅ GATE B PASS**（`v2b_arm_demo.elf` linked, zero undefined refs, symbols verified）
- **Phase C0 本地静态 sanity — ✅ OOC synth PASS + BD 创建 / 验证 / 保存 PASS + 地址 0xA0000000 via HPM0_FPD 已锁**（full bitgen + 板上 smoke 在 Qingan sign-off + 有板子时跑）
- Phase C0 board smoke、Phase C1 board smoke — 待上板

**Scope rule**: evidence branch，**不 merge 回 v2，不 touch main**，**不修改 V2.B accelerator datapath / cmd-rsp 合约**。本 doc 覆盖 Phase A + Phase B + Phase C0 的静态产出（RTL wrapper、ARM C 代码、Vivado TCL、xsct 脚本）；上板日志放 `board_bringup_log_c0.md` / `_c1.md`。

关联计划：`C:\Users\24201\.claude\plans\noble-soaring-beaver.md` (REV 2)。

---

## 1. 目标 & 边界

| 维度 | 说明 |
|---|---|
| **目标** | 把 `snn_soc_v2b_top` 包装成 AXI4-Lite slave，使 ZCU102 Cortex-A53 PS 可通过 MMIO 直接驱动 V2.B accelerator。 |
| **不做** | E203-in-PL、Vivado BD、Vitis BSP（后续 Phase B/C），不碰 V2.B core datapath。 |
| **可改** | 仅本分支内 additive 的 `snn_soc_pkg.sv`（+2 个 localparam）和 `axi2simple_bridge.sv`（+1 行 `addr_mapped`）。 |
| **Merge policy** | Phase A/B/C 全过之后**保留 branch**，tag `v2-arm-fpga-demo-passed`，不 merge 回 v2；paper/doc 只引用 tag + commit + board log。 |

---

## 2. 顶层构成

```
┌──────────────────────────── v2b_arm_demo_top ───────────────────────────┐
│  (Vivado OOC 综合 sanity 顶，仅做端口 re-expose，无额外逻辑)              │
│                                                                          │
│  ┌──────────────────────── v2b_axi_wrapper ─────────────────────────┐   │
│  │                                                                  │   │
│  │  AXI-Lite slave ──► axi2simple_bridge ──► simple2v2btop_adapter  │   │
│  │  (5-channel)        (既有模块，            (新增，本分支)        │   │
│  │                      不改动)                                     │   │
│  │                                                                  │   │
│  │                                    │ cmd_valid/cmd_addr/         │   │
│  │                                    │ cmd_wdata/cmd_wstrb         │   │
│  │                                    ▼ rsp_valid/rsp_rdata         │   │
│  │                          ┌────────────────────┐                  │   │
│  │                          │  snn_soc_v2b_top   │                  │   │
│  │                          │  (V2.B accelerator │                  │   │
│  │                          │   零改动)           │                  │   │
│  │                          └────────────────────┘                  │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────┘
```

| 模块 | 文件 | 改动类型 |
|---|---|---|
| `v2b_arm_demo_top` | `rtl/top/v2b_arm_demo_top.sv` | 新增（OOC 综合顶，~60 行） |
| `v2b_axi_wrapper` | `rtl/top/v2b_axi_wrapper.sv` | 新增（组装 3 件，~150 行） |
| `simple2v2btop_adapter` | `rtl/bus/simple2v2btop_adapter.sv` | 新增（FSM 适配，~150 行） |
| `axi2simple_bridge` | `rtl/bus/axi2simple_bridge.sv` | additive +1 行白名单（branch-local） |
| `snn_soc_pkg` | `rtl/top/snn_soc_pkg.sv` | additive +2 localparam（branch-local） |
| `snn_soc_v2b_top` | `rtl/top/snn_soc_v2b_top.sv` | **不动** |

---

## 3. 关键决策（D1–D6 → 落地结果）

| Plan 决策 | Phase A 产出的落地 |
|---|---|
| **D1** Vitis BSP first | Phase B 再落地；Phase A 不依赖任何 firmware 工具链。 |
| **D2** axi2simple_bridge + 新 adapter + 新 wrapper | `rtl/bus/simple2v2btop_adapter.sv` + `rtl/top/v2b_axi_wrapper.sv` 完成。 |
| **D3** `addr_mapped()` additive | 见第 4 节。 |
| **D4** V2B_SOC_BASE = proposed `0xA000_0000` | 见第 4 节；final 以 Vivado Address Editor 生成的 `xparameters.h` 为准（Phase C0 时确认）。 |
| **D5** Golden in C header | Phase B 再落地。本分支 Phase A 的 AXI cosim TB 直接 `$readmemh` 读 Python golden。 |
| **D6** 不改现有 V2.B parity 合约 | 已确认：`v2b_soc_top_parity_tb.sv` / `fw_cosim_resident_14x14_tb.sv` 仍 PASS（见第 6 节）。 |

---

## 4. 地址窗口

- **AXI master** 访问 `ADDR_V2B_BASE .. ADDR_V2B_END`（proposed `0xA000_0000 .. 0xA000_0FFF`），bridge 的 `addr_mapped()` 会接受；窗口外地址返回 DECERR。
- Adapter 取 `m_addr[11:0]` 作为 v2b_top 的 `cmd_addr`（12-bit）。
- `snn_soc_pkg.sv` 新加的两行：
  ```sv
  // [feature/v2-arm-fpga-demo branch-local; do not merge to v2 as-is.]
  localparam logic [31:0] ADDR_V2B_BASE = 32'hA000_0000;
  localparam logic [31:0] ADDR_V2B_END  = 32'hA000_0FFF;
  ```
- Vivado BD Address Editor 分配到不同 base（e.g., `0xB000_0000`）时：改 `snn_soc_pkg.sv` 一行常量 + firmware 里的 `V2B_SOC_BASE` 宏，不需要动 RTL wrapper。

---

## 5. Adapter 时序（核心技术点）

### 5.1 v2b_top cmd/rsp 合约（只读摘要，来源 `rtl/top/snn_soc_v2b_top.sv:422–466`）

- `cmd_ready = 1'b1`（always-ready slave）
- `rsp_valid <= cmd_valid;`（1-cycle registered，不做反压）
- `rsp_rdata <= read_mux;`
  - read_mux 是**组合逻辑**，按 `cmd_addr` case 分派；
  - 直接寄存器（CFG*/STATUS/...）：read_mux 在当拍已正确 → rsp_rdata @ N+1 正确；因为 cmd_addr 保持，@ N+2 还正确；
  - 间接 SBA/SBB (0x4xx / 0x8xx)：read_mux 使用 registered `cmd_read_sb*_q`，需要在 cmd_valid=1 后多等 **1** 拍才让 sbX_rd_data 透过 read_mux → rsp_rdata 在 N+2 active 读到正确值，N+3 active 被覆写成 0。

### 5.2 Adapter FSM（4 state）

```
ADP_IDLE ──(m_valid=1 & m_write=1)──► ADP_WR_ACK ──► ADP_IDLE     (2 cycle 写)
         ──(m_valid=1 & m_write=0)──► ADP_RD_WAIT ──► ADP_RD_DONE ──► ADP_IDLE  (3 cycle 读)
```

| 拍 | 状态 | adapter 输出 | DUT 侧 |
|---|---|---|---|
| N | ADP_IDLE, m_valid=1 | `cmd_valid=1` + 用 live m_* 驱动 cmd_addr/cmd_write/cmd_wdata/cmd_wstrb；同拍 latch 到 q_* 寄存器 | DUT 采样 cmd_valid=1；寄存 cmd_read_sb*_q；写路径直接落 register |
| N+1（写） | ADP_WR_ACK | `m_ready=1` | bridge 收到 m_ready → ST_WR_RSP |
| N+1（读） | ADP_RD_WAIT | cmd_valid=0；cmd_addr/cmd_write/cmd_wdata/cmd_wstrb **从 q_\*** 驱动（保持） | read_mux = sbX_rd_data（cmd_read_sb*_q=1）；rsp_rdata <= 正确值（NBA）|
| N+2（读） | ADP_RD_DONE | `m_rvalid=1`, `m_rdata = rsp_rdata` | bridge 在 N+2 active-before-NBA 采样到 m_rvalid=1 且 m_rdata=正确值，捕获进 rdata_reg |

### 5.3 为什么 cmd_addr 必须"粘住"

read_mux 的 case 依赖 `cmd_addr`。如果 adapter 把 cmd_addr 清零，read_mux 会跳回 `A_STAGE_CTRL` 分支，rsp_rdata 就被覆写成 `{24'h0, done_sticky, 7'h0}`。本 adapter 通过 `q_addr/q_write/q_wdata/q_wstrb` 四个寄存器在 ADP_IDLE 那一拍 latch 当前交易、随后拍默认用 q_* 驱动 cmd_*，保证 cmd_addr 整个事务期间都等于交易目标地址。

这与既有 `tb/fw_cosim_resident_14x14_tb.sv` 的 `bus_read` 行为等价（那边只把 cmd_valid 清零，cmd_addr 留在 TB 的 `reg` 里不变）。

---

## 6. Phase A Gate 验证结果（仿真）

| 脚本 | 期望 tag | 结果 |
|---|---|---|
| `sim/run_v2b_soc_top_parity.sh` | V2B_SOC_TOP_PARITY_TB_PASS | ✅ PASS |
| `sim/run_fw_cosim_resident_14x14.sh` | FW_COSIM_RESIDENT_14X14_TB_PASS | ✅ PASS |
| **`sim/run_axi_arm_cosim_resident_14x14.sh`** | **AXI_ARM_COSIM_RESIDENT_14X14_TB_PASS** | ✅ **PASS**（本分支新增） |
| `sim/run_tile_partial_buf.sh` | TILE_PARTIAL_BUF_TB_PASS | ✅ PASS |
| `sim/run_stream_buffer_v2.sh` | STREAM_BUFFER_V2_TB_PASS | ✅ PASS |
| `sim/run_input_stream_sram.sh` | INPUT_STREAM_SRAM_TB_PASS | ✅ PASS |
| `sim/run_lif_neuron_alu.sh` | LIF_NEURON_ALU_PASS | ✅ PASS |
| `sim/run_cim_mac_v2_dim_edge.sh` | CIM_MAC_BEHAVIORAL_V2_DIM_EDGE_TB_PASS | ✅ PASS |
| `sim/run_streamed_stage_parity.sh` | STREAMED_STAGE_PARITY_TB_PASS | ✅ PASS |
| `sim/run_tile_accumulator_parity.sh` | TILE_ACCUMULATOR_PARITY_TB_PASS | ✅ PASS |
| `sim/run_stage_engine_v2.sh` | STAGE_ENGINE_V2_TB_PASS | ✅ PASS |
| `sim/run_multilayer_sample_parity.sh` | MULTILAYER_SAMPLE_PARITY_TB_PASS | ✅ PASS |
| `sim/run_stage_engine_v2_invalid_cfg.sh` | STAGE_ENGINE_V2_INVALID_CFG_TB_PASS | ✅ PASS |
| `sim/run_v2b_primitive_reg_contract.sh` | V2B_PRIMITIVE_REG_CONTRACT_TB_PASS | ✅ PASS |
| `sim/run_icarus_light.sh` | LIGHT_SMOKETEST_PASS | ✅ PASS |
| `sim/run_multilayer.sh` | MULTILAYER_SMOKE_PASS | ✅ PASS |
| `sim/run_multilayer_scan_ext.sh` | MULTILAYER_SCAN_EXT_PASS | ✅ PASS |
| `python -m pytest python_multilayer/tests -q` | 84 passed / 2 skipped | ✅ 84 PASS, 2 skip |

**Gate A 通过**：additive 修改 + 新 RTL wrapper 没有破坏任何现有回归；新 AXI cosim TB 与 Python golden 对于全部 10 个 Fashion 14×14 sample 的 per-class spike count 逐 bit 一致。

---

## 7. 本分支 Phase A 与 plan REV 2 的差异

| 项 | REV 2 原意 | Phase A 实现 | 原因 |
|---|---|---|---|
| **Weight load semantics** | "Boot once, per-sample 只 reload stream" | 本 AXI cosim TB 和 parity TB 一样 **per-sample 重载权重** | Parity TB（`fw_cosim_resident_14x14_tb.sv::sw_infer_from_golden_wl`）也是 per-sample reload；若强行 resident 会脱离 parity 合约，本分支不改 V2.B datapath。真正 boot-once 语义交给 Phase B firmware 验证。 |
| **Adapter 读延迟** | "3-cycle 读（N+3 采样）" | **2-cycle 读（N+2 采样）** | v2b_top 的 `cmd_read_sb*_q` 在 cmd_valid=0 后会在 N+2 active 之后 fall 回 0，N+3 的 rsp_rdata 已被覆写为 0。正确采样点是 N+2 active-before-NBA。 |

两处差异都已在对应文件的 header 注释中记录。

---

## 8. Phase B 实施细节

### 8.1 产出文件（全部在 `fw/arm/` 树下，branch-local）

| 文件 | 角色 |
|---|---|
| `fw/arm/include/platform.h` | `V2B_SOC_BASE` / `UART_BASE` / `UART_REF_CLK_HZ` macros；可被 `-D` 覆盖 |
| `fw/arm/include/uart_ps.h` | UART driver 头 |
| `fw/arm/include/golden_fashion10.h` | Golden 数据结构声明（由 Python 生成） |
| `fw/arm/src/golden_fashion10.c` | Golden 数据 C 内嵌（~320 KB，10 samples × pixel_196 + encoded_stream + counts + class；**含全局权重数组**） |
| `fw/arm/src/uart_ps.c` | Zynq Ultrascale+ PS UART0 最小 Tx poll 驱动（115200 8N1） |
| `fw/arm/src/crt0_aarch64.S` | 最小 AArch64 启动：设栈、清 bss、跳 arm_main |
| `fw/arm/src/v2b_scheduler_arm.c` | 2 行薄包装：define `V2B_SOC_BASE` + include 原始 `fw/src/v2b_scheduler.c` |
| `fw/arm/src/arm_main.c` | Phase C0 入口：UART init → MMIO self-test → C0 loop → C1 loop |
| `fw/arm/link_arm.ld` | 独立 AArch64 linker script（DDR @ 0x100000，16 MB 区域，64 KB 栈） |
| `fw/arm/build_arm_firmware.sh` | 一键编译/链接/Gate B 检查 |
| `fw/arm/scripts/gen_golden_header.py` | 从 `python_multilayer/.../fashion_multilayer_golden/` 生成 `golden_fashion10.[hc]` |

### 8.2 额外改动

| 文件 | 改动 | 原因 |
|---|---|---|
| `fw/include/v2b_soc_regs.h` | `V2B_SOC_REG` 宏中增加 `(uintptr_t)` cast | AArch64 上 `uint32_t → pointer` 触发 `-Wint-to-pointer-cast`；32-bit E203 侧 `uintptr_t==uint32_t`，no-op |

### 8.3 Phase B Gate 结果

```
text    data    bss    dec     hex    filename
67216   0       69680  136896  216c0  v2b_arm_demo.elf
```
- `.text` 66 KB = 代码 ~33 KB + `.rodata` 34 KB (golden 数据)
- `.bss` 4 KB 实 BSS + 64 KB stack NOLOAD 预留
- 0 undefined refs；`arm_main / v2b_infer_resident_14x14 / v2b_run_stage / uart_init / golden_fashion10 / _start` 全部 present
- `[build_arm_firmware] PHASE_B_GATE_PASS` 打标

### 8.4 **MMIO self-test 修正**（Round 1 review finding）

初版 self-test 使用 `STAGE_CFG4` 做 round-trip — 但 `snn_soc_v2b_top.sv` 根本没把 CFG4 connected 到任何寄存器（写被静默丢弃，读返回 0）。已改用 `STAGE_CFG1`（threshold，标准 32-bit R/W，`sw_run_stage` 每次 stage 运行前会覆写），保证 round-trip 真能检测 AXI-Lite 路径故障。

### 8.5 **Cache / MMU 策略（板上注意事项）**

本 Phase B 的 `crt0_aarch64.S` **不做 MMU 初始化**。Cortex-A53 reset 默认：`SCTLR_EL1.M=0, I=0, C=0` → 所有 memory 按 strongly-ordered (Device-nGnRnE) 处理。这意味着：
- MMIO writes/reads 到 `0xA000_0000..0xA000_0FFF` 会**正确**地穿过 AXI SmartConnect（因为没有 cache coherence 问题）
- Instruction fetches 和 .rodata 读取**不 cache** → 整体执行很慢，但正确

对于 Phase C0/C1 smoke 的 10 sample × 14×14 推理，预估总运行时间 < 30 秒（uncached）。Production 部署时会切换到 Vitis BSP 路线，BSP 的 `MMUTable.c` 会把 PL MMIO window 标为 Device-nGnRnE，把 DDR 代码/数据标为 Normal cacheable，吞吐提升 50-100 倍。

### 8.6 Weight-load 策略（和 Phase A 一致）

`v2b_infer_resident_14x14` 和 C0 loop 都 **per-sample reload** weights，完全匹配 `fw_cosim_resident_14x14_tb.sv::sw_infer_from_golden_wl` 的行为。plan REV 2 §D5 原想做 boot-once resident，但 parity TB 自身就不是 boot-once，所以本分支 Phase A/B 都跟随 parity 合约。真正 boot-once 验证留给未来（可能需要 V2.B RTL 调整来确保 weight memory 跨 stage 保持）。

---

## 9. Phase C0 实施细节

### 9.1 产出文件

| 文件 | 角色 |
|---|---|
| `rtl/top/v2b_axi_wrapper_bd.v` | **plain-Verilog shim**，instantiates `v2b_axi_wrapper.sv`；**带 X_INTERFACE_INFO 属性**让 Vivado BD 自动把 AXI 信号打包成 `s_axi` 接口。**仅 Phase C0 用**（sim 侧还是用 `.sv`） |
| `fpga_synth/zcu102_arm_demo.tcl` | 全流程：PS IP + SmartConnect + wrapper + addr map + synth + impl + bitgen + XSA export |
| `fpga_synth/ooc_v2b_arm_demo.tcl` | 快速 sanity：OOC synth `v2b_arm_demo_top.sv` on `xczu9eg-ffvb1156-2-e`，~30s |
| `fpga_synth/bd_sanity_zcu102_arm_demo.tcl` | 快速 sanity：BD 创建 + validate + save（不跑 synth），~30s |
| `fpga_synth/zcu102_arm_demo.xdc` | 空（ZCU102 的 IO 由 board preset 自动填充） |
| `scripts/build_zcu102_arm_demo.sh` | bash 入口，调 `vivado -mode batch` 跑全流程，~30-40 min |
| `scripts/program_zcu102_c0.tcl` | xsct：连 JTAG → `rst -system` → `fpga -file *.bit` → source `psu_init.tcl` → `dow ELF` → `con` |
| `scripts/program_zcu102_c1.tcl` | 同 C0（目前 ELF 里 C0+C1 loop 在一起；脚本名保留以备未来拆分） |

### 9.2 **为什么需要 `.v` shim（Vivado BD 限制）**

Vivado `create_bd_cell -type module -reference` **拒绝 SystemVerilog** 作为 top 文件（`filemgmt 56-195`）。但 SV 文件可以作为 dependency。`v2b_axi_wrapper_bd.v` 是一个纯 Verilog 层，同样的端口定义，instantiate `v2b_axi_wrapper`，并在端口上挂 `X_INTERFACE_INFO` 属性使 Vivado BD 推断出 `s_axi` AXI-Lite slave 接口。

### 9.3 地址映射（锁死到 HPM0_FPD）

- Zynq US+ PS 有三个 PL-facing AXI masters：
  - HPM0_LPD：aperture `<0x8000_0000 [ 512M ]>`，32-bit，低速 LPD
  - HPM0_FPD：aperture `<0xA000_0000 [ 256M ]>` + 其他 big apertures，128-bit 原生
  - HPM1_FPD：同 HPM0_FPD 的其他 aperture
- plan REV 2 D4 提议 V2B_SOC_BASE=`0xA000_0000` → 必须走 HPM0_FPD（LPD 的 aperture 不覆盖）
- SmartConnect 做 width convert：128-bit PS master → 32-bit AXI-Lite slave
- TCL 用 `assign_bd_address -offset 0xA0000000 -range 4K` 强制到 HPM0_FPD 的 `0xA000_0000 [ 256M ]` aperture

### 9.4 Phase C0 sanity 结果（本地静态）

| 检查 | 脚本 | 结果 |
|---|---|---|
| OOC synth `v2b_arm_demo_top` | `vivado -mode batch -source ooc_v2b_arm_demo.tcl` | ✅ `TIMING_STATUS : PASS` @ 50 MHz（pseudo-constraint 20 ns period，匹配项目 baseline） |
| BD 创建 + validate + save | `vivado -mode batch -source bd_sanity_zcu102_arm_demo.tcl` | ✅ `ZCU102_BD_SANITY_PASS`；`u_v2b_wrapper/s_axi` 接口正确推断；地址段挂在 `<0xA000_0000 [ 4K ]>` |
| Full bitgen + XSA | `scripts/build_zcu102_arm_demo.sh` | ⏳ 待在有 Vivado + 时间预算的机器上跑（~35 min） |
| 上板 C0 smoke | `xsct scripts/program_zcu102_c0.tcl` | ⏳ 待有板子后执行 |

### 9.5 已知上板风险（待 board smoke 时验证）

| # | 风险 | 严重度 | 缓解 |
|---|---|---|---|
| C0-R1 | PS PLL 对 50 MHz 目标产出的 pl_clk0 可能有小数偏差（如 49.99 MHz） | 低 | 已从 `v2b_axi_wrapper_bd.v` 的 `X_INTERFACE_PARAMETER` 移除 `FREQ_HZ` 硬编码，让 Vivado 自动传播 BD 真实频率，避免 validate mismatch |
| C0-R2 | xsct 走 JTAG 直接 `dow ELF` 不经过 FSBL → DDR 未训练？ | 中 | 脚本 source `psu_init.tcl` 先初始化 DDR + PS，再 load ELF |
| C0-R3 | SmartConnect 在 Low-area mode 不支持 WRAP burst | 低 | 我们只做 AXI-Lite（无 burst），纯 SINGLE transactions。警告可忽略 |
| C0-R4 | 没 MMU，指令和 rodata 读都 uncached，性能差 | 低 | 10 sample 总 inference 应 < 30s，能 PASS tag 即可 |

---

## 10. Paper wording（plan REV 2 §8）

| 状态 | 可写措辞 | 当前？ |
|---|---|---|
| **当前**（仿真 + firmware build 过，板上未验） | "V2.B has achieved Python/RTL/firmware-scheduler co-simulation parity. An ARM-hosted ZCU102 FPGA artifact is under development." | ✅ |
| **Phase C0 board PASS 之后** | "The V2.B accelerator was validated on ZCU102 through ARM-hosted MMIO control with bit-exact output counts (10 Fashion-MNIST 14×14 samples)." | ⏳ |
| **Phase C1 board PASS 之后** | "The board-side ARM processor executes the same scheduler flow used in co-simulation, including pixel stream encoding, stage execution, and output count verification." | ⏳ |

始终**不可写**（直到 E203-in-PL 分支跑通）："autonomous SoC-local firmware execution"、"E203 firmware already runs V2.B on FPGA"、"integrated RISC-V + CIM SoC with firmware self-orchestration"。
