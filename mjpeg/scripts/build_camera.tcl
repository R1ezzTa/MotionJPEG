if {$argc!=5} {error "Expected project_root output_directory Synth|Full denoise_enable preprocess_enable"}
lassign $argv project_root output_directory action denoise_enable preprocess_enable
set project_root [file normalize $project_root]
set output_directory [file normalize $output_directory]
cd $project_root
file mkdir $output_directory
set_param general.maxThreads 2
create_project -in_memory -part xc7a35tfgg484-2
set fd [open [file join $project_root scripts camera_sources.txt] r]
set source_list [split [read $fd] \n];close $fd
foreach line $source_list {
    set line [string trim $line]
    if {$line=="" || [string match {#*} $line]} {continue}
    if {[file extension $line]==".v"} {read_verilog [file join $project_root $line]}
}
set_property include_dirs [list $project_root [file join $project_root rtl generated]] [current_fileset]
set profile_xdc [file join $output_directory board_profile.xdc]
file copy [file join $project_root constraints davinci_mjpeg_camera.xdc] $profile_xdc
read_xdc $profile_xdc
synth_design -top davinci_mjpeg_camera_top -part xc7a35tfgg484-2 -generic [list REAL_CAMERA=1 CAMERA_PROFILE=5 DENOISE_ENABLE=$denoise_enable PREPROCESS_ENABLE=$preprocess_enable]
read_xdc [file join $project_root constraints davinci_mjpeg_cdc.xdc]
# No MIG controller, frame-reference transport, application memory or 200 MHz
# reference clock may survive elaboration. One constant pin parks board DRAM.
if {[llength [get_cells -hier -quiet -filter {NAME =~ *memory/controller* || NAME =~ *ddr_spatial_transport* || REF_NAME =~ *mig* || REF_NAME =~ *jpeg_spatial_skip*}]]} {error "Unexpected DDR/interframe hardware"}
set memory_ports [get_ports -quiet ddr3_*]
if {[llength $memory_ports]!=1 || [get_property NAME $memory_ports]!="ddr3_reset_n"} {error "Unexpected DDR ports"}
if {[llength [get_clocks -quiet *ddr*]]} {error "Unexpected DDR clock"}
set rx_ram_clocks [get_pins -hier -filter {REF_PIN_NAME == CLK && NAME =~ *rx_fifo/memory_reg*/CLK}]
set rx_read_registers [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *rx_fifo/m_data_reg*}]
if {![llength $rx_ram_clocks] || [llength $rx_read_registers]!=8} {error "RX RAM CDC endpoints missing"}
set core_registers [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *tx_fifo/wgray_reg*}]
set core_clocks [get_clocks -of_objects [get_pins -of_objects $core_registers -filter {REF_PIN_NAME == C}]]
if {[llength $core_clocks]!=1 || abs([get_property PERIOD $core_clocks]-10.000)>0.001} {error "Expected 100 MHz encoding clock"}
foreach fifo_name {tx_fifo rx_fifo pixel_fifo} {
    foreach pointer {wgray rgray wgray_r1 rgray_w1} {
        if {![llength [get_cells -hier -quiet -filter "NAME =~ *$fifo_name/${pointer}_reg*"]]} {error "Missing CDC pointer $fifo_name/$pointer"}
    }
}
report_clocks -file [file join $output_directory clocks.rpt]
report_io -file [file join $output_directory io.rpt]
write_checkpoint -force [file join $output_directory synthesized.dcp]
report_utilization -file [file join $output_directory utilization_synth.rpt]
report_utilization -hierarchical -file [file join $output_directory utilization_hier.rpt]
report_cdc -details -file [file join $output_directory cdc_synth.rpt]
proc check_cdc {path} {
    set fd [open $path r];set value [read $fd];close $fd
    if {[regexp {CDC-[0-9]+\s+Critical} $value]} {error "Unreviewed critical CDC in $path"}
}
check_cdc [file join $output_directory cdc_synth.rpt]
if {$action=="Synth"} {exit}
opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
phys_opt_design -directive AggressiveExplore
write_checkpoint -force [file join $output_directory routed_before_checks.dcp]
report_utilization -file [file join $output_directory utilization.rpt]
report_utilization -hierarchical -file [file join $output_directory utilization_hier_routed.rpt]
report_timing_summary -file [file join $output_directory timing_routed.rpt]
report_drc -file [file join $output_directory drc_routed.rpt]
report_cdc -details -file [file join $output_directory cdc_routed.rpt]
report_bus_skew -file [file join $output_directory bus_skew.rpt]
report_clock_interaction -file [file join $output_directory clock_interaction.rpt]
report_timing -max_paths 20 -file [file join $output_directory critical_setup.rpt]
check_cdc [file join $output_directory cdc_routed.rpt]
set fd [open [file join $output_directory bus_skew.rpt] r];set skew [read $fd];close $fd
if {[regexp {Slack \(VIOLATED\)} $skew]} {error "CDC bus skew violation"}
foreach delay_type {max min} {
    set paths [get_timing_paths -quiet -delay_type $delay_type -max_paths 1]
    if {![llength $paths] || [get_property SLACK [lindex $paths 0]]<0} {error "Routed $delay_type timing failed"}
}
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]} {error "DRC errors remain"}
if {[llength [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]]} {error "Black boxes remain"}
set t_cells [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *link/tristate_n_reg*}]
set t_paths [get_timing_paths -from $t_cells -to [get_ports {usb_data[*]}] -max_paths 8 -nworst 1]
if {[llength $t_paths]!=8} {error "Missing USB T release paths"}
report_timing -from $t_cells -to [get_ports {usb_data[*]}] -max_paths 8 -nworst 1 -file [file join $output_directory usb_tristate_timing.rpt]
foreach path $t_paths {if {[get_property DATAPATH_DELAY $path]>8.000} {error "USB T release exceeds 8 ns"}}
set fd [open [file join $output_directory utilization.rpt] r];set utilization [read $fd];close $fd
if {![regexp {\|\s*Slice LUTs\s*\|\s*([0-9]+)} $utilization -> used_luts]} {error "Cannot read routed LUT count"}
if {$used_luts>16640} {error "LUT usage exceeds the 80 percent camera headroom budget"}
write_bitstream -force [file join $output_directory davinci_mjpeg_board_test.bit]
set fd [open [file join $output_directory BUILD_PASS.txt] w]
puts $fd "Independent camera 1080p30; no DDR/reference hardware; LUTs $used_luts/20800 <=80%; setup/hold, CDC, bus skew, DRC and USB release passed."
close $fd
