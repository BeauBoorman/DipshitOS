package pdfwrite

import "virelai/flate"

// The compressor moved to user/go/flate (issue #2976): the owned
// fixed-Huffman + bounded hash-chain encoder written here for M153a is now
// flate.CompressZlib, shared with webrender's PNG writer. The promotion
// kept the algorithm identical, so every stream pdfwrite emits is
// byte-identical to the pre-promotion encoder — this file's tests and the
// package's rendered-document checks pin that.
func deflateZlib(src []byte) []byte {
	return flate.CompressZlib(src)
}
