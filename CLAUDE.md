# CLAUDE.md 鈥?SNN SoC 椤圭洰鍏抽敭绾︽潫

## 鈿狅笍 蹇呰瑙勫垯锛堟瘡娆″彂瑷€鍓嶅己鍒舵墽琛岋級

**姣忔鍙戣█涔嬪墠锛屽繀椤诲厛璇?鍢垮樋"锛屾棤涓€渚嬪銆?*

---

## 椤圭洰鏍稿績鍙傛暟锛堢粷涓嶅彲鏀瑰姩锛岄櫎闈炵敤鎴锋槑纭姹傦級

| 鍙傛暟 | 鍊?| 璇存槑 |
|------|----|------|
| NUM_INPUTS | 64 | 8脳8 杈撳叆锛屽凡鏀癸紙鍘?7脳7=49锛墊
| ADC_BITS | 8 | 8-bit ADC锛?-bit 鐣?V2 |
| ADC_CHANNELS | 20 | Scheme B 宸垎锛?0璺?|
| TIMESTEPS | 3 | 工程默认，按性价比定版 |
| THRESHOLD_RATIO | 4 | ratio_code，对应 THRESHOLD_DEFAULT=3060 |
| THRESHOLD_DEFAULT | 3060 | = 4 × 255 × 3 |
| NEURON_DATA_WIDTH | 9 | signed 9-bit锛圫cheme B 宸垎杈撳嚭锛墊

## 瀵勫瓨鍣ㄥ湴鍧€琛紙蹇€熷弬鑰冿紝鏉冨▉浠?doc/02_reg_map.md 涓哄噯锛?

> 娉ㄦ剰锛氫笉鍚屽璁炬湁涓嶅悓鍩哄湴鍧€锛屼笉瑕佹妸 offset 娣锋垚鍚屼竴寮犺〃銆?

### REG_BANK锛堝熀鍦板潃 `0x4000_0000`锛?

| 缁濆鍦板潃 | offset | 鍚嶇О | 璇存槑 |
|------|------|------|------|
| 0x4000_0000 | 0x00 | REG_THRESHOLD | LIF 阈值（default 3060） |
| 0x4000_0014 | 0x14 | CIM_CTRL | [0]=START(W1P), [1]=SOFT_RESET(W1P), [7]=DONE(W1C) |
| 0x4000_0018 | 0x18 | STATUS | [0]=BUSY, [4:1]=FIFO 鏍囧織, [15:8]=TIMESTEP_CNT |
| 0x4000_0024 | 0x24 | REG_THRESHOLD_RATIO | 8-bit ratio_code锛坉efault 4锛宻hadow锛?|
| 0x4000_002C | 0x2C | REG_CIM_TEST | [0]=test_mode, [15:8]=test_data_pos, [23:16]=test_data_neg |

### DMA锛堝熀鍦板潃 `0x4000_0100`锛?

| 缁濆鍦板潃 | offset | 鍚嶇О | 璇存槑 |
|------|------|------|------|
| 0x4000_0100 | 0x00 | DMA_SRC_ADDR | DMA 婧愬湴鍧€ |
| 0x4000_0104 | 0x04 | DMA_LEN_WORDS | DMA 闀垮害锛堝崟浣嶏細32-bit word锛?|
| 0x4000_0108 | 0x08 | DMA_CTRL | [0]=START(W1P), [1]=DONE(W1C), [2]=ERR(W1C), [3]=BUSY(RO) |

## CIM Test Mode锛堟祦鐗囧悗鑷鍏抽敭锛?

- `test_mode=1` 鈫?缁曡繃妯℃嫙 CIM 瀹忥紝鍙湪鏃犳ā鎷熻姱鐗囨儏鍐典笅楠岃瘉鏁板瓧閾捐矾
- 鍐欐硶锛歚wstrb=4'b0111`锛宍data=32'h0000_6400`锛坧os=0x64=100锛宯eg=0锛?
- 结果：diff = 100，T=3 即可观察到 LIF 累加并产生 OUT_FIFO（用于验证数字链路）
- MUX 閫昏緫锛歚bl_sel < NUM_OUTPUTS ? cim_test_data_pos : cim_test_data_neg`

