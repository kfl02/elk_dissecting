# Use J-Link EDU as the adapter
adapter driver jlink
transport select jtag
adapter speed 4000

# Define a single CPLD in the chain
jtag newtap cpld tap -irlen 8 -expected-id 0x06e5e093
#jtag arp_init-reset

set bsrtap cpld.tap

init

set INTEST 0b00000010
set BYPASS 0b11111111
set SAMPLE 0b00000011
set EXTEST 0b00000000

# taken from Elk Pi schematics and xc2c64a_vq44.bsdl
set RESET_IN_BIT    143   ;# pin 29 -> IO_32
set RESET_OUT_BIT   142
set RESET_CTL_BIT   141
set BCLK_IN_BIT     104   ;# pin 19 -> IO_45
set BCLK_OUT_BIT    103
set BCLK_CTL_BIT    102
set LRIN_IN_BIT     110   ;# pin 20 -> IO_43
set LRIN_OUT_BIT    109
set LRIN_CTL_BIT    108
set LROUT_IN_BIT    116   ;# pin 22 -> IO_41
set LROUT_OUT_BIT   115
set LROUT_CTL_BIT   114

# load instructions into IR register

proc extest {} {
    global bsrtap EXTEST

    irscan $bsrtap $EXTEST
}

proc intest {} {
    global bsrtap INTEST

    irscan $bsrtap $INTEST
}

proc bypass {} {
    global bsrtap BYPASS

    irscan $bsrtap $BYPASS
}

proc sample {} {
    global bsrtap SAMPLE

    irscan $bsrtap $SAMPLE
}

proc init_bs {tap len} {
    global bsrtap bsrlen

    set bsrlen $len
    set bsrtap $tap

    init_bsrstate
}

# update the global bsrstate variable with the given state
proc update_bsrstate {state} {
    global bsrstate

    set i 1

    foreach word $state {
        set bsrstate [lreplace $bsrstate $i $i 0x$word]
        incr i 2
    }
}

# shift bsrstateout to DR register
# save incoming TDO data in bsrstate
# if pause != 0, remain in pause state, so that outgoing data is not loaded
proc exchange_bsr {{pause 0}} {
    global bsrtap bsrstate bsrstateout

    set scan_cmd [concat $bsrtap $bsrstateout]

    if {$pause} {
        append scan_cmd " -endstate drpause"
    }

    update_bsrstate [eval drscan $scan_cmd]

    return $bsrstate
}

# initialize global bsrstate and bsrstateout variable
proc init_bsrstate {} {
    global bsrtap bsrlen bsrstate bsrstateout

    set bsrstate ""

    for {set i $bsrlen} {$i > 32} {incr i -32} {
        append bsrstate 32 " " 0xFFFFFFFF " "
    }

    if {$i > 0} {
        append bsrstate $i " " 0xFFFFFFFF
    }

    set bsrstateout $bsrstate

    extest
    exchange_bsr 1

    set bsrstateout $bsrstate

    exchange_bsr

    return
}

# get value of bit in bsr
# if "register" is not specified, the global incoming bsr is used
proc get_bit_bsr {bit {register 0}} {
    global bsrstate

    if {$register == 0} {
        set register $bsrstate
    }

    set idx [expr {$bit / 32}]
    set bit [expr {$bit % 32}]

    expr {([lindex $register [expr {$idx*2 + 1}]] & [expr {2**$bit}]) != 0}
}

# set bit in outgoing bsr to specified value
proc set_bit_bsr {bit value} {
    global bsrstateout

    set idx [expr {($bit / 32) * 2 + 1}]

    set bit [expr {$bit % 32}]
    set bitval [expr {2**$bit}]
    set word [lindex $bsrstateout $idx]

    if {$value == 0} {
        set word [format %X [expr {$word & ~$bitval}]]
    } else {
        set word [format %X [expr {$word | $bitval}]]
    }

    set bsrstateout [lreplace $bsrstateout $idx $idx 0x$word]

    return
}

# global tick counter
set TICKS 0

# test counters
set LAST_LRIN -1    # last known value of LRIN, -1 initially
set LAST_LROUT -1   # last known value of LROUT, -1 initially
set COUNT_LRIN 0    # number of ticks since last LRIN change
set COUNT_LROUT 0   # number of ticks since last LROUT change
set COUNT_LRIN_CHANGE 0     # number of LRIN changes observed so far
set COUNT_LROUT_CHANGE 0    # number of LROUT changes observed so far

# reset all test counters and the tick counter
proc reset_test_counters {} {
    global TICKS
    global LAST_LRIN LAST_LROUT
    global COUNT_LRIN COUNT_LROUT
    global COUNT_LRIN_CHANGE COUNT_LROUT_CHANGE

    set LAST_LRIN -1
    set LAST_LROUT -1
    set COUNT_LRIN 0
    set COUNT_LROUT 0
    set COUNT_LRIN_CHANGE 0
    set COUNT_LROUT_CHANGE 0
    set TICKS 0
}

