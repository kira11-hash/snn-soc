// sim/sim_bus_interconnect_v2_e203.f
// bus_interconnect_v2_e203 单元 TB filelist
//
// 用途：Phase A-1 fabric 单元验证（4 slave + V2B wait-state）
// 编译：iverilog -g2012 -gno-assertions -o bus_ic_v2e203_test -f sim_bus_interconnect_v2_e203.f
// 运行：./bus_ic_v2e203_test 或 bash run_bus_interconnect_v2_e203.sh

// ── package（最先编译）──
../rtl/top/snn_soc_pkg.sv

// ── DUT ──
../rtl/bus/bus_interconnect_v2_e203.sv

// ── testbench ──
../tb/bus_interconnect_v2_e203_tb.sv
