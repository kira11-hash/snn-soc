# fpga_synth/zcu102_e203_demo/build_e203_demo.tcl
# Vivado non-project mode build script for feature/main-fpga-e203.
# Target: Xilinx XCZU9EG-2FFVB1156E (ZCU102 PL fabric)
# Top module: snn_soc_fpga_top
#
# Usage (from repo root):
#   vivado -mode batch -source fpga_synth/zcu102_e203_demo/build_e203_demo.tcl \
#          -tclargs [instr_hex_path] [output_dir]
#
# Arguments:
#   instr_hex_path : path to e203_smoke.hex (default: fw/e203_smoke/out/e203_smoke.hex)
#   output_dir     : output directory      (default: fpga_synth/zcu102_e203_demo/out)
#
# Outputs:
#   out/snn_soc_fpga_top.bit  — bitstream
#   out/timing_summary.rpt    — timing summary (check WNS > 0)
#   out/utilization.rpt       — resource utilization

# ---------------------------------------------------------------------------
# Argument parsing
# build_e203_demo.sh passes: repo_short  instr_hex_short  out_dir_short
# All three are 8.3 / spaces-free paths so Vivado read_verilog accepts them.
# ---------------------------------------------------------------------------
# When called from build_e203_demo.sh, argv contains 8.3 short paths that
# are free of spaces.  Do NOT call [file normalize] on these — it would
# expand them back to long paths, reintroducing spaces.
if {[llength $argv] >= 1} {
    set repo_root [lindex $argv 0]
} else {
    set repo_root [file normalize [file join [file dirname [info script]] ../..]]
}

if {[llength $argv] >= 2} {
    set instr_hex [lindex $argv 1]
} else {
    set instr_hex [file join $repo_root fw e203_smoke out e203_smoke.hex]
}

if {[llength $argv] >= 3} {
    set out_dir [lindex $argv 2]
} else {
    set out_dir [file join $repo_root fpga_synth zcu102_e203_demo out]
}

file mkdir $out_dir

puts "=== ZCU102 E203 FPGA Build ==="
puts "Repo root  : $repo_root"
puts "Firmware   : $instr_hex"
puts "Output dir : $out_dir"

if {![file exists $instr_hex]} {
    puts "ERROR: Firmware hex not found: $instr_hex"
    puts "Run: bash fw/e203_smoke/build_e203_smoke.sh"
    exit 2
}

# ---------------------------------------------------------------------------
# Part and top
# ---------------------------------------------------------------------------
set part    "xczu9eg-ffvb1156-2-e"
set top_mod "snn_soc_fpga_top"

# ---------------------------------------------------------------------------
# Source files
# ---------------------------------------------------------------------------
# For FPGA build:
#   - EXCLUDE rtl/snn/cim_macro_blackbox.sv  (behavioral model with `ifdef)
#   - INCLUDE  fpga/cim_model/cim_fpga_programmable_model.sv  (FPGA drop-in)
# All other RTL files are included verbatim.

set sv_files [list \
    $repo_root/rtl/top/snn_soc_pkg.sv \
    $repo_root/rtl/bus/bus_simple_if.sv \
    $repo_root/rtl/bus/bus_interconnect.sv \
    $repo_root/rtl/bus/icb_err_slave.sv \
    $repo_root/rtl/bus/icb2simple_bridge.sv \
    $repo_root/rtl/mem/sram_simple.sv \
    $repo_root/rtl/mem/sram_simple_dp.sv \
    $repo_root/rtl/mem/fifo_sync.sv \
    $repo_root/rtl/reg/reg_bank.sv \
    $repo_root/rtl/reg/fifo_regs.sv \
    $repo_root/rtl/dma/dma_engine.sv \
    $repo_root/rtl/snn/dac_ctrl.sv \
    $repo_root/rtl/snn/adc_ctrl.sv \
    $repo_root/rtl/snn/lif_neurons.sv \
    $repo_root/rtl/snn/cim_array_ctrl.sv \
    $repo_root/rtl/snn/wl_mux_wrapper.sv \
    $repo_root/rtl/snn/cim_macro_arbiter.sv \
    $repo_root/rtl/snn/cim_program_ctrl.sv \
    $repo_root/rtl/periph/uart_ctrl.sv \
    $repo_root/rtl/periph/spi_ctrl.sv \
    $repo_root/rtl/periph/jtag_mem_loader.sv \
    $repo_root/rtl/top/e203_min_wrap.sv \
    $repo_root/rtl/top/snn_soc_top.sv \
    $repo_root/fpga/cim_model/cim_fpga_programmable_model.sv \
    $repo_root/fpga/boards/zcu102/snn_soc_fpga_top.sv \
]

