#!/usr/bin/env bash
# sim/run_boot_rom.sh
# Standalone smoke for rtl/mem/boot_rom.sv.
# Pass tag: BOOT_ROM_TB_PASS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

mkdir -p waves

# Pre-generate boot_rom init hex files — must exist before vvp
# starts so the DUT's initial-block $readmemh sees it at time 0.
cat > boot_rom_init_1.hex <<'EOF'
0BADC0DE
EOF

cat > boot_rom_init_2.hex <<'EOF'
11110000
22220000
EOF

cat > boot_rom_init_4.hex <<'EOF'
11110000
22220000
33330000
44440000
EOF

cat > boot_rom_init_8.hex <<'EOF'
DEADBEEF
CAFEBABE
00000013
00000001
11112222
33334444
55556666
77778888
EOF

# Build sim filelist
cat > sim_boot_rom.f <<'EOF'
../rtl/mem/boot_rom.sv
../tb/boot_rom_tb.sv
EOF

run_iverilog -g2012 -f sim_boot_rom.f -s boot_rom_tb -o boot_rom.out

run_vvp boot_rom.out | tee boot_rom_sim.log

if grep -q "BOOT_ROM_TB_PASS" boot_rom_sim.log; then
    echo ""
    echo "============================================"
    echo "[RESULT] BOOT_ROM_TB_PASS"
    echo "============================================"
    exit 0
else
    echo ""
    echo "============================================"
    echo "[RESULT] BOOT_ROM_TB_FAIL"
    echo "============================================"
    exit 1
fi
