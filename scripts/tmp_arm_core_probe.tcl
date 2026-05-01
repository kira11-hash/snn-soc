connect
targets -set -filter {name =~ "Cortex-A53 #0"}
stop
puts "TARGETS"
puts [targets]
puts "REGS"
rrd
exit
