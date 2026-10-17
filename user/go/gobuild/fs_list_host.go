//go:build !virelai

package main

import "os"

func dirEntries(dir string) ([]dirEnt, error) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	out := make([]dirEnt, 0, len(ents))
	for _, e := range ents {
		out = append(out, dirEnt{name: e.Name(), isDir: e.IsDir()})
	}
	return out, nil
}
