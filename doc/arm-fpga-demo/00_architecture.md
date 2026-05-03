# feature/v2-arm-fpga-demo / -conv — Architecture

**Status**:
- **Phase A（仿真 + RTL wrapper）—✅ 全部 Gate PASS**（commit `8301c226`）
- **Phase B（ARM 固件交叉编译）—✅ GATE B PASS**（`v2b_arm_demo.elf` 链接成功，无 undefined refs，所有关键符号已验证）
- **Phase C0 本地静态 sanity — ✅ OOC 综合 PASS + BD 创建 / 验证 / 保存 PASS + 地址 0xA0000000 经 HPM0_FPD 已锁**（完整 bitgen + 板上 smoke 在用户 sign-off + 有板子时执行）
- **Phase C0/C1 板级验证（frozen v1，Fashion-MNIST 14×14）—✅ PASS**（tag `v2-arm-fpga-demo-passed` @ `8e51ae27`，2026-04-22 sign-off）
- **Fix wave F1（WSTRB partial-write 修复）—✅ RTL/TB PASS + 重 bitgen PASS + 重烧 PASS**（tag `v2-arm-fpga-demo-v2-passed`，2026-04-25 sign-off）
- **CONV 扩展 + LeNet-5 28×28 板验（feature/v2-arm-fpga-demo-conv）—✅ PASS**（当前分支 HEAD `bf56e942`；LeNet-5 closure/evidence anchor = `d50b7d37`；prior bit/XSA build commit = `537ad3b1`；原生 conv1 root-cause fix commit = `48958da0`；最新 re-verify PASS marker = `ARM_FPGA_DEMO_LENET5_PASS`，详见 §12）

**Scope rule**: evidence branch，**不 merge 回 v2，不 touch main**。frozen v1 与 v2 fix wave 通过双 tag 并存：

| Tag | Commit | bit/elf SHA256 简述 | 时间 | 用途 |
|---|---|---|---|---|
| `v2-arm-fpga-demo-passed` | `8e51ae27` | bit `1215D913…`, elf `1D6D6BB3…` | 2026-04-22 | frozen v1 板验（**WSTRB 漏洞潜伏期**） |
| `v2-arm-fpga-demo-v2-passed` | `03a39a61` | bit `78A5F36C…`, elf `AEEB02A0…` | 2026-04-25 | F1 修后重烧版（partial-write 语义正确） |

引用规则：
- 论文叙事 / 简历 → 引用 **v2 tag**（语义正确版）
- 历史复现 / 对比研究 → 引用 v1 tag（保留 evidence 不可变性）
- 老 tag **不 move**（不把它指向新 commit），保持 git 历史可审计

详见 §11 "Evidence trail (v1 vs v2)" + `board_bringup_log_c0_c1_uart.txt`（v1）+ `board_bringup_log_v2.txt`（v2）+ `build_manifest_v2.txt`（v2 工具链/路径 manifest）。

关联计划：`C:\Users\24201\.claude\plans\noble-soaring-beaver.md` (REV 2)。

---

## 1. 目标 & 边界

| 维度 | 说明 |
|---|---|
| **目标** | 把 `snn_soc_v2b_top` 包装成 AXI4-Lite slave，使 ZCU102 Cortex-A53 PS 可通过 MMIO 直接驱动 V2.B accelerator。 |
| **不做** | E203-in-PL、production Vitis BSP app、Linux/PetaLinux、DMA/DDR streaming，仍不碰 V2.B core datapath。 |
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
| `snn_soc_v2b_top` | `rtl/top/snn_soc_v2b_top.sv` | frozen v1 不动；fix wave F1 补 `cmd_wstrb` 语义 |

---

## 3. 关键决策（D1–D6 → 落地结果）

