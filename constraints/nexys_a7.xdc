## ----------------------------------------------------------------------------
## Nexys A7-100T FPGA Board Constraints for RVM32I (top_fpga)
## Part: xc7a100tcsg324-1
## ----------------------------------------------------------------------------

## Configuration Properties for Bitstream Generation
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

################ CLOCK (100 MHz oscillator) ################
set_property PACKAGE_PIN E3 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 10.000 -name sys_clk_pin [get_ports clk]

################ RESET (BTNC Push Button - Active High) ################
set_property PACKAGE_PIN N17 [get_ports reset]
set_property IOSTANDARD LVCMOS33 [get_ports reset]

################ SWITCHES (SW0 - SW15) ################
set_property PACKAGE_PIN J15 [get_ports {sw[0]}]
set_property PACKAGE_PIN L16 [get_ports {sw[1]}]
set_property PACKAGE_PIN M13 [get_ports {sw[2]}]
set_property PACKAGE_PIN R15 [get_ports {sw[3]}]
set_property PACKAGE_PIN R17 [get_ports {sw[4]}]
set_property PACKAGE_PIN T18 [get_ports {sw[5]}]
set_property PACKAGE_PIN U18 [get_ports {sw[6]}]
set_property PACKAGE_PIN R13 [get_ports {sw[7]}]
set_property PACKAGE_PIN T8  [get_ports {sw[8]}]
set_property PACKAGE_PIN U8  [get_ports {sw[9]}]
set_property PACKAGE_PIN R16 [get_ports {sw[10]}]
set_property PACKAGE_PIN T13 [get_ports {sw[11]}]
set_property PACKAGE_PIN H6  [get_ports {sw[12]}]
set_property PACKAGE_PIN U12 [get_ports {sw[13]}]
set_property PACKAGE_PIN U11 [get_ports {sw[14]}]
set_property PACKAGE_PIN V10 [get_ports {sw[15]}]
set_property IOSTANDARD LVCMOS33 [get_ports sw[*]]

################ LEDS (LD0 - LD15) ################
set_property PACKAGE_PIN H17 [get_ports {led[0]}]
set_property PACKAGE_PIN K15 [get_ports {led[1]}]
set_property PACKAGE_PIN J13 [get_ports {led[2]}]
set_property PACKAGE_PIN N14 [get_ports {led[3]}]
set_property PACKAGE_PIN R18 [get_ports {led[4]}]
set_property PACKAGE_PIN V17 [get_ports {led[5]}]
set_property PACKAGE_PIN U17 [get_ports {led[6]}]
set_property PACKAGE_PIN U16 [get_ports {led[7]}]
set_property PACKAGE_PIN V16 [get_ports {led[8]}]
set_property PACKAGE_PIN T15 [get_ports {led[9]}]
set_property PACKAGE_PIN U14 [get_ports {led[10]}]
set_property PACKAGE_PIN T16 [get_ports {led[11]}]
set_property PACKAGE_PIN V15 [get_ports {led[12]}]
set_property PACKAGE_PIN V14 [get_ports {led[13]}]
set_property PACKAGE_PIN V12 [get_ports {led[14]}]
set_property PACKAGE_PIN V11 [get_ports {led[15]}]
set_property IOSTANDARD LVCMOS33 [get_ports led[*]]

################ 7-SEGMENT DISPLAY CATHODES (CA - CG, DP) ################
# Active-low cathodes: seg[0]=CA, seg[1]=CB, seg[2]=CC, seg[3]=CD, seg[4]=CE, seg[5]=CF, seg[6]=CG
set_property PACKAGE_PIN T10 [get_ports {seg[0]}]
set_property PACKAGE_PIN R10 [get_ports {seg[1]}]
set_property PACKAGE_PIN K16 [get_ports {seg[2]}]
set_property PACKAGE_PIN K13 [get_ports {seg[3]}]
set_property PACKAGE_PIN P15 [get_ports {seg[4]}]
set_property PACKAGE_PIN T11 [get_ports {seg[5]}]
set_property PACKAGE_PIN L18 [get_ports {seg[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports seg[*]]

set_property PACKAGE_PIN H15 [get_ports dp]
set_property IOSTANDARD LVCMOS33 [get_ports dp]

################ 7-SEGMENT DISPLAY ANODES (AN0 - AN7) ################
# Active-low digit anodes: an[0]=rightmost, an[7]=leftmost
set_property PACKAGE_PIN J17 [get_ports {an[0]}]
set_property PACKAGE_PIN J18 [get_ports {an[1]}]
set_property PACKAGE_PIN T9  [get_ports {an[2]}]
set_property PACKAGE_PIN J14 [get_ports {an[3]}]
set_property PACKAGE_PIN P14 [get_ports {an[4]}]
set_property PACKAGE_PIN T14 [get_ports {an[5]}]
set_property PACKAGE_PIN K2  [get_ports {an[6]}]
set_property PACKAGE_PIN U13 [get_ports {an[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports an[*]]
