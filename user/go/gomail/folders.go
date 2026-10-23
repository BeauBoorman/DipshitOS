package main

// folders.go — M193a (#3253): SELECT-able folder browsing. `use <box>`
// validates the name over the real LIST — never a fake folder — SELECTs
// it, and records both halves in the cache: BOXES (the folder list the
// wire just proved) and USE (the selection later runs remember, since
// every GOMAIL invocation is a fresh process). Offline the cached LIST
// is the authority a `use`/`boxes` answers from — a name it does not
// hold is a cache-miss, not a folder.

import "strings"

// parseBoxes decodes the BOXES file: one folder name per line.
func parseBoxes(b []byte) []string {
	var out []string
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		out = append(out, line)
	}
	return out
}

// formatBoxes encodes the folder list; names are sanitized one-line and
// the list is bounded.
func formatBoxes(boxes []string) []byte {
	var b strings.Builder
	for i, name := range boxes {
		if i >= cacheBoxesMax {
			break
		}
		name = field(name)
		if name == "" {
			continue
		}
		b.WriteString(name)
		b.WriteByte('\n')
	}
	return []byte(b.String())
}

// cacheLoadBoxes returns the remembered folder list (nil when none).
func cacheLoadBoxes() []string {
	return parseBoxes(cacheRead("BOXES"))
}

// cacheSaveBoxes republishes the folder list a wire LIST just proved.
func cacheSaveBoxes(boxes []string) {
	cacheWrite("BOXES", formatBoxes(boxes))
}

// cacheLoadUse returns the remembered selection ("" when none).
func cacheLoadUse() string {
	for _, line := range strings.Split(string(cacheRead("USE")), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			return line
		}
	}
	return ""
}

// cacheSaveUse records the selected mailbox.
func cacheSaveUse(box string) {
	cacheWrite("USE", []byte(field(box)+"\n"))
}

// boxKnown reports whether name rides the folder list we hold — the
// LIST's own rows, so a `use` of a name the server never listed is a
// refusal, not a selection.
func boxKnown(boxes []string, name string) bool {
	for _, b := range boxes {
		if b == name {
			return true
		}
	}
	return false
}

// resolveBox picks a verb's mailbox: an explicit argument wins, else the
// remembered `use`, else INBOX — the protocol's own default, and still
// SELECT-validated (a fake name answers the server's refusal, not rows).
func resolveBox(arg string) string {
	if arg != "" {
		return arg
	}
	if u := cacheLoadUse(); u != "" {
		return u
	}
	return "INBOX"
}

// runUse is the 'use <box>' leg: LIST, membership, SELECT, remember. A
// name the LIST does not carry is a named refusal — GOMAIL browses real
// folders or none.
func runUse(cfg Config, box string) error {
	c, err := dialIMAP(cfg)
	if err != nil {
		return offlineOr(err, func() error { return offlineUse(box) })
	}
	defer c.logout()
	return useLeg(c, box)
}

// useLeg is the online half of 'use', split so the recorded-session
// test can drive it over a scripted WireConn.
func useLeg(c *imapClient, box string) error {
	boxes, err := c.list()
	if err != nil {
		return err
	}
	for _, b := range boxes {
		say("gomail: box " + b)
	}
	cacheSaveBoxes(boxes)
	if !boxKnown(boxes, box) {
		return protoErr("refuse use ", box)
	}
	exists, err := c.selectBox(box)
	if err != nil {
		return err
	}
	say("gomail: use " + box + " exists=" + itoa(int64(exists)))
	cacheSaveUse(box)
	return nil
}

// offlineUse answers 'use' from the remembered LIST: a cached name
// selects (and records); an unknown one is a cache-miss, not a folder.
func offlineUse(box string) error {
	say("gomail: offline use " + box)
	if !boxKnown(cacheLoadBoxes(), box) {
		return protoErr("cache-miss ", "use "+box)
	}
	say("gomail: use " + box + " cached")
	cacheSaveUse(box)
	return nil
}
