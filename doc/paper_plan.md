# 论文计划（冻结版，E0 前置重排）

**1. 最终论文元数据**

主选题目：`A CIM-Ready Digital SNN SoC for RRAM Integration with Interface-Compatible Macro Substitution and Macro-Absent Bring-Up`

备选题目：`Digital SNN SoC Design for RRAM-CIM Integration: Interface Contract, Validation Continuity, and FPGA-Assisted Prototype Evidence`

三条 contribution 的英文正式表述：
1. `We present a SoC-oriented digital SNN architecture for RRAM-CIM integration, built around a parameterized digital CIM interface contract that decouples the downstream digital pipeline from backend macro implementation.`
2. `We establish an interface-compatible, hierarchical validation path spanning L0 Test Mode, L1 RTL behavioral macro, L2 FPGA weight-loaded macro model, and a future L3 real macro, thereby preserving control-path invariance under macro substitution.`
3. `We implement a macro-absent digital bring-up mechanism via CIM Test Mode with programmable uniform differential injection, enabling self-check of the digital control and inference chain before analog macro availability.`

英文摘要草稿：
`We present a CIM-ready digital spiking neural network (SNN) SoC for RRAM-oriented back-end integration. The work addresses a practical pre-silicon challenge: digital development must proceed before a real CIM macro is available. To this end, we define a parameterized digital CIM interface contract and implement an interface-compatible validation stack spanning L0 Test Mode, L1 RTL behavioral macro, L2 FPGA weight-loaded model, and a future L3 real macro. The downstream digital pipeline remains unchanged across these levels. We further provide a macro-absent bring-up mechanism and report Python-guided design-point locking together with FPGA implementation evidence on ZCU102.`

**投稿策略**

