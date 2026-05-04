# ============================================================
# 本项目环境配置 — V1 SNN SoC tape-out 面积估算
# ============================================================

# 项目 RTL 根目录或 flist 根目录。
# 本项目 dc 脚本从 dc/ 目录启动，flist.f 也放在 dc/，所以 RTL_FILE = "."；
# flist.f 内文件路径用 "../rtl/..."（相对 dc/）。
set RTL_FILE        .

# 顶层模块名（chip_top 是 V1 tape-out-intent pad-level wrapper，
# 包含 reset_sync + sync_2ff + snn_soc_top 实例 + 所有 pad-facing port）。
# 必须与 rtl/top/chip_top.sv 里 `module chip_top` 完全一致。
set working_design  chip_top

# 本次综合版本号 / 标签（区分不同综合批次的 RPT/OUT/WORK 子目录）。
set file_version    soc_v1_estimate

# 是否需要 scan / DFT。
# 流片项目最终需要 DFT；首次面积估算 do_scan=0 拿 base 数字，
# 后续上 DFT 流程时再开 do_scan=1 看 scan-friendly 综合后面积变化。
set do_scan         0

# 报告 / 输出根目录（首次跑会自动 mkdir）。
set RPT_DIR         RPT
set OUT_DIR         OUT

# 输出路径派生（不需改，自动跟随 RPT_DIR/OUT_DIR + file_version）。
set RPT_OUT  [format "%s%s" $RPT_DIR/ $file_version]
set DATA_OUT [format "%s%s" $OUT_DIR/ $file_version]

# 工艺库角点名（SMIC 55nm low-leakage HS-RVT，与模板同库）。
set lib_slow      scc55nll_hs_rvt_ss_v1p08_125c_basic
set lib_fast      scc55nll_hs_rvt_ff_v1p32_0c_basic

# ============================================================
# 面积优化与 black-box 选项（2026-05-04 加，修正 over-estimate）
# ============================================================
# OPT_SRAM_BLACKBOX = 1（默认）：把 sram_simple / sram_simple_dp / boot_rom /
#   cim_macro_blackbox 4 个模块替换成 dc/stubs/ 下的空 stub，DC 综合时这些
#   cell 占 0 area，避免行为模型综合成 FF 阵列后的 over-estimate。
#   面积报告里只看到真实数字逻辑（reg_bank / dma_engine / e203 / etc.）。
#   真实 SRAM macro / mask ROM / 模拟 CIM macro 的面积由 P&R 阶段或模拟侧补回。
#
# OPT_SRAM_BLACKBOX = 0：综合所有真 RTL，得到 over-estimate（FF 阵列）。
#   若需 sanity check 一下 SRAM 行为模型的 RTL 没问题，跑这个版本。
set OPT_SRAM_BLACKBOX 1

# OPT_USE_TEMPLATE_MEM_LIB = 1：加载 template 的 weight_sram + neuron_sram
#   两个 SRAM macro lib（来自 SNPU 项目，本 V1 SoC 不实际使用）。
#   仅当 DC 因为找不到这些 .db 报错时才需要切到 0 把它们从 link_library 去掉。
# OPT_USE_TEMPLATE_MEM_LIB = 0（默认）：不加载，本项目不需要这些 macro。
set OPT_USE_TEMPLATE_MEM_LIB 0

# OPT_AREA_HIGH_EFFORT = 1（默认）：compile_ultra 加 -area_high_effort_script，
#   触发 DC 额外的面积优化 pass（多跑几轮 area recovery）。代价：综合时间 +30~60%。
# OPT_AREA_HIGH_EFFORT = 0：标准 compile，时间快但面积可能略大。
set OPT_AREA_HIGH_EFFORT 1

# OPT_GATE_CLOCK = 1（默认）：compile_ultra 加 -gate_clock，自动插入 clock
#   gating cells。同时降低面积（FF 数量减少）+ 动态功耗。流片项目通常开启。
#   若 DFT scan 流程对 clock gating 敏感，可关闭后再综合一次对比。
# OPT_GATE_CLOCK = 0：不插 clock gating，结构更简单但面积/功耗略差。
set OPT_GATE_CLOCK 1

# OPT_POST_COMPILE_AREA = 1（默认）：compile 完成后跑 optimize_netlist -area
#   做最后一轮面积扫尾（对已生成网表做局部 cell 替换 / 删除 / 合并）。
# OPT_POST_COMPILE_AREA = 0：不跑扫尾，节省 5~10 分钟。
set OPT_POST_COMPILE_AREA 1

# OPT_CONST_PROP_AREA = 1（默认）：允许 no-boundary-opt 场景下的常量传播。
#   作用：把 tied-off / 永远不翻转的控制条件进一步向下推进，去掉死逻辑，
#   对面积估算更友好。代价：局部结构可能比“保守保形”模式更激进。
# OPT_CONST_PROP_AREA = 0：保持当前保守模式，优先结构稳定性。
set OPT_CONST_PROP_AREA 1

# OPT_SET_MAX_AREA = 1（默认）：在 compile 前显式下 `set_max_area 0`，
#   告诉 DC 在满足时序/DRC 的前提下继续做面积恢复。
# OPT_SET_MAX_AREA = 0：不额外下 max_area 目标，只靠 compile_ultra 默认策略。
set OPT_SET_MAX_AREA 1
