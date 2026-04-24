// sim/sim_v2_e203_bus_chain.f
// Phase A-4 chain TB: bridge + fabric + adapter + mock v2b_top
//
// 编译：iverilog -g2012 -gno-assertions -o v2e203_chain_test -f sim_v2_e203_bus_chain.f

../rtl/top/snn_soc_pkg.sv
../rtl/bus/icb2simple_bridge_v2b.sv
../rtl/bus/bus_interconnect_v2_e203.sv
../rtl/bus/simple2v2btop_adapter.sv
../tb/v2_e203_bus_chain_tb.sv
