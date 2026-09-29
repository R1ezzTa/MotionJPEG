# Activate the current DDR-free camera source set in the existing GUI project.
# Run with Vivado -mode batch -source scripts/activate_camera.tcl.
set project_root [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $project_root mjpeg.xpr]
if {[get_property PART [current_project]]!="xc7a35tfgg484-2"} {error "Wrong board device"}
set fd [open [file join $project_root scripts camera_sources.txt] r]
set lines [split [read $fd] \n];close $fd
set wanted {}
foreach line $lines {
    set line [string trim $line]
    if {$line=="" || [string match {#*} $line]} {continue}
    lappend wanted [file normalize [file join $project_root $line]]
}
foreach name {pixels.mem quant.mem camera_quant.mem} {
    lappend wanted [file normalize [file join $project_root data board_test $name]]
}
foreach file [get_files -of_objects [get_filesets sources_1]] {
    if {[lsearch -exact $wanted [file normalize [get_property NAME $file]]]<0} {remove_files $file}
}
foreach file $wanted {
    if {![llength [get_files -quiet $file]]} {add_files -fileset sources_1 -norecurse $file}
    if {[file extension $file]==".vh"} {set_property FILE_TYPE {Verilog Header} [get_files $file]}
}
foreach file [get_files -of_objects [get_filesets constrs_1]] {remove_files $file}
add_files -fileset constrs_1 -norecurse [file join $project_root constraints davinci_mjpeg_camera.xdc]
set cdc [file join $project_root constraints davinci_mjpeg_cdc.xdc]
add_files -fileset constrs_1 -norecurse $cdc
set_property USED_IN_SYNTHESIS false [get_files $cdc]
set_property INCLUDE_DIRS [list $project_root [file join $project_root rtl generated]] [get_filesets sources_1]
set_property TOP_AUTO_SET false [get_filesets sources_1]
set_property TOP davinci_mjpeg_camera_top [get_filesets sources_1]
set_property GENERIC {REAL_CAMERA=1 CAMERA_PROFILE=5 DENOISE_ENABLE=1 PREPROCESS_ENABLE=1} [get_filesets sources_1]
# Preprocessing benches generate vectors through their explicit simulation
# scripts; preserve the existing integrated-camera GUI simulation entry.
foreach name {tb_yuv422_preprocess.sv tb_spatial_denoise_yuv.sv} {
    set file [file join $project_root tb $name]
    if {![llength [get_files -quiet $file]]} {add_files -fileset sim_1 -norecurse $file}
}
set_property TOP tb_mjpeg_real_camera [get_filesets sim_1]
set_property GENERIC {} [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
report_compile_order -fileset sources_1 -used_in synthesis -file [file join $project_root reports camera_compile_order.rpt]
close_project
puts "CAMERA_PROJECT_ACTIVE: independent 1080p30, spatial denoise and preprocessing, no MIG/DDR reference"
