set TOP top_tb

add wave $TOP.dut.bus_if.*
add wave $TOP.dut.u_reg_bank.*
add wave $TOP.dut.u_dma.*
add wave $TOP.dut.u_input_fifo.*
add wave $TOP.dut.u_output_fifo.*
add wave $TOP.dut.u_cim_ctrl.*
add wave $TOP.dut.u_dac.*
add wave $TOP.dut.u_macro.*
add wave $TOP.dut.u_adc.state
add wave $TOP.dut.u_adc.bl_sel
add wave $TOP.dut.u_adc.neuron_in_valid
add wave $TOP.dut.u_lif.*

wave zoom full