| Plan 决策 | Phase A 产出的落地 |
|---|---|
| **D1** ARM runtime | 实现偏离原计划的 Vitis-BSP-first：当前 Phase B/C0 采用最小 `aarch64-none-elf-gcc` 裸机 ELF + `psu_init.tcl` JTAG bring-up；Vitis BSP 保留为后续性能/工程化路线。 |
| **D2** axi2simple_bridge + 新 adapter + 新 wrapper | `rtl/bus/simple2v2btop_adapter.sv` + `rtl/top/v2b_axi_wrapper.sv` 完成。 |
| **D3** `addr_mapped()` additive | 见第 4 节。 |
| **D4** V2B_SOC_BASE = proposed `0xA000_0000` | BD sanity 已确认 `u_v2b_wrapper/s_axi` 被强制分配到 `<0xA000_0000 [4K]>`，走 HPM0_FPD。 |
| **D5** Golden in C header | Phase B 已落地：`golden_fashion10.[hc]` 内嵌 10 samples + 全局权重；Phase A AXI cosim 仍直接 `$readmemh` 同一批 Python golden。 |
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
| **`sim/run_v2b_axi_partial_write.sh`** | **V2B_AXI_PARTIAL_WRITE_TB_PASS** | ✅ **PASS**（AXI 栈级 WSTRB gate） |
| **`sim/run_v2b_partial_write_invariant.sh`** | **V2B_PARTIAL_WRITE_INVARIANT_TB_PASS** | ✅ **PASS**（direct-top permanent W1P/W1C gate） |
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
| **Weight load semantics** | "Boot once, per-sample 只 reload stream" | 本 AXI cosim TB 和 parity TB 一样 **per-sample 重载权重** | Parity TB（`fw_cosim_resident_14x14_tb.sv::sw_infer_from_golden_wl`）也是 per-sample reload；若强行 resident 会脱离 parity 合约，本分支不改 V2.B datapath。真正 boot-once / per-stage resident 语义留给未来单独验证。 |
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
| `fw/arm/src/golden_fashion10.c` | Golden 数据 C 内嵌（生成源 ~3.3k 行；ELF `.text/.rodata` 合计约 67 KB；10 samples + 全局权重数组） |
| `fw/arm/src/uart_ps.c` | Zynq Ultrascale+ PS UART0 最小 Tx poll 驱动（115200 8N1） |
| `fw/arm/src/crt0_aarch64.S` | 最小 AArch64 启动：设栈、清 bss、跳 arm_main |
| `fw/arm/src/v2b_scheduler_arm.c` | 2 行薄包装：define `V2B_SOC_BASE` + include 原始 `fw/src/v2b_scheduler.c` |
| `fw/arm/src/arm_main.c` | Phase C0 入口：UART init → MMIO self-test → C0 loop → C1 loop |
| `fw/arm/link_arm.ld` | 独立 AArch64 linker script（OCM @ `0xFFFC0000`，256 KB 区域，64 KB 栈） |
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

本 Phase B/C0 的 `crt0_aarch64.S` **不做 MMU/cache 初始化**；JTAG 脚本依赖 `psu_init.tcl` 完成 PS/DDR/PL isolation bring-up。对这个 first-smoke 路线的实际含义是：
- `0xA000_0000..0xA000_0FFF` 的 MMIO volatile load/store 不会被本 firmware 自己打开的 D-cache 缓住；地址映射错误时仍可能直接 data abort 或无响应；
- OCM 中的 instruction fetch 和 `.rodata` 读取不走本地启用的 cache 路径 → 整体执行较慢，但足够做 10-sample PASS tag；
- 具体复位 EL / debug state 由 XSCT + `psu_init.tcl` 决定，所以 board log 里要记录实际启动脚本和 Vivado/Vitis 版本。

对于 Phase C0/C1 smoke 的 10 sample × 14×14 推理，预估总运行时间 < 30 秒（uncached）。Production 部署时会切换到 Vitis BSP 路线，BSP 的 `MMUTable.c` 会把 PL MMIO window 标为 Device-nGnRnE，把 DDR 代码/数据标为 Normal cacheable，吞吐提升 50-100 倍。

