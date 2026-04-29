# `fw/main.c` 开机擦除 — FPGA 板上复验说明

**日期**：2026-04-24
**关联 commit**：
- `e56c7c05` fw(main): add boot-time RRAM full-array erase (P2-1 closed)
- `6df4446f` fw+tb: make boot-time erase work in e203 regression

**关联决策**：器件老师 2026-04-24 确认"RRAM 流片后需要开机擦除"（doc/11 P2-1）。

## 结论

**`fw/main.c` 改动不需要重跑 FPGA 板上验证**。
现有 `main-fpga-e203-alpha-passed` tag（完整板验日志见 `main-fpga-e203-alpha` 分支内的 `doc/main-fpga-e203/board_bringup_log_c0c1c2.txt`）的证据链已经覆盖开机擦除路径。

## 理由

本次要求的"开机擦除"在项目里是**两条相互独立的固件路径**：

| 固件 | 角色 | 全阵列擦除已经实现 |
|---|---|---|
| `fw/main.c` (+ `fw/boot_main.c` bootloader) | **tape-out silicon 的 SPI flash 启动路径** | ✅ 由本次 `e56c7c05` 新增 |
| `fw/e203_smoke/e203_fpga_smoke.c` | **FPGA ZCU102 bitstream 的 BRAM pre-init 启动路径** | ✅ **本来就做**（Phase 1 Step 1a） |

### FPGA 路径本来就擦

`fw/e203_smoke/e203_fpga_smoke.c` 第 68-72 行：
```c
// Step 1a: full-array erase
// PROG_CTRL[2]=FULL_ARRAY, [1]=ERASE, [0]=START(W1P)
PROG_CTRL = 0x07u;
(void)wait_prog_done();
uart_puts("[PROG] full-array erase DONE\n");
```

FPGA build 脚本 `fpga_synth/zcu102_e203_demo/build_e203_demo.sh` 默认用的就是这份 hex（`fw/e203_smoke/out/e203_smoke.hex`，不是 `fw/out/flash_image.hex`）。所以当 `main-fpga-e203-alpha-passed` 在 2026-04-24 通过板上验证时：
```
UART_OK
FPGA_E203_BOOT_UART_PASS
[PROG] full-array erase DONE           ← 全阵列擦除已在板上实测通过
[PROG] write subset rows=0..9 cols=0..9 PASS
FPGA_E203_PROGRAM_ERASE_WRITE_PASS
...
FPGA_E203_PROGRAMMED_INFERENCE_PASS
```
"全阵列擦除 → 写 → verify → 推理" 整条链路**已经在 FPGA 上实测过**。器件老师今天的"开机必须擦除"确认，对 FPGA 路径是"已经这么做了"，不是新需求。

### 为什么还要改 `fw/main.c`？

因为 tape-out silicon 的启动流是：
```
ROM bootloader (fw/boot_main.c) → 从 SPI flash 把 app 加载到 INSTR_SRAM → 跳到 app
                                                                          │
                                                                          ▼
                                                               fw/main.c 从这里起跑
```

ROM bootloader 只负责搬码，不触碰 RRAM；app (fw/main.c) 才是真正做推理的代码。app 要想在"开机初始态是 HRS / LRS / 随机"的 cell 上跑出干净推理，**必须在跑推理前自己做一次全阵列擦除**。这就是 `e56c7c05` 加的事。

`fw/main.c` 不是 FPGA 的 BRAM pre-init 固件，**它只在 tape-out silicon 上跑**。因此：
- ✅ Icarus e203 smoke 覆盖了这条路径的数字语义（`E203_SMOKETEST_PASS`，新 `APP erase SEQ_DONE` 日志；这里的语义是“控制器完成 full-array erase 时序”，不是固件逐 cell spot-verify）
- ⏳ 真实 tape-out silicon 路径的物理验证，要等数字 die 回片 + PCB 装配 + 模拟 die 到位之后，一次性和 silicon_bringup、真实擦除、真实权重写入、真实推理一起做

## Regression 证据（本次 commits 之后）

### Main 分支 Gate A 全套 15/15 PASS
- LIGHT / WEIGHTED / DMA / CIM_PROGRAM_CTRL
- UART / SPI / PROG_PULSE_CFG / PROG_START_INTERLOCK
- BOOT_ROM / SILICON_BRINGUP
- **E203_SMOKETEST_PASS**（新：看到 `APP erase SEQ_DONE` + count=100 + neuron[0..9]=10 each）
- CHIP_TOP_ROM_SMOKE / PROG_BYPASS_LATCH / PROG_PAD_ENCODER / PROG_WL_PAD_ROUTE

### Alpha 分支 E203 smoke（cherry-pick 后）
同样 `APP erase SEQ_DONE` + `E203_SMOKETEST_PASS`。alpha 分支整体以 `main-fpga-e203-alpha-passed` tag 为证据底座，tag 本身未动。

## 下次真正触发板上复验的条件

如果未来有以下任一变更，**要重新烧 bitstream + 上板跑 `fpga_bringup_capture.sh`**：

1. 改动 `fw/e203_smoke/e203_fpga_smoke.c`（FPGA BRAM init 固件本身）
2. 改动 RTL 里影响 `snn_soc_top` / `cim_program_ctrl` / `cim_macro_arbiter` / `wl_mux_wrapper` / `cim_macro_blackbox` 等 FPGA 综合路径的文件
3. 改动 ZCU102 wrapper（`fpga/boards/zcu102/snn_soc_fpga_top.sv`）或 XDC 约束
4. 把 `fw/main.c` 的某个版本引入到 FPGA pre-init（目前没有这个计划）

本次的 `fw/main.c` 改动**不在**这四条里的任何一条。
