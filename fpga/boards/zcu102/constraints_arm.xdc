## =============================================================================
## ZCU102 Constraints for Step3 ARM Top (top_fpga_arm)
## Target: XCZU9EG-2FFVB1156E
## =============================================================================
## IMPORTANT:
##   - This file is for top_fpga_arm.sv only.
##   - Do NOT use step2 constraints.xdc together with this file.
##   - In Vivado project mode, keep only this XDC enabled for step3 runs.

## ---------------------------------------------------------------------------
## AXI clock/reset constraints (from PS side)
## ---------------------------------------------------------------------------
## Project baseline uses 50 MHz (align with step2/ASIC flow).
## Keep this constraint consistent with PS FCLK configuration in BD.
create_clock -name s_axi_aclk -period 20.000 [get_ports s_axi_aclk]

## Reset is asynchronous to timing analysis paths.
set_false_path -from [get_ports s_axi_aresetn]

## ---------------------------------------------------------------------------
## AXI-Lite IO timing model (virtual external master, board-level placeholder)
## ---------------------------------------------------------------------------
set_input_delay  -clock [get_clocks s_axi_aclk] 0.0 [get_ports {\
  s_axi_awaddr[*] s_axi_awprot[*] s_axi_awvalid \
  s_axi_wdata[*]  s_axi_wstrb[*]  s_axi_wvalid  \
  s_axi_bready \
  s_axi_araddr[*] s_axi_arprot[*] s_axi_arvalid \
  s_axi_rready \
}]

set_output_delay -clock [get_clocks s_axi_aclk] 0.0 [get_ports {\
  s_axi_awready s_axi_wready \
  s_axi_bresp[*] s_axi_bvalid \
  s_axi_arready \
  s_axi_rdata[*] s_axi_rresp[*] s_axi_rvalid \
}]

## ---------------------------------------------------------------------------
## External UART/SPI/LED pins (same mapping as step2 bring-up)
## ---------------------------------------------------------------------------
## UART via PMOD J55
set_property PACKAGE_PIN A20 [get_ports uart_txd]
set_property PACKAGE_PIN B20 [get_ports uart_rxd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rxd]

## SPI via PMOD J55 (optional)
set_property PACKAGE_PIN A17 [get_ports spi_cs_n]
set_property PACKAGE_PIN A18 [get_ports spi_sck]
set_property PACKAGE_PIN B16 [get_ports spi_mosi]
## NOTE:
##   Keep spi_miso without LOC for now (board-pin to be re-confirmed for this flow).
##   If your board mapping is confirmed, add PACKAGE_PIN for spi_miso here.
set_property IOSTANDARD LVCMOS33 [get_ports spi_cs_n]
set_property IOSTANDARD LVCMOS33 [get_ports spi_sck]
set_property IOSTANDARD LVCMOS33 [get_ports spi_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports spi_miso]

## LEDs
set_property PACKAGE_PIN AG14 [get_ports {led[0]}]
set_property PACKAGE_PIN AF13 [get_ports {led[1]}]
set_property PACKAGE_PIN AE13 [get_ports {led[2]}]
set_property PACKAGE_PIN AJ14 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]

## UART/SPI async inputs in this stage
set_false_path -from [get_ports uart_rxd]
set_false_path -from [get_ports spi_miso]

## Async outputs for this bring-up phase
set_false_path -to [get_ports {uart_txd spi_cs_n spi_sck spi_mosi}]
set_false_path -to [get_ports {led[*]}]

## ---------------------------------------------------------------------------
## Power-estimation hygiene (avoid unrealistic default toggle on AXI buses)
## ---------------------------------------------------------------------------
## This helps avoid inflated power report when no SAIF/VCD is provided.
set_switching_activity -static_probability 0.01 -toggle_rate 0.001 [get_ports {\
  s_axi_awaddr[*] s_axi_awprot[*] s_axi_awvalid \
  s_axi_wdata[*]  s_axi_wstrb[*]  s_axi_wvalid  s_axi_bready \
  s_axi_araddr[*] s_axi_arprot[*] s_axi_arvalid s_axi_rready \
}]

set_switching_activity -static_probability 0.01 -toggle_rate 0.001 [get_ports {uart_rxd spi_miso}]

## ---------------------------------------------------------------------------
## Bitstream settings
## ---------------------------------------------------------------------------
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
