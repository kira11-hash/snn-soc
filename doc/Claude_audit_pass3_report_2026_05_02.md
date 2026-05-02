# Claude Audit Pass 3 — 总结报告（2026-05-02）

> **本轮角色**：第三轮独立 cold-start audit（Claude Opus 4.7，1M context），
> 在 audit-pass / audit-pass2（共 14 个 commits）已 push origin 之后执行。
> 范围：main + main-fpga-e203-alpha 双支线，pre-tape-out 严苛。
> **不**做 FPGA 板验（GPT 那边的任务）。

## 抓到的新问题（按严重度）

### BLOCKER（必修，影响 RTL/FW 流片正确性）

无新增 BLOCKER。前一轮的 9 个 BLOCKER（B-1/B-2/B-01/B-03/B1×3/C4/FW-C1）经
本轮重审，fix 行为正确：
- B-1 `chip_top.BOOT_ROM_INIT_FILE` 默认 `fw/boot_rom/out/boot_rom.hex`：所有
  TB 都显式 override 为 `../fw/boot_rom/out/boot_rom.hex`（相对 sim/ cwd），
  default 主要给 FPGA 综合（Vivado 从 project root 跑能找到）+ documentation
  价值；ASIC mask ROM 由 foundry compiler 取代，不读 `$readmemh`。✓
- B-2 `cim_program_ctrl` verify window：用 `cim_macro_blackbox` 行为模型推算
  16 个 level 的 readback 中心 = `level × 16` ∈ {0, 16, 32, ..., 240}，全部
  落在 fix 后的 `[max(0, c-2), min(255, c+2)]` 窗口内 ✓。commit message 关于
  "level=15 LRS 饱和到 250+" 的措辞略夸张（仿真模型不会到 250+，硅片真饱和
  到 250+ 是 cim_macro_blackbox 应该改而不是 RTL 该扩 window — ±2 是 D2D/C2C
  contract sweet spot）。整体 fix 行为正确。

### CONCERN（应修，sim 覆盖率 / 可维护性 / byte-strobe 严格性）

| # | 问题 | 文件:行 | main fix commit | FPGA sync commit |
|---|---|---|---|---|
| W-1a | `silicon_bringup.bin` 漏 git add（前一轮 FW-C3 commit message 说 "silicon_bringup 同样处理" 但实际只 track 了 .hex，与 boot_rom 风格不一致） | `fw/silicon_bringup/out/silicon_bringup.bin` | `bd78a0b0` | `7644dea9` |
| W-1b | `rom_smoke_*` / `rom_hi_smoke_*` build artifact 持续未跟踪噪音（chip_top_rom_smoke / chip_top_rom_hi_smoke 现场 WSL build，每次 sim 重 build） | `.gitignore` + `fw/.gitignore` | `bd78a0b0` | `7644dea9` |
| R-M1.1 | `uart_ctrl.sv:131` ST_IDLE 的 TX 启动路径漏 `req_wstrb[0]` gate（前一轮 R-M1 fix 只 gate 了 txdata_shadow 的写路径；启动路径 byte-strobe 严格性漏洞，fw 实际用 store-word 不触发） | `rtl/periph/uart_ctrl.sv:131` | `bd78a0b0` | `7644dea9` |
| D-1 | `silicon_bringup_plan.md §6.4` R-C9 code template 用 `PROG_CTRL_BYPASS_HANDSHAKE_MASK`，但 codebase 唯一已实现的宏是 `PROG_CTRL_BYPASS_MASK`（`silicon_bringup.c:34`），生产固件未来照搬模板会编译失败 | `doc/silicon_bringup_plan.md:282-318` | `bd78a0b0` | `7644dea9` |

### MINOR（建议修，文档 / cosmetic / follow-up）

未在本轮 commit，但建议下一轮 audit 处理：

