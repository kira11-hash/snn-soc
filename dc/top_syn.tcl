# ============================================================
# 可配置参数（易变项集中在这里）
# ============================================================
# 脚本目录名。本项目所有 .tcl 直接放在 dc/ 根目录下（不用 script/ 子目录），
# 所以 SCRIPT_FILE = "."；source 路径变成 ./set_env.tcl 等。
set SCRIPT_FILE "."
# 环境初始化脚本名（定义库/设计名等）。
set SET_ENV_FILE "set_env.tcl"
# 目录创建脚本名（创建 RPT/OUT/WORK 等）。
set FILE_CREATE_FILE "file_create.tcl"
# 参数配置脚本名（综合开关/规则）。
set SET_PARAMETER_FILE "set_parameter.tcl"
# 约束脚本名（SDC）。
set CONSTRAINT_FILE "constraint_sdc.tcl"
# dont_touch 脚本名（保护 RAM/PLL/CDC 等）。
set DONT_TOUCH_FILE "dont_touch.tcl"

# 综合命令名称（通常是 compile_ultra，可替换为 compile 等）。
set COMPILE_TOOL "compile_ultra"
# 基础综合选项（稳定层级、便于约束/调试）。
set CMP_OPT_BASE "-no_autoungroup"
# 扫描相关选项（需要 scan/DFT 时启用）。
set CMP_OPT_SCAN "-scan"

# 标准单元库根目录（来自统一的 library.tcl 配置）。
set LIB_PATH "/home/PIE_student_1/Documents/smic55ll"
# 目标库列表（多角点：ss/tt/ff）。
set TARGET_LIB_LIST [list \
            "$LIB_PATH/STD/SCC55NLL_HS_RVT_V2p1a/liberty/1.2v/scc55nll_hs_rvt_ss_v1p08_125c_basic.db" \
            "$LIB_PATH/STD/SCC55NLL_HS_RVT_V2p1a/liberty/1.2v/scc55nll_hs_rvt_tt_v1p2_25c_basic.db" \
            "$LIB_PATH/STD/SCC55NLL_HS_RVT_V2p1a/liberty/1.2v/scc55nll_hs_rvt_ff_v1p32_0c_basic.db" \
            ]
# IO 库（用于 I/O 单元解析）。
set IO_LIBRARY "$LIB_PATH/IO/SP55NLLD2RP_OV3_V0p7/syn/3p3v/SP55NLLD2RP_OV3_V0p4_tt_V1p20_25C.db"
# synthetic 库（DesignWare 等综合库）。
set SYNTHETIC_LIBRARY "/home/opt/Synopsys/syn/T-2022.03-SP5-5/libraries/syn/dw_foundation.sldb"
# memory 宏库列表（如 SRAM/ROM 等）。
set MEMORY_LIB_LIST [list \
            "/home/DS_student_2/INNOVUS/innovus1_ref/SNPU_syn_v1(setup05hold05)/SNPU_syn_v1(setup05hold05)/lib/weight_sram/S55NLLGSPH_X128Y4D100_BW_ss_1.08_125.db" \
            "/home/DS_student_2/INNOVUS/innovus1_ref/SNPU_syn_v1(setup05hold05)/SNPU_syn_v1(setup05hold05)/lib/neuron_sram/S55NLLGSPH_X72Y4D128_ss_1.08_125.db" \
            ]

# 搜索路径列表（RTL/库等文件的查找路径）。
# 按 library.tcl 一致，仅使用库根目录。
set SEARCH_PATH_LIST [list $LIB_PATH]

# analyze 输入格式（sverilog 适用于 SystemVerilog）。
set ANALYZE_FORMAT "sverilog"
# filelist 文件名（存放 RTL 列表）。dc/flist.f 是本项目 ASIC syn 用 RTL 清单
# （从 sim/sim_chip_top_rom_smoke.f 派生，去除 TB 文件 + FPGA 专用文件）。
set FILELIST_NAME "flist.f"
# analyze 在 VCS 兼容模式下接受一个**单一字符串**包含所有 VCS-style 参数，
# 包括 -f flist.f / +define+ / +incdir+。本项目需要：
#   - +define+SOC_ENABLE_E203_VENDOR：用真 E203 vendor RTL（rtl/vendor_e203/e203/core/*.v）
#     而不是 e203_min_wrap 里的 stub 分支
#   - +incdir+../rtl/vendor_e203/e203/core：让 vendor 文件之间 `include 能互相找到
#   - -f ./flist.f：本项目 RTL 清单
#   - 不设 +define+FPGA_SOURCE：综合目标是 ASIC，不要 Xilinx XPM 等 FPGA-only 路径
# 注意：VCS_OPTIONS 字符串末尾必须以 -f flist.f 收尾（VCS 习惯）。

