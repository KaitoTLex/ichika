set top    [lindex $argv 0]
set part   [lindex $argv 1]
set srcdir [lindex $argv 2]

proc find_hdl {dir} {
    set results {}
    foreach f [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $f]} {
            lappend results {*}[find_hdl $f]
        } elseif {[regexp {\.sv$|\.v$} $f]} {
            lappend results $f
        }
    }
    return $results
}

set srcs [find_hdl $srcdir]
if {[llength $srcs] == 0} {
    puts "ERROR: No .sv/.v files found under $srcdir"
    exit 1
}
foreach src $srcs {
    read_verilog -sv $src
}

foreach xdc [glob -nocomplain -directory [file dirname $srcdir] *.xdc] {
    read_xdc $xdc
}

synth_design -top $top -part $part
opt_design
place_design
route_design

set rptdir [file join [file dirname $srcdir] reports]
file mkdir $rptdir
report_timing_summary -file [file join $rptdir timing_impl.rpt]
report_utilization    -file [file join $rptdir utilization_impl.rpt]

set bitfile [file join $srcdir ${top}.bit]
write_bitstream -force $bitfile

puts "Implementation complete. Bitstream: $bitfile"
