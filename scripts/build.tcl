# vivado -mode batch -source scripts/build.tcl -tclargs <module> [clock_period_ns]

set part xck26-sfvc784-2LV-c
set board xilinx.com:kr260_som:part0:2.0

set top    [expr {[llength $argv] > 0 ? [lindex $argv 0] : "header_strip"}]
set period [expr {[llength $argv] > 1 ? [lindex $argv 1] : 6.4}]

set root   [file normalize [file join [file dirname [info script]] ..]]
set outdir $root/build/synth/$top
file delete -force $outdir
file mkdir $outdir

set srcs {}
foreach f [glob -nocomplain $root/rtl/*/*.sv] {
    if {[file size $f] > 0} { lappend srcs $f }
}
if {[llength $srcs] == 0} {
    puts "ERROR: no sources under rtl/"
    exit 1
}

create_project -in_memory -part $part
if {[llength [get_board_parts -quiet $board]]} {
    set_property board_part $board [current_project]
}
read_verilog -sv $srcs
synth_design -mode out_of_context -top $top -part $part

set clks {}
foreach p [get_ports -quiet -filter {DIRECTION == IN}] {
    if {[string match -nocase *clk* $p] || [string match -nocase *clock* $p]} {
        create_clock -name $p -period $period [get_ports $p]
        lappend clks [get_clocks $p]
    }
}
if {[llength $clks] == 0} {
    puts "ERROR: no clock port found on $top"
    exit 1
}
if {[llength $clks] > 1} {
    set_clock_groups -asynchronous -group [lindex $clks 0] -group [lindex $clks 1]
    report_cdc -details -file $outdir/cdc.rpt
}

write_checkpoint -force $outdir/post_synth.dcp
report_utilization    -file $outdir/util.rpt
report_timing_summary -file $outdir/timing.rpt
report_timing -max_paths 10 -file $outdir/paths.rpt

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set fmax [expr {1000.0 / ($period - $wns)}]
set luts  [llength [get_cells -quiet -hier -filter {REF_NAME =~ LUT*}]]
set ffs   [llength [get_cells -quiet -hier -filter {REF_NAME =~ FD*}]]
set brams [llength [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*}]]

puts "--------------------------------------------------"
puts "module   : $top"
puts "part     : $part"
puts "target   : $period ns ([format %.1f [expr {1000.0/$period}]] MHz)"
puts "WNS      : $wns ns"
puts "Fmax     : [format %.1f $fmax] MHz"
puts "LUT/FF   : $luts / $ffs   BRAM: $brams"
puts "reports  : $outdir"
puts "--------------------------------------------------"
if {$wns < 0} { puts "TIMING NOT MET at $period ns" }
exit 0
