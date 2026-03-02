#!/usr/bin/env bash
# sim/run_spi_icarus.sh
# Build and run SPI unit smoke test with Icarus.

set -e
cd "$(dirname "$0")"

echo "[INFO] Compiling SPI test (Icarus)..."
iverilog -g2012 -gno-assertions \
         -o spi_test \
         -f sim_spi.f \
         2>&1 | tee spi_compile.log

if [ ! -f spi_test ]; then
  echo "[ERROR] Compilation failed - check spi_compile.log"
  exit 1
fi

echo "[INFO] Running simulation..."
vvp spi_test 2>&1 | tee spi_sim.log

echo ""
if grep -q "SPI_SMOKETEST_PASS" spi_sim.log; then
  echo "============================================"
  echo "[RESULT] SPI_SMOKETEST_PASS"
  echo "============================================"
else
  echo "============================================"
  echo "[RESULT] SPI_SMOKETEST_FAIL"
  echo "  -> check sim/spi_sim.log for [FAIL] lines"
  echo "============================================"
  exit 1
fi

