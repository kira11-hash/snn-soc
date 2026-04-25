# ASIC Pad Map Freeze

## Purpose

This document is the canonical in-repo source of truth for the current ASIC pad plan.

- Scope: ASIC mainline only
- Physical intent: full **55-pad** package view (expanded from 48 on 2026-04-24 to accommodate the external programming contract — see V1 freeze notes below)
- Current RTL status: [`rtl/top/chip_top.sv`](../rtl/top/chip_top.sv) now routes the digital core signals (including the 7 new programming-interface signals) to the documented pad-facing ports, but still does not instantiate technology-specific pad cells
- Counting rule:
  - **55 pads total**
  - **52 usable pads**
  - 3 `ESD-reserved` pads
  - The 52 usable pads are split into **46 functional signal pads** (39 original + **7 external programming**) + 6 power/ground pads

## Notes

- Pad index order below is the frozen documentation order for interface planning and cross-team review. It is not yet a final physical pad-ring placement order.
- `default/reset behavior` describes the current repository behavior and reset expectation. Where `chip_top.sv` still lacks technology-specific pad-cell implementation, that is called out explicitly.
- This **55-pad freeze** documents the currently frozen digital-chip pad contract. It covers **both** the external inference interface (pads 19..45, frozen 2026-03-16) **and** the external programming interface (pads 46..52, frozen 2026-04-24, scheme α').
- **External programming contract (scheme α', 2026-04-24)**:
  - 7 new pads carry `prog_op[2:0]` (D→A op encoding) + `prog_level[3:0]` (D→A target conductance level).
  - `cim_start`, `cim_done`, `wl_data / wl_group_sel / wl_latch`, `bl_sel`, `bl_data` are **shared** between inference and programming — analog side looks at `prog_op` to disambiguate.
  - The verify pass/fail decision is made by the **digital side** (`cim_program_ctrl` compares `bl_data` against `prog_level * (256/16) ± 2`), so **no** `prog_pass` A→D pad is required.
  - Noise implication: if analog+ADC RMS noise is about **1 LSB**, single-shot verify pass rate under the fixed `±2 LSB` window is only about 95%; for near-3σ single-shot margin, target roughly **≤ 0.67 LSB RMS**.
- Full protocol details (encoding table, timing, electrical): `doc/08_cim_analog_interface.md` §10 + `doc/03_cim_if_protocol.md` §Programming.
- Current digital RTL status (2026-04-24 final): all seven new sideband pads
  (`prog_op[2:0]`, `prog_level[3:0]`) are routed through `snn_soc_top` and
  `chip_top`, **and** the shared carrier pads (`wl_data`, `wl_group_sel`,
  `wl_latch`, `cim_start`, `bl_sel`) are fully switched to the programming
  path when `prog_busy=1`. The Q1 LEVEL-gate / Q2 phase-aligned /
  Q3 verify-timing contracts are locked in `doc/08` §10 and covered by
  regressions `PROG_WL_PAD_ROUTE_TB_PASS` + `PROG_PAD_ENCODER_TB_PASS`.
  - `prog_op_ext` / `prog_level_ext` carry a 10-stage pipeline delay so
    they are phase-aligned with `cim_start_ext` — analog side can safely
    latch on `cim_start` rising edge.
  - `cim_start_ext` is a **LEVEL-hold pulse gate** during `prog_busy=1`
    (not a 1-cycle strobe) — analog side drives pulse / read-voltage
    while `cim_start=1` and withdraws on the falling edge.
- `expected signal owner`:
  - `digital direct` means the current RTL already drives or receives the signal at `snn_soc_top`
  - `chip_top routed wrapper` means the signal is already exposed at [`rtl/top/chip_top.sv`](../rtl/top/chip_top.sv), but still not backed by technology pad cells
- JTAG remains 4-wire only in the current pad freeze. There is no dedicated `TRST_n` pad.
- `clk` and `rst_n` are **PCB-shared inputs**, not digital-to-analog forwarded outputs. The board shall fan out one 50 MHz clock source and one supervisor/reset source to both the digital die and the analog die. There is no digital-side `clk_out` / `rst_out` pad and no digital-side duty-cycle reshaper.
- If the analog die needs an internal ~40/60 duty cycle, that duty reshape belongs inside the analog die (DCC/local clock shaping). The digital pad contract remains a conventional 50 MHz input clock.

## PCB Reference BOM（PCB 设计提醒，2026-04-25）

> 这条是给后续画 PCB 的同学的硬提醒，画板时直接照下面的拓扑放器件即可。最终 SI / 端接策略仍以 `doc/11` P0-10 的 PCB stackup + field solver 提取为准。

**时钟分发**：

```
PCB 板上 50 MHz 标准晶振 / oscillator (标称 50/50 占空比)
        │
        ├──走线──→ 数字 die  pad 01  `clk`     (方向 in)
        └──走线──→ 模拟 die        `clk_in`   (方向 in)
```

- 推荐器件：50 MHz CMOS oscillator（如 SiT8008 / ASEMB / 等通用型号）
- 输出**并行驱动**两 die，**不经过数字 die 转发**
- 数字 die 不提供 `clk_out`，不做 buffer / reshape
- 走线 layout target：chip-to-chip skew ≤ 0.5 ns（FR-4 典型 60-70 ps/cm，约 7 cm 量级走线差）；最终以 PCB stackup + 仿真签核
- 如模拟 die 需要 ~40/60 占空比，由模拟 die 内部 DCC 自行 shape（见 `doc/11` P0-8）

**复位分发**：

```
PCB supervisor IC (例如带 /MR 的 MAX809-class / TPS3839-class 器件)
        │  +  PCB 手动复位按钮 (优先接 supervisor /MR；或采用 open-drain / wired-OR reset)
        │
        ├──走线──→ 数字 die  pad 02  `rst_n`   (方向 in，低有效)
        └──走线──→ 模拟 die        `rst_n`    (方向 in，低有效)
```

- 推荐器件：MAX809-class / LM809-class / TPS3839-class 等 power-on reset supervisor，监测 VDD 上电 + 提供 ≥ 100 ms 的 reset hold time；优先选择带 manual-reset input (`/MR`) 或 open-drain reset 输出的型号
- 手动按钮（可选）：优先接 supervisor `/MR` 输入；若必须直接拉低 `rst_n` 总线，应使用 open-drain / wired-OR 拓扑。不要用按钮硬拉一个 push-pull supervisor 输出，否则按键时可能与 supervisor 高电平驱动短暂冲突
- 输出**并行驱动**两 die，**不经过数字 die 转发**
- 数字 die 不提供 `rst_out`
- 模拟 die 自己负责 reset deassert 同步与 bias / ADC / DCC ready time（见 `doc/11` P0-9）

**关键不变量（画板时不要违反）**：
1. 数字 die `clk` (pad 01) 与模拟 die `clk_in` 必须接同一组 PCB clock source 输出
2. 数字 die `rst_n` (pad 02) 与模拟 die `rst_n` 必须接同一组 supervisor 输出
3. 不要在 PCB 上做"数字 die → 模拟 die 的 clock buffer / reset 同步链"（这种拓扑会引入额外 skew + jitter，且和当前 pad 表不一致——数字 die 没有这种 output pad）
4. 占空比/duty 整形不在 PCB 上做（除非未来要切到带可编程时钟管理 IC 的方案，需重新评估 BOM）

## Full 55-Pad Table

| Pad | Name | Function | Dir | Class | Default / Reset Behavior | Notes |
|---|---|---|---|---|---|---|
| 01 | `clk` | System reference clock | in | signal | External PCB clock source drives; no internal default | PCB shared with analog die `clk_in`; routed to `snn_soc_top.clk`; no digital-side forwarding / reshape |
| 02 | `rst_n` | Active-low reset | in | signal | PCB supervisor/reset source holds low during reset entry, releases high for normal run | PCB shared with analog die `rst_n`; routed to `snn_soc_top.rst_n`; no digital-side reset forwarding |
| 03 | `uart_tx` | UART TX | out | signal | `uart_ctrl` drives idle high (`1`) after reset and emits 8N1 TX frames when active | Current source: `uart_ctrl.sv` |
| 04 | `uart_rx` | UART RX | in | signal | External source drives; current V1 mainline has RX path reserved but not yet consumed by logic | Current sink: `uart_ctrl.sv` |
| 05 | `spi_cs_n` | SPI chip select | out | signal | `spi_ctrl` drives high (`1`) after reset; software may force low during transaction | Current source: `spi_ctrl.sv` |
| 06 | `spi_sck` | SPI clock | out | signal | `spi_ctrl` drives low (`0`) when idle and toggles during active transfers | Current source: `spi_ctrl.sv` |
| 07 | `spi_mosi` | SPI MOSI | out | signal | `spi_ctrl` drives low (`0`) when idle and shifts TX data during active transfers | Current source: `spi_ctrl.sv` |
| 08 | `spi_miso` | SPI MISO | in | signal | External source drives; current logic samples it during active SPI transfers | Current sink: `spi_ctrl.sv` |
| 09 | `jtag_tck` | JTAG clock | in | signal | External source drives rescue TAP clock; no dedicated `TRST_n` companion pad | Current sink: `jtag_mem_loader.sv` |
| 10 | `jtag_tms` | JTAG mode select | in | signal | External source drives rescue TAP state transitions | Current sink: `jtag_mem_loader.sv` |
| 11 | `jtag_tdi` | JTAG data in | in | signal | External source shifts `IDCODE/MEMACC/CPUCTL` payloads LSB-first | Current sink: `jtag_mem_loader.sv` |
| 12 | `jtag_tdo` | JTAG data out | out | signal | Rescue TAP shifts out `IDCODE/MEMACC/CPUCTL` responses | Current source: `jtag_mem_loader.sv` |
| 13 | `VDDCORE0` | Core supply | inout | power | Power pad; no logic reset state | One of two core VDD pads |
| 14 | `VSSCORE0` | Core ground | inout | power | Ground pad; no logic reset state | One of two core VSS pads |
| 15 | `VDDCORE1` | Core supply | inout | power | Power pad; no logic reset state | One of two core VDD pads |
| 16 | `VSSCORE1` | Core ground | inout | power | Ground pad; no logic reset state | One of two core VSS pads |
| 17 | `VDDIO` | IO supply | inout | power | Power pad; no logic reset state | Shared digital IO supply |
| 18 | `VSSIO` | IO ground | inout | power | Ground pad; no logic reset state | Shared digital IO ground |
| 19 | `wl_data[0]` | WL mux data bit 0 | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `wl_mux_wrapper` path |
| 20 | `wl_data[1]` | WL mux data bit 1 | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `wl_mux_wrapper` path |
| 21 | `wl_data[2]` | WL mux data bit 2 | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `wl_mux_wrapper` path |
| 22 | `wl_data[3]` | WL mux data bit 3 | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `wl_mux_wrapper` path |
| 23 | `wl_data[4]` | WL mux data bit 4 | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `wl_mux_wrapper` path |
| 24 | `wl_data[5]` | WL mux data bit 5 | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `wl_mux_wrapper` path |
| 25 | `wl_data[6]` | WL mux data bit 6 | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `wl_mux_wrapper` path |
| 26 | `wl_data[7]` | WL mux data bit 7 | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `wl_mux_wrapper` path |
| 27 | `wl_group_sel[0]` | WL mux group select bit 0 | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `wl_mux_wrapper` path |
| 28 | `wl_group_sel[1]` | WL mux group select bit 1 | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `wl_mux_wrapper` path |
| 29 | `wl_group_sel[2]` | WL mux group select bit 2 | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `wl_mux_wrapper` path |
| 30 | `wl_latch` | WL mux latch pulse | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `wl_mux_wrapper` path |
| 31 | `cim_start` | CIM transaction start pulse | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `cim_array_ctrl` |
| 32 | `cim_done` | CIM transaction done pulse | in | signal | External analog side drives and feeds `snn_soc_top` external CIM interface | Current sink: chip-level external CIM input |
| 33 | `bl_sel[0]` | BL readback select bit 0 | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `adc_ctrl` |
| 34 | `bl_sel[1]` | BL readback select bit 1 | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `adc_ctrl` |
| 35 | `bl_sel[2]` | BL readback select bit 2 | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `adc_ctrl` |
| 36 | `bl_sel[3]` | BL readback select bit 3 | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `adc_ctrl` |
| 37 | `bl_sel[4]` | BL readback select bit 4 | out | signal | Driven from `snn_soc_top` external CIM interface | Current source: `adc_ctrl` |
| 38 | `bl_data[0]` | BL readback data bit 0 | in | signal | External analog side drives and feeds `snn_soc_top` external CIM interface | Current sink: chip-level external CIM input |
| 39 | `bl_data[1]` | BL readback data bit 1 | in | signal | External analog side drives and feeds `snn_soc_top` external CIM interface | Current sink: chip-level external CIM input |
| 40 | `bl_data[2]` | BL readback data bit 2 | in | signal | External analog side drives and feeds `snn_soc_top` external CIM interface | Current sink: chip-level external CIM input |
| 41 | `bl_data[3]` | BL readback data bit 3 | in | signal | External analog side drives and feeds `snn_soc_top` external CIM interface | Current sink: chip-level external CIM input |
| 42 | `bl_data[4]` | BL readback data bit 4 | in | signal | External analog side drives and feeds `snn_soc_top` external CIM interface | Current sink: chip-level external CIM input |
| 43 | `bl_data[5]` | BL readback data bit 5 | in | signal | External analog side drives and feeds `snn_soc_top` external CIM interface | Current sink: chip-level external CIM input |
| 44 | `bl_data[6]` | BL readback data bit 6 | in | signal | External analog side drives and feeds `snn_soc_top` external CIM interface | Current sink: chip-level external CIM input |
| 45 | `bl_data[7]` | BL readback data bit 7 | in | signal | External analog side drives and feeds `snn_soc_top` external CIM interface | Current sink: chip-level external CIM input |
| 46 | `prog_op[0]` | External programming op bit 0 | out | signal | Driven from `snn_soc_top.prog_op_ext`. See §Programming below for encoding. | Current source: `snn_soc_top` encoder from `cim_program_ctrl` + `reg_bank`. Added 2026-04-24. |
| 47 | `prog_op[1]` | External programming op bit 1 | out | signal | Driven from `snn_soc_top.prog_op_ext` | Same source as pad 46 |
| 48 | `prog_op[2]` | External programming op bit 2 | out | signal | Driven from `snn_soc_top.prog_op_ext` | Same source as pad 46 |
| 49 | `prog_level[0]` | External programming target level bit 0 | out | signal | Driven from `snn_soc_top.prog_level_ext` (sourced from `reg_bank.PROG_CTRL[7:4]` through a 10-stage shift register that phase-aligns with `cim_start_ext`; in-flight writes to `PROG_CTRL.LEVEL` while `prog_busy=1` are blocked by reg_bank — see `doc/02_reg_map.md` PROG_CTRL footnote ¹). Valid only when `prog_op==010` (write). | Current source: `reg_bank` prog_level → 10-stage pipeline in `snn_soc_top`. Added 2026-04-24. |
| 50 | `prog_level[1]` | External programming target level bit 1 | out | signal | Same as pad 49 | Same source as pad 49 |
| 51 | `prog_level[2]` | External programming target level bit 2 | out | signal | Same as pad 49 | Same source as pad 49 |
| 52 | `prog_level[3]` | External programming target level bit 3 | out | signal | Same as pad 49 | Same source as pad 49 |
| 53 | `ESD_RSV0` | Reserved pad for ESD / foundry rule closure | n/a | ESD-reserved | Do not assign logic use | Not exported in current RTL wrapper |
| 54 | `ESD_RSV1` | Reserved pad for ESD / foundry rule closure | n/a | ESD-reserved | Do not assign logic use | Not exported in current RTL wrapper |
| 55 | `ESD_RSV2` | Reserved pad for ESD / foundry rule closure | n/a | ESD-reserved | Do not assign logic use | Not exported in current RTL wrapper |

## Programming op encoding (pads 46..48)

Analog macro latches `prog_op[2:0]` on `cim_start` rising edge (digital side
pipelines `prog_op_ext` / `prog_level_ext` so they are stable at that edge)
and decodes:

| `prog_op[2:0]` | Meaning | `prog_level` field | Cell selected by |
|---|---|---|---|
| `3'b000` | Inference (standard MAC) | — | `wl_data / wl_group_sel / wl_latch` (inference WL vector) + `bl_sel` |
| `3'b001` | Erase cell | don't care | `wl_data / wl_group_sel / wl_latch` (one-hot row) + `bl_sel` (col) |
| `3'b010` | Write cell | **target level 0..15** | `wl_data / wl_group_sel / wl_latch` (one-hot row) + `bl_sel` (col) |
| `3'b011` | Verify cell (readback on `bl_data`) | don't care | `wl_data / wl_group_sel / wl_latch` (one-hot row) + `bl_sel` (col) |
| `3'b100` | Erase full array (ignores row selection) | don't care | all rows asserted; `bl_sel` don't care |
| `3'b101..111` | Reserved | — | analog side shall treat as idle / no-op |

Contract (2026-04-24 Q1/Q2/Q3 lock-in):

- **Q1 — LEVEL-gate `cim_start`**: during `prog_busy=1`, `cim_start` is held
  high for the entire pulse / verify window. Analog drives pulse while
  `cim_start=1`, withdraws on falling edge. **No analog-side self-timing.**
- **Q2 — per-window `prog_op` stability**: `prog_op` is stable within each
  `cim_start=1` window but may switch between windows (e.g. write → verify);
  the digital FSM guarantees a ≥ 1-cycle gap with `cim_start=0` between
  windows, during which `prog_op` transitions. Latch on rising edge is safe.
- **Q3 — verify `bl_data` timing + noise budget**: `bl_data` must settle to
  ±1 LSB within **≤ 100 ns** after `cim_start_ext` rising edge, and hold
  until `cim_start_ext` falling edge. Digital compares against
  `prog_level * 16 ± 2`.
  - If analog + ADC RMS noise is **≤ 1 LSB**, the fixed `±2 LSB` window still
    works, but single-shot pass rate is only about 95%, so retry should remain enabled.
  - For near-3σ single-shot margin inside that same `±2 LSB` window, target roughly
    **≤ 0.67 LSB RMS**.
  Therefore **no** analog → digital `prog_pass` pad is required.

## Totals

| Class | Count |
|---|---:|
| `signal` | 46 |
| `power` | 6 |
| `ESD-reserved` | 3 |
| Total | **55** |

## Consistency Rules

- Any document that mentions the ASIC pad plan must reference this file instead of re-deriving pin arithmetic inline.
- Any future change to pad count, pad name, direction, or reset behavior must update this file first.
- `rtl/top/chip_top.sv` is currently a signal-routing wrapper rather than a final pad-ring implementation, but its comments must stay aligned with this table.