| # | 问题 | 位置 | 建议 |
|---|---|---|---|
| M-1 | `silicon_bringup.c:105` 嵌入 `__DATE__` → 每次重 build hex 内容变 | `fw/silicon_bringup/silicon_bringup.c:105` | 加 `SOURCE_DATE_EPOCH` env override 或固定 build string；当前作为 "build provenance" feature 也可接受，但破坏 hex SHA 可重现性 |
| M-2 | `fw/include/soc_regs.h` 缺 PROG_* 寄存器宏 → silicon_bringup.c 局部 alias，未来其他固件也得各自定义，漂移风险 | `fw/include/soc_regs.h` | 把 `PROG_CTRL` / `PROG_ROW` / `PROG_COL` / `PROG_STATUS` + 所有 mask 宏迁移到 soc_regs.h 集中管理（D-1 doc 已加 NOTE 提示） |
| M-3 | `spi_ctrl.sv` REG_CTRL 不是 byte-selective：`cs_force` 在 byte1（bit 8），SB 单 byte 写到 byte1 写不进（仅 wstrb[0] gate） | `rtl/periph/spi_ctrl.sv:110` | fw 实际都用 store-word（`SPI_CTRL = ...`），不触发；严格 byte-strobe 完整性可加 byte0/1 selective 更新逻辑 |
| M-4 | DMA `V2B_DMA_PUSH_TIMEOUT_CYCLES = 1M cycles`（20ms @ 50MHz）选值合理但未做硅片实测验证 | `rtl/top/snn_soc_pkg.sv:216` | 已在 doc/07 schedule follow-up 列出 |

## 已 push 的 commit

- main: `bd78a0b0` （audit-pass3 单 commit，覆盖 W-1 + R-M1.1 + D-1）
- main-fpga-e203-alpha: `7644dea9` (Merge branch 'main' into main-fpga-e203-alpha)

## 跨分支一致性 verification

```
git diff --name-only origin/main origin/main-fpga-e203-alpha → 25 文件
```

全部 FPGA-only：

```
doc/main-fpga-e203/00_architecture.md
doc/main-fpga-e203/alpha_board_bringup_log_20260424.txt
doc/main-fpga-e203/board_bringup_log_c0c1c2.txt
doc/main-fpga-e203/fw_main_c_boot_erase_board_validation_analysis.md
doc/main-fpga-e203/silicon_bringup_uart_capture_20260423_120301.txt
fpga/boards/zcu102/constraints_e203.xdc
fpga/boards/zcu102/snn_soc_fpga_top.sv
fpga/cim_model/cim_fpga_programmable_model.sv
fpga_synth/zcu102_e203_demo/build_e203_demo.sh
fpga_synth/zcu102_e203_demo/build_e203_demo.tcl
fw/e203_smoke/build_e203_smoke.sh
fw/e203_smoke/e203_fpga_smoke.c
fw/e203_smoke/out/e203_smoke.{bin,dump,elf,hex,map,_crt0.o,_main.o,_uart.o}
scripts/gen_bram_init.py
scripts/program_zcu102_e203.tcl
sim/run_fpga_programmable_cim_model.sh
sim/sim_fpga_programmable_cim_model.f
tb/fpga_programmable_cim_model_tb.sv
```

✓ 25/25 全部 FPGA-only，无 RTL / shared FW / shared TB / shared doc 漂移。

## sim regression 状态（push 前 8/8 PASS）

跑于 main worktree（commit `bd78a0b0` 已 stage）：

| TB | Status | Notes |
|---|---|---|
| run_chip_top_rom_smoke | CHIP_TOP_ROM_SMOKE_PASS | 验证 RTL B-1（chip_top default boot ROM hex） |
| run_chip_top_rom_hi_smoke | CHIP_TOP_ROM_HI_SMOKE_PASS | 高地址段 boot ROM 切换 |
| run_cim_program_ctrl | CIM_PROGRAM_CTRL_PASS (8/8 sub-tests) | 验证 RTL B-2（verify window 16 levels） |
| run_dma_icarus | DMA_SMOKETEST_PASS | 验证 R-M2（push_stall_cnt timeout） |
| run_uart_icarus | UART_SMOKETEST_PASS (14/14) | 验证 R-M1.1（TX 启动 wstrb[0] gate） |
| run_spi_icarus | SPI_SMOKETEST_PASS | 既有 byte-strobe coverage |
| run_prog_inflight_lock | PROG_INFLIGHT_LOCK_TB_PASS | reg_bank PROG_* in-flight lock |
| run_boot_erase_e2e | BOOT_ERASE_E2E_TB_PASS | boot+erase 端到端链路 |

