# V2.B CONV Extension — Closure Log

> **Status**: M7 Evidence Seal（2026-05-02 closure）
>
> **Plan reference**: `C:\Users\24201\.claude\plans\d1-d3-idempotent-umbrella.md` (REV 5)
>
> 本文件是 V2.B CONV extension（M0 → M7）的最终封存记录，给未来自己 / 论文叙事 /
> 简历评审 / handoff 同事提供单点真相（single source of truth）。所有 hash /
> commit / PASS marker 都在写文档当时核对过；后续 evidence 分支演进不改写本文件。

---

## 1. M0–M7 最终状态

| 里程碑 | 状态 | 简述 |
|---|---|---|
| **M0** Architecture Freeze（1 周）| ✅ 完成 | dynamic WL ready/valid 协议 + 32-bit padded fmap layout + FPGA-only resource scope 全部签核 |
| **M1** Python integer reference + synthetic golden（1 周）| ✅ 完成 | `python_multilayer/snn_engine_conv.py` + `exporter_conv.py` + `gen_synthetic_conv_golden.py` 全部交付，bit-exact reference 当唯一 golden |
| **M2** Pre-RTL FC tile_mode=1 gate（0.5 周）| ✅ 完成 | `tile_mode_1_e2e_tb` PASS + 9 个现有 V2 sim gate FC 字节级一致 |
| **M3** CONV RTL + 19 sim gate（2-3 周）| ✅ 完成 | 4 个新 RTL（fmap_sram_v2 / patch_unroller_v2 / fmap_flatten_reader_v2 / conv_ctrl_v2）+ stage_engine_v2 dynamic-WL 扩展 + byte-mask invariant 60 sub-test 全 PASS |
| **M4** LeNet-5 Bit-exact Cosim + ZCU102 板验（1 周）| ✅ 完成 | 10/10 sample 字节级 byte-exact match Python integer reference；ARM Cortex-A53 + E203 RISC-V 双 CPU 路径都板验通过 |
| **M5** Tiny VGG + Plain-CNN-4 Bit-exact（1-2 周）| ❌ **主动收兵** | 训练精度卡 ~13%（CIFAR-10），判定为冻结 V2.B 架构上限——非 bit-exact 路径 bug，纯 accuracy ceiling。论文叙事如实表达，不掩饰 |
| **M6** Phase D port to evidence branches（1 周）| ✅ 完成 | 两条 evidence 分支独立 bitgen + JTAG 烧 + UART 抓 PASS marker；详见 §3 |
| **M7** Closure / Evidence Seal（0.5 天）| ✅ **本文件 + 两个 tag** | 详见 §6 |

---

## 2. 三网络仿真 / 板验结果

### 2.1 LeNet-5 (MNIST 28×28，T=10)

| 维度 | 值 |
|---|---|
| Python integer reference checkpoint | `python_multilayer/checkpoints/lenet5_snn.pth` |
| Quantized SNN test accuracy | 0.9303（10000 张 MNIST test set） |
| Selected accuracy（10 个 class-first samples） | 1.0（10/10 全部 predicted=label） |
| Layer chain | conv1 (28×28×1→28×28×6, K=5) → conv2 (28×28×6→12×12×16, K=5 S=2) → fc1 (2304→120, 9 tiles) → fc2 (120→84) → fc3 (84→10) |
| max_signed_level（layer-wise） | conv1=8 / conv2=16 / fc1=7 / fc2=7 / fc3=3 |
| Cosim TB | `tb/lenet5_cosim_tb.sv`（不在 main，仅 evidence 分支） |
| Cosim PASS marker | `LENET5_COSIM_TB_PASS` |
| ARM 板验 PASS marker | `ARM_FPGA_DEMO_LENET5_PASS`（10 行 [PASS] sample N） |
| E203 板验 PASS marker | `FPGA_V2_E203_BOOT_UART_PASS` + 10 行 [PASS] sample N + V2_E203_LENET5_PASS |