# link_library 的前缀（通常是 "*" 表示先从已读设计解析）。
set LINK_LIB_PREFIX "*"

# 设计库名称（DC 的 WORK 库名）。
set WORK_LIB_NAME "WORK"
# 设计库根目录（会拼接 file_version 形成子目录）。
set WORK_LIB_BASE "./WORK"

# 时钟报告文件名。
set RPT_CLOCK_FILE "clock.syn.rpt"
# compile 报告文件名。
set RPT_COMPILE_FILE "compile.rpt"
# 增量 compile 报告文件名（第一次）。
set RPT_COMPILE_INC_FILE "compile_inc.rpt"
# 增量 compile 报告文件名（第二次）。
set RPT_COMPILE_INC2_FILE "compile_inc2.rpt"
# 结构检查报告文件名。
set RPT_CHECK_DESIGN_FILE "check_design.rpt"
# 时序检查报告文件名。
set RPT_CHECK_TIMING_FILE "check_timing.rpt"
# QoR 报告文件名。
set RPT_QOR_FILE "qor.rpt"
# 面积报告文件名（总览）。
set RPT_AREA_FILE "area.rpt"
# 面积报告文件名（层级）。
set RPT_AREA_HIER_FILE "area_hier.rpt"
# 组合环路报告文件名。
set RPT_TIMING_LOOP_FILE "timing_loop.rpt"
# 最小延迟（hold）报告文件名。
set RPT_TIMING_MIN_FILE "timing.min.rpt"
# 最大延迟（setup）报告文件名。
set RPT_TIMING_MAX_FILE "timing.max.rpt"
# 约束违规报告文件名。
set RPT_CONSTRAINTS_FILE "constraints.rpt"
# 功耗报告文件名。
set RPT_POWER_FILE "power.rpt"

# report_timing 输出的最大路径条数。
# 公式：TIMING_MAX_PATHS = 你希望总共看的最坏路径数量。
# 例：快速查看可设 20~50；深入分析可设 200（这里就是 200）。
set TIMING_MAX_PATHS 200
# report_timing 每组最差路径条数。
# 公式：TIMING_NWORST = 每个时钟组内需要查看的最坏路径数量。
# 例：只看最坏 10 条可设 10；全面排查可设 100~200。
set TIMING_NWORST 200

# 输出网表扩展名。
set NETLIST_EXT "v"
# 输出 ddc 扩展名。
set DDC_EXT "ddc"
# 输出 sdc 扩展名。
set SDC_EXT "sdc"
# 输出 sdf 扩展名。
set SDF_EXT "sdf"
# SDF 版本号（按仿真器/后端工具支持选择）。
# 例：VCS/Questa 通常兼容 2.1；若流程要求 SDF 3.0，则改为 "3.0"。
set SDF_VERSION "2.1"

# 总线命名风格（影响网表/SDC/LEC 兼容性）。
set BUS_NAMING_STYLE {%s[%d]}

# 后面所有脚本，都默认放在 ./script/ 目录下，这是工程可维护性的写法：
# 不把 script 这个目录名写死在每一行
# 后面如果你改成：
#set SCRIPT_FILE scripts_syn
# 改成后这里只需改一次，其余脚本路径不用动

source ./$SCRIPT_FILE/$SET_ENV_FILE

#source：执行另一个 Tcl 文件
#set_env.tcl = “综合世界初始化”
#新手最容易犯的错

#❌ 把 set_env.tcl 当成“普通脚本”随便插位置
#❌ 在后面又重新 set library，把这里覆盖
#❌ 不知道变量在哪定义，以为是 DC 内建的

source -echo ./$SCRIPT_FILE/$FILE_CREATE_FILE
#-echo 是什么

#-echo 的作用：
#👉 在 log 里把执行的 Tcl 命令原样打印出来
#也就是说：
#不影响功能
#只影响 可读性 / 可 debug 性
#file_create.tcl 通常干什么？
#名字已经非常诚实了：
#一般包含：
#file mkdir WORK
#file mkdir REPORT
#file mkdir LOG
#或者更高级一点：
#foreach dir {WORK REPORT LOG NETLIST} {
#   if {![file exists $dir]} {
#       file mkdir $dir
#   }
#}
#👉 这是“工程目录结构初始化”
#为什么单独拆成一个文件？
#两个原因：
#不会被反复修改
#所有流程（综合 / 形式验证 / STA）都能复用