首选：`Microelectronics Journal`
- 优点：范围很宽，微电子系统、架构、实现、验证都能收。
- 当前官方信息显示其为 SCIE，Impact Factor 2.3，Submission to acceptance 约 69 天，可走 subscription 无需 APC。[官方页](https://www.sciencedirect.com/journal/microelectronics-journal/about/insights)
- 你这篇文章按“数字 SoC + 实现 + 少量建模支撑”去写，和它最匹配。
- 期刊里近年也有 SNN/硬件加速相关文章，例如 2025 年的 SCNN accelerator 论文。[示例](https://www.sciencedirect.com/science/article/pii/S1879239125000657)

次选：`Integration, the VLSI Journal`
- 优点：题目非常对口，范围明确覆盖设计、验证、测试、嵌入式系统和新型器件/架构。
- 缺点：当前官方显示 Submission to acceptance 约 144 天，明显更慢。[官方页](https://www.sciencedirect.com/journal/integration/about/insights)
- 如果你把 E203/UART/SPI 也顺手接进来、文章更像完整 VLSI system paper，再投它。

备选：`Microelectronics Reliability`
- 只有当你明显把文章往“testability / bring-up / validation risk reduction”方向写时才合适。
- 当前官方显示 SCIE，Impact Factor 1.9，Submission to acceptance 约 121 天。[官方页](https://www.sciencedirect.com/journal/microelectronics-reliability/about/insights)

我的建议很明确：
- 先写 `Microelectronics Journal` 版本。
- 不要等 E203 全部收尾后再写。
- 如果 E203 最小闭环在投稿前自然完成，再升级文章，而不是把它设成硬门槛。

**2. 完整论文结构**

| Section | 要回答的问题 | 必备图/表 | 数据来源 |
|---|---|---|---|
| 1. Introduction | 为什么 `real CIM macro absent` 是真实 IC 问题；为什么数字侧不能等模拟侧 | Fig.1 问题背景与证据链图；Table.1 本文贡献概览 | 架构主线来自 [snn_soc_top.sv](D:/SoC%20Design/SoC%20Design/rtl/top/snn_soc_top.sv)、[snn_soc_pkg.sv](D:/SoC%20Design/SoC%20Design/rtl/top/snn_soc_pkg.sv) |
| 2. Related Work | 现有工作缺什么；你的 gap 是什么；外部结构化 baseline 如何定义 | Table.2 Related work matrix | 本地文献库 [SNN SoC相关文献](D:/SoC%20Design/SoC%20Design/项目相关文件/SNN%20SoC相关文献) |
| 3. Architecture Overview | 这是不是 complete digital SNN SoC with RISC-V control plane，而不是孤立 accelerator | Fig.2 系统框图 | [snn_soc_top.sv](D:/SoC%20Design/SoC%20Design/rtl/top/snn_soc_top.sv)、[top_fpga_arm.sv](D:/SoC%20Design/SoC%20Design/fpga/boards/zcu102/top_fpga_arm.sv)、E203/UART/SPI 合入后的顶层/互连文件 |
| 4. CIM Interface Contract | 真实宏需要满足什么接口契约；为什么数字侧对 latency variation 容忍 | Table.3 接口契约表；Fig.3 handshake timing 图 | 权威口径用 [03_cim_if_protocol.md](D:/SoC%20Design/SoC%20Design/doc/03_cim_if_protocol.md)、[08_cim_analog_interface.md](D:/SoC%20Design/SoC%20Design/doc/08_cim_analog_interface.md)、[snn_soc_pkg.sv](D:/SoC%20Design/SoC%20Design/rtl/top/snn_soc_pkg.sv)、[cim_array_ctrl.sv](D:/SoC%20Design/SoC%20Design/rtl/snn/cim_array_ctrl.sv)、[adc_ctrl.sv](D:/SoC%20Design/SoC%20Design/rtl/snn/adc_ctrl.sv)；不要引用已过时的 [CIM_Macro_Interface_Specification.md](D:/SoC%20Design/SoC%20Design/doc/develop%20docs/CIM_Macro_Interface_Specification.md) 作为权威 |
| 5. Macro-Substitutable Validation Stack | L0/L1/L2/L3 分别是什么；替换后什么保持不变 | Fig.4 模型替换示意图 | [reg_bank.sv](D:/SoC%20Design/SoC%20Design/rtl/reg/reg_bank.sv)、[cim_macro_blackbox.sv](D:/SoC%20Design/SoC%20Design/rtl/snn/cim_macro_blackbox.sv)、[cim_fpga_model.sv](D:/SoC%20Design/SoC%20Design/fpga/cim_model/cim_fpga_model.sv) |
| 6. Design-Point Locking | 参数为什么这样选；Python 在文中扮演什么角色；在固定 64 输入接口下，非神经网络前端主配置如何确定；内部定量 baseline 如何定义 | Fig.5 参数锁定图；Table.4 最终配置表 | E0 三阶段正式输出：`results/paper_e0/stage1/`（方法排序与粗扫 ratio）、`results/paper_e0/stage2/`（fine ratio 与 finalists）、`results/paper_e0/stage3/`（硬件网格 + A/B + noise + adaptive + final test）；旧 `results/summary.txt` 和 `exhaustive_*.csv` 仅作历史参考；最终数值以 [snn_soc_pkg.sv](D:/SoC%20Design/SoC%20Design/rtl/top/snn_soc_pkg.sv) 为准 |
| 7. Validation and Prototype Evidence | 你的主实验 A/B/C/D 是什么，证据够不够；内部验证 baseline 是否闭环；这些结果是否都建立在 E0 冻结后的新 RTL/新 Step2/3 上 | Table.5 协议/时序一致性；Fig.6 Python vs L2；Fig.7 Test Mode；Table.6 FPGA 实现结果 | 见第 3 节实验计划；所有正式结果以 E0 之后重新生成的仿真、Step2、Step3 产物为准，旧 `project_2/project_5` 只作为历史参考，不作为投稿结果来源 |
| 8. Discussion and Limitations | 你没有真实宏/流片数据，边界在哪 | Table.7 限制与未来工作 | 直接基于实验边界与接口契约表 |
| 9. Conclusion | 你解决了什么，没解决什么 | 无新图表 | 全文总结 |

**3. 完整实验计划**

执行总原则：
- `E0` 现在是总开关。
- `E0` 冻结之前，不再把旧仿真、旧 Step2、旧 Step3 当成正式论文结果。
- `E0` 之后必须先完成 `RTL/配置同步 -> 仿真与 smoke test 重跑 -> Step2/Step3 重跑`，然后再继续 A-F 的正式结果采集。

| 实验/阶段 | 目的 | 具体操作步骤 | 输入/脚本 | 预期输出 | 论文对应 |
|---|---|---|---|---|---|
| E0 参数冻结核对 | 消灭口径冲突，尤其是 `summary.txt` 与 `pkg` 不一致，并在固定 64 输入接口下确定非神经网络主配置与内部定量 baseline | 1. 以 [snn_soc_pkg.sv](D:/SoC%20Design/SoC%20Design/rtl/top/snn_soc_pkg.sv) 冻结最终硬件参数；2. 使用 `paper_e0_runner.py` 三阶段流程重跑全部 6 个 shortlist 方法：`avgpool_8x8`、`pad32_zero_8x8`、`pad32_reflect_8x8`、`pad32_replicate_8x8`、`maxpool_8x8`、`proj_sup_64`；3. Stage 1 粗扫 ratio（0.01~0.50），Stage 2 细扫 finalists，Stage 3 全量硬件网格 + A/B 对照 + noise + adaptive + final test；4. 不重跑 `7x7` 系列、`proj_pca_64` 和全量无关方法；5. Stage 1 不使用 `--skip-train`（需训练全部 6 个方法的 ANN 权重），Stage 2/3 可 `--skip-train` 复用已保存权重；6. 旧 [summary.txt](D:/SoC%20Design/SoC%20Design/项目相关文件/器件对齐/Python建模/results/summary.txt) 和旧 `csv` 只做历史参考；7. 写一页 `paper_facts.md` 记录最终口径，并把 `proj_sup_64` 降级为 learned upper-bound reference；8. 将非神经网络方法中的 top-2 与 `proj_sup_64` 形成主文内部定量 baseline，`proj_sup_64` 仅作为 learned upper-bound reference，不作为主部署前端 | [paper_e0_runner.py](D:/SoC%20Design/SoC%20Design/项目相关文件/器件对齐/Python建模/paper_e0_runner.py)、[paper_e0_presets.py](D:/SoC%20Design/SoC%20Design/项目相关文件/器件对齐/Python建模/paper_e0_presets.py)、[paper_e0_stage_plan_v1.md](D:/SoC%20Design/SoC%20Design/项目相关文件/器件对齐/Python建模/paper_e0_stage_plan_v1.md)、[snn_soc_pkg.sv](D:/SoC%20Design/SoC%20Design/rtl/top/snn_soc_pkg.sv)、[config.py](D:/SoC%20Design/SoC%20Design/项目相关文件/器件对齐/Python建模/config.py) | Table.4 最终配置表；Fig.5 参数锁定图 | Section 6 |
| E0.5 配置同步与 smoke 重基线 | 让后续全部实验建立在 E0 冻结后的统一口径上 | 1. 按 E0 Stage 2 结果确认主前端方法（如 `avgpool_8x8`）及其最终 `threshold_ratio`；2. 更新 `snn_soc_pkg.sv`：将 `THRESHOLD_RATIO_DEFAULT` 改为 E0 选出的新 ratio_code，同步更新 `THRESHOLD_DEFAULT`（= ratio_code × 255 × T），并在注释中更新主前端方法名称；3. ADC_BITS=8、WEIGHT_BITS=4、TIMESTEPS=3 等硬件参数保持不变（除非 E0 Stage 3 推荐配置明显偏离，需人工决策）；4. 用新主前端方法的权重，通过 [export_weights.py](D:/SoC%20Design/SoC%20Design/fpga/scripts/export_weights.py) 重新导出 `weight_pos.hex/weight_neg.hex`；5. 重新导出匹配新前端预处理的测试输入 `test_image.hex`；6. 更新所有文档中的主前端方法名称和 ratio 值（CLAUDE.md、doc/、SNNSoC主文档等）；7. 重新跑数字仿真和 smoke test（Icarus light），确认主链通过；8. 只有 smoke 全通过，A-F 的正式结果才开始记录；9. 旧 Step2/Step3 目录不再作为正式结果来源 | [snn_soc_pkg.sv](D:/SoC%20Design/SoC%20Design/rtl/top/snn_soc_pkg.sv)、[export_weights.py](D:/SoC%20Design/SoC%20Design/fpga/scripts/export_weights.py)、E0 输出 `results/paper_e0/stage2/summary.json`、`results/paper_e0/stage3/recommendation.json`、现有 `sim/` 和 `tb/` 流程 | 一份 post-E0 frozen config 记录（含新 ratio_code 和主前端方法）；更新后的 `snn_soc_pkg.sv`；新的 `weight_pos.hex/weight_neg.hex/test_image.hex`；重新通过的 smoke test 结果 | 不单独成图；作为 A-F 的前置门槛 |
| A 协议/时序一致性 | 证明 `control-path invariance under macro substitution` | 1. 在 E0.5 通过后，不新增 TB，直接复用 [top_tb_icarus_light.sv](D:/SoC%20Design/SoC%20Design/tb/top_tb_icarus_light.sv)；2. L0：当前分支打开 `REG_CIM_TEST`；3. L1：在 blackbox 路径下运行；4. L2：在 FPGA model 路径下运行；5. 三种模型各自生成 VCD；6. 用脚本提取 `u_cim_ctrl.state`、`u_adc.state`、`cim_start_pulse`、`cim_done`、`adc_start`、`adc_done` 的变化时刻；7. 对比阶段顺序与阶段 cycle 数 | 复用 [top_tb_icarus_light.sv](D:/SoC%20Design/SoC%20Design/tb/top_tb_icarus_light.sv)、[run_icarus_light.sh](D:/SoC%20Design/SoC%20Design/sim/run_icarus_light.sh)、[cim_macro_blackbox.sv](D:/SoC%20Design/SoC%20Design/rtl/snn/cim_macro_blackbox.sv)、[cim_fpga_model.sv](D:/SoC%20Design/SoC%20Design/fpga/cim_model/cim_fpga_model.sv)；新增的仅是一个 VCD/log 提取脚本，建议放在 `tools/` 或 `fpga/scripts/` | 三种模型的状态转移序列相同；阶段 cycle 数在相同 delay 参数下相同 | Table.5，Fig.6 左半 |
| B L2 vs Python 结果等价性 | 证明相同权重下，L2 路径与 Python golden 的输出一致 | 1. 在 E0.5 之后，用 [export_weights.py](D:/SoC%20Design/SoC%20Design/fpga/scripts/export_weights.py) 导出新的 `weight_pos.hex/weight_neg.hex`；2. 额外导出 `test_image.hex`；3. 新增 `tb/tb_python_equiv.sv` 读入该图像；4. **Python golden 必须直接加载 `weight_pos.hex / weight_neg.hex` 的整数值作为量化权重，而不是从 float 权重重新量化**；5. 若仓库中没有现成反向加载能力，则新增一个简单的 `hex -> numpy` 加载脚本，建议放在 `fpga/scripts/`；6. Python 侧保存同一图像或小 batch 的 `spike count vector`；7. L2 路径跑同一输入；8. 比较 10 维输出向量或 `OUT_FIFO_COUNT` | [run_all.py](D:/SoC%20Design/SoC%20Design/项目相关文件/器件对齐/Python建模/run_all.py)、[export_weights.py](D:/SoC%20Design/SoC%20Design/fpga/scripts/export_weights.py)、[run_cim_fpga_test.sh](D:/SoC%20Design/SoC%20Design/fpga/sim/run_cim_fpga_test.sh) 作为 L2 单元测试模板；输入必须包含 `weight_pos.hex`、`weight_neg.hex`、`test_image.hex` | Python vs L2 的结果对照表；至少 1 图 + 1 表 | Fig.6 右半，Table.6 |
| C CIM Test Mode bring-up | 证明无宏条件下数字链可自检 | 1. 在 E0.5 之后，用 `REG_CIM_TEST` 设置 4 组注入：`100/0`、`60/20`、`20/20`、`0/100`；2. 记录 `OUT_FIFO_COUNT`、`dbg_*` 计数、`adc_sat`；3. 写明当前是统一 `pos/neg` 注入，不能逐 neuron 分类；4. 不做过度 claim | [reg_bank.sv](D:/SoC%20Design/SoC%20Design/rtl/reg/reg_bank.sv)、[snn_soc_top.sv](D:/SoC%20Design/SoC%20Design/rtl/top/snn_soc_top.sv)、[top_tb_icarus_light.sv](D:/SoC%20Design/SoC%20Design/tb/top_tb_icarus_light.sv) | 一张单调性/场景矩阵图；一段 limitation 说明 | Fig.7，Table.7 |
| D FPGA 实现证据 | 提供 Python/VCS 给不了的 implementation evidence | 1. 仅在 E0.5 smoke 全通过后重新做 Step2；2. 从新的 Step2 提取 `WNS/LUT/FF/BRAM/power/DRC`；3. 再重新做 Step3；4. 从新的 Step3 提取 `xsa/bit/hwh` 和 implementation 报告；5. 统一成一张 implementation table；6. 功耗标注为 FPGA estimate | 新一轮 Step2/Step3 生成目录、[doc/14_fpga_fullversion_execution.md](D:/SoC%20Design/SoC%20Design/doc/14_fpga_fullversion_execution.md) 作为流程参考 | Table.8 FPGA implementation summary | Section 7 |
| E ARM P0 最小闭环 | 为 main-text 提供最小板级系统证据 | 1. 基于 E0.5 后新生成的 Step3 结果下载新的 `xsa` 和 `bit`；2. ARM 侧只做最小闭环：读寄存器、写输入、启动、读回 `OUT_FIFO_COUNT`；3. 不追求先做 batch | [top_fpga_arm.sv](D:/SoC%20Design/SoC%20Design/fpga/boards/zcu102/top_fpga_arm.sv)、新的 Step3 产物、[doc/14_fpga_fullversion_execution.md](D:/SoC%20Design/SoC%20Design/doc/14_fpga_fullversion_execution.md) | 一张最小闭环截图/表格；若通则写入主文，若不通则降级 | Section 7 主文或附录 |
| F 系统完整性补充 | 证明这不是孤立核，而是 complete digital SNN SoC with RISC-V control plane | 1. UART/SPI 合入后复跑现有 unit test；2. E203 合入后做最小固件 smoke：配置寄存器、启动一次推理、读回结果；3. 只作 system completeness，不作为 novelty；4. 正式记录基于 E0.5 后的新版本系统 | [run_uart_icarus.sh](D:/SoC%20Design/SoC%20Design/sim/run_uart_icarus.sh)、[run_spi_icarus.sh](D:/SoC%20Design/SoC%20Design/sim/run_spi_icarus.sh)、E203 合入后的顶层/固件路径 | 一张 system completeness checklist | 附录或 Section 3 最后一小节 |

说明：
- Windows 下优先直接用 `iverilog/vvp`、Vivado GUI/Tcl、Vitis；仓库里的 `.sh` 脚本主要作为流程模板。
- 所有新增代码只允许落在 `tb/`、`sim/`、`tools/`、`doc/paper_figs/`，不改流片网表逻辑。
- Experiment B 若 ARM 路径顺利，可升级为 `small-batch board run vs Python`; 若 ARM 不通，保留 `L2 simulation vs Python` 也可投稿。
- 旧 `project_2/project_5` 如被删除，不影响本计划，因为正式结果本来就要求在 E0.5 之后重建。

**4. Related Work 对比表**

最终表头定义：

| Work | Target | CIM backend | SoC/control completeness | Temporal coding / bit-serial | Parameterized CIM interface | Macro-absent digital validation | Testability / bring-up path | Validation scope |

必须精读的 8 篇论文与提取信息：

**A. 数字 SNN SoC**
- `ODIN (UCLouvain).pdf`，目录 [SNN SoC相关文献](D:/SoC%20Design/SoC%20Design/项目相关文件/SNN%20SoC相关文献)
  - 提取：是否完整数字 SNN chip、是否有 CPU/control plane、**Temporal coding / bit-serial 方式**、是否讨论 CIM interface、验证级别、测试机制
- `darwin3.pdf` 或 `Darwin__A neuromorphic hardware co-processor based on spiking neural networks.pdf`
  - 提取：系统完整性、可编程性、外设/控制方式、**Temporal coding / bit-serial 方式**、验证范围
- `SENECA building a fully digital neuromorphic processor, design trade-offs and challenges.pdf`
  - 提取：SoC 级数字设计特点、trade-off 口径、**Temporal coding / bit-serial 方式**、是否有 bring-up/test path

**B. CIM + 数字控制**
- `Tempo-CIM_A_RRAM_Compute-in-Memory_Neuromorphic_Accelerator_With_Area-Efficient_LIF_Neuron_and_Split-Train-Merged-Inference_Algorithm_for_Edge_AI_Applications.pdf`
  - 提取：有无系统级数字控制面、验证级别、**Temporal coding / bit-serial 方式**、是否接口参数化、宏缺失时是否可验证
- `DIANA_An_End-to-End_Hybrid_DIgital_and_ANAlog_Neural_Network_SoC_for_the_Edge.pdf`
  - 提取：SoC/控制链完整度、真实宏依赖程度、**Temporal coding / bit-serial 方式**、测试/bring-up 讨论
- `A_RISC-V_Neuromorphic_Micro-Controller_Unit_vMCU_with_Event-Based_Physical_Interface_and_Computational_Memory_for_Low-Latency_Machine_Perception_and_Intelligence_at_the_Edge.pdf`
  - 提取：RISC-V 控制面、计算存储结合方式、**Temporal coding / bit-serial 方式**、是否支持宏缺失验证
- `A_73.53TOPS_W_14.74TOPS_Heterogeneous_RRAM_In-Memory_and_SRAM_Near-Memory_SoC_for_Hybrid_Frame_and_Event-Based_Target_Tracking.pdf`
  - 提取：SoC 级系统整合、CIM backend、**Temporal coding / bit-serial 方式**、验证方式

**C. 阵列级反衬**
- `A_2.38_MCells_mm2_9.81_-350_TOPS_W_RRAM_Compute-in-Memory_Macro_in_40nm_CMOS_with_Hybrid_Offset_IOFF_Cancellation_and_ICELL_RBLSL_Drop_Mitigation.pdf`
  - 提取：宏级验证、**Temporal coding / bit-serial 方式**、是否缺少数字 SoC/bring-up 讨论
- `Neuro-CIM_ADC-Less_Neuromorphic_Computing-in-Memory_Processor_With_Operation_Gating_Stopping_and_DigitalAnalog_Networks.pdf`
  - 提取：阵列/核级范围、**Temporal coding / bit-serial 方式**、是否有系统级控制面、验证级别

填表规则：
- 没明说的一律写 `Not discussed`，不要自己推断。
- 本文 baseline 分两层：主文使用内部定量 baseline（`avgpool_8x8` shortlist、`L0/L1/L2`、`L2 vs Python`），Table.2 使用外部结构化 baseline（系统维度与验证维度对比）。
- 你的差异化重点写在两列：`Macro-absent digital validation`、`Testability / bring-up path`。
- 不做“谁更强”式精度/功耗硬拼，除非任务、数据集、网络、工艺完全同口径。

**5. 需要画的所有图**

| 图号 | 内容与目的 | 数据来源 | 呈现方式 |
|---|---|---|---|
| Fig.1 | 问题定义与证据链：Python parameter locking → L0/L1/L2/L3 → future macro | 架构与流程文档、[snn_soc_pkg.sv](D:/SoC%20Design/SoC%20Design/rtl/top/snn_soc_pkg.sv) | 结构框图 |
| Fig.2 | SoC block diagram：CPU/AXI/bus/DMA/FIFO/CIM/LIF/output | [snn_soc_top.sv](D:/SoC%20Design/SoC%20Design/rtl/top/snn_soc_top.sv)、[top_fpga_arm.sv](D:/SoC%20Design/SoC%20Design/fpga/boards/zcu102/top_fpga_arm.sv) | 系统框图 |
| Fig.3 | 模型替换图：L0/L1/L2/L3 共享同一接口，只有虚线框内 macro 替换 | [reg_bank.sv](D:/SoC%20Design/SoC%20Design/rtl/reg/reg_bank.sv)、[cim_macro_blackbox.sv](D:/SoC%20Design/SoC%20Design/rtl/snn/cim_macro_blackbox.sv)、[cim_fpga_model.sv](D:/SoC%20Design/SoC%20Design/fpga/cim_model/cim_fpga_model.sv) | 单页示意图 |
| Fig.4 | handshake timing：`dac_valid`、`cim_start/cim_done`、`adc_start/adc_done` | [03_cim_if_protocol.md](D:/SoC%20Design/SoC%20Design/doc/03_cim_if_protocol.md)、[cim_array_ctrl.sv](D:/SoC%20Design/SoC%20Design/rtl/snn/cim_array_ctrl.sv)、[adc_ctrl.sv](D:/SoC%20Design/SoC%20Design/rtl/snn/adc_ctrl.sv) | 时序图 |
| Fig.5 | 参数锁定图：只放 `8x8 非神经网络前端 shortlist 重跑对比`、`ADC sweep`、`Scheme A/B` 三个最小子图，并明确前者是主文内部定量 baseline | E0 Stage 1 `results/paper_e0/stage1/coarse_ratio_results.csv`（方法对比）、Stage 3 `results/paper_e0/stage3/adc_sweep.csv`（ADC sweep）、`results/paper_e0/stage3/scheme_compare.csv`（A/B 对照） | 3 合 1 拼图 |
| Fig.6 | Experiment A+B：左侧阶段 cycle 对比，右侧 Python vs L2 spike vector 对比 | A/B 实验输出 | 左 bar chart，右 grouped bar/scatter |
| Fig.7 | CIM Test Mode 注入结果：`pos-neg` 差分与 `OUT_FIFO_COUNT` / `dbg_*` 的关系 | Experiment C | 条形图或矩阵热图 |
| Fig.8 | 可选：ARM P0 最小闭环路径 | Step3 流程与板测日志 | 流程图或一页截图拼图 |

**6. 五周执行时间表**

| 周次 | 任务 | 交付物 |
|---|---|---|
| Week 1 | 精读 8 篇 baseline；完成 Table.2 草表；完成 E0 参数冻结；确定以 `avgpool_8x8` 为起点的 shortlist 重跑配置并启动正式跑；同步 `paper_facts.md`；确定 Fig.1~Fig.4 草图 | 一页 frozen facts、Related work matrix v1、shortlist 重跑配置与首轮日志、图草图 |
| Week 2 | 完成 E0 结果冻结；按 E0 结果修改 RTL/配置/权重导出/输入导出；完成 E0.5 的仿真与 smoke 重基线；确认 post-E0 frozen config | Table.4 初版、smoke test 通过记录、post-E0 frozen config |
| Week 3 | 基于新 frozen config 完成 Experiment A、B、C；同时重新发起 Step2；优先攻 ARM P0 的前置准备 | Fig.6/7 初版、Experiment A/B/C 原始结果、Step2 中间结果 |
| Week 4 | 完成新的 Step2/Step3；提取 FPGA implementation table；跑 ARM P0 最小闭环；把 E203/UART/SPI 的系统完整性证据写成一小节或附录 | Table.8、ARM P0 结果、system completeness checklist、Draft v1 |
| Week 5 | 组内修改；压 claims；补 cover letter；按 `Microelectronics Journal` 格式定稿提交 | Draft v2 + submission package |

P0 阻塞项：
- ARM Step3 最小闭环：`寄存器读写通`、`输入可写`、`能启动一次推理`、`能读回 OUT_FIFO_COUNT`

ARM fallback：
- 若 Week 4 末 ARM 仍不通，论文主文删除“board-level batch validation”表述
- 保留 `Experiment A/B/C + 新 Step2/Step3 implementation evidence`
- Section 7 改写为 `FPGA-assisted prototype evidence`，不写“ARM-driven batch system validation”
- Fig.8 删除或移附录
- 题目不变，摘要中只写 `FPGA implementation evidence on ZCU102`

E203/UART/SPI 集成口径：
- 投稿版本主文统一使用 `complete digital SNN SoC with RISC-V control plane`
- UART/SPI/E203 的定位仍然是 system completeness 与 engineering maturity，不作为核心 novelty

**7. 风险清单和审稿人预判**

| 质疑 | 回应策略 | 需要额外数据 |
|---|---|---|
| 1. 没有真实 CIM 宏/流片数据，为什么能发 | 本文聚焦数字侧与预硅验证连续性，不声称真实宏数值行为；用接口契约表、Experiment A/C、E0 后重做的 Step2/3 实现证据支撑 | Table.3、Experiment A/C、Table.8 |
| 2. 为什么不用 VCS/后仿就够了 | 明确承认 VCS 更强于 correctness fidelity；FPGA 的价值是 system executability/implementation evidence，不替代后仿 | Experiment D；摘要和 Discussion 中要主动说明 |
| 3. 宏可替换不代表真实宏一定接上就能用 | 不说 `any RRAM macro`；只说 `any macro conforming to the interface contract`; 强调 handshake-based, latency-insensitive control | Table.3 接口契约表；Fig.4 时序图 |
| 4. CIM Test Mode 太弱，只能统一注入 | 主动承认当前只支持 uniform pos/neg injection；定位是 digital self-check，不是 per-neuron replay；future work 写逐通道注入 | Experiment C；Limitations 段落 |
| 5. baseline 不充分或不公平 | 主动把 baseline 分成两层：内部定量 baseline 用于主结果支撑，外部结构化 baseline 用于 related work 对比；不做跨任务硬拼数值，缺项一律 `Not discussed` | E0 shortlist 重跑、Experiment A/B、Table.2；不需要额外新结构实验 |

**8. 红线清单**

绝对不能出现的表述：
- `functional equivalence`
  - 替换为：`control-path invariance under macro substitution` / `validation continuity`
- `any RRAM macro can be plugged in`
  - 替换为：`Any macro conforming to the defined digital CIM interface contract can be integrated without redesigning the downstream digital SNN pipeline.`
- `FPGA validation is more accurate than VCS/post-layout simulation`
  - 替换为：`FPGA provides implementation-level and system-execution evidence complementary to simulation.`
- `SoC-oriented digital SNN architecture with integrated control and peripheral interfaces`
  - 本文主文统一使用 `complete digital SNN SoC with RISC-V control plane`
- `silicon-level power/area`
  - 替换为：`FPGA implementation estimate` / `Vivado reported power`
- `CIM Test Mode supports classification without macro`
  - 替换为：`CIM Test Mode enables digital-chain self-check without macro; current implementation does not provide per-neuron programmable replay.`
- 直接引用已过时的 [CIM_Macro_Interface_Specification.md](D:/SoC%20Design/SoC%20Design/doc/develop%20docs/CIM_Macro_Interface_Specification.md)
  - 替换为：用 [03_cim_if_protocol.md](D:/SoC%20Design/SoC%20Design/doc/03_cim_if_protocol.md)、[08_cim_analog_interface.md](D:/SoC%20Design/SoC%20Design/doc/08_cim_analog_interface.md)、[snn_soc_pkg.sv](D:/SoC%20Design/SoC%20Design/rtl/top/snn_soc_pkg.sv)
- 把 [summary.txt](D:/SoC%20Design/SoC%20Design/项目相关文件/器件对齐/Python建模/results/summary.txt) 里的 `ADC=6` 当成最终 RTL 当前值
  - 替换为：`Python sweep shows 6-bit as a cost-efficient point, while the current tapeout-oriented RTL freezes 8-bit ADC for implementation margin.`
- 把 `proj_sup_64` 直接写成默认部署前端而不解释其 learned projection 属性
  - 替换为：`The deployment-oriented default front-end is chosen from non-neural 8x8 candidates under the fixed 64-input interface, while proj_sup_64 is retained only as a learned upper-bound reference if needed for comparison.`
- 使用 E0 之前的旧仿真、旧 Step2、旧 Step3 结果作为正式论文图表
  - 替换为：所有正式结果必须来自 E0 冻结之后重建的仿真、smoke、Step2、Step3 流程

论文中必须出现的关键声明：
- `The CIM interface employs handshake-based control rather than fixed-cycle assumptions, making the digital control path tolerant to implementation-dependent latency variations.`
- `The current L0/L1/L2 models use deterministic delay parameters for reproducible verification, while the digital control path itself is latency-insensitive at the protocol level.`
- `Any macro conforming to the defined digital CIM interface contract can be integrated without redesigning the downstream digital SNN pipeline.`
- `CIM Test Mode currently injects uniform positive/negative values shared across channels; it is intended for digital-chain self-check rather than per-neuron classification replay.`
- `Python modeling is used here for device-aware parameter locking; final reported hardware configuration follows the single source of truth in snn_soc_pkg.sv.`
- `The non-neural front-end is re-evaluated under the fixed 64-input hardware interface starting from avgpool_8x8, while learned projection is used only as an upper-bound reference if retained.`
- `The paper uses a two-level baseline: internal quantitative baselines under identical 64-input conditions, and external structural baselines from prior SoC/CIM literature.`
- `All reported post-silicon proxy evidence in this paper is rebuilt after E0-driven configuration freezing and post-freeze simulation/smoke revalidation.`

执行优先级一句话总结：
先做 `Week 1 的 frozen facts + Related Work + avgpool_8x8 起点的 shortlist 重跑`，然后立刻进入 `E0.5：RTL/配置同步 + 仿真和 smoke 重基线`；只有这一步通过之后，`Experiment A`、`Experiment B`、`Experiment C`、`Experiment D`、新的 Step2/Step3 和 ARM P0 才开始记为正式论文结果。
