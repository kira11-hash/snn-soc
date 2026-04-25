# `feature/v2-fpga-e203` — Architecture

**Status**：Phase G3 PASS（2026-04-25）— ZCU102 UART capture shows 10 samples × 10 counts bit-exact and final PASS
**Branch**：`feature/v2-fpga-e203`（起点 `v2` @ `17693e4f`）
**Sibling**：平行线 `main-fpga-e203-alpha`（V1 E203 on ZCU102，已上板 PASS）+ `v2-arm-fpga-demo-passed`（V2.B + ARM host）
**Scope rule**：evidence branch，**不 merge 回 v2，不动 `main*` / `v2-arm-fpga-demo-passed`**。Gate 全绿后 tag `v2-fpga-e203-passed` 封存。

关联 plan：`C:\Users\24201\.claude\plans\d1-d3-idempotent-umbrella.md`（v11）。

---

## 0. Phase 0 Bootstrap Note（对 plan 原文 cherry-pick 步骤的有意偏离）

Plan v11 Phase 0 原文列了 6 个蓝本文件要 cherry-pick 到本分支。实际落地时**有意偏离**如下，属于刻意简化，不是遗漏：

| 蓝本文件（alpha 分支） | 本支线处理方式 |
|---|---|
| `scripts/gen_bram_init.py` | ✅ **checkout 到本分支同路径**（Phase A 固件 → BRAM hex 必用，Phase B synth 之前就要跑起来，必须在树里可直接 `python3 scripts/gen_bram_init.py ...`）|
| `scripts/program_zcu102_e203.tcl` | ❌ 不 checkout。Phase C 上板前按 `fpga_synth/zcu102_v2_e203_demo/...` 新目录结构直接写 `scripts/program_zcu102_v2_e203.tcl`，用 `git show main-fpga-e203-alpha:scripts/program_zcu102_e203.tcl` 读蓝本内容对照 |
| `fpga/boards/zcu102/snn_soc_fpga_top.sv` | ❌ 不 checkout。Phase B 直接新写 `fpga/boards/zcu102_v2_e203/snn_soc_v2b_e203_fpga_top.sv`，蓝本用 `git show` 读 |
| `fpga/boards/zcu102/constraints_e203.xdc` | ❌ 不 checkout。Phase B 直接新写 `fpga/boards/zcu102_v2_e203/constraints_v2_e203.xdc`，蓝本用 `git show` 读 |
| `fpga_synth/zcu102_e203_demo/build_e203_demo.tcl` | ❌ 不 checkout。Phase B 直接新写 `fpga_synth/zcu102_v2_e203_demo/build_v2_e203_demo.tcl`，蓝本用 `git show` 读 |
| `fpga_synth/zcu102_e203_demo/build_e203_demo.sh` | ❌ 不 checkout。Phase B 直接新写 `fpga_synth/zcu102_v2_e203_demo/build_v2_e203_demo.sh`，蓝本用 `git show` 读 |

**理由**：5 个 FPGA/Vivado 蓝本最终要落在新目录（`fpga/boards/zcu102_v2_e203/` 和 `fpga_synth/zcu102_v2_e203_demo/`），换命名（bitstream = `snn_soc_v2b_e203_fpga_top.bit` 不同于 alpha 的 `snn_soc_fpga_top.bit`），删 α' 编程 pad 相关约束。把它们先 checkout 到旧路径 `fpga/boards/zcu102/` 再改名搬家，不如 `git show` 读一次蓝本后直接在新目录里写最终版。`gen_bram_init.py` 例外是因为它是通用工具，不换路径，也不该改内容。

**承诺**：Phase B 开工前，新写的每个 tcl/sh/xdc/sv 都会和对应的 `git show main-fpga-e203-alpha:<path>` 输出逐节比对，任何关键 delta（`-top` 模块名、defines 组合、clock 约束、XDC pad 分配、reset 释放策略）都会在 `doc/v2-fpga-e203/` 里单独记录，防止"凭记忆重写"。

---

## 1. 目标 & 参数口径（**必读**）

### 1.1 目标

把 V2.B streamed-rate multi-layer accelerator（`snn_soc_v2b_top`）与 E203 RISC-V soft-core 集成到 ZCU102 PL，使 CPU 通过 ICB → simple_bus → v2b_bus 两段桥驱动加速器推理，10 样本 Fashion-14×14 bit-exact 对齐 Python golden。

