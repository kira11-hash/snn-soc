# Claude Prompt: `feature/v2-fpga-e203` Board-Ready Handoff

你接手的是 `D:/SoC Design/SoC Design` 的 `feature/v2-fpga-e203`。请不要回退用户或 GPT 已做的改动；当前目标是上 ZCU102 做 G3 烧板验证。

## 当前结论

Phase B 已允许并已执行完成。Phase A 的 100-count bit-exact cosim 在 Icarus 下仍未完成，原因仍是 wall-clock 过长；这不是 Phase B 综合/bitgen blocker。bit-exact 推理结果验证转移到 FPGA G3。

准入判断：
- Q1 PASS：允许 Phase B，综合/bitgen 与 Icarus 100-count bit-exact 无直接依赖。
- Q2 CONCERN：full-top Icarus 未跑到 `INFER_DONE`，若 FPGA 上长期无 `MULTILAYER_INFER_PASS`，优先查 bridge/fabric/adapter + real v2b_top 集成路径。
- Q3 PASS：encoder RPC 路径在 Icarus 下有效；真实 Bresenham encoder 在 board-ready build 中已启用。
- Q4 PASS：`SIM_FAST=0` 默认不定义 `NUM_COSIM_SAMPLES`，固件 fallback 到 `GOLDEN_NUM_SAMPLES=10`。
- Q5 PASS：板级 wrapper、XDC、Vivado Tcl/sh、program Tcl 已补齐。
- Q6 CONCERN：DRC 有 DSP pipeline 建议，不影响 50 MHz timing；上板仍需 UART 实测闭环。

## 已修的关键 blocker

1. `rtl/mem/sram_simple.sv`
   - 增加 `INIT_FILE` 参数，在 memory module 内部 `$readmemh`，Vivado 可把 firmware hex 写进 BRAM INIT。
   - 将总线写和 DMA 写改为单写端口 mux，保留 DMA > bus 优先级。
   - 修复 Vivado 原错误：`Unable to infer a block/distributed RAM for mem_reg`，64 KB IMEM 不再被尝试拆成寄存器。

2. `rtl/top/e203_min_wrap.sv`
   - 在 `SOC_ENABLE_E203_VENDOR` 下 include `e203_defines.v`。
   - 显式 tie-off E203 external ITCM/DTCM ports，消除 Vivado 对未连接 ext2itcm/ext2dtcm 端口的风险。
   - include 用 `ifdef SOC_ENABLE_E203_VENDOR` 包住，避免不带 vendor incdir 的 V1/V2 baseline TB 回归。

3. `rtl/top/snn_soc_v2b_e203_top.sv`
   - IMEM instance 将 `INSTR_INIT_FILE` 传给 `sram_simple.INIT_FILE`。
   - 功能仿真保持 `INSTR_INIT_FILE=""`，TB 继续 hierarchical load。

4. `fw/v2_e203_smoke/build_v2_e203_smoke.sh`
   - 默认 `SIM_FAST=0`：board-ready，10 样本，真实 encoder，不加 `ICARUS_SKIP_ENCODE`。
   - `SIM_FAST=1`：Icarus 快速模式，限制样本数并启用 skip encoder marker。

5. 新增/补齐
   - `fpga/boards/zcu102_v2_e203/snn_soc_v2b_e203_fpga_top.sv`
   - `fpga/boards/zcu102_v2_e203/constraints_v2_e203.xdc`
   - `fpga_synth/zcu102_v2_e203_demo/build_v2_e203_demo.{tcl,sh}`
   - `scripts/program_zcu102_v2_e203.tcl`

## 已跑验证

Phase A 快速门禁：
- `run_multilayer.sh` -> `MULTILAYER_SMOKE_PASS`
- `run_fw_cosim_resident_14x14.sh` -> `FW_COSIM_RESIDENT_14X14_TB_PASS`
- `run_bus_interconnect_v2_e203.sh` -> `BUS_INTERCONNECT_V2_E203_PASS`
- `run_icb2simple_bridge_v2b.sh` -> `ICB2SIMPLE_BRIDGE_V2B_PASS`
- `run_simple2v2btop_adapter.sh` -> `SIMPLE2V2BTOP_ADAPTER_PASS`
- `run_v2_e203_bus_chain_tb.sh` -> `V2_E203_BUS_CHAIN_PASS`
- `run_v2_e203_soc_compile.sh` -> `V2_E203_SOC_COMPILE_PASS`
- `run_v2_e203_encoder_parity.sh` -> `V2_E203_ENCODER_PARITY_PASS`
- `run_v2_e203_cosim.sh` -> `V2_E203_COSIM_PASS`

Board-ready firmware:
- `SIM_FAST=0 bash fw/v2_e203_smoke/build_v2_e203_smoke.sh`
- smoke: `text=30540`, `bss=4560`
- encoder real path: `text=3156`, `bss=4108`

Vivado Phase B:
- Command: `bash fpga_synth/zcu102_v2_e203_demo/build_v2_e203_demo.sh`
- Bitstream: `fpga_synth/zcu102_v2_e203_demo/out/snn_soc_v2b_e203_fpga_top.bit`
- Timing: WNS `4.837 ns`, TNS `0.000`, WHS `0.012`; all user timing constraints met.
- Route: fully routed, routing errors `0`.
- Utilization: CLB LUTs `21.59%`, CLB registers `2.51%`, BRAM tile `10.53%`, DSP `0.08%`.
- DRC: 7 warnings only: DSP pipeline suggestions and E203 internal no-load nets; no DRC errors.

## 烧板步骤

用户已说 FPGA 就绪，但必须等用户明确下令开始烧录。

烧录命令：

```bash
xsct scripts/program_zcu102_v2_e203.tcl fpga_synth/zcu102_v2_e203_demo/out/snn_soc_v2b_e203_fpga_top.bit
```

UART：
- ZCU102 J83 CP2108 Interface 2
- 115200 8N1, no flow control
- 预期先看到 `FPGA_V2_E203_BOOT_UART_PASS`
- 然后等待 10 个 sample counts
- 最终目标：`FPGA_V2_E203_MULTILAYER_INFER_PASS`

若卡住：
- 有 boot tag 但无 infer pass：优先查 stage_engine busy / adapter start pulse / v2b `STAGE_CTRL.START`。
- 无 boot tag：查 clock/reset、UART pin/channel、BRAM init hex、E203 PC。
- counts 与 golden 不一致：保存完整 UART log，按 `python_multilayer/results_multilayer/fashion_multilayer_golden/sample_00..09_counts.txt` 对比。
