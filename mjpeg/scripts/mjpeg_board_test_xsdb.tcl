if {$argc != 2} { error "Expected Help|Program|State project_root" }
lassign $argv action project_root
set project_root [file normalize $project_root]
connect -url tcp:127.0.0.1:3122
puts "MJPEG_TEST_JTAG_TARGETS=[jtag targets]"
if {$action eq "Help"} {
    puts "MJPEG_TEST_SYSTEM_TARGETS=[targets]"
    puts [help fpga]
} else {
    set devices [jtag targets -target-properties -filter {name == "xc7a35t"}]
    if {[llength $devices] != 1} { error "Expected exactly one connected XC7A35T." }
    set device [lindex $devices 0]
    if {[dict get $device jtag_cable_serial] ne "210512180081"} {
        error "Connected JTAG cable does not match the previously identified board."
    }
    set device_idcode [string tolower [dict get $device idcode]]
    if {$device_idcode ni {0362d093 0x0362d093}} { error "Unexpected silicon IDCODE: $device_idcode" }
    targets -set -filter {name == "xc7a35t"}

    if {$action eq "Program"} {
        set pointer [open [file join $project_root reports mjpeg_board_test latest_build.txt] r]
        fconfigure $pointer -encoding utf-8
        set output_directory [file normalize [string trim [read $pointer] "\ufeff \t\r\n"]]
        close $pointer
        if {![file exists [file join $output_directory BUILD_PASS.txt]]} { error "Build pass marker missing." }
        set bitstream [file join $output_directory davinci_mjpeg_board_test.bit]
        if {![file exists $bitstream]} { error "Self-test bitstream missing." }
        puts "MJPEG_TEST_PROGRAMMING_BITSTREAM=$bitstream"
        fpga -file $bitstream
    } elseif {$action ne "State"} {
        error "Unknown action: $action"
    }

    set configured [string trim [fpga -state]]
    set configuration_status [fpga -config-status]
    puts "MJPEG_TEST_FPGA_CONFIGURED=$configured"
    puts "MJPEG_TEST_CONFIG_STATUS=$configuration_status"
    if {$action eq "Program"} {
        if {$configured ne "FPGA is configured"} { error "FPGA is not configured after programming." }
        if {![regexp {CONFIG STATUS:\s+([0-9]+)} $configuration_status -> status_word]} {
            error "Unable to parse installed XSDB configuration status."
        }
        if {($status_word & 1) != 0 || ($status_word & (1 << 14)) == 0 || ($status_word & (1 << 4)) == 0} {
            error "Configuration CRC, DONE or EOS check failed."
        }
        set marker [open [file join $output_directory PROGRAM_PASS.txt] w]
        puts $marker "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] JTAG programming succeeded; $configured; CRC ERROR=0, DONE PIN=1, EOS=1. JPEG serial readback checks remain separate."
        close $marker
        puts "MJPEG_TEST_PROGRAM_PASSED=$bitstream"
    }
}
disconnect
exit

