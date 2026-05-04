# DC 脚本语法速查（仅覆盖本工程用到的语法/命令）

说明：本文件是速查，不是可执行脚本。所有示例均来自当前 DC 脚本的用法。

一、Tcl 基础语法
1) 变量赋值
   - 语法：set 变量名 值
   - 示例：set working_design fifo_512x10
   - 说明：变量引用用 $working_design

2) 字符串/列表/花括号
   - 双引号 ""：允许变量替换
   - 花括号 {}：原样保留，不做变量替换
   - list：把多个元素组装成 Tcl 列表
   - 示例：set search_path [list ./ ../ /path/to/lib]

3) 命令替换
   - 语法：[命令 ...]
   - 说明：先执行方括号里的命令，再把结果当作字符串使用
   - 示例：set_load [load_of ${lib_slow}/BUFHDV24/I] [all_outputs]

4) 条件判断
   - 语法：if {条件} { ... } else { ... }
   - 示例：if {$do_scan == 1} { ... } else { ... }

5) 字符串格式化
   - 语法：format "格式" 参数
   - 示例：set RPT_OUT [format "%s%s" $RPT_DIR/ $file_version]

6) 续行
   - 语法：反斜杠 \ 续到下一行
   - 示例：set search_path [list \ ./ \ ../ \ /path \ ]

二、文件/目录与日志
1) file exists
   - 语法：file exists 路径
   - 说明：判断路径是否存在，常用于 if 判断

2) exec
   - 语法：exec 命令 参数...
   - 说明：执行系统命令（例如 mkdir / rm）

3) echo
   - 语法：echo "文本"
   - 说明：打印到工具日志

4) source / source -echo
   - 语法：source 脚本.tcl
   - 说明：执行其他 Tcl 文件
   - source -echo：执行时把命令回显到日志，便于 debug

三、工程变量/路径常量（set_env.tcl）
1) 目录/版本
   - RTL_FILE：RTL 根目录或 flist 根路径
   - file_version：本次综合版本号/标签（用于输出与 WORK）
   - RPT_DIR / OUT_DIR：报告与输出根目录

2) 设计与库
   - working_design：顶层模块名
   - lib_slow / lib_fast：工艺库角点名

四、读 RTL / 建库 / 解析层级
1) define_design_lib
   - 语法：define_design_lib WORK -path ./WORK/$file_version
   - 说明：指定设计库 WORK 的物理目录

2) analyze
   - 语法：analyze -format sverilog -vcs "-f $RTL_FILE/flist.f"
   - -format sverilog：输入是 SystemVerilog
   - -vcs：按 VCS 兼容规则解析参数
   - -f filelist：从文件中读取 RTL 列表（filelist）

3) elaborate / current_design / link
   - elaborate：实例化顶层并生成层级结构
   - current_design：指定当前操作的设计
   - link：链接库与模块，解决引用关系

五、约束相关（constraint_sdc.tcl）
1) create_clock
   - 语法：create_clock -name CLK -p 10 [get_ports CLK]
   - -p 等价于 -period，单位一般是 ns
   - -waveform {0 5}：指定上升/下降沿时刻

2) set_clock_groups -asynchronous
   - 语法：set_clock_groups -asynchronous -group {CLK_A} -group {CLK_B}
   - 说明：定义异步时钟域，跨域路径不做 setup/hold

3) set_max_transition / set_clock_transition / set_input_transition
   - set_max_transition：限制信号最大转变时间
   - -clock_path：仅限制时钟路径

4) set_driving_cell / set_load / load_of
   - set_driving_cell -lib_cell BUFHDV24 [all_inputs]
   - set_load [load_of ${lib_slow}/BUFHDV24/I] [all_outputs]
   - load_of：读取某个库单元 pin 的输入电容作为负载

5) set_input_delay / set_output_delay
   - set_input_delay -max/-min：max 对 setup，min 对 hold
   - set_output_delay：输出到外部逻辑的时序预算
   - 语法示例：set_input_delay -max 5 -clock CLK {RD_EN}

6) set_false_path
   - 语法：set_false_path -from [get_ports RST]
   - 说明：标记该起点的路径不做时序检查

7) get_ports / all_inputs / all_outputs / all_clocks
   - get_ports：获取端口对象
   - all_inputs / all_outputs：获取全部输入/输出端口
   - all_clocks：获取所有时钟对象

六、综合变量与策略（set_parameter.tcl）
1) 变量 set ... true/false
   - 这些是 DC 的应用变量（App Vars），影响优化策略
   - 例：compile_enable_constant_propagation_with_no_boundary_opt
   - 例：timing_enable_multiple_clocks_per_reg
   - 例：enable_recovery_removal_arcs

2) 网表与 HDL 规则
   - write_name_nets_same_as_ports
   - compile_assume_fully_decoded_three_state_buses
   - compile_fix_multiple_port_nets
   - hdlin_* / verilogout_* 等为输入/输出规则

3) 扫描相关
   - insert_test_design_naming_style

七、综合流程与命令（top_syn.tcl）
1) CMP_OPTION / compile_ultra
   - -no_autoungroup：禁止自动拍扁层级
   - -scan：启用 scan 友好优化
   - compile_ultra -inc：增量综合
   - alias do_compile / do_compile_inc：简化命令调用

2) search_path
   - 语法：set search_path [list ./ ../ /path/to/lib]
   - 说明：影响读 RTL / 读库的搜索路径

3) target_library / link_library
   - target_library：综合映射的目标库
   - link_library：用于链接解析的库列表
   - "*" 表示先从当前设计中解析

4) uniquify -force
   - 说明：把共享模块拆成实例级独立副本，避免相互影响

5) change_names -rules verilog -hierarchy
   - 说明：把所有对象名转换成合法 Verilog 名字，层级递归生效

八、检查与报告
1) check_design / check_timing
   - 结构健康检查 / 约束完整性检查

2) report_clock / report_qor / report_area
   - report_clock -skew：报告时钟与偏斜
   - report_area -hierarchy：按层级统计面积

3) report_timing
   - -delay min/max：分别看 hold / setup
   - -path full：完整路径
   - -net -cap -input -tran：显示网表/电容/输入/转换信息
   - -max_paths / -nworst：限制报告条数
   - -loops：检查组合环路

4) report_constraints
   - -all_violators -verbose：列出所有违规并详细输出

5) report_power
   - 说明：综合阶段只做趋势参考

九、输出与保存
1) write_file
   - 语法：write_file -f verilog -hierarchy -output xxx.v
   - -f ddc：输出 Synopsys 数据库

2) write_sdf
   - 语法：write_sdf -version 2.1 xxx.sdf

3) write_sdc
   - 语法：write_sdc xxx.sdc

十、其他常用对象/模式
1) get_cells
   - 语法：get_cells 层级路径/通配
   - 示例：get_cells ram_dual/**
   - ** 表示递归匹配子层级

2) 通配符
   - 示例：DATA_RD* 匹配 DATA_RD[0]、DATA_RD0 等
