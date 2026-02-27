# 11_模拟对接与近期执行清单（定版后）

## 1) 当前冻结口径（先统一这件事）
- Python/RTL 当前冻结参数：`proj_sup_64 + Scheme B + ADC=8 + W=4 + T=10 + ratio_code=4(4/255)`.
- 默认阈值：`THRESHOLD_DEFAULT=10200 (=4*255*10)`.
- 对齐结果口径：`spike-only`，`zero-spike=0.00%`。
- 参考结果文件：`项目相关文件/器件对齐/Python建模/results/summary.txt`。

## 2) 发给模拟同学的文档（按顺序）
1. `doc/08_cim_analog_interface.md`（主合同，信号+时序+责任边界）
2. `doc/03_cim_if_protocol.md`（快速协议版）
3. `doc/02_reg_map.md`（寄存器与可调参数口径）
4. `SNNSoC工程主文档.md`（只看“关键决策点 / 定版参数 / 45-pin相关章节”）

补充建议一起发：
- `项目相关文件/09_analog_team_handoff.md`（会前问题清单与会后动作映射）

## 3) 会上问题优先级（建议固定流程）
- 第 1 优先：`A7`（时序合同）
  - 目标：先把脉冲语义定死：`cim_done/adc_done` 脉宽、`dac_ready` 行为、guard time。
- 第 2 优先：`A5`（每阶段真实延迟）
  - 目标：拿到 WL 建立 / CIM 稳定 / ADC MUX 建立 / ADC 转换的 ns 与 cycles。
- 第 3 优先：`A4`（Vref + TIA 增益）
  - 目标：建立“ADC 码值 ↔ 物理电流”映射，避免阈值物理意义漂移。
- 第 4 优先：`A6`（噪声与动态范围）
  - 目标：确认当前阈值健壮性，判断是否要回标 Python 噪声参数。
- 第 5 优先：`P0/P1/P2`（物理映射与供电偏置）
  - 目标：确定 pad wrapper 最终连法与后端约束输入。

## 4) 要求模拟同学“按表给值”的关键信息（拿不到就不能收口）
- `A7`：每个握手信号的主从、有效沿、脉宽（cycles）、是否允许 back-to-back。
- `A5`：每阶段延迟（ns/cycles）+ 最坏 PVT 数值。
- `A4`：Vref 高低点、TIA 增益标称/容差、是否可调、温漂。
- `A6`：噪声（LSB RMS / pp）、最小可检电流、ENOB、温漂影响。
- `P0`：最终 pin list（45-pin 定稿）与宏接口方位。
- `P1`：AVDD/DVDD 约束、偏置来源、是否新增外部引脚。
- `P2`：RRAM 上电状态、retention/read-disturb、V1 是否需写入流程。

## 5) 等待反馈期间你该做什么（顺序）
- Step A：先跑 smoke test（数字链路）
  - 目标：确认 `top_tb` 基线可稳定通过（寄存器配置 → DMA → 推理 → 输出）。
  - 建议重点观测：`DONE`、FIFO 计数、`ADC_SAT_COUNT`、debug counter。
- Step B：按 `doc/06_learning_path.md` Stage A→E 过代码
  - A: `snn_soc_pkg.sv`（参数与时序）
  - B: `reg_bank.sv` + bus（控制口径）
  - C: `dma_engine.sv` + FIFO（数据搬运）
  - D: `cim_array_ctrl.sv`/`adc_ctrl.sv`/`lif_neurons.sv`（推理核心）
  - E: `wl_mux_wrapper.sv` + `chip_top.sv`（封装与集成）
- Step C：整理一页“待回填参数表”
  - 直接按 A4/A5/A6/A7/P0/P1/P2 建表，等待会上填值后回写。

## 6) 拿到模拟参数后，你的改码顺序（固定）
1. 先改时序参数（A5）：`rtl/top/snn_soc_pkg.sv`
2. 重跑 SV lint + smoke test（先验证数字状态机无回归）
3. 再改建模噪声/量程（A4/A6）：`项目相关文件/器件对齐/Python建模/config.py`
4. 跑 `--skip-train` 做快速一致性回归（只验证推理链路）
5. 如精度/稳定性变化超阈值，再决定是否重跑 full
6. 最后处理 pad/物理映射（P0/P1/P2）：`rtl/top/chip_top.sv` + 文档

## 7) 返工触发条件（避免反复改）
- 若 `A7` 未定：先不改握手 RTL。
- 若 `A5` 未给最坏值：先不冻结周期参数。
- 若 `A4/A6` 只有定性没有定量：先不改 Python 噪声/满量程。
- 若 `P0` 未给最终 pin list：先不做 pad-level 定稿提交。

## 8) 你当前计划评估
- 你现在的顺序（08→03→02→主文档节选；A7→A5→A4→A6→P0；等待期做 smoke+学代码）是合理且可执行的。
- 建议只加一条：会上要求“表格化回填 + 版本号 + 日期 + 负责人”，避免会后口径漂移。
