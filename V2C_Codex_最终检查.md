# V2C RTL 开工前最终检查（Codex；多 subagent；只读、产出检查报告、勿改代码）

> 开工写 RTL 前的**最后把关**。用户要求"**不要有任何遗漏**"。Claude 已自检一遍（修了 spec/逻辑主线的状态/开工顺序/读延迟 caveat），现请你**独立再查、catch 我漏的**。

## 0. 任务 + 工作方式（用户硬规则）
**派多个 subagent（每个检查方面 ≥2 个 cross-check）**，对整个开工方案做最后仔细检查，找**任何漏洞 / 矛盾 / 遗漏 / 更极致 PPA 机会**。要求：自检、**不拘泥既定方案（发现更极致 PPA / 更大可发表 novelty 就提，哪怕推翻）**、带真实量级、诚实标注、不混仿真与硅。

## 1. 读什么（`~/dev/snn-soc/`）
- **`V2C_RTL开工spec.md`**（§9 定稿为准；§1-7 推导；§9.7 RRAM↔Python bit-exact 契约；§9.9 读 1-10μs 影响）
- **`V2C_论文逻辑主线.md`**（motivation + 三桶评估 + best/honest 原则）
- **`V2C_极致PPA创新点.md`**（§F 可行性、§G-§J 调研+cross-check、§K/§K0b 实测、§L 双方收敛、§M RTL 设计）
- **`plan-v1.md`**（架构规格）、**`encoding.py` + `robustness.py`**（parity 契约的 golden）、现有 `rtl/v2c/`、`cost.py`

## 2. 重点检查（多 subagent 分工，每方面 ≥2）
1. **逻辑/方案自洽**：A 喂→B 算→C 决策→D 编排 数据流咬合对吗？§9.2 开工顺序合理吗？§9.7 bit-exact 契约覆盖全吗？文档间有无残留矛盾（我刚修过状态/顺序/读延迟，复核）？
2. **bit-exact 风险（最关键，开工会崩 parity 的坑）**：① `mac_array32` 三套编码（W1 BNN / W2 ternary 含 (1,1) illegal 计数 / W≥4 two's-comp MSB 取负）逐一对 `encoding.mac` 对吗？② output bucket 的 **tie-break（首脉冲那拍膜 max→min idx）/ (row,t_fire) 保序 / fallback** 对 `forward.ttfs_classify`+`convert.strict_decode_from_traj` 吗？③ **lane-offset-22 未对齐 mapping**（output 落 block 7 lane 22-31）④ 末 stripe mask（246%32=22）⑤ dense_bypass 边界。
3. **PPA 遗漏 / 更极致**：有没有更省的招没挖到（不拘泥）？**读 1-10μs（§9.9 待澄清"1-bit sense 是否也慢"）** 的两情形方案对吗？读慢时"一次多读/读-算流水"评估对吗？counters（§9.3）够支撑论文 PPA 吗？
4. **novelty**：read-width-aligned bit-event 跳零 + popcount-free 行流 + 决策融进累积尾 + 单宏跨层，组合在数字二值 0T1R+TTFS 上，对标 E-ReCON/SpiDR/FlexSpIM 站得住吗？有无更强角度？
5. **评估口径**：三桶（数字 DC 实测 / 阵列器件数据 / 模拟外围 estimate）+ best/honest + worst-case，诚实吗？有无会被审稿人挑的？

## 3. 输出
分主题检查报告：【confirmed OK】【发现的漏洞/矛盾/遗漏（带 `文件:位置` + 修法）】【更极致 PPA 候选（带量级+novelty）】【开工前**必修** vs 可选】。最后一句"开工前最该先堵的一个风险"。我会逐条独立判定后落地，再写冷启动交接文档开工。
