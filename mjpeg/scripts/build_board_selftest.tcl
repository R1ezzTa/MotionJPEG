if {$argc != 2} { error "Expected project_root output_directory" }
lassign $argv project_root output_directory
set project_root [file normalize $project_root]
set output_directory [file normalize $output_directory]
file mkdir $output_directory
create_project -in_memory -part xc7a35tfgg484-2
set_param general.maxThreads 2
read_verilog [file join $project_root rtl top davinci_board_selftest_top.v]
read_xdc [file join $project_root constraints davinci_board_selftest.xdc]
synth_design -top davinci_board_selftest_top -part xc7a35tfgg484-2
opt_design
place_design
route_design
report_utilization -file [file join $output_directory utilization.rpt]
report_timing_summary -file [file join $output_directory timing_routed.rpt]
report_drc -file [file join $output_directory drc_routed.rpt]

foreach delay_type {max min} {
    set timing_paths [get_timing_paths -quiet -delay_type $delay_type -max_paths 1]
    if {[llength $timing_paths] == 0} { error "No $delay_type timing path found." }
    set slack [get_property SLACK [lindex $timing_paths 0]]
    puts "SELFTEST_${delay_type}_SLACK=$slack"
    if {$slack < 0} { error "Routed $delay_type timing failed." }
}
set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
if {[llength $drc_errors] != 0} { error "Routed DRC errors remain: $drc_errors" }
write_checkpoint -force [file join $output_directory davinci_board_selftest_routed.dcp]
write_bitstream -force [file join $output_directory davinci_board_selftest.bit]
set marker [open [file join $output_directory BUILD_PASS.txt] w]
puts $marker "Davinci board LED/key test: routed timing and DRC gates passed; bitstream generated."
close $marker
puts "SELFTEST_BUILD_PASSED=$output_directory"