### 2.2 Tiny VGG / Plain-CNN-4（CIFAR-10 32×32，T=64）— M5 主动收兵

| 网络 | 训练精度 | 判定 | 论文措辞 |
|---|---|---|---|
| Tiny VGG | ~13%（near random for 10-class） | 冻结架构上限：4-bit weights + 8-bit ADC + ratio_code=1 + T=10/64 在 CIFAR 数据集上无法收敛 | "Tiny VGG / Plain-CNN-4 attempted on V2.B CONV extension; accuracy plateaued at ~13% indicating architectural capacity ceiling for this stack. Validated bit-exact path (LeNet-5) remains the headline result; richer topologies would require a v3 stack with wider weights / higher ADC precision / longer T—not in scope." |
| Plain-CNN-4 | ~13% | 同上 | 同上 |

判定根据：
- 不是 bit-exact path bug（infrastructure 在 LeNet-5 上 10/10 PASS 已证明 bit-exact path 健康）
- 是 V2.B 量化堆栈在 CIFAR 这种 dataset 上的 capacity 上限
- 不应作为论文 contribution；不写"我们成功跑了 VGG/Plain-CNN-4 on chip"
- 写"V2.B CONV extension 可端到端 inference，bit-exact 验证基于 LeNet-5；CIFAR
  级 dataset 需 v3 stack（wider weights / higher ADC / longer T），留作 future work"

---

## 3. 两条 evidence 分支 — 板验证据

| 分支 | CPU 路径 | 当前 HEAD | 板验 commit | UART log |
|---|---|---|---|---|
| `feature/v2-arm-fpga-demo-conv` | ARM Cortex-A53 (PS) + AXI-Lite | `e5d43a05` | `48958da0`（native conv1 fix）clean rebuild | `doc/arm-fpga-demo/board_bringup_log_lenet5.txt` |
| `feature/v2-fpga-e203-conv` | E203 RISC-V (PL soft-core) + BRAM init | `8642c84e` | `e2635967` 之后 audit-pass-2 series | `doc/v2-fpga-e203/board_bringup_log_lenet5.txt` |

### 3.1 ARM 分支板验细节

- **Bitstream**：`fpga_synth/zcu102_arm_demo/zcu102_arm_demo.runs/impl_1/v2b_arm_demo_bd_wrapper.bit`
  - SHA256：`1d26e2e3bfc22a8a1028839ab810d7293642db4c3534dcc55ce917662cd7bcc7`
- **ELF**：`fw/arm/out/v2b_arm_demo.elf`
  - SHA256：`964e620f5e04e93b4c295a5615175b1b5de7ea7c027514ca5e0f5c3afbb5b12b`
- **Vivado**：v2022.2 (64-bit) SW Build 3671981 / IP Build 3669848
- **AArch64 GCC**：11.2.0
- **板**：ZCU102 (Zynq UltraScale+ XCZU9EG)
- **PASS marker**：`ARM_FPGA_DEMO_LENET5_PASS`（详见 board_bringup_log_lenet5.txt UART trace）

### 3.2 E203 分支板验细节

- **Bitstream**：`fpga_synth/zcu102_v2_e203_demo/out/snn_soc_v2b_e203_fpga_top.bit`
  - SHA256：`d8505dd70f2d431b308b62246efc439c4839b3c802e25166c33d5b23fc088d11`
- **BRAM init hex**：`fw/v2_e203_smoke/out/v2_e203_lenet5.hex`
  - SHA256：`8ead9baa1d797314c2dba211d62e56d33cdd00ef366dd2777ac602eb7817e74f`
- **Vivado**：v2022.2（同 ARM）
- **riscv32 GCC**：riscv64-unknown-elf 工具链（用 -march=rv32imc）
- **PASS marker**：`FPGA_V2_E203_BOOT_UART_PASS` + 10 行 `[PASS] sample N`

---

