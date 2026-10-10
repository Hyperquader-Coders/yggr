package main

import "fmt"

func main() {
	// A deliberate type error lives one edit away; for now this is valid Go.
	msg := greeting("yggr")
	fmt.Println(msg)
}

func greeting(name string) string {
	return "hello, " + name
}
