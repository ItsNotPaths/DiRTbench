package main

// What `--version` and `--notice` print.
//
// The licence and the credits are compiled in rather than read from disk: a
// release is one file to copy, and a notice that can go missing is not a
// notice. Every embedded asset credits.txt names is embedded the same way.

import "core:fmt"

VERSION :: "0.1.0"

LICENSE_TEXT :: #load("../../LICENSE", string)
CREDITS_TEXT :: #load("../../credits.txt", string)

version_print :: proc() {
	fmt.printfln("dirtbench %s", VERSION)
}

notice_print :: proc() {
	fmt.printfln("dirtbench %s\n", VERSION)
	fmt.println(LICENSE_TEXT)
	fmt.println(CREDITS_TEXT)
}
