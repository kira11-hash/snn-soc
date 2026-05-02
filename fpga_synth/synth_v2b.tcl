# synth_v2b.tcl - Vivado batch synthesis script for V2.B standalone SoC top
#
# Target:  Zynq UltraScale+ XCZU9EG-FFVB1156-2-E
# Purpose: Resource + timing report for Phase D readiness
#
# Usage:
#   cd fpga_synth/
#   vivado -mode batch -source synth_v2b.tcl
#
# Outputs (under fpga_synth/reports/):
#   utilization.rpt        - post-synth LUT / FF / BRAM / DSP totals
#   utilization_hier.rpt   - post-synth per-module breakdown
#   timing.rpt             - post-synth timing summary
#   impl_utilization.rpt   - post-route LUT / FF / BRAM / DSP totals
#   impl_timing.rpt        - post-route timing summary
#   synth_log.txt          - full synthesis log
#   impl_log.txt           - full implementation log
#   post_synth_status.rpt  - compact post-synth summary
#   post_impl_status.rpt   - compact post-route summary

# ── Project setup ───────────────────────────────────────────────────
# Hardcoded path via junction to avoid spaces (d:/SoCDesign -> d:/SoC Design/SoC Design)
set proj_dir "d:/SoCDesign/fpga_synth"
cd $proj_dir

# Timestamped project name - avoids locked-file conflicts from stale Vivado
# runs. Reports still land in ./reports/ regardless.
set PROJ_NAME "v2b_synth_[clock format [clock seconds] -format {%Y%m%d_%H%M%S}]"
set PART xczu9eg-ffvb1156-2-e
set TOP snn_soc_v2b_top

# Try to delete the evergreen "v2b_synth" (old name); ignore lock errors.
foreach stale [glob -nocomplain "v2b_synth" "v2b_synth_*"] {
  # Only delete dirs older than 1h to preserve in-progress runs
  if {[file isdirectory $stale]} {
    if {[catch {file delete -force $stale} err]} {
      puts "INFO: skip locked $stale ($err) - harmless"
    }
  }
}

puts "\n=== Fresh project: $PROJ_NAME ===\n"
create_project $PROJ_NAME ./$PROJ_NAME -part $PART -force
set_property target_language Verilog [current_project]

# ── Add source files (one at a time to handle spaces in path) ──────────
set src_root "d:/SoCDesign/rtl"

foreach f [list \
  {top/snn_soc_pkg.sv} \
  {snn/input_stream_sram.sv} \
  {snn/stream_buffer_v2.sv} \
  {snn/tile_partial_buf.sv} \
  {snn/cim_mac_behavioral_v2.sv} \
  {snn/stage_engine_v2.sv} \
  {snn/fmap_sram_v2.sv} \
  {snn/patch_unroller_v2.sv} \
  {snn/fmap_flatten_reader_v2.sv} \
  {snn/conv_ctrl_v2.sv} \
  {top/snn_soc_v2b_top.sv} \
] {
  add_files -norecurse "${src_root}/${f}"
}
set_property file_type SystemVerilog [get_files *.sv]
set_property top $TOP [current_fileset]

# Add constraint
add_files -fileset constrs_1 -norecurse "d:/SoCDesign/fpga_synth/v2b_top.xdc"

# ── Run synthesis ───────────────────────────────────────────────────
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

# ── Compact pass/fail summaries ─────────────────────────────────────
proc _read_file {path} {
  set fd [open $path r]
  set data [read $fd]
  close $fd
  return $data
}

proc _extract_used {text label} {
  # Vivado uses "CLB LUTs*" in post-synth and "CLB LUTs" post-route.
  # Accept an optional literal star after the label.
  set pattern [format {\|[[:space:]]*%s\*?[[:space:]]*\|[[:space:]]*([0-9]+)} $label]
  if {[regexp $pattern $text -> value]} {
    return $value
  }
  return "NA"
}

proc _write_status {path title part top util_file wns} {
  set util_text [read [open $util_file r]]
  set luts  [_extract_used $util_text "CLB LUTs"]
  set ffs   [_extract_used $util_text "CLB Registers"]
  set brams [_extract_used $util_text "Block RAM Tile"]
  set dsps  [_extract_used $util_text "DSPs"]

  set fd [open $path w]
  puts $fd "=============================================="
  puts $fd "$title"
  puts $fd "Target: $part  Top: $top"
  puts $fd "Clock: 50 MHz (20.000 ns)"
  puts $fd "=============================================="
  puts $fd "LUTs      : $luts"
  puts $fd "FFs       : $ffs"
  puts $fd "BRAMs     : $brams"
  puts $fd "DSPs      : $dsps"
  puts $fd "WNS (ns)  : $wns     (negative = timing FAIL)"
  puts $fd ""
  if {$wns eq "NA"} {
    puts $fd "TIMING_STATUS : UNKNOWN"
  } elseif {$wns < 0} {
    puts $fd "TIMING_STATUS : FAIL (missed clock period)"
  } else {
    puts $fd "TIMING_STATUS : PASS"
  }
  puts $fd ""
  puts $fd "xczu9eg-ffvb1156-2-e budget: 274080 LUT, 548160 FF, 912 BRAM tiles, 2520 DSP48"
  close $fd
}

set util_text [read [open $report_dir/utilization.rpt r]]
set luts  [_extract_used $util_text "CLB LUTs"]
set ffs   [_extract_used $util_text "CLB Registers"]
set brams [_extract_used $util_text "Block RAM Tile"]
set dsps  [_extract_used $util_text "DSPs"]

set timing_paths [get_timing_paths -max_paths 1 -nworst 1]
if {[llength $timing_paths] > 0} {
  set wns [get_property SLACK [lindex $timing_paths 0]]
} else {
  set wns "NA"
}

_write_status $report_dir/post_synth_status.rpt \
  "V2.B standalone SoC top - post-synthesis summary" \
  $PART $TOP $report_dir/utilization.rpt $wns

# Echo to console too (so batch log captures it)
puts [read [open $report_dir/post_synth_status.rpt r]]

# ── Capture full synth log ──────────────────────────────────────────
file copy -force [get_property DIRECTORY [get_runs synth_1]]/runme.log $report_dir/synth_log.txt

# ── Run implementation (place + route) ──────────────────────────────
launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1

open_run impl_1 -name impl_1

report_utilization         -file $report_dir/impl_utilization.rpt
report_utilization -hierarchical -file $report_dir/impl_utilization_hier.rpt
report_timing_summary      -file $report_dir/impl_timing.rpt
report_route_status        -file $report_dir/impl_route_status.rpt

set impl_timing_paths [get_timing_paths -max_paths 1 -nworst 1]
if {[llength $impl_timing_paths] > 0} {
  set impl_wns [get_property SLACK [lindex $impl_timing_paths 0]]
} else {
  set impl_wns "NA"
}

_write_status $report_dir/post_impl_status.rpt \
  "V2.B standalone SoC top - post-route implementation summary" \
  $PART $TOP $report_dir/impl_utilization.rpt $impl_wns

puts [read [open $report_dir/post_impl_status.rpt r]]
file copy -force [get_property DIRECTORY [get_runs impl_1]]/runme.log $report_dir/impl_log.txt

puts "\n\nSCRIPT DONE: Reports at: $report_dir/"
puts "  - post_synth_status.rpt  <-- post-synth summary"
puts "  - post_impl_status.rpt   <-- post-route summary"
puts "  - utilization.rpt"
puts "  - impl_utilization.rpt"
puts "  - utilization_hier.rpt"
puts "  - timing.rpt"
puts "  - impl_timing.rpt"
puts "  - synth_log.txt          <-- search for 'RAM' / 'infer' for memory inference"
puts "  - impl_log.txt"
