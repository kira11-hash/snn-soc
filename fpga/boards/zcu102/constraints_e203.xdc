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
## UART via PMOD J55 (3.3V LVCMOS)
##   A20 = FPGA TX  (pin 1 of J55)
##   B20 = FPGA RX  (pin 2 of J55)
## Connect external USB-TTL adapter (CP2102/CH340/PL2303, 3.3V compatible):
##   USB-TTL RX  → J55 pin 1 (A20 / FPGA TX)
##   USB-TTL TX  → J55 pin 2 (B20 / FPGA RX)
##   GND         → J55 pin 5 or 11 (GND)
## ---------------------------------------------------------------------------
set_property PACKAGE_PIN A20 [get_ports uart_txd]
set_property PACKAGE_PIN B20 [get_ports uart_rxd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rxd]

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
