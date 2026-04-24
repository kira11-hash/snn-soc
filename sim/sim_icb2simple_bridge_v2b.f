// sim/sim_icb2simple_bridge_v2b.f
// icb2simple_bridge_v2b 单元 TB filelist
//
// 用途：Phase A-2 ICB→simple_bus bridge（V2B 白名单）
// 编译：iverilog -g2012 -gno-assertions -o icb_br_v2b_test -f sim_icb2simple_bridge_v2b.f

../rtl/top/snn_soc_pkg.sv
../rtl/bus/icb2simple_bridge_v2b.sv
../tb/icb2simple_bridge_v2b_tb.sv
