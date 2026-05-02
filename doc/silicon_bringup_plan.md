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

### Day 1 — Power-on sanity (no analog die, no SPI flash)

Assumes `chip_top.ENABLE_BOOT_ROM=1` (the frozen tape-out configuration) so the
mask ROM boots first; the SPI flash pads are left unconnected or empty.

```
1. Plug digital die + JTAG (pyftdi-compatible) + UART (115200 8N1).  Power on.
2. Reset vector points to the mask ROM at 0x0.  boot_rom_main.c starts:
     BL start
     BL rdid=<hex>              (CP2108 → UART; flash not present → junk ID)
     BL bad magic 0xFFFFFFFF
     BL waiting for JTAG rescue (wfi)
   CPU enters wfi loop.  The JTAG TAP + jtag_mem_loader are still alive and
   independent of the CPU.
3. JTAG rescue (load self-test firmware into the SHIFTED INSTR_SRAM @ 0x1000):
     wsl bash fw/silicon_bringup/build_silicon_bringup.sh      # produce .hex
     python scripts/jtag_rescue.py --backend pyftdi --url "ftdi:///1" \
         rescue-load fw/silicon_bringup/out/silicon_bringup.hex \
             --load-addr 0x1000
   The script holds CPU, writes INSTR_SRAM @ 0x1000, releases CPU.  Because the
   ROM's bootloader is still in wfi, the release makes CPU re-fetch from 0x0:
   it re-runs boot_rom_main, hits the wfi again unless the rescue concurrently
   triggered soft reset — the recommended flow is to *release-cpu after
   pressing the external reset button* so PC restarts at 0x0, the bootloader
   does not find valid flash, and falls through to running the freshly loaded
   code at 0x1000 (via the "fallback jump" path documented in
   doc/silicon_bringup_guide.md §2.2).
4. Expected UART after the fallback jump:
     SILICON_BRINGUP_START v1 build=...
     [STAGE_A] neuron[0..9] hw=80 sw=80 OK
     [STAGE_A] total_spikes=800 mismatch=0
     [STAGE_B] erase  PROG_STATUS=0x00000082  (DONE + PASS)
     [STAGE_B] write  PROG_STATUS=0x00000082  (DONE + PASS)
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
- [x] Decide whether `BYPASS_HANDSHAKE` should be gated by a hard fuse or production firmware lock so it cannot be abused in shipped silicon. → **决策已在 §6 落地（2026-05-02 audit follow-up R-C9）**

---

## 6. BYPASS_HANDSHAKE 生命周期与生产固件 readback assert（R-C9 audit fix，2026-05-02）

### 6.1 背景：为什么这个 bit 危险

`PROG_CTRL.BYPASS_HANDSHAKE`（reg_bank.sv 中 PROG_CTRL[3]，CLAUDE.md 寄存器表 0x38）
是 silicon bring-up 早期为隔离数字/模拟问题留的逃生门：**置 1 时，cim_program_ctrl
跳过模拟侧真实 ADC verify 握手，强制使用一个落在 verify 窗口内的伪造 readback
值 → 任何 cell 都判 PASS**。

危险在于：硬件层面没有锁。`reg_bank.sv` 是普通 RW bit：
```sv
if (req_wstrb[0] && !prog_inflight) prog_handshake_bypass <= req_wdata[3];
```
任何固件 / JTAG 调试 / OTA 更新都可以把它置 1。一旦在生产固件里**意外**（bug、
误操作、调试遗留）让它 = 1，硅片实际写错了权重也 silently 全 PASS，推理精度
崩了用户都不知道。

### 6.2 R-C9 决策：本 die **没有 efuse / OTP cell**，只能走软件 lock

2026-05-02 audit 抓到 R-C9 时考虑过两条 mitigation：

| 方案 | 强度 | 是否需 RTL/工艺改动 | 是否绕得过 |
|---|---|---|---|
| A. efuse / OTP 硬件锁 | 硬件强制 | 需要 die 上有 OTP cell + 改 RTL 加 efuse 信号 + chip_top pad | 不可绕过 |
| B. 生产固件 readback assert | 仅靠固件自律 | 不需要 RTL 改动 | JTAG / 攻破固件可绕过 |

**本项目当前 die 工艺不带 OTP cell**（已确认），所以**只能走方案 B**。
方案 A 留作未来工艺升级时可选。

### 6.3 BYPASS_HANDSHAKE 的三阶段生命周期

| 阶段 | 数字 die | 模拟 die | BYPASS | 说明 |
|---|---|---|---|---|
| **Day 1-2 数字自检** | ✅ 上电 | ❌ 没接 / 没 ready | **= 1（必需）** | `bl_data` 是模拟侧 ADC，没接时 X 或悬空。BYPASS=0 会让所有 verify 因读到 X/0 而 FAIL，无法定位是数字 RTL 问题还是模拟未接。**silicon_bringup.c 默认走这条路径**，这是它存在的根本理由。 |
| **Day 3+ 双 die 集成测试** | ✅ | ✅ PCB 互连 | **= 0（必需）** | `bl_data` 是真实 ADC 读回，cim_program_ctrl 走真实 verify 窗口判断 PASS/FAIL/RETRY。如果 BYPASS=1 你看到所有 cell 都 PASS，但其实没真测——自欺欺人。 |
| **生产 / 出货** | ✅ | ✅ | **= 0 永久** | 终端用户跑推理。任何让 BYPASS=1 的路径都是 bug。 |

### 6.4 生产固件 readback assert 的硬性要求

**针对阶段 3（生产固件），强制实施**以下 readback assert 模式，不可省略：

> **宏命名说明（audit-pass4 M-2，2026-05-02）**：
> `PROG_CTRL_BYPASS_MASK`（含义 `(1u << 3)`）以及其他 `PROG_*` 寄存器/位域
> 宏现已集中在 `fw/include/soc_regs.h`（pass4 之前是各固件文件局部 alias，
> 容易漂移；pass4 M-2 完成迁移）。生产固件直接 `#include "soc_regs.h"`
> 即可使用本模板，无需自己定义。