# 派生变量（基于 set_env.tcl 与可配置区）
# WORK 的版本目录（用于 cache/中间产物隔离）。
set WORK_VERSION_DIR [format "%s/%s" $WORK_LIB_NAME $file_version]
# WORK 设计库物理路径（define_design_lib 使用）。
set WORK_LIB_PATH [format "%s/%s" $WORK_LIB_BASE $file_version]
# filelist 完整路径（RTL_FILE = "." + flist.f → "./flist.f"，相对 dc/）。
set FILELIST_PATH [format "%s/%s" $RTL_FILE $FILELIST_NAME]
# 完整 VCS 参数串（包括 +define+ / +incdir+ / -f flist.f，全部塞进 -vcs 引号）。
set VCS_OPTIONS [format "+define+SOC_ENABLE_E203_VENDOR +incdir+../rtl/vendor_e203/e203/core -f %s" $FILELIST_PATH]
# link_library 列表（包含 "*" + 目标库 + synthetic + memory + IO 库）。
# concat 用于展开 TARGET_LIB_LIST/MEMORY_LIB_LIST 里的多条路径。
set LINK_LIB_LIST [concat $LINK_LIB_PREFIX $TARGET_LIB_LIST $SYNTHETIC_LIBRARY $MEMORY_LIB_LIST $IO_LIBRARY]

# 时钟报告输出路径。
set RPT_CLOCK_PATH [format "%s/%s" $RPT_OUT $RPT_CLOCK_FILE]
# compile 报告输出路径。
set RPT_COMPILE_PATH [format "%s/%s" $RPT_OUT $RPT_COMPILE_FILE]
# 第一次增量 compile 报告输出路径。
set RPT_COMPILE_INC_PATH [format "%s/%s" $RPT_OUT $RPT_COMPILE_INC_FILE]
# 第二次增量 compile 报告输出路径。
set RPT_COMPILE_INC2_PATH [format "%s/%s" $RPT_OUT $RPT_COMPILE_INC2_FILE]
# 结构检查报告输出路径。
set RPT_CHECK_DESIGN_PATH [format "%s/%s" $RPT_OUT $RPT_CHECK_DESIGN_FILE]
# 时序检查报告输出路径。
set RPT_CHECK_TIMING_PATH [format "%s/%s" $RPT_OUT $RPT_CHECK_TIMING_FILE]
# QoR 报告输出路径。
set RPT_QOR_PATH [format "%s/%s" $RPT_OUT $RPT_QOR_FILE]
# 面积报告输出路径（总览）。
set RPT_AREA_PATH [format "%s/%s" $RPT_OUT $RPT_AREA_FILE]
# 面积报告输出路径（层级）。
set RPT_AREA_HIER_PATH [format "%s/%s" $RPT_OUT $RPT_AREA_HIER_FILE]
# 组合环路报告输出路径。
set RPT_TIMING_LOOP_PATH [format "%s/%s" $RPT_OUT $RPT_TIMING_LOOP_FILE]
# 最小延迟（hold）报告输出路径。
set RPT_TIMING_MIN_PATH [format "%s/%s" $RPT_OUT $RPT_TIMING_MIN_FILE]
# 最大延迟（setup）报告输出路径。
set RPT_TIMING_MAX_PATH [format "%s/%s" $RPT_OUT $RPT_TIMING_MAX_FILE]
# 约束违规报告输出路径。
set RPT_CONSTRAINTS_PATH [format "%s/%s" $RPT_OUT $RPT_CONSTRAINTS_FILE]
# 功耗报告输出路径。
set RPT_POWER_PATH [format "%s/%s" $RPT_OUT $RPT_POWER_FILE]

# 最终门级网表输出路径。
set OUTPUT_NETLIST_PATH [format "%s/%s.%s" $DATA_OUT $working_design $NETLIST_EXT]
# SDF 输出路径。
set OUTPUT_SDF_PATH [format "%s/%s.%s" $DATA_OUT $working_design $SDF_EXT]
# DDC 输出路径。
set OUTPUT_DDC_PATH [format "%s/%s.%s" $DATA_OUT $working_design $DDC_EXT]
# SDC 输出路径。
set OUTPUT_SDC_PATH [format "%s/%s.%s" $DATA_OUT $working_design $SDC_EXT]