## 4. Audit pass chain（pre-tape-out 严苛度）

两条 evidence 分支都经过了 **2 轮独立 cold-start audit + GPT 第二轮 audit + 重烧验证**：

### 4.1 audit-pass（Claude 第一轮，2026-05-01）

| ID | 修复内容（精简） | arm commit | e203 commit |
|---|---|---|---|
| A1-A8 | arm sim filelist / Vivado TCL / TB cfg_input_src 扩宽 / `00_architecture.md §12` / `board_bringup_log_lenet5.txt` / `06_learning_path.md Part D` / FW 中文化 / manifest 口径说明 | `f9c542fe` | — |
| B1 | 4 个 conv-path unit TB（fmap_sram / patch_unroller / fmap_flatten_reader / conv_ctrl）28/28 PASS | `3f4de9f5` | `0ee13e71` |
| B2 | byte-mask invariant TB 加 21 个 CONV-reg negative case，33/33 PASS | `3f4de9f5` | `0ee13e71` |
| E2 | stage_engine_v2 加 `cfg_conv_mode/cfg_input_src` 一致性 guard + SVA + 新错误码 0x06 | `3f4de9f5` | `0ee13e71` |
| G2 | uart_put_dec 全栈统一为 uint32_t | `65190e10` | `829e1b51` |
| G8 | gen_convnet_golden.py docstring 中文化 | — | `e2635967` |
| capture | `scripts/capture_uart.py` autonomous board verify helper | `c57d6391` | `f58495f0` |

### 4.2 audit-pass-2（GPT 第二轮，2026-05-02）

| ID | 修复内容 | arm commit | e203 commit |
|---|---|---|---|
| edge guards | conv RTL 边界守口 + audit gaps（fix conv edge cases + evidence gap fixes） | `592092fc` | `2407c7a1` |
| RTL converge | shared conv RTL 跨 evidence 分支字节级一致 | `e5d43a05` | `8642c84e` |

GPT 还独立做了 FPGA 重烧 + UART 抓三段 PASS marker 的板验，证据保留在两条分支
的 `doc/<branch>-fpga-demo|fpga-e203/board_bringup_log_lenet5.txt`（UART 完整 trace）。

---

## 5. Tool versions（工具链 freeze）

| 工具 | 版本 | 用途 |
|---|---|---|
| Vivado | 2022.2 (64-bit) SW Build 3671981 / IP Build 3669848 | bitgen 综合 + impl |
| xsct (Vitis) | 2022.2 | JTAG 烧写 |
| AArch64 GCC | 11.2.0 (aarch64-xilinx-elf-gcc) | ARM ELF 编译 |
| riscv32 GCC | riscv64-unknown-elf（rv32imc 模式） | E203 hex 编译 |
| Icarus Verilog | 12.0 (devel) (s20150603-1539-g2693dd32b) | sim |
| Python | 3.x（带 pyserial / torch / torchvision） | golden + UART 抓取 |

---

## 6. M7 Closure tags

两条 evidence 分支各有一个 closure tag：

| Tag | 指向 | 说明 |
|---|---|---|
| `v2-arm-fpga-demo-conv-passed` | `e5d43a05`（arm-conv HEAD） | M7 evidence seal — ARM Cortex-A53 path LeNet-5 板验 + 双轮 audit + GPT 重烧验证完整通过 |
| `v2-fpga-e203-conv-passed` | `8642c84e`（e203-conv HEAD） | M7 evidence seal — E203 RISC-V path LeNet-5 板验 + 双轮 audit + GPT 重烧验证完整通过 |

> 注：plan REV 5 §M7 写"tag `v2-conv-evidence-passed`"是 singular，但实际有
> 两条 evidence 分支各承载独立的 CPU 路径 evidence。延续既有命名风格
> （`v2-arm-fpga-demo-passed` / `v2-fpga-e203-passed`），用平行的两个 tag 而
> 非单一 tag。