### 1.2 Gate 条件

| Gate | 内容 |
|---|---|
| G1（仿真） | Icarus 快速门禁 9/9 PASS；完整 SoC 100 spike count bit-exact 因 Icarus wall-clock 过长 deferred to G3。保留 `run_fw_cosim_resident_14x14.sh` 作为直接驱动 V2B baseline bit-exact 证据。 |
| G2（综合） | **PASS**：ZCU102 @ 50 MHz WNS `4.837 ns`，LUT/FF/BRAM < 50%，bitgen OK。bitstream: `fpga_synth/zcu102_v2_e203_demo/out/snn_soc_v2b_e203_fpga_top.bit` |
| G3（上板） | **PASS**：CP2108 J83 PuTTY capture shows `FPGA_V2_E203_BOOT_UART_PASS`, 10 sample count lines, and `FPGA_V2_E203_MULTILAYER_INFER_PASS`; firmware self-checks 100 spike counts against Python golden before printing final PASS. |

### 1.3 参数口径分离（CLAUDE.md 硬约束的正确解读）

CLAUDE.md 里冻结的 **V1 tape-out params**（`NUM_INPUTS=64, ADC_BITS=8, THRESHOLD=2550` 等）是 **V1 `snn_soc_top` 专有口径**，与 V2.B 并存但不共用。本支线属 V2.B 路线，**只使用 V2B_\* 和 V2E203_\* 常量**，不读 V1 前缀常量。

| 集合 | 用于 | 常量 |
|---|---|---|
| **V1 frozen**（不动） | `snn_soc_top` / V1 TB / V1 固件 | `NUM_INPUTS=64`, `ADC_BITS=8`, `ADC_CHANNELS=20`, `TIMESTEPS_DEFAULT=10`, `THRESHOLD_DEFAULT=2550`, `NEURON_DATA_WIDTH=9`, `INSTR_SRAM_BYTES=0x4000`, `DATA_SRAM_BYTES=0x4000` |
| **V2.B compile-time max**（硬件宽度，`snn_soc_pkg.sv:263-271`） | `snn_soc_v2b_top` / `stage_engine_v2` / V2 parity TB | `V2B_NUM_INPUTS=256`, `V2B_MAX_OUT_NEURONS=128`, `V2B_MAX_TIMESTEPS=256`, `V2B_ADC_BITS=10`, `V2B_PARTIAL_WIDTH=14` |
| **V2.B Fashion-14×14 runtime**（`v2b_scheduler.c:27-38` 传参） | 本支线 10-样本 smoke | `S0_IN_DIM=196, S0_OUT_DIM=64, S0_THRESHOLD=16, S0_SUM_MAX=2940`；`S1_IN_DIM=64, S1_OUT_DIM=10, S1_THRESHOLD=8, S1_SUM_MAX=960`；`T_COUNT=64` |
| **V2E203 FPGA 支线专用**（本支线 additive）| `snn_soc_v2b_e203_top` + 桥 + TB + 固件 | `V2E203_INSTR_BYTES=0x10000` (64 KB), `V2E203_DATA_BYTES=0x2000` (8 KB), `ADDR_V2B_BASE=0xA000_0000`, `ADDR_V2B_END=0xA000_0FFF`, `ADDR_V2E203_UART_BASE=0x0002_0000`, `ADDR_V2E203_UART_END=0x0002_00FF` |

### 1.4 严格纪律（grep-enforceable）

新 RTL/TB/固件**禁止**引用 V1 前缀常量（含 `INSTR_SRAM_BYTES`, `DATA_SRAM_BYTES`, `ADDR_INSTR_BASE`, `ADDR_DATA_BASE`, `ADDR_REG_BASE`, `ADDR_UART_BASE`, `NUM_INPUTS`, `ADC_BITS`, `THRESHOLD_DEFAULT`, `NEURON_DATA_WIDTH`）；新固件**绝不** include `fw/include/soc_regs.h`。Phase A 末段跑 grep check（见 plan R15/R16/R17）兜底。

---

## 2. 顶层框图