### 8.6 Weight-load 策略（和 Phase A 一致）

`v2b_infer_resident_14x14` 和 C0 loop 都 **per-sample reload** weights，完全匹配 `fw_cosim_resident_14x14_tb.sv::sw_infer_from_golden_wl` 的行为。plan REV 2 §D5 原想做 boot-once resident，但 standalone V2.B 当前只有一套 MAC weight store，stage0 和 stage1 不能同时常驻两套权重；本分支因此跟随已验证 parity 合约。真正 boot-once / per-stage resident 需要未来加权重 bank、stage-local weight memory，或接受明确的 stage reload schedule。

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
- 本 TCL 把 HPM0_FPD 数据宽度配置为 32-bit（`PSU__MAXIGP0__DATA_WIDTH=32`），SmartConnect 主要承担 AXI-Lite 连接/时钟复位/地址 decode；不是依赖 128→32 数据宽转换。
- TCL 用 `assign_bd_address -offset 0xA0000000 -range 4K` 强制到 HPM0_FPD 的 `0xA000_0000 [ 256M ]` aperture

### 9.4 Phase C0 sanity 结果（本地静态）

| 检查 | 脚本 | 结果 |
|---|---|---|
| OOC synth `v2b_arm_demo_top` | `vivado -mode batch -source ooc_v2b_arm_demo.tcl` | ✅ `TIMING_STATUS : PASS` @ 50 MHz（pseudo-constraint 20 ns period，匹配项目 baseline） |
| BD 创建 + validate + save | `vivado -mode batch -source bd_sanity_zcu102_arm_demo.tcl` | ✅ `ZCU102_BD_SANITY_PASS`；`u_v2b_wrapper/s_axi` 接口正确推断；地址段挂在 `<0xA000_0000 [ 4K ]>` |
| Full bitgen + XSA | `scripts/build_zcu102_arm_demo.sh` | ✅ frozen v1 + F1 fix wave v2 均已完成；v2 bit/XSA SHA 见 `build_manifest_v2.txt` |
| 上板 C0/C1 smoke | `xsct scripts/program_zcu102_c0.tcl` | ✅ frozen v1 + F1 fix wave v2 均已完成；v2 UART log 见 `board_bringup_log_v2.txt` |

> 注：`v2-arm-fpga-demo-passed` 代表 frozen v1 的板验完成；当前 fix wave 的重烧/重测证据统一写入 `doc/arm-fpga-demo/board_bringup_log_v2.txt`。

### 9.5 fix wave 重烧风险（当前待验证）

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
| **frozen v1（已板验）** | "The V2.B accelerator was validated on ZCU102 through ARM-hosted MMIO control with bit-exact output counts (10 Fashion-MNIST 14×14 samples)." | ✅ |
| **F1 修复后 v2 tag（已重烧）** | "The AXI partial-write repair has board evidence and preserves the original full-word firmware behavior while restoring byte-strobe correctness." | ✅ |
| **fix wave re-burn PASS 之后** | "The AXI partial-write repair preserves the original board-validated behavior while restoring byte-strobe correctness on the ARM-hosted MMIO path." | ✅ |

始终**不可写**（直到 E203-in-PL 分支跑通）："autonomous SoC-local firmware execution"、"E203 firmware already runs V2.B on FPGA"、"integrated RISC-V + CIM SoC with firmware self-orchestration"。

---

## 11. Evidence trail (v1 vs v2)

### 11.1 为什么有两个 tag

`v2-arm-fpga-demo-passed` (2026-04-22) 板验通过的 frozen bit 在 `rtl/top/snn_soc_v2b_top.sv` AXI-Lite 写路径未消费 `cmd_wstrb`，partial write 被悄悄放大成全字写。该 bug 在 v1 板验里**未被触发**（ARM firmware 全部走 32-bit 写），但流片后任何走 byte-mask 的 SW 都会触发——其中 `A_STAGE_CTRL` 的 byte0-only START W1P 在 `wstrb=4'b0010` 时仍会误触发 stage engine。

