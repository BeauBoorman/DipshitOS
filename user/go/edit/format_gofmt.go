//go:build editfmt

package main

// format_gofmt.go — the opt-in build (`-tags editfmt`): go/format linked
// in. NOT the shipped default — the M138b probe measured GOEDIT+format at
// 2,556,064 bytes, over exec_program_max (2,097,152), so this variant
// produces an image the kernel loader refuses today. It exists so the
// next cap bump (or a smaller import closure) flips one tag, and so the
// refusal path's alternative stays compile-tested. See format.go for the
// seam and the refusal contract.
import "go/format"

var formatSource = format.Source
