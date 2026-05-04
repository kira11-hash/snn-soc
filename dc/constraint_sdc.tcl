# ============================================================
# 本项目 SDC 约束 — V1 SNN SoC chip_top 单时钟 + pad-facing IO
# ============================================================
# 设计特性回顾（CLAUDE.md "FP-005 单时钟域 CDC 误判"）：
#   - 整个 SoC 数字部分单时钟 clk_pad，不存在多时钟域
#   - 异步信号入口已通过 reset_sync (rst_n_pad → rst_n_sync) 和
#     sync_2ff (cim_done_pad → cim_done_sync) 同步过；jtag_tck 由
#     jtag_mem_loader 内部 toggle + 2-FF sync 处理
#   - 所以本 SDC 不需要 set_clock_groups -asynchronous，单 create_clock 即可
# ============================================================

# 是否激进做常量传播。设 false 保持结构稳定，便于 LEC / DFT / 形式验证。
set CFG_CONST_PROP_ENABLE false
# 单时钟设计本不必要，但若 SDC 有 generated_clock 需要保险，可保 true。
set CFG_MULTI_CLOCKS_PER_REG true
# 异步复位 recovery/removal 检查。本项目 rst_n_pad 异步 + sync release，
# 同时 false_path -from rst_n_pad（见末尾），但综合阶段开此 flag
# 让工具能识别 reset 弧时序意图。
set CFG_ENABLE_RECOVERY_REMOVAL_ARCS true

# ============================================================
# 主时钟（chip_top 唯一对外时钟 pad）
# ============================================================
# 时钟名（SDC 内部引用）。
set CLK_NAME "CLK"
# 时钟端口名（必须与 rtl/top/chip_top.sv 里 input port 完全一致）。
set CLK_PORT "clk_pad"
# 时钟周期 ns。
#   公式：T = 1 / f
#   50 MHz → T = 20 ns（FPGA evidence 当前 clock）
#   100 MHz → T = 10 ns（流片目标可冲到此频）
# 第一次估面积建议先用 50 MHz 拿 baseline，再用 100 MHz 看面积/时序代价。
set CLK_PERIOD 20
# 波形（占空比 50%）。50% 占空比 + T=20ns → {0 10}
set CLK_WAVEFORM {0 10}

# ============================================================
# Slew / Transition 约束
# ============================================================
# 设计整体 max slew（参考 SMIC 55nm 库 ≤ 1.5ns，留 0.1ns 余量）。
set MAX_TRANSITION_DESIGN 1.4
# 时钟路径 max slew（更严格，~0.6x of design max）。
set MAX_TRANSITION_CLOCK_PATH 0.90
# 理想时钟源 transition（PLL/CTS 估算上升沿）。
set CLOCK_TRANSITION 0.9
# 输入端口 transition（外部驱动上升沿估算）。
set INPUT_TRANSITION 0.89

# ============================================================
# Driving cell / output load（与模板一致，库相同）
# ============================================================
set DRIVING_CELL "BUFHDV24"
set OUTPUT_LOAD_CELL "BUFHDV24"
set OUTPUT_LOAD_PIN "I"

# ============================================================
# IO 延迟通用约束（chip_top pad-facing 端口延迟估算）
# ============================================================
# 第一次面积估算用统一近似值。如某些关键 pad 有精确接口规格
#（如 SPI flash tCO / UART setup），后续可单独 override。
#
# 数值依据：
#   - 输入 max（setup 预算）：外部驱动 tCO + 板级延迟 + 余量 ≈ 4ns
#   - 输入 min（hold 预算）：外部驱动 tCO_min + 短路径 ≈ 1ns
#   - 输出 delay：外部接收端 setup + 板级 + 余量 ≈ 4ns
set IO_INPUT_DELAY_MAX  4
set IO_INPUT_DELAY_MIN  1
set IO_OUTPUT_DELAY     4

# 复位端口（异步）— 设 false_path（不做 setup/hold 检查）。
set RST_PORT "rst_n_pad"

# 负载引用路径（库 / 单元 / 引脚名拼接）。
set OUTPUT_LOAD_REF "${lib_slow}/${OUTPUT_LOAD_CELL}/${OUTPUT_LOAD_PIN}"

# ============================================================
# DC 应用变量
# ============================================================
set compile_enable_constant_propagation_with_no_boundary_opt $CFG_CONST_PROP_ENABLE
set timing_enable_multiple_clocks_per_reg $CFG_MULTI_CLOCKS_PER_REG
set enable_recovery_removal_arcs $CFG_ENABLE_RECOVERY_REMOVAL_ARCS

# ============================================================
# 时钟约束（单时钟 chip_top.clk_pad）
# ============================================================
create_clock -name $CLK_NAME -p $CLK_PERIOD [get_ports $CLK_PORT] -waveform $CLK_WAVEFORM

# 单时钟 SoC 不需要 set_clock_groups -asynchronous。
# 如未来引入第二时钟域（例如独立 ADC clock），在此处加：
# set_clock_groups -asynchronous -group {CLK} -group {ADC_CLK}

# ============================================================
# Transition / Load 约束
# ============================================================
set_max_transition  $MAX_TRANSITION_DESIGN [current_design]
set_max_transition  -clock_path $MAX_TRANSITION_CLOCK_PATH [all_clocks]
set_clock_transition $CLOCK_TRANSITION [all_clocks]
set_input_transition $INPUT_TRANSITION [all_inputs]

# Driving cell / output load
# 排除 clk_pad 和 rst_n_pad（不要给时钟和复位用 BUFHDV24 建模）。
set DRIVING_PORTS [remove_from_collection [all_inputs] \
                     [get_ports [list $CLK_PORT $RST_PORT]]]
set_driving_cell -lib_cell $DRIVING_CELL $DRIVING_PORTS
set_load [load_of $OUTPUT_LOAD_REF] [all_outputs]

# ============================================================
# IO 输入 / 输出延迟（统一约束所有 pad-facing 端口）
# ============================================================
# 所有输入端口（除 CLK / RST）受 CLK 约束。
# 用 -max 控 setup，用 -min 控 hold。
set INPUT_DATA_PORTS [remove_from_collection [all_inputs] \
                        [get_ports [list $CLK_PORT $RST_PORT]]]

set_input_delay  -max $IO_INPUT_DELAY_MAX  -clock $CLK_NAME $INPUT_DATA_PORTS
set_input_delay  -min $IO_INPUT_DELAY_MIN  -clock $CLK_NAME $INPUT_DATA_PORTS

# 所有输出端口受 CLK 约束。
set_output_delay $IO_OUTPUT_DELAY -clock $CLK_NAME [all_outputs]

# ============================================================
# False path
# ============================================================
# 异步复位 rst_n_pad 已通过 reset_sync 同步释放，但 raw rst_n_pad 仍
# 走 chip_top.u_reset_sync.rst_n_async，对 always_ff 是 async assert
# 路径——不做 setup/hold 检查。
set_false_path -from [get_ports $RST_PORT]
