if {$argc!=10} {error "Expected project_root output_directory SelfTest|Synth|Full camera_profile threshold_enable routed_build|- skip_enable adaptive_enable denoise_enable preprocess_enable"}
lassign $argv project_root output_directory action camera_profile threshold_enable routed_build skip_enable adaptive_enable denoise_enable preprocess_enable
set project_root [file normalize $project_root]
set output_directory [file normalize $output_directory]
cd $project_root
file mkdir $output_directory
set_param general.maxThreads 2
proc collect_verilog {directory} {
    set result [glob -nocomplain -directory $directory *.v]
    foreach subdir [glob -nocomplain -type d -directory $directory *] {set result [concat $result [collect_verilog $subdir]]}
    return $result
}
create_project -in_memory -part xc7a35tfgg484-2
if {$routed_build!="-"} {
    # Hardware inputs and the original script hash were checked by PowerShell.
    # No source, IP or physical constraints are regenerated in this branch.
} elseif {$action=="SelfTest"} {
    foreach file {rtl/top/davinci_ddr3_selftest_top.v rtl/memory/ddr3_selftest_core.v rtl/memory/mjpeg_ddr3_memory.v rtl/memory/ddr3_burst_bridge.v rtl/common/board_test_core_clock.v rtl/usb/board_test_async_fifo.v rtl/usb/board_test_usb_clock_guard.v rtl/usb/board_test_ft245_sync.v} {
        read_verilog [file join $project_root $file]
    }
} else {read_verilog [collect_verilog [file join $project_root rtl]]}
set_property include_dirs [list $project_root [file join $project_root rtl generated]] [current_fileset]
if {$routed_build=="-"} {
    set ip_file [file join $project_root ip ddr3 davinci_ddr3_mig davinci_ddr3_mig.xci]
    if {![file exists $ip_file]} {error "Verified DDR3 IP is missing"}
    read_ip $ip_file
    set ip [get_ips davinci_ddr3_mig]
    generate_target all $ip
    read_verilog [file join $project_root ip ddr3 davinci_ddr3_mig davinci_ddr3_mig_stub.v]
}
set fd [open [file join $project_root constraints davinci_mjpeg_board_test.xdc] r]
set xdc [read $fd]
close $fd
if {$action=="SelfTest"} {
    set top davinci_ddr3_selftest_top
    set reduced ""
    foreach line [split $xdc \n] {
        if {[regexp {^(create_clock|set_property|set_input_delay|set_output_delay|set_clock_uncertainty|set_false_path)} $line] &&
            ![regexp {cam_|key|seg_} $line]} {append reduced "$line\n"}
    }
    append reduced "set_false_path -to \[get_ports {led\[*\] usb_siwu_n}\]\n"
    set xdc $reduced
    set generics {}
} else {
    set top davinci_mjpeg_ddr3_top
    set period [lindex {40.000 20.000 23.500 13.250 13.250 13.250} $camera_profile]
    regsub {create_clock -name cam_clk -period [0-9.]+} $xdc "create_clock -name cam_clk -period $period" xdc
    set generics [list REAL_CAMERA=1 CAMERA_PROFILE=$camera_profile SPATIAL_SKIP=$skip_enable SPATIAL_THRESHOLD=$threshold_enable SPATIAL_ADAPTIVE=$adaptive_enable DENOISE_ENABLE=$denoise_enable PREPROCESS_ENABLE=$preprocess_enable]
}
set profile_xdc [file join $output_directory board_profile.xdc]
# DDR GPIO constraints must be present at top level BEFORE synthesis. Importing
# an OOC stub first otherwise inserts outer I/O buffers and scoped get_ports
# in the checkpoint can resolve to cell pins instead of board ports.
set fd [open [file join $project_root ip ddr3 davinci_ddr3_mig davinci_ddr3_mig user_design constraints davinci_ddr3_mig.xdc] r]
set mig_constraints [read $fd];close $fd
set gpio_constraints "set_property IO_BUFFER_TYPE NONE \[get_ports ddr3_*\]\n"
foreach line [split $mig_constraints \n] {
    if {[regexp {^set_property.*\[get_ports.*ddr3_} $line]} {append gpio_constraints "$line\n"}
}
append xdc $gpio_constraints
set gpio_xdc [file join $output_directory ddr_gpio.xdc]
set fd [open $gpio_xdc w];puts $fd $gpio_constraints;close $fd
set fd [open $profile_xdc w];puts $fd $xdc;close $fd
if {$routed_build=="-"} {
    read_xdc $profile_xdc
    synth_design -top $top -part xc7a35tfgg484-2 -generic $generics
    read_checkpoint -cell memory/controller [file join $project_root ip ddr3 davinci_ddr3_mig davinci_ddr3_mig.dcp]
    read_xdc $gpio_xdc
} else {
    set fd [open [file join $routed_build board_profile.xdc] r];set original_profile [read $fd];close $fd
    set fd [open $profile_xdc r];set current_profile [read $fd];close $fd
    if {$original_profile!=$current_profile} {error "Routed board/clock/GPIO profile changed"}
    open_checkpoint [file join $routed_build routed_before_checks.dcp]
    # The DCP XML top/part and hash were checked before opening. Vivado's
    # in-memory design NAME is "netlist", and fileset TOP is empty after open.
    if {![llength [get_cells -quiet memory/controller]] || ![llength [get_cells -quiet engine/codec]]} {error "Routed DDR3 hierarchy changed"}
}
if {[llength [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]]} {error "DDR3 IP synthesis checkpoint was not loaded"}
set ddr_ports [get_ports ddr3_*]
if {[llength $ddr_ports]!=48} {error "Expected 48 DDR3 board ports"}
foreach port $ddr_ports {
    if {[get_property PACKAGE_PIN $port]=="" || [get_property IOSTANDARD $port]=="DEFAULT"} {error "DDR3 port constraints missing: $port"}
}
foreach port [get_ports {ddr3_ck_p[*] ddr3_ck_n[*]}] {
    if {[get_property IOSTANDARD $port]!="DIFF_SSTL15"} {error "DDR3 CK voltage mismatch"}
}
report_io -file [file join $output_directory io.rpt]
report_clocks -file [file join $output_directory clocks.rpt]
write_checkpoint -force [file join $output_directory synthesized.dcp]
report_utilization -file [file join $output_directory utilization_synth.rpt]
report_utilization -hierarchical -file [file join $output_directory utilization_hier.rpt]
if {$routed_build!="-"} {
    # Reuse all physical constraints stored in the routed checkpoint.
} elseif {$action=="SelfTest"} {
    set_false_path -to [get_pins -hier -regexp {.*clock_guard/heartbeat_sync_reg\[0\]/D}]
    set_false_path -to [get_pins -hier -regexp {.*(usb_reset_pipe|reset_pipe)_reg\[.*\]/CLR}]
    foreach pointer {wgray rgray} first_sync {wgray_r1 rgray_w1} {
        set start [get_cells -hier -filter "IS_SEQUENTIAL == 1 && (NAME =~ *tx_fifo/${pointer}_reg* || NAME =~ *tx_fifo/[string map {gray bin} $pointer]_reg*)"]
        set finish [get_cells -hier -filter "IS_SEQUENTIAL == 1 && NAME =~ *tx_fifo/${first_sync}_reg*"]
        set_max_delay -datapath_only 10.000 -from $start -to $finish
        set_bus_skew 10.000 -from $start -to $finish
    }
    set_multicycle_path 2 -setup -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *link/tristate_n_reg*}] -to [get_ports {usb_data[*]}]
    set_multicycle_path 1 -hold -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *link/tristate_n_reg*}] -to [get_ports {usb_data[*]}]
} else {read_xdc [file join $project_root constraints davinci_mjpeg_cdc.xdc]}
set ddr_transactions_required [expr {$action=="SelfTest" || $skip_enable!=0}]
if {$routed_build=="-"} {source [file join $project_root scripts ddr3_cdc.tcl]}
report_cdc -details -file [file join $output_directory cdc_synth.rpt]
if {$action=="Synth"} {exit}
if {$routed_build=="-"} {
    opt_design -directive Explore
    place_design -directive Explore
    phys_opt_design -directive AggressiveExplore
    route_design -directive Explore
    phys_opt_design -directive AggressiveExplore
}
write_checkpoint -force [file join $output_directory routed_before_checks.dcp]
report_utilization -file [file join $output_directory utilization.rpt]
report_timing_summary -file [file join $output_directory timing_routed.rpt]
report_drc -file [file join $output_directory drc_routed.rpt]
report_cdc -details -file [file join $output_directory cdc_routed.rpt]
report_bus_skew -file [file join $output_directory bus_skew.rpt]
report_clock_interaction -file [file join $output_directory clock_interaction.rpt]
report_timing -max_paths 20 -file [file join $output_directory critical_setup.rpt]
set fd [open [file join $output_directory bus_skew.rpt] r];set skew_text [read $fd];close $fd
if {[regexp {Slack \(VIOLATED\)} $skew_text]} {error "DDR3 FIFO/USB/camera bus skew violated"}
set fd [open [file join $output_directory cdc_routed.rpt] r];set cdc_text [read $fd];close $fd
set reviewed_vendor_resets 0
set reviewed_fifo_data 0
foreach line [split $cdc_text \n] {
    if {[regexp {^\s*[0-9]+\s+CDC-[0-9]+\s+Critical\s+} $line]} {
        # MIG infrastructure uses rst_tmp for asynchronous assertion and
        # shifts zeros through rst_sync_r/rstdiv0_sync_r/rstdiv2_sync_r for
        # synchronous release in each clock domain. Only these PRE entrances
        # are covered by the vendor common-reset review.
        if {[regexp {memory/controller/.*/(rst_sync_r_reg|rstdiv0_sync_r_reg|rstdiv2_sync_r_reg).*?/PRE} $line]} {
            incr reviewed_vendor_resets
        } elseif {$action=="SelfTest" &&
                  [regexp {^\s*[0-9]+\s+CDC-1\s+Critical.*Max Delay Datapath Only\s+memory/bridge/read_fifo/memory_reg[^ ]*/RAM[A-D]/CLK\s+(memory/bridge/(busy|done|read_consumed)_reg/D|tester/(FSM_sequential_state|state|beat|errors|first_bad_addr|first_expected|first_observed)_reg(\[[0-9]+\])?/CE)\s*$} $line]} {
            # FWFT data and last-bit are immutable until consumed; the write
            # pointer crosses two Gray synchronizer stages before r_valid.
            # These exact read consumers are bounded to 10 ns in ddr3_cdc.tcl.
            # Full camera consumers require their own routed CDC review.
            incr reviewed_fifo_data
        } elseif {$action=="Full" &&
                  [regexp {^\s*[0-9]+\s+CDC-1\s+Critical.*Max Delay Datapath Only\s+memory/bridge/read_fifo/memory_reg_0_63_126_128/RAMC/CLK\s+memory/bridge/(busy|done|read_consumed)_reg/D\s*$} $line]} {
            incr reviewed_fifo_data
        } elseif {$action=="Full" &&
                  [regexp {^\s*[0-9]+\s+CDC-13\s+Critical.*Max Delay Datapath Only\s+memory/bridge/read_fifo/memory_reg_0_63_([0-9]+)_([0-9]+)/RAM[ABC]/CLK\s+engine/codec/encoder/channels\[0\]\.channel/ddr_spatial_transport\.skip/reference_ram_reg_[01]/(DIADI|DIBDI|DIPADIP|DIPBDIP)\[([0-9]+)\]\s*$} $line -> lower upper pin bit] &&
                  $lower%3==0 && $upper==$lower+2 && $upper<=128 &&
                  (($pin=="DIADI" || $pin=="DIBDI")?$bit<32:$bit<4)} {
            # Cache writes reference BRAM only in READ_TRANSFER with r_valid,
            # r_ready and !recovering. No address/WE/clock CDC is accepted.
            incr reviewed_fifo_data
        } else {
            error "Unreviewed critical CDC: $line"
        }
    }
}
puts "DDR3_REVIEWED_VENDOR_RESET_CDC=$reviewed_vendor_resets"
puts "DDR3_REVIEWED_FIFO_DATA_CDC=$reviewed_fifo_data"
foreach type {max min} {
    set paths [get_timing_paths -delay_type $type -max_paths 1]
    if {![llength $paths] || [get_property SLACK [lindex $paths 0]]<0} {error "DDR3 routed $type timing failed"}
}
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]} {error "DDR3 DRC errors remain"}
if {[llength [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]]} {error "DDR3 black boxes remain"}
set t_cells [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *link/tristate_n_reg*}]
set t_paths [get_timing_paths -from $t_cells -to [get_ports {usb_data[*]}] -max_paths 8 -nworst 1]
if {[llength $t_paths]!=8} {error "Missing USB T release paths"}
foreach path $t_paths {if {[get_property DATAPATH_DELAY $path]>8.000} {error "USB T release exceeds 8ns"}}
# Accepted critical CDCs are common-reset entrances and the specifically
# reviewed, bounded FWFT RAM data consumers above. All others fail the build.
write_bitstream -force [file join $output_directory davinci_mjpeg_board_test.bit]
set fd [open [file join $output_directory BUILD_PASS.txt] w]
puts $fd "DDR3 $action built; setup/hold/DRC/USB T/bus skew passed; CDC reviewed: vendor resets $reviewed_vendor_resets, bounded FIFO data $reviewed_fifo_data"
close $fd