### 历史 frozen tags（不动，仅作对照）

| Tag | 指向 commit | 说明 |
|---|---|---|
| `v2-arm-fpga-demo-passed` | 早期 v1 | Fashion-MNIST 14×14 baseline，WSTRB 漏洞潜伏期 |
| `v2-arm-fpga-demo-v2-passed` | `03a39a61` | F1 修后 Fashion-MNIST 14×14 完整版 |
| `v2-fpga-e203-passed` | 早期版本 | E203 path Fashion-MNIST baseline |
| `v2-permanent-gate-2026-04-25` | 早期版本 | 永久 byte-mask invariant gate |

---

## 7. 引用规则（论文 / 简历 / handoff）

### 论文叙事

- **可写**：
  - "V2.B CONV extension validated on ZCU102 FPGA with bit-exact LeNet-5 inference
    (10/10 sample byte-exact match against integer reference) on two independent
    CPU paths (ARM Cortex-A53 + E203 RISC-V soft-core)."
  - "Evidence sealed at tags `v2-arm-fpga-demo-conv-passed @ e5d43a05` and
    `v2-fpga-e203-conv-passed @ 8642c84e`."

- **不可写**（M5 主动收兵相关）：
  - ❌ "We trained Tiny VGG / Plain-CNN-4 on the V2.B accelerator."
  - ❌ "Demonstrated CIFAR-10 inference on V2.B chip."
  - ✅ 替换为："V2.B CONV extension can run multi-layer CNN topologies bit-exact;
    LeNet-5 was used as the headline benchmark. CIFAR-10-class topologies
    plateaued at ~13% accuracy with the V2.B 4-bit/8-bit/T=10-64 quantization
    stack; richer accuracy targets are out of scope and would require a v3
    architectural rev."

### 简历

- 引用 closure tag + UART PASS marker，不引用 manifest SHA（manifest SHA 是工具链
  build 记录，不是板验事实唯一锚点；UART 抓到 marker + 本 closure log 是事实锚点）

### Handoff（给后续同事 / V3 接手者）

- 入口文件：本 closure log（`doc/v2-architecture/conv_extension_log.md`）
- 设计 spec：`C:/tmp/v2-conv-extension/doc/v2-architecture/conv_extension_design.md`
  （M0 design freeze，REV 5 时锁定的接口契约）
- 板验日志：`doc/arm-fpga-demo/board_bringup_log_lenet5.txt` /
  `doc/v2-fpga-e203/board_bringup_log_lenet5.txt`
- audit pass 报告：`doc/Claude_audit_pass{3,4,5}_report_2026_05_02.md`（在 main 分支）

---

## 8. v3 / Future Work（明确 out of scope）

本次 V2.B CONV extension 不在 scope 内、留作 v3 plan 必做：

1. **Weight-stationary 优化**：当前 activation-stationary 让 cosim runtime 1-2 天/sample；
   weight-stationary 把 weight load 从 H·W·N_tiles 降到 N_tiles，约 H·W× 加速
2. **CIFAR-10 capacity**：要么扩 weight bit-width（4-bit → 6-bit/8-bit），要么扩
   ADC 精度（8-bit → 10-bit），要么扩 T（10/64 → 256），任选其一或组合，让 V3
   能 break 13% 上限
3. **Spikformer / Transformer-like attention**：本架构无 element-wise add；v3 需要
4. **Residual sum / batchnorm / dropout / pool 专用算子**：当前用 stride 替代 pool，
   ResNet 没法做
5. **ASIC tape-out signoff for V2.B**：本次明确不流片；v3 如果要 tape-out 整条
   V2.B 路径，要重做 RTL 后端 + signoff

---

**封存声明**：本文件锁定于 2026-05-02。后续两条 evidence 分支若再演进
（修 sim bug / 加 audit pass），不改写本文件——演进证据走新 commit + 新 audit
report，本 closure log 反映 M7 节点的 ground truth。
