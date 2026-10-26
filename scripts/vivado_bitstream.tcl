# ==============================================================================
# Vivado Bitstream Generation TCL Script for RVM32I / Nexys A7 100T
# Top-level Module: top_fpga
# Target FPGA Part: xc7a100tcsg324-1 (Digilent Nexys A7 100T)
# ==============================================================================

set SCRIPT_DIR [file normalize [file dirname [info script]]]
set PROJ_DIR   [file normalize "$SCRIPT_DIR/.."]

puts "======================================================================"
puts " Starting Vivado Bitstream Generation Flow for RVM32I"
puts " Project Root Directory : $PROJ_DIR"
puts " Target Device           : xc7a100tcsg324-1"
puts " Top Module              : top_fpga"
puts "======================================================================"

# Set target FPGA part
set_part xc7a100tcsg324-1

# Create reports and output directory
file mkdir "$PROJ_DIR/reports"

# ------------------------------------------------------------------------------
# 1. Read Design Sources (RTL)
# ------------------------------------------------------------------------------
puts "\n--> \[1/6\] Reading Verilog Design Sources..."
cd $PROJ_DIR

read_verilog [list \
    "$PROJ_DIR/opcode.vh" \
    "$PROJ_DIR/IF_ID.v" \
    "$PROJ_DIR/execute.v" \
    "$PROJ_DIR/muldiv.v" \
    "$PROJ_DIR/wb.v" \
    "$PROJ_DIR/memory.v" \
    "$PROJ_DIR/pipeline.v" \
    "$PROJ_DIR/top_fpga.v" \
]

# Set include directory so `include "opcode.vh"` resolves properly
set_property include_dirs [list "$PROJ_DIR"] [current_fileset]

# ------------------------------------------------------------------------------
# 2. Read Constraints (XDC)
# ------------------------------------------------------------------------------
puts "\n--> \[2/6\] Reading Constraint Files..."
read_xdc "$PROJ_DIR/constraints/nexys_a7.xdc"

# ------------------------------------------------------------------------------
# 3. Synthesis (Full Top-Level, not out-of-context)
# ------------------------------------------------------------------------------
puts "\n--> \[3/6\] Running Synthesis for top_fpga..."
synth_design -top top_fpga -part xc7a100tcsg324-1 -include_dirs [list "$PROJ_DIR"]

puts "Generating Post-Synthesis Utilization Report..."
report_utilization -file "$PROJ_DIR/reports/post_synth_utilization.rpt"

# ------------------------------------------------------------------------------
# 4. Implementation (Opt, Place, Route)
# ------------------------------------------------------------------------------
puts "\n--> \[4/6\] Running Logic Optimization..."
opt_design

puts "\n--> Running Placement..."
place_design

puts "\n--> Running Physical Optimization..."
phys_opt_design

puts "\n--> Running Routing..."
route_design

# ------------------------------------------------------------------------------
# 5. Timing and Utilization Reports
# ------------------------------------------------------------------------------
puts "\n--> \[5/6\] Generating Implementation Reports..."
report_timing_summary -file "$PROJ_DIR/reports/timing_summary.rpt" -max_paths 10
report_utilization    -file "$PROJ_DIR/reports/utilization.rpt"
report_drc            -file "$PROJ_DIR/reports/drc_report.rpt"

# ------------------------------------------------------------------------------
# 6. Bitstream Generation
# ------------------------------------------------------------------------------
puts "\n--> \[6/6\] Writing Bitstream..."
write_bitstream -force -file "$PROJ_DIR/top_fpga.bit"

puts "======================================================================"
puts " SUCCESS: Bitstream generation finished successfully!"
puts " Output Bitstream : $PROJ_DIR/top_fpga.bit"
puts " Reports Directory: $PROJ_DIR/reports/"
puts "======================================================================"