# E203 vendor RTL files (accessed via rtl/vendor_e203 NTFS junction)
# Matches sim/sim_e203.f; excludes TB files.
set e203_vendor_files [list \
    $repo_root/rtl/vendor_e203/e203/general/sirv_1cyc_sram_ctrl.v \
    $repo_root/rtl/vendor_e203/e203/general/sirv_gnrl_bufs.v \
    $repo_root/rtl/vendor_e203/e203/general/sirv_gnrl_dffs.v \
    $repo_root/rtl/vendor_e203/e203/general/sirv_gnrl_icbs.v \
    $repo_root/rtl/vendor_e203/e203/general/sirv_gnrl_ram.v \
    $repo_root/rtl/vendor_e203/e203/general/sirv_gnrl_xchecker.v \
    $repo_root/rtl/vendor_e203/e203/general/sirv_sim_ram.v \
    $repo_root/rtl/vendor_e203/e203/general/sirv_sram_icb_ctrl.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_biu.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_clk_ctrl.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_clkgate.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_core.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_cpu_top.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_cpu.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_dtcm_ctrl.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_dtcm_ram.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_extend_csr.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_alu_bjp.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_alu_csrctrl.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_alu_dpath.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_alu_lsuagu.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_alu_muldiv.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_alu_rglr.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_alu.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_branchslv.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_commit.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_csr.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_decode.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_disp.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_excp.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_longpwbck.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_nice.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_oitf.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_regfile.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_exu_wbck.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_ifu_ifetch.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_ifu_ift2icb.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_ifu_litebpu.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_ifu_minidec.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_ifu.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_irq_sync.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_itcm_ctrl.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_itcm_ram.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_lsu_ctrl.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_lsu.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_reset_ctrl.v \
    $repo_root/rtl/vendor_e203/e203/core/e203_srams.v \
    $repo_root/rtl/vendor_e203/e203/subsys/e203_subsys_nice_core.v \
]

# XDC constraints
set xdc_file $repo_root/fpga/boards/zcu102/constraints_e203.xdc

# ---------------------------------------------------------------------------
# Read design
# read_verilog called one file at a time; avoids word-splitting on paths
# containing spaces when using {*} expansion with Vivado 2022 TCL.
# ---------------------------------------------------------------------------
foreach f $sv_files {
    read_verilog -sv $f
}
# E203 vendor files are plain Verilog (not SystemVerilog)
foreach f $e203_vendor_files {
    read_verilog $f
}
read_xdc $xdc_file

# ---------------------------------------------------------------------------
# Define SYNTHESIS + SOC_ENABLE_E203_VENDOR + FPGA_SOURCE
#   SYNTHESIS    : guards behavioral-only blocks (sim-only $display etc.)
#   SOC_ENABLE_E203_VENDOR : activates E203 core inside e203_min_wrap.sv
#   FPGA_SOURCE  : selects FPGA RAM path in sirv_gnrl_ram.v / xchecker guards
# ---------------------------------------------------------------------------
set_property verilog_define {SYNTHESIS=1 SOC_ENABLE_E203_VENDOR=1 FPGA_SOURCE=1} [current_fileset]

# ---------------------------------------------------------------------------
# Synthesis
# ---------------------------------------------------------------------------
puts "=== Running synthesis ==="
synth_design \
    -top $top_mod \
    -part $part \
    -generic "INSTR_INIT_FILE=[file nativename $instr_hex]" \
    -include_dirs [list $repo_root/rtl/top $repo_root/rtl/vendor_e203/e203/core] \
    -verbose

write_checkpoint -force $out_dir/post_synth.dcp

# Check for critical messages
set crit [get_msg_config -severity {CRITICAL WARNING} -count]
if {$crit > 0} {
    puts "WARNING: $crit critical warnings in synthesis. Review before tape-out."
}

# ---------------------------------------------------------------------------
# Optimization
# ---------------------------------------------------------------------------
puts "=== Optimizing design ==="
opt_design

# ---------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------
puts "=== Running placement ==="
place_design
phys_opt_design

# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------
puts "=== Running routing ==="
route_design

write_checkpoint -force $out_dir/post_route.dcp

# ---------------------------------------------------------------------------
# Timing reports
# ---------------------------------------------------------------------------
puts "=== Generating reports ==="
report_timing_summary \
    -file $out_dir/timing_summary.rpt \
    -warn_on_violation

report_utilization \
    -file $out_dir/utilization.rpt

# Check WNS
set wns [get_property SLACK [get_timing_paths -max_paths 1]]
puts "=== WNS = $wns ns ==="
if {$wns < 0} {
    puts "WARNING: Negative WNS — timing violation at 50 MHz. Review timing_summary.rpt"
} else {
    puts "Timing PASS: WNS > 0"
}

# ---------------------------------------------------------------------------
# Bitstream
# ---------------------------------------------------------------------------
puts "=== Generating bitstream ==="
write_bitstream -force $out_dir/snn_soc_fpga_top.bit

puts ""
puts "=== Build complete ==="
puts "Bitstream : $out_dir/snn_soc_fpga_top.bit"
puts "Timing    : $out_dir/timing_summary.rpt"
puts "Util      : $out_dir/utilization.rpt"
puts ""
puts "Program board: xsct scripts/program_zcu102_e203.tcl $out_dir/snn_soc_fpga_top.bit"