```
┌─────────────── snn_soc_v2b_e203_fpga_top（板级 wrapper，ZCU102 pad）──────────────┐
│  sys_clk_p/n (AL8/AL7, 300 MHz diff) ──► IBUFDS ──► MMCME4_ADV ──► BUFG ──► clk_50m │
│  btn_rst (AM13) ──► 2-FF rst sync + mmcm_locked gating ──► rst_n                     │
│  LED[3:0] (AG14/AF13/AE13/AJ14)  ← heartbeat / mmcm_locked / rst_n / spare           │
│  uart_txd/rxd (F13/E13, LVCMOS18, CP2108 Ch2)                                        │
│                                                                                      │
│  ┌───────────────── snn_soc_v2b_e203_top（SoC core，纯 RTL）─────────────────┐      │
│  │                                                                           │      │
│  │  ┌──────────── e203_min_wrap ─────────────┐                               │      │
│  │  │ E203 RISC-V core + 5-ch ICB export     │                               │      │
│  │  │ (只用 mem_icb，其余 ppi/clint/plic/fio  │                               │      │
│  │  │  挂 icb_err_slave)                      │                               │      │
│  │  └──────────────┬──────────────────────────┘                               │      │
│  │                 │ mem_icb                                                 │      │
│  │                 ▼                                                          │      │
│  │  ┌──────── icb2simple_bridge_v2b ────────┐  白名单：                       │      │
│  │  │ ICB → simple_bus                       │  V2E203_INSTR(0x0~0xFFFF)       │      │
│  │  │ 3-state FSM                            │  V2E203_DATA (0x10000~0x11FFF)  │      │
│  │  │ 非白名单地址 → rsp_err=1               │  V2E203_UART (0x20000~...00FF)  │      │
│  │  └──────────────┬──────────────────────────┘  V2B (0xA0000000~...0FFF)     │      │
│  │                 │ simple_bus                                              │      │
│  │                 ▼                                                          │      │
│  │  ┌────────────── bus_interconnect_v2_e203 ───────────────┐                │      │
│  │  │ 新 fabric（NOT 复用 V1 bus_interconnect，它是固定     │                │      │
│  │  │ 1-cycle，与 adapter 2-cycle 读不兼容）                │                │      │
│  │  │ - INSTR/DATA/UART 路径：req 寄存 + 1-cycle rdata       │                │      │
│  │  │ - V2B 路径：透传 m_valid 给 adapter，等 m_ready/m_rvalid │              │      │
│  │  └──┬───────┬───────┬──────────────────┬───────────────────┘              │      │
│  │     │       │       │                  │                                  │      │
│  │     ▼       ▼       ▼                  ▼                                  │      │
│  │  INSTR_SRAM  DATA_SRAM  uart_ctrl    simple2v2btop_adapter                │      │
│  │  (64 KB,    (8 KB,     (V1 复用)      (v2-arm-fpga-demo-passed 拷入)       │      │
│  │   sram_     sram_                    4-state FSM，q_* latch 保            │      │
│  │   simple,   simple,                  cmd_addr 稳定；读 2 cycle            │      │
│  │   $readmemh  uninit                  固定延迟；写 1 cycle)                │      │
│  │   BRAM init)                              │                              │      │
│  │                                           ▼                              │      │
│  │                               ┌──── snn_soc_v2b_top ────┐                │      │
│  │                               │ V2.B multi-layer SoC    │                │      │
│  │                               │ (v2 分支原件，0 改)      │                │      │
│  │                               │ - stage_engine_v2        │                │      │
│  │                               │ - cim_mac_behavioral_v2  │                │      │
│  │                               │ - stream_buffer_v2 A/B   │                │      │
│  │                               │ - input_stream_sram      │                │      │
│  │                               │ - tile_partial_buf       │                │      │
│  │                               └──────────────────────────┘                │      │
│  └───────────────────────────────────────────────────────────────────────────┘      │
└───────────────────────────────────────────────────────────────────────────────────┘
```

### 2.1 数据流

1. **Boot**：E203 从 INSTR_SRAM @ `0x0000_0000` 取指，执行 `crt0_v2_e203.S`（设 sp=__stack_top、清 bss、跳 main）
2. **smoke 固件**：`v2_e203_smoke_main.c` 初始化 UART → 清 DMEM buffers → 写 BUFFER_PTR + BOOT_MARK → 通过 V2B MMIO 装权重 → 10 样本循环（CPU encode → push input_stream → run stage0/1 → read SBB counts）→ 写 INFER_DONE_MARK
3. **TB 侧**：轮询 MARKER_BASE 四个 word，读 BUFFER_PTR 解引用 buffer，对比 Python golden

