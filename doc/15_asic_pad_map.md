# ASIC Pad Map Freeze

## Purpose

This document is the canonical in-repo source of truth for the current ASIC pad plan.

- Scope: ASIC mainline only
- Physical intent: full 48-pad package view
- Current RTL status: [`rtl/top/chip_top.sv`](/d:/SoC%20Design/SoC%20Design/rtl/top/chip_top.sv) is still a signal-pad skeleton and does not yet instantiate real pad cells
- Counting rule:
  - 48 pads total
  - 45 usable pads
  - 3 `ESD-reserved` pads
  - The 45 usable pads are split into 39 functional signal pads + 6 power/ground pads

## Notes

- Pad index order below is the frozen documentation order for interface planning and cross-team review. It is not yet a final physical pad-ring placement order.
- `default/reset behavior` describes the current repository behavior and reset expectation. Where `chip_top.sv` is still a placeholder, that is called out explicitly.
- `expected signal owner`:
  - `digital stub/direct` means the current RTL already drives or receives the signal at `snn_soc_top`
  - `chip_top skeleton` means the signal exists only as a placeholder at [`rtl/top/chip_top.sv`](/d:/SoC%20Design/SoC%20Design/rtl/top/chip_top.sv)

## Full 48-Pad Table

| Pad | Name | Function | Dir | Class | Default / Reset Behavior | Notes |
|---|---|---|---|---|---|---|
| 01 | `clk` | System reference clock | in | signal | External source drives; no internal default | Routed to `snn_soc_top.clk` |
| 02 | `rst_n` | Active-low reset | in | signal | Hold low during reset entry, release high for normal run | Routed to `snn_soc_top.rst_n` |
| 03 | `uart_tx` | UART TX | out | signal | `uart_ctrl` drives idle high (`1`) after reset and emits 8N1 TX frames when active | Current source: `uart_ctrl.sv` |
| 04 | `uart_rx` | UART RX | in | signal | External source drives; current V1 mainline has RX path reserved but not yet consumed by logic | Current sink: `uart_ctrl.sv` |
| 05 | `spi_cs_n` | SPI chip select | out | signal | Stub holds high (`1`) after reset | Current source: `spi_stub.sv` |
| 06 | `spi_sck` | SPI clock | out | signal | Stub holds low (`0`) after reset | Current source: `spi_stub.sv` |
| 07 | `spi_mosi` | SPI MOSI | out | signal | Stub holds low (`0`) after reset | Current source: `spi_stub.sv` |
| 08 | `spi_miso` | SPI MISO | in | signal | External source drives; stub currently ignores input | Current sink: `spi_stub.sv` |
| 09 | `jtag_tck` | JTAG clock | in | signal | External source drives; stub absorbs input only | Current sink: `jtag_stub.sv` |
| 10 | `jtag_tms` | JTAG mode select | in | signal | External source drives; stub absorbs input only | Current sink: `jtag_stub.sv` |
| 11 | `jtag_tdi` | JTAG data in | in | signal | External source drives; stub absorbs input only | Current sink: `jtag_stub.sv` |
| 12 | `jtag_tdo` | JTAG data out | out | signal | Stub drives constant `0` | Current source: `jtag_stub.sv`; not pass-through |
| 13 | `VDDCORE0` | Core supply | inout | power | Power pad; no logic reset state | One of two core VDD pads |
| 14 | `VSSCORE0` | Core ground | inout | power | Ground pad; no logic reset state | One of two core VSS pads |
| 15 | `VDDCORE1` | Core supply | inout | power | Power pad; no logic reset state | One of two core VDD pads |
| 16 | `VSSCORE1` | Core ground | inout | power | Ground pad; no logic reset state | One of two core VSS pads |
| 17 | `VDDIO` | IO supply | inout | power | Power pad; no logic reset state | Shared digital IO supply |
| 18 | `VSSIO` | IO ground | inout | power | Ground pad; no logic reset state | Shared digital IO ground |
| 19 | `wl_data[0]` | WL mux data bit 0 | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 20 | `wl_data[1]` | WL mux data bit 1 | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 21 | `wl_data[2]` | WL mux data bit 2 | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 22 | `wl_data[3]` | WL mux data bit 3 | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 23 | `wl_data[4]` | WL mux data bit 4 | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 24 | `wl_data[5]` | WL mux data bit 5 | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 25 | `wl_data[6]` | WL mux data bit 6 | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 26 | `wl_data[7]` | WL mux data bit 7 | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 27 | `wl_group_sel[0]` | WL mux group select bit 0 | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 28 | `wl_group_sel[1]` | WL mux group select bit 1 | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 29 | `wl_group_sel[2]` | WL mux group select bit 2 | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 30 | `wl_latch` | WL mux latch pulse | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 31 | `cim_start` | CIM transaction start pulse | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 32 | `cim_done` | CIM transaction done pulse | in | signal | External analog side drives; current `chip_top` only terminates input | Final hookup pending |
| 33 | `bl_sel[0]` | BL readback select bit 0 | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 34 | `bl_sel[1]` | BL readback select bit 1 | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 35 | `bl_sel[2]` | BL readback select bit 2 | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 36 | `bl_sel[3]` | BL readback select bit 3 | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 37 | `bl_sel[4]` | BL readback select bit 4 | out | signal | Current `chip_top` skeleton drives `0` | Final hookup pending |
| 38 | `bl_data[0]` | BL readback data bit 0 | in | signal | External analog side drives; current `chip_top` only terminates input | Final hookup pending |
| 39 | `bl_data[1]` | BL readback data bit 1 | in | signal | External analog side drives; current `chip_top` only terminates input | Final hookup pending |
| 40 | `bl_data[2]` | BL readback data bit 2 | in | signal | External analog side drives; current `chip_top` only terminates input | Final hookup pending |
| 41 | `bl_data[3]` | BL readback data bit 3 | in | signal | External analog side drives; current `chip_top` only terminates input | Final hookup pending |
| 42 | `bl_data[4]` | BL readback data bit 4 | in | signal | External analog side drives; current `chip_top` only terminates input | Final hookup pending |
| 43 | `bl_data[5]` | BL readback data bit 5 | in | signal | External analog side drives; current `chip_top` only terminates input | Final hookup pending |
| 44 | `bl_data[6]` | BL readback data bit 6 | in | signal | External analog side drives; current `chip_top` only terminates input | Final hookup pending |
| 45 | `bl_data[7]` | BL readback data bit 7 | in | signal | External analog side drives; current `chip_top` only terminates input | Final hookup pending |
| 46 | `ESD_RSV0` | Reserved pad for ESD / foundry rule closure | n/a | ESD-reserved | Do not assign logic use | Not exported in current RTL skeleton |
| 47 | `ESD_RSV1` | Reserved pad for ESD / foundry rule closure | n/a | ESD-reserved | Do not assign logic use | Not exported in current RTL skeleton |
| 48 | `ESD_RSV2` | Reserved pad for ESD / foundry rule closure | n/a | ESD-reserved | Do not assign logic use | Not exported in current RTL skeleton |

## Totals

| Class | Count |
|---|---:|
| `signal` | 39 |
| `power` | 6 |
| `ESD-reserved` | 3 |
| Total | 48 |

## Consistency Rules

- Any document that mentions the ASIC pad plan must reference this file instead of re-deriving pin arithmetic inline.
- Any future change to pad count, pad name, direction, or reset behavior must update this file first.
- `rtl/top/chip_top.sv` may remain a skeleton during the current stage, but its comments must stay aligned with this table.
