# Receiver board KR260 pin and timing constraints for the SFP+ cage and its 156.25 MHz GTH reference clock.

set_property -dict {LOC T2} [get_ports sfp_rx_p]
set_property -dict {LOC T1} [get_ports sfp_rx_n]
set_property -dict {LOC R4} [get_ports sfp_tx_p]
set_property -dict {LOC R3} [get_ports sfp_tx_n]
set_property -dict {LOC Y6} [get_ports sfp_mgt_refclk_p]
set_property -dict {LOC Y5} [get_ports sfp_mgt_refclk_n]

set_property -dict {LOC Y10  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports sfp_tx_disable]
set_property -dict {LOC A10  IOSTANDARD LVCMOS33} [get_ports sfp_tx_fault]
set_property -dict {LOC J12  IOSTANDARD LVCMOS33} [get_ports sfp_rx_los]
set_property -dict {LOC W10  IOSTANDARD LVCMOS33} [get_ports sfp_mod_abs]
set_property -dict {LOC AB11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports sfp_i2c_scl]
set_property -dict {LOC AC11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports sfp_i2c_sda]

set_property -dict {LOC F8 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {led[0]}]
set_property -dict {LOC E8 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {led[1]}]
set_property -dict {LOC G8 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {sfp_led[0]}]
set_property -dict {LOC F7 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8} [get_ports {sfp_led[1]}]

create_clock -period 6.400 -name sfp_mgt_refclk [get_ports sfp_mgt_refclk_p]

set_false_path -to [get_ports sfp_tx_disable]
set_output_delay 0 [get_ports sfp_tx_disable]
set_false_path -from [get_ports {sfp_tx_fault sfp_rx_los sfp_mod_abs}]
set_input_delay 0 [get_ports {sfp_tx_fault sfp_rx_los sfp_mod_abs}]
set_false_path -to [get_ports {sfp_i2c_sda sfp_i2c_scl}]
set_output_delay 0 [get_ports {sfp_i2c_sda sfp_i2c_scl}]
set_false_path -from [get_ports {sfp_i2c_sda sfp_i2c_scl}]
set_input_delay 0 [get_ports {sfp_i2c_sda sfp_i2c_scl}]
set_false_path -to [get_ports {led[*] sfp_led[*]}]
set_output_delay 0 [get_ports {led[*] sfp_led[*]}]
