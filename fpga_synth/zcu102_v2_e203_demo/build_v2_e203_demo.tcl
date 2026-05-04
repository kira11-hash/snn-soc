# fpga_synth/zcu102_v2_e203_demo/build_v2_e203_demo.tcl
# Vivado non-project build for feature/v2-fpga-e203.
# Top: snn_soc_v2b_e203_fpga_top
# Output: ${out_dir}/snn_soc_v2b_e203_fpga_top.bit

if {[llength $argv] >= 1} {
    set repo_root [lindex $argv 0]
} else {
    set repo_root [file normalize [file join [file dirname [info script]] ../..]]
}

if {[llength $argv] >= 2} {
    set instr_hex [lindex $argv 1]
} else {
    set instr_hex [file join $repo_root fw v2_e203_smoke out v2_e203_lenet5.hex]
}

if {[llength $argv] >= 3} {
    set out_dir [lindex $argv 2]
} else {
    set out_dir [file join $repo_root fpga_synth zcu102_v2_e203_demo out]
}

proc find_vendor_e203_rtl_dir {repo_root} {
    set alias_dir [file join $repo_root rtl vendor_e203]
    if {[file isdirectory $alias_dir]} {
        return $alias_dir
    }

    set preferred_dir [file join $repo_root 项目相关文件 未添加的IP的源代码 e203_hbirdv2-master rtl]
    if {[file isdirectory $preferred_dir]} {
        return $preferred_dir
    }

    error "Unable to locate vendor E203 RTL under $repo_root (checked rtl/vendor_e203 and 项目相关文件/.../e203_hbirdv2-master/rtl)"
}

file mkdir $out_dir

puts "=== ZCU102 V2E203 FPGA Build ==="
puts "Repo root  : $repo_root"
puts "Firmware   : $instr_hex"
puts "Output dir : $out_dir"

set vendor_rtl [find_vendor_e203_rtl_dir $repo_root]
puts "Vendor RTL : $vendor_rtl"

if {![file exists $instr_hex]} {
    puts "ERROR: Firmware hex not found: $instr_hex"
    exit 2
}

set part    "xczu9eg-ffvb1156-2-e"
set top_mod "snn_soc_v2b_e203_fpga_top"

set_property verilog_define {SYNTHESIS=1 SOC_ENABLE_E203_VENDOR=1 FPGA_SOURCE=1} [current_fileset]
set_property include_dirs [list \
    $repo_root/rtl/top \
    $vendor_rtl/e203/core \
] [current_fileset]

set sv_files [list \
    $repo_root/rtl/top/snn_soc_pkg.sv \
    $repo_root/rtl/bus/icb_err_slave.sv \
    $repo_root/rtl/bus/icb2simple_bridge_v2b.sv \
    $repo_root/rtl/bus/bus_interconnect_v2_e203.sv \
    $repo_root/rtl/bus/simple2v2btop_adapter.sv \
    $repo_root/rtl/mem/sram_simple.sv \
    $repo_root/rtl/periph/uart_ctrl.sv \
    $repo_root/rtl/sys/reset_sync.sv \
    $repo_root/rtl/snn/lif_neuron_alu.sv \
    $repo_root/rtl/snn/cim_mac_behavioral_v2.sv \
    $repo_root/rtl/snn/input_stream_sram.sv \
    $repo_root/rtl/snn/stream_buffer_v2.sv \
    $repo_root/rtl/snn/tile_partial_buf.sv \
    $repo_root/rtl/snn/fmap_sram_v2.sv \
    $repo_root/rtl/snn/patch_unroller_v2.sv \
    $repo_root/rtl/snn/fmap_flatten_reader_v2.sv \
    $repo_root/rtl/snn/conv_ctrl_v2.sv \
    $repo_root/rtl/snn/stage_engine_v2.sv \
    $repo_root/rtl/top/snn_soc_v2b_top.sv \
    $repo_root/rtl/top/e203_min_wrap.sv \
    $repo_root/rtl/top/snn_soc_v2b_e203_top.sv \
    $repo_root/fpga/boards/zcu102_v2_e203/snn_soc_v2b_e203_fpga_top.sv \
]