**详细暴露证据**：`tb/v2b_axi_partial_write_tb.sv` 在老 RTL 上跑出 7 mismatches（T1/T2/T3/T4/T5/T6/T8），其中 T8 `STAGE wrong-byte got=0x01 exp=0x00` 直接证明误启动；同 TB 在 fix 后 RTL 上全 PASS。

### 11.2 fix wave 内容

| 改动 | 文件 | 说明 |
|---|---|---|
| RTL byte-mask | `rtl/top/snn_soc_v2b_top.sv` | 新增 `apply_wstrb()` 函数，所有 CFG/STAGING 写做 read-modify-write byte merge；W1P/W1C 控制位（START/CLR/strobe）由 `cmd_wstrb[0]` 守门 |
| 新单元 TB | `tb/v2b_axi_partial_write_tb.sv` | 8 个测试覆盖单字节写、混合 byte mask、错位 byte 不应触发 W1P 等场景；老 RTL FAIL（暴露 bug 基线）+ 新 RTL PASS |
| 重 bitgen | `fpga_synth/zcu102_arm_demo/...` | Vivado v2022.2，WNS=8.358 ns @ 50 MHz，TNS=0，新 bit SHA256 `78A5F36C…` |
| 重烧板 | `xsct scripts/program_zcu102_c0.tcl` | UART 抓 `ARM_FPGA_DEMO_ACCEL_FASHION10_PASS` + `ARM_FPGA_DEMO_SCHEDULER_FASHION10_PASS`，10 sample × 10 class 与 v1 board log byte-exact 一致 |
| 配套 doc/manifest | `board_bringup_log_v2.txt` + `build_manifest_v2.txt` | 工具链版本、resolved psu_init.tcl 路径、bit/elf/xsa SHA256 完整可复现 |

### 11.3 引用规则

- **新工作**：以 `v2-arm-fpga-demo-v2-passed` 为基线；引用 bit/elf 用 v2 SHA256
- **复现 / 对照实验**：可显式引用 v1 tag 做"老 bit 表现"对比
- **CI / regression**：永远跑新 RTL（merged HEAD），不要 checkout v1 tag 做新功能开发
- **老 tag policy**：v1 tag **永不 move**，不打 `-f`，不删；保持 git 历史可审计

### 11.4 后续 invariant 保护

当前分支保留两层 WSTRB gate：

| 层级 | 命令 | 目的 |
|---|---|---|
| AXI 栈级 | `sim/run_v2b_axi_partial_write.sh` | 证明 ARM PS-facing AXI WSTRB 经 `v2b_axi_wrapper` 传到 V2.B core，8 个 case 全 PASS |
| direct-top | `sim/run_v2b_partial_write_invariant.sh` | 直驱 `snn_soc_v2b_top.cmd_*`，守住 START W1P / DONE W1C / clear pulses 的 byte0 invariant |

后续任何触碰 `rtl/top/snn_soc_v2b_top.sv`、`rtl/top/v2b_axi_wrapper.sv` 或 `rtl/bus/simple2v2btop_adapter.sv` 的改动，都应同时跑这两条 gate。

---

## 12. CONV 扩展 + LeNet-5 28×28 板验（feature/v2-arm-fpga-demo-conv 子分支）

