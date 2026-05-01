connect
targets -set -filter {name =~ "PSU"}
puts "PROGRESS_MARKERS"
puts [mrd -value 0xFFFD3DA8 4]
exit