### 2.2 延迟预算

| 阶段 | cycle |
|---|---|
| E203 LSU 发起 mem_icb | 1 |
| `icb2simple_bridge_v2b` IDLE→WAIT | 1 |
| fabric 透传 | 0（组合）|
| `simple2v2btop_adapter` IDLE→RD_WAIT→RD_DONE | 2 |
| 回传 rsp | 1 |
| **读 round-trip** | **~5 cycle @ 50 MHz = 100 ns** |

V2.B 单样本推理 ≈ 200 µs。poll BUSY 一次 100 ns，开销 < 0.1%。

---

## 3. 决策落地（用户 + GPT 10 轮冷审通过）

| ID | 决策 | 理由摘要 |
|---|---|---|
| **D1** | 方案 α：两段桥串联（ICB → simple_bus → v2b_bus） | V2B bus 本质是 simple_bus+12-bit addr；adapter 已修 3 个时序坑（rsp_valid 语义、SBA/SBB 2 拍、cmd_addr 保持）；总读 RT ~5 cycle |
| **D3** | Option A-full：port `v2b_scheduler.c` 到 E203，一次跑 10 样本 | 最大复用 portable C；CPU 在线跑 Bresenham 和 arm-demo 一致 |
| **UART** | CP2108 J83 Ch2（F13/E13, LVCMOS18） | alpha 已调通，无需外接 USB-TTL |
| **IMEM** | 64 KB（本支线 `V2E203_INSTR_BYTES`） | 权重表 25.8 KB + text ~6 KB + golden 2.4 KB + 余量 30 KB；V1 main 流片线 16 KB 不动（V1 权重预烧 CIM，不经 MAC_W_LOAD） |
| **DMEM** | 8 KB（本支线 `V2E203_DATA_BYTES`） | bss 4.1 KB + stack 3 KB + marker 256 B + .smoke_bufs 464 B ≈ 7.9 KB，余 264 B（linker ASSERT 兜底）|
| **V2B_SOC_BASE** | `0xA000_0000` | 与 arm-demo 源码对称（非 binary 可换）|
| **UART_BASE** | `0x0002_0000`（新） | 避开 V1 0x4000_0200，同时避开 E203 CLINT `0x0200_0000..0x0200_FFFF`；必须落在 `mem_icb` 可达区 |
| **MARKER_BASE** | `ORIGIN(DMEM)+LENGTH(DMEM)-0x100 = 0x0001_1F00`（linker `__marker_base`）| 6 word layout：BOOT/INFER_DONE/ENCODER_DONE + 3 个 BUFFER_PTR |
| **STACK_TOP** | `__marker_base-4 = 0x0001_1EFC`（linker `__stack_top`）| 3 KB reserve (`__stack_reserve=0xC00`)，ASSERT 兜底 |
| **Gate C 判据** | 10 × 10 = 100 spike count 全部 bit-exact | 叙事 "firmware→RTL bit-exact"，不放宽到 ±1 |
| **Stream 编码** | E203 CPU 在线 `v2b_encode_pixel_even_rate` | 与 arm-demo 一致，rodata 每样本仅 196 B |
| **固件双 build** | smoke + encoder 两个 ELF（linker script 独立）| 匹配 smoke TB 和 encoder parity TB 两种 DMEM 布局；`-Wl,--gc-sections` 让 encoder ELF 裁掉未用函数 |
| **bitstream 产物隔离** | smoke → `out/...bit`；encoder → `out_encoder/...bit`，文件名相同 | alpha 蓝本脚本只有 `HEX=/OUT_DIR=/SKIP_FW=` 入口，无 bitstream 名入口 |

### 3.1 Marker 常量（具体数值）

