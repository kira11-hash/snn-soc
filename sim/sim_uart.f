// sim/sim_uart.f
// UART TX 控制器独立测试文件列表
//
// 用途：uart_ctrl 独立端到端验证
// 编译：iverilog -g2012 -gno-assertions -o uart_test -f sim_uart.f
// 运行：./uart_test 或 bash run_uart_icarus.sh
//
// 包含模块：
//   uart_ctrl  → DUT（8N1 TX 控制器）
//   uart_tb    → 测试顶层

// ── RTL ─────────────────────────────────────────────────────────────────────
../rtl/periph/uart_ctrl.sv

// ── 测试顶层 ─────────────────────────────────────────────────────────────────
../tb/uart_tb.sv
