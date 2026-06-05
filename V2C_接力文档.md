# V2C 接力文档（HANDOFF）—— 给下一个对话

> 喂给新对话用：① 最省事 = 让新对话直接 `Read` 本文件 `~/dev/snn-soc/V2C_接力文档.md`；② 或复制本文件全文粘贴。
> 本文件是**入口**，权威细节在下面列的几个源文件里——接手前务必把它们读一遍。
> 最后更新：2026-06-05。

---

## 0. 权威源文件（都在 `~/dev/snn-soc/`，接手前先读）
- **`plan-v1.md`** — V2C 论文线总计划（架构 / 网络 / PPA 口径 / Test Plan / Assumptions / 红线）。**最重要**。
- **`V2C_设计决策与权衡记录.md`** — 每条决策 + 为什么 + 权衡了什么（§1–§10，含 Codex 三轮复审采纳记录、P&V 方案、器件参数、编码表）。
- **`python_multilayer/v2c/PROGRESS.md`** — 执行进度表（哪些 part done / 待审 / 文件）。
- **`V2C_RTL_bug记录.md`** — V2C RTL bug 记录（RTL 阶段才用）。
- 自动记忆（若新对话从 `~/Desktop/soc` 启动会自动加载）：`snn_soc_project.md`（含 ★ 极致压榨 PPA 标准指令 + V2C 概要）、`env_local_machine.md`（环境坑 + `.venv-v2c` + 安装授权）。

---

## 1. 项目与目标（一句话）
用户的 **SNN/CIM SoC 芯片项目**（repo `~/dev/snn-soc`，分支 `asic-v2b-noe203-base`）。当前在做 **V2C 论文线**：**数字二值 0T1R RRAM-CIM + TTFS** 的加速器，目标灌一篇 **Q4 SCI**。与已验证的 V2.B（ARM-FPGA evidence）**并行、不得破坏**——V2C 所有东西都 **fork 新建**，不动 V2.B 的文件。

---

## 2. ★ 最高指令 / 协作风格（必记）
- **★ STANDING DIRECTIVE：一切决策与操作朝"极致压榨 PPA"（面积/功耗/延迟）**。accuracy 够用就行，但要"PPA 最优前提下也追 accuracy 最优"。
- **headline 定位**：正面竞争押 **latency（硬件 cycle，RTL/FPGA 可测）**；**SOP/J 是 projected**（能量含器件/外围 estimate，别称"可测"）；**density/area 作 motivation + 标 estimate 的 Figure**，非主 claim。
- **真实性红线**：所有结果标 `Python Sim./RTL Sim./FPGA/DC Synth./RRAM Estimate/Device Cite`，**不混仿真与实测**；缺数据写 **TBD**，不硬编、不伪造。
- **用户授权**：缺任何环境/工具/文件，**直接装、别问、别绕**（properly 安装）。
- **回复风格**：用户用中文、要简洁；技术深、是认真的硬件/RTL/ASIC 工程师，可以直说、可以 push back（有理有据）。
- **文档常被用户/Codex 并行外部编辑** → 每次 Edit 前先 `Read` 拿最新文本，否则 Edit 会 "string not found"。

---

## 3. 工作协议（用户定的，必须遵守）
**每完成一个"part"：**
1. 写代码（fork 到 `python_multilayer/v2c/`，不碰 V2.B）。
2. 本地 pytest 跑绿：`cd ~/dev/snn-soc && ./.venv-v2c/bin/python -m pytest -q -p no:cacheprovider python_multilayer/v2c/`。
3. **出一份 Codex 审核 prompt**（给用户，用户去喂 Codex；模板：背景 + 规格 + 重点核查 + 输出 P0/P1/P2 + "只读不改"）。
4. 用户回贴 **Codex 审核结果** → 你**逐条判定采纳/驳回**（Codex 质量高、基本无误解，但仍要独立判断、不盲从）→ 修 → 复验 pytest → 必要时再出一轮复审 prompt。
5. 在 `PROGRESS.md` 把该 part 标 **✅ done**。
- 历史上 Codex 每轮都能挑出真问题（shape 防护、float 截断、TTFS tie-break 用错膜电位、对称码、负时间吞等），**全部已采纳修复**。保持这个严谨度。