辅助检查：
- `python scripts/check_markdown_links.py` → MARKDOWN_LINK_CHECK_PASS (45 files)
- `git diff --name-only origin/main origin/main-fpga-e203-alpha | wc -l` → 25

## 修不动 / 需人工决策的项

无。本轮 audit 抓到的 W-1a / W-1b / R-M1.1 / D-1 都已修复 + push + sim 验证通过 +
跨分支同步完成。MINOR M-1..M-4 留作 follow-up，已在上表列出建议处理路径。

## 审查方法摘要

按 prompt §三 七大维度逐项 cover：

1. **跨分支一致性**（§3.1）✓：`git diff --name-only` 仅 25 个 FPGA-only 文件
2. **RTL 层**（§3.2）✓：B-1 / B-2 / R-M1 / R-M2 / CDC / 复位 / byte-strobe / 位宽
   - chip_top.sv / cim_program_ctrl.sv / cim_macro_blackbox.sv / uart_ctrl.sv /
     spi_ctrl.sv / dma_engine.sv / reg_bank.sv / jtag_mem_loader.sv 全文逐句过
   - 对照 CLAUDE.md FP-001..FP-005 误报库，避免重复误判（lif_neurons `<<<` /
     output FIFO 4-bit 位宽 / dma `addr_ptr-4` / 零长度 DMA / fifo_sync CDC 都
     **未**作为新问题报告）
3. **FW 层**（§3.3）✓：silicon_bringup.{c,bin,hex} 一致性 + soc_regs.h vs RTL
   - 抓到 silicon_bringup.bin 漏 add（W-1a）、PROG_* 宏散布（M-2）、`__DATE__`
     reproducibility（M-1）
4. **TB / sim 层**（§3.4）✓：8/8 核心 TB 全 PASS；watchdog 数值合理
5. **文档层**（§3.5）✓：silicon_bringup_plan §6 R-C9 description 完整 + code
   template 修正宏名（D-1）；07_tapeout_schedule §2026-05-02 sync 完整；
   CLAUDE.md 参数表与 RTL 一致（无新增 FP）；markdown links 45/45 PASS
6. **边界 / 可疑点**（§3.6）✓：dma push_stall_cnt 走出 ST_PUSH 必经 line 350
   清零 → 再次进入时一定 = 0；BOOT_ROM_INIT_FILE 相对路径在 FPGA / sim TB
   override / mask ROM compiler 三种场景都合理；R-C9 软件 lock 不会被
   silicon_bringup helper 函数泄漏到生产 binary（doc §6.6 已透明披露）

## 关键决策记录

- **silicon_bringup.bin track**：与 boot_rom.bin 风格一致 + 硅片回来 day 1
  烧 SPI flash 需要 raw bytes，决定 git add（W-1a）。前 3348 bytes 与 hex
  字节完全对齐验证 ✓。
- **rom_smoke_*/rom_hi_smoke_* gitignore**：sim 现场 build artifact 不是流片
  对象，加入 .gitignore（W-1b）。
- **`__DATE__` reproducibility**：未修，作为 build provenance feature；列入
  M-1 follow-up，由用户决定是否引入 SOURCE_DATE_EPOCH 流程。
- **R-M1.1 严重度**：标 CONCERN 而非 BLOCKER，因为现有 fw 全部用 store-word
  写 UART_TXDATA，硅片实际不会触发；但严格 byte-strobe 完整性要求与
  txdata_shadow 写路径对齐，已修。
- **B-2 commit message 措辞**：未单独修复 commit message（cosmetic），仅
  在本报告中记录 "level=15 LRS 饱和到 250+" 措辞与实际 fix（clamp 到 [0,255]）
  的偏差；fix 行为本身正确。

完。
