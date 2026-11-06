# ==============================================================================
# Vivado Bitstream Generation TCL Script for RVM32I with Victim Cache
# Target Board: Digilent Nexys A7 100T (xc7a100tcsg324-1)
# Top Module: top_fpga
# ==============================================================================

set SCRIPT_DIR [file normalize [file dirname [info script]]]
set PROJ_DIR   [file normalize "$SCRIPT_DIR/.."]

puts "======================================================================"
puts " Starting Vivado Bitstream Generation Flow for RVM32I + Victim Cache"
puts " Project Root Directory : $PROJ_DIR"
puts " Target Device           : xc7a100tcsg324-1"
puts " Top Module              : top_fpga"
puts "======================================================================"

# Set target FPGA part
set_part xc7a100tcsg324-1

# Create reports directory
file mkdir "$PROJ_DIR/reports"

# ------------------------------------------------------------------------------
# 0. Preload Default FPGA Demo Workload (conflict_thrash)
# ------------------------------------------------------------------------------
cd $PROJ_DIR
if {![file exists "$PROJ_DIR/imem.hex"] || ![file exists "$PROJ_DIR/mem128.hex"]} {
    puts "\n--> \[0/6\] Preloading default demonstration workload (conflict_thrash)..."
    file copy -force "$PROJ_DIR/sw/conflict_thrash_imem.hex"   "$PROJ_DIR/imem.hex"
    file copy -force "$PROJ_DIR/sw/conflict_thrash_mem128.hex" "$PROJ_DIR/mem128.hex"
    file copy -force "$PROJ_DIR/sw/conflict_thrash_dmem.hex"   "$PROJ_DIR/dmem.hex"
}

# ------------------------------------------------------------------------------
# 1. Read Design Sources (RTL Hierarchy)
# ------------------------------------------------------------------------------
puts "\n--> \[1/6\] Reading Verilog Design Sources..."
read_verilog [list \
    "$PROJ_DIR/rtl/core/opcode.vh" \
    "$PROJ_DIR/rtl/core/IF_ID.v" \
    "$PROJ_DIR/rtl/core/execute.v" \
    "$PROJ_DIR/rtl/core/muldiv.v" \
    "$PROJ_DIR/rtl/core/wb.v" \
    "$PROJ_DIR/rtl/core/pipeline.v" \
    "$PROJ_DIR/rtl/mem/memory.v" \
    "$PROJ_DIR/rtl/mem/main_memory.v" \
    "$PROJ_DIR/rtl/mem/l1_cache_controller.v" \
    "$PROJ_DIR/rtl/victim/victim_cache.v" \
    "$PROJ_DIR/rtl/mem/mem_subsystem.v" \
    "$PROJ_DIR/rtl/prefetch/prefetcher.v" \
    "$PROJ_DIR/rtl/perf/perf_profiler.v" \
    "$PROJ_DIR/rtl/uart/uart_tx.v" \
    "$PROJ_DIR/rtl/uart/uart_reporter.v" \
    "$PROJ_DIR/rtl/top/top_fpga.v" \
]

set INC_DIRS [list \
    "$PROJ_DIR/rtl/core" \
    "$PROJ_DIR/rtl/mem" \
    "$PROJ_DIR/rtl/victim" \
    "$PROJ_DIR/rtl/prefetch" \
    "$PROJ_DIR/rtl/perf" \
    "$PROJ_DIR/rtl/uart" \
    "$PROJ_DIR/rtl/top" \
]
set_property include_dirs $INC_DIRS [current_fileset]

# ------------------------------------------------------------------------------
# 2. Read Constraints (XDC)
# ------------------------------------------------------------------------------
puts "\n--> \[2/6\] Reading Constraint Files..."
read_xdc "$PROJ_DIR/constraints/nexys_a7.xdc"

# ------------------------------------------------------------------------------
# 3. Synthesis (Full Top-Level)
# ------------------------------------------------------------------------------
puts "\n--> \[3/6\] Running Synthesis for top_fpga..."
synth_design -top top_fpga -part xc7a100tcsg324-1 -include_dirs $INC_DIRS

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
