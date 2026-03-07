## =============================================================================
## Pre-synth hook: copy CIM weight hex files into current synth run directory.
## This avoids "$readmemh file not found" in Vivado project mode.
## =============================================================================

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize "$script_dir/../../.."]

set weight_pos_src [file normalize "$repo_root/fpga/cim_model/weight_pos.hex"]
set weight_neg_src [file normalize "$repo_root/fpga/cim_model/weight_neg.hex"]

if {![file exists $weight_pos_src]} {
  error "Missing weight file: $weight_pos_src"
}
if {![file exists $weight_neg_src]} {
  error "Missing weight file: $weight_neg_src"
}

set run_dir [pwd]
file copy -force $weight_pos_src [file join $run_dir "weight_pos.hex"]
file copy -force $weight_neg_src [file join $run_dir "weight_neg.hex"]

puts "INFO: copied weight_pos.hex/weight_neg.hex -> $run_dir"
