#==============================================================================
# fpga_synth/ooc_v2b_arm_demo.tcl — OOC synthesis sanity for v2b_arm_demo_top.
#
# Purpose (Phase C0, local sanity):
#   Synthesize `rtl/top/v2b_arm_demo_top.sv` + dependency tree out-of-context
#   on the ZCU102 part. Catches coding errors / unresolved references BEFORE
#   committing to the full Block Design + bitgen flow (which takes ~30 min).
#   No BD, no bitstream, no board dependencies.
#
# Invocation:
#   cd d:/SoC Design/audit-v2/fpga_synth
#   vivado -mode batch -source ooc_v2b_arm_demo.tcl -log ooc.log -journal ooc.jou
#
# Success = `post_synth_status.rpt` has `TIMING_STATUS : PASS` OR `UNKNOWN`
# (UNKNOWN when OOC has no constraints — that's fine; timing signed off in BD).
#
# This TCL is adapted from `fpga_synth/synth_v2b.tcl`; key differences:
#   - TOP = v2b_arm_demo_top (wraps v2b_axi_wrapper which wraps v2b_top)
#   - Adds axi2simple_bridge + simple2v2btop_adapter + v2b_axi_wrapper to src set
#   - Does NOT run implementation (placement/route) — synth-only.
#==============================================================================

# ── Project setup ───────────────────────────────────────────────────
# Detect workspace root. Vivado on Windows cannot tolerate paths that
# contain spaces, so the invoking shell passes the DOS 8.3 short form
# via -tclargs (see scripts/build_zcu102_arm_demo.sh or ooc runner).
# Layout:  $root_dir = audit-v2 tree root (DOS 8.3 when path has spaces)
#          $proj_dir = $root_dir/fpga_synth
if {$argc >= 1} {
  set root_dir [lindex $argv 0]
} else {
  set this_file [file normalize [info script]]
  set root_dir [file dirname [file dirname $this_file]]
}
set proj_dir "${root_dir}/fpga_synth"
cd $proj_dir

set PROJ_NAME "v2b_arm_demo_ooc_[clock format [clock seconds] -format {%Y%m%d_%H%M%S}]"
set PART xczu9eg-ffvb1156-2-e
set TOP v2b_arm_demo_top

# Cleanup stale project dirs (non-critical; ignore locks).
foreach stale [glob -nocomplain "v2b_arm_demo_ooc_*"] {
  if {[file isdirectory $stale]} {
    catch {file delete -force $stale}
  }
}

puts "\n=== OOC synth project: $PROJ_NAME ==="
puts "=== TOP: $TOP  PART: $PART ===\n"

create_project $PROJ_NAME ./$PROJ_NAME -part $PART -force
set_property target_language Verilog [current_project]

# ── Add source files (bottom-up: pkg → snn core → wrappers → top) ────
set src_root "${root_dir}/rtl"
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
  {bus/axi2simple_bridge.sv} \
  {bus/simple2v2btop_adapter.sv} \
  {top/v2b_axi_wrapper.sv} \
  {top/v2b_arm_demo_top.sv} \
] {
  add_files -norecurse "${src_root}/${f}"
}
set_property file_type SystemVerilog [get_files *.sv]
set_property top $TOP [current_fileset]

# Make the OOC unit's clock a 50 MHz pseudo-constraint (project baseline;
# matches fpga_synth/synth_v2b.tcl). Real constraints live in the BD
# wrapper .xdc when going through the full Vivado flow.
set xdc_body {
create_clock -name clk -period 20.000 [get_ports clk]
set_input_delay  -clock clk 4.000 [all_inputs]
set_output_delay -clock clk 4.000 [all_outputs]
}
set xdc_path "${proj_dir}/v2b_arm_demo_ooc.xdc"
set fd [open $xdc_path w]
puts $fd $xdc_body
close $fd
add_files -fileset constrs_1 -norecurse $xdc_path

# ── Run synthesis ───────────────────────────────────────────────────
launch_runs synth_1 -jobs 4
wait_on_run synth_1

set synth_state [get_property PROGRESS [get_runs synth_1]]
if {$synth_state ne "100%"} {
  set err [get_property STATUS [get_runs synth_1]]
  puts "[FATAL] synth_1 did not complete 100% (got $synth_state; status=$err)"
  exit 1
}

open_run synth_1 -name synth_1

# ── Reports ──────────────────────────────────────────────────────────
set report_dir "./reports_ooc_arm_demo"
file mkdir $report_dir

report_utilization         -file $report_dir/utilization.rpt
report_utilization -hierarchical -file $report_dir/utilization_hier.rpt
report_timing_summary      -file $report_dir/timing.rpt

# Extract WNS for pass/fail summary
set paths [get_timing_paths -max_paths 1 -nworst 1]
if {[llength $paths] > 0} {
  set wns [get_property SLACK [lindex $paths 0]]
} else {
  set wns "NA"
}

set fd [open $report_dir/post_synth_status.rpt w]
puts $fd "=============================================="
puts $fd "v2b_arm_demo_top - OOC post-synthesis summary"
puts $fd "Target: $PART  Top: $TOP"
puts $fd "Clock: 50 MHz (20.000 ns) pseudo-constraint"
puts $fd "=============================================="
puts $fd "WNS (ns)  : $wns"
if {$wns eq "NA"} {
  puts $fd "TIMING_STATUS : UNKNOWN (no reported path)"
} elseif {$wns < 0} {
  puts $fd "TIMING_STATUS : FAIL (missed clock period)"
} else {
  puts $fd "TIMING_STATUS : PASS"
}
close $fd
puts [read [open $report_dir/post_synth_status.rpt r]]

puts "\n=== OOC ARM DEMO SYNTH DONE ==="
puts "Reports at: $report_dir/"