---

## 4. 关键架构决策（速览；细节见 `plan-v1.md` + 决策记录）
- **数字二值 CIM**：每 cell 1 bit；读出 = 每 BL **1-bit 电流 sense amp**（判 LRS/HRS）；MAC 在数字逻辑 **popcount + shift-add**；**无多比特 ADC、无 Scheme-B 差分、无模拟电流求和**。器件表征的 TIA+ADC 不进 V2C 计算路径。
- **阵列**：1024×1024 物理二值 bit-cell；逻辑 `1024 输入 × (1024/W) 输出`，列 `col=(layer_base+out_idx)*W+bit_idx`（单宏多层常驻）。
- **权重三套编码（W = cells/weight）+ accumulator**（这是 `encoding.py` 的核心）：
  - W=1 **BNN** `{−1,+1}`，1 cell，`2·popcount(cell=1) − N_active`。
  - W=2 **ternary** `{−1,0,+1}`，2 cell(pos,neg)，`popcount(pos) − popcount(neg)`；**码表 +1=(1,0)/−1=(0,1)/0=(0,0)/(1,1)=illegal**（理想 assert 不产生；非理想解 0 且计 fault）。
  - W≥4 **two's-complement**（**对称**：用 `[−(2^(W-1)−1), 2^(W-1)−1]`，最负码不发），`Σ_k 2^k·popcount(bp_k)`，MSB 取负。
  - 列预算 `1024/W`；W=8 需双宏（并行）作 high-acc 上界、不与 W=4 同面积比。
- **主网络**：单宏常驻 **TTFS-MLP `784→246→10`**（W=4 占满 256 列、~74% 利用率）；**3-FC `784→160→80→10`** 作 ablation（实证加深→利用率↓）。
- **数据集**：MNIST + Fashion-MNIST + KMNIST（均 28×28/10类、同网络同映射）。**精度 sweep**：三数据集 × W∈{1,2,4,8} × T∈{16,32,64} × 数字非理想；**分阶段门禁**：先 W=4×T 过门 → 再 W sweep → 非理想只主点+边界。
- **TTFS 语义**：每神经元每帧≤1 spike；分类取**最早输出 spike + 首 spike 早停**；**并列**（同最早时刻）→ **首脉冲时刻**膜电位最高 → 最小类号；**无 spike** → 回退 **最终**膜电位 argmax（fallback_used）。⚠ tie-break 必须用**早停/首脉冲时刻**膜电位，不是全程最终膜电位。**延迟双指标**：算法首发时间（fallback=T）vs 硬件 cycle latency。
- **PPA 三桶**：①数字逻辑（DC 综合，**不含 CPU**）②RRAM 阵列（器件数据估算）③**mixed-signal 外围**（sense amp/WL-BL 驱动/3.3·1.5·0.75V 生成，estimate）。`SOP/J = SOP ÷ E_total`，`E_total = P_digital×cycles/f + E_array + E_periphery`（P&V 装载能耗不入单张 inference）。DC/后仿 TB 驱动不含 CPU；**仅 FPGA 接 ARM PS**。
- **RRAM 模型（双模型）**：BRAM 存标称权重态 + **可综合注入逻辑**（LFSR 读 bit-flip + ROM stuck-at mask + P&V 写失败）→ Verdi 与 FPGA 都反映 degradation；理想模式与 Python golden bit-exact。`memristor_plugin.py` 模拟物理只做**标定**（蒸馏数字参数）、不进 RTL。
- **P&V（器件方提供，原模拟 CIM 用、V2C 只取共性）**：V/2 半选 + 双极性 **SET(WL=3.3/BL=0)/RESET(WL=0/BL=3.3)**、半选 1.5V、**VERIFY** 读回(WL=1.5/BL=0、其余 BL=0.75 抑制) + 双向诊断 → stuck-at。

