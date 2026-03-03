## =============================================================================
## Vivado Non-Project Mode Build Script for SNN SoC FPGA
## Target: ZCU102 (XCZU9EG-2FFVB1156E)
## Usage: vivado -mode batch -source build.tcl
## =============================================================================

set project_name "snn_soc_fpga"
set part         "xczu9eg-ffvb1156-2-e"
set top_module   "top_fpga"

# Resolve directories relative to this script
set script_dir   [file dirname [file normalize [info script]]]
set project_root [file normalize "$script_dir/../../.."]
set fpga_dir     [file normalize "$script_dir/../.."]
set rtl_dir      "$project_root/rtl"
set output_dir   "$script_dir/output"
set weight_pos_src "$fpga_dir/cim_model/weight_pos.hex"
set weight_neg_src "$fpga_dir/cim_model/weight_neg.hex"

file mkdir $output_dir

puts "============================================"
puts "SNN SoC FPGA Build"
puts "  Part:    $part"
puts "  Top:     $top_module"
puts "  RTL dir: $rtl_dir"
puts "  Out dir: $output_dir"
puts "============================================"

# ---------------------------------------------------------------------------
# Step 1: Read source files
# ---------------------------------------------------------------------------
read_verilog -sv [list \
  "$rtl_dir/top/snn_soc_pkg.sv"        \
  "$rtl_dir/bus/bus_simple_if.sv"       \
  "$rtl_dir/bus/bus_interconnect.sv"    \
  "$rtl_dir/mem/sram_simple.sv"         \
  "$rtl_dir/mem/sram_simple_dp.sv"      \
  "$rtl_dir/mem/fifo_sync.sv"           \
  "$rtl_dir/reg/reg_bank.sv"            \
  "$rtl_dir/reg/fifo_regs.sv"           \
  "$rtl_dir/dma/dma_engine.sv"          \
  "$rtl_dir/snn/dac_ctrl.sv"            \
  "$rtl_dir/snn/adc_ctrl.sv"            \
  "$rtl_dir/snn/lif_neurons.sv"         \
  "$rtl_dir/snn/cim_array_ctrl.sv"      \
  "$rtl_dir/snn/wl_mux_wrapper.sv"      \
  "$rtl_dir/periph/uart_stub.sv"        \
  "$rtl_dir/periph/spi_stub.sv"         \
  "$rtl_dir/periph/jtag_stub.sv"        \
  "$rtl_dir/top/snn_soc_top.sv"         \
  "$fpga_dir/cim_model/cim_fpga_model.sv" \
  "$script_dir/top_fpga.sv"             \
]

# Read constraints
read_xdc "$script_dir/constraints.xdc"

# Define SYNTHESIS and FPGA macros
set_property verilog_define {SYNTHESIS FPGA} [current_fileset]

# Prepare weight files in synthesis working directory for $readmemh.
if {![file exists $weight_pos_src]} {
  error "Missing weight file: $weight_pos_src"
}
if {![file exists $weight_neg_src]} {
  error "Missing weight file: $weight_neg_src"
}
file copy -force $weight_pos_src "$output_dir/weight_pos.hex"
file copy -force $weight_neg_src "$output_dir/weight_neg.hex"
puts "Copied weight init files to $output_dir"

# Make CWD deterministic so $readmemh(\"weight_*.hex\") resolves reliably.
cd $output_dir
puts "Vivado CWD: [pwd]"

# ---------------------------------------------------------------------------
# Step 2: Synthesis
# ---------------------------------------------------------------------------
puts ">>> Running Synthesis..."
synth_design -top $top_module -part $part \
  -flatten_hierarchy rebuilt \
  -directive Default

# Post-synthesis reports
report_utilization -file "$output_dir/post_synth_utilization.rpt"
report_timing_summary -file "$output_dir/post_synth_timing.rpt"
report_io -file "$output_dir/post_synth_io.rpt"

# Save checkpoint
write_checkpoint -force "$output_dir/post_synth.dcp"

# ---------------------------------------------------------------------------
# Step 3: Implementation (Place & Route)
# ---------------------------------------------------------------------------
puts ">>> Running Placement..."
opt_design
place_design -directive Default

puts ">>> Running Physical Optimization..."
phys_opt_design

puts ">>> Running Routing..."
route_design -directive Default

# ---------------------------------------------------------------------------
# Step 4: Post-implementation reports
# ---------------------------------------------------------------------------
report_utilization -file "$output_dir/post_impl_utilization.rpt"
report_timing_summary -file "$output_dir/post_impl_timing.rpt" -max_paths 20
report_power -file "$output_dir/post_impl_power.rpt"
report_drc -file "$output_dir/post_impl_drc.rpt"

# Fail fast on IO-standard/location/bank-voltage issues.
set io_drc [get_drc_violations -quiet -filter {NAME =~ "NSTD-1" || NAME =~ "UCIO-1" || NAME =~ "BIVC-1"}]
if {[llength $io_drc] > 0} {
  puts "ERROR: IO DRC violations detected:"
  foreach v $io_drc {
    puts "  [get_property NAME $v] :: [get_property DESCRIPTION $v]"
  }
  exit 1
}

# Check timing
set timing_slack [get_property SLACK [get_timing_paths -max_paths 1]]
puts ">>> Worst negative slack: $timing_slack ns"
if {$timing_slack < 0} {
  puts "WARNING: Timing not met! Worst slack = $timing_slack ns"
}

# Save implementation checkpoint
write_checkpoint -force "$output_dir/post_impl.dcp"

# ---------------------------------------------------------------------------
# Step 5: Generate bitstream
# ---------------------------------------------------------------------------
puts ">>> Generating Bitstream..."
write_bitstream -force "$output_dir/${project_name}.bit"

puts "============================================"
puts "Build complete!"
puts "  Bitstream: $output_dir/${project_name}.bit"
puts "  Reports:   $output_dir/*.rpt"
puts "============================================"
