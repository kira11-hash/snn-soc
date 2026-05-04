# Round 4 alpha no-reburn rationale (2026-05-04)

Branch: `main-fpga-e203-alpha`
Current HEAD at time of review: `d60cdea6`

## Conclusion

No additional ZCU102 reburn is required after the existing
`doc/main-fpga-e203/uart_capture_20260503_round3_postfix_reverify.txt`
capture.

The reason is not "round 4 had no board-facing changes at all"; the reason is:

1. the only board-facing round-4-era change was already covered by the
   2026-05-03 17:51 postfix reverify, and
2. the later commit `ef2a6f59` only closed simulation/regression gaps and did
   not change the FPGA bitstream input firmware (`fw/e203_smoke/out/e203_smoke.hex`)
   or the committed bitstream itself.

## Why the 2026-05-03 postfix reverify already covers the board-facing change

The alpha FPGA build path preloads `fw/e203_smoke/out/e203_smoke.hex` into
INSTR SRAM BRAM:

- `fpga_synth/zcu102_e203_demo/build_e203_demo.tcl` defaults
  `instr_hex_path` to `fw/e203_smoke/out/e203_smoke.hex`
- synthesis passes that file through generic
  `INSTR_INIT_FILE=<.../e203_smoke.hex>`
- `scripts/program_zcu102_e203.tcl` programs only the FPGA bitstream; the E203
  then starts directly from BRAM

Therefore, for the alpha FPGA board path, the board-facing firmware is
`e203_smoke`, not `boot_rom` and not `silicon_bringup`.

Commit `456b78c0` did modify the board-facing path:

- `fw/e203_smoke/e203_fpga_smoke.c`
- `fw/e203_smoke/out/e203_smoke.bin`
- `fw/e203_smoke/out/e203_smoke.hex`

So that commit did require a fresh board reverify.

That reverify already happened:

- `456b78c0` timestamp: `2026-05-03 17:50:00 +0800`
- `cc9553aa` timestamp: `2026-05-03 17:50:06 +0800`
- `uart_capture_20260503_round3_postfix_reverify.txt` capture start:
  `Sun May 3 17:51:26 2026`
- matching xsct programming log exists at
  `uart_capture_20260503_round3_postfix_reverify.txt.xsct.log`

So the postfix reverify is already post-`456b78c0` and post-`cc9553aa`.

## Commit-by-commit impact review

| Commit | Files of interest | Board behavior impact |
|---|---|---|
| `456b78c0` | `fw/e203_smoke/e203_fpga_smoke.c` + rebuilt `fw/e203_smoke/out/e203_smoke.hex` | Yes, board-facing. Already covered by `uart_capture_20260503_round3_postfix_reverify.txt`. |
| `456b78c0` | `fw/boot_main.c`, `fw/boot_rom/boot_rom_main.c`, `fw/silicon_bringup/silicon_bringup.c` | Not part of the alpha FPGA BRAM-init boot path. Relevant to other boot flows, but not to this board evidence path. |
| `cc9553aa` | `rtl/sys/reset_sync.sv` | Synth-visible `STAGES==1` branch added, but alpha synthesized path instantiates `reset_sync #(.STAGES(2))` in `rtl/top/chip_top.sv`; no `STAGES=1` FPGA use site exists. Sim-only `$fatal` is under `` `ifndef SYNTHESIS ``. |
| `cc9553aa` | `rtl/sys/sync_2ff.sv` | Only adds `` `ifndef SYNTHESIS `` parameter guard for `WIDTH < 1`; synthesized `WIDTH=1` path is unchanged. |
| `33dfb7af` | doc + capture import | No board impact. |
| `4b0fcf45` | `fpga_synth/zcu102_e203_demo/build_e203_demo.tcl` | Adds DRC report emission only; no RTL/netlist/firmware content change. |
| `ef2a6f59` | `fw/silicon_bringup/*`, `tb/silicon_bringup_tb.sv`, `sim/run_silicon_bringup.sh` | Simulation closure only. `silicon_bringup` is not the BRAM-init firmware used by the alpha FPGA board path. |
| `ef2a6f59` | `fw/e203_smoke/build_e203_smoke.sh` | Build-script path normalization only (`OUT_DIR`, relative include/link paths, `cd "$SCRIPT_DIR"`). No committed `e203_smoke.hex` / `e203_smoke.bin` delta after the existing postfix reverify. |

## Key evidence behind the no-reburn decision

1. `cc9553aa` is non-board-affecting for this FPGA image:
   - `reset_sync` board instance is `STAGES=2`
   - `sync_2ff` change is sim-only guard code

2. `456b78c0` was board-affecting, but the board was already reverified after
   that commit.

3. After the capture-bearing commit `33dfb7af`, there is no further delta in:
   - `fw/e203_smoke/out/e203_smoke.hex`
   - `fw/e203_smoke/out/e203_smoke.bin`
   - `fpga_synth/zcu102_e203_demo/out/snn_soc_fpga_top.bit`

4. `ef2a6f59` changes `silicon_bringup` build/runtime behavior for simulation
   closure, but the alpha FPGA board path still boots the BRAM-preloaded
   `e203_smoke` image.

## Final decision

No new reburn is required for alpha at current HEAD `d60cdea6`.

The valid board evidence chain is:

- board-facing firmware update: `456b78c0`
- reset/sync coverage fix: `cc9553aa`
- fresh board reverify after those changes:
  `doc/main-fpga-e203/uart_capture_20260503_round3_postfix_reverify.txt`
- later non-board-affecting follow-ups:
  `33dfb7af`, `4b0fcf45`, `ef2a6f59`, `d60cdea6`

Therefore the existing 2026-05-03 postfix capture remains the correct
source-of-truth alpha board evidence for final paper handoff.
