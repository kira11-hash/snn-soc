# 论文 E0 三阶段重跑计划

## 目标

这份计划用于冻结论文导向的 E0 重跑流程，同时避免重新打开完整的全量搜索空间。当前范围严格限制为：

- `avgpool_8x8`
- `pad32_zero_8x8`
- `pad32_reflect_8x8`
- `pad32_replicate_8x8`
- `maxpool_8x8`
- `proj_sup_64`

这里不新增新的压缩方式。当前论文目标是在固定 64 输入硬件接口下，冻结一套干净的内部 baseline，而不是再开启新的算法方向。

这份文件只负责 E0 本身，不覆盖 E0 之后的总执行顺序。E0 完成后，必须转入总计划 [paper_plan.md](D:/SoC%20Design/SoC%20Design/doc/paper_plan.md) 中定义的 E0.5（RTL/配置同步 + 仿真和 smoke 重基线） -> 新 Step2/Step3 -> 正式实验 A-F 流程；E0 之前的旧仿真、旧 Step2、旧 Step3 结果不得直接作为正式论文结果引用。

## 第一阶段

目的：

- 在一组固定硬件点下先对前端方法做排序
- 避免因为同时加入 Scheme A 而把工作量翻倍
- 避免过早把 ratio 标定和硬件参数扫描混在一起

设置：

- 方法：以上 6 个 shortlist
- Scheme：只跑 `B`
- 固定配置：`ADC=8`、`W=4`、`T=3`
- 决策方式：`spike`
- noisy：关闭
- adaptive threshold：关闭
- ratio 粗扫网格：`0.01, 0.02, 0.04, 0.08, 0.15, 0.30, 0.50`
- 用于筛选的方法学口径：`val`

输出：

- `results/paper_e0/stage1/coarse_ratio_results.csv`
- `results/paper_e0/stage1/best_by_method.csv`
- `results/paper_e0/stage1/summary.json`
- `results/paper_e0/stage1/summary.txt`

第一阶段决定什么：

- overall 最优方法
- 非神经网络最优方法
- 推荐进入第二阶段的 finalists

## 第二阶段

目的：

- 只对第一阶段筛出来的 finalists 细化 `threshold_ratio`
- 在硬件点保持不变的前提下，把 ratio 锁得更精确

设置：

- 默认 finalists：第一阶段前 2 个非神经网络方法 + `proj_sup_64`
- Scheme：只跑 `B`
- 固定配置：`ADC=8`、`W=4`、`T=3`
- 决策方式：`spike`
- noisy：关闭
- adaptive threshold：关闭
- ratio 细扫网格：围绕第一阶段最优 ratio 做 `center +/- 0.05`，步长 `0.01`
- 用于筛选的方法学口径：`val`

输出：

- `results/paper_e0/stage2/fine_ratio_results.csv`
- `results/paper_e0/stage2/best_by_method.csv`
- `results/paper_e0/stage2/summary.json`
- `results/paper_e0/stage2/summary.txt`

第二阶段决定什么：

- 每个 finalist 的最终 ratio
- 非神经网络默认部署方法
- learned upper-bound reference

## 第三阶段

目的：

- 冻结最佳非神经网络方法
- 在 Scheme B 下扫描硬件参数
- 然后补齐论文最小必需证据：A/B 对照、noisy/ideal、adaptive threshold、final test

设置：

- 主方法：第二阶段选出的最佳非神经网络方法
- Scheme B 的 ratio：直接继承自第二阶段
- Scheme B 全量硬件网格：
  - `ADC_BITS = 6, 8, 10, 12`
  - `WEIGHT_BITS = 2, 3, 4, 6, 8`
  - `TIMESTEPS = 1, 3, 5, 10, 20`
- 决策方式：`spike`
- adaptive threshold：只在主 Scheme B 配置冻结后再评估
- noisy/ideal：只在主 Scheme B 配置冻结后再评估
- Scheme A：只在冻结方法上作为最终对照补跑

输出：

- `results/paper_e0/stage3/full_grid_scheme_b.csv`
- `results/paper_e0/stage3/adc_sweep.csv`
- `results/paper_e0/stage3/weight_sweep.csv`
- `results/paper_e0/stage3/timestep_sweep.csv`
- `results/paper_e0/stage3/scheme_a_coarse_ratio.csv`
- `results/paper_e0/stage3/scheme_a_fine_ratio.csv`
- `results/paper_e0/stage3/scheme_compare.csv`
- `results/paper_e0/stage3/noise_compare.json`
- `results/paper_e0/stage3/adaptive_compare.json`
- `results/paper_e0/stage3/final_test.json`
- `results/paper_e0/stage3/summary.json`
- `results/paper_e0/stage3/summary.txt`

## 服务器运行命令

在 Python 建模目录下运行：

```bash
python paper_e0_runner.py --stage 1
python paper_e0_runner.py --stage 2 --skip-train
python paper_e0_runner.py --stage 3 --skip-train
```

快速 sanity 路径：

```bash
python paper_e0_runner.py --stage 1 --quick
python paper_e0_runner.py --stage 2 --quick --skip-train
python paper_e0_runner.py --stage 3 --quick --skip-train
```

只有在下面三个条件同时满足时，才允许使用 `--skip-train`：

- 该阶段的方法列表没有变化
- 训练侧设置没有变化
- 所需权重已经存在于 `weights_full/` 或 `weights_quick/`

## Ratio 口径说明

这个 runner 有意使用论文专用的 staged ratio 网格 `0.01 ~ 0.50`。

除非你在文档中明确说明 ratio 定义已经变化，否则不要把这套 staged 结果与较新的 `config.py` 默认候选集（`2/255 ~ 12/255`）直接混合比较。

