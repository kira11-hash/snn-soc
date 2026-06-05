# V2C RTL Bug 记录

> 记录 V2C 论文线（`snn_soc_v2c_top` 及数字二值 CIM / TTFS / bit-cell P&V 等新模块）RTL 开发中**发现的 bug、根因与解决办法**。
> **与 `已修复的bug原因及其解决办法.md`（V1 / V2.B）区分、不覆盖。** 创建于 2026-06-04（V2C RTL 尚未开工，先建模板，随开发追加）。

## 记录格式

每条 bug 一节，含：

- **日期 / 模块**：
- **现象**：仿真（Verdi/iverilog）、综合（DC）或 FPGA 上的可观察症状。
- **根因**：定位到的真正原因，不止表象。
- **修复**：具体改动（文件 / 信号 / 逻辑）。
- **回归**：验证修复的 TB / 结果。

> 提示：bit-parallel shift-add 的符号位（MSB 取负**仅 two's-complement W≥4**；W=2 ternary 用 `popcount(pos)−popcount(neg)`、W=1 BNN 用 `2·popcount(1)−N_active`，**按 encoding mode 分支**）、列映射 `col=(layer_base+out)*W+bit`（多层常驻含 layer_base）、单宏常驻各层列段地址、首 spike 早停的时序、LFSR/ROM 非理想注入与理想模式 bit-exact 这几处历来易错，重点记录；P&V 的双极性切换（SET WL=3.3/BL=0 vs RESET WL=0/BL=3.3）、半选 1.5V 偏置、VERIFY 读回（BL=0.75 抑制）的极性/时序也易错；ternary 的 `(1,1)` 非法态在非理想 bit-flip 下会被 `popcount(pos)−popcount(neg)` 静默解成 0，必须 RTL assert（理想）+ 计 illegal/fault（非理想），别吞。

---

## （暂无 —— V2C RTL 待开工后在此追加）