# 增量综合缓存写入路径（指向版本化 WORK 目录）。
set cache_write  $WORK_VERSION_DIR
# 增量综合缓存读取路径（指向版本化 WORK 目录）。
set cache_read   $WORK_VERSION_DIR

#字面含义
#定义两个路径变量：
#cache_write：写缓存用
#cache_read：读缓存用
#实际展开为：
#WORK/<某个版本号>
#其中：
#WORK/：综合中间产物目录
#$file_version：一定是在前面某处定义的变量
#$file_version 通常是什么？
#常见写法有三种：
#✅ 时间戳
#set file_version 20260111_v1
#✅ Git hash / tag
#set file_version syn_rtl_clean
#✅ 自动生成
#set file_version [clock format [clock seconds] -format "%Y%m%d_%H%M"]
#这套 cache 机制是干嘛的？（重点）
#这是用来支持：
#增量综合
#版本回滚
#多次试跑参数对比
#典型用途（后面你一定会看到）：
#compile_ultra -incremental -cache_read $cache_read -cache_write $cache_write
#👉 不是给新手玩的，但模板已经给你铺好路了

# set CMP_OPTION "-no_autoungroup -scan"
if {$do_scan == 1} { 
set CMP_OPTION [format "%s %s" $CMP_OPT_BASE $CMP_OPT_SCAN]
} else {
set CMP_OPTION [format "%s" $CMP_OPT_BASE]
}

#通过变量 do_scan 决定是否加 -scan 选项
#-scan（重点）
#让综合更倾向于生成可插入scan链的结构/门级风格
#典型影响：会更严格地处理触发器、复位、时钟门控等，使得DFT工具更友好
#实际是否“需要”：看项目是否要做scan/DFT（流片项目一般要）
#如果你是做可流片 SoC，通常 do_scan=1 是常态。
#-no_autoungroup（重点中的重点）
#禁止工具“自动把层级拆掉/拍扁”
#否则工具可能为了优化 QoR 自动 ungroup 一些层级模块
#为什么模板默认加这个：
#你做 SoC/大设计时，层级稳定性比“多抠 1% QoR”更重要：
#方便 debug
#方便约束绑定（特别是层级路径）
#方便后端/DFT/形式验证对齐

set compile_cmd  "$COMPILE_TOOL $CMP_OPTION"
alias do_compile $compile_cmd
alias do_compile_inc $compile_cmd -inc

#compile_cmd 是一个字符串："compile_ultra <options>"
#alias do_compile ...：创建一个别名命令
#之后你可以在 Tcl 里直接写：
#do_compile
#等价于执行 compile_ultra ...
#do_compile_inc：等价于 compile_ultra ... -inc
#-inc 是什么
#incremental compile（增量综合）
#典型用法：当设计只改了局部时，复用之前编译结果，加快速度/保持结果稳定
#注意：增量依赖于 cache / 先前结果，因此后面你看到的 cache_read/cache_write 就对上了。

# 新项目必改：更新 RTL/库的搜索路径（尽量用环境变量避免硬编码绝对路径）。
set search_path $SEARCH_PATH_LIST

#earch_path 是 DC/综合工具用来搜索文件的路径列表
#里包含：
#前目录 ./
#一级 ../
#艺库目录 /home/.../smic55nm_lib/.../1.2v
#程习惯上它会影响什么？
#ead_verilog xxx.v 如果你没写全路径，它会按 search_path 去找
#et target_library ... 指向库文件时也可能按 search_path 搜
#该如何对待
# 项目换工艺、换库，这里几乎必改
# 别写“个人电脑的绝对路径”到共享仓库（除非公司固定路径）
# 更理想的是用环境变量（比如 $env(PDK_HOME)）

# 新项目必改：标准单元库/宏单元库按工艺库实际配置。
set target_library   $TARGET_LIB_LIST
set link_library     $LINK_LIB_LIST
#set synthetic_library [list standard.sldb]
#set symbol_library [list generic.sdb]

