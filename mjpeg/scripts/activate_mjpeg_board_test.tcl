# Add the board test to the user's existing project; does not launch any run.
set task_batch [expr {[info exists argv] && [lsearch -exact $argv --batch]>=0}]
set task_argv $argv
set argv {}
source [file join [file dirname [info script]] import_sources.tcl]
set argv $task_argv
set_property TOP davinci_mjpeg_board_test_top [get_filesets sources_1]
set_property GENERIC {} [get_filesets sources_1]
foreach task_mem {pixels.mem quant.mem} {
    set task_path [file join $project_root data board_test $task_mem]
    if {[llength [get_files -quiet $task_path]]==0} {add_files -fileset sources_1 -norecurse $task_path}
}
set task_xdc [file join $project_root constraints davinci_mjpeg_board_test.xdc]
if {[llength [get_files -quiet $task_xdc]]==0} {add_files -fileset constrs_1 -norecurse $task_xdc}
set task_cdc_xdc [file join $project_root constraints davinci_mjpeg_cdc.xdc]
if {[llength [get_files -quiet $task_cdc_xdc]]==0} {add_files -fileset constrs_1 -norecurse $task_cdc_xdc}
set_property USED_IN_SYNTHESIS false [get_files $task_cdc_xdc]
set task_tb [file join $project_root tb tb_davinci_mjpeg_fifo_test.sv]
if {[llength [get_files -quiet $task_tb]]==0} {add_files -fileset sim_1 -norecurse $task_tb}
set task_tb [file join $project_root tb tb_fps_peripherals.sv]
if {[llength [get_files -quiet $task_tb]]==0} {add_files -fileset sim_1 -norecurse $task_tb}
set task_tb [file join $project_root tb tb_mjpeg_progressive.sv]
if {[llength [get_files -quiet $task_tb]]==0} {add_files -fileset sim_1 -norecurse $task_tb}
foreach task_tb_name {tb_mjpeg_payload_coalescer.sv tb_mjpeg_core_throughput.sv tb_mjpeg_block_transport.sv tb_board_test_async_fifo.sv tb_davinci_mjpeg_sync_test.sv} {
    set task_tb [file join $project_root tb $task_tb_name]
    if {[llength [get_files -quiet $task_tb]]==0} {add_files -fileset sim_1 -norecurse $task_tb}
}
set_property TOP tb_davinci_mjpeg_sync_test [get_filesets sim_1]
set_property GENERIC {} [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
report_compile_order -fileset sources_1 -used_in synthesis -file [file join $project_root reports board_test_compile_order.rpt]
puts "BOARD_TEST_PROJECT_ACTIVE: davinci_mjpeg_board_test_top, MMCM core 100 MHz / USB_SLAVE FT245 sync 60 MHz, CDC buffers"
if {$task_batch} {close_project}
