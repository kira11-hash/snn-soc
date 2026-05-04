# ============================================================
# 本项目 dont_touch — V1 SNN SoC chip_top
# ============================================================
# 必须保护的对象：
#   1. u_soc_core/u_macro (cim_macro_blackbox)
#      → 行为模型；流片时由模拟 CIM macro 替换；不允许综合优化破坏其端口
#
# 不需要 dont_touch（让 DC 综合，得到 over-estimate 面积）：
#   - u_soc_core/u_boot_rom (boot_rom.sv) — tape-out 由 foundry mask ROM
#     compiler 替换；综合后 over-estimate，最终汇报时手动扣除
#   - u_soc_core/u_instr_sram / u_data_sram / u_weight_sram
#     (sram_simple / sram_simple_dp 行为模型) — 流片由 SRAM macro 替换；
#     综合后 over-estimate，最终汇报时按 SRAM 容量乘以 macro density 手动校正
#   - 其他 SoC 数字逻辑（reg_bank / dma_engine / e203 vendor / 等）
#     全部让 DC 综合
# ============================================================

# CIM 模拟 macro 实例路径（chip_top.u_soc_core.u_macro）。
# 综合时此 cell 内部行为模型不被优化；流片前 LEC / 后端会替换为真实
# 模拟 CIM macro 黑盒。
set DONT_TOUCH_CIM_MACRO "u_soc_core/u_macro"

set_dont_touch [get_cells $DONT_TOUCH_CIM_MACRO]

# 如未来要 dont_touch 更多对象（例如把 SRAM 转黑盒后），在此处追加：
# set_dont_touch [get_cells u_soc_core/u_instr_sram]
# set_dont_touch [get_cells u_soc_core/u_data_sram]
# set_dont_touch [get_cells u_soc_core/u_weight_sram]
# set_dont_touch [get_cells u_soc_core/u_boot_rom]
