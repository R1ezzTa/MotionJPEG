# Applied after synthesis; source this Tcl so conditional groups are supported.
if {![info exists ddr_transactions_required]} {set ddr_transactions_required 1}
proc ddr_bound_gray {fifo source sync1 clock_pin} {
    set start [get_cells -hier -quiet -filter "IS_SEQUENTIAL == 1 && (NAME =~ *$fifo/${source}_reg* || NAME =~ *$fifo/[string map {gray binary} $source]_reg*)"]
    set finish [get_cells -hier -quiet -filter "IS_SEQUENTIAL == 1 && NAME =~ *$fifo/${sync1}_reg*"]
    if {[llength $start]==0 || [llength $finish]==0} {error "Missing Gray CDC endpoints $fifo $source"}
    set clocks [get_clocks -of_objects [get_pins -of_objects $start -filter {REF_PIN_NAME == C}]]
    set period [get_property PERIOD [lindex $clocks 0]]
    set_max_delay -datapath_only $period -from $start -to $finish
    set_bus_skew $period -from $start -to $finish
}
foreach fifo {memory/bridge/write_fifo memory/bridge/read_fifo} {
    if {$ddr_transactions_required} {
        ddr_bound_gray $fifo wr_gray wr_gray_sync1 C
        ddr_bound_gray $fifo rd_gray rd_gray_sync1 C
    }
}
# Bundled command fields are held until terminal acknowledgment, and sampled
# only after the request toggle has crossed two destination-domain flops.
set bundle_source [get_cells -hier -quiet -filter {IS_SEQUENTIAL == 1 && (NAME =~ *memory/bridge/request_addr_reg* || NAME =~ *memory/bridge/request_bytes_reg* || NAME =~ *memory/bridge/request_write_reg*)}]
set bundle_target [get_cells -hier -quiet -filter {IS_SEQUENTIAL == 1 && (NAME =~ *memory/bridge/ui_base_reg* || NAME =~ *memory/bridge/ui_words_reg* || NAME =~ *memory/bridge/ui_write_reg*)}]
if {$ddr_transactions_required} {
    if {![llength $bundle_source] || ![llength $bundle_target]} {error "Missing DDR3 bundled command endpoints"}
    set_max_delay -datapath_only 10.000 -from $bundle_source -to $bundle_target
} elseif {[llength $bundle_source] || [llength $bundle_target]} {
    error "Independent JPEG unexpectedly retains DDR3 application commands"
} else {
    puts "DDR3_APPLICATION_TRANSACTIONS_REMOVED: no command bundle or reference transfer"
}
set_false_path -to [get_pins -hier -regexp {.*memory/bridge/(request_sync1|completion_sync1|fault_sync1|calibrated_sync1|ui_rst_sync1|ui_reset_release_sync1|local_fault_sync1)_reg/D}]
set_false_path -to [get_pins -hier -regexp {.*(codec_reset_pipe|ui_reset_pipe)_reg\[.*\]/CLR}]
# Each asynchronous RAM location is read only after the committed write
# pointer has crossed its synchronizer. Bound clock-to-data in one read cycle.
foreach fifo {memory/bridge/write_fifo memory/bridge/read_fifo} {
    set ram_clocks [get_pins -hier -quiet -filter "REF_PIN_NAME == CLK && NAME =~ *$fifo/memory_reg*/CLK"]
    set targets [get_cells -hier -quiet -filter "IS_SEQUENTIAL == 1 && (NAME =~ *memory/bridge/* || NAME =~ *memory/controller/* || NAME =~ *engine/* || NAME =~ *tester/*)"]
    if {$ddr_transactions_required} {
        if {![llength $ram_clocks]} {error "DDR3 FIFO RAM inference/CDC endpoints missing: $fifo"}
        set_max_delay -datapath_only 10.000 -from $ram_clocks -to $targets
    } elseif {[llength $ram_clocks]} {
        error "Independent JPEG unexpectedly retains DDR3 FIFO RAM: $fifo"
    }
}
