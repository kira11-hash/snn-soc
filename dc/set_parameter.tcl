# ============================================================
# 可配置参数（本文件易变项集中在这里）
# ============================================================
# 让与端口相连的 net 名称尽量和端口一致，便于 LEC/调试/报告阅读。
# 若团队有固定命名规则或不希望改网名，可设为 false。
set CFG_WRITE_NAME_NETS_SAME_AS_PORTS        true
# 三态总线是否假设“任意时刻只有一个驱动使能”（fully decoded）。
# 有明确互斥控制可设 true；不确定或可能多驱动同时有效则设 false 更保守。
set CFG_ASSUME_FULLY_DECODED_THREE_STATE     true
# 多端口/多驱动网络修复开关（插 buffer/拆网等）。
# 一般建议开启，能避免下游多驱动报错。
set CFG_COMPILE_FIX_MULTIPLE_PORT_NETS       true
# 异步复位 recovery/removal 检查开关。
# 异步复位设计建议开启；全同步复位可关闭以简化检查。
set CFG_ENABLE_RECOVERY_REMOVAL_ARCS         true

# HDL 规则：是否检查潜在 latch（建议开启，避免意外锁存器）。
set CFG_HDLIN_CHECK_NO_LATCH                 true
# HDL 规则：是否抑制警告（一般不建议抑制，便于发现问题）。
set CFG_HDLIN_SUPPRESS_WARNINGS              false
# HDL 规则：将 always 块推断为同步 set/reset（配合同步复位设计）。
set CFG_HDLIN_FF_ALWAYS_SYNC_SET_RESET       true
# HDL 规则：MUX 推断策略（default 通常即可，除非有特定风格要求）。
set CFG_HDLIN_INFER_MUX                      default
# HDL 规则：信号名保留策略（all_driving 可提升可读性/可追溯性）。
set CFG_HDLIN_KEEP_SIGNAL_NAME               all_driving
# 顺序映射特殊策略开关（通常保持 false 以获得更可控结果）。
set CFG_HDLIN_ON_SEQUENTIAL_MAPPING          false

# 网表输出：是否显示未连接引脚（调试时有用，建议 true）。
set CFG_VERILOGOUT_SHOW_UNCONNECTED_PINS     true
# 网表输出：是否禁止 tri（三态）网型（下游工具兼容性更好）。
set CFG_VERILOGOUT_NO_TRI                    true
# 网表输出：单比特总线是否保持单比特形式（false = 保持总线语义）。
set CFG_VERILOGOUT_SINGLE_BIT                false
# 网表输出：是否输出布尔方程形式（一般 false，保持结构化网表）。
set CFG_VERILOGOUT_EQUATION                  false

# Scan 相关命名风格（如无扫描可保持默认）。
set CFG_INSERT_TEST_DESIGN_NAMING_STYLE      "%s_%d"

##################################################################
## Compile variable##
##################################################################
# 新项目一般无需改本文件；若设计含三态总线/复位策略不同/网表输出规则不同，请按下方标注调整。
set write_name_nets_same_as_ports $CFG_WRITE_NAME_NETS_SAME_AS_PORTS

#作用：让与端口相连的 net 名字尽量和 port 一致（例如 port=DATA，内部连线也叫 DATA）。
#好处：更好 debug、LEC/STA 更容易对齐、报告更可读。
#风险：很小，通常建议开。

# 新项目按需改：若没有三态总线可保持；若三态控制不互斥请改为 false。
set compile_assume_fully_decoded_three_state_buses $CFG_ASSUME_FULLY_DECODED_THREE_STATE

#作用：对三态总线（多个驱动通过三态合一根总线）假设“任意时刻只有一个驱动被使能”（fully decoded）。
#好处：工具可以做更激进优化/避免把三态当成多驱动灾难。
#风险：如果你的三态控制不是互斥的，这个假设会让工具“乐观”，可能掩盖真实冲突。

