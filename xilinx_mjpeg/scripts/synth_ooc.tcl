# Out-of-context synthesis only. No pin assignment or board bitstream.
# Required args: part channels max_width clock_period_ns
if {$argc != 4} { error "Expected: part channels max_width clock_period_ns" }
lassign $argv part channels max_width period
if {![string is integer -strict $channels] || $channels < 1 || $channels > 4} {
    error "channels must be 1..4"
}
if {![string is integer -strict $max_width] || $max_width < 16 || $max_width % 16} {
    error "max_width must be a positive multiple of 16"
}
if {![string is double -strict $period] || $period <= 0} { error "Invalid clock period" }
proc rtl_files {dir} {
    set result [glob -nocomplain -directory $dir *.v]
    foreach subdir [glob -nocomplain -type d -directory $dir *] {
        set result [concat $result [rtl_files $subdir]]
    }
    return [lsort $result]
}
create_project -in_memory -part $part
# Keep these reference resource evaluations modest in CPU usage.
set_param general.maxThreads 1
set_param synth.maxThreads 1
set_property include_dirs [list [pwd]] [current_fileset]
read_verilog [rtl_files rtl]
# Load the clock before synthesis so it can guide timing optimization.
set clock_file [open core_clock.xdc w]
puts $clock_file [format {create_clock -name core_clk -period %s [get_ports clk]} $period]
close $clock_file
read_xdc core_clock.xdc
synth_design -top mjpeg_synth_top -part $part -mode out_of_context \
    -generic [list CHANNELS=$channels MAX_WIDTH=$max_width]
report_utilization -file utilization.rpt
report_utilization -hierarchical -file utilization_hierarchy.rpt
report_timing_summary -file timing_synthesis.rpt
report_drc -file drc_synthesis.rpt
if {[llength [get_cells -hierarchical -filter {IS_BLACKBOX == 1}]] != 0} {
    error "Unresolved black boxes remain"
}
write_checkpoint -force mjpeg_ooc.dcp
set result [open SYNTHESIS_COMPLETE.txt w]
puts $result "OOC synthesis complete: $part, CHANNELS=$channels, MAX_WIDTH=$max_width, period=$period ns"
puts $result "Clock XDC loaded before synthesis."
puts $result "Not a routed timing pass or board-ready bitstream. Inspect resource utilization."
close $result