**当前分支 HEAD**：`bf56e942`（2026-05-03；async-assert/sync-release reset +
cim_done CDC sync）
**LeNet-5 closure/evidence anchor**：`d50b7d37`（2026-05-03；docs/evidence
alignment + ARM ELF rebuild hash re-check）
**prior bit/XSA build commit**：`537ad3b1`（bit/XSA provenance；ELF 在 closure HEAD 重建后 SHA 不变）
**原生 conv1 root-cause fix commit**：`48958da0`（历史关键修复点，不再是当前 HEAD）
**板验 PASS 标记**：`ARM_FPGA_DEMO_LENET5_PASS`
**对应 manifest**：`doc/arm-fpga-demo/build_manifest_v2.txt`（记录 closure HEAD、prior bit/XSA build commit 与当前 artifact hash）
**最新 UART capture**：`doc/arm-fpga-demo/uart_capture_20260503_round3_postfix_reverify.txt`
**历史长日志**：`doc/arm-fpga-demo/board_bringup_log_lenet5.txt`

### 12.1 为什么从 Fashion-MNIST 14×14 升级到 LeNet-5

| 维度 | v2 (Fashion 14×14) | v2-conv (LeNet-5 28×28) |
|------|------------------|------------------------|
| 拓扑 | 单 stage（patch_unroller 直进 stage_engine） | 5 层串流：conv1 → conv2 → fc1(flatten) → fc2 → fc3 |
| 输入 | 14×14×1，每像素 8 bit | 28×28×1，每像素 8 bit |
| 卷积核 | 无（直接展开成向量做 FC） | 5×5，stride=1/2，pad=2/0 |
| RTL 增量 | 无 | fmap_sram_v2 / patch_unroller_v2 / flatten_reader_v2 / conv_ctrl_v2 / stage_engine 扩展 |
| ARM 调度 | 一次 stage 配置 + start | 按层 tile-by-tile 握手：WAIT_WEIGHT_REQ → 写 weight → WEIGHT_READY |
| 验证范围 | spike count byte-exact | spike count byte-exact + argmax accuracy 10/10 |

LeNet-5 的目的是**把 V2.B 第一次推到真实 CNN 拓扑**，证明 streamed-stage MAC 能把多层 conv + flatten + fc 串联起来，让 ARM 端可以纯靠 MMIO + tile-mode 调度跑完整张图的端到端推理。

### 12.2 RTL 新增模块（M3.A → M3.C）

来自 commit 序列：`13b87cc7` (M3.A) → `cacb4285` (M3.B) → `30ebada3` (M3.C) → `5ff5264c` (M4 LeNet-5 golden) → `dea06766` (ARM bring-up)。

| 模块 | 文件 | 作用 |
|---|---|---|
| `fmap_sram_v2` | `rtl/snn/fmap_sram_v2.sv` | 双 bank ping-pong feature map SRAM，cur/next 帧分开存 |
| `patch_unroller_v2` | `rtl/snn/patch_unroller_v2.sv` | 把 conv 的 5×5 patch 按行扫描后展平成 stage_engine 期望的向量；支持 stride / pad / 多通道 |
| `flatten_reader_v2` | `rtl/snn/flatten_reader_v2.sv` | flatten 模式下按 row-major (h*W+w)*C+c 顺序把 fmap 平铺出来给 stage_engine |
| `conv_ctrl_v2` | `rtl/snn/conv_ctrl_v2.sv` | conv 层 FSM：扫 (oh, ow) → 触发 patch 取 → 等 stage_engine 完成 → 写回 fmap |
| `stage_engine_v2` 扩展 | `rtl/snn/stage_engine_v2.sv` | 增加 conv tile-mode + flatten tile-mode 入口 |

### 12.3 寄存器扩展

新增寄存器（详见 `fw/include/v2b_soc_regs.h`）：

