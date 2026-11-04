package main

import "core:fmt"

main :: proc() {
	// Deliberate type error: 11 where a string is expected. OLS flags it on
	// open, so the default `make run` shows diagnostics without an edit.
	msg := greeting(11)
	fmt.println(msg)
}

greeting :: proc(name: string) -> string {
	return fmt.tprintf("hello, %s", name)
}
