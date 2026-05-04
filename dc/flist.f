// ============================================================
// DC ASIC 综合 RTL filelist — V1 SNN SoC chip_top
// ============================================================
// 派生自 sim/sim_chip_top_rom_smoke.f；
// 已去除 TB 文件 + FPGA-only 路径文件。
// 路径相对 dc/（DC 从 dc/ 启动），所以用 ../rtl/...
//
// +define+SOC_ENABLE_E203_VENDOR 在 top_syn.tcl 里设过，
// 让 e203_min_wrap.sv 走真 vendor RTL 分支（不走 stub）。
// ============================================================

// ── package ─────────────────────────────────────────────────
../rtl/top/snn_soc_pkg.sv

// ── 总线 / 桥接 ────────────────────────────────────────────
../rtl/bus/bus_simple_if.sv
../rtl/bus/bus_interconnect.sv
../rtl/bus/icb_err_slave.sv
../rtl/bus/icb2simple_bridge.sv

// ── 存储 ──────────────────────────────────────────────────
../rtl/mem/boot_rom.sv
../rtl/mem/sram_simple.sv
../rtl/mem/sram_simple_dp.sv
../rtl/mem/fifo_sync.sv

// ── 寄存器 ─────────────────────────────────────────────────
../rtl/reg/reg_bank.sv
../rtl/reg/fifo_regs.sv

// ── DMA ────────────────────────────────────────────────────
../rtl/dma/dma_engine.sv

// ── SNN 数字加速器 ─────────────────────────────────────────
../rtl/snn/dac_ctrl.sv
../rtl/snn/adc_ctrl.sv
../rtl/snn/lif_neurons.sv
../rtl/snn/cim_array_ctrl.sv
../rtl/snn/wl_mux_wrapper.sv
../rtl/snn/cim_macro_blackbox.sv
../rtl/snn/cim_macro_arbiter.sv
../rtl/snn/cim_program_ctrl.sv

// ── 外设 ──────────────────────────────────────────────────
../rtl/periph/uart_ctrl.sv
../rtl/periph/spi_ctrl.sv
../rtl/periph/jtag_mem_loader.sv

// ── E203 RISC-V wrapper ────────────────────────────────────
../rtl/top/e203_min_wrap.sv

// ── CDC / reset 同步器（pre-tape-out fix） ─────────────────
../rtl/sys/sync_2ff.sv
../rtl/sys/reset_sync.sv

// ── SoC 顶层 + chip_top pad-level wrapper ──────────────────
../rtl/top/snn_soc_top.sv
../rtl/top/chip_top.sv

// ── E203 vendor 通用模块 ──────────────────────────────────
../rtl/vendor_e203/e203/general/sirv_1cyc_sram_ctrl.v
../rtl/vendor_e203/e203/general/sirv_gnrl_bufs.v
../rtl/vendor_e203/e203/general/sirv_gnrl_dffs.v
../rtl/vendor_e203/e203/general/sirv_gnrl_icbs.v
../rtl/vendor_e203/e203/general/sirv_gnrl_ram.v
../rtl/vendor_e203/e203/general/sirv_gnrl_xchecker.v
../rtl/vendor_e203/e203/general/sirv_sim_ram.v
../rtl/vendor_e203/e203/general/sirv_sram_icb_ctrl.v

// ── E203 vendor core ──────────────────────────────────────
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

// ── E203 vendor subsys ────────────────────────────────────
../rtl/vendor_e203/e203/subsys/e203_subsys_nice_core.v