| 地址 | 名称 | 值 |
|---|---|---|
| `__marker_base+0x00` | `V2E203_BOOT_MARK` | `0xB007_0001u` |
| `__marker_base+0x04` | `V2E203_INFER_DONE_MARK` | `0x1F4E_D001u` |
| `__marker_base+0x08` | `V2E203_ENCODER_DONE_MARK` | `0x31C0_D001u` |
| `__marker_base+0x0C` | `BUFFER_PTR_0` | 运行时填入（smoke: `&__smoke_counts_base`；encoder: `&__encoder_stream_base`）|
| `__marker_base+0x10` | `BUFFER_PTR_1` | 运行时填入（smoke: `&__sample_done_flags`；encoder: `&__encoder_sample_req`）|
| `__marker_base+0x14` | `BUFFER_PTR_2` | 运行时填入（encoder: `&__encoder_sample_done`）|

### 3.2 Risk Hotlist（完整见 plan §风险清单）

- **R10**：新 fabric 解决 V1 `bus_interconnect.sv` 固定 1-cycle 不兼容 adapter 2-cycle
- **R11**：新 bridge 白名单只允 V2E203_* 3 段 + V2B，避免 V1 MMIO 低 12-bit 别名进 V2B
- **R13/R18**：DMEM 8 KB + linker 符号驱动 buffer + ASSERT + BUFFER_PTR 运行时发布，避免 .bss 与 buffer 重叠
- **R15/R16/R17**：grep 守卫防止新文件偷用 V1 常量或 include V1 soc_regs.h
- **R14**（技术债）：`simple2v2btop_adapter` 忽略 `cmd_ready`/`rsp_valid`，依赖单 outstanding + 固定延迟假设。本支线不修，V2 tape-out 时再审。

### 3.3 Adapter 拷入合约（Phase A-3）

`rtl/bus/simple2v2btop_adapter.sv` 是从 `v2-arm-fpga-demo-passed` 0 字改拷入的原件。文件头仍保留 ARM demo/`axi2simple_bridge` 语境，这是为了保持 byte-exact，不代表本支线继续使用 ARM host 或 AXI path。本支线的实际上游是 `bus_interconnect_v2_e203` 的 V2B simple_bus 端口。

使用前置条件必须写死：上游只能发 single outstanding、single-pulse `m_valid` 事务；adapter 在 `ADP_IDLE && m_valid` 同拍采样 `m_addr/m_write/m_wdata/m_wstrb`，随后靠 `q_*` 保持 `cmd_addr`，覆盖 direct-reg read 与 SBA/SBB delayed read。若未来上游改成 hold-valid 或 pipeline 多 outstanding，必须先重审 adapter FSM 和 R14 技术债。

---

## 4. Phase A/B Evidence Snapshot

### 4.1 Phase A 快速门禁

| Script | Result |
|---|---|
| `run_multilayer.sh` | `MULTILAYER_SMOKE_PASS` |
| `run_fw_cosim_resident_14x14.sh` | `FW_COSIM_RESIDENT_14X14_TB_PASS` |
| `run_bus_interconnect_v2_e203.sh` | `BUS_INTERCONNECT_V2_E203_PASS` |
| `run_icb2simple_bridge_v2b.sh` | `ICB2SIMPLE_BRIDGE_V2B_PASS` |
| `run_simple2v2btop_adapter.sh` | `SIMPLE2V2BTOP_ADAPTER_PASS` |
| `run_v2_e203_bus_chain_tb.sh` | `V2_E203_BUS_CHAIN_PASS` |
| `run_v2_e203_soc_compile.sh` | `V2_E203_SOC_COMPILE_PASS` |
| `run_v2_e203_encoder_parity.sh` | `V2_E203_ENCODER_PARITY_PASS` |
| `run_v2_e203_cosim.sh` | `V2_E203_COSIM_PASS` |

Known deviation: `run_v2_e203_cosim.sh` proves BOOT marker, BUFFER_PTR, UART boot tag, PC entering sample/scheduler loop, and CLINT zero-activity guard. It does not complete 10-sample inference under Icarus; 100-count bit-exact is G3 board evidence.

### 4.2 Phase B Gate

Command:

```bash
bash fpga_synth/zcu102_v2_e203_demo/build_v2_e203_demo.sh
```

Results:

