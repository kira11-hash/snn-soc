# scripts/program_zcu102_v2_e203.tcl
# XSCT helper: program ZCU102 PL with V2E203 bitstream.
#
# Usage:
#   xsct scripts/program_zcu102_v2_e203.tcl [bitstream_path]
#
# Default:
#   fpga_synth/zcu102_v2_e203_demo/out/snn_soc_v2b_e203_fpga_top.bit

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]

if {[llength $argv] >= 1} {
    set bitfile [lindex $argv 0]
} else {
    set bitfile [file join $repo_root fpga_synth zcu102_v2_e203_demo out snn_soc_v2b_e203_fpga_top.bit]
}

if {![file exists $bitfile]} {
    puts "ERROR: bitstream not found: $bitfile"
    puts "Run: bash fpga_synth/zcu102_v2_e203_demo/build_v2_e203_demo.sh"
    exit 1
}

puts "=== V2E203 FPGA Board Bring-up ==="
puts "Bitstream : $bitfile"

connect

puts "Available targets:"
puts [targets]

targets -set -filter {name =~ "*xczu9eg*" || name =~ "*PL*"}

puts "Programming PL..."
fpga $bitfile

puts ""
puts "=== Bitstream programmed successfully ==="
puts ""
puts "The E203 soft-core starts automatically from IMEM BRAM."
puts "Open ZCU102 J83 CP2108 Interface 2 at 115200 8N1 and watch for:"
puts "  FPGA_V2_E203_BOOT_UART_PASS"
puts {  [PASS] sample 00 ...}
puts {  ...}
puts {  [PASS] sample 09 ...}
puts "  FPGA_V2_E203_LENET5_PASS"
puts ""

disconnect
exit 0
