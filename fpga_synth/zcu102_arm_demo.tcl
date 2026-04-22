#==============================================================================
# fpga_synth/zcu102_arm_demo.tcl — Phase C0 full Vivado flow for ZCU102.
#
# Produces:
#   $PROJ_NAME/$PROJ_NAME.runs/impl_1/v2b_arm_demo_bd_wrapper.bit  — bitstream
#   $PROJ_NAME/$PROJ_NAME.xsa                                        — hw handoff
#
# Block Design layout:
#
#   ┌──────────────┐         ┌─────────────────┐      ┌──────────────────┐
#   │ Zynq US+ PS  │ HPM0_   │ AXI SmartConnect│      │ v2b_axi_wrapper  │
#   │ (A53, DDR,   │─FPD────►│  (1 master →    │─────►│  (AXI-Lite slave)│
#   │  PS UART0)   │  (32b)  │   1 slave)      │      │                  │
#   └──┬───────────┘         └─────────────────┘      └──────────────────┘
#      │ pl_clk0 (50 MHz — project baseline; matches fpga_synth/synth_v2b.tcl)
#      │ pl_resetn0
#      ▼
#   ┌─────────────────────────┐
#   │ Proc System Reset       │
#   │ (synchronous resets)    │
#   └─────────────────────────┘
#
# Address map assignment:
#   ADDR_V2B_BASE = 0x00_A000_0000, RANGE = 4K (matches ADDR_V2B_BASE / END
#   in rtl/top/snn_soc_pkg.sv for the feature/v2-arm-fpga-demo branch).
#
# ARM firmware invariants this script guarantees:
#   - PS UART0 is enabled and usable via Xuartps or direct MMIO
#   - PS DDR is available for .text/.rodata (app loads to 0x100000 by default)
#   - PL fabric clock `clk` @ 50 MHz (project baseline; pulse widths in
#     cim_program_ctrl / uart_ctrl / etc. are calibrated for 50 MHz)
#
# Invocation:
#   cd d:/SoC Design/audit-v2/fpga_synth
#   vivado -mode batch -source zcu102_arm_demo.tcl -log bitgen.log
#
# Outputs .xsa for Vitis (Phase B's `build_arm_firmware.sh` can eventually
# consume xparameters.h from this XSA to replace hardcoded V2B_SOC_BASE).
#==============================================================================

# ── Project setup ───────────────────────────────────────────────────
# Root may be passed via `-tclargs` (DOS 8.3 form, see build_zcu102_arm_demo.sh)
# to work around Vivado-on-Windows' inability to handle paths with spaces.
if {$argc >= 1} {
  set root_dir [lindex $argv 0]
} else {
  set this_file [file normalize [info script]]
  set root_dir [file dirname [file dirname $this_file]]
}
set proj_dir "${root_dir}/fpga_synth"
cd $proj_dir

set PROJ_NAME "zcu102_arm_demo"
set PART      "xczu9eg-ffvb1156-2-e"
set BD_NAME   "v2b_arm_demo_bd"
set TOP       "${BD_NAME}_wrapper"

# Board definition used by the Zynq PS preset.
set BOARD_PART "xilinx.com:zcu102:part0:3.4"

# ── Clean stale project dir (only if not the most recent & not locked) ──
if {[file isdirectory $PROJ_NAME]} {
  catch {file delete -force $PROJ_NAME}
}

puts "\n=== Creating project: $PROJ_NAME  TOP=$TOP  PART=$PART ==="

create_project $PROJ_NAME ./$PROJ_NAME -part $PART -force
set_property target_language    Verilog      [current_project]
set_property simulator_language Mixed        [current_project]
# Attach ZCU102 board preset so PS IP gets proper DDR / pin / clock config.
catch {set_property board_part $BOARD_PART [current_project]}

# ── Add RTL sources ─────────────────────────────────────────────────
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

# ── Create Block Design ─────────────────────────────────────────────
create_bd_design $BD_NAME
current_bd_design $BD_NAME

# --- Zynq UltraScale+ PS IP (populated from ZCU102 board preset) ---
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.4 zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
  -config {apply_board_preset "1"} $ps

