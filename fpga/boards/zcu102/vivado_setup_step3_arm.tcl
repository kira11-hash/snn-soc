## =============================================================================
## Vivado project-mode one-click setup for Step3 (top_fpga_arm)
## Usage (Tcl Console):
##   source F:/SoC Design/fpga/boards/zcu102/vivado_setup_step3_arm.tcl
## Then re-run synthesis/implementation.
## =============================================================================

if {[current_project -quiet] eq ""} {
  error "No open Vivado project. Open project first."
}

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize "$script_dir/../../.."]

set top_sv   [file normalize "$script_dir/top_fpga_arm.sv"]
set arm_xdc  [file normalize "$script_dir/constraints_arm.xdc"]
set w_pos    [file normalize "$repo_root/fpga/cim_model/weight_pos.hex"]
set w_neg    [file normalize "$repo_root/fpga/cim_model/weight_neg.hex"]
set pre_hook [file normalize "$script_dir/vivado_pre_synth_copy_weights.tcl"]

foreach f [list $top_sv $arm_xdc $w_pos $w_neg $pre_hook] {
  if {![file exists $f]} {
    error "Required file missing: $f"
  }
}

proc _add_file_if_missing {fileset path} {
  set npath [file normalize $path]
  set hits [get_files -quiet $npath]
  if {[llength $hits] == 0} {
    add_files -norecurse -fileset $fileset $npath
  }
}

_add_file_if_missing sources_1 $top_sv
_add_file_if_missing constrs_1 $arm_xdc
_add_file_if_missing sources_1 $w_pos
_add_file_if_missing sources_1 $w_neg

# Keep only ARM constraints enabled in this flow.
set all_xdc [get_files -quiet -of_objects [get_filesets constrs_1] *.xdc]
foreach x $all_xdc {
  if {[string equal [file normalize $x] [file normalize $arm_xdc]]} {
    set_property used_in_synthesis true  [get_files $x]
    set_property used_in_implementation true [get_files $x]
  } else {
    set_property used_in_synthesis false [get_files $x]
    set_property used_in_implementation false [get_files $x]
  }
}

# Make sure weight files are treated as memory init files.
set wf [get_files -quiet [list $w_pos $w_neg]]
if {[llength $wf] > 0} {
  set_property file_type {Memory Initialization Files} $wf
  set_property used_in_synthesis true $wf
  set_property used_in_implementation true $wf
}

# Top and macro defines.
set_property top top_fpga_arm [get_filesets sources_1]
set_property verilog_define {FPGA SYNTHESIS} [get_filesets sources_1]
set_property verilog_define {FPGA SYNTHESIS} [get_filesets sim_1]

# Install pre-synthesis hook to auto-copy weight hex into synth_1 run directory.
set synth_run [get_runs -quiet synth_1]
if {[llength $synth_run] == 0} {
  error "Run synth_1 not found in current project."
}
set_property STEPS.SYNTH_DESIGN.TCL.PRE $pre_hook $synth_run

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "============================================"
puts "Step3 ARM setup completed"
puts "  Top:         [get_property top [get_filesets sources_1]]"
puts "  XDC enabled: $arm_xdc"
puts "  Weights:     $w_pos"
puts "               $w_neg"
puts "  Pre-hook:    $pre_hook"
puts "============================================"
