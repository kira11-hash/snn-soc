# Silicon Bring-up Plan — V1 Digital Die

> **Scope**: post-tape-out plan for the V1 digital die (E203 + SNN SoC,
> separate from the analog CIM die).  Covers boot paths, self-test firmware,
> test-mode extensions, and the recommended bring-up sequence.

**Related files / scripts** (all committed on `feature/main-fpga-e203`):

| Area | Artifact |
|---|---|
| Boot ROM module | `rtl/mem/boot_rom.sv` + `tb/boot_rom_tb.sv` + `sim/run_boot_rom.sh` |
| test_mode extension | `rtl/reg/reg_bank.sv` (`PROG_CTRL[3] = BYPASS_HANDSHAKE`), `rtl/top/snn_soc_top.sv` (fake ADC done / bl_data MUX) |
| Bring-up firmware | `fw/silicon_bringup/silicon_bringup.c` + `build_silicon_bringup.sh` |
| Bring-up TB | `tb/silicon_bringup_tb.sv` + `sim/sim_silicon_bringup.f` + `sim/run_silicon_bringup.sh` |
| Board capture | `scripts/fpga_bringup_capture.sh` |

---

## 1. Three boot paths & their silicon realities

| Path | What it is | ASIC support now | ASIC support with `boot_rom` |
|---|---|---|---|
| **A — SRAM pre-init** | `$readmemh` fills INSTR_SRAM at reset (FPGA BRAM INIT_xx style) | ❌ foundry SRAM macros generally do not support `$readmemh` — uninitialised SRAM = X on power-on | ❌ (same constraint; use Path A' below) |
| **A′ — Mask ROM pre-init** | Replace SRAM @ reset vector with a mask ROM macro | ✅ via `rtl/mem/boot_rom.sv` → foundry ROM compiler (e.g., TSMC ROM) | ✅ (primary path this plan enables) |
| **B — SPI flash boot** | Bootloader reads from external SPI flash → loads SRAM → jump | Needs a bootloader in some non-volatile storage first — requires Path A′ to host the bootloader | ✅ Path A′ ROM contains `fw/boot_rom/boot_rom_main.c` |
| **C — JTAG rescue** | Host PC uses `scripts/jtag_rescue.py` to halt CPU, load SRAM over JTAG, release CPU | ✅ works even without `boot_rom` (assuming JTAG TAP, `jtag_mem_loader`, and CPU-hold logic are on-die) | ✅ (used as fallback if ROM image is flawed) |

**Recommended ASIC tape-out composition**: Path A′ (2–4 KB mask ROM at 0x0) hosting a minimal bootloader (SPI flash boot + JTAG-rescue wait), with Path C as permanent fallback.

### Why Path A′ is the primary recommendation

Without a mask ROM, the only way to get any code running on the silicon is **Path C** — which means **every single power-on requires a working JTAG chain**.  If the JTAG pads or `jtag_mem_loader` have even a small silicon bug, the chip is bricked.  A mask ROM makes the chip self-booting, demotes JTAG to "debug / rescue" (where it belongs), and shrinks the post-silicon attack surface dramatically.

### Minimal boot ROM image (for future tape-out)

Two flavours are usable right now:

1. **Trampoline ROM (~50 bytes)**: `jal 0x1000` (jump to INSTR_SRAM).  Pair with JTAG rescue or a pre-loaded SRAM (e.g., via JTAG-flashed FPGA emulation in early bring-up).
2. **Full bring-up ROM (~3 KB, fits in 4 KB)**: compile `fw/silicon_bringup/silicon_bringup.c` directly into the ROM.  Chip powers on → immediately self-tests via `test_mode` + `BYPASS_HANDSHAKE`, reports PASS on UART.  Most informative choice for silicon bring-up.

Integration into `snn_soc_top` / `chip_top` is now complete on `main`:

- Bus-interconnect address decoder shifts `INSTR_SRAM` to `0x1000..0x4FFF` when `ENABLE_BOOT_ROM=1`
- `chip_top` enables `BOOT_ROM` and `PROGRAM_MODE` for the tape-out intent path
- `fw/link_app.ld`, `fw/boot_rom/build_boot_rom.sh`, and `scripts/make_boot_image.py` complete the Day-2 boot chain

---

## 2. Test-mode coverage summary

The digital die has **two orthogonal mock/bypass mechanisms**, both driven from MMIO bits accessible to the CPU firmware:

### 2.1 `REG_CIM_TEST[0] = cim_test_mode` (existing in V1)

Replaces **inference-path** signals so the CPU can validate the digital datapath without a responding analog macro:

- `cim_done_test`: 2-cycle delayed pulse after `cim_start_pulse`
- `adc_done_test`: 1-cycle delayed pulse after `adc_start`
- `bl_data`: `{pos (ch 0..9), neg (ch 10..19)}` from `REG_CIM_TEST[23:8]`

**Covers**: `cim_array_ctrl` / `adc_ctrl` FSMs, LIF neurons, output FIFO, SOFT_RESET, register control loop.

**Does NOT cover**: programming FSM (`cim_program_ctrl` / `cim_macro_arbiter`), which still waits on `prog_adc_done` from the real macro.

### 2.2 `REG_PROG_CTRL[3] = BYPASS_HANDSHAKE` (NEW 2026-04-23)

Added by Stage 2 of this work.  When set before `PROG_CTRL.START`, `snn_soc_top` latches
`BYPASS_HANDSHAKE`, erase/write mode, and level for the current operation, injects a
registered **fake** `prog_adc_done` response after `prog_adc_start`, and forces
`prog_bl_data` to the **ideal** readback value:

- `erase` op → readback = `0` (passes `<= 1` verify)
- `write` op → readback = `prog_level * 16` (centre of the `target_level * (256 / PROG_LEVELS) ± 2` window)

Result: `cim_program_ctrl` ST_VERIFY always transitions to ST_PASS.  CPU can exercise the **full** programming state machine (SETUP → PULSE → PULSE_HOLD → READBACK → RB_WAIT → VERIFY → PASS → DONE) **without the analog die present**.  The latched control also means accidental firmware writes to `PROG_CTRL` while busy do not change the in-flight bypass decision.

**Covers**: `cim_program_ctrl`, `cim_macro_arbiter` infer-side masking, reg_bank sticky DONE, retry/fail path.

**Does NOT cover**: actual pulse generation voltages, the RRAM cell itself, analog readback INL/DNL.

### 2.3 Combined coverage table (what a full self-test can validate)

With `cim_test_mode=1` + `BYPASS_HANDSHAKE=1`, the silicon digital die can run `fw/silicon_bringup/silicon_bringup.c` fully standalone and validate:

| Digital subsystem | Validated? |
|---|---|
| E203 CPU boot, fetch, execute | ✅ |
| Bus interconnect + MMIO decode | ✅ |
| reg_bank (threshold, timesteps, test, prog ctrl, status) | ✅ |
| DMA (data_sram → input_fifo) | ✅ |
| cim_array_ctrl (WL scan, timestep/bit-plane counters) | ✅ |
| adc_ctrl (20-channel MUX sequencing) | ✅ |
| lif_neurons (9-bit signed, bit-plane shifts, soft reset) | ✅ |
| output FIFO (push on spike, pop via MMIO read) | ✅ |
| cim_program_ctrl (erase/write/verify FSM) | ✅ |
| cim_macro_arbiter (infer-side masking while `prog_busy`) | ✅ |
| UART TX | ✅ |
| Reset synchroniser / CPU hold | ✅ (implicitly — firmware couldn't run otherwise) |
| **Analog macro itself** | ❌ (test_mode bypasses it) |
| **Real programming voltages** | ❌ (BYPASS_HANDSHAKE bypasses them) |
| **Level shifters / pad electrical** | ❌ (only tested if real analog die is connected) |

---

## 3. Bring-up sequence (recommended)

Assumes digital die comes back first; analog die may or may not be attached.

### Day 1 — Power-on sanity (no analog die)

```
1. Plug digital die + JTAG + UART.  Power on.
2. CPU should fault immediately from uninitialised SRAM (PC stuck or wild).
3. JTAG rescue: run scripts/jtag_rescue.py to load silicon_bringup.bin into SRAM.
4. JTAG release CPU → self-test runs.
5. Expected UART:
     SILICON_BRINGUP_START v1 build=...
     [STAGE_A] neuron[0..9] hw=80 sw=80 OK
     [STAGE_A] total_spikes=800 mismatch=0
     [STAGE_B] erase  PROG_STATUS=0x82  (DONE + PASS)
     [STAGE_B] write  PROG_STATUS=0x82  (DONE + PASS)
     SILICON_BRINGUP_DIGITAL_PASS
```

If this fails, the digital die is compromised — triage via the specific `SILICON_BRINGUP_DIGITAL_FAIL_<stage>` tag.

### Day 2 — SPI flash boot (if ROM populated)

```
1. Flash silicon_bringup.bin to external SPI flash (addr 0, with the 16-byte
   `scripts/make_boot_image.py` header prepended).
2. Power on.  CPU runs `fw/boot_rom/boot_rom_main.c` from ROM → reads SPI → loads SRAM → jumps.
3. Expect same SILICON_BRINGUP_DIGITAL_PASS UART stream as Day 1.
```

Confirms SPI + DMA + bootloader path.

### Day 3 — Analog die integration

```
1. Mount analog die + level shifters + pad bonds.
2. Reset, run the SAME silicon_bringup firmware with cim_test_mode=0 and
   BYPASS_HANDSHAKE=0 (production settings).
3. Run full `fw/e203_smoke/e203_fpga_smoke.c` — covers real erase → write
   → verify → programmed inference.
4. Compare against the FPGA Phase C reference log (doc/main-fpga-e203/
   board_bringup_log_c0c1c2.txt).
```

If Stage A fails but Day 1 SILICON_BRINGUP_DIGITAL_PASS held: analog die is suspect, digital die confirmed OK.

---

## 4. FPGA verification of the extensions

The extensions added in this work (`BYPASS_HANDSHAKE` bit + fake-response MUX) must be validated in both simulation **and** on the ZCU102 before being trusted in silicon.

### Simulation (already green)

| Regression | Pass tag | Status |
|---|---|---|
| `sim/run_icarus_light.sh` | `LIGHT_SMOKETEST_PASS` | ✅ |
| `sim/run_dma_icarus.sh` | `DMA_SMOKETEST_PASS` | ✅ |
| `sim/run_cim_program_ctrl.sh` | `CIM_PROGRAM_CTRL_PASS` (8/8) | ✅ |
| `sim/run_uart_icarus.sh` | `UART_SMOKETEST_PASS` | ✅ |
| `sim/run_prog_pulse_cfg.sh` | `PROG_PULSE_CFG_TB_PASS` | ✅ |
| `sim/run_prog_start_interlock.sh` | `PROG_START_INTERLOCK_TB_PASS` | ✅ |
| `sim/run_fpga_programmable_cim_model.sh` | `FPGA_PROGRAMMABLE_CIM_MODEL_TB_PASS` | ✅ |
| `sim/run_boot_rom.sh` | `BOOT_ROM_TB_PASS` (23/23) | ✅ |
| `sim/run_silicon_bringup.sh` | `SILICON_BRINGUP_TB_PASS` | ✅ |

### FPGA board (for GPT / user to run)

```bash
# 1. Build the silicon-bringup FPGA variant
bash fw/silicon_bringup/build_silicon_bringup.sh
VIVADO=/d/Xilinx/Vivado/2022.2/bin/vivado \
  SKIP_FW=1 \
  HEX="$PWD/fw/silicon_bringup/out/silicon_bringup.hex" \
  OUT_DIR="$PWD/fpga_synth/zcu102_silicon_bringup/out" \
  bash fpga_synth/zcu102_e203_demo/build_e203_demo.sh

# 2. Capture with the new harness
bash scripts/fpga_bringup_capture.sh \
     --bitstream fpga_synth/zcu102_silicon_bringup/out/snn_soc_fpga_top.bit \
     --serial COM3 \
     --baud 115200 \
     --timeout 120 \
     --tag "SILICON_BRINGUP_DIGITAL_PASS" \
     --fail-tag "SILICON_BRINGUP_DIGITAL_FAIL"
```

Expected exit code: `0` (all tags seen).  Saves UART capture to
`doc/main-fpga-e203/uart_capture_<TIMESTAMP>.log`.

Expected UART landmarks:

```text
SILICON_BRINGUP_START v1 build=...
[STAGE_A] neuron[0] hw=80 sw=80 OK
...
[STAGE_A] total_spikes=800 mismatch=0
[STAGE_B] bypass toggle readback PASS
[STAGE_B] full_array_erase PROG_STATUS=0x00000082
[STAGE_B] erase PROG_STATUS=0x00000082
[STAGE_B] write PROG_STATUS=0x00000082
SILICON_BRINGUP_DIGITAL_PASS
```

---

## 5. Open items / deferred to V1.1

- [ ] Pick final ROM size (2 KB trampoline vs. 4 KB full self-test) after SPI-flash boot flow is frozen.
- [ ] Decide whether tape-out ROM content is the full SPI bootloader (`fw/boot_rom/boot_rom_main.c`) or a smaller trampoline ROM.
- [ ] Integrate `fpga_bringup_capture.sh` into the automation CI so any RTL change automatically re-runs Phase C on a physical board (requires remote board access infrastructure).
- [ ] Decide whether `BYPASS_HANDSHAKE` should be gated by a hard fuse or production firmware lock so it cannot be abused in shipped silicon.

---

## 6. Paper-wording envelope

Unchanged from `doc/main-fpga-e203/00_architecture.md`:

- **Can write**: "V1 digital RTL functional equivalence validated on ZCU102 FPGA with an E203 RISC-V soft-core and bit-exact output spike counts; post-silicon digital-die self-test infrastructure prepared."
- **Cannot write**: "analog CIM validated", "tape-out ready", "chip functional validation complete" — those remain gated behind the analog die integration + mixed-signal co-simulation + full back-end signoff.
