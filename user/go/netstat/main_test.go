package main

import (
	"testing"

	"virelai/vi"
)

func TestFormatting(t *testing.T) {
	if got := ipString([4]byte{192, 168, 64, 5}); got != "192.168.64.5" {
		t.Fatalf("ipString = %q", got)
	}
	if got := macString([6]byte{2, 0, 0, 0, 0, 2}); got != "02:00:00:00:00:02" {
		t.Fatalf("macString = %q", got)
	}
	for state, want := range map[byte]string{0: "idle", 1: "selecting", 2: "requesting", 3: "bound", 4: "renewing", 5: "rebinding", 9: "idle"} {
		if got := dhcpName(state); got != want {
			t.Errorf("dhcpName(%d) = %q, want %q", state, got, want)
		}
	}
	for state, want := range map[byte]string{0: "IDLE", 1: "SYN-SENT", 2: "ESTABLISHED", 3: "FIN-WAIT", 4: "CLOSED", 9: "IDLE"} {
		if got := tcpName(state); got != want {
			t.Errorf("tcpName(%d) = %q, want %q", state, got, want)
		}
	}
	for state, want := range map[byte]string{0: "syn-sent", 1: "established", 2: "closing", 3: "terminal", 9: "?"} {
		if got := sockStateName(state); got != want {
			t.Errorf("sockStateName(%d) = %q, want %q", state, got, want)
		}
	}
}

func TestSocketRowLine(t *testing.T) {
	lst := socketRowLine(vi.SocketRow{Owner: 7, Kind: 0,
		LocalIP: [4]byte{10, 0, 0, 1}, LocalPort: 2222})
	if lst != "pid=7 listen 10.0.0.1:2222" {
		t.Fatalf("listener row = %q", lst)
	}
	conn := socketRowLine(vi.SocketRow{Owner: 7, Kind: 1, State: 1,
		LocalIP: [4]byte{10, 0, 0, 1}, LocalPort: 2222,
		RemoteIP: [4]byte{10, 0, 0, 2}, RemotePort: 12345})
	if conn != "pid=7 tcp 10.0.0.1:2222 -> 10.0.0.2:12345 established" {
		t.Fatalf("conn row = %q", conn)
	}
	a := []vi.SocketRow{lst_row(), conn_row()}
	if !socketRowsEqual(a, append([]vi.SocketRow(nil), a...)) {
		t.Fatal("equal row sets not equal")
	}
	if socketRowsEqual(a, a[:1]) || socketRowsEqual(a, []vi.SocketRow{conn_row(), lst_row()}) {
		t.Fatal("unequal row sets reported equal")
	}
}

func lst_row() vi.SocketRow {
	return vi.SocketRow{Owner: 7, Kind: 0, LocalIP: [4]byte{10, 0, 0, 1}, LocalPort: 2222}
}

func conn_row() vi.SocketRow {
	return vi.SocketRow{Owner: 7, Kind: 1, State: 1, LocalIP: [4]byte{10, 0, 0, 1},
		LocalPort: 2222, RemoteIP: [4]byte{10, 0, 0, 2}, RemotePort: 12345}
}
