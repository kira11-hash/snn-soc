# feature/v2-arm-fpga-demo — Architecture

**Status**: Phase A (仿真 + RTL wrapper) 已通过所有 gate。Phase B（ARM firmware build）/ Phase C0–C1（ZCU102 板上验证）尚未开始。
**Scope rule**: evidence branch，**不 merge 回 v2，不 touch main**，**不修改 V2.B accelerator datapath / cmd-rsp 合约**。本 doc 只覆盖 Phase A 的 RTL wrapper 与 cosim TB 产出。

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

## 8. 下一步（Phase B / C 预告，未启动）

- Phase B：Vitis standalone BSP + `fw/arm/src/arm_main.c` + golden C header generator
  - 预置 check：`which vitis && which aarch64-none-elf-gcc` — 不可用时停下通知 Qingan
  - Boot-once weight load vs per-sample weight load 作为 runtime 选择；两者都编译通过
- Phase C0：`fpga_synth/zcu102_arm_demo.tcl` + bitgen + xsct program → UART 看 `ARM_FPGA_DEMO_ACCEL_FASHION10_PASS`
- Phase C1：同 bitstream，换 elf → UART 看 `ARM_FPGA_DEMO_SCHEDULER_FASHION10_PASS`
- Paper wording 当前等级：`V2.B has achieved Python/RTL/firmware-scheduler co-simulation parity. An ARM-hosted ZCU102 FPGA artifact is under development.` — C0/C1 过后按 plan §8 升级。
