// sim/sim_v2_e203.f
// V2E203 SoC 功能仿真 filelist
// 编译：iverilog -g2012 -gno-assertions -o v2_e203_test -f sim_v2_e203.f
// 不得定义 SYNTHESIS；功能仿真必须带 SOC_ENABLE_E203_VENDOR + FPGA_SOURCE。

+define+SOC_ENABLE_E203_VENDOR
+define+FPGA_SOURCE
+incdir+../rtl/vendor_e203/e203/core

// ── Package ──
../rtl/top/snn_soc_pkg.sv

// ── V2E203 buses (new in this branch) ──
../rtl/bus/icb2simple_bridge_v2b.sv
../rtl/bus/bus_interconnect_v2_e203.sv
../rtl/bus/simple2v2btop_adapter.sv

// ── V1 shared infra still reused (0 diff) ──
../rtl/bus/icb_err_slave.sv
../rtl/mem/sram_simple.sv
../rtl/periph/uart_ctrl.sv

// ── V2B accelerator primitives (from v2 branch) ──
../rtl/snn/lif_neuron_alu.sv
../rtl/snn/cim_mac_behavioral_v2.sv
../rtl/snn/input_stream_sram.sv
../rtl/snn/stream_buffer_v2.sv
../rtl/snn/tile_partial_buf.sv
../rtl/snn/stage_engine_v2.sv
../rtl/top/snn_soc_v2b_top.sv

// ── E203 core wrap + vendor ──
../rtl/top/e203_min_wrap.sv

../rtl/vendor_e203/e203/general/sirv_1cyc_sram_ctrl.v
../rtl/vendor_e203/e203/general/sirv_gnrl_bufs.v
../rtl/vendor_e203/e203/general/sirv_gnrl_dffs.v
../rtl/vendor_e203/e203/general/sirv_gnrl_icbs.v
../rtl/vendor_e203/e203/general/sirv_gnrl_ram.v
../rtl/vendor_e203/e203/general/sirv_gnrl_xchecker.v
../rtl/vendor_e203/e203/general/sirv_sim_ram.v
../rtl/vendor_e203/e203/general/sirv_sram_icb_ctrl.v

../rtl/vendor_e203/e203/core/e203_biu.v
../rtl/vendor_e203/e203/core/e203_clk_ctrl.v
../rtl/vendor_e203/e203/core/e203_clkgate.v
../rtl/vendor_e203/e203/core/e203_core.v
../rtl/vendor_e203/e203/core/e203_cpu_top.v
../rtl/vendor_e203/e203/core/e203_cpu.v
../rtl/vendor_e203/e203/core/e203_dtcm_ctrl.v
../rtl/vendor_e203/e203/core/e203_dtcm_ram.v
../rtl/vendor_e203/e203/core/e203_extend_csr.v
../rtl/vendor_e203/e203/core/e203_exu_alu_bjp.v
../rtl/vendor_e203/e203/core/e203_exu_alu_csrctrl.v
../rtl/vendor_e203/e203/core/e203_exu_alu_dpath.v
../rtl/vendor_e203/e203/core/e203_exu_alu_lsuagu.v
../rtl/vendor_e203/e203/core/e203_exu_alu_muldiv.v
../rtl/vendor_e203/e203/core/e203_exu_alu_rglr.v
../rtl/vendor_e203/e203/core/e203_exu_alu.v
../rtl/vendor_e203/e203/core/e203_exu_branchslv.v
../rtl/vendor_e203/e203/core/e203_exu_commit.v
../rtl/vendor_e203/e203/core/e203_exu_csr.v
../rtl/vendor_e203/e203/core/e203_exu_decode.v
../rtl/vendor_e203/e203/core/e203_exu_disp.v
../rtl/vendor_e203/e203/core/e203_exu_excp.v
../rtl/vendor_e203/e203/core/e203_exu_longpwbck.v
../rtl/vendor_e203/e203/core/e203_exu_nice.v
../rtl/vendor_e203/e203/core/e203_exu_oitf.v
../rtl/vendor_e203/e203/core/e203_exu_regfile.v
../rtl/vendor_e203/e203/core/e203_exu.v
../rtl/vendor_e203/e203/core/e203_exu_wbck.v
../rtl/vendor_e203/e203/core/e203_ifu_ifetch.v
../rtl/vendor_e203/e203/core/e203_ifu_ift2icb.v
../rtl/vendor_e203/e203/core/e203_ifu_litebpu.v
../rtl/vendor_e203/e203/core/e203_ifu_minidec.v
../rtl/vendor_e203/e203/core/e203_ifu.v
../rtl/vendor_e203/e203/core/e203_irq_sync.v
../rtl/vendor_e203/e203/core/e203_itcm_ctrl.v
../rtl/vendor_e203/e203/core/e203_itcm_ram.v
../rtl/vendor_e203/e203/core/e203_lsu_ctrl.v
../rtl/vendor_e203/e203/core/e203_lsu.v
../rtl/vendor_e203/e203/core/e203_reset_ctrl.v
../rtl/vendor_e203/e203/core/e203_srams.v
../rtl/vendor_e203/e203/subsys/e203_subsys_nice_core.v

// ── V2E203 SoC top ──
../rtl/top/snn_soc_v2b_e203_top.sv

// ── TB (override by -s flag or by changing this file) ──
../tb/v2_e203_soc_compile_tb.sv
