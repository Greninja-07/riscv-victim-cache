# ==============================================================================
# program_fpga.tcl - Flash top_fpga.bit onto Digilent Nexys A7-100T via JTAG
# ==============================================================================

set SCRIPT_DIR [file normalize [file dirname [info script]]]
set PROJ_DIR   [file normalize "$SCRIPT_DIR/.."]
set BIT_FILE   "$PROJ_DIR/top_fpga.bit"

if {![file exists $BIT_FILE]} {
    puts "\n\[ERROR\] Bitstream file not found: $BIT_FILE"
    puts "Please build the bitstream first using build_bitstream.bat\n"
    exit 1
}

puts "\n\[INFO\] Connecting to hardware server..."
open_hw_manager
connect_hw_server -allow_non_jtag

puts "\[INFO\] Opening hardware target..."
open_hw_target

set TARGET_DEVICE [lindex [get_hw_devices xc7a100t_0] 0]
if {$TARGET_DEVICE == ""} {
    puts "\[ERROR\] Nexys A7 (xc7a100t_0) not detected! Ensure the board is powered ON and USB cable is connected."
    close_hw_manager
    exit 1
}

current_hw_device $TARGET_DEVICE
refresh_hw_device -update_hw_probes false $TARGET_DEVICE

puts "\[INFO\] Programming Nexys A7 with: $BIT_FILE"
set_property PROGRAM.FILE $BIT_FILE $TARGET_DEVICE
program_hw_devices $TARGET_DEVICE

puts "\n======================================================================"
puts " SUCCESS: Nexys A7-100T programmed successfully!"
puts "======================================================================\n"
close_hw_manager
exit 0