```c
/*
 * R-C9 audit fix（2026-05-02）：本 die 工艺不带 efuse / OTP cell，
 * 没有硬件 lock 阻止 BYPASS_HANDSHAKE 被生产固件意外置 1。
 * 替代方案：每次进入 program / verify 路径前 readback PROG_CTRL，
 * 强制 BYPASS=0 否则 hard panic。本函数是 production firmware
 * 的红线，不可被任何 caller 跳过。
 */
static void v2b_assert_no_bypass(void) {
    uint32_t v = *(volatile uint32_t *)PROG_CTRL;
    if (v & PROG_CTRL_BYPASS_MASK) {  // bit[3], silicon bring-up only
        uart_puts("\n[FATAL] PROG_CTRL.BYPASS_HANDSHAKE=1 is FORBIDDEN in production\n");
        uart_puts("[FATAL] R-C9 policy violation — refusing to program any cell.\n");
        uart_puts("[FATAL] Halting CPU. Inspect firmware build and flash a clean image.\n");
        uart_wait_idle();
        for (;;) __asm__ volatile ("wfi");
        // 不可达
    }
}

/*
 * 所有生产固件的 program 入口必须**先**调用 v2b_assert_no_bypass()。
 * silicon_bringup.c 中允许 BYPASS=1（自检阶段），所以这个 assert 只
 * 在生产固件里调用，不要回写到 silicon_bringup.c。
 */
void v2b_program_cell(uint8_t row, uint8_t col, uint8_t level) {
    v2b_assert_no_bypass();   // ← 红线：每次都检查
    // ...真实 program 序列
}

void v2b_program_array(const uint8_t *weights, size_t n) {
    v2b_assert_no_bypass();   // ← 同样
    for (size_t i = 0; i < n; i++) {
        // ...
    }
}
```

### 6.5 落地清单（按时间顺序，绑定 tape-out 路径）

- [ ] **硅片回来后 Day 3** 双 die 集成首次测试时：写一个 minimal integration test
      firmware（`fw/integration_test/`），手动 `PROG_CTRL.BYPASS_HANDSHAKE = 0`，
      跑几轮真实 program / verify 确认双 die 通了
- [ ] **生产固件开发阶段**（V2 或后续）：建立 `fw/production/` 目录，所有 program
      / verify API 入口必须调用 `v2b_assert_no_bypass()`
- [ ] **CI lint 守口**：在 `production/` 目录下用 grep 模式匹配，禁止任何
      `*PROG_CTRL = ... | PROG_CTRL_BYPASS_MASK` 类的写法
- [ ] **出货前 review**：生产固件 .elf 反汇编 grep `PROG_CTRL_BYPASS_MASK`（或
      与之对应的立即数 `(1<<3)` / `0x08`），确认所有出现都是 **read** + **assert 0**，
      没有任何 **write 1** 的指令序列

### 6.6 已知绕过路径（透明披露）

- **JTAG 调试**：通过 jtag_mem_loader 直接写 PROG_CTRL，可以绕过固件 assert。
  生产场景下 JTAG pad 不应连接（PCB 切断），是物理隔离防御。
- **OTA 升级到带 BYPASS=1 的 firmware**：依赖 OTA 路径自身的签名验证；
  如果 OTA 通道被攻破，软件层任何防御都失效。
- **未来如有 die respin 加 efuse**：方案 A 上线后 readback assert 仍保留，
  作为软件冗余（depth-in-defense）。

---

## 7. Paper-wording envelope

Unchanged from `doc/main-fpga-e203/00_architecture.md`:

- **Can write**: "V1 digital RTL functional equivalence validated on ZCU102 FPGA with an E203 RISC-V soft-core and bit-exact output spike counts; post-silicon digital-die self-test infrastructure prepared."
- **Cannot write**: "analog CIM validated", "tape-out ready", "chip functional validation complete" — those remain gated behind the analog die integration + mixed-signal co-simulation + full back-end signoff.
