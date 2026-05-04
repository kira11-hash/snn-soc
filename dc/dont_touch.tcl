# ============================================================
# 本项目 dont_touch — V1 SNN SoC chip_top
# ============================================================
# 必须保护的对象：
#   1. u_soc_core/u_macro (cim_macro_blackbox) — 模拟 CIM macro 实例
#      - OPT_SRAM_BLACKBOX=1：stub 模式（端口 tied to 0），dont_touch 防止
#        被优化掉、保持端口与下游连接，方便 P&R 时换真模拟 macro
#      - OPT_SRAM_BLACKBOX=0：行为模型，dont_touch 防止综合优化破坏其端口
#
#   2. （仅 OPT_SRAM_BLACKBOX=1）SRAM / boot_rom 实例：
#      - u_soc_core/u_boot_rom (boot_rom)
#      - u_soc_core/u_instr_sram (sram_simple)
#      - u_soc_core/u_data_sram (sram_simple_dp)
#      - u_soc_core/u_weight_sram (sram_simple)
#      stub 模式下这些 cell 是空 module（输出 tied to 0），dont_touch 防止
#      DC 把整个 cell 优化掉（认为 0 输出 = 无用）。流片时 P&R 接入真 SRAM macro。
# ============================================================

# CIM 模拟 macro 实例路径（chip_top.u_soc_core.u_macro），无论 stub 还是行为
# 模式都需要 dont_touch。
set_dont_touch [get_cells u_soc_core/u_macro]
# 显式保护 reset / CDC 同步器壳层，避免综合时跨级优化破坏同步器结构。
set_dont_touch [get_cells u_reset_sync]
set_dont_touch [get_cells u_cim_done_sync]

# 仅 stub 模式下，把 SRAM / boot_rom 实例也 dont_touch，防止空 stub 被优化掉。
if {$OPT_SRAM_BLACKBOX == 1} {
    echo {[INFO] dont_touch SRAM + boot_rom stubs (OPT_SRAM_BLACKBOX=1)}
    set_dont_touch [get_cells u_soc_core/u_boot_rom]
    set_dont_touch [get_cells u_soc_core/u_instr_sram]
    set_dont_touch [get_cells u_soc_core/u_data_sram]
    set_dont_touch [get_cells u_soc_core/u_weight_sram]
}
