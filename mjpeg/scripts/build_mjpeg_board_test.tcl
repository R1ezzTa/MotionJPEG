if {$argc!=2} {error "Expected project_root output_directory"}
lassign $argv project_root output_directory
set project_root [file normalize $project_root]
set output_directory [file normalize $output_directory]
cd $project_root
file mkdir $output_directory
create_project -in_memory -part xc7a35tfgg484-2
set_param general.maxThreads 2
proc collect_verilog {directory} {
    set result [glob -nocomplain -directory $directory *.v]
    foreach subdir [glob -nocomplain -type d -directory $directory *] {
        set result [concat $result [collect_verilog $subdir]]
    }
    return $result
}
read_verilog [collect_verilog [file join $project_root rtl]]
set_property include_dirs [list $project_root [file join $project_root rtl generated]] [current_fileset]
read_xdc [file join $project_root constraints davinci_mjpeg_board_test.xdc]
synth_design -top davinci_mjpeg_board_test_top -part xc7a35tfgg484-2
report_utilization -file [file join $output_directory utilization_synth.rpt]
opt_design
place_design
route_design
report_utilization -file [file join $output_directory utilization.rpt]
report_timing_summary -file [file join $output_directory timing_routed.rpt]
report_drc -file [file join $output_directory drc_routed.rpt]
foreach delay_type {max min} {
    set paths [get_timing_paths -quiet -delay_type $delay_type -max_paths 1]
    if {[llength $paths]==0} {error "Missing $delay_type timing path"}
    set slack [get_property SLACK [lindex $paths 0]]
    puts "MJPEG_${delay_type}_SLACK=$slack"
    if {$slack<0} {error "Routed $delay_type timing failed"}
}
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]!=0} {error "DRC errors remain"}
if {[llength [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]]!=0} {error "Black boxes remain"}
write_checkpoint -force [file join $output_directory davinci_mjpeg_board_test_routed.dcp]
write_bitstream -force [file join $output_directory davinci_mjpeg_board_test.bit]
set marker [open [file join $output_directory BUILD_PASS.txt] w]
puts $marker "MJPEG board test built; routed setup/hold and DRC passed at 50 MHz."
close $marker