## 4b. 器件参数（来自模拟 CIM 同学的 SOW，cite-pending）
- **cell 0.64 μm²**（BL/WL pitch 0.8μm）、**node = SMIC 55nm** → V2C 1024×1024 ≈ **0.671 mm²**。
- 写/擦 **3.3V·10μs pulse**；读 1.5V；抑制 0.75V；半选 1.5V。50MHz。
- **on/off = 5000:1**（器件方称实测，仓库暂无正式可引用文档 → `Device Cite pending`）；插件复算 I-V.xlsx≈1680 仅内部 golden。
- **诚实密度口径**：对 SRAM-CIM cell ≈ **2–3×**（**不是** 4F²/30–40×、不是对纯 6T 存储；那是混 F 的错，已废）。
- SOW 的"单器件 10nA–0.1μA"是**模拟 4-bit 窗口**、非二值 on/off。
- **仍待器件组**：写电流 I_write（写/擦能耗）、半选 disturb 数据、on/off 正式可引用出处、node-matched 6T SRAM cell 面积。

---

## 5. 当前代码状态（`python_multilayer/v2c/`，纯 fork）
**环境（关键！见 §6）**：本机 pip 坏，用 **`~/dev/snn-soc/.venv-v2c`**。当前 **全量 98 个 pytest 绿**。

| 文件 | 作用 | 状态 |
|---|---|---|
| `encoding.py` | 三套编码 pack/unpack + 数字-CIM `mac`(popcount accumulator) + `value_range/outputs_per_macro/count_ternary_illegal`；含 shape/binary/整数校验 | ✅ done（Codex 审+修）|
| `ttfs.py` | TTFS 输入编码：`encode_pixel_to_ttfs`(像素→首脉冲时间,亮=早,0可不发)、`ttfs_times_to_stream`、`ttfs_stream_to_times`；`NO_SPIKE=-1`；含负向 guard | ✅ done |
| `forward.py` | `ttfs_layer_forward`(单层,每timestep `mac`累膜电位,首spike latch,早停)、`ttfs_classify`(最早+tie-break+fallback)、`multilayer_ttfs_forward`(链多层,hidden→stream,输出层早停,**pred 永远用早停膜电位**) | ✅ done |
| `data.py` | `load_dataset(name,train,root)` → MNIST/Fashion/KMNIST 的 `(images uint8[N,784], labels int64[N])`；torchvision；缓存 `v2c/_data`(gitignore) | ✅ done |
| `qat.py` | `quantize_weight(w,W)` → `(w_q STE, w_int∈value_range, scale)`；W=1 BNN htanh-STE / W=2 ternary TWN / W≥4 对称 two's-comp；输出整数直接喂 `encoding.pack` | ✅ done |
| `test_*.py` | pytest（encoding/ttfs/forward/data/qat），**98 passed** | — |
| `PROGRESS.md` | 进度表 | — |

**已完成 part：1(编码) 2(TTFS) 3(单层forward) 4(多层forward) 5(数据loader) 6a(QAT量化器)** —— 全部 Codex 审完+修+绿。
**TTFS-MLP 推理 golden 全链路打通**（给定整数权重：encode→单层/多层 forward→分类）。

---

