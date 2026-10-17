// Third-party publisher drill fixture (M110d, card #2406): the stand-in
// for an app VirelaiOS did not write. It is authored in-repo (project
// license — no third-party code) but published under the acme publisher
// key, the second TRUSTED.TXT entry, so the go-flint gate's fresh share
// installs and runs software signed by a key that is not ours.
//
// Runtime-only like tools/go/hello.go — zero standard-library OS
// imports. The gate builds it per run with
//   GO_BUILD_NAME=ACMEAPP bash tools/go/build-go.sh \
//       tools/gate/fixtures/third-party-app/acmeapp.go
// and asserts the marker on serial after `store install acme`.
package main

func main() {
	println("acme-app: shipped by the second publisher key")
	println("acme-app OK")
}