#Target_library 是什么（核心）
#综合映射用的标准单元库（.db）
#工具会把你的 RTL 变成这里面的门（NAND/FF/INV…）
#link_library 是什么（核心）
#用来“链接/解析”设计中引用到的所有单元/模块
#通常要包含
#标准单元库
#可能还有 RAM/PLL/IO 等 .db
#以及 *（表示先在当前设计/已读入设计里找）
#"*" 的意义非常重要：
#允许工具先用你当前读进来的 design 来解析引用
#不然层级引用容易报 unresolved reference
#模板常见写法：link_library 包含 "*" + 目标库列表 + IO 库。

#${lib_slow} 是什么？
#这也是一个外部定义变量（一般在 set_env.tcl 里），比如：
#set lib_slow "smic55_ss_1p2v_125c"
#最终变成 smic55_ss_1p2v_125c.db
#你要立刻建立的工程直觉
#综合通常用一个角（比如 slow/ss）做 timing 收敛
#后续 STA 会跑多角（ss/tt/ff + 电压温度）
#所以 lib_slow 不一定“永远正确”，但它是综合阶段最常见选择。

define_design_lib $WORK_LIB_NAME -path $WORK_LIB_PATH

#在干什么
#告诉 DC：WORK 这个 design library 存在，它的物理目录在哪里
#DC 会把很多中间结果（ddc、编译数据库等）放进去
#结合你前面那段：
#你已经设置了 cache_read/cache_write 指向 WORK/$file_version
#这里又把 WORK 的 path 指向同一个版本目录
#👉 这就是**“一次综合 run 的隔离目录”**机制：
#每次跑一个版本号 → 生成独立的 WORK 目录
#不会和别的版本混起来
#你该怎么对待它
#✅ 这是非常好的工程习惯
#✅ 你一般只需要保证：
#./WORK/$file_version 目录存在（file_create.tcl 大概率会创建）
#file_version 的命名规则稳定、可追溯

##################################################################
## Read in Verilog Files    ##
##################################################################
# read_sverilog  ./$RTL_FILE/ram_dual.v
# read_sverilog  ./$RTL_FILE/fifo_512x10_async.v
# current_design $working_design
# link

# analyze RTL（VCS 兼容模式，所有参数塞进 -vcs 单字符串）。
# 展开后实际命令：
#   analyze -format sverilog -vcs "+define+SOC_ENABLE_E203_VENDOR +incdir+../rtl/vendor_e203/e203/core -f ./flist.f"
analyze -format $ANALYZE_FORMAT -vcs $VCS_OPTIONS

#“分析（parse）RTL 源码，但还不生成实例”
#analyze：
#👉 只做 语法分析 + 生成中间表示
#不会：
#建立层级实例
#连接模块
#做综合
#-format sverilog
#输入是 SystemVerilog
#如果你写的是 logic / always_ff / interface 等，必须用这个
#-vcs "-f flist.f"
#这是很多人第一次会懵的点。
#-vcs：
#👉 告诉 DC：按 VCS 的解析规则来吃参数
#"-f flist.f"：
#👉 和 VCS 一样，从 flist.f 里读 RTL 文件列表

elaborate $working_design

#elaborate 做了什么？
#实例化 top
#递归实例化所有 submodule
#解析 parameter
#生成 design hierarchy tree
#👉 到这里，设计“结构”才真正出现。

report_attributes -design

#这是个“检查点”，不是流程必须
#作用：
#打印当前 design 的属性
#看：
#设计名
#是否 elaborated
#当前状态
#典型用途：
#调试脚本
#确认 elaborate 成功
#防止后面在“空 design”上操作

current_design $working_design

#显式告诉工具：
#“接下来所有操作，都是针对这个 design（top）”

link
#link 在干什么？
#检查是否有：
#未定义模块
#未找到的 cell
#把：
#RTL 实例
#标准单元（.db）
#宏单元
#连接成一个 完整可综合网络

#1️⃣ analyze 只读代码，不生成设计
#2️⃣ elaborate 之后，design 才“存在”
#3️⃣ link 是 compile 之前的最后一道关卡


source -echo ./$SCRIPT_FILE/$SET_PARAMETER_FILE

source -echo ./$SCRIPT_FILE/$CONSTRAINT_FILE
source -echo ./$SCRIPT_FILE/$DONT_TOUCH_FILE

#1️⃣ set_parameter.tcl
#作用：确定 RTL 的参数配置
#决定结构 / 位宽 / generate 分支
#属于结构定义，不是优化
#必须在 compile 前
#记忆点：“参数定结构”

