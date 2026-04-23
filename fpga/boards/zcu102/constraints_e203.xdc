## =============================================================================
## fpga/boards/zcu102/constraints_e203.xdc
## ZCU102 XDC for feature/main-fpga-e203 (E203 RISC-V soft-core)
## Target: XCZU9EG-2FFVB1156E
## =============================================================================

## ---------------------------------------------------------------------------
## System Clock: USER_SI570 300 MHz differential (ZCU102 bank J, pins AL8/AL7)
## ---------------------------------------------------------------------------
set_property PACKAGE_PIN AL8 [get_ports sys_clk_p]
set_property PACKAGE_PIN AL7 [get_ports sys_clk_n]
set_property IOSTANDARD LVDS [get_ports sys_clk_p]
set_property IOSTANDARD LVDS [get_ports sys_clk_n]

create_clock -period 3.333 -name sys_clk [get_ports sys_clk_p]

## MMCM 50 MHz output: Vivado auto-derives; allow CMT column crossing
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets u_ibufds/O]

## ---------------------------------------------------------------------------
## Push-button reset: GPIO_SW_C (active-high)
## ---------------------------------------------------------------------------
set_property PACKAGE_PIN AM13 [get_ports btn_rst]
set_property IOSTANDARD LVCMOS33 [get_ports btn_rst]

## ---------------------------------------------------------------------------
## UART via on-board USB-UART J83 (Silicon Labs CP2108, Channel 2 → PL)
##   F13 = FPGA TX  (uart2_PL_TX  → CP2108 Ch2 RX → PC)
##   E13 = FPGA RX  (uart2_PL_RX  ← CP2108 Ch2 TX ← PC)
##
## Host setup (no external adapter needed):
##   Plug USB cable into ZCU102 J83.  Windows enumerates four COM ports
##   (CP2108 Interface 0..3).  The PL soft-core UART is on Interface 2 —
##   typically the 3rd COM port listed for the CP2108 device.
##   Serial settings: 115200 8N1, no flow control.
## ---------------------------------------------------------------------------
set_property PACKAGE_PIN F13 [get_ports uart_txd]
set_property PACKAGE_PIN E13 [get_ports uart_rxd]
## Bank voltage for F13/E13 is 1.8V on ZCU102 HP bank (rev 1.0 onward);
## board-level level shifter sits between CP2108 (3.3V) and FPGA (1.8V),
## so use LVCMOS18 on the FPGA side (Vivado DRC expects this per part0_pins).
set_property IOSTANDARD LVCMOS18 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS18 [get_ports uart_rxd]

## ---------------------------------------------------------------------------
## LEDs (ZCU102 on-board PL LEDs, bank 26 LVCMOS33)
## ---------------------------------------------------------------------------
set_property PACKAGE_PIN AG14 [get_ports {led[0]}]
set_property PACKAGE_PIN AF13 [get_ports {led[1]}]
set_property PACKAGE_PIN AE13 [get_ports {led[2]}]
set_property PACKAGE_PIN AJ14 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]

## ---------------------------------------------------------------------------
## Timing exceptions
## ---------------------------------------------------------------------------
## False path from async reset synchroniser input to registered domain
set_false_path -from [get_ports btn_rst]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *mmcm_locked*}] -to [get_cells -hierarchical -filter {NAME =~ *rst_sync*}]
