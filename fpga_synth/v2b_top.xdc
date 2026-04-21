# v2b_top.xdc - minimal constraints for synthesis + implementation pass
#
# Only a clock period constraint. No pin mapping (pins irrelevant for
# standalone resource/timing checks). Clock period 20 ns = 50 MHz, matching
# the original SoC/RTL operating target.
#
# If your target board differs, swap the period and re-run.

create_clock -name clk -period 20.000 -waveform {0.000 10.000} [get_ports clk]

# Input delay / output delay constraints intentionally omitted for
# synthesis-only pass. Will be added for P&R.