#2️⃣ constraint_sdc.tcl
#作用：加载 SDC 时序/接口约束
#create_clock / set_input_delay / set_false_path ...
#告诉综合“跑多快才算好”
#没 SDC 的综合 ≈ 无意义
#记忆点：“约束定目标”

#3️⃣ dont_touch.tcl
#作用：禁止综合改动某些对象
#RAM / PLL / CDC / 时钟网络等
#防止被拆、被优化、被重构
#必须在 compile 前生效
#记忆点：“dont_touch 画红线”
#change naming rule

report_clock > $RPT_CLOCK_PATH
report_clock -skew >> $RPT_CLOCK_PATH

#report_clock
#作用：报告当前设计里的所有时钟信息
#时钟名、周期、来源、是否 propagated
#用来确认 SDC 是否生效
#-skew
#作用：报告时钟偏斜（clock skew）
#综合阶段是估算值
#用来提前发现潜在 CTS 风险
#> / >>
#> ：新建/覆盖文件
#>> ：追加内容到同一报告

current_design $working_design

uniquify -force

#uniquify
#作用：
#把多个实例共享的同一个 module，拆成各自独立的副本
#为什么要做？
#防止不同实例在综合/优化时互相影响
#为后续：
#不同实例独立优化
#ECO
#dont_touch 局部实例
#做准备
#-force
#强制 uniquify（即使工具觉得“没必要”）
#记忆点：“uniquify = 实例级独立，防串扰”

##################################################################
## Optimization
##################################################################

change_names -rules verilog -hierarchy

#1️⃣ 它到底在改什么？
#综合工具内部允许很多**“非法 Verilog 名字”**存在，例如：
#名字里有 /
#有 [ ]
#以数字开头
#含特殊字符
#工具内部 OK，但：
#写 verilog 网表会炸
#后端工具（ICC/Innovus）会炸
#形式验证会炸
#change_names -rules verilog 的作用就是：
#把所有对象名，强制转换成“100% 合法 Verilog 名字”
#2️⃣ -hierarchy 是关键
#表示：
#整个层级递归生效
#module / cell / net / pin 全部处理
#不加的话，只会改当前层，极其危险。
#3️⃣ 为什么要在 compile 前跑一次？
#原因不是“强制要求”，而是防御性工程习惯：
#parameter / generate 可能生成奇怪名字
#RTL 作者可能写了边缘命名
#提前清洗一遍，避免 compile 中途报怪错
#👉 这是在给综合“扫雷”

do_compile > $RPT_COMPILE_PATH
do_compile_inc > $RPT_COMPILE_INC_PATH
do_compile_inc > $RPT_COMPILE_INC2_PATH

#inc = incremental = 增量综合，不推翻结构，只微调 QoR
#如果你后面看到：
#-inc
#incremental
#compile_inc
#全部等价于：在已有解上修修补补。

#为什么不是只跑一次？
#这是一个非常工程化、但新手看不懂的点。
#原因有 3 个：
#原因 A：inc 是“局部搜索”
#一次 inc 不一定到最优
#第二次可能还能改善
#原因 B：QoR 是否收敛？
#第一次 inc 改了
#第二次 inc 如果：
#基本不变 → 说明结果稳定
#还在大幅变化 → 设计/约束可能有问题
#原因 C：防止“假改善”
#有时：
#第一次 inc 好看
#第二次 inc 反而变差
#这说明：
#你的综合解不稳定

#3️⃣ 工程经验判断
#inc1 改善，inc2 几乎不变
#→ 好设计，好 QoR
#inc1/2 来回波动
#→ RTL / SDC / dont_touch 有问题

change_names -rules verilog -hierarchy
current_design $working_design

#为什么还要写？

#因为：

#compile / inc / change_names
#都有可能改变 current_design 指向

##########################################

check_design  > $RPT_CHECK_DESIGN_PATH
check_timing  > $RPT_CHECK_TIMING_PATH

#1️⃣ check_design
#检查：设计结构是否健康
#未连接端口
#悬空 net
#unresolved reference
#dont_touch 冲突等
#工程意义
#✅ 必须基本 clean
#❌ 如果这里报一堆 warning/error，后面所有 report 都不可信
#这是“设计有没有病”的体检。

#2️⃣ check_timing
#检查：时序约束是否完整、合理
#有没有 clock
#clock 是否被用到
#是否存在 unconstrained path
#工程意义
#❌ 出现大量 unconstrained = SDC 有严重问题
#❌ 没 clock = 后面 timing report 没意义
#这是“你给的 SDC 像不像人话”。

