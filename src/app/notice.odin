package main

// What `--version`, `--license`, `--credits` and `--readme` print.
//
// All four documents are compiled in rather than read from disk: a release is
// one file to copy, and a notice that can go missing is not a notice. Every
// embedded asset credits.txt names is embedded the same way.

import "core:fmt"

// Stamped at build time, never edited here: a number in the source and a tag on
// the remote drift apart, and the commit is the only thing that says exactly
// what a binary is. release.sh and the release workflow pass both in.
//
// An unstamped build says so rather than claiming a release it is not.
VERSION :: #config(DIRTBENCH_VERSION, "dev")
COMMIT :: #config(DIRTBENCH_COMMIT, "unknown")

LICENSE_TEXT :: #load("../../LICENSE", string)
CREDITS_TEXT :: #load("../../credits.txt", string)
README_TEXT :: #load("../../README.md", string)

version_print :: proc() {
	fmt.printfln("dirtbench %s (%s)", VERSION, COMMIT)
}

license_print :: proc() {
	fmt.printfln("dirtbench %s (%s)\n", VERSION, COMMIT)
	fmt.println(LICENSE_TEXT)
}

credits_print :: proc() {
	fmt.println(CREDITS_TEXT)
}

readme_print :: proc() {
	fmt.println(README_TEXT)
}
