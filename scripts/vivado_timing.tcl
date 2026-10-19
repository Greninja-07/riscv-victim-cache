cd [file normalize [file join [file dirname [info script]] ..]]
set part xc7a100tcsg324-1
set files [glob rtl/core/*.v]
read_verilog -sv $files
set_property include_dirs [list rtl/core] [current_fileset]
synth_design -top pipe -part $part -mode out_of_context -include_dirs rtl/core
create_clock -period 20.000 -name clk [get_ports clk]
report_utilization -file scratch/utilization_synth.rpt
opt_design
place_design
route_design
report_timing_summary -file scratch/timing_summary.rpt
report_timing -max_paths 5 -file scratch/timing_paths.rpt
report_utilization -file scratch/utilization.rpt
report_methodology -file scratch/methodology.rpt