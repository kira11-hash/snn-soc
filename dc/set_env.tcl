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
