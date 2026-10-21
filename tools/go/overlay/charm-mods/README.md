# Charm module overlays (charm-mods)

`tools/go/overlay/charm/` maps onto the *staged Bubble Tea module* itself
(the `-overlay` JSON in `tools/go/build-*.sh`); this tree maps onto the
**other Go modules in a Charm app's dependency closure** — the only place
x/term's platform files can be adapted without editing the host module
cache. The mechanism is the `gostalgia-mods` one (#2957): same layout,
same application rules, staged by `tools/go/build-charmhello.sh`.

Layout: `charm-mods/<module-path>@<version>/<file>` — each directory
names a module version in the app's transitive closure. For every
directory the build:

1. resolves the pristine module through `go mod download -json`
   (versions the closure already names — nothing new is fetched);
2. copies it to `.build/charm-mods/<module>@<version>/`;
3. applies each `.go` file here onto that copy at the same relative
   path, under the same rules as the source overlay:
   - a file at an **existing** path replaces it and must carry a
     `// pinned-sha256: <hex>` marker matching the module-cache original;
   - a file at a **new** path is added and must carry `//go:build virelai`;
   - `README.md` and non-`.go` files are never applied.
4. re-verifies the staged copy against the cache snapshot (every file
   the overlay did not name must match byte-for-byte);
5. adds `replace <module> => <staged copy>` to the transient modfile —
   the module cache itself is never written.

Kernel access in an overlay file goes through `virelai/vi` and
`virelai/teatty` — never `os`, `os/signal`, `syscall`, or `x/sys/unix`
(the guest has no POSIX surface behind them; the v1 tree's guard made
the same rule explicit).

## Surface

| Module | Files | What it adapts |
|---|---|---|
| `github.com/charmbracelet/x/term@v0.2.2` | `term_other.go` (replace, retag `!virelai`), `term_virelai.go` (add) | The catch-all fallback compiles but returns "not implemented" for `IsTerminal`/`GetSize`/`MakeRaw`, which fails `tea.Run` at its first `term.GetSize`; the virelai file answers `IsTerminal`/`GetSize` through `teatty` (bound-fd answer, last-known CELLS) and makes the state calls honest no-ops — there is no line discipline to enter or restore |
