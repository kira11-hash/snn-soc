#==============================================================================
# fpga_synth/zcu102_arm_demo.xdc — constraints for the Phase C0 BD top.
#
# The BD wrapper (`v2b_arm_demo_bd_wrapper.v`) exposes zero user IOs —
# everything (DDR, PS UART0 via MIO, JTAG via PS-JTAG) is driven through the
# Zynq UltraScale+ PS. The board preset `xilinx.com:zcu102:part0:3.4`
# fills in the MIO pin mapping automatically during `apply_bd_automation`.
#
# Therefore this XDC is intentionally near-empty: no clock, no IO, no timing
# exceptions beyond what the auto-generated BD wrapper handles.
#
# If a future Phase C reshape adds PL-side IOs (e.g., LED debug), constrain
# them below with ZCU102-specific package pins (UG1182 Table 1).
#==============================================================================

# placeholder — add PL IO constraints here as needed
