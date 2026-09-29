set root F:/zju/dasanshangkecheng/HDL
set iproot [file join $root mjpeg ip ddr3]
set probe [file join $root work ddr3_20260928]
create_project -force ddr3_final_probe [file join $probe final_project] -part xc7a35tfgg484-2
set_property target_language Verilog [current_project]
create_ip -name mig_7series -vendor xilinx.com -library ip -version 4.2 -module_name davinci_ddr3_mig -dir $iproot
set_property CONFIG.XML_INPUT_FILE [file join $iproot davinci_mig_lite.prj] [get_ips davinci_ddr3_mig]
generate_target all [get_ips davinci_ddr3_mig]
set_param project.vivado.isBlockSynthRun true
set_param synth.vivado.isSynthRun true
synth_design -top davinci_ddr3_mig -part xc7a35tfgg484-2 -mode out_of_context
report_utilization -file [file join $probe mig_final_utilization.rpt]
report_utilization -hierarchical -file [file join $probe mig_final_utilization_hierarchical.rpt]
report_timing_summary -file [file join $probe mig_final_timing.rpt]
write_checkpoint -force [file join $iproot davinci_ddr3_mig davinci_ddr3_mig.dcp]
write_verilog -force -mode synth_stub [file join $iproot davinci_ddr3_mig davinci_ddr3_mig_stub.v]
puts MIG_FINAL_SYNTH_PASS
