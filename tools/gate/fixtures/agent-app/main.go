// The M109d live-agent-loop fixture app (card #2400): the program an
// agent authors in-guest through AGENTD's fs.write verb, builds with
// GOBUILD, signs into a release stream with FLINT, and a fresh VM then
// installs and runs through STORE. Runtime-only like
// tools/gate/fixtures/third-party-app/acmeapp.go — zero standard-library
// OS imports, two atoms (main.Banner + main.main) so the pushed Changes
// stay far under the relay's ~1460-byte fill bound.
package main

const Banner = "agentapp: shipped by an agent through the loop"

func main() {
	println(Banner)
	println("agentapp OK")
}
