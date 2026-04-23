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
- Full protocol details (encoding table, timing, electrical): `doc/08_cim_analog_interface.md` §10 + `doc/03_cim_if_protocol.md` §Programming.
- Current digital RTL note: the 7 new sideband pads are already routed; shared carrier pads (`wl_*`, `cim_start`, `bl_sel`) still need a digital follow-up to switch to programming sources during `prog_busy`. This does not change the pad contract seen by the analog team, but it does matter for later end-to-end bring-up.
- `expected signal owner`:
  - `digital direct` means the current RTL already drives or receives the signal at `snn_soc_top`
  - `chip_top routed wrapper` means the signal is already exposed at [`rtl/top/chip_top.sv`](../rtl/top/chip_top.sv), but still not backed by technology pad cells
- JTAG remains 4-wire only in the current pad freeze. There is no dedicated `TRST_n` pad.

## Full 55-Pad Table

| Pad | Name | Function | Dir | Class | Default / Reset Behavior | Notes |
|---|---|---|---|---|---|---|
| 01 | `clk` | System reference clock | in | signal | External source drives; no internal default | Routed to `snn_soc_top.clk` |
| 02 | `rst_n` | Active-low reset | in | signal | Hold low during reset entry, release high for normal run | Routed to `snn_soc_top.rst_n` |
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
| 49 | `prog_level[0]` | External programming target level bit 0 | out | signal | Driven from `snn_soc_top.prog_level_ext` (directly from `reg_bank.PROG_CTRL[7:4]`). Valid only when `prog_op==010` (write). | Current source: `reg_bank` prog_level. Added 2026-04-24. |
| 50 | `prog_level[1]` | External programming target level bit 1 | out | signal | Same as pad 49 | Same source as pad 49 |
| 51 | `prog_level[2]` | External programming target level bit 2 | out | signal | Same as pad 49 | Same source as pad 49 |
| 52 | `prog_level[3]` | External programming target level bit 3 | out | signal | Same as pad 49 | Same source as pad 49 |
| 53 | `ESD_RSV0` | Reserved pad for ESD / foundry rule closure | n/a | ESD-reserved | Do not assign logic use | Not exported in current RTL wrapper |
| 54 | `ESD_RSV1` | Reserved pad for ESD / foundry rule closure | n/a | ESD-reserved | Do not assign logic use | Not exported in current RTL wrapper |
| 55 | `ESD_RSV2` | Reserved pad for ESD / foundry rule closure | n/a | ESD-reserved | Do not assign logic use | Not exported in current RTL wrapper |

## Programming op encoding (pads 46..48)

Analog macro samples `prog_op[2:0]` concurrently with `cim_start` rising edge
and decodes:

| `prog_op[2:0]` | Meaning | `prog_level` field | Cell selected by |
|---|---|---|---|
| `3'b000` | Inference (standard MAC) | — | `wl_data / wl_group_sel / wl_latch` (inference WL vector) + `bl_sel` |
| `3'b001` | Erase cell | don't care | `wl_data / wl_group_sel / wl_latch` (one-hot row) + `bl_sel` (col) |
| `3'b010` | Write cell | **target level 0..15** | `wl_data / wl_group_sel / wl_latch` (one-hot row) + `bl_sel` (col) |
| `3'b011` | Verify cell (readback on `bl_data`) | don't care | `wl_data / wl_group_sel / wl_latch` (one-hot row) + `bl_sel` (col) |
| `3'b100` | Erase full array (ignores row selection) | don't care | all rows asserted; `bl_sel` don't care |
| `3'b101..111` | Reserved | — | analog side shall treat as idle / no-op |

Digital compares `bl_data` readback against `prog_level * (256/16) ± 2` internally.
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
