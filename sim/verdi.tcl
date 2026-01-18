set TOP top_tb

add wave -group BUS $TOP.dut.bus_if.*
add wave -group REG $TOP.dut.u_reg_bank.*
add wave -group DMA $TOP.dut.u_dma.*
add wave -group FIFO_IN $TOP.dut.u_input_fifo.*
add wave -group FIFO_OUT $TOP.dut.u_output_fifo.*
add wave -group CIM_CTRL $TOP.dut.u_cim_ctrl.*
add wave -group DAC $TOP.dut.u_dac.*
add wave -group MACRO $TOP.dut.u_macro.*
add wave -group ADC $TOP.dut.u_adc.*
add wave -group LIF $TOP.dut.u_lif.*

wave zoom full
