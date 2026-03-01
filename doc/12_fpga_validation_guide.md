# 12_fpga_validation_guide

## 0. 目的与边界

本文件用于定义 SNN SoC 在后端前的 FPGA 系统验证流程，目标是提前发现系统集成问题，降低 tapeout 前返工风险。

- 目标：验证数字系统级可运行性（寄存器、总线、DMA/FIFO、控制流、固件流程、长时稳定性）。
- 非目标：
  - 不替代 DC/STA/LEC/DRC/LVS 签核。
  - 不替代真实模拟宏验证（IR drop、噪声、漂移、器件波动）。
  - 不作为最终性能/功耗结论依据。

## 1. 建议执行时机

建议在以下条件满足后执行一次完整 FPGA 验证：

1. UART/SPI/AXI/E203 的主功能链路已连通。
2. RTL smoke test（仿真）稳定通过。
3. 关键接口文档已冻结（至少冻结一版）。

一句话：FPGA 是“后端前系统门禁”，不是“替代后端签核”。

## 2. 工程组织原则（避免污染 ASIC 主线 RTL）

FPGA 适配要和 ASIC 主线解耦，防止“为上板临时改 RTL”带回主分支。

- ASIC 主线保留：`rtl/`、`tb/`、`sim/`。
- FPGA 专用文件集中到新目录：`fpga/`。
- 板级 top、时钟/复位生成、约束（XDC）、IP wrapper、下载脚本只放 `fpga/`。
- 通过 `ifdef FPGA` 或独立 wrapper 做适配，不直接改动功能 RTL 行为。

推荐目录：

```text
fpga/
  boards/
    <board_name>/
      constraints.xdc
      top_fpga.sv
      build.tcl
      program.tcl
  ip/
    clk_wiz_wrapper.sv
    ila_stub.sv
  cim_model/
    cim_fpga_model.sv
  scripts/
    build_vivado.ps1
    run_smoke_fpga.ps1
  README.md
```

## 3. FPGA 上 CIM 的处理策略

真实 RRAM/CIM 宏无法在 FPGA 上实现，需替代模型。

- 方案 A（优先，最快）：继续使用行为模型（`cim_macro_blackbox.sv` 的可综合替代实现或等价模块）。
- 方案 B（增强）：用 BRAM 存权重表，做数字乘加近似 CIM。

建议节奏：先 A 跑通控制链路，再 B 做算法一致性验证。

## 4. 执行流程（详细）

### Step 1: 基线冻结

1. 记录当前 commit/tag（例如 `pre_fpga_gate_YYYYMMDD`）。
2. 先跑 RTL smoke（仿真）并保存日志。
3. 冻结一版寄存器表与接口文档（至少 `doc/02`、`doc/03`、`doc/08`、`doc/11`）。

交付：`baseline_sim.log`、commit id、文档版本号。

### Step 2: 建立 FPGA 适配层

1. 新建 `fpga/boards/<board>/top_fpga.sv`。
2. 引入板级时钟/复位逻辑（PLL/MMCM、复位同步）。
3. 将 SoC 顶层接到板级 IO（UART、按键、LED、调试口等）。
4. 不改 SoC 主状态机语义，只做外壳连接与时序适配。

检查点：综合通过，无关键未连接端口、无多驱动。

### Step 3: 固件/输入加载策略

优先使用最省事模式完成首轮联调：

- 推荐：`$readmemh` 预加载 SRAM/ROM（bitstream 上电即跑）。
- 之后再切换 UART/SPI 实时加载，验证通信链路。

检查点：能稳定触发一次完整推理流程并读回结果。

### Step 4: 生成 bitstream 并上板

1. 使用 Tcl 脚本批处理综合/实现/生成 bitstream。
2. 固化脚本化流程，避免 GUI 手工操作不可复现。
3. 下载 bitstream 后执行冒烟流程。

建议最小冒烟序列：

1. 读版本寄存器（确认总线可用）。
2. 写配置寄存器后读回（确认可写可读）。
3. 启动 DMA 并观察 done/err 位。
4. 启动 CIM 流程并读 `OUT_FIFO_COUNT`。
5. 拉通一次 end-to-end（含输出读取）。

### Step 5: 对齐验证

对齐对象：RTL 仿真 vs FPGA 实测。

- 对齐内容：状态机阶段顺序、关键计数器单调性、done/err 语义。
- 允许差异：绝对周期数（FPGA 时钟/等待策略不同）。
- 不允许差异：状态机非法跳转、寄存器语义不一致、DONE/ERR 定义漂移。

### Step 6: 稳定性回归

至少做一项长期测试：

- `>=1k` 次短任务循环，或
- 连续运行 `>=1h`。

通过条件：无死锁、无不可恢复错误、错误计数器不异常累积。

## 5. Go/No-Go 门禁标准

满足以下全部条件才建议进入后端主线：

1. 寄存器读写与启动流程稳定。
2. `data_sram -> DMA -> input_fifo -> CIM替代模型 -> ADC替代模型 -> LIF -> output_fifo` 链路可重复通过。
3. RTL 与 FPGA 的控制流语义一致。
4. 长稳测试通过（无卡死/无不可恢复 error）。
5. 关键文档版本与上板实现一致。

## 6. 常见风险与规避

- 时钟/复位问题：外部按键复位必须同步释放，避免亚稳态。
- CDC 问题：跨时钟域接口要有同步器或握手。
- 初始化问题：未初始化 RAM/FIFO 会导致“偶发通过”。
- 语义漂移：为 FPGA 临时改寄存器语义，导致和仿真/文档不一致。
- 过度依赖 ILA：ILA 只用于定位问题，不能替代可重复脚本化测试。

## 7. 与后端工作的衔接

FPGA 通过后，建议立即做三件事：

1. 冻结一版“可后端输入”的 RTL/tag。
2. 输出一份 `fpga_gate_report.md`（记录测试范围、通过项、残留风险）。
3. 明确未覆盖项（例如真实模拟非理想、真实 pad 电气约束），避免误判“已全验证”。

## 8. 建议交付物清单

- bitstream 文件与生成脚本（含版本号）。
- 板级 top 与约束文件（`top_fpga.sv` + `constraints.xdc`）。
- 上板 smoke 日志（寄存器读写、DMA/CIM 完成、输出计数）。
- 与 RTL 对齐记录（至少一份对照表）。
- `fpga_gate_report.md`（通过项/未覆盖项/后续动作）。

## 9. 与现有文档关系

- 本文是 FPGA 详细执行文档。
- 主文档只保留粗略门禁说明，避免重复与口径漂移。
- 冒烟执行细节仍以 `doc/09_smoke_test_checklist.md` 为准。