| Item | Result |
|---|---|
| Bitstream | `fpga_synth/zcu102_v2_e203_demo/out/snn_soc_v2b_e203_fpga_top.bit` |
| Timing | WNS `4.837 ns`, TNS `0.000`, WHS `0.012`; all user timing constraints met |
| Route | fully routed; routing errors `0` |
| Utilization | CLB LUTs `21.59%`, CLB registers `2.51%`, BRAM tile `10.53%`, DSP `0.08%` |
| DRC | 0 errors; warnings are DSP pipeline suggestions and E203 internal no-load nets |

### 4.3 Phase G3 Board Evidence

Full UART log is recorded in `doc/v2-fpga-e203/board_bringup_log.txt`.

Observed result:

```text
FPGA_V2_E203_BOOT_UART_PASS
sample 00 counts=[63 0 0 34 0 0 0 0 0 0]
sample 01 counts=[0 63 0 0 1 0 0 0 0 0]
sample 02 counts=[0 0 61 0 1 0 0 0 0 0]
sample 03 counts=[0 0 0 63 0 0 0 4 0 0]
sample 04 counts=[0 0 0 0 63 0 1 0 0 0]
sample 05 counts=[1 1 0 0 0 63 0 63 0 0]
sample 06 counts=[0 0 0 0 0 11 6 0 0 0]
sample 07 counts=[0 0 0 0 0 0 0 63 0 0]
sample 08 counts=[0 0 0 0 0 6 0 0 63 0]
sample 09 counts=[0 0 0 0 0 63 0 0 62 7]
FPGA_V2_E203_MULTILAYER_INFER_PASS
```

The final PASS string is printed only after firmware compares all 100 spike counts with `golden_fashion10.expected_counts`.

## 5. Phase D — 封存

**状态：CLOSED 2026-04-25**

| 项 | 值 |
|---|---|
| Tag | `v2-fpga-e203-passed` |
| 封存 commit | `1620ccda725396372c72a98a0fd3567f9cab5e86` |
| Bitstream SHA256 | `e5ae7936064d299b6e427ff98252aa53f3684ef3dc12c6de6e2a9b9dae6234e5` |
| smoke.hex SHA256 | `c2b2fb17968c45d8bc69293670d58070c917b21201370debab16337fa3a4dca7` |
| encoder.hex SHA256 | `83fb301c81b3606b3f4b66be51265119a4537ab41ef0fcdfb4abf5e20d210513` |
| Vivado | v2022.2 (win64) Build 3671981 |
| FW toolchain | riscv64-unknown-elf-gcc 13.2.0 |
| Gate G1 sim | 9/9 PASS（其中 `run_v2_e203_encoder_parity.sh` 在 `SIM_FAST=1` 下验证 RPC/marker parity；stream bit-exact deferred to G3 board evidence） |
| Gate G2 synth | WNS 4.837 ns @ 50 MHz, LUT 21.59%, BRAM 10.53%, DSP 0.08%, DRC 0 error |
| Gate G3 board | 100/100 spike count bit-exact，单次烧板即得 `MULTILAYER_INFER_PASS` |

完整 UART log + 板上 vs Python golden 逐样本比对 → `doc/v2-fpga-e203/board_bringup_log.txt`。

### Scope rule 复述（不变）

- 本支线 **不 merge 回 `v2`**；引用必须 pin 到 tag `v2-fpga-e203-passed` 或 commit `1620ccda`。
- 不动 `main` / `main-fpga-e203-alpha` / `v2-arm-fpga-demo-passed`。
- V1 流片（main）的 16 KB IMEM / V1 frozen 参数集**未受任何影响**——本支线纯 additive，硬件预算独立（FPGA BRAM）。

### Paper / 简历表述参考

> An E203 RISC-V soft-core was integrated into the V2.B multi-layer SNN
> SoC (`snn_soc_v2b_top`) on a ZCU102 (XCZU9EG @ 50 MHz). Firmware compiled
> from `fw/v2_e203_smoke/` was preloaded into 64 KB BRAM IMEM via Vivado
> `$readmemh`. The CPU drove on-PL CIM-array inference end-to-end
> (per-sample Bresenham encoder, weight install via MMIO, two-stage CIM
> MAC dispatch, stream-buffer ping-pong, LIF neuron firing, count read
> back). UART captured the 10-sample Fashion-14×14 result on a single
> programming pass; **all 100 per-class spike counts matched the Python
> golden bit-exactly**. This validates the firmware-to-RTL integration
> path that the future tape-out version will reuse.
