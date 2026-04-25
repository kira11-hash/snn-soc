## =============================================================================
## fpga/boards/zcu102_v2_e203/constraints_v2_e203.xdc
## ZCU102 constraints for V2.B + E203 FPGA evidence branch.
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

## MMCM 50 MHz output: allow CMT column crossing as in the alpha E203 wrapper.
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets u_ibufds/O]

## ---------------------------------------------------------------------------
## Push-button reset: GPIO_SW_C (active-high)
## ---------------------------------------------------------------------------
set_property PACKAGE_PIN AM13 [get_ports btn_rst]
set_property IOSTANDARD LVCMOS33 [get_ports btn_rst]

## ---------------------------------------------------------------------------
## UART via on-board USB-UART J83 (Silicon Labs CP2108, Channel 2 -> PL)
##   F13 = FPGA TX  (uart2_PL_TX -> CP2108 Ch2 RX -> PC)
##   E13 = FPGA RX  (uart2_PL_RX <- CP2108 Ch2 TX <- PC)
## Host: CP2108 Interface 2, 115200 8N1, no flow control.
## ---------------------------------------------------------------------------
set_property PACKAGE_PIN F13 [get_ports uart_txd]
set_property PACKAGE_PIN E13 [get_ports uart_rxd]
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
## btn_rst and MMCM LOCKED drive an async-assert/sync-release reset tree.
set_false_path -from [get_ports btn_rst]
set_false_path -to   [get_cells -hier -filter {NAME =~ *rst_sync_reg[0]*}]
