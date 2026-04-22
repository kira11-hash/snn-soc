# feature/main-fpga-e203 — Architecture Decisions

## Overview

This branch validates the V1 SNN SoC (main branch) in ZCU102 PL fabric with an
E203 RISC-V soft-core CPU, using a behavioral FPGA CIM macro model and
pre-loaded BRAM firmware.

## Key Decisions

### D1: E203 boots from BRAM pre-init (bitstream contains firmware)

Firmware is compiled → ELF → `$readmemh` hex → embedded in bitstream via
`sram_simple.sv` `INIT_FILE` parameter. E203 executes from address 0x0 on
power-on. No runtime JTAG firmware loading required.

### D2: FPGA CIM model = `cim_fpga_programmable_model.sv`

Module name `cim_macro_blackbox` for drop-in substitution. Differences vs RTL
`cim_macro_blackbox.sv`:
- Always uses FF-based weight storage (no `ifdef SYNTHESIS` guard)
- Supports `prog_en` / `erase_en` programming path
- Combinational weighted sum (FF outputs, no sync-read latency)
- No `$error`/`$fatal`/`$display` (Vivado-safe)

### D3: Firmware = `e203_fpga_smoke.c` (three phases, no SPI)

Phase 0 (Boot): UART init → `FPGA_E203_BOOT_UART_PASS`

Phase 1 (Program): Full-array erase → write rows 0..9 × cols 0..9 at level 1
→ `FPGA_E203_PROGRAM_ERASE_WRITE_PASS`

Phase 2 (Inference): All-ones 64-bit input × 10 timesteps, compare HW spike
histogram against SW-simulated LIF expected counts
→ `FPGA_E203_PROGRAMMED_INFERENCE_PASS`

### D4: MMCM 300 MHz differential → 50 MHz

`IBUFDS` (DIFF_TERM=TRUE) + `MMCME4_ADV` (MULT=4.0, DIV=24.0, VCO=1200 MHz)
+ `BUFG`. Clock input: USER_SI570 on pins AL8 (P) / AL7 (N).

### D5: UART via PMOD J55 (external USB-TTL adapter)

A20 = FPGA TX, B20 = FPGA RX. LVCMOS33. Not routed via CP2108.
Requires external USB-TTL adapter (CP2102/CH340/PL2303, 3.3V).

### D6: Branch from `main @ 4c5de4eb`

Evidence branch. Tags `main-fpga-e203-passed` when all three gates pass.
Default does NOT merge to main.

## File Map

| File | Purpose |
|------|---------|
| `rtl/mem/sram_simple.sv` | Added `INIT_FILE` param + `$readmemh` for BRAM pre-init |
| `rtl/top/snn_soc_top.sv` | Added `INSTR_INIT_FILE` pass-through to `u_instr_sram` |
| `fpga/cim_model/cim_fpga_programmable_model.sv` | Programmable CIM model (drop-in for Vivado) |
| `fpga/boards/zcu102/snn_soc_fpga_top.sv` | MMCM + reset + `snn_soc_top` wrapper |
| `fpga/boards/zcu102/constraints_e203.xdc` | Pin assignments + timing constraints |
| `fw/e203_smoke/e203_fpga_smoke.c` | Three-phase smoke firmware |
| `fw/e203_smoke/build_e203_smoke.sh` | Firmware build script |
| `scripts/gen_bram_init.py` | ELF/bin → $readmemh hex converter |
| `scripts/program_zcu102_e203.tcl` | xsct: load bitstream to ZCU102 PL |
| `fpga_synth/zcu102_e203_demo/build_e203_demo.tcl` | Vivado non-project build |
| `fpga_synth/zcu102_e203_demo/build_e203_demo.sh` | Full pipeline wrapper |
| `tb/fpga_programmable_cim_model_tb.sv` | FPGA CIM model unit TB |
| `sim/run_fpga_programmable_cim_model.sh` | Icarus runner for above TB |

## Gate Criteria

| Gate | Command | Pass tag |
|------|---------|----------|
| A | `bash sim/run_fpga_programmable_cim_model.sh` | `FPGA_PROGRAMMABLE_CIM_MODEL_TB_PASS` |
| A | `bash sim/run_e203_icarus.sh` | `E203_SMOKETEST_PASS` |
| A | `bash sim/run_icarus_light.sh` | `LIGHT_SMOKETEST_PASS` |
| A | `bash sim/run_cim_program_ctrl.sh` | `CIM_PROGRAM_CTRL_PASS` |
| B | `bash fpga_synth/zcu102_e203_demo/build_e203_demo.sh` | WNS > 0, bitstream generated |
| C | UART capture | `FPGA_E203_BOOT_UART_PASS` + `FPGA_E203_PROGRAM_ERASE_WRITE_PASS` + `FPGA_E203_PROGRAMMED_INFERENCE_PASS` |

## Inference Expected Counts

With programmed weights (rows 0..9 × cols 0..9, level 1 → weight 16) and
all-ones 64-bit input:
- diff[k] = 160 for k = 0..9 (10 active rows × weight 16)
- Per timestep (8 bit-planes, shifts 7..0): net membrane increase = 40800 − 8×2550 = 20400
- Every bit-plane triggers a spike (addend always ≥ threshold after timestep 0)
- **Expected: 80 spikes per neuron × 10 neurons = 800 total output FIFO entries**
