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

set xdc [file join [file dirname $srcdir] constraints.xdc]
if {[file exists $xdc]} {
    read_xdc $xdc
}

synth_design -top $top -part $part

set rptdir [file join [file dirname $srcdir] reports]
file mkdir $rptdir
write_checkpoint      -force [file join [file dirname $srcdir] synth.dcp]
report_timing_summary -file  [file join $rptdir timing_synth.rpt]
report_utilization    -file  [file join $rptdir utilization_synth.rpt]

puts "Synthesis complete."
