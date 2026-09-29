if {$argc<4 || $argc>6} {error "Expected project_root output_directory synthesis_checkpoint camera_profile ?spatial_skip? ?spatial_threshold?"}
lassign $argv project_root output_directory synthesis_checkpoint camera_profile spatial_skip spatial_threshold
if {$spatial_skip==""} {set spatial_skip 0}
if {$spatial_threshold==""} {set spatial_threshold 0}
if {$spatial_threshold!=0 && $spatial_threshold!=1} {error "Invalid spatial threshold mode"}
if {$spatial_threshold && !$spatial_skip} {error "Threshold requires spatial skip"}
if {$spatial_skip!=0 && $spatial_skip!=1} {error "Invalid spatial skip mode"}
if {$synthesis_checkpoint=="-"} {set synthesis_checkpoint ""}
if {$camera_profile<0 || $camera_profile>5} {error "Unsupported camera profile"}
set project_root [file normalize $project_root]
set output_directory [file normalize $output_directory]
cd $project_root
file mkdir $output_directory
set_param general.maxThreads 2
set cam_period [lindex {40.000 20.000 23.500 13.250 13.250 13.250} $camera_profile]
set fd [open [file join $project_root constraints davinci_mjpeg_board_test.xdc] r]
set board_constraints [read $fd]
close $fd
regsub {create_clock -name cam_clk -period [0-9.]+} $board_constraints "create_clock -name cam_clk -period $cam_period" board_constraints
set profile_xdc [file join $output_directory board_profile.xdc]
set fd [open $profile_xdc w]
puts $fd $board_constraints
close $fd
puts "CAMERA_PROFILE=$camera_profile CAM_CONSTRAINED_PERIOD=$cam_period"
proc collect_verilog {directory} {
    set result [glob -nocomplain -directory $directory *.v]
    foreach subdir [glob -nocomplain -type d -directory $directory *] {
        set result [concat $result [collect_verilog $subdir]]
    }
    return $result
}
if {$synthesis_checkpoint!=""} {
    open_checkpoint $synthesis_checkpoint
    reset_timing
    read_xdc $profile_xdc
} else {
    create_project -in_memory -part xc7a35tfgg484-2
    read_verilog [collect_verilog [file join $project_root rtl]]
    set_property include_dirs [list $project_root [file join $project_root rtl generated]] [current_fileset]
    read_xdc $profile_xdc
    synth_design -top davinci_mjpeg_board_test_top -part xc7a35tfgg484-2 -generic [list REAL_CAMERA=1 CAMERA_PROFILE=$camera_profile SPATIAL_SKIP=$spatial_skip SPATIAL_THRESHOLD=$spatial_threshold]
}
read_xdc [file join $project_root constraints davinci_mjpeg_cdc.xdc]
set rx_ram_clocks [get_pins -hier -filter {REF_PIN_NAME == CLK && NAME =~ *rx_fifo/memory_reg*/CLK}]
set rx_read_registers [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *rx_fifo/m_data_reg*}]
if {[llength $rx_ram_clocks]==0 || [llength $rx_read_registers]!=8} {
    error "RX distributed RAM CDC endpoints are missing"
}
set core_registers [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *tx_fifo/wgray_reg*}]
set core_clocks [get_clocks -of_objects [get_pins -of_objects $core_registers -filter {REF_PIN_NAME == C}]]
if {[llength $core_clocks]!=1 || abs([get_property PERIOD $core_clocks]-10.000)>0.001} {
    error "Encoding clock must be MMCM-derived 100MHz"
}
report_clocks -file [file join $output_directory clocks.rpt]
puts "CORE_CLOCK_PERIOD_NS=[get_property PERIOD $core_clocks]"
foreach fifo_name {tx_fifo rx_fifo} {
    foreach pointer {wgray rgray wgray_r1 rgray_w1} {
        if {[llength [get_cells -hier -filter "NAME =~ *$fifo_name/${pointer}_reg*"]]==0} {
            error "CDC constraint register group is missing: $fifo_name/$pointer"
        }
    }
}
write_checkpoint -force [file join $output_directory synthesized.dcp]
report_cdc -details -file [file join $output_directory cdc_synth.rpt]
set cdc_handle [open [file join $output_directory cdc_synth.rpt] r]
set cdc_text [read $cdc_handle]
close $cdc_handle
if {[regexp {CDC-[0-9]+\s+Critical} $cdc_text]} {
    error "Critical CDC before implementation; inspect cdc_synth.rpt"
}
report_utilization -file [file join $output_directory utilization_synth.rpt]
opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
phys_opt_design -directive AggressiveExplore
write_checkpoint -force [file join $output_directory routed_before_checks.dcp]
report_utilization -file [file join $output_directory utilization.rpt]
report_timing_summary -file [file join $output_directory timing_routed.rpt]
report_drc -file [file join $output_directory drc_routed.rpt]
report_cdc -details -file [file join $output_directory cdc_routed.rpt]
report_clock_interaction -file [file join $output_directory clock_interaction.rpt]
report_bus_skew -file [file join $output_directory bus_skew.rpt]
report_timing -from $rx_ram_clocks -to $rx_read_registers -max_paths 8 -nworst 1 \
    -file [file join $output_directory rx_ram_cdc_timing.rpt]
report_timing -max_paths 20 -nworst 1 -file [file join $output_directory critical_setup.rpt]
set t_cells [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *link/tristate_n_reg*}]
if {[llength $t_cells]!=8} {error "Expected eight independent I/O T registers"}
set t_paths [get_timing_paths -from $t_cells -to [get_ports {usb_data[*]}] -max_paths 8 -nworst 1]
if {[llength $t_paths]!=8} {error "Missing tri-state release timing paths"}
report_timing -from $t_cells -to [get_ports {usb_data[*]}] -max_paths 8 -nworst 1 \
    -file [file join $output_directory usb_tristate_timing.rpt]
foreach path $t_paths {
    set transit [get_property DATAPATH_DELAY $path]
    puts "USB_T_RELEASE_DATAPATH_NS=$transit"
    if {$transit=="" || $transit>8.000} {error "T release cannot settle before next-cycle OE"}
}
foreach report_name {cdc_routed.rpt bus_skew.rpt} {
    set report_handle [open [file join $output_directory $report_name] r]
    set report_text [read $report_handle]
    close $report_handle
    if {[regexp {CDC-[0-9]+\s+Critical|Slack \(VIOLATED\)} $report_text]} {
        error "Critical CDC or bus skew violation in $report_name"
    }
}
puts "USB_CLK_PIN_FUNCTION=[get_property PIN_FUNC [get_package_pins Y4]]"
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
puts $marker "MJPEG board test built; MMCM core 100MHz / synchronous FT245 60MHz; routed setup/hold, CDC, bus skew and DRC passed."
close $marker
