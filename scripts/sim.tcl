# vivado -mode batch -source scripts/sim.tcl -tclargs <tb_name>

set tb [expr {[llength $argv] > 0 ? [lindex $argv 0] : "tb_header_strip"}]
set root [file normalize [file join [file dirname [info script]] ..]]

set rtl(tb_header_strip)  {rtl/eth/header_strip.sv}
set rtl(tb_axis_cdc_fifo) {rtl/common/axis_cdc_fifo.sv}
set rtl(tb_mold_deframe)  {rtl/eth/mold_deframe.sv}
set rtl(tb_itch_parse)    {rtl/itch/itch_parse.sv}
set rtl(tb_symbol_filter) {rtl/itch/symbol_filter.sv}
set rtl(tb_feed_top)      {rtl/eth/header_strip.sv rtl/eth/mold_deframe.sv rtl/itch/itch_parse.sv rtl/itch/symbol_filter.sv rtl/top/feed_top.sv}

set vec(tb_header_strip)  {eth_beats.hex mold_expect.hex eth_frames.txt}
set vec(tb_axis_cdc_fifo) {}
set vec(tb_mold_deframe)  {mold_beats.hex itch_expect.hex itch_expect.txt mold_packets.txt}
set vec(tb_itch_parse)    {itch_expect.hex itch_expect.txt}
set vec(tb_symbol_filter) {itch_expect.hex itch_expect.txt}
set vec(tb_feed_top)      {eth_beats.hex itch_expect.hex itch_expect.txt}

if {![info exists rtl($tb)]} {
    puts "ERROR: no entry for $tb in scripts/sim.tcl"
    exit 1
}
if {![file exists $root/tb/unit/$tb.sv]} {
    puts "ERROR: tb/unit/$tb.sv not found"
    exit 1
}

set work $root/build/sim/$tb
file delete -force $work
file mkdir $work
cd $work

foreach v $vec($tb) {
    if {![file exists $root/tb/vectors/$v]} {
        puts "ERROR: tb/vectors/$v missing"
        puts "       python scripts/mold_packetize.py <itch file>"
        puts "       python scripts/eth_encapsulate.py"
        exit 1
    }
    file copy -force $root/tb/vectors/$v $work
}

set srcs {}
foreach f $rtl($tb) { lappend srcs $root/$f }
lappend srcs $root/tb/unit/$tb.sv

set fh [open wave.tcl w]
puts $fh "log_wave -recursive *"
puts $fh "run all"
puts $fh "exit"
close $fh

puts "=== xvlog ==="
if {[catch {exec xvlog -sv {*}$srcs} out]} { puts $out; exit 1 }
puts $out

puts "=== xelab ==="
if {[catch {exec xelab $tb -s ${tb}_snap -debug typical --relax} out]} { puts $out; exit 1 }
puts $out

puts "=== xsim ==="
catch {exec xsim ${tb}_snap -wdb $tb.wdb -tclbatch wave.tcl} out
puts $out

puts "waves: $work/$tb.wdb"
if {[string match "*RESULT: PASS*" $out] && ![string match "*RESULT: FAIL*" $out]} {
    puts "SIM RESULT: PASS ($tb)"
} else {
    puts "SIM RESULT: FAIL ($tb)"
    exit 1
}
