#==============================================================================
# fpga_synth/bd_sanity_zcu102_arm_demo.tcl — BD-creation-only sanity for
# Phase C0 `zcu102_arm_demo.tcl`.
#
# Sources zcu102_arm_demo.tcl up through validate_bd_design / save_bd_design,
# then EXITS before synth/impl/bitgen. Use this for a fast (~30 s) check
# that the BD TCL is valid. Full bitgen still requires the real script.
#
# Invocation:
#   vivado -mode batch -source bd_sanity_zcu102_arm_demo.tcl -tclargs <ROOT_8_3>
#==============================================================================

# Resolve root (DOS 8.3 from wrapper script)
if {$argc >= 1} {
  set root_dir [lindex $argv 0]
} else {
  set this_file [file normalize [info script]]
  set root_dir [file dirname [file dirname $this_file]]
}
set proj_dir "${root_dir}/fpga_synth"
cd $proj_dir

set PROJ_NAME "zcu102_bd_sanity_[clock format [clock seconds] -format {%H%M%S}]"
set PART      "xczu9eg-ffvb1156-2-e"
set BD_NAME   "v2b_arm_demo_bd"
set BOARD_PART "xilinx.com:zcu102:part0:3.4"

# Clean stale
foreach stale [glob -nocomplain "zcu102_bd_sanity_*"] {
  if {[file isdirectory $stale]} { catch {file delete -force $stale} }
}

create_project $PROJ_NAME ./$PROJ_NAME -part $PART -force
set_property target_language Verilog [current_project]
catch {set_property board_part $BOARD_PART [current_project]}

set src_root "${root_dir}/rtl"
foreach f [list \
  {top/snn_soc_pkg.sv} \
  {snn/input_stream_sram.sv} \
  {snn/stream_buffer_v2.sv} \
  {snn/tile_partial_buf.sv} \
  {snn/cim_mac_behavioral_v2.sv} \
  {snn/stage_engine_v2.sv} \
  {top/snn_soc_v2b_top.sv} \
  {bus/axi2simple_bridge.sv} \
  {bus/simple2v2btop_adapter.sv} \
  {top/v2b_axi_wrapper.sv} \
  {top/v2b_axi_wrapper_bd.v} \
] {
  add_files -norecurse "${src_root}/${f}"
}
set_property file_type SystemVerilog [get_files *.sv]
set_property file_type Verilog        [get_files *.v]
update_compile_order -fileset sources_1

create_bd_design $BD_NAME
current_bd_design $BD_NAME

set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.4 zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
  -config {apply_board_preset "1"} $ps

set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0        "1" \
  CONFIG.PSU__USE__M_AXI_GP1        "0" \
  CONFIG.PSU__USE__M_AXI_GP2        "0" \
  CONFIG.PSU__MAXIGP0__DATA_WIDTH   "32" \
  CONFIG.PSU__FPGA_PL0_ENABLE       "1" \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ "100" \
] $ps

set wrapper [create_bd_cell -type module -reference v2b_axi_wrapper_bd u_v2b_wrapper]
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps_100M]

connect_bd_net [get_bd_pins $ps/pl_clk0]        [get_bd_pins $rst/slowest_sync_clk]
connect_bd_net [get_bd_pins $ps/pl_clk0]        [get_bd_pins $wrapper/clk]
connect_bd_net [get_bd_pins $ps/pl_resetn0]     [get_bd_pins $rst/ext_reset_in]
connect_bd_net [get_bd_pins $rst/peripheral_aresetn] [get_bd_pins $wrapper/rst_n]

# Try automation first
if {[catch {
  apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/zynq_ultra_ps_e_0/M_AXI_HPM0_FPD" \
             Clk_xbar "Auto" Clk_master "Auto" Clk_slave "Auto" intc_ip "New AXI SmartConnect"} \
    [get_bd_intf_pins $wrapper/s_axi]
} err]} {
  puts "INFO: apply_bd_automation failed ($err); falling back to manual SmartConnect"
  set xbar [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_0]
  set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $xbar
  connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] [get_bd_intf_pins $xbar/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins $xbar/M00_AXI] [get_bd_intf_pins $wrapper/s_axi]
  connect_bd_net [get_bd_pins $ps/pl_clk0] [get_bd_pins $xbar/aclk]
  connect_bd_net [get_bd_pins $rst/peripheral_aresetn] [get_bd_pins $xbar/aresetn]
}

# Assign address directly into the 0xA000_0000 (256 MB) HPM0_FPD aperture.
# Using -offset/-range on assign_bd_address avoids the two-step set_property
# path which failed when auto-assignment picked a different aperture
# (0x4_0000_0000).
assign_bd_address -offset 0xA0000000 -range 4K \
  [get_bd_addr_segs {u_v2b_wrapper/s_axi/reg0}]
puts "\[bd_sanity\] V2B window assigned at 0xA0000000/4K via HPM0_FPD"

validate_bd_design
save_bd_design

# Check that the wrapper shows up as an AXI slave and was interface-inferred
set wrapper_axi_intfs [get_bd_intf_pins -of_objects $wrapper]
puts "\n\[bd_sanity\] wrapper intf pins: $wrapper_axi_intfs"

puts "\n=============================================="
puts "ZCU102_BD_SANITY_PASS"
puts "=============================================="