# pull the reset line high or low
proc pull_reset {level} {
    global RESET_IN_BIT

    if {$level} {
        set_bit_bsr $RESET_IN_BIT 1
    } else {
        set_bit_bsr $RESET_IN_BIT 0
    }

    exchange_bsr
    intest
}

# init jtag, tap, bsr control bits
# pull reset bit high, then low again
# reset counters
proc test_init {} {
    global bsrtap 
    global BCLK_CTL_BIT LRIN_CTL_BIT LROUT_CTL_BIT RESET_CTL_BIT
    global RESET_IN_BIT BCLK_IN_BIT LRIN_IN_BIT

    init_bs $bsrtap 192

    set_bit_bsr $BCLK_CTL_BIT 0
    set_bit_bsr $LRIN_CTL_BIT 0
    set_bit_bsr $LROUT_CTL_BIT 1
    set_bit_bsr $RESET_CTL_BIT 0

    set_bit_bsr $BCLK_IN_BIT 0
    set_bit_bsr $LRIN_IN_BIT 0

    pull_reset 1
    pull_reset 0

    reset_test_counters
}

# set the bclk bit in bsr according to tick clock
proc set_bclk {} {
    global BCLK_IN_BIT TICKS

    set_bit_bsr $BCLK_IN_BIT [expr {$TICKS & 1}]
}

# advance tick clock
proc bclk {} {
    global TICKS

    incr TICKS
}

# check for changes in LRIN and LROUT and output some information
# return true if LROUR changed
proc check_lr_change {} {
    global TICKS
    global LAST_LRIN LAST_LROUT
    global COUNT_LRIN COUNT_LROUT
    global COUNT_LRIN_CHANGE COUNT_LROUT_CHANGE
    global LRIN_IN_BIT LROUT_OUT_BIT
    global bsrstate bsrstateout

    set LRIN [get_bit_bsr $LRIN_IN_BIT $bsrstateout]
    set LROUT [get_bit_bsr $LROUT_OUT_BIT $bsrstate]

    incr COUNT_LRIN

    if {$LRIN != $LAST_LRIN} {
        incr COUNT_LRIN_CHANGE

        if {$LAST_LRIN != -1} {
            echo [concat "LRIN change #" $COUNT_LRIN_CHANGE " from " $LAST_LRIN " to " $LRIN " after " $COUNT_LRIN " ticks. (" $TICKS ")"]
        } else {
            echo [concat "LRIN init #" $COUNT_LRIN_CHANGE " to " $LRIN " after " $COUNT_LRIN " ticks. (" $TICKS ")"]
        }

        set COUNT_LRIN 0
    }

    incr COUNT_LROUT

    set LROUT_CHANGED [expr {$LROUT != $LAST_LROUT}]

    if {$LROUT_CHANGED} {
        incr COUNT_LROUT_CHANGE

        if {$LAST_LROUT != -1} {
            echo [concat "LROUT change #" $COUNT_LROUT_CHANGE " from " $LAST_LROUT " to " $LROUT " after " $COUNT_LROUT " ticks. (" $TICKS ")"]
        } else {
            echo [concat "LROUT init #" $COUNT_LROUT_CHANGE " to " $LROUT " after " $COUNT_LROUT " ticks. (" $TICKS ")"]
        }

        set COUNT_LROUT 0
    }

    set LAST_LRIN $LRIN
    set LAST_LROUT $LROUT

    return $LROUT_CHANGED
}

# length: number of BCLK cycles to generate
# shift: length of LRIN cycles to generate
#        0 = constant 0
#        1 = BCLK
#        2 = BCLK * 2
# not: != 0 invert the LRIN cycles generated with the shift option 
# max_toggles: maximum number of LROUT toggles to observe
#              0 = keep looping unto the BCLK cycles specified by length
proc test_loop {length {shift 0} {not 0} {max_toggles 0}} {
    global LRIN_IN_BIT
    global TICKS

    set toggles 0

    if {$not != 0} {
        set not [expr {1 << ($shift - 1)}]
    }

    for {set c 0} {($c < $length * 2) && ($max_toggles == 0 || ($max_toggles != 0) && ($toggles < $max_toggles))} {incr c} {
        set LRIN [expr {(($c & ((1 << $shift) -1)) & (1 << ($shift - 1))) != $not}]

        set_bclk
        set_bit_bsr $LRIN_IN_BIT $LRIN

        exchange_bsr
        intest
        exchange_bsr
        extest

        set LROUT_CHANGED [check_lr_change]

        if {$LROUT_CHANGED && ($max_toggles > 0)} {
            incr toggles
        }

        bclk
    }
}
