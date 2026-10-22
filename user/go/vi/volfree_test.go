// Host tests for vi.VolumeFree (M160b): the name→row mapping and the
// kernel errno pass-through, stubbed at the volumeFree seam.
package vi

import (
	"errors"
	"testing"
)

func stubVolumeFree(t *testing.T, fn func(uint64) int64) {
	t.Helper()
	saved := volumeFree
	volumeFree = fn
	t.Cleanup(func() { volumeFree = saved })
}

func TestVolumeFreeMapsNamesToRows(t *testing.T) {
	var got []uint64
	stubVolumeFree(t, func(row uint64) int64 {
		got = append(got, row)
		if row == 0 {
			return 12345678
		}
		return 4096
	})
	b, err := VolumeFree("host")
	if err != nil || b != 12345678 {
		t.Fatalf("VolumeFree(host) = %d, %v", b, err)
	}
	b, err = VolumeFree("disk")
	if err != nil || b != 4096 {
		t.Fatalf("VolumeFree(disk) = %d, %v", b, err)
	}
	if len(got) != 2 || got[0] != volumeRowHost || got[1] != volumeRowDisk {
		t.Fatalf("rows queried = %v, want [0 1]", got)
	}
}

func TestVolumeFreeNamesRefusals(t *testing.T) {
	stubVolumeFree(t, func(row uint64) int64 { return -ErrENOENT })
	if _, err := VolumeFree("disk"); !errors.Is(err, errno(ErrENOENT)) {
		t.Fatalf("unmounted disk err = %v, want ENOENT", err)
	}
	for _, name := range []string{"usb", "usb1", "esp", "data", "", "HOST"} {
		if _, err := VolumeFree(name); !errors.Is(err, ErrNoVolumeRow) {
			t.Fatalf("VolumeFree(%q) err = %v, want ErrNoVolumeRow", name, err)
		}
	}
}
