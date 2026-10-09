lassign $argv action build_directory
connect -url tcp:127.0.0.1:3122
set devices [jtag targets -target-properties -filter {name == "xc7a35t"}]
if {[llength $devices]!=1} {error "Expected one connected XC7A35T"}
targets -set -filter {name == "xc7a35t"}
if {$action eq "Program"} {
    fpga -file [file join $build_directory davinci_mjpeg_camera.bit]
}
set configured [string trim [fpga -state]]
set configuration_status [fpga -config-status]
puts $configured
puts $configuration_status
if {$action eq "Program"} {
    if {$configured ne "FPGA is configured"} {error "FPGA is not configured"}
    regexp {CONFIG STATUS:\s+([0-9]+)} $configuration_status -> status_word
    if {($status_word & 1)!=0 || ($status_word & (1<<14))==0 || ($status_word & (1<<4))==0} {
        error "Configuration CRC, DONE or EOS check failed"
    }
    set marker [open [file join $build_directory PROGRAM_PASS.txt] w]
    puts $marker "JTAG programmed; CRC ERROR=0, DONE=1, EOS=1"
    close $marker
}
disconnect
exit
