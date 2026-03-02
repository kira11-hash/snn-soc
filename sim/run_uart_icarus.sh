#!/usr/bin/env bash
# sim/run_uart_icarus.sh
# UART TX 控制器 Icarus 轻量烟雾测试
#
# 用法（在 sim/ 目录下）：
#   bash run_uart_icarus.sh
#
# 通过标准：输出包含 UART_SMOKETEST_PASS
# 产出日志：sim/uart_sim.log

set -e
cd "$(dirname "$0")"

echo "[INFO] Compiling UART TX test (Icarus)..."
iverilog -g2012 -gno-assertions \
         -o uart_test \
         -f sim_uart.f \
         2>&1 | tee uart_compile.log

if [ ! -f uart_test ]; then
  echo "[ERROR] Compilation failed - check uart_compile.log"
  exit 1
fi
echo "[INFO] Compilation OK"

echo "[INFO] Running simulation..."
vvp uart_test 2>&1 | tee uart_sim.log

echo ""
if grep -q "UART_SMOKETEST_PASS" uart_sim.log; then
  echo "============================================"
  echo "[RESULT] UART_SMOKETEST_PASS"
  echo "============================================"
else
  echo "============================================"
  echo "[RESULT] UART_SMOKETEST_FAIL"
  echo "  → 查看 uart_sim.log 定位 [FAIL] 项"
  echo "============================================"
  exit 1
fi
