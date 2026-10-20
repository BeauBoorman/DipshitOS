//go:build !editfmt

package main

// format_nofmt.go — the shipped build: the M138b probe (see format.go's
// header) measured the go/format image over exec_program_max, so the
// default carries no go/format import at all. formatSource stays nil and
// every .go save prints the card's named refusal.
var formatSource func([]byte) ([]byte, error)