set e203_vendor_files [list \
    $vendor_rtl/e203/general/sirv_1cyc_sram_ctrl.v \
    $vendor_rtl/e203/general/sirv_gnrl_bufs.v \
    $vendor_rtl/e203/general/sirv_gnrl_dffs.v \
    $vendor_rtl/e203/general/sirv_gnrl_icbs.v \
    $vendor_rtl/e203/general/sirv_gnrl_ram.v \
    $vendor_rtl/e203/general/sirv_gnrl_xchecker.v \
    $vendor_rtl/e203/general/sirv_sim_ram.v \
    $vendor_rtl/e203/general/sirv_sram_icb_ctrl.v \
    $vendor_rtl/e203/core/e203_biu.v \
    $vendor_rtl/e203/core/e203_clk_ctrl.v \
    $vendor_rtl/e203/core/e203_clkgate.v \
    $vendor_rtl/e203/core/e203_core.v \
    $vendor_rtl/e203/core/e203_cpu_top.v \
    $vendor_rtl/e203/core/e203_cpu.v \
    $vendor_rtl/e203/core/e203_dtcm_ctrl.v \
    $vendor_rtl/e203/core/e203_dtcm_ram.v \
    $vendor_rtl/e203/core/e203_extend_csr.v \
    $vendor_rtl/e203/core/e203_exu_alu_bjp.v \
    $vendor_rtl/e203/core/e203_exu_alu_csrctrl.v \
    $vendor_rtl/e203/core/e203_exu_alu_dpath.v \
    $vendor_rtl/e203/core/e203_exu_alu_lsuagu.v \
    $vendor_rtl/e203/core/e203_exu_alu_muldiv.v \
    $vendor_rtl/e203/core/e203_exu_alu_rglr.v \
    $vendor_rtl/e203/core/e203_exu_alu.v \
    $vendor_rtl/e203/core/e203_exu_branchslv.v \
    $vendor_rtl/e203/core/e203_exu_commit.v \
    $vendor_rtl/e203/core/e203_exu_csr.v \
    $vendor_rtl/e203/core/e203_exu_decode.v \
    $vendor_rtl/e203/core/e203_exu_disp.v \
    $vendor_rtl/e203/core/e203_exu_excp.v \
    $vendor_rtl/e203/core/e203_exu_longpwbck.v \
    $vendor_rtl/e203/core/e203_exu_nice.v \
    $vendor_rtl/e203/core/e203_exu_oitf.v \
    $vendor_rtl/e203/core/e203_exu_regfile.v \
    $vendor_rtl/e203/core/e203_exu.v \
    $vendor_rtl/e203/core/e203_exu_wbck.v \
    $vendor_rtl/e203/core/e203_ifu_ifetch.v \
    $vendor_rtl/e203/core/e203_ifu_ift2icb.v \
    $vendor_rtl/e203/core/e203_ifu_litebpu.v \
    $vendor_rtl/e203/core/e203_ifu_minidec.v \
    $vendor_rtl/e203/core/e203_ifu.v \
    $vendor_rtl/e203/core/e203_irq_sync.v \
    $vendor_rtl/e203/core/e203_itcm_ctrl.v \
    $vendor_rtl/e203/core/e203_itcm_ram.v \
    $vendor_rtl/e203/core/e203_lsu_ctrl.v \
    $vendor_rtl/e203/core/e203_lsu.v \
    $vendor_rtl/e203/core/e203_reset_ctrl.v \
    $vendor_rtl/e203/core/e203_srams.v \
    $vendor_rtl/e203/subsys/e203_subsys_nice_core.v \
]

foreach f $sv_files {
    read_verilog -sv $f
}
foreach f $e203_vendor_files {
    read_verilog $f
}
read_xdc $repo_root/fpga/boards/zcu102_v2_e203/constraints_v2_e203.xdc

puts "=== Running synthesis ==="
synth_design \
    -top $top_mod \
    -part $part \
    -generic "INSTR_INIT_FILE=$instr_hex" \
    -include_dirs [list $repo_root/rtl/top $vendor_rtl/e203/core] \
    -verbose

write_checkpoint -force $out_dir/post_synth.dcp

puts "=== Optimizing design ==="
opt_design

puts "=== Running placement ==="
place_design
phys_opt_design

puts "=== Running routing ==="
route_design
write_checkpoint -force $out_dir/post_route.dcp

puts "=== Generating reports ==="
report_timing_summary -file $out_dir/timing_summary.rpt -warn_on_violation
report_utilization     -file $out_dir/utilization.rpt
report_route_status    -file $out_dir/route_status.rpt
report_drc             -file $out_dir/drc.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1]]
puts "=== WNS = $wns ns ==="
if {$wns < 0} {
    puts "ERROR: Negative WNS at 50 MHz. Review timing_summary.rpt"
    exit 3
}

puts "=== Generating bitstream ==="
write_bitstream -force $out_dir/snn_soc_v2b_e203_fpga_top.bit

puts ""
puts "=== Build complete ==="
puts "Bitstream : $out_dir/snn_soc_v2b_e203_fpga_top.bit"
puts "Timing    : $out_dir/timing_summary.rpt"
puts "Util      : $out_dir/utilization.rpt"