#工程建议：
#SoC 顶层 IO 总线可能用得到
#普通 FIFO/同步逻辑一般无三态，这个开着也无害
#set verilogout_no_tri true
#作用：输出网表时不使用 tri/三态网类型，尽量转成普通 wire + 逻辑等效形式。
#好处：提升下游工具兼容性（不少 flow 不喜欢 tri）。
#set compile_no_new_cells_at_top_level false
#作用：是否禁止在 top level 插入新 cell（buffer/inverter 等）。
#这里是 false → 允许工具在顶层插入新单元。
#工程含义：更容易修时序/修 transition；如果设为 true，可能限制 QoR。
#什么时候会设 true：一些极严格的封装接口/顶层固定结构项目。
#set compile_preserve_sync_resets true
#作用：尽量保持同步复位结构，不把它“逻辑化/优化掉”。
#好处：DFT/形式验证/调试更稳；复位结构不被重写得面目全非。
#坑：如果你复位是“常量可推”，开这个会减少优化（但通常值得）。

## Remove assign statements when generating gate level netlist 

set compile_fix_multiple_port_nets $CFG_COMPILE_FIX_MULTIPLE_PORT_NETS

#作用：综合/输出网表时，修复“一个 net 连到多个 module port 导致的多驱动/多端口问题”，常见处理方式是插 buffer、拆网等。
#注释里写了“Remove assign statements …”，实际效果之一确实是减少奇怪的 assign/多驱动结构。
#工程意义：让 gate-level 网表更“干净”、下游更不容易报 multi-driver。
# for async reset timing check

# 新项目按需改：是否启用异步复位 recovery/removal 检查，按复位类型决定。
set enable_recovery_removal_arcs $CFG_ENABLE_RECOVERY_REMOVAL_ARCS

#作用：启用异步复位的 recovery/removal timing check。
#配套：如果你后面又把 RST 全 false path，可能把一部分意义抵消（需你按设计意图取舍）。
#set_fix_multiple_port_nets -all -buffer_constants
#这是命令（不是变量），会对当前设计执行处理。
#-all：对所有多端口/多驱动相关网络处理
#-buffer_constants：常量网（tie0/tie1）也会插 buffer/隔离，避免常量扇出过大、也避免某些工具把常量网搞得很怪
#set_fix_multiple_port_nets -all

#/******************************************************************
#****                         HDL RULES                          ***
#*******************************************************************/
set hdlin_check_no_latch                        $CFG_HDLIN_CHECK_NO_LATCH
set hdlin_suppress_warnings                     $CFG_HDLIN_SUPPRESS_WARNINGS
set hdlin_ff_always_sync_set_reset              $CFG_HDLIN_FF_ALWAYS_SYNC_SET_RESET
set hdlin_infer_mux                             $CFG_HDLIN_INFER_MUX

set hdlin_keep_signal_name                      $CFG_HDLIN_KEEP_SIGNAL_NAME
set hdlin_on_sequential_mapping                 $CFG_HDLIN_ON_SEQUENTIAL_MAPPING

#作用：不启用某种“顺序映射时的特殊行为”（偏工具内部策略）。一般模板这么设是为了结果可控。

#set compile_delete_unloaded_sequential_cells    true
#set hdlin_preserve_sequential                   none

#作用：没被用到（Q 不扇出）的寄存器会被删掉。
#好处：清理无用逻辑。
#坑：如果你有“为了测试/观测而保留”的寄存器，这会删掉；那就需要 dont_touch

#/******************************************************************
#****         VERILOG RULES: VERILOG OUT                        **** 
#*******************************************************************/
set verilogout_show_unconnected_pins            $CFG_VERILOGOUT_SHOW_UNCONNECTED_PINS
set verilogout_no_tri                           $CFG_VERILOGOUT_NO_TRI
set verilogout_single_bit                       $CFG_VERILOGOUT_SINGLE_BIT
set verilogout_equation                         $CFG_VERILOGOUT_EQUATION

#/******

#/******************************************************************
#****                    Scan Options                           ***
#*******************************************************************/
set insert_test_design_naming_style             $CFG_INSERT_TEST_DESIGN_NAMING_STYLE
#set test_scan_in_port_naming_style              "SI%s%s"
#set test_scan_enable_port_naming_style          "SCN%s"
#set test_scan_out_port_naming_style             "SO%s%s"


