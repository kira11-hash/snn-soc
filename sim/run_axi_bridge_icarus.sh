#!/usr/bin/env bash
# sim/run_axi_bridge_icarus.sh
# AXI-Lite 桥接模块 Icarus 轻量烟雾测试
#
# 用法（在 sim/ 目录下）：
#   bash run_axi_bridge_icarus.sh
#
# 通过标准：输出包含 AXI_BRIDGE_SMOKETEST_PASS
# 产出日志：sim/axi_bridge_sim.log

set -e
cd "$(dirname "$0")"

echo "[INFO] Compiling AXI-Lite bridge test (Icarus)..."
iverilog -g2012 -gno-assertions \
         -o axi_bridge_test \
         -f sim_axi_bridge.f \
         2>&1 | tee axi_bridge_compile.log

if [ ! -f axi_bridge_test ]; then
  echo "[ERROR] Compilation failed - check axi_bridge_compile.log"
  exit 1
fi
echo "[INFO] Compilation OK"

echo "[INFO] Running simulation..."
vvp axi_bridge_test 2>&1 | tee axi_bridge_sim.log

echo ""
if grep -q "AXI_BRIDGE_SMOKETEST_PASS" axi_bridge_sim.log; then
  echo "============================================"
  echo "[RESULT] AXI_BRIDGE_SMOKETEST_PASS"
  echo "============================================"
else
  echo "============================================"
  echo "[RESULT] AXI_BRIDGE_SMOKETEST_FAIL"
  echo "  → 查看 axi_bridge_sim.log 定位 [FAIL] 项"
  echo "============================================"
  exit 1
fi
