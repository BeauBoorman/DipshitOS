package store

// api.go — the exported M110c (#2405) surface GOSTORE.ELF links against.
// STORE stays the only implementation of the signed legs; this file adds
// no behavior, it only names what the in-process caller needs beyond the
// verbs themselves (Ls/Info/Install/Update/Rollback/Pin/Remove,
// ConsoleFn, LegFn, LoadCatalog, CatalogRow).

// Release is the signed release manifest on a CatalogEntry — an alias so
// the GUI renders the authenticated consts by name.
type Release = release

// Installed reports whether APPS.TXT already carries bin's manifest row —
// the same check `store info` prints as `store: installed yes|no`. A
// manifest read failure is an error, not a "no": the GUI must not render
// an install state it could not read.
func Installed(fs FS, bin string) (bool, error) {
	lines, err := loadManifest(fs)
	if err != nil {
		return false, err
	}
	return manifestHasBin(lines, bin), nil
}
