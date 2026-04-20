# v2b_top.xdc — minimal constraints for synthesis-only pass
#
# Only a clock period constraint. No pin mapping (pins irrelevant for
# synthesis-only). Clock period 10 ns = 100 MHz — realistic target for
# Artix-7 / Zynq prototype.
#
# If your target board differs, swap the period and re-run.

create_clock -name clk -period 10.000 -waveform {0.000 5.000} [get_ports clk]

# Input delay / output delay constraints intentionally omitted for
# synthesis-only pass. Will be added for P&R.

# Don't sweat this at synth time — suppress "loop iteration limit" style
# chatter that's not useful for first-pass assessment.
set_msg_config -severity INFO -suppress