# Enable HPM0_FPD (Full Power Domain master, 0xA000_0000 aperture covers
# our proposed V2B_SOC_BASE). Disable HPM1_FPD and HPM0_LPD — single-path
# saves BD clutter and makes address decoding trivial.
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0        "1" \
  CONFIG.PSU__USE__M_AXI_GP1        "0" \
  CONFIG.PSU__USE__M_AXI_GP2        "0" \
  CONFIG.PSU__MAXIGP0__DATA_WIDTH   "32" \
  CONFIG.PSU__FPGA_PL0_ENABLE       "1" \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ "50" \
] $ps

# --- Our AXI-Lite slave wrapper (Verilog shim → SV core) ---
# Must use v2b_axi_wrapper_bd (.v) as the module reference top, because
# Vivado BD rejects .sv files as the top of a module-reference cell.
set wrapper [create_bd_cell -type module -reference v2b_axi_wrapper_bd u_v2b_wrapper]

# --- Proc System Reset (synchronous resets for PL fabric) ---
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps_100M]

# --- Wire clocks & resets ---
connect_bd_net [get_bd_pins $ps/pl_clk0]        [get_bd_pins $rst/slowest_sync_clk]
connect_bd_net [get_bd_pins $ps/pl_clk0]        [get_bd_pins $wrapper/clk]
connect_bd_net [get_bd_pins $ps/pl_resetn0]     [get_bd_pins $rst/ext_reset_in]
connect_bd_net [get_bd_pins $rst/peripheral_aresetn] [get_bd_pins $wrapper/rst_n]

# --- AXI SmartConnect: PS HPM0_FPD → v2b_axi_wrapper ---
# The X_INTERFACE_INFO attributes on v2b_axi_wrapper_bd.v make Vivado infer
# a single `s_axi` AXI-Lite slave interface pin. Try automation first; if it
# fails (older Vivado / IP catalog mismatches), fall back to explicit wiring.
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
  connect_bd_intf_net [get_bd_intf_pins $xbar/M00_AXI]      [get_bd_intf_pins $wrapper/s_axi]
  connect_bd_net [get_bd_pins $ps/pl_clk0]              [get_bd_pins $xbar/aclk]
  connect_bd_net [get_bd_pins $rst/peripheral_aresetn]  [get_bd_pins $xbar/aresetn]
}

# ── Address map ─────────────────────────────────────────────────────
# proposed V2B_SOC_BASE = 0xA000_0000, 4 KB range; assigned into the
# 0xA0000000 (256 MB) HPM0_FPD aperture exposed by the Zynq US+ PS.
assign_bd_address -offset 0xA0000000 -range 4K \
  [get_bd_addr_segs {u_v2b_wrapper/s_axi/reg0}]

# ── Validate + generate BD ──────────────────────────────────────────
validate_bd_design
save_bd_design

make_wrapper -files [get_files ${BD_NAME}.bd] -top
add_files -norecurse ./$PROJ_NAME/$PROJ_NAME.srcs/sources_1/bd/$BD_NAME/hdl/${BD_NAME}_wrapper.v
set_property top $TOP [current_fileset]
update_compile_order -fileset sources_1

# ── Add constraint file ─────────────────────────────────────────────
set xdc_path "${proj_dir}/zcu102_arm_demo.xdc"
if {[file exists $xdc_path]} {
  add_files -fileset constrs_1 -norecurse $xdc_path
} else {
  puts "INFO: no XDC file at $xdc_path (OK — ZCU102 PS IOs come from board preset)"
}

# ── Synthesis + implementation + bitgen ─────────────────────────────
puts "\n=== LAUNCH synth_1 ==="
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  puts "[FATAL] synth_1 failed"
  exit 1
}

puts "\n=== LAUNCH impl_1 (to bitstream) ==="
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  puts "[FATAL] impl_1 failed"
  exit 1
}

# ── Export hardware (XSA for Vitis) ─────────────────────────────────
open_run impl_1
write_hw_platform -fixed -include_bit -force -file ./$PROJ_NAME.xsa

# ── Summary ─────────────────────────────────────────────────────────
set bit [glob -nocomplain ./$PROJ_NAME/$PROJ_NAME.runs/impl_1/*.bit]
puts "\n=============================================="
puts "ZCU102_ARM_DEMO_BITGEN_PASS"
puts "=============================================="
puts "bitstream: $bit"
puts "xsa:       ./$PROJ_NAME.xsa"
puts ""
puts "Next: use scripts/program_zcu102_c0.tcl (xsct) to load + run on board."