## 6. 环境（一定要用对，否则白费功夫）
- **本机 pip 坏**：系统 python3.14 + brew python@3.12 的 `pyexpat`/`libexpat` 缺符号（`_XML_SetAllocTrackerActivationThreshold`），导致 `pip`/`ensurepip`/`venv(带pip)` 全挂（pip import xml→pyexpat）。**不是 py 版本问题。**
- **✅ 可用 venv：`~/dev/snn-soc/.venv-v2c`**（Codex 建的，pyexpat 修好了）：py **3.12.13** + numpy **2.4.6** + pytest **9** + **torch 2.12.0 + torchvision 0.27.0（MPS 可用）** + pyexpat ok；**pip 正常**。
- **跑测试**：`cd ~/dev/snn-soc && ./.venv-v2c/bin/python -m pytest -q -p no:cacheprovider python_multilayer/v2c/`
- **装新包**：`./.venv-v2c/bin/python -m pip install <pkg>`（这个 venv 的 pip 能用）。
- 别用系统/brew python 跑（pip 会挂）；`/tmp/v2c_pylibs` wheel-extract 是旧 fallback，已弃用。
- 也别用 `~/dev/snn-soc/.venv`（那个是坏的，已 gitignore）。

---

## 7. 下一步要做的：Part 6b(已转向) → 6c → 之后（accuracy 攻坚 + 后端）
**用户：6b 要"认认真真做、使出最强水平、PPA 最优前提下追 accuracy 最优、免费 trick 能用就用"。**

### ⚠ Part 6b 重大转向（2026-06-05，已落地、本地 147 绿、待 Codex 审）
**原计划「graded ReLU 量化 ANN proxy → 阈值校准 → TTFS」已证伪**：Fashion W=4 量化 ANN proxy
86.7%，但导出权重跑真实 `forward.py` ≈ **随机 10%**，扫任何全局阈值乘子无效。根因 = TTFS-IF 动力学
（膜电位均值为负 → per-neuron 阈值多为负 → membrane 从 0 起即过阈、t=0 秒发；带符号权重 → 膜电位非
单调 → "首脉冲是否发放"≠"最终膜电位≥阈值"）。光靠阈值校准救不了。
→ **改 surrogate-gradient 在真实 TTFS-IF forward 动力学里直训**（用户拍板）。详见 `python_multilayer/v2c/PROGRESS.md` Part 6b 段。
- **已交付**：`spiking.py`(`SpikeFn` 替代梯度 + `V2CSpikingMLP` 可微 TTFS-IF forward，与 `forward.py`
  同语义；`ttfs_loss`=earliness CE+膜 CE；`encode_stream`) / `qat.py`(+`lsq_quantize_weight` per-output
  LSQ) / `model.py`(`QuantLinear`) / `train_spiking.py` / `convert.py`(读学习整数阈值+跑 golden)。
  `train.py`+`model.V2CMLP` 降级为"量化 ANN 参考上界"(非部署路径)；旧 `convert.fold_threshold` 已删。
- **threshold-QAT**：`mem_train=scale⊙mem_inf` → 发放判据与 golden 整数比较 bit 一致（fire-decision
  96% agreement 测试锁定）；导出每输出整数阈值寄存器、推理零 BN/零乘法(PPA-clean)。
- **首结果** Fashion W=4 T=16 主网 30ep：golden 早停/部署 **66.7%**、full-frame 上限 74%、fallback 0%、
  延迟 2.54/16。⚠ **偏低、需调优**。

### Part 6c（accuracy 调优 + sweep；method 已对齐 SOTA）
- **目标 accuracy（联网调研 2026-06-05）**：纯 MLP TTFS 在 Fashion-MNIST，SOTA ETTFS(arXiv 2410.23619)
  `FC400-400-10` T=8 **92.9%**（推理 ~2 timestep）；TTFS SOTA 总体 Fashion ~91–93% / MNIST ~99.5%。
  量化(W=4)/RRAM-BSNN 再减 1–3pp → **W=4 现实目标 ~85–90%**。**当前 74% = 欠调，不是天花板。**
- **method 确认**：surrogate-grad 直训 = SOTA TTFS-from-scratch 的做法、且契合 latency headline；
  **ANN-to-SNN 精度高但要 ~10²–10³ timestep、打死 latency，不用**。
