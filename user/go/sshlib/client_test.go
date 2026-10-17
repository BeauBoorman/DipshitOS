package sshlib

import (
	"testing"

	"virelai/ed25519"
)

func pump(t *testing.T, cl *Client, srv *Server, rounds int) {
	t.Helper()
	out := cl.Start()
	for i := 0; i < rounds; i++ {
		if cl.Closed() && (srv.Closed() || len(out) == 0) {
			return
		}
		out = srv.Feed(out)
		if cl.Closed() && len(out) == 0 {
			return
		}
		out = cl.Feed(out)
		if len(out) == 0 && !cl.Closed() {
			out = cl.Feed(nil)
		}
	}
}

func TestClientNewkeysThenServiceConcatenated(t *testing.T) {
	hostSeed, _ := ParseHex32("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
	userSeed, _ := ParseHex32("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
	alice, _ := ParseHex32("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	bob, _ := ParseHex32("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
	hostPub := ed25519.EdDerivePublic(hostSeed)
	cc, sc := testClientCfg(userSeed, hostSeed, alice, bob, hostPub, true, true, "VIRELAI-GATE-EXEC")
	cl := NewClient(cc)
	srv := NewServer(sc)
	out := cl.Start()
	var newkeys []byte
	for i := 0; i < 12 && newkeys == nil; i++ {
		out = srv.Feed(out)
		out = cl.Feed(out)
		if cl.sendCipher != nil && cl.phase == phaseKex && len(out) == 16 {
			newkeys = append([]byte(nil), out...)
		}
	}
	if newkeys == nil {
		t.Fatal("client never flushed a min-pad NEWKEYS write")
	}
	// Server NEWKEYS is still in the client's input (flush returned first).
	_ = cl.Feed(nil)
	service := cl.Feed(nil)
	if cl.authState != 1 || len(service) == 0 {
		t.Fatalf("expected SERVICE_REQUEST authState=1 out=%d", len(service))
	}
	combined := append(append([]byte(nil), newkeys...), service...)
	got := srv.Feed(combined)
	if srv.Failed() {
		t.Fatal("server leftover-decrypt of NEWKEYS||SERVICE_REQUEST failed")
	}
	if len(got) == 0 {
		t.Fatal("server produced no SERVICE_ACCEPT after concatenated feed")
	}
}

func testClientCfg(userSeed, hostSeed, alice, bob [32]byte, pin [32]byte, hasPin, hasSeed bool, cmd string) (ClientConfig, ServerConfig) {
	userPub := ed25519.EdDerivePublic(userSeed)
	cl := ClientConfig{
		User:      "alice",
		Cmd:       cmd,
		HostPin:   pin,
		HasPin:    hasPin,
		UserSeed:  userSeed,
		HasSeed:   hasSeed,
		Cookie:    []byte{0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01},
		Ephemeral: alice[:],
	}
	srv := ServerConfig{
		HostSeed:  hostSeed,
		Keys:      []AuthKey{{User: "alice", Pub: userPub}},
		Cookie:    []byte{0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff},
		Ephemeral: bob[:],
		Run: func(cmd string) ([]byte, uint32, error) {
			return []byte("VIRELAI-SSH5-OK\n"), 0, nil
		},
	}
	return cl, srv
}

func TestClientKexAuthExec(t *testing.T) {
	hostSeed, ok := ParseHex32("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
	if !ok {
		t.Fatal("host seed")
	}
	userSeed, _ := ParseHex32("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
	alice, _ := ParseHex32("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	bob, _ := ParseHex32("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
	hostPub := ed25519.EdDerivePublic(hostSeed)
	cc, sc := testClientCfg(userSeed, hostSeed, alice, bob, hostPub, true, true, "VIRELAI-GATE-EXEC")
	cl := NewClient(cc)
	srv := NewServer(sc)
	pump(t, cl, srv, 40)
	if cl.Failed() {
		t.Fatalf("client failed stage=%s err=%s", cl.Stage, cl.ErrName)
	}
	if !cl.Closed() {
		t.Fatal("client did not close")
	}
	if cl.RemoteChan != ServerChanID {
		t.Fatalf("remote chan = %d want %d", cl.RemoteChan, ServerChanID)
	}
	if string(cl.Stdout) != "VIRELAI-SSH5-OK\n" {
		t.Fatalf("stdout = %q", cl.Stdout)
	}
	if cl.ExitStatus == nil || *cl.ExitStatus != 0 {
		t.Fatalf("exit-status = %v", cl.ExitStatus)
	}
}

func TestClientHostKeyMismatch(t *testing.T) {
	hostSeed, _ := ParseHex32("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
	userSeed, _ := ParseHex32("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
	alice, _ := ParseHex32("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	bob, _ := ParseHex32("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
	wrong, _ := ParseHex32("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7")
	cc, sc := testClientCfg(userSeed, hostSeed, alice, bob, wrong, true, true, "VIRELAI-GATE-EXEC")
	var logs []string
	sc.Log = func(s string) { logs = append(logs, s) }
	cl := NewClient(cc)
	srv := NewServer(sc)
	pump(t, cl, srv, 40)
	if cl.ErrName != "HostKeyMismatch" || cl.ExitCode != ExitPin {
		t.Fatalf("err=%s code=%d stage=%s", cl.ErrName, cl.ExitCode, cl.Stage)
	}
	for _, s := range logs {
		if s == "service-accept ssh-userauth" {
			t.Fatal("userauth started after pin mismatch")
		}
	}
}

func TestClientMissingCredential(t *testing.T) {
	hostSeed, _ := ParseHex32("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
	userSeed, _ := ParseHex32("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
	alice, _ := ParseHex32("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	bob, _ := ParseHex32("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
	hostPub := ed25519.EdDerivePublic(hostSeed)
	cc, sc := testClientCfg(userSeed, hostSeed, alice, bob, hostPub, true, false, "VIRELAI-GATE-EXEC")
	cl := NewClient(cc)
	srv := NewServer(sc)
	pump(t, cl, srv, 40)
	if cl.ErrName != "MissingCredential" || cl.ExitCode != ExitAuth {
		t.Fatalf("err=%s code=%d stage=%s", cl.ErrName, cl.ExitCode, cl.Stage)
	}
}

func TestClientAuthRejected(t *testing.T) {
	hostSeed, _ := ParseHex32("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
	userSeed, _ := ParseHex32("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
	wrongSeed, _ := ParseHex32("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7")
	alice, _ := ParseHex32("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	bob, _ := ParseHex32("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
	hostPub := ed25519.EdDerivePublic(hostSeed)
	cc, sc := testClientCfg(userSeed, hostSeed, alice, bob, hostPub, true, true, "VIRELAI-GATE-EXEC")
	cc.UserSeed = wrongSeed
	cl := NewClient(cc)
	srv := NewServer(sc)
	pump(t, cl, srv, 40)
	if cl.ErrName != "AuthRejected" || cl.ExitCode != ExitAuth {
		t.Fatalf("err=%s code=%d stage=%s", cl.ErrName, cl.ExitCode, cl.Stage)
	}
}

func TestClientTamperedMAC(t *testing.T) {
	hostSeed, _ := ParseHex32("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
	userSeed, _ := ParseHex32("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
	alice, _ := ParseHex32("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	bob, _ := ParseHex32("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
	hostPub := ed25519.EdDerivePublic(hostSeed)
	cc, sc := testClientCfg(userSeed, hostSeed, alice, bob, hostPub, true, true, "VIRELAI-GATE-EXEC")
	cl := NewClient(cc)
	srv := NewServer(sc)
	out := cl.Start()
	sawClientNewkeys := false
	var encrypted []byte
	for i := 0; i < 20 && encrypted == nil; i++ {
		out = srv.Feed(out)
		if sawClientNewkeys && len(out) >= PolyTagLen+8 {
			encrypted = out
			break
		}
		out = cl.Feed(out)
		if len(out) == 0 && !cl.Closed() {
			out = cl.Feed(nil)
		}
		if cl.flushAfterNewkeys {
			t.Fatal("flushAfterNewkeys still set after Feed returned")
		}
		if !sawClientNewkeys && cl.sendCipher != nil && cl.phase == phaseKex {
			// The Feed that sent our NEWKEYS must not also carry ciphertext.
			if len(out) != 16 {
				t.Fatalf("NEWKEYS write was %d bytes; want min-pad 16", len(out))
			}
			sawClientNewkeys = true
		}
	}
	if encrypted == nil {
		t.Fatal("server never produced an encrypted packet after client NEWKEYS")
	}
	encrypted[len(encrypted)-1] ^= 0x01
	_ = cl.Feed(encrypted)
	if cl.ErrName != "BadPacket" || cl.ExitCode != ExitTransport || cl.Stage != "protocol" {
		t.Fatalf("err=%s code=%d stage=%s", cl.ErrName, cl.ExitCode, cl.Stage)
	}
}

func TestParseKnownHosts(t *testing.T) {
	pub, _ := ParseHex32("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
	body := "#v1\n10.0.0.2\t2222\tssh-ed25519\td75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a\n"
	pin, found, ok := ParseKnownHosts(body, "10.0.0.2", 2222)
	if !ok || !found || pin != pub {
		t.Fatalf("pin=%x found=%v ok=%v", pin, found, ok)
	}
	_, found, ok = ParseKnownHosts(body, "10.0.0.2", 22)
	if !ok || found {
		t.Fatal("wrong port should be missing, not malformed")
	}
	if _, _, ok := ParseKnownHosts("not-v1\n", "10.0.0.2", 2222); ok {
		t.Fatal("missing #v1 accepted")
	}
}
