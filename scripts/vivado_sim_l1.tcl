# ==============================================================================
# Vivado Automated Behavioral Simulation Script
# Project: RV32I Memory Hierarchy Enhancement with 4-Entry Victim Cache
#
# How to run:
#   Option A (Vivado GUI Tcl Console):
#       cd C:/Users/Asus/riscv-victim-cache
#       source scripts/vivado_sim_l1.tcl
#
#   Option B (PowerShell / Command Prompt):
#       cd C:\Users\Asus\riscv-victim-cache
#       & "C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode gui -source scripts/vivado_sim_l1.tcl
# ==============================================================================

# Set working directory to project root
set repo_root [file normalize [file join [file dirname [info script]] ".."]]
cd $repo_root

puts "=================================================================="
puts "  STARTING VIVADO SIMULATION: L1 CACHE + VICTIM CACHE"
puts "  Target Part: xc7a100tcsg324-1 (Nexys A7-100T)"
puts "=================================================================="

# Close any open project
catch {close_project}

# Create a project in a clean directory
create_project -force sim_l1_proj "$repo_root/sim_l1_proj" -part xc7a100tcsg324-1

# Add RTL Design Sources
add_files -fileset sources_1 [list \
    "$repo_root/rtl/mem/l1_cache_controller.v" \
    "$repo_root/rtl/victim/victim_cache.v" \
    "$repo_root/rtl/mem/main_memory.v" \
]

# Add Simulation Testbench
add_files -fileset sim_1 [list \
    "$repo_root/tb/tb_l1_cache.v" \
]

# Update compile order and set top
set_property top tb_l1_cache [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Launch Behavioral Simulation
puts "--> Launching Behavioral Simulation (xsim)..."
launch_simulation

# Run all test cases until $finish
puts "--> Running simulation..."
run all

puts "=================================================================="
puts "  VIVADO SIMULATION COMPLETE"
puts "=================================================================="