- **要加的 trick（来自 ETTFS，全部 PPA 兼容/可折叠）**：① **ETTFS-init** 权重 `U(±√(3T/N))`(考虑 T)
  ② 训练期**权重标准化** ③ **可学习 per-output 仿射 γ·mem+β**（治"膜均值为负"，γ,β 折进每输出阈值/下层权重、推理无乘法）④ **指数时间解码 `γ^-t`**(替换现 `ttfs_loss` 的线性 `T-t`、更锐)
  ⑤ **强制末步发放**(去 no-spike，稳梯度) ⑥ 让 loss/监控**对齐早停决策**(收 74%→66.7% 的 7.3pp)。
- **sweep**：三数据集 × W∈{1,2,4,8} × T∈{8,16,32,64}；分阶段门禁(先 W=4×T 定点)。
- **latency-accuracy Pareto**(早停 vs full-frame) = headline；ANN(参考上界) vs TTFS(部署) degradation 报告。

### 6c 之后
- **二值位平面权重导出**（给 RTL golden）：用 `encoding.pack` 把训好的整数权重导成 bit-cell 文件。
- **能效-延迟-SOP 指标**：SOP 计数（算法突触操作）、双延迟、按器件数据估能耗。
- **RTL**：`snn_soc_v2c_top` + 数字二值 CIM 宏（BRAM + LFSR/ROM 注入 + bit-parallel shift-add + 首spike早停 + 时钟门控）+ TTFS neuron bank（≥256、无FIFO、单spike、膜电位~16b；**只复用** `lif_neuron_alu` 思想、不复用本体）+ bit-cell P&V FSM（复用 `cim_program_ctrl.sv` 骨架、改二值）。拓扑系统 fork `role=v2c`（放宽 `out_dim≤1024/W`、去 Scheme-B 2×）。
- **DC**（SMIC 55nm、50MHz、不含 CPU、TB 驱动）+ **FPGA**（ZCU102、仅此接 ARM PS）。

---

## 8. 重要 gotcha / 红线（别踩）
- **不碰 V2.B**：`topologies.py`、`cim_program_ctrl.sv`、`trainer_multilayer.py` 等都是 V2.B/Scheme-B/ADC/多级语义——V2C 全 fork 新建，别原地改。
- **编辑文档前先 Read**（外部并行编辑频繁，Edit 易 mismatch）。
- **器件数字非理想（stuck-at/write-fail/disturb/read-BER）**：无器件统计前一律**参数 sweep（标假设）**、不声称 derived；read-BER 给"由 on/off+噪声+阈值推导"的公式。
- **"首次 TTFS on 0T1R"** 文献核对前**不**在 plan/摘要写成已确认 novelty。
- **TTFS 分类 tie-break 用早停（首脉冲时刻）膜电位**，不是全程最终膜电位（这点 Codex 抓过两次，已修，别回退）。
- **two's-comp 对称量化**：最负码 `-2^(W-1)` 保留不发（intentional，已文档+测试锁定）。
- 文档里**密度对 SRAM 是 ~2–3×**，不是 4F²/30–40×（那是错的、已废）。

---

## 9. 接手第一步建议
1. 读 §0 列的源文件（`plan-v1.md`、决策记录、PROGRESS.md）。
2. 跑一遍 `cd ~/dev/snn-soc && ./.venv-v2c/bin/python -m pytest -q -p no:cacheprovider python_multilayer/v2c/` 确认 **147 passed**、环境 OK。
3. 看 `python_multilayer/v2c/{encoding,ttfs,forward,qat,data}.py` 了解底层 API + **`spiking.py`/`train_spiking.py`/`convert.py`**（6b 部署路径）。
4. **当前状态**：6b 代码完成（surrogate-grad 直训，见 §7 转向），Fashion W=4 首结果 66.7%(早停)/74%(full-frame)，**等用户回贴 Codex 审核结果** → 逐条判定采纳/驳回 → 修 → 再进 **6c accuracy 调优**（按 §7 的 ETTFS trick 把 Fashion 推到 ~85–90%）。
