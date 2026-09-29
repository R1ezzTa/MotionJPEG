set root F:/zju/dasanshangkecheng/HDL
set iproot [file join $root mjpeg ip ddr3]
set probe [file join $root work ddr3_20260928]
create_project -force ddr3_probe [file join $probe project] -part xc7a35tfgg484-2
set_property target_language Verilog [current_project]
create_ip -name mig_7series -vendor xilinx.com -library ip -version 4.2 -module_name mig_7series_0 -dir $iproot
set_property CONFIG.XML_INPUT_FILE [file join $iproot davinci_mig.prj] [get_ips mig_7series_0]
generate_target all [get_ips mig_7series_0]
export_ip_user_files -of_objects [get_ips mig_7series_0] -no_script -sync -force
create_ip_run [get_ips mig_7series_0]
launch_runs mig_7series_0_synth_1 -jobs 4
wait_on_run mig_7series_0_synth_1
if {[get_property STATUS [get_runs mig_7series_0_synth_1]] ne "synth_design Complete!"} { error "MIG OOC synthesis failed" }
open_run mig_7series_0_synth_1
report_utilization -file [file join $probe mig_utilization.rpt]
report_utilization -hierarchical -file [file join $probe mig_utilization_hierarchical.rpt]
report_timing_summary -file [file join $probe mig_timing.rpt]
write_checkpoint -force [file join $probe mig_synthesized.dcp]
puts MIG_GENERATION_SYNTH_PASS
