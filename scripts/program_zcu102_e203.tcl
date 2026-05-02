# scripts/program_zcu102_e203.tcl
# xsct script: program ZCU102 with E203 FPGA bitstream.
# E203 self-starts from BRAM on power-on — no ELF download needed.
#
# Usage:
#   xsct scripts/program_zcu102_e203.tcl [bitstream_path]
#
# Default bitstream path:
#   fpga_synth/zcu102_e203_demo/out/snn_soc_fpga_top.bit
#
# After programming: open the on-board CP2108 UART on J83.
#   CP2108 Interface 2 / COM3 = PL-side E203 console (115200 8N1).
# Open PuTTY / minicom / fpga_bringup_capture.sh and watch for:
#   FPGA_E203_BOOT_UART_PASS
#   FPGA_E203_PROGRAM_ERASE_WRITE_PASS
#   FPGA_E203_PROGRAMMED_INFERENCE_PASS

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]

# Default bitstream path
if {[llength $argv] >= 1} {
    set bitfile [lindex $argv 0]
} else {
    set bitfile [file join $repo_root fpga_synth zcu102_e203_demo out snn_soc_fpga_top.bit]
}

if {![file exists $bitfile]} {
    puts "ERROR: bitstream not found: $bitfile"
    puts "Run: bash fpga_synth/zcu102_e203_demo/build_e203_demo.sh first"
    exit 1
}

puts "=== E203 FPGA Board Bring-up ==="
puts "Bitstream : $bitfile"

# Connect to hardware server
connect

# Open ZCU102 target (xczu9eg)
set targets [targets]
puts "Available targets:"
puts $targets

# Select the FPGA PL target (xczu9eg)
targets -set -filter {name =~ "*xczu9eg*" || name =~ "*PL*"}

# Program PL bitstream
puts "Programming PL with bitstream..."
fpga $bitfile

puts ""
puts "=== Bitstream programmed successfully ==="
puts ""
puts "E203 RISC-V soft-core starts automatically from BRAM."
puts ""
puts "Open the on-board CP2108 UART on J83:"
puts "  Interface 2 / COM3 = PL-side E203 console"
puts "  Settings: 115200 8N1, no flow control"
puts ""
puts "Open serial terminal at 115200 8N1 and watch for:"
puts "  FPGA_E203_BOOT_UART_PASS"
puts "  FPGA_E203_PROGRAM_ERASE_WRITE_PASS"
puts "  FPGA_E203_PROGRAMMED_INFERENCE_PASS"
puts ""

disconnect
exit 0
