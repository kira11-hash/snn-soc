## =============================================================================
## ZCU102 Constraints for SNN SoC FPGA Prototype
## Target: XCZU9EG-2FFVB1156E (Zynq UltraScale+ MPSoC)
## =============================================================================
## Note:
##   Pin/IOSTANDARD assumptions are validated by post-impl DRC checks in
##   fpga/boards/zcu102/build.tcl (NSTD-1 / UCIO-1 / BIVC-1).
##   If board revision or connector mapping differs, update this XDC first.

## ---------------------------------------------------------------------------
## System Clock: USER_SI570 (programmable, default 300 MHz differential)
## ---------------------------------------------------------------------------
set_property PACKAGE_PIN AL8 [get_ports sys_clk_p]
set_property PACKAGE_PIN AL7 [get_ports sys_clk_n]
set_property IOSTANDARD LVDS [get_ports sys_clk_p]
set_property IOSTANDARD LVDS [get_ports sys_clk_n]

create_clock -period 3.333 -name sys_clk [get_ports sys_clk_p]

## ---------------------------------------------------------------------------
## Generated clock (50 MHz from MMCM)
## ---------------------------------------------------------------------------
# Vivado will auto-derive this from the MMCM instance
# But we set the output constraint explicitly for clarity
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets u_ibufds/O]

## ---------------------------------------------------------------------------
## Push button reset: GPIO_SW_C (active-high)
## ---------------------------------------------------------------------------
set_property PACKAGE_PIN AM13 [get_ports btn_rst]
set_property IOSTANDARD LVCMOS33 [get_ports btn_rst]

## ---------------------------------------------------------------------------
## UART via PMOD J55 (directly accessible PL GPIO pins)
## Using PMOD header J55, pins 1 (TX from FPGA) and 2 (RX to FPGA)
## ---------------------------------------------------------------------------
set_property PACKAGE_PIN A20 [get_ports uart_txd]
set_property PACKAGE_PIN B20 [get_ports uart_rxd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rxd]

## ---------------------------------------------------------------------------
## SPI via PMOD J55 (optional, pins 3-6)
## ---------------------------------------------------------------------------
set_property PACKAGE_PIN A17 [get_ports spi_cs_n]
set_property PACKAGE_PIN A18 [get_ports spi_sck]
set_property PACKAGE_PIN B16 [get_ports spi_mosi]
# NOTE: Disabled for current bring-up because B17 is invalid on the active device/package map.
# Re-enable with a validated SPI_MISO pin after board-pin confirmation.
# set_property PACKAGE_PIN B17 [get_ports spi_miso]
set_property IOSTANDARD LVCMOS33 [get_ports spi_cs_n]
set_property IOSTANDARD LVCMOS33 [get_ports spi_sck]
set_property IOSTANDARD LVCMOS33 [get_ports spi_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports spi_miso]

## ---------------------------------------------------------------------------
## LEDs (directly accessible PL GPIO LEDs on ZCU102)
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
## Timing constraints
## ---------------------------------------------------------------------------
# btn_rst/uart_rxd/spi_miso are asynchronous in this bringup flow.
# Do not constrain them with sys_clk-based IO delay numbers.
set_false_path -from [get_ports btn_rst]
set_false_path -from [get_ports uart_rxd]
set_false_path -from [get_ports spi_miso]

# UART/SPI outputs are also used asynchronously in this phase.
set_false_path -to [get_ports {uart_txd spi_cs_n spi_sck spi_mosi}]
set_false_path -to [get_ports {led[*]}]

## ---------------------------------------------------------------------------
## Bitstream settings
## ---------------------------------------------------------------------------
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
# NOTE: Disabled to avoid tool/version property compatibility warning in current flow.
# set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
