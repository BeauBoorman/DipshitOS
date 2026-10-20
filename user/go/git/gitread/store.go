package gitread

// Loose object store + a root-tree checkout. Paths stay inside the kernel's
// 64-byte cap (file_table.max_path_len): dest is a short share path like
// /host/G so objects/ab/<38-hex> still fits. No .git/index or config —
// host `git status` in the checkout will look dirty; fsck/log are the
// #1337 evidence.

import "virelai/flate"

// HasPrefix reports whether b starts with the bytes of p. Shared by the
// reader (commit/tree sniffing) and GOTGIT's transport (smart.go).
func HasPrefix(b []byte, p string) bool {
	if len(b) < len(p) {
		return false
	}
	for i := 0; i < len(p); i++ {
		if b[i] != p[i] {
			return false
		}
	}
	return true
}

const maxPath = 64

func JoinPath(dir, name string) (string, bool) {
	if name == "" || name == "." || name == ".." {
		return "", false
	}
	for i := 0; i < len(name); i++ {
		if name[i] == '/' {
			return "", false
		}
	}
	if len(dir) > 0 && dir[len(dir)-1] == '/' {
		dir = dir[:len(dir)-1]
	}
	out := dir + "/" + name
	if len(out) > maxPath {
		return "", false
	}
	return out, true
}

func ObjectPath(gitDir string, id [20]byte) (string, bool) {
	hex := HexEncode(id[:])
	d, ok := JoinPath(gitDir, "objects")
	if !ok {
		return "", false
	}
	d, ok = JoinPath(d, hex[:2])
	if !ok {
		return "", false
	}
	return JoinPath(d, hex[2:])
}

func LooseBytes(o GitObj) []byte {
	hdr := typeName(o.Type) + " " + Uitoa(uint64(len(o.Data))) + "\x00"
	raw := make([]byte, len(hdr)+len(o.Data))
	copy(raw, hdr)
	copy(raw[len(hdr):], o.Data)
	return flate.ZlibStore(raw)
}

type TreeEnt struct {
	Mode string
	Name string
	ID   [20]byte
}

func ParseTree(data []byte) []TreeEnt {
	var ents []TreeEnt
	i := 0
	for i < len(data) {
		sp := i
		for sp < len(data) && data[sp] != ' ' {
			sp++
		}
		if sp >= len(data) {
			break
		}
		mode := string(data[i:sp])
		nul := sp + 1
		for nul < len(data) && data[nul] != 0 {
			nul++
		}
		if nul+21 > len(data) {
			break
		}
		name := string(data[sp+1 : nul])
		var id [20]byte
		copy(id[:], data[nul+1:nul+21])
		ents = append(ents, TreeEnt{Mode: mode, Name: name, ID: id})
		i = nul + 21
	}
	return ents
}

func CommitTree(data []byte) ([20]byte, bool) {
	var id [20]byte
	if !HasPrefix(data, "tree ") || len(data) < 5+40 {
		return id, false
	}
	hex := data[5:]
	if len(hex) < 40 {
		return id, false
	}
	return HexDecode(string(hex[:40]))
}

func FindObj(objs []GitObj, id [20]byte) (GitObj, bool) {
	for _, o := range objs {
		if o.ID == id {
			return o, true
		}
	}
	return GitObj{}, false
}

func encodeTree(ents []TreeEnt) []byte {
	var out []byte
	for _, e := range ents {
		out = append(out, []byte(e.Mode)...)
		out = append(out, ' ')
		out = append(out, []byte(e.Name)...)
		out = append(out, 0)
		out = append(out, e.ID[:]...)
	}
	return out
}

func IsBlobMode(mode string) bool {
	return mode == "100644" || mode == "100755" || mode == "644" || mode == "755"
}
