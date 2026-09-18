# Run with source in the Vivado Tcl Console, or pass --batch from the CLI.
set project_root [file normalize [file join [file dirname [info script]] ..]]
set project_file [file join $project_root mjpeg.xpr]
set batch_mode [expr {[info exists argv] && [lsearch -exact $argv --batch] >= 0}]

proc collect_design_sources {directory} {
    set result {}
    foreach item [lsort [glob -nocomplain -directory $directory *]] {
        if {[file isdirectory $item]} {
            set result [concat $result [collect_design_sources $item]]
        } elseif {[file extension $item] in {.v .vh}} {
            lappend result $item
        }
    }
    return $result
}

if {[current_project -quiet] eq ""} {
    open_project $project_file
}
if {[file normalize [get_property DIRECTORY [current_project]]] ne $project_root} {
    error "Open mjpeg/mjpeg.xpr before importing these sources."
}
if {[get_property PART [current_project]] ne "xc7a35tfgg484-2"} {
    error "Expected the Davinci xc7a35tfgg484-2 project."
}

set source_files [collect_design_sources [file join $project_root rtl]]
if {[llength $source_files] == 0} { error "No RTL sources found." }
foreach source_file $source_files {
    if {[llength [get_files -quiet $source_file]] == 0} {
        add_files -fileset sources_1 -norecurse $source_file
    }
    if {[file extension $source_file] eq ".vh"} {
        set_property FILE_TYPE {Verilog Header} [get_files $source_file]
    }
}
set_property TARGET_LANGUAGE Verilog [current_project]
set_property SIMULATOR_LANGUAGE Mixed [current_project]
set_property INCLUDE_DIRS [list $project_root [file join $project_root rtl generated]] [get_filesets sources_1]
set_property TOP_AUTO_SET false [get_filesets sources_1]
set_property TOP mjpeg_synth_top [get_filesets sources_1]
# This top is for module integration/analysis; it is not the physical board top.
set_property GENERIC [list CHANNELS=1 MAX_WIDTH=1920] [get_filesets sources_1]
update_compile_order -fileset sources_1
file mkdir [file join $project_root reports]
report_compile_order -fileset sources_1 -used_in synthesis -file [file join $project_root reports import_compile_order.rpt]
puts "IMPORT_SOURCES_COMPLETE: [llength $source_files] files, xc7a35tfgg484-2, CHANNELS=1, MAX_WIDTH=1920"
if {$batch_mode} {
    close_project
}