| 偏移 | 名称 | 关键位段 |
|------|------|---------|
| 0x084 | CONV_MODE_CFG | [0]=EN, [1]=FLATTEN_MODE, [2]=FMAP_PP_SEL, [3]=WEIGHT_TIMEOUT_EN |
| 0x088 | CONV_CFG_HW | [15:0]=H, [31:16]=W |
| 0x08C | CONV_CFG_C | [15:0]=C_in, [31:16]=C_out |
| 0x090 | CONV_CFG_K_S_P | [3:0]=k, [7:4]=stride, [15:8]=pad |
| 0x094 | CONV_CFG_OUT_HW | [15:0]=out_H, [31:16]=out_W |
| 0x098 | CONV_CFG_T | [15:0]=t_count |
| 0x09C | CONV_CFG_TILE | [15:0]=tile_count, [31:16]=last_tile_valid_count |
| 0x0A0 | CONV_CFG_FMAP_BASE | fmap 基地址（word 单位） |
| 0x0A4 | CONV_CFG_OUT_BASE | 输出基地址（word 单位） |
| 0x0A8 | CONV_CTRL | [0]=START W1P, [1]=ABORT W1P, [2]=WEIGHT_READY W1P |
| 0x0AC | CONV_STATUS | [0]=BUSY RO, [1]=DONE W1C, [2]=WEIGHT_REQ RO, [7:4]=ERR RO, [31:8]=cur_h/w/tile RO |
| 0x0B0 | CONV_FMAP_WR_DATA | fmap 预加载写数据 |
| 0x0B4 | CONV_FMAP_WR_ADDR | fmap 写地址（word index） |
| 0x0BC | CONV_FMAP_WR_CTRL | [0]=COMMIT W1P, [1]=AUTO_INC, [2]=TARGET_BANK |

### 12.4 CONV 调度握手协议（ARM 侧）

`fw/src/v2b_conv_scheduler.c` 的 `v2b_run_conv_layer` 实现了如下序列：

```
1. 配置寄存器：
   STAGE_CFG1 = threshold
   STAGE_CFG2 = sum_max
   CONV_CFG_HW / C / K_S_P / OUT_HW / T / TILE / FMAP_BASE / OUT_BASE
   CONV_MODE_CFG = EN | (FLATTEN_MODE if applicable) | (PP_SEL if applicable)

2. 清 DONE：CONV_STATUS = DONE_MASK

3. 启动：CONV_CTRL = START

4. tile-by-tile 握手循环（重复 requests_expected 次）：
   while (!(CONV_STATUS & WEIGHT_REQ));         // 等硬件请求权重
   tile_idx = CONV_STATUS_CUR_TILE(status);     // 读当前 tile id
   v2b_switch_sparse_tile(layer, tile_idx);     // 把 sparse weight 写进 MAC
   CONV_CTRL = WEIGHT_READY;                    // 通知硬件继续

5. 等 DONE：while (!(CONV_STATUS & DONE));
6. 检查 ERR 字段，非 0 则报错
```

**为什么需要 WAIT_WEIGHT_REQ 握手**：V2.B 的 MAC 权重存储区只够装一个 tile（NUM_INPUTS×NUM_OUTPUTS）；多 tile 层（如 fc1 输入维度 12×12×16=2304，需要 9 个 tile）必须在每个 tile 切换前重新装权重。硬件用 WEIGHT_REQ 拉高表示"我下一拍要切到 tile_idx，软件请把对应权重写好后再 WEIGHT_READY"。LeNet-5 的层级 requests_expected：

| 层 | requests_expected | 含义 |
|---|------------------|------|
| conv1 | 28×28 = 784 | 每个 (oh, ow) 像素位置都触发 1 次（单 tile，所以同一个 weight） |
| conv2 | 12×12 = 144 | stride=2 后输出 12×12 像素位置 |
| fc1 | 9 | 9 个 tile 各请求 1 次（input dim 2304 / 256 NUM_INPUTS = 9） |
| fc2 | 0 + 1 stage | 单 tile，走 `v2b_run_fc_stage`（不走 conv 调度） |
| fc3 | 0 + 1 stage | 同上 |

### 12.5 LeNet-5 黄金参考链路

