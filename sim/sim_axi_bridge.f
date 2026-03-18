// sim/sim_axi_bridge.f
// AXI-Lite 桥接模块独立测试文件列表
//
// 用途：axi2simple_bridge + bus_interconnect 端到端验证
// 编译：iverilog -g2012 -gno-assertions -o axi_bridge_test -f sim_axi_bridge.f
// 运行：./axi_bridge_test 或 bash run_axi_bridge_icarus.sh
//
// 包含模块：
//   snn_soc_pkg    → 地址常量（ADDR_REG_BASE 等）
//   bus_interconnect → 地址译码路由
//   axi_lite_if    → 接口定义（仅供 VCS；Icarus 忽略 interface 内容但需语法通过）
//   axi2simple_bridge → DUT
//   axi_bridge_tb  → 测试顶层

// ── 包（必须最先编译）───────────────────────────────────────────────────────
../rtl/top/snn_soc_pkg.sv

// ── 总线 RTL ────────────────────────────────────────────────────────────────
../rtl/bus/bus_simple_if.sv
../rtl/bus/bus_interconnect.sv
../rtl/bus/axi_lite_if.sv
../rtl/bus/axi2simple_bridge.sv

// ── 测试顶层 ────────────────────────────────────────────────────────────────
../tb/axi_bridge_tb.sv