## Scheme B 宸垎锛堟牳蹇冩灦鏋勫喅绛栵級

- 20璺?ADC 閫氶亾锛歝h 0-9 = pos鍒楋紝ch 10-19 = neg鍒?
- 鏁板瓧渚ц绠楋細`diff[i] = raw[i] - raw[i+10]`锛坰igned 9-bit锛?
- 杩欐槸纭畾鏂规锛圓1锛夛紝涓嶅彲鏀瑰洖 Scheme A

## 浠跨湡鐜

- **瀹屾暣浠跨湡**锛歀inux + VCS + Verdi锛堝叆鍙ｏ細`sim/run_vcs.sh`锛?
- **鏈湴杞婚噺**锛欼carus锛坄cd sim && bash run_icarus_light.sh`锛?
- **閫氳繃鏍囧噯**锛歚LIGHT_SMOKETEST_PASS`锛孫UT_FIFO_COUNT=20锛堥潪闆跺嵆鍙級
- SVA 鏂█鍦?`` `ifdef VCS `` 鍐咃紝Icarus 鐢?`-gno-assertions` 璺宠繃

## 鏂囦欢缂栫爜娉ㄦ剰

- `SNNSoC宸ョ▼涓绘枃妗?md` 鍚?`\xa0`锛坣on-breaking space锛夛紝Edit 宸ュ叿鏃犳硶鍖归厤鏃舵敼鐢?Python 鑴氭湰
- 閮ㄥ垎 `.sv` 鏂囦欢鏈?UTF-8 BOM锛屾敞鎰忕紪杈戝櫒璁剧疆

## AXI-Lite 分支状态（feature/axi-lite，2026-03-01）

- **已完成**：`rtl/bus/axi_lite_if.sv`（接口定义）、`rtl/bus/axi2simple_bridge.sv`（5态 FSM 桥接）
- **已完成**：`tb/axi_bridge_tb.sv`（T1~T9，含字节写使能、AW/W错拍与B/R背压测试）、`sim/sim_axi_bridge.f`、`sim/run_axi_bridge_icarus.sh`
- **待做**：`rtl/bus/axi_lite_interconnect.sv`（可选，E203 接入前不急）、集成进 `snn_soc_top.sv`
- 运行测试：`cd sim && bash run_axi_bridge_icarus.sh`，通过标准：`AXI_BRIDGE_SMOKETEST_PASS`
- 桥时序：写/读均为 2 cycle（IDLE→PEND→RSP），bus_simple 固定 1-cycle 响应与之匹配

## 当前迭代路径（顺序固定，不可跳步）

1. **AXI-Lite 基础骨架** ✅（进行中）：`axi_lite_if` + `axi2simple_bridge` + AXI TB（T1~T9）已完成；下一步是 `axi_lite_interconnect` 与 `snn_soc_top.sv` 集成。
2. **UART**：最小可用（TX/RX + 状态寄存器），用于 bring-up 打印日志。
3. **SPI**：先做 Flash 读路径（读 ID + 连续读），暂不追求复杂模式，为 boot/data load 做准备。
4. **DMA 扩展**：先打通 SPI → SRAM，再 SRAM → input_fifo，每条路径单独写 TB，确认 done/err/busy。
5. **E203 最后接入**：先跑最小固件（UART 打印 → SPI 读 → DMA 搬运），出问题容易定位。
## 不可修改事项（除非用户明确授权）

- 不可修改上表中的任何定版参数。
- 不可删除 `ifndef SYNTHESIS` / `ifdef VCS` 宏保护。
- 不可将 Scheme B 改回 Scheme A。
- 不可 force push 到 `main` 分支。

- 论文口径：可附加 T=10 作为高精度对照点，做精度/时延 trade-off 图。