```
gen_convnet_golden.py (Python)
   │ MNIST (60000 train / 10000 test) + seed=20260430
   ▼
ConvNet (PyTorch float)        ← train_proxy_checkpoint，~24 epochs
   │ quantize_signed (4-bit signed [-7, +7])
   ▼
QuantSNNNet / LenetSNNHead      ← train_lenet5_head_checkpoint，~8 epochs
   │ checkpoint = lenet5_snn.pth (quant_snn_test_accuracy=0.9303)
   ▼
run_integer_network             ← bit-exact 整数 SNN 引擎（与 RTL 完全对齐）
   │ 10 个 class-first 样本 → spike counts + intermediate hex
   ▼
results_conv/lenet5/lenet5_golden_manifest.json
   │ + sample_NN_*.hex / *.txt (input fmap / conv1 / conv2 / fc1/2/3 stream + counts)
   ▼
gen_lenet5_header.py            ← 生成 ARM 固件可直接编译进 OCM 的 sparse 权重 + golden samples
   ▼
fw/arm/include/golden_lenet5.h + fw/arm/src/golden_lenet5.c
```

**bit-exact 合约**：

- Python 整数引擎 (`run_integer_network`) 和 RTL 在每一 (sample, layer, t, channel) 上输出相同的 spike bit
- 板上 ARM 跑完后 `counts_buf[0..9]` 与 `golden_lenet5[i].expected_counts` 字节级匹配
- argmax(counts_buf) 与 `golden_lenet5[i].expected_class` 完全一致 → 选定的 10/10 样本全部预测正确

### 12.6 量化与权重稀疏化

- **权重精度**：4-bit signed，范围 `[-7, +7]`（用 `quantize_signed` 把每层最大绝对值映射到 `max_level=7`）
- **存储格式**：每层每 tile 拆成 `pos_hex` + `neg_hex` 两个 256×NUM_OUTPUTS 矩阵；CIM 阵列硬件按"正负通道"分别累加再做差分
- **稀疏化**（仅 ARM 端 OCM 优化）：`gen_lenet5_header.py` 的 `collect_sparse_entries` 把 (lane, out_c, packed) 三元组打包；packed[3:0]=pos[3:0]，packed[7:4]=neg[3:0]；只保留 pos!=0 或 neg!=0 的 entry，跳过零权重，节省 OCM
- 例如 fc1 9 个 tile 全 dense 是 9×256×120×2=552960 bytes，稀疏后通常只剩 ~10-30%（视真实训练后的稀疏度），刚好能塞进 OCM 256 KB

### 12.7 v2 → v2-conv 之间的关键 fix

| Commit | 描述 | 影响 |
|--------|------|------|
| `5beca16b` | "Work around conv1 path for ARM board pass" | 临时把 Python 端 conv1 reference 直接塞进 ARM header（`conv1_ref_all_samples.h`），绕开 conv1 RTL，先确保下游 conv2 / FC 调度路径上板可验证（**已被 48958da0 回滚，不再是当前路径**） |
| `3719c3e7` | "Checkpoint before native conv1 root-cause fix" | 工作中点 checkpoint，保留 work-around 状态；**仅作为 root-cause fix 之前的历史 checkpoint，不再是板验所引用的版本** |
| `48958da0` | "Fix conv fmap preload address increment" | 定位并修复 RTL root cause：`snn_soc_v2b_top.sv` 中 `CONV_FMAP_WR_CTRL.WR_COMMIT` 与 `reg_conv_fmap_wr_addr` 自增同拍发出，导致带 `auto_inc` 的固件 preload 实际写入地址整体错后一格；fix = 把地址递增延后到下一拍 + 在 firmware sparse preload 之前先清目标 bank（避免零词跳写留下旧数据）。同步删除 5beca16b 的 work-around 头文件，回到 native conv1 路径。**已用此版重新 bitgen + ELF link，板上 10/10 native PASS。** |

### 12.7.1 板验路径已统一为 native conv1（commit 48958da0）

