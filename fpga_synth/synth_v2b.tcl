# synth_v2b.tcl — Vivado batch synthesis script for V2.B standalone SoC top
#
# Target:  Artix-7 XC7A100T-CSG324-1 (most common WebPack device; easy swap to Zynq)
# Purpose: First-pass resource + timing report for Phase D readiness
#
# Usage:
#   cd fpga_synth/
#   vivado -mode batch -source synth_v2b.tcl
#
# Outputs (under fpga_synth/reports/):
#   utilization.rpt        — LUT / FF / BRAM / DSP totals
#   utilization_hier.rpt   — per-module breakdown
#   timing.rpt             — worst negative slack + critical path
#   synth_log.txt          — full synthesis log (RAM inference warnings etc)
#   post_synth_status.rpt  — one-line "PASS/FAIL + numbers" summary

# ── Project setup ───────────────────────────────────────────────────
set proj_dir [file dirname [file normalize [info script]]]
cd $proj_dir

set PROJ_NAME v2b_synth
set PART xc7a100tcsg324-1
set TOP snn_soc_v2b_top

# Clean previous run
if {[file isdirectory $PROJ_NAME]} {
  file delete -force $PROJ_NAME
}

create_project $PROJ_NAME ./$PROJ_NAME -part $PART -force
set_property target_language Verilog [current_project]

# ── Add source files (relative to $proj_dir = fpga_synth/) ──────────
set src_root "../rtl"
add_files -norecurse [list \
  $src_root/top/snn_soc_pkg.sv \
  $src_root/snn/input_stream_sram.sv \
  $src_root/snn/stream_buffer_v2.sv \
  $src_root/snn/tile_partial_buf.sv \
  $src_root/snn/cim_mac_behavioral_v2.sv \
  $src_root/snn/stage_engine_v2.sv \
  $src_root/top/snn_soc_v2b_top.sv \
]
set_property file_type SystemVerilog [get_files -filter {FILE_TYPE == Verilog}]
set_property top $TOP [current_fileset]

# Add constraint
add_files -fileset constrs_1 -norecurse ./v2b_top.xdc

# ── Run synthesis only (no P&R) ─────────────────────────────────────
# reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1

# ── Open the synthesised design for reporting ───────────────────────
open_run synth_1 -name synth_1

# ── Dump reports ────────────────────────────────────────────────────
set report_dir "./reports"
file mkdir $report_dir

report_utilization         -file $report_dir/utilization.rpt
report_utilization -hierarchical -file $report_dir/utilization_hier.rpt
report_timing_summary      -file $report_dir/timing.rpt
report_ram_utilization     -file $report_dir/ram_utilization.rpt
report_clock_utilization   -file $report_dir/clock_utilization.rpt

# ── One-line pass/fail summary (easy to paste back to Claude) ───────
set wns [get_property STATS.WNS [get_runs synth_1]]
set luts [get_property STATS.LUT [get_runs synth_1]]
set ffs  [get_property STATS.FF  [get_runs synth_1]]
set brams [get_property STATS.BRAMS [get_runs synth_1]]
set dsps [get_property STATS.DSP [get_runs synth_1]]

set fd [open $report_dir/post_synth_status.rpt w]
puts $fd "=============================================="
puts $fd "V2.B standalone SoC top — synthesis summary"
puts $fd "Target: $PART  Top: $TOP"
puts $fd "=============================================="
puts $fd "LUTs      : $luts"
puts $fd "FFs       : $ffs"
puts $fd "BRAMs     : $brams"
puts $fd "DSPs      : $dsps"
puts $fd "WNS (ns)  : $wns     (negative = timing FAIL)"
puts $fd ""
if {$wns < 0} {
  puts $fd "TIMING_STATUS : FAIL (missed clock period)"
} else {
  puts $fd "TIMING_STATUS : PASS"
}
puts $fd ""
puts $fd "Artix-7 XC7A100T budget: 63400 LUT, 126800 FF, 270 BRAM18, 240 DSP48"
close $fd

# Echo to console too (so batch log captures it)
puts [read [open $report_dir/post_synth_status.rpt r]]

# ── Capture full synth log ──────────────────────────────────────────
file copy -force [get_property DIRECTORY [get_runs synth_1]]/runme.log $report_dir/synth_log.txt

puts "\n\n[SCRIPT DONE] Reports at: $report_dir/"
puts "  - post_synth_status.rpt  <-- one-line summary, paste this back first"
puts "  - utilization.rpt"
puts "  - utilization_hier.rpt"
puts "  - timing.rpt"
puts "  - synth_log.txt          <-- search for 'RAM' / 'infer' for memory inference"