report_qor > $RPT_QOR_PATH
#report_qor
#一页看清综合结果的核心指标
#WNS / TNS
#Area
#Power
#Violating paths 数量
#工程用法
#用来：
#比版本
#比 compile / inc
#是第一个该看的报告
#这是“综合成绩单总览”。

report_area > $RPT_AREA_PATH
report_area -hierarchy > $RPT_AREA_HIER_PATH

#1️⃣ report_area
#总面积
#cell 数
#不分层级
#2️⃣ report_area -hierarchy
#按模块分解面积
#看谁是“面积大户”
#工程意义
#找 bloated 模块
#判断架构是否合理
#后端、架构优化最常从这里下手。

report_timing   -loops > $RPT_TIMING_LOOP_PATH
report_timing -path full -net -cap -input -tran -delay min -max_paths $TIMING_MAX_PATHS -nworst $TIMING_NWORST > $RPT_TIMING_MIN_PATH
report_timing -path full -net -cap -input -tran -delay max -max_paths $TIMING_MAX_PATHS -nworst $TIMING_NWORST > $RPT_TIMING_MAX_PATH

#这两条是标准“深度 timing 报告”
#-delay max
#Setup timing
#看：WNS / TNS / critical path
#-delay min
#Hold timing
#看：min delay / 潜在 hold 风险
#关键选项含义
#-path full：完整路径
#-net -cap -tran：看电容、slew
#-nworst 200：每组最差 200 条
#-max_paths 200：总共最多 200 条
#工程意义
#这是你真正 debug timing 的地方
#QoR 好坏，最终体现在这里
#setup / hold 都要看，缺一不可。

report_constraints -all_violators -verbose > $RPT_CONSTRAINTS_PATH
report_power > $RPT_POWER_PATH

#工程定位
#只能做趋势判断
#不作为最终功耗结论
#真正功耗看：后端 + SAIF/VCD

#-loops
#检查 组合环路
#正常设计应为空
#❌ 有 loop：
#RTL 错
#或综合 bug
#或 dont_touch 用错

###################################################################
## Saving Hierarchy
###################################################################

set bus_naming_style $BUS_NAMING_STYLE

#行在干什么？
#规定“总线信号在导出 Verilog 网表时的命名格式”
#%s → 信号名
#%d → bit index
#结果示例：
#data[0], data[1], data[2]
#而不是：
#data_0, data_1
#为什么这行非常重要？
#因为 后端 / 仿真 / LEC / STA 工具对 bus 命名极其敏感：
#Verilog 标准写法：a[3]
#SDC / SDF / SAIF / VCD 默认都假设这种形式
#不统一 → 工具间对不上信号
#👉 这是“跨工具一致性设置”
#如果不设会怎样？
#工具可能用默认风格（如 a_3）
#后果：
#SDF 回标失败
#LEC 匹配不上
#STA 报 port 不存在
#这行属于：“不显眼，但踩过坑的人一定会写”

write_file -f verilog -hierarchy -output $OUTPUT_NETLIST_PATH
#在干什么？
#导出最终的门级 Verilog 网表
#-f verilog：格式是 Verilog
#-hierarchy：
#保留层级结构
#不 flatten
#为什么要 -hierarchy？
#SoC / 大设计：
#后端需要层级
#ECO / debug / CTS 需要层级
#没有它：
#网表被拍扁
#很难维护
#👉 默认正确选择
#这个文件用来干嘛？
#后端 P&R（ICC / Innovus）
#LEC（RTL ↔ gate）
#gate-level 仿真（+ SDF）
#这是最核心交付物。

write_sdf -version $SDF_VERSION $OUTPUT_SDF_PATH
#-version 2.1 是什么意思？
#SDF 的标准版本
#2.1 是兼容性最好的版本
#VCS / NC / Questa 都稳
#后端工具也支持

write_file -f ddc -hierarchy -output $OUTPUT_DDC_PATH
#.ddc 是什么？
#Synopsys 的设计数据库快照
#包含：
#完整 design#
#时序
#约束
#cell 绑定
#dont_touch 信息
#为什么要交付 .ddc？
#工程上非常重要：
#以后：
#ECO
#增量综合
#重跑 STA
#不用重新 analyze / elaborate RTL
#👉 .ddc = 综合阶段的“存档点”

write_sdc $OUTPUT_SDC_PATH

#exit