| 维度 | 当前板验状态（active branch HEAD = `bf56e942`；LeNet-5 closure/evidence anchor = `d50b7d37`；prior bit/XSA build commit = `537ad3b1`；原生 conv1 root-cause fix = `48958da0`） |
|------|---------------------------------------------|
| conv1 数据来源 | 完全走 RTL（conv_ctrl_v2 + fmap_sram_v2 + patch_unroller_v2） |
| conv2 / FC1-3 | 完全走 RTL（与 conv1 同一调度链） |
| RTL 状态 | fmap auto-inc bug 已修，native 路径完整正确 |
| 板验状态 | ✅ 板上 PASS（10/10 sample 全 native，UART 实抓 ARM_FPGA_DEMO_LENET5_PASS） |
| reference bypass | ❌ 已删除，**没有 reference conv1 bypass，没有 work-around** |

**历史回顾（保留作复盘）**：
- 5beca16b → 3719c3e7 期间存在 work-around 路径（Python 预算 conv1，跳过 conv1 RTL），用于隔离 conv1 RTL bug 与下游 conv2/FC bug，保证下游调度链先有上板证据
- 48958da0 修复 RTL root cause 之后，work-around 头文件 + scheduler 分支被全部回滚；当前分支只剩 native 一条路径
- 论文 / 简历叙事直接引用 native PASS 即可，无需提及 work-around；work-around 仅作为调试日志条目保留

### 12.8 板级证据链

| 项 | 状态 |
|---|------|
| Vivado bitstream / XSA | ✅ `build_manifest_v2.txt` 记录当前 committed artifact hash |
| ARM ELF 链接 + 大小检查 | ✅ `v2b_arm_demo.elf` 已存在且 manifest 已刷新 |
| xsct JTAG 烧写 | ✅ [program_zcu102_c0] CORE_0_RUNNING |
| UART 抓 LeNet-5 PASS marker | ✅ `ARM_FPGA_DEMO_LENET5_PASS`（2026-05-03 round 3 postfix re-verify，capture 见 `uart_capture_20260503_round3_postfix_reverify.txt`） |
| Manifest 文件本体 | ✅ `build_manifest_v2.txt` 已在 closure HEAD `d50b7d37` 刷新；bit/XSA hash 与 prior build commit `537ad3b1` 对齐，ARM ELF rebuild hash 不变 |
| native conv1 路径板验事实 | ✅ 当前 artifact set 重新抓到 10/10 `ARM_FPGA_DEMO_LENET5_PASS` |
| 板验日志 | ✅ 历史长日志 `board_bringup_log_lenet5.txt` + 最新 raw capture `uart_capture_20260503_round3_postfix_reverify.txt` |

### 12.9 仍未做 / 计划但未上板

| 项 | 状态 | 说明 |
|---|------|------|
| CIFAR-10 拓扑（tiny_vgg / plain_cnn4） | 仅 Python + 仿真 cosim | 权重过大，OCM 紧张；本评估周期不上板 |
| 多 sample batch 调度（不重置 fmap SRAM） | 当前每 sample 完整重载 input fmap | 后续可优化，目前 10 sample / batch 总耗时 < 几秒 |
| Cache / MMU 启用 | 未启用，纯 OCM uncached 路径 | Vitis BSP 路线下未来可切，预计 50-100× 吞吐提升 |
| ASIC 路径（chip_top）的 CONV 支持 | 不在 v2-conv scope | 本分支专注 FPGA evidence；ASIC tape-out 仍走 V1 单层路径 |

### 12.10 引用规则

- **论文 / 简历**：引用当前 round 3 evidence commit + `build_manifest_v2.txt` + `uart_capture_20260503_round3_postfix_reverify.txt`；bit/XSA/ELF provenance 以 manifest 当前 hash 为准
- **历史对照**：v2-arm-fpga-demo-v2-passed (Fashion-MNIST 14×14) 仍是合法基线
- **复现命令**：详见 `board_bringup_log_lenet5.txt` 末节

