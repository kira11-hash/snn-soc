#==============================================================================
# scripts/program_zcu102_c0.tcl — xsct JTAG loader for Phase C0 board smoke.
#
# Invocation:
#   xsct scripts/program_zcu102_c0.tcl
#
# Requires:
#   - ZCU102 board powered on, JTAG USB cable connected
#   - hw_server / cs_server running (xsct auto-launches hw_server)
#   - ./fpga_synth/zcu102_arm_demo/zcu102_arm_demo.runs/impl_1/*.bit exists
#   - ./fw/arm/out/v2b_arm_demo.elf exists  (Phase B Gate output)
#
# Expected UART output (115200 8N1 on ZCU102 USB-UART port):
#   UART_OK
#   [TB] v2b_arm_demo start — 10 Fashion 14x14 samples via AXI-Lite
#   [TB] V2B_SOC_BASE=0xa0000000
#   [OK] MMIO round-trip CFG4
#   [TB] C0 loop (bypass encoder)
#   [PASS] sample 0 class=0 counts=[63 0 0 34 0 0 0 0 0 0]
#   ... (9 more [PASS] lines)
#   ARM_FPGA_DEMO_ACCEL_FASHION10_PASS
#   (C1 loop continues; for C0 gate, ACCEL_PASS is the target)
#==============================================================================

# ── Resolve workspace paths ─────────────────────────────────────────
set script_path [file normalize [info script]]
set script_dir  [file dirname $script_path]
set root_dir    [file dirname $script_dir]

# Bitstream: most recent .bit under the impl_1 run dir.
set bit_candidates [glob -nocomplain \
  "$root_dir/fpga_synth/zcu102_arm_demo/zcu102_arm_demo.runs/impl_1/*.bit"]
if {[llength $bit_candidates] == 0} {
  puts "[FATAL] no bitstream under fpga_synth/zcu102_arm_demo/.../impl_1/"
  puts "        Run scripts/build_zcu102_arm_demo.sh first."
  exit 1
}
set BIT [lindex $bit_candidates 0]
set ELF "$root_dir/fw/arm/out/v2b_arm_demo.elf"
if {![file exists $ELF]} {
  puts "[FATAL] missing ELF: $ELF"
  puts "        Run fw/arm/build_arm_firmware.sh first."
  exit 1
}

puts "[program_zcu102_c0] bitstream: $BIT"
puts "[program_zcu102_c0] elf:       $ELF"

# ── Connect to hw_server ────────────────────────────────────────────
connect
targets -set -filter {name =~ "PSU"}

# Stop all A53 cores, reset PL, download bitstream, then bring up core0.
puts "[program_zcu102_c0] halting all PSU cores + resetting PL"
foreach core {"Cortex-A53 #0" "Cortex-A53 #1" "Cortex-A53 #2" "Cortex-A53 #3"} {
  if {![catch {targets -set -filter "name =~ \"$core\""} err]} {
    catch {stop}
    after 50
  }
}
targets -set -filter {name =~ "PSU"}
rst -system
after 500

# Download bitstream to PL
puts "[program_zcu102_c0] programming PL bitstream"
fpga -file $BIT

# FSBL is normally needed to bring PS DDR up. Without a Vitis-generated
# FSBL project, we fall back to the ZCU102 "PSU init" script that Vivado
# exports alongside the XSA (psu_init.tcl). Assumption: xsct has already
# sourced it once per board session. If not, source it now:
set psu_init_glob [glob -nocomplain \
  "$root_dir/fpga_synth/zcu102_arm_demo/zcu102_arm_demo.srcs/sources_1/bd/v2b_arm_demo_bd/hw_handoff/psu_init.tcl"]
if {[llength $psu_init_glob] > 0} {
  set psu_init [lindex $psu_init_glob 0]
  puts "[program_zcu102_c0] sourcing psu_init.tcl for DDR/PS bring-up"
  source $psu_init
  targets -set -filter {name =~ "Cortex-A53 #0"}
  psu_init
  after 500
  psu_post_config
  after 500
  psu_ps_pl_isolation_removal
  after 500
  psu_ps_pl_reset_config
  after 500
}

# Download ELF to core 0 and run
targets -set -filter {name =~ "Cortex-A53 #0"}
stop
dow $ELF
puts "[program_zcu102_c0] ELF downloaded — releasing core 0"
con

puts ""
puts "=============================================="
puts "[program_zcu102_c0] CORE_0_RUNNING"
puts "=============================================="
puts "Open a terminal on the ZCU102 USB-UART port (115200 8N1) and watch"
puts "for: ARM_FPGA_DEMO_ACCEL_FASHION10_PASS"
puts ""
puts "(Leave this xsct session open so JTAG stays attached; Ctrl-C to disconnect.)"
