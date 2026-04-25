#==============================================================================
# scripts/program_zcu102_c1.tcl — xsct JTAG loader for Phase C1 board smoke.
#
# IDENTICAL to program_zcu102_c0.tcl except: it expects a SEPARATE ELF built
# with a `-DC1_ONLY` define (or a different arm_main.c) if we ever split
# C0 and C1 into distinct binaries. As currently written, our single ELF
# runs BOTH loops back-to-back (C0 first, then C1), so this script is a
# convenience alias pointing at the same ELF. The expected UART PASS tag
# is `ARM_FPGA_DEMO_SCHEDULER_FASHION10_PASS` (appears AFTER the
# ARM_FPGA_DEMO_ACCEL_FASHION10_PASS line).
#
# Invocation:
#   xsct scripts/program_zcu102_c1.tcl
#==============================================================================

set script_path [file normalize [info script]]
set script_dir  [file dirname $script_path]
set root_dir    [file dirname $script_dir]
set manifest    "$root_dir/doc/arm-fpga-demo/build_manifest_v2.txt"
set psu_init_override ""
if {$argc >= 1} {
  set psu_init_override [file normalize [lindex $argv 0]]
}

set bit_candidates [glob -nocomplain \
  "$root_dir/fpga_synth/zcu102_arm_demo/zcu102_arm_demo.runs/impl_1/*.bit"]
if {[llength $bit_candidates] == 0} {
  puts "\[FATAL\] no bitstream — run scripts/build_zcu102_arm_demo.sh first"
  exit 1
}
set BIT [lindex $bit_candidates 0]

set ELF "$root_dir/fw/arm/out/v2b_arm_demo.elf"
if {![file exists $ELF]} {
  puts "\[FATAL\] missing ELF: $ELF"
  exit 1
}

puts "\[program_zcu102_c1\] bitstream: $BIT"
puts "\[program_zcu102_c1\] elf:       $ELF"

connect
targets -set -filter {name =~ "PSU"}
rst -system
after 500

fpga -file $BIT

if {$psu_init_override ne ""} {
  if {![file exists $psu_init_override]} {
    puts "\[FATAL\] explicit psu_init.tcl not found: $psu_init_override"
    exit 2
  }
  set psu_init $psu_init_override
} else {
  # See program_zcu102_c0.tcl for rationale: Vivado 2022.2 uses .gen/ path.
  set _candidates [list \
    "$root_dir/fpga_synth/zcu102_arm_demo/zcu102_arm_demo.gen/sources_1/bd/v2b_arm_demo_bd/ip/*zynq_ultra_ps_e*/psu_init.tcl" \
    "$root_dir/fpga_synth/zcu102_arm_demo/zcu102_arm_demo.srcs/sources_1/bd/v2b_arm_demo_bd/hw_handoff/psu_init.tcl" \
  ]
  set psu_init_glob [list]
  foreach _pat $_candidates {
    set _hits [glob -nocomplain $_pat]
    if {[llength $_hits] > 0} { set psu_init_glob $_hits; break }
  }
  if {[llength $psu_init_glob] == 0} {
    puts "\[FATAL\] psu_init.tcl not found under Vivado BD project."
    puts "        Re-run scripts/build_zcu102_arm_demo.sh and check the XSA/BD export."
    exit 2
  }
  set psu_init [lindex $psu_init_glob 0]
}
puts "\[program_zcu102_c1\] resolved psu_init.tcl: $psu_init"
if {[file exists $manifest]} {
  set _mf [open $manifest r]
  set _manifest_text [read $_mf]
  close $_mf
  if {[string first "Vivado version: Vivado v2022.2" $_manifest_text] < 0} {
    puts "\[WARN\] build manifest does not show locked Vivado v2022.2"
  }
} else {
  puts "\[WARN\] build manifest missing: $manifest"
}
source $psu_init

targets -set -filter {name =~ "PSU"}
after 200
psu_init
after 1000
psu_post_config
after 500
psu_ps_pl_isolation_removal
after 500
psu_ps_pl_reset_config
after 500

targets -set -filter {name =~ "Cortex-A53 #0"}
rst -processor -clear-registers
after 200
dow $ELF
con

puts ""
puts "=============================================="
puts "\[program_zcu102_c1\] CORE_0_RUNNING"
puts "=============================================="
puts "Watch UART for: ARM_FPGA_DEMO_SCHEDULER_FASHION10_PASS"
puts "(will appear AFTER the ACCEL_FASHION10_PASS line)"
puts "(Optional explicit psu_init override: xsct scripts/program_zcu102_c1.tcl /abs/path/to/psu_init.tcl)"
