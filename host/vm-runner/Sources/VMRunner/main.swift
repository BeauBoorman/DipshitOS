// VirelaiOS VM runner for the Apple Virtualization.framework path.
//
// Usage: VMRunner <disk-image> [serial-log] [--screen <png>]
//        VMRunner --overlay-base <base.img> [serial-log] [flags...]
// (--overlay-base: macOS 27 DiskImageKit stacked image — read-only base +
//  throwaway ASIF overlay per run; positional <disk-image> is then ignored.
//  --vars <path>: per-run EFI variable store.)
//         [--secure-boot --secure-boot-pk <DER cert>
//          --secure-boot-db-efi <PE> | --secure-boot-db-hash <64-hex>]
//          (M113b #2418, ADR 0054 Part I: opt-in UEFI Secure Boot — a
//          FRESH per-run variable store, a custom Platform Key, and db
//          entries of PE/COFF Authenticode digests (the convention the
//          firmware enforces) or raw hashes. The firmware refuses an
//          unpinned BOOTAA64.EFI before any guest code runs. Both
//          db flags are repeatable. OFF by default: without the flag the
//          store and every device are byte-identical.)
//         [--vz-restore] (claim #1370: standalone headless save/restore probe —
//          real VZ pause/saveMachineStateTo/stop/restoreMachineStateFrom/resume;
//          a fresh post-restore serial query must recover a RAM-only clipboard
//          marker. Supports only --overlay-base/--vars/--serial/--cpus/--timeout;
//          needs --timeout in (0,600]. See docs/hardware-contract.md.)
//         [--data-disk <img>] (M100b, #2307, ADR 0050: a second virtio-blk
//          function — the guest's VLFS data disk; raw RW image created if
//          absent, blockDeviceIdentifier "virelai-vlfs", sync .full.
//          Coexists with --overlay-base, which covers the boot disk only.)
//          [--vz-restore-save <dir>] [--vz-restore-load <dir>] (M70g G3, #1459:
//          restore beyond same-process — one process boots, stores the marker,
//          saves state + the ASIF overlay + the marker into <dir> and exits;
//          a NEW process restores from <dir> instead of booting and must
//          recover the marker.) Device knobs --display/--input/--usb-msd/
//          --custom-virtio/--gpu3d-metal/--vsock are accepted under
//          --vz-restore so their save/restore verdict can be measured
//          (validateSaveRestoreSupport + the full cycle); a refusal is
//          printed as `VZ-RESTORE: validateSaveRestoreSupport REFUSED ...`
//          before the error exit.
//         [--vsock [--vsock-port <n>] [--vsock-ctl [--vsock-ctl-port <n>]]]
//          (M115a, #2460: attach Apple's
//          VZVirtioSocketDevice and arm a host listener on port <n>,
//          default 1208. A guest connect to that port is accepted and
//          printed as `VSOCK: listener accepted guest connect ...`.
//          M115b, #2461: --vsock-ctl arms the virelai-ctl/1 endpoint on
//          --vsock-ctl-port, default 1209 — the HMAC-challenged
//          suspend/snapshot wire, keyed by the share's vsock-ctl
//          SECRETS.TXT row (either host channel's share is read); no
//          row, no listener. M115d, #2463: `suspend` is armed — pause,
//          save into the profile's saved-state/, reply ok, stop, exit.)
//         [--profile <path>] (M115c, #2462: boot from a .virelaivm bundle —
//          a manifest-gated directory holding efi-vars.bin, the PERSISTENT
//          overlay.asif over config.json's base image, vlfs.img, share/,
//          machine-id.bin and saved-state/. An absent path is minted; an
//          existing one must carry a readable virelaivm/1 manifest or the
//          run refuses by name. Profile members are DEFAULTS: explicit
//          --vars/--overlay-base/--data-disk/--cvc-file/--cpus flags win.
//          --profile-init mints/validates the bundle and exits without
//          booting — tools/session.sh runs it before seeding the share.)
//         [--resume <path>] (M115d, #2463: boot the profile's saved-state/
//          instead of the boot image — the continuation of a ctl `suspend`.
//          Requires an existing bundle AND a written state.vzsave; both
//          refuse by name. Mutually exclusive with --vz-restore and
//          --profile-init; the ctl listener re-arms so the resumed
//          machine can suspend again.)
//         [--apply-update] [--rollback-update] [--update-key <64-hex>]
//          (M115f, #2465: verify the signed staged set in <share>/UPDATE/
//          and swap it in as the boot base image, retaining <base>.prev;
//          --rollback-update swaps it back. The trust pin comes from
//          --update-key or the profile's config.json updatePubkey. A
//          refused set fails the run by name; absent is "none staged".)
//         [--timeout <s|0>] (0 = run until Ctrl-C) [--expect <line>] [--terminal-marker <line>]
//         [--host-session] (tools/session.sh's bundled local front door;
//          close/Quit stop the VM, failures stay visible until dismissed)
//         [--cpus <n>] (claim 907: VCPU count, default 2 — the four-core
//          four-domain stress gate boots 4)
//         [--memory-mib <n>] (M129a #2610: guest RAM in MiB, 64...2048,
//          default 512 — wins over a profile's config.json memoryMiB)
//         [--console] [--console-tcp [host:]port[:secret]] [--console-tcp-secret-file <path>]
//          (M70g G2 #1459: secret from a file's first line, never argv)
//         [--debug-input] [--dump-marker <file>]
//         [--nvram-console <file>] [--script <file>]
//         [--script-after <text>] [--script-expect <text>]
//         [--script-expect-tail <s>] (claim 4912: hold the VM this long
//          after the expected transcript first appears, so the kernel's
//          async reap/report tail reaches the serial log before teardown;
//          default 1.5, 0 = stop on first match) [--custom-virtio]
//         [--cvc-echo] (claim 3141: the host-initiated custom-virtio push
//          echo — implies --custom-virtio and attaches a third queue)
//         [--via-virtio] (claim 9588, issue #523 item 3: inject keys through
//          the custom-virtio INPUT queue — queue 3 — instead of synthesizing
//          NSEvents into a view; implies --custom-virtio AND --cvc-echo,
//          attaching the full four-queue shape. HID-shaped 16-byte messages
//          per docs/hardware-contract.md. No window, no activation wall
//          (#151), no silent synthesized drop (#179).)
//         [--cvc-snap] (claim 0680, issue #523 item 3 capstone: attach the
//          FIFTH virtqueue — the framebuffer-snapshot channel. The guest
//          streams its composed scanout over queue 4 as tagged binary
//          messages; the runner reassembles them into a raw BGRX file.
//          Implies --via-virtio.)
//         [--cvc-file <host-dir>] (M34 HF1+HF2, issues #735/#736: attach
//          the SIXTH virtqueue — the host file channel. The guest userland
//          filesystem becomes a macOS folder served over queue 5 with plain
//          FileManager calls rooted at <host-dir> (wire format in
//          Sources/VFWire/VFWire.swift). The deepest flag implies the full
//          five-queue shape below it.)
//         [--host-clipboard] (M108b #2325, ADR 0051: the bidirectional
//          clipboard lane — signed VHI1 record files in <share>/HOSTINT/.
//          Guest→host: seat-emitted CLIP_OUT is mirrored to the
//          pasteboard; host→guest: changeCount polls emit CLIP_IN the
//          seat applies. Requires --cvc-file and a `host-int` row in the
//          share's SECRETS.TXT; OFF by default — no directory, no
//          records, no pasteboard read.)
//         [--host-pasteboard <name>] (retarget the clipboard lane to
//          NSPasteboard(name:) — mandatory for gates so a run never
//          clobbers .general; modifier on --host-clipboard)
//         [--host-clip-in <text>] [--host-clip-in-after <marker>]
//          (test hook: write <text> to the lane pasteboard once <marker>
//          appears — a real changeCount bump the ordinary path then
//          carries in. Default trigger: `gotabwm: hostint armed`.)
//         [--host-drop] (M108c #2326, ADR 0051 D4: the host→guest file-drop
//          lane — the display view registers .fileURL; dropped files land
//          in <share>/INBOX/ via temp+rename (≤64 MiB/file, ≤16/gesture)
//          and a signed DROP record announces each for the seat's toast.
//          Requires --cvc-file, the `host-int` SECRETS.TXT row, and a
//          display path; OFF by default — no INBOX/, no drag target, no
//          records.)
//         [--host-drop-file <path>] [--host-drop-after <marker>]
//          (test hook: feed <path> through the real drop handler once
//          <marker> appears — repeatable for multi-file gestures.
//          Default trigger: `gotabwm: hostint armed`.)
//         [--host-notify] (M108d #2328, ADR 0051 D5: seat toasts cross the
//          glass — each kind-12 toast becomes a signed NOTIFY_OUT record
//          the runner posts as a UNUserNotificationCenter banner. Banners
//          exist only under the `just session` bundle; the bare runner
//          consumes records and logs `host-notify: dropped
//          reason=no_bundle` per record instead. Requires --cvc-file and
//          the `host-int` SECRETS.TXT row; OFF by default — no records
//          polled, no center touched.)
//         [--host-outbox] (M127d #2602, ADR 0051 V2-D5: the guest→host
//          export lane — GOSH `export` / GOFILES "Export to Host" stage
//          <share>/OUTBOX/<name> + a REQ intent marker; the seat signs an
//          OUTBOX record and the runner verifies, then moves the payload
//          to --host-outbox-dir (default ~/Downloads). Caps: ≤64 MiB/file
//          at move time, ≤64 exports/epoch, ≤1 record per tick. Requires
//          --cvc-file and the `host-int` SECRETS.TXT row; OFF by default
//          — no OUTBOX/, no records.)
//         [--host-outbox-dir <path>] (modifier on --host-outbox: the
//          export landing. Default ~/Downloads — the flag is the gate
//          redirect, so a class-B run never touches a real Downloads.)
//         [--host-cmd-after <marker>:<verb>] (M114a #2454, index #2447:
//          dispatch <verb> on the HostCommand bus — the same seam every
//          AppKit menu item uses — once <marker> appears in the serial
//          stream. Repeatable; <verb> is the suffix after the LAST colon
//          and unknown verbs are a parse-time error. Every dispatch emits
//          one `host-ui: cmd=<verb> state=<...>` receipt on stdout.
//          Requires --script or --host-session, where the marker scan
//          runs.)
//         [--host-capture-keys] (M114b #2455, index #2447: arm the machine
//          view's capturesSystemKeys at startup by dispatching the
//          capture-keys verb on the HostCommand bus once the
//          VZVirtualMachineView exists — the same host-ui: receipt as
//          ⌥⌘K / the toolbar pill / a --host-cmd-after trigger. Requires
//          a view: --screen/--display/--host-session.)
//         [--host-serial-send <line>] (M114d #2457, index #2447: arm the
//          inspector drawer's input line — the send-serial verb (a
//          --host-cmd-after trigger, or the drawer's Send) writes it into
//          the console pipe, the same path --script forwards through.
//          The dispatch receipts `disabled` without a guest RX path:
//          --script/--console/--host-session/--vz-restore provide one.)
//         [--cvc-console-file <path>] (claim 0680: structured console —
//          capture every queue-1 guest log line to <path>; also arms the
//          guest's console tee with a kind-3 control message once the pool
//          is ready. Requires --custom-virtio.)
//         [--snapshot-after <marker>] (claim 0680: fire one kind-4 snapshot
//          request when <marker> appears in the serial stream; repeatable,
//          each instance writes <base>-<n>.raw. Requires --screen (the GPU
//          owns the framebuffer). Implies --cvc-snap.)
//         [--snapshot-out <base>] (claim 0680: override the snapshot output
//          base path; default is the --screen base + "-snap".)
//         [--snapshot-drain-timeout <sec>] (issue 1788: hold the VM at
//          teardown, up to <sec>, while an armed kind-4 snapshot stream is
//          still in flight, so a stop cannot eat a frame the gate is
//          entitled to. Default 20; 0, negative, or unparsable = stop
//          immediately, the --script-expect-tail convention.)
//         [--sound] (milestone fifteen card A1, claim 6140: attach one
//          VZVirtioSoundDeviceConfiguration with one
//          VZVirtioSoundDeviceOutputStreamConfiguration (the PCM output
//          stream) carrying a VZHostAudioOutputStreamSink, so the guest's
//          virtio-snd device is discovered and its output can play on the
//          host speakers. OFF by default: without the flag
//          config.soundDevices stays [] — every existing gate is
//          byte-identical.)
//         [--script2 <file> --script2-after <text>] (claim 4613: a second
//          scripted phase, forwarded once after its own serial marker)
//         [--script3 <file> --script3-after <text>] (claim 7786: a third
//          scripted phase, forwarded once after its own serial marker)
//         [--net <capture-file>] (milestone five card N1, claim 1373: attach
//          one VZVirtioNetworkDeviceConfiguration with a
//          VZFileHandleNetworkDeviceAttachment so the guest's virtio-net TX
//          frames are captured byte-exactly to <capture-file> (raw Ethernet
//          bytes, host writes them as they arrive). The guest MAC is FIXED
//          (02:00:00:00:00:01) so the guest-side VIRTIO_NET_F_MAC read is
//          deterministic and gate-assertable. OFF by default: without the
//          flag config.networkDevices stays [] — every existing gate is
//          byte-identical.)
//         [--net-sntp-respond <host-ip>[:<port>]] (M83b #1775: a tiny
//          deterministic host-side SNTP server inside the capture thread
//          — the guest's client-mode (3) NTP request for <host-ip>:<port>
//          (default 123) is answered with an RFC 4330 server packet
//          carrying host wall-clock time, the request's transmit
//          timestamp echoed as the originate timestamp. Requires --net.
//          OFF by default.)
//         [--net-sntp-skew <seconds>] (M83b: signed seconds added to the
//          host clock for every served timestamp, so a gate can prove the
//          guest clock really moved; default 0; requires
//          --net-sntp-respond.)
//         [--net-ra-respond <v6-prefix>/64] [--net-ndp-respond <v6-addr>]
//          [--net-icmp6-respond <v6-addr>] (M117b #2474, ADR 0057 D10: the
//          three v6 hermetic responders — request-driven synthesizers in
//          the capture thread, the --net-arp-respond shape. On a guest
//          Router Solicitation, --net-ra-respond answers with an RA from
//          the router link-local fe80::ff:fe00:2 carrying the argument
//          /64 prefix as an A+L PIO. On a guest Neighbor Solicitation
//          whose target is a listed address, --net-ndp-respond (repeatable)
//          answers with an NA (S=1 O=1, TLLA 02:00:00:00:00:02); when
//          --net-ra-respond is set the router link-local is implicitly
//          listed. On an ICMPv6 echo request for the address,
//          --net-icmp6-respond answers with the echo reply — id/seq/
//          payload byte-exact. All require --net. An unlisted target or
//          an unset flag goes unanswered — the refusal leg.)
//         [--net-udp6-respond [<v6-addr>]:<host-port>]
//          [--net-tcp6-respond [<v6-addr>]:<host-port>] (M117c #2475,
//          ADR 0057: the v6 transport responders — the N5 UDP echo and
//          the N10 TCP handshake/echo shapes on the fixed 40-byte
//          header. The bracketed literal keeps the address's own colons
//          out of the port split — the same shape `vi.Dial` speaks.
//          The UDP6 reply echoes the datagram byte-exact (v6 src/dst
//          swapped, UDP ports swapped, the pseudo-header checksum over
//          the 16-byte addresses recomputed). The TCP6 server answers
//          the guest's SYN with a SYN-ACK (the FIXED ISN 0x12345678),
//          data with an ACK + the payload echoed (or the HTTP 200 on a
//          GET / port 80/8080 — the v4 responder's same answer table),
//          and FIN with FIN-ACK; per-connection state keys on the
//          guest's v6 src addr:port. Both require --net.)
//         [--net-dhcp-respond <lease-ip>] (milestone five card N8, claim
//          0351: a tiny deterministic host-side DHCP server inside the
//          capture thread — the guest's DHCPDISCOVER is answered with an
//          OFFER and its REQUEST with an ACK, both carrying the FIXED
//          gate-assertable lease {ip=<lease-ip>, mask 255.255.255.0,
//          gateway 10.0.0.1, server id=<lease-ip>, lease 3600}, the
//          guest's xid echoed byte-exact, written into the SAME
//          attachment socket end (VZ reads fds[0], so the guest receives
//          it). Requires --net. OFF by default: the default VM is
//          unchanged.)
//         [--net-tcp-respond <host-ip>:<host-port>] (milestone five card
//          N10, claim 7026: a tiny deterministic host-side TCP server
//          inside the capture thread — the guest's SYN is answered with a
//          SYN-ACK (the FIXED gate-assertable server ISN 0x12345678, ack
//          = the guest's ISN+1), its data segment with an ACK + the SAME
//          payload echoed byte-exact, and its FIN with a FIN-ACK, all
//          written into the SAME attachment socket end. An optional
//          `:handshake` suffix (card N11, claim 5357) answers the SYN
//          with a SYN-ACK then goes SILENT on data/FIN — the
//          deterministic black hole for the retransmission-bound run.
//          M51 SSH1 (#1168) added a `:packet` suffix (paced payload) and
//          M51 SSH5 (#1172) a `:ssh` suffix (the runner-hosted minimal
//          SSH-2 server, VSSH). M51 real-OpenSSH interop (#1209, goal
//          #1066, ADR 0025 D8) adds a `:relay` suffix with
//          [--net-tcp-respond-relay <host-ip>:<host-port>]: the same
//          deterministic TCP endpoint, but the byte stream is proxied
//          byte-for-byte (NO crypto in the runner) to that real upstream
//          TCP server — e.g. a local OpenSSH `sshd` — so the guest's
//          SSH.BIN negotiates with real OpenSSH. The documented manual
//          check, never a CI gate.
//          Requires --net. OFF by default: the default VM is unchanged.)
//         [--net-tcp-connect <guest-ip>:<port>[:<payload-file>|ssh]]
//          [--net-tcp-connect-stream <executable>] (hermetic --net gate only;
//           its exit closes the connection: status 0 sends FIN, else RST)
//          [--net-tcp-connect-stream-arg <arg>] (repeatable; stream argv)
//          [--net-tcp-connect-intruder] (stream only: a second SYN from
//           another port once the guest speaks; reports whether it answered)
//          [--net-tcp-connect-after <text>]
//          [--net-tcp-connect-close-after <text>]
//          [--net-tcp-connect-secret <s>] (M50 TS4: answer the guest's
//           VIRELAIOS-AUTH/1 challenge with HMAC-SHA256(s))
//          [--net-tcp-connect-mac <hex>] (M50 TS4 replay: send this
//           pre-recorded MAC line instead of computing one)
//          [--net-tcp-connect-ssh-exec <cmd>] [--net-tcp-connect-ssh-user <name>]
//          (M45 SH7, issue #1083,
//          ADR 0020 Amendment B: the host INITIATES an inbound TCP
//          connection TO a guest listener — the reverse of
//          --net-tcp-respond. After <text> (default "sh: remote") the host
//          sends a SYN, completes the handshake against the guest server's
//          fixed ISN 0x54321098, sends the payload file's bytes, captures
//          the guest shell's reply, and closes with a FIN — the guest
//          auto-detaches on disconnect. <close-after> (optional) delays the
//          FIN until the reply contains that text. M70g G1 (#1491): a
//          `:ssh` suffix speaks the ADR 0025 D2 profile as a client
//          (VSSH.SSHClient) against the in-guest GOSSHD.ELF, paced one
//          ≤192-byte segment per guest ACK. Requires --net. OFF by
//          default: every existing gate is byte-identical.)
//         [--net-nat] (milestone five card N7, claim 4678: attach one
//          VZVirtioNetworkDeviceConfiguration with a
//          VZNATNetworkDeviceAttachment instead of the file-handle
//          attachment — the host serves as router + NAT for the guest's
//          accesses to outside networks. No capture file (the host
//          translates the frames — that is the point), so the N7 gate
//          asserts GUEST-OBSERVED COUNTERS, not capture bytes.
//          Mutually exclusive with --net (one network device per guest for
//          now); the fixed locally-administered MAC 02:00:00:00:00:01 is
//          set on the device config and what the guest actually observes
//          under NAT is a claim-time observation, pinned in the hardware
//          contract. OFF by default: without the flag
//          config.networkDevices stays [] — every existing gate is
//          byte-identical.)
//         [--net-bridged <iface>] (M117d, issue #2476, ADR 0057 D11:
//          attach one VZVirtioNetworkDeviceConfiguration with a
//          VZBridgedNetworkDeviceAttachment on the named
//          VZBridgedNetworkInterface — the guest sits on the host's real
//          LAN (its own MAC, a real DHCP lease). OFF by default. Every
//          missing piece refuses by name: an <iface> absent from
//          VZBridgedNetworkInterface.networkInterfaces names itself; the
//          com.apple.vm.networking entitlement absent from this binary's
//          signature names itself (it is a RESTRICTED entitlement — an
//          ad-hoc codesign cannot carry it; entitlements-net.plist is the
//          set for a development-signed build). Mutually exclusive with
//          --net/--net-nat/--net-vmnet — one network device per guest.)
//         [--net-vmnet] (M117d, issue #2476, ADR 0057 D11: attach one
//          VZVirtioNetworkDeviceConfiguration with a
//          VZVmnetNetworkDeviceAttachment on a shared-mode vmnet logical
//          network (vmnet_network_create, macOS 26+ — the daemon serves
//          DHCP + NAT44/66 by default). OFF by default. A non-success
//          vmnet_return_t from vmnet_network_create fails carrying the
//          status and naming the com.apple.developer.networking.vmnet
//          entitlement (or root) the daemon demands — also restricted,
//          also in entitlements-net.plist. Same mutual exclusivity.
//          [--net-vmnet-subnet <a.b.c.d>/<len>] pins the network's IPv4
//          subnet (e.g. 192.168.77.0/24 — the daemon picks a rotating
//          /24 under 192.168/16 otherwise). The address must be the
//          network base. Requires --net-vmnet.)
//         [--net-inject <file>] [--net-inject-after <text>] (milestone five
//          card N2, claim 6076: the host->guest RX direction of the SAME
//          --net attachment — the file's bytes are written into the socket
//          end VZ delivers from, exactly ONCE, when <text> appears in the
//          serial log (default "net: rx-armed" — the guest's queue-0 RX
//          buffer is guaranteed supplied by then; deterministic, not a
//          sleep). Requires --net. OFF by default: the default VM — and the
//          29-gate aggregate — stays byte-identical. The injected bytes are
//          the KNOWN raw Ethernet frame the guest's net recv must print
//          byte-exact; the guest's netsend echo proves the round trip.)
//
// * --custom-virtio (macOS 27 spike, audit step 3): attaches one
//   default-off VZCustomVirtioDeviceConfiguration so the guest's PCI
//   discovery can observe it on a real VZ boot (VID 0x1af4, DID 0x1082,
//   class 0x00/0x00, 2 queues). Without the flag the VM configuration is
//   byte-identical to before — all existing gates are unchanged. NOTE:
//   Xcode 27 beta 4 exposes no host-triggered guest-interrupt API; the
//   spike proves discovery + queue transport (audit step 4) and the
//   used-ring IRQ via returnToQueue (audit step 5, claim 0828).
//
// * --gpu3d-metal (M102d3, issue #2168): attaches ONE additional custom-
//   virtio device — the experimental private render device (virtio deviceID
//   0x43, PCI DID 0x1083, class 0x03/0x00, 2 queues) served by b2's VIR1
//   envelope core with c2's real Metal backend. APPENDED to the
//   custom-virtio list: the 0x42 channel and the native 2D GPU are
//   untouched, and without the flag the VM configuration is byte-identical
//   to before. A Metal device that cannot initialize is a named failure,
//   never a fallback. Requires the SPIKE build (macOS 27 custom-virtio SDK
//   types); an ordinary build rejects the flag by name.
//   [--gpu3d-test-mode <delay|wrong-fence|stall>] selects one of c2's
//   deterministic completion-fault knobs; SPIKE-only, requires
//   --gpu3d-metal, and OFF by default — no fault mode exists without it.
//
// * --virtio-fs <host-dir> (M83g): attach Apple's standard VirtioFS device,
//   independently of the custom-virtio spike. The directory is shared
//   writable under the guest's fixed `virelaios` tag. Unlike custom virtio,
//   this standard device is eligible for VZ machine-state save/restore.
//
// * --nvram-console <file> (M1.5 VZ serial-gate successor, claim 0015):
//   before exiting, reconstruct the kernel's post-exit console stream from
//   the EFI variable store (artifacts/efi-vars.bin). In nvram-console
//   builds the kernel writes every console byte as chunked EFI variables
//   `VirelaiC0`, `VirelaiC1`, ... via runtime SetVariable — the one
//   post-exit-safe device channel on VZ (post-exit access to the
//   virtio-pci transport hangs, claim 0013). Each chunk value is prefixed
//   with the in-band marker `VIRELAIC <idx>:`; the host byte-scans the
//   store (file order == write order), validates the chunk indices, and
//   concatenates the payloads. The reconstructed text is written to
//   <file> and printed. In this mode the exit code is 0 iff reconstructed
//   output is non-empty — the NVRAM channel, not the (silent) serial
//   channel, is the gate. The serial evidence gate above is unchanged
//   when the flag is absent.
//
//   NOTE: the reconstructed bytes travelled the NVRAM variable channel,
//   NOT the virtio serial pipe — vm-serial.log stays 0 B. This is the
//   fallback channel claim 0013 named, and it makes post-exit console
//   evidence observable on VZ for the first time.
// * --dump-marker <file> (ADR 0004 D4 fixed-memory-marker fallback, gate
//   work item 3, claim 0009): before exiting, read the EFI variable store
//   (artifacts/efi-vars.bin) and save the ordered ladder of M2_* marker
//   instances the kernel wrote (the kernel persists each takeover stage as
//   the non-volatile variable `VirelaiM2` via runtime SetVariable, which
//   survives ExitBootServices on VZ). In this mode the exit code is 0 iff at
//   least one marker instance was found — the marker channel, not the
//   (silent) serial channel, is the gate. The serial evidence gate above is
//   unchanged when the flag is absent.
//
//   NOTE: the original memory-dump form (scanning this process's address
//   space for the BSS marker, on the assumption that the in-process VZ guest
//   RAM is host-mapped) is provably impossible on VZ: a full submap-aware
//   walk finds no 256 MiB guest-RAM region and every M2_* hit is this
//   runner's own constant array (claim 0009, artifacts/marker-dump.txt). The
//   NVRAM ladder is the working form of the fallback.
//
// Two modes:
//   * default (evidence gate): starts the VZ guest, captures the
//     virtio-console serial stream to the log, and reports success only
//     after the requested serial line and terminal line have both been
//     observed. This is the milestone-two evidence path (`zig build run`)
//     and is unchanged by the M1.5 console work.
//   * --console (M1.5 host plumbing): duplex serial attachment. The
//     attachment's fileHandleForReading is a real host input source (stdin
//     forwarded through a pipe), guest output is teed live to the terminal
//     AND to the serial log, and the host terminal is put into character
//     mode with its original settings restored on normal exit, on
//     ^C / SIGTERM / SIGHUP, and on failure.
//
// Honest limits (see docs/status.md, ADR 0004):
//   * The guest serial console has NO RX path. Bytes forwarded to the
//     serial attachment enter the guest's virtio-console input device, but
//     nothing in this slice proves the kernel received them — guest RX is a
//     separate milestone slice. `--debug-input` only shows bytes handed to
//     the attachment, not guest receipt.
//   * The VZ serial gate is blocked as of 2026-08-06 (vm-serial.log empty in
//     every saved run), so console mode currently shows no guest output.
// No guest filesystem or POSIX dependency is added; the guest is untouched.

import AppKit
import ApplicationServices
import CryptoKit
import Darwin
// DiskImageKit ships in the macOS 27 SDK only (#523 item 2). The class-A
// CI job builds against the older macos-latest SDK, so the import and the
// --overlay-base implementation are compiled in ONLY when the SDK has the
// framework; elsewhere the flag fails honestly at runtime.
#if canImport(DiskImageKit)
import DiskImageKit
#endif
import Foundation
import ScreenCaptureKit
import Security
import Virtualization
// M117d (#2476, ADR 0057 D11): vmnet.framework backs --net-vmnet. The
// vmnet_network_* symbols are macOS 26+, so they exist wherever this
// runner's deployment floor applies; the module-level guard keeps an
// older-SDK toolchain compiling — the flag then refuses by name.
#if canImport(vmnet)
import vmnet
#endif
import VFWire
import VMAppKit
import VMDiskImage
import VMGPU3D
import VMPostmortem
import VMProfile
import VMTcp
import VSCtl
import VSNTP
import VSSH

// Diagnostics and the console tee must survive signal exits (SIGINT/SIGTERM),
// so stdout is unbuffered: print() reaches the terminal/file immediately.
setbuf(stdout, nil)

let arguments = CommandLine.arguments
let diskImagePath = arguments.count > 1 ? arguments[1] : "artifacts/disk.img"
var serialLogPath = "artifacts/vm-serial.log"
var screenshotPath: String?
// Card G6 set_visible follow-on (claim 0487): `--screenshot-after <marker>`
// captures the framebuffer ONCE when the marker appears in the serial log
// (deterministic, marker-driven — the fixed 5/10/15 s captures cannot
// guarantee a capture lands inside an EL0 hide/show window). OFF by default;
// a no-op without `--screen` (validated at parse time).
var screenshotAfter: String?
var screenshotAfterCaptured = false
// M81f (#1766): `--host-write <relpath>` + `--host-write-content <text>` +
// `--host-write-after <marker>` — one marker-anchored macOS-side share
// mutation: when <marker> appears in the serial log, write <text> (+ newline)
// into <relpath> under the --cvc-file share dir. Test CHOREOGRAPHY for the
// change-feed gates: the guest must observe the mutation through the same
// stateless file channel it always reads through, so the write happens
// outside the guest, exactly like a real host-side edit. Three flags, not a
// joined `marker:path:text` value — guest markers carry colons (`gofiles:
// watch armed`), so no combined format can delimit them (observed: the
// colon-split first gate run wrote the wrong path). Requires --cvc-file.
var hostWritePath: String?
var hostWriteContent: String?
var hostWriteAfter: String?
var hostWriteFired = false
// Milestone six card G1 (claim 6053): `--display` attaches the virtio-gpu
// device and shows the VM window for the whole session (the machine boots
// to a screen). OFF by default — without the flag config.graphicsDevices
// stays [] exactly as before, so every existing gate stays byte-identical.
// `--screenshot <path>` remains the evidence capture (the two combine:
// `--display --screenshot`).
var displayMode = false
// M128c (#2607): `var`, not `let` — a Finder-launched session arrives
// bare and this flag is set when the open-documents event lands below.
var hostSessionMode = CommandLine.arguments.contains("--host-session")
var hostApplication: HostApplication?
// Milestone seven card I1 (claim 4272; premise corrected by claim 3868):
// `--input` attaches the keyboard + pointing devices
// (VZUSBKeyboardConfiguration +
// VZUSBScreenCoordinatePointingDeviceConfiguration). OFF by default —
// without the flag config.keyboards/pointingDevices stay [] exactly as
// before, so every existing gate stays byte-identical.
//
// CLAIM-TIME OBSERVATION (2026-08-13): these configs do NOT present a
// virtio-input device (DID 0x1052). VZ exposes them as an Apple XHCI USB
// host controller — PCI VID=0x106b DID=0x1a06 CLS=0x0c0330, two MMIO
// BARs (0x50001000 + 0x50000000) — with the keyboard/pointer as USB HID
// devices behind it. So screen-side input needs a USB XHCI + HID stack,
// not a virtio-input transport. See claim 3868 (historical — in git history).
var inputMode = false
// Milestone fifteen card A1 (claim 6140): `--sound` attaches the
// virtio-snd device (VZVirtioSoundDeviceConfiguration with one output
// stream + a VZHostAudioOutputStreamSink). OFF by default — without the
// flag config.soundDevices stays [] exactly as before, so every existing
// gate stays byte-identical. A1 is the TRANSPORT: the guest discovers the
// device, negotiates, and arms the control queue; the PCM playback path
// (the audible beep) is card A2.
var soundMode = false
// M97g (#2084): --no-entropy detaches the virtio-entropy device so a gate
// can prove the guest's slot-72 fail-closed behavior while unseeded.
var noEntropy = false
// M43 card U6 (issue #1037, claim #1040): `--usb-msd <disk.img>` attaches a
// USB mass storage device (VZUSBMassStorageDeviceConfiguration wrapping a
// VZDiskImageStorageDeviceAttachment) on an EXPLICIT VZXHCIControllerConfiguration
// (macOS 15+ API) — the first third USB device class the runner can present.
// OFF by default — without the flag config.usbControllers stays [] exactly as
// before (the M7 keyboard/pointer attachments ride their own config surface
// and are untouched), so every existing gate stays byte-identical. The U1
// bulk probe is the first consumer: the guest enumerates the MSD as a third
// XHCI device (bulk EP1 OUT/IN pair) and `usb bulk` reads the engine state.
var usbMsdPath: String? = nil
// M100b (issue #2307, ADR 0050 D1/D2): `--data-disk <img>` attaches a SECOND
// virtio-blk function as the guest's VLFS data disk — a plain read-write
// VZDiskImageStorageDeviceAttachment (never stacked; the throwaway overlay
// covers the boot disk only) named "virelai-vlfs" via blockDeviceIdentifier,
// synchronizationMode .full so a guest VIRTIO_BLK_T_FLUSH is a host-side
// full sync. A missing file is created as a zero-filled 64 MiB raw image —
// formatting is mkfs.vlfs's job, never the runner's. Off by default: without
// the flag config.storageDevices keeps its single boot element.
var dataDiskPath: String? = nil
// M115c (issue #2462): `--profile <path>` boots a persistent machine from a
// `.virelaivm` bundle instead of the flag-by-flag throwaway pieces. The
// bundle's manifest members fill --vars/--overlay-base/--data-disk/
// --cvc-file and its config.json fills cpus/ram/device defaults — every
// explicit flag wins over the profile member it names. `--profile-init`
// only mints/validates the bundle and exits (session.sh's pre-seed step).
var profilePath: String?
var profileInitOnly = false
// M115d (#2463): `--resume <path>` boots the profile's saved machine
// state instead of the boot image — the continuation of a ctl `suspend`.
var resumeFromPath: String?
// M115f (#2465): `--apply-update` verifies the guest-staged signed set in
// <share>/UPDATE/ (UPDATE.MF + UPDATE.SIG over it) and swaps it in as the
// boot base image, retaining the old base at <base>.prev and discarding
// a profile's persistent overlay.asif. `--rollback-update` swaps .prev
// back. `--update-key <64-hex>` pins the Ed25519 public key the manifest
// must verify under; absent it, a profile's config.json updatePubkey
// applies.
var applyUpdate = false
var rollbackUpdate = false
var updateKeyHex: String?
var memoryMiB = 512
// M129a (#2610): like --cpus, an explicit --memory-mib wins over a profile's
// config.json memoryMiB; without it the bundle's stored value applies.
var memoryMiBExplicit = false
// Milestone seven card I2 (claim 4116): the minimal synthesized-key seam.
// `--input-key <mac-keycode>` posts one keyDown (no keyUp) into the
// VZVirtualMachineView after `--input-key-after <marker>` (default: the
// guest's `usb: enumerated` line), producing ONE deterministic HID report.
// VZ has no programmatic keyboard API — VZUSBKeyboardConfiguration is driven
// only by a view forwarding host key events — so the runner dispatches a
// synthesized NSEvent. The full scripted key-sequence surface is I3.
var inputKeyCode: UInt16?
var inputKeyAfter: String?
// Milestone seven card I3 (claim 6050): the scripted key-SEQUENCE surface.
// `--input-string <ascii>` types the literal string (keyDown + keyUp per
// char, shift for uppercase, `\n` = Enter) into the VZVirtualMachineView
// after `--input-string-after <marker>` (default: the shell's first
// `virelai> ` prompt — typing before the idle loop starts drops keystrokes,
// the interrupt-IN ring buffers one report). The marker watch runs to
// max(40 s, --timeout) — a deep marker needs a session timeout that
// covers it (#2703). This types a real command into Road Pops.
var inputString: String?
var inputStringAfter: String?
// Milestone eight card U2 (claim 1809): the scripted CHORD surface for the
// line-editor live gate. `--input-chords <csv>` types a comma-separated list
// of keystrokes — a printable char, or a named chord (return/up/down/left/
// right/home/end/delete/tab, ctrl-a..ctrl-z, ctrl-space, ctrl-comma) — keyDown + keyUp per chord
// after `--input-chords-after <marker>` (default: the boot self-test line),
// so arrows and Ctrl chords reach the I3 keymap over a real VZ keyboard.
//
// DELIVERY TRANSPORT (read this before writing a gate): the chord sequence
// rides the custom-virtio INPUT queue whenever via-virtio is on — implied by
// --via-virtio, --cvc-file, --cvc-snap, --snapshot-after, and --pointer-virtio
// (the deepest flag implies the shape below it). The cv-input transport needs
// no view/window (headless-safe) but paces at a FIXED 0.25 s per stroke and
// IGNORES --input-chords-delay. The VZVirtualMachineView path (default when
// via-virtio is off) honors --input-chords-delay, so gates that need slow,
// deterministic spacing for cross-process handoffs (launch-then-focus arcs
// like the desktop → FILE.BIN composition) must pass --chords-view to force
// the view path even when --cvc-file (etc.) armed the cv queue. Without it,
// a 0.5 s gap between two Returns is not enough for a freshly exec'd app to
// take focus (observed live 2026-09-01: the second Return re-launched
// FILE.BIN from the desktop menu).
var inputChords: String?
var inputChordsAfter: String?
// Milestone-eight audit follow-up (issue #117): the keyDown/keyUp spacing
// for --input-chords. Default 3.0 s keeps every existing gate byte-identical;
// the input-depth gate lowers it to ~0.3 s to stress the guest's
// multi-TRB interrupt-IN depth. Only meaningful with --input-chords.
// NOTE: only the VZ-view path honors this; the cv-input transport (via-virtio
// armed) paces at a fixed 0.25 s per stroke regardless (see the delivery-
// transport note in the --input-chords doc above).
var inputChordsDelay: Double = 3.0
// M34 HF5 (issue #739): force --input-chords through the VZVirtualMachineView
// (NSEvents, honors --input-chords-delay) even when the custom-virtio INPUT
// queue is attached. See the delivery-transport note in the --input-chords
// doc above — the trigger is any flag that arms via-virtio (most commonly
// --cvc-file), which switches chords to the cv-input transport paced at
// 0.25 s per stroke and ignoring --input-chords-delay. That is too fast for
// a launch-then-focus handoff (observed live: the desktop composition gate's
// second Return hit the desktop before FILE.BIN's window took focus). The
// view path restores the slow, deterministic pacing for display-equipped
// gates. Requires --display (there is no view to post NSEvents into
// otherwise). Only affects --input-chords, not --input-string.
var chordsViaView = false
// Milestone eight cards U4/U5 (claims 4993/0935): the pointer-synthesis
// seam — "--pointer <x>,<y>[,c][;x2,y2[,c]...]" synthesizes one
// NSEvent.mouseEvent per step (mouseMoved; + mouseDown/Up when the click
// flag is set) into the VZVirtualMachineView after --pointer-after's
// marker, mirroring the I3 keyboard seam (VZ has no programmatic pointer
// API either). Coordinates are GUEST pixels (y from the top); the view's
// bottom-left origin is flipped here. 3 s per step (the report-cadence
// lesson; the chord interval does not apply — pointer reports ride the
// same single-TRB arming).
var pointerScript: String?
var pointerAfter: String?
var pointerVirtioScript: String?
var pointerVirtioAfter: String?
// The pointer delivery route: "window" (sendEvent into the key window —
// observed NOT to reach VZ's pointer translation), "app" (NSApp.postEvent
// into the application queue), or "cg" (real CGEventPost at the HID tap —
// requires Accessibility permission for the terminal). Probes pick the
// route; the gate pins the observed-working one.
var pointerRoute: String = "window"
// Card U4 CG follow-on (claim 3692): `--pointer-request-trust` prompts the
// system to grant Accessibility to the responsible process (the terminal)
// via AXIsProcessTrustedWithOptions. OFF by default — the default VM and
// every existing gate stay byte-identical. The cg route checks trust
// first and reports `PTR-TRUST: untrusted` instead of silently dropping
// the post (the claim-4993 observation).
var pointerRequestTrust = false
let vzRestore = arguments.contains("--vz-restore")
// M70g G3 (#1459): restore beyond same-process. `--vz-restore-save <dir>`
// boots, stores the RAM marker, saves the machine state + the ASIF overlay
// + the marker into <dir> and EXITS; `--vz-restore-load <dir>` builds the
// equivalent configuration in a NEW process, restores from <dir> instead of
// booting, and must recover the marker by a fresh serial query.
var vzRestoreSaveDir: String?
var vzRestoreLoadDir: String?
// ADR 0059 D4 (M131b #2639): on --vz-restore-save, the boot-settle marker
// a checkpoint base boot waits for before pause/save/stop.
var vzRestoreSettle: String?
var vzRestoreWitness: String?
var vzRestoreVerifyCommand: String?
var vzRestoreVerifyOutput: String?
var virtioFSShareDir: String?
// M115a (#2460): Apple's standard VSOCK device (`VZVirtioSocketDevice`) —
// the probe for a restore-safe guest↔host channel. `--vsock` attaches the
// device and arms a host listener on `--vsock-port` (default 1208); under
// `--vz-restore` the card measures whether the device survives
// save/restore and a post-restore guest connect is still accepted.
var vsockEnabled = false
var vsockPort: UInt32 = 1208
var vsockPortSet = false
// M115b (#2461, ADR 0056): the virelai-ctl/1 control channel on the same
// device. `--vsock-ctl` arms a second listener on `--vsock-ctl-port`
// (default 1209) that serves the HMAC-challenged suspend/snapshot wire;
// the credential is the share's `vsock-ctl` SECRETS.TXT row (uid_system).
var vsockCtlEnabled = false
var vsockCtlPort: UInt32 = VSCtl.defaultPort
var vsockCtlPortSet = false
var cpuCount = 2
var cpusExplicit = false
var timeout: TimeInterval = 30
var timeoutExplicit = false
var expectLine = "firmware has agreed to cooperate"
var terminalMarker: String?
var consoleMode = false
// #1066 Stage 0 (issue #1066): a host-side remote console. `--console-tcp
// [host:]port` listens on host:port and bridges the socket to the SAME guest
// serial console the `--console` plumbing uses (client bytes -> the serial
// input attachment; guest output -> every connected client). It turns the
// console session into something you can `nc localhost 2222` (or reach from
// another machine with `0.0.0.0:<port>`). Plaintext, single client at a
// time — the trusted-LAN MVP before any guest crypto/SSH.
var consoleTCPPort: UInt16?
var consoleTCPBind: String = "127.0.0.1"
// M50 TS4 (#1138, ADR 0024 D7): an optional bridge HMAC secret. When set
// (`[host:]port:secret`), the bridge sends a fresh
// `VIRELAIOS-AUTH/1 hmac-sha256 <hex-challenge>` line and requires
// `hex(HMAC-SHA256(secret, domain || 0x00 || challenge))` as the client's
// first line; on mismatch it writes `console-tcp: auth failed` and closes.
// M70g G2 (#1459): `--console-tcp-secret-file <path>` reads the secret's
// first line from a file instead, so it never sits in the process list.
var consoleTCPSecret: String?
var consoleTCPSecretFromFile: String?
var debugInput = false
var markerDumpPath: String?
var nvramConsolePath: String?
var scriptPath: String?
var scriptAfter: String?
var scriptExpect: String?
// Claim 4912: after --script-expect first matches, hold the VM this many
// seconds (default 1.5 — one 1 Hz guest timer tick plus delivery/tee
// margin) before teardown, so the kernel's async exit-report tail (the
// `tasks/procs ... exited status=N` reap lines, drained from the shell
// idle loop on the timer tick) reaches the serial log. 0 restores the
// legacy stop-on-first-match behavior.
var scriptExpectTail: Double = 1.5
// Claim 4613: a second scripted phase. The primary --script is forwarded
// in ONE burst (claim 6684), so a scripted command that must land AFTER a
// background program exits and is reaped (the long-lived gate's re-exec
// into the freed pool slot) cannot be in the same burst: --script2 is
// forwarded once after its own serial marker (the reap line) instead.
var script2Path: String?
var script2After: String?
// Card N9 (claim 9489): the claim-6684 settle before forwarding script2
// / script3 becomes configurable (default 0.5 — every existing gate is
// unchanged), so a lease-lifecycle gate can wait past T1/T2/expiry
// deterministically.
var script2Delay: Double = 0.5
var script3Delay: Double = 0.5
// Card 3c (claim 7786): a THIRD scripted phase. The primary --script is
// forwarded in ONE burst (claim 6684) and --script2 handles the next
// phase (claim 4613); --script3 covers the post-reap snapshot that must
// land after a background process is killed AND reaped (the kill gate's
// procs/pages/re-exec read) — forwarded once after its own serial marker
// via the identical machinery.
var script3Path: String?
var script3After: String?
var customVirtioEnabled = false
// Claim 3141 (issue #523 item 3): `--cvc-echo` runs the HOST-initiated push
// echo over a third virtqueue — implies --custom-virtio. The host app
// enqueues the request into the guest's pre-armed receive buffer, the guest
// replies on the same queue, and the delegate verifies byte-exactly.
var cvcEchoEnabled = false
// Claim 9588 (issue #523 item 3): `--via-virtio` injects keys through the
// custom-virtio INPUT queue (queue 3) as HID-shaped 16-byte messages — no
// NSEvent synthesis, no view, no window. Implies the full four-queue device
// (custom virtio + cvc-echo + input).
var viaVirtioEnabled = false
// Claim 0680 (issue #523 item 3 capstone): `--cvc-snap` adds the FIFTH
// virtqueue — the framebuffer-snapshot channel. The guest streams its
// composed scanout as tagged binary messages over queue 4; the runner
// reassembles them into a raw BGRX file, replacing ScreenCaptureKit
// scraping (and its Screen Recording TCC dependency) for gates that opt in.
// Implies --via-virtio (five contiguous queues).
var cvcSnapEnabled = false
// M34 HF1+HF2 (issues #735/#736): `--cvc-file <host-dir>` attaches the
// SIXTH virtqueue — the host file channel. The guest userland filesystem
// is a macOS folder served over queue 5 with plain FileManager calls
// (wire format in Sources/VFWire/VFWire.swift). The deepest flag implies
// the full five-queue shape below it (unchanged rule).
var cvcFileShareDir: String?
var cvcFileEnabled: Bool { cvcFileShareDir != nil }
// M108b (#2325, ADR 0051): the host-integration lanes are signed VHI1
// record files under <share>/HOSTINT/ — modifiers on --cvc-file, so the
// share is the transport. `--host-clipboard` arms the clipboard lane both
// directions (seat-emitted CLIP_OUT records are mirrored to the
// pasteboard; pasteboard changeCount bumps become CLIP_IN records the
// seat applies). OFF by default: no lane flag means no HOSTINT/ is ever
// created and no pasteboard is ever read (D7 byte-silence).
// M139a (#2779): the five host-integration endpoints are per-SESSION
// state on the primary VMSession — these names keep their hundreds of
// single-VM call sites but the storage lives on the session object the
// registry owns (a secondary session's endpoints are its own fields).
var hostClipboardFlag = false
// `--host-pasteboard <name>` retargets the lane to NSPasteboard(name:) —
// the gate/test hook so a run never clobbers the operator's .general
// pasteboard (ADR 0051 D3's pasteboard-identity rule).
var hostPasteboardName: String?
// `--host-clip-in <text>` + `--host-clip-in-after <marker>`: the
// marker-timed test hook that performs a real pasteboard write once the
// marker appears — the changeCount path then carries it in like any host
// copy (the --host-write-after precedent).
var hostClipInText: String?
var hostClipInAfter: String?
var hostClipInFired = false
// M124c: a typed inject — file bytes + a negotiated mime.
var hostClipInFile: String?
var hostClipInMime: String?
var hostClipboard: HostClipboard? {
    get { primarySession.clipboard }
    set { primarySession.clipboard = newValue }
}
// M108c (#2326, ADR 0051 D4): `--host-drop` arms the file-drop lane — the
// display view registers .fileURL, dropped files land in <share>/INBOX/
// (≤64 MiB/file, ≤16/gesture) and each gets a signed DROP notice the seat
// toasts. `--host-drop-file`/`--host-drop-after` are the marker-timed test
// hook: feed a host path through the SAME handler the NSView drop calls
// (repeatable — a multi-file gesture is one call).
var hostDropFlag = false
var hostDropFiles: [String] = []
var hostDropAfter: String?
var hostDropFired = false
var hostDrop: HostDrop? {
    get { primarySession.drop }
    set { primarySession.drop = newValue }
}
// M108d (#2328, ADR 0051 D5): `--host-notify` arms the notify-out lane —
// seat toasts arrive as signed NOTIFY_OUT records and post as macOS
// banners under the session bundle (bare runner: `no_bundle` drops).
var hostNotifyFlag = false
var hostNotify: HostNotify? {
    get { primarySession.notify }
    set { primarySession.notify = newValue }
}
// M127d (#2602, ADR 0051 V2-D5): `--host-outbox` arms the export lane —
// the seat signs OUTBOX records for REQ-marked payloads under
// <share>/OUTBOX/ and the runner moves them to `--host-outbox-dir`
// (default ~/Downloads; the flag is the gate redirect — a class-B run
// never touches a real Downloads). No display precondition: exports are
// not a window gesture.
var hostOutboxFlag = false
var hostOutboxDir: String?
var hostOutbox: HostOutbox? {
    get { primarySession.outbox }
    set { primarySession.outbox = newValue }
}
// M114a (#2454, index #2447): `--host-cmd-after <marker>:<verb>` — the
// headless mirror of the HostCommand bus every menu item dispatches on
// (index thesis 1: AppKit is never driven by synthesized clicks; the bus
// is the testable seam). Repeatable; each armed trigger fires once on
// its serial marker and the dispatch emits one `host-ui:` receipt.
var hostCmdTriggers: [HostCommandTrigger] = []
// M114b (#2455): `--host-capture-keys` arms the machine view's
// capturesSystemKeys at startup — by dispatching the capture-keys verb
// on the bus once setupDisplayWindow has built the view, so the receipt
// is identical to ⌥⌘K / the toolbar pill / a --host-cmd-after trigger.
var hostCaptureKeys = false
// M114d (#2457, index #2447): the inspector drawer's model — ONE
// instance for the run. The serial polls feed it the growing log; the
// `inspector`/`send-serial` verbs act on it; a session window's drawer
// renders the same object, so a headless --host-cmd-after run exercises
// the identical seam the open drawer does.
let inspector = HostInspector()
// `--host-serial-send <line>`: arms the drawer's input line headlessly —
// the send-serial verb (a --host-cmd-after trigger, or the drawer's own
// Send) writes it into the console pipe exactly as the field would.
var hostSerialSend: String?
// The shared lane session (ADR 0051 D2): ONE credential, ONE epoch, ONE
// ARMED record naming every live lane — the seat adopts (epoch, mask), so
// per-lane epochs would refuse each other stale_epoch forever.
var hostIntSession: HostIntSession? {
    get { primarySession.hostInt }
    set { primarySession.hostInt = newValue }
}
// Claim 0680: `--cvc-console-file <path>` captures every queue-1 guest log
// line to a structured file (the structured console). When the file is set,
// the host also answers the guest's "cvconsole-ready" line with a kind-3
// control message arming the guest's console tee, so kernel console output
// rides queue 1 alongside serial. Requires --custom-virtio (queue 1).
var cvcConsoleFilePath: String?
// Claim 0680: `--snapshot-after <marker>` fires one kind-4 snapshot request
// when <marker> appears in the serial stream (repeatable; each instance
// writes its own numbered .raw). `--snapshot-out <base>` overrides the
// default output base (<screen path>-snap).
struct SnapshotTrigger {
    let marker: String
    let outPath: String
    var fired = false
}
var snapshotAfterMarkers: [String] = []
var snapshotOutBase: String?
// Issue #1788: a kind-4 snapshot is a 3.5 MiB round trip, so a trigger
// marker printed microseconds before the --script-expect match leaves the
// stream mid-flight when the teardown would otherwise fire. Hold the VM
// this long (bounded) while a stream is in flight. 0 = stop immediately.
var snapshotDrainTimeout: Double = 20
var snapshotTriggers: [SnapshotTrigger] = []
// M102d3 (issue #2168): the opt-in private 3D render device. Zero-value
// options mean the VM configuration is byte-identical to before; the
// VMGPU3D leaf owns the parsing vocabulary, the named rejections and the
// device/backend assembly.
var gpu3dOptions = GPU3DRunnerConfiguration.Options()
// Milestone five card N1 (claim 1373): `--net <capture-file>` attaches the
// virtio-net device; the guest's TX frames are captured byte-exactly to the
// file. nil = default (no network device attached, config.networkDevices
// stays [] — the default VM is unchanged).
var netCapturePath: String?
// Milestone five card N2 (claim 6076): `--net-inject <file>` writes the
// file's bytes into the runner's end of the SAME datagram socketpair VZ
// delivers guest-bound frames from, exactly ONCE, when the trigger marker
// appears in the serial log (default: the guest's `net: rx-armed` line —
// the RX buffer is guaranteed supplied; deterministic, not a sleep). nil =
// no injection (the default VM is unchanged).
var netInjectPath: String?
var netInjectAfter: String?
// Milestone five card N3 (claim 7293): `--net-arp-respond <host-ip>`
// answers the guest's ARP requests from the HOST side — a tiny
// deterministic host-side ARP responder inside the capture thread: when a
// captured datagram is an ARP request (ethertype 0x0806, op 1, htype 1,
// ptype 0x0800, hlen 6, plen 4), the synthesized reply (host MAC
// 02:00:00:00:00:02 at the given IP — the same fixed address as the
// guest's fallback_mac) is written into the SAME attachment socket end
// `--net-inject` writes (VZ reads fds[0], so the guest receives it).
// Driven by the guest's actual request bytes, not a sleep. nil = the
// guest's ARP requests go unanswered (the default VM is unchanged).
var netArpRespondHostIP: [UInt8]?
// Milestone five card N4 (claim 0148): `--net-icmp-respond <host-ip>`
// answers the guest's ICMP ECHO REQUESTS from the HOST side — a tiny
// deterministic host-side ICMP responder inside the capture thread: when
// a captured datagram is an ICMP echo request for the given IP (ethertype
// 0x0800, protocol 1, type 8, dst IP match, non-fragment), the
// synthesized echo reply (type 0, id/seq/payload echoed byte-exact, both
// checksums recomputed) is written into the SAME attachment socket end
// the ARP responder writes (VZ reads fds[0], so the guest receives it).
// Driven by the guest's actual request bytes, not a sleep. nil = the
// guest's echo requests go unanswered (the default VM is unchanged).
var netIcmpRespondHostIP: [UInt8]?
// M117b (issue #2474, ADR 0057 D10): the three v6 hermetic responders —
// request-driven synthesizers inside the capture thread, the
// --net-arp-respond shape. `--net-ra-respond <v6-prefix>/64` answers a
// guest Router Solicitation with a Router Advertisement from the router
// link-local fe80::ff:fe00:2 (the EUI-64 derivation of the fixed host
// MAC, deterministic + gate-assertable) carrying the argument prefix as
// an A+L /64 PIO. `--net-ndp-respond <v6-addr>` (repeatable) answers a
// guest Neighbor Solicitation whose target is a listed address with a
// Neighbor Advertisement (S=1 O=1, TLLA 02:00:00:00:00:02); when
// --net-ra-respond is set the router link-local is implicitly listed —
// the guest's router-resolution NS is answered without a second flag.
// An NS for an unlisted target goes unanswered (the refusal leg).
// `--net-icmp6-respond <v6-addr>` answers an ICMPv6 echo request for the
// address byte-exact (id/seq/payload, the --net-icmp-respond mirror).
// All write into the SAME attachment socket end (VZ reads fds[0], so
// the guest receives it). nil flag = unanswered = the default VM
// unchanged.
var netRaRespondPrefix: [UInt8]? // the advertised /64 (16 bytes, IID bits zero)
var netNdpRespondAddrs: [[UInt8]] = []
var netIcmp6RespondAddr: [UInt8]?
// M117c (#2475, ADR 0057): the v6 transport responders — the N5 UDP echo
// and the N10 TCP handshake+echo shapes on the 40-byte fixed header
// (ethertype 0x86dd, next-header 17 / 6). Both take `[v6-addr]:port` —
// the same bracketed literal shape `vi.Dial` speaks — so an address's
// own colons never confuse the parse.
var netUdp6RespondAddr: [UInt8]?
var netUdp6RespondPort: UInt16?
var netTcp6RespondAddr: [UInt8]?
var netTcp6RespondPort: UInt16?
// The hermetic router's link-local — the modified-EUI-64 derivation of
// the fixed host MAC 02:00:00:00:00:02 (ADR 0057 D10).
let netRouterLinkLocal: [UInt8] = [0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0, 0, 0x02]
// Milestone five card N5 (claim 8552): `--net-udp-respond <host-ip>:<host-port>`
// answers the guest's UDP datagrams from the HOST side — a tiny
// deterministic host-side UDP responder inside the capture thread: when
// a captured datagram is a UDP datagram for the given ip:port (ethertype
// 0x0800, version 4/IHL 5, non-fragment, protocol 17, dst IP + dst port
// match), the synthesized reply (FROM host-ip:host-port TO the sender's
// ip:src-port, the SAME payload byte-exact, both checksums recomputed)
// is written into the SAME attachment socket end (VZ reads fds[0], so the
// guest receives it). Driven by the guest's actual datagram bytes, not a
// sleep. nil = the guest's datagrams go unanswered (the default VM is
// unchanged).
var netUdpRespondHostIP: [UInt8]?
var netUdpRespondHostPort: UInt16?
// Milestone twelve card N2 (claim 7566): `--net-dns-respond <host-ip>[:<port>]`
// answers the guest's DNS queries from the HOST side — a tiny deterministic
// DNS resolver inside the capture thread.
var netDnsRespondHostIP: [UInt8]?
var netDnsRespondHostPort: UInt16 = 53
// M99i (issue #2187): the responder's depth knobs, all gated on
// --net-dns-respond. `--net-dns-answer <ipv4>` (repeatable) pins the A
// records every A reply carries (empty = the legacy qname table, one
// answer). `--net-dns-answer6 <32 hex digits>` (repeatable) pins the
// AAAA records every AAAA reply carries (empty = one fixed 2001:db8::53).
// `--net-dns-ttl <sec>` is the TTL written into every record (default
// 300). The hostile knobs inject noise BEFORE the real reply so the
// guest's rejection path is exercised, not just asserted:
// `--net-dns-spoof` sends the same reply forged from source IP 10.0.0.9,
// `--net-dns-wrong-question` sends a reply whose echoed question section
// is corrupted, and `--net-dns-truncate` answers every query with TC=1
// and ANCOUNT=0 (the guest must refuse — no TCP fallback exists).
var netDnsAnswers: [[UInt8]] = []
var netDnsAnswers6: [[UInt8]] = []
var netDnsTTL: UInt32 = 300
var netDnsSpoof = false
var netDnsWrongQuestion = false
var netDnsTruncate = false
// M83b (#1775): `--net-sntp-respond <host-ip>[:<port>]` answers the guest's
// SNTP queries with host wall-clock time + `--net-sntp-skew` seconds.
var netSntpRespondHostIP: [UInt8]?
var netSntpRespondHostPort: UInt16 = 123
var netSntpSkew: Int64?
// Milestone five card N8 (claim 0351): `--net-dhcp-respond <lease-ip>`
// answers the guest's DHCP handshake from the HOST side — a tiny
// deterministic host-side DHCP server inside the capture thread: when a
// captured datagram is a DHCPDISCOVER (ethertype 0x0800, protocol 17,
// src port 68 -> dst port 67, dst broadcast), the synthesized OFFER
// (BOOTREPLY, the guest's xid ECHOED, yiaddr = <lease-ip>, mask
// 255.255.255.0, gateway 10.0.0.1, server id = <lease-ip>, lease 3600)
// is written into the SAME attachment socket end the other responders
// write (VZ reads fds[0], so the guest receives it); on the guest's
// DHCPREQUEST (message type 3) the ACK (message type 5, the SAME fixed
// lease) is written. Driven by the guest's actual handshake bytes, not a
// sleep. nil = the guest's DHCP messages go unanswered (the default VM
// is unchanged). The fixed lease is gate-assertable — the `net dhcp`
// bound report must show ip=<lease-ip> mask=255.255.255.0 gw=10.0.0.1
// server=<lease-ip> lease=<lease-secs>.
var netDhcpRespondLeaseIP: [UInt8]?
// Card N9 (claim 9489): the OFFER/ACK lease option 51, in seconds
// (default 3600 — backward compatible; the `:N` suffix sets it, so the
// lease lifecycle is testable in seconds).
var netDhcpRespondLeaseSecs: UInt32 = 3600
// Audit follow-up 3 (issue #119): `--net-dhcp-respond-norenew` refuses
// the guest's UNICAST renewal REQUESTs (mtype 3 with a unicast dst MAC
// — the RENEWING REQUEST from RFC 2131 §4.4.5), so the client's T1
// renewal fails and it must ESCALATE to REBINDING at T2 (the broadcast
// REQUEST, which this knob still answers — it only refuses the unicast
// renew).
var netDhcpRespondNoRenew = false
// Audit follow-up 3 (issue #119): `--net-dhcp-respond-norebind` refuses
// the guest's BROADCAST renewal REQUESTs (mtype 3, broadcast dst, with
// ciaddr != 0 — the REBINDING REQUEST; the INITIAL REQUEST carries
// ciaddr == 0 and is still answered, so the bind + a post-expiry
// re-DISCOVER recovery keep working). With both refusal knobs (or with
// norebind + no resolved server ARP) the client's renewals all fail
// and the lease runs out — the autonomous-expiry evidence.
var netDhcpRespondNoRebind = false
// Milestone five card N10 (claim 7026): `--net-tcp-respond
// <host-ip>:<host-port>` answers the guest's bounded TCP client from the
// HOST side — a tiny deterministic TCP server inside the capture thread:
// the guest's SYN (src 8000 -> host-ip:host-port, protocol 6) is
// answered with a SYN-ACK (the FIXED gate-assertable server ISN
// 0x12345678, ack = the guest's ISN+1); the handshake ACK is observed;
// a data segment is answered with an ACK + the SAME payload byte-exact
// (the echo); the FIN is answered with a FIN-ACK; the final ACK is
// observed. Driven by the guest's actual segment bytes, not a sleep.
// nil = the guest's TCP segments go unanswered (the default VM is
// unchanged). The fixed ISN is gate-assertable — the live gate's python
// walk pins the full seq/ack chain.
var netTcpRespondHostIP: [UInt8]?
var netTcpRespondHostPort: UInt16?
// Card N11 (claim 5357): the optional `:handshake` responder mode —
// answer the SYN with a SYN-ACK, then go SILENT on data/FIN (a
// deterministic data black hole for the gate's retransmission-bound
// run). Default (no suffix) = the full N10 responder.
var netTcpRespondHandshakeOnly = false
// M99h (#2186): the optional `:options` responder mode — the same
// deterministic endpoint, but its SYN-ACK carries a real peer's option
// list (MSS 1460 + SACK-permitted + WS + NOP + a pinned TS, data offset
// 10) and its data/FIN segments carry NOP+NOP+TS (data offset 8). The
// guest must parse-and-skip the options and honor the advertised MSS —
// the shape a real NAT peer puts on the wire.
var netTcpRespondOptionsMode = false
// The pinned option lists (pre-padded to the 4-byte bound). SYN-ACK:
// MSS(4) + SACK-perm(2) + WS=0(3) + NOP(1) + TS(10) = 20 bytes.
// Data/FIN: NOP + NOP + TS(10) = 12 bytes.
let netTcpOptionsSynAck: [UInt8] = [0x02, 0x04, 0x05, 0xb4, 0x04, 0x02, 0x03, 0x03, 0x00, 0x01,
                                  0x08, 0x0a, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
let netTcpOptionsData: [UInt8] = [0x01, 0x01, 0x08, 0x0a, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00]
// M51 SSH1 (#1168): the optional `:packet` responder mode — after the
// handshake, page a caller-supplied byte payload out as ≤chunk-byte TCP
// segments, one per guest ACK. This is the deterministic peer the
// `live-ssh-packet` gate needs: the guest's kernel RX is one bounded slot
// with no reassembly, so the host MUST pace (blast several segments and the
// guest drops all but the first; the host has no retransmission).
var netTcpRespondPacketMode = false
var netTcpRespondPacketPayload: [UInt8] = []
var netTcpRespondPacketChunk: Int = 192
// M51 SSH5 (#1172): the optional `:ssh` responder mode — a runner-hosted
// minimal SSH-2 server (VSSH) behind the same deterministic TCP responder:
// curve25519-sha256 KEX with a pinned ssh-ed25519 host key, pinned
// publickey ed25519 userauth, one session channel, one fixed exec. The
// guest's `SSH.BIN` is the client. TX is paced exactly like `:packet`
// (one ≤192-byte segment per guest ACK) because the guest kernel RX is a
// single bounded slot with no reassembly. The pinned fixtures default to
// RFC 8032 §7.1 TEST 1/TEST 2; the flags allow the negative runs to pin
// different keys.
var netTcpRespondSSHMode = false
var netTcpRespondSSHHostKey: [UInt8] = SSHFixtures.hex(SSHFixtures.hostKeySeedHex) ?? []
var netTcpRespondSSHUserKey: [UInt8] = SSHFixtures.hex(SSHFixtures.userPublicKeyHex) ?? []
var netTcpRespondSSHTamperMAC = false
var netTcpRespondSSHMarker = SSHFixtures.defaultMarker
var netTcpRespondSSHExitStatus: UInt32 = 0
// M51 real-OpenSSH interop (#1209, goal #1066, ADR 0025 D8): the optional
// `:relay` responder mode — the same deterministic TCP endpoint, but the
// byte stream is proxied byte-for-byte to a REAL upstream TCP server
// (typically a local OpenSSH `sshd`). The runner performs NO SSH/crypto:
// it only carries bytes, so the guest's SSH.BIN negotiates with real
// OpenSSH. TX is paced exactly like `:ssh` (one ≤192-byte segment per
// guest ACK) because the guest kernel RX is a single bounded slot with
// no reassembly. OFF by default: every existing gate is byte-identical.
var netTcpRespondRelayMode = false
var netTcpRespondRelayHost = "127.0.0.1"
var netTcpRespondRelayPort: UInt16?
// The responder's per-connection state, keyed by the guest's 4-tuple
// (src IP:src port — M99f #2184). The FIXED server ISN (gate-assertable);
// a new SYN on an existing key resets that connection's state. Each
// connection carries its own server sequence, packet-mode index, SSH
// server instance + paced TX, and relay upstream — one guest's socket
// table can hold several live connections and every one is answered.
let netTcpSrvIsn: UInt32 = 0x12345678
final class NetTcpSrvConn {
    var srvNxt: UInt32 = netTcpSrvIsn &+ 1 // after the SYN
    var packetIndex = 0
    var sshServer: SSHServer?
    var sshTx: [UInt8] = []
    var sshTxOffset = 0
    // #2349: the `:relay` upstream state machine (dedup + window/MSS
    // pacing) lives in VMTcp so `swift test` drives it without a VM.
    let relay = NetTcpRelay()
    var closed = false
}
var netTcpSrvConns: [String: NetTcpSrvConn] = [:]
/// Bounded table: 16 live server-side connections; a SYN over the cap is
/// refused with an RST (the same honesty the guest's table applies).
let netTcpSrvConnLimit = 16
func netTcpConnKey(_ guestIP: [UInt8], _ guestPort: UInt16) -> String {
    "\(guestIP[0]).\(guestIP[1]).\(guestIP[2]).\(guestIP[3]):\(guestPort)"
}
// M117c (#2475): the v6 connection key — the v6 address rendered
// compactly so it shares the bounded `netTcpSrvConns` table without ever
// colliding with a dotted-quad key.
func netTcp6ConnKey(_ guestAddr: [UInt8], _ guestPort: UInt16) -> String {
    "v6:" + v6Text(guestAddr) + ":\(guestPort)"
}
/// The v6 connection a guest segment belongs to — the v4
/// `netTcpSrvConn(for:)` shape on the 40-byte header (src at 22..38,
/// ports at 54..58).
func netTcp6SrvConn(for buf: [UInt8]) -> NetTcpSrvConn {
    let key = netTcp6ConnKey([UInt8](buf[22..<38]), (UInt16(buf[54]) << 8) | UInt16(buf[55]))
    if let conn = netTcpSrvConns[key] { return conn }
    let conn = NetTcpSrvConn()
    netTcpSrvConns[key] = conn
    return conn
}
/// The connection a guest segment belongs to — lazily created so every
/// segment reaches the per-connection state machine (byte-identical with
/// today's always-on scalar for the single-connection case).
func netTcpSrvConn(for buf: [UInt8]) -> NetTcpSrvConn {
    let key = netTcpConnKey([UInt8](buf[26..<30]), (UInt16(buf[34]) << 8) | UInt16(buf[35]))
    if let conn = netTcpSrvConns[key] { return conn }
    let conn = NetTcpSrvConn()
    netTcpSrvConns[key] = conn
    return conn
}
/// Bounded admission for a fresh SYN: drop closed entries first, then
/// refuse when the live table is full (the RST is the caller's to build).
func netTcpSrvAdmit(_ key: String) -> Bool {
    netTcpSrvConns = netTcpSrvConns.filter { !$0.value.closed }
    if netTcpSrvConns[key] == nil, netTcpSrvConns.count >= netTcpSrvConnLimit { return false }
    return true
}
// SH7 (#1083, ADR 0020 Amendment B): `--net-tcp-connect
// <guest-ip>:<port>[:<payload-file>]` — the host initiates an INBOUND TCP
// connection TO a guest listener (the reverse of the N10 responder): SYN,
// handshake, the payload, the guest shell's reply, then a FIN. Frames ride
// the same `--net` attachment socketpair. The guest server's ISN is the
// fixed `kernel/src/tcp.zig` constant 0x54321098; the client ISN/source
// port are fixed for gate assertability.
// M99f (#2184): each `--net-tcp-connect` flag is ONE host client with its
// own state machine, keyed by the guest listener port; its source port is
// `netTcpCliPort` + index so two clients to the same guest port still
// have distinct 5-tuples. `netTcpConnectGuestIP`/`netTcpConnectPort`/
// `netTcpConnectPayload` remain the FIRST target's mirrors for the
// validation/print paths — a single flag behaves byte-identically.
var netTcpConnectGuestIP: [UInt8]?
var netTcpConnectPort: UInt16?
var netTcpConnectPayload: [UInt8] = []
var netTcpConnectAfter: String?
var netTcpConnectCloseAfter: String?
// M50 TS4 (#1138, ADR 0024 D6): the delegated-auth client. With a secret
// set the client waits for the guest's `VIRELAIOS-AUTH/1` challenge, answers
// with hex(HMAC-SHA256(secret, domain || 0x00 || challenge)), then sends the
// payload. `netTcpConnectMac` is the replay path: send that pre-recorded MAC
// hex line instead of computing one (a captured handshake replayed against a
// fresh challenge must fail).
var netTcpConnectSecret: String?
var netTcpConnectMac: String?
// M70g G1 (#1491): `--net-tcp-connect …:ssh` — the runner-hosted SSH-2
// client that dials the in-guest GOSSHD.ELF. TX is paced one ≤192-byte
// segment per guest ACK (the guest kernel RX is a single slot).
var netTcpConnectSSHMode = false
var netTcpConnectSSHUserSeed: [UInt8] = SSHFixtures.hex(SSHFixtures.userKeySeedHex) ?? []
var netTcpConnectSSHHostPin: [UInt8] = SSHFixtures.hex(SSHFixtures.hostPublicKeyHex) ?? []
var netTcpConnectSSHUser = "alice"
var netTcpConnectSSHExec = "echo VIRELAI-SSH-SERVER-OK-ARGV2"
// The hermetic RFB gate's byte-stream adapter. Unlike the payload-file
// client this pipes a local probe's stdin/stdout through the existing
// host->guest TCP emulation. It never binds a host port or uses --net-nat.
// M99f: it attaches to the FIRST connect target's client.
var netTcpConnectStreamExec: String?
var netTcpConnectStreamArgs: [String] = []
// A second viewer's SYN, sent from the next source port while the first
// holds the guest's one connection. The guest's answer (or silence) is the
// over-cap receipt.
var netTcpConnectIntruder = false
var nativeSocketProbeMode: String?
var nativeSocketProbe: NativeSocketProbe?
let netTcpIntruderIsn: UInt32 = 0x0badf00d
let netTcpStreamLock = NSLock()
let netTcpStreamMaxTx = 16 * 1024
// Lifetime byte bound, not a queue: one raw 1280x720x4 RFB frame plus
// handshake fits; the old 64 KiB cut off even a compressed first frame.
let netTcpStreamMaxRx = 4 * 1024 * 1024
let netTcpCliIsn: UInt32 = 0x10203040
let netTcpCliPort: UInt16 = 12345
let netTcpCliSrcIP: [UInt8] = [10, 0, 0, 2]
let netTcpGuestMAC: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x01]
let netTcpGuestSrvIsn: UInt32 = 0x54321098
/// One host-initiated connection's state machine (0 idle, 1 synSent,
/// 2 established, 3 closed, 4 finSent, 5 awaitingChallenge) plus the
/// SSH/stream/intruder per-connection state — M99f (#2184).
final class NetTcpClient {
    let guestIP: [UInt8]
    let guestPort: UInt16
    let cliPort: UInt16
    var payload: [UInt8]
    var sshMode: Bool
    var state: UInt8 = 0
    var seq: UInt32 = 0
    var ack: UInt32 = 0
    var recvText = ""
    var sshClient: SSHClient?
    var sshTx: [UInt8] = []
    var sshTxOffset = 0
    // M99f (#2184): the guest's advertised window, refreshed on every
    // inbound segment. The guest kernel reports 0 while its one-slot RX
    // buffer holds an unconsumed segment, and the guest emits a
    // window-update ACK when its read drains the slot — so holding a
    // chunk back while peerWindow == 0 loses nothing.
    var peerWindow: UInt32 = 0
    // False until the guest Recv's the first SSH chunk and emits bytes.
    // The kernel ACKs a segment as soon as it lands in the one-slot RX
    // buffer (tcp.zig syn_received / established), so a bare ACK or
    // SYN-ACK retransmit must NOT release the next ≤192-byte chunk — that
    // overflow is dropped and never ACKed. Guest data is the signal.
    var sshGuestDataSeen = false
    var streamProcess: Process?
    var streamInput: FileHandle?
    var streamTx: [UInt8] = []
    var streamInFlight = false
    var streamDone = false
    var streamEOF = false // the probe exited 0: FIN once its bytes are ACKed
    var streamRxBytes = 0
    var intruderSent = false
    var intruderAnswered = false
    /// `--net-tcp-connect-stream` attaches the probe to the FIRST declared
    /// client only (M99f: later clients never take the stream branch).
    var isStreamClient: Bool {
        netTcpConnectStreamExec != nil && netTcpClients.first === self
    }

    init(guestIP: [UInt8], guestPort: UInt16, cliPort: UInt16, payload: [UInt8], sshMode: Bool) {
        self.guestIP = guestIP
        self.guestPort = guestPort
        self.cliPort = cliPort
        self.payload = payload
        self.sshMode = sshMode
    }
}
var netTcpClients: [NetTcpClient] = []
// Milestone five card N7 (claim 4678): `--net-nat` attaches one
// VZVirtioNetworkDeviceConfiguration with a VZNATNetworkDeviceAttachment
// instead of the file-handle attachment — the host is the guest's router
// and performs NAT for accesses to outside networks. Boolean, OFF by
// default: without the flag config.networkDevices stays [] (the default
// VM is unchanged). Mutually exclusive with `--net` (one network device
// per guest for now).
var netNatEnabled = false
// M117d (issue #2476, ADR 0057 D11): the opt-in real-LAN attachments.
// `--net-bridged <iface>` attaches a VZBridgedNetworkDeviceAttachment on
// the named VZBridgedNetworkInterface; `--net-vmnet` attaches a
// VZVmnetNetworkDeviceAttachment on a shared-mode vmnet logical network
// created up front (vmnet_network_create). Both are off by default,
// mutually exclusive with --net/--net-nat/each other, and every missing
// piece refuses by name — the absent interface, the absent
// com.apple.vm.networking entitlement in this signature, or the
// non-success vmnet_return_t the daemon returns when it lacks
// com.apple.developer.networking.vmnet/root. netBridgedIface and
// netVmnetNetwork hold the validated objects between flag checks and the
// attachment assembly below.
var netBridgedInterface: String?
var netVmnetEnabled = false
var netVmnetSubnet: (ip: [UInt8], prefixLen: Int)?
var netBridgedIface: VZBridgedNetworkInterface?
var netVmnetSubnetText: String?
#if canImport(vmnet)
var netVmnetNetwork: vmnet_network_ref?
#endif

// Issue #523 item 2 (claim 6637): run isolation.
// `--overlay-base <path>`: open <path> READ-ONLY as the base of a
// DiskImageKit stacked image and append a fresh ASIF overlay layer (created
// in a private temp dir, removed at exit). Every run boots a pristine disk
// by construction; guest writes land in the overlay and are discarded. The
// positional <disk-image> argument is ignored in this mode.
// `--vars <path>`: per-run EFI variable store (default artifacts/efi-vars.bin,
// kept for back-compat with every existing invocation).
var overlayBasePath: String?
var varsOverridePath: String?

// M113b (#2418, ADR 0054 Part I): the opt-in verified-boot flag family.
// `--secure-boot` builds a FRESH per-run variable store, enables UEFI
// Secure Boot with a custom Platform Key (`--secure-boot-pk`, a DER
// X.509 certificate), and enrolls the db as SHA-256 entries — either the
// PE/COFF Authenticode digest of each `--secure-boot-db-efi <PE>` image
// (the convention the firmware enforces — the M113a probe pinned it) or
// a raw 64-hex digest from `--secure-boot-db-hash`. Flags OFF is
// byte-identical: the store is created/opened exactly as before and the
// boot default does not move.
var secureBootEnabled = false
var secureBootPKPath: String?
var secureBootDbEfiPaths: [String] = []
var secureBootDbHashes: [String] = []

var idx = arguments.count > 1 && arguments[1].hasPrefix("--") ? 1 : 2
while idx < arguments.count {
    let arg = arguments[idx]
    if vzRestore, arg.hasPrefix("--") {
        // M70g G3 (#1459): the probe also takes the save/load directory and
        // the device knobs whose save/restore support it measures.
        // ADR 0059 (M131b #2639): --vz-restore-settle names the base boot's
        // quiescent marker (save side); the --script* family arms a scripted
        // warm leg on the --vz-restore-load side (D2's allow-list).
        let valued = ["--overlay-base", "--vars", "--serial", "--cpus", "--timeout",
                      "--vz-restore-save", "--vz-restore-load", "--vz-restore-witness",
                      "--vz-restore-verify-command", "--vz-restore-verify-output",
                      "--vz-restore-settle",
                      "--script", "--script-after", "--script-expect", "--script-expect-tail",
                      "--script2", "--script2-after", "--script2-delay",
                      "--script3", "--script3-after", "--script3-delay",
                      "--usb-msd", "--virtio-fs", "--vsock-port", "--vsock-ctl-port"]
        let bare = ["--vz-restore", "--display", "--input", "--custom-virtio", "--gpu3d-metal", "--vsock", "--vsock-ctl"]
        guard valued.contains(arg) || bare.contains(arg) else {
            fail("--vz-restore is a standalone headless save/restore probe; supports only --overlay-base, --vars, --serial, --cpus, --timeout, --vz-restore-save/--vz-restore-load <dir>, --vz-restore-witness <serial-line>, --vz-restore-verify-command/--vz-restore-verify-output, --vz-restore-settle <marker>, the --script* family on --vz-restore-load, --virtio-fs <host-dir>, and the device knobs --display, --input, --usb-msd, --custom-virtio, --gpu3d-metal, --vsock.")
        }
        if valued.contains(arg) {
            guard idx + 1 < arguments.count, !arguments[idx + 1].hasPrefix("--") else {
                fail("--vz-restore: \(arg) requires a value.")
            }
            if arg == "--timeout", Double(arguments[idx + 1]) == nil {
                fail("--vz-restore: --timeout requires a numeric value.")
            }
        }
    }
    if arg == "--overlay-base", idx + 1 < arguments.count {
        overlayBasePath = arguments[idx + 1]
        idx += 2
    } else if arg == "--vars", idx + 1 < arguments.count {
        varsOverridePath = arguments[idx + 1]
        idx += 2
    } else if arg == "--serial", idx + 1 < arguments.count {
        // Per-run serial log path (#523 item 2): the default
        // artifacts/vm-serial.log is shared state two concurrent gates
        // would clobber.
        serialLogPath = arguments[idx + 1]
        idx += 2
    } else if arg == "--screen", idx + 1 < arguments.count {
        screenshotPath = arguments[idx + 1]
        idx += 2
    } else if arg == "--screenshot-after", idx + 1 < arguments.count {
        screenshotAfter = arguments[idx + 1]
        idx += 2
    } else if arg == "--host-write", idx + 1 < arguments.count {
        hostWritePath = arguments[idx + 1]
        idx += 2
    } else if arg == "--host-write-content", idx + 1 < arguments.count {
        hostWriteContent = arguments[idx + 1]
        idx += 2
    } else if arg == "--host-write-after", idx + 1 < arguments.count {
        hostWriteAfter = arguments[idx + 1]
        idx += 2
    } else if arg == "--display" {
        displayMode = true
        idx += 1
    } else if arg == "--input" {
        inputMode = true
        idx += 1
    } else if arg == "--host-session" {
        idx += 1
    } else if arg == "--sound" {
        soundMode = true
        idx += 1
    } else if arg == "--no-entropy" {
        // M97g (#2084): detach the virtio-entropy device so a gate can
        // prove slot 72 fails closed while the CSPRNG is unseeded.
        noEntropy = true
        idx += 1
    } else if arg == "--usb-msd", idx + 1 < arguments.count {
        usbMsdPath = arguments[idx + 1]
        idx += 2
    } else if arg == "--data-disk", idx + 1 < arguments.count {
        dataDiskPath = arguments[idx + 1]
        idx += 2
    } else if arg == "--profile", idx + 1 < arguments.count {
        profilePath = arguments[idx + 1]
        idx += 2
    } else if arg == "--resume", idx + 1 < arguments.count {
        resumeFromPath = arguments[idx + 1]
        idx += 2
    } else if arg == "--profile-init" {
        profileInitOnly = true
        idx += 1
    } else if arg == "--apply-update" {
        applyUpdate = true
        idx += 1
    } else if arg == "--rollback-update" {
        rollbackUpdate = true
        idx += 1
    } else if arg == "--update-key", idx + 1 < arguments.count {
        updateKeyHex = arguments[idx + 1]
        idx += 2
    } else if arg == "--input-key", idx + 1 < arguments.count {
        guard let kc = UInt16(arguments[idx + 1]) else {
            fail("--input-key requires a numeric macOS virtual keycode, got '\(arguments[idx + 1])'.")
        }
        inputKeyCode = kc
        idx += 2
    } else if arg == "--input-key-after", idx + 1 < arguments.count {
        inputKeyAfter = arguments[idx + 1]
        idx += 2
    } else if arg == "--input-string", idx + 1 < arguments.count {
        inputString = arguments[idx + 1]
        idx += 2
    } else if arg == "--input-string-after", idx + 1 < arguments.count {
        inputStringAfter = arguments[idx + 1]
        idx += 2
    } else if arg == "--input-chords", idx + 1 < arguments.count {
        inputChords = arguments[idx + 1]
        idx += 2
    } else if arg == "--input-chords-after", idx + 1 < arguments.count {
        inputChordsAfter = arguments[idx + 1]
        idx += 2
    } else if arg == "--input-chords-delay", idx + 1 < arguments.count {
        guard let d = Double(arguments[idx + 1]), d > 0 else {
            fail("--input-chords-delay requires a positive seconds value, got '\(arguments[idx + 1])'.")
        }
        inputChordsDelay = d
        idx += 2
    } else if arg == "--chords-view" {
        // M34 HF5 (issue #739): see the chordsViaView declaration above.
        chordsViaView = true
        idx += 1
    } else if arg == "--pointer", idx + 1 < arguments.count {
        pointerScript = arguments[idx + 1]
        idx += 2
    } else if arg == "--pointer-after", idx + 1 < arguments.count {
        pointerAfter = arguments[idx + 1]
        idx += 2
    } else if arg == "--pointer-route", idx + 1 < arguments.count {
        pointerRoute = arguments[idx + 1]
        idx += 2
    } else if arg == "--pointer-request-trust" {
        pointerRequestTrust = true
        idx += 1
    } else if arg == "--vz-restore" {
        idx += 1
    } else if arg == "--vz-restore-save", idx + 1 < arguments.count {
        vzRestoreSaveDir = arguments[idx + 1]
        idx += 2
    } else if arg == "--vz-restore-load", idx + 1 < arguments.count {
        vzRestoreLoadDir = arguments[idx + 1]
        idx += 2
    } else if arg == "--vz-restore-settle", idx + 1 < arguments.count {
        vzRestoreSettle = arguments[idx + 1]
        idx += 2
    } else if arg == "--vz-restore-witness", idx + 1 < arguments.count {
        vzRestoreWitness = arguments[idx + 1]
        idx += 2
    } else if arg == "--vz-restore-verify-command", idx + 1 < arguments.count {
        vzRestoreVerifyCommand = arguments[idx + 1]
        idx += 2
    } else if arg == "--vz-restore-verify-output", idx + 1 < arguments.count {
        vzRestoreVerifyOutput = arguments[idx + 1]
        idx += 2
    } else if arg == "--secure-boot" {
        secureBootEnabled = true
        idx += 1
    } else if arg == "--secure-boot-pk", idx + 1 < arguments.count {
        secureBootPKPath = arguments[idx + 1]
        idx += 2
    } else if arg == "--secure-boot-db-efi", idx + 1 < arguments.count {
        secureBootDbEfiPaths.append(arguments[idx + 1])
        idx += 2
    } else if arg == "--secure-boot-db-hash", idx + 1 < arguments.count {
        secureBootDbHashes.append(arguments[idx + 1])
        idx += 2
    } else if arg == "--virtio-fs", idx + 1 < arguments.count {
        virtioFSShareDir = arguments[idx + 1]
        idx += 2
    } else if arg == "--vsock" {
        vsockEnabled = true
        idx += 1
    } else if arg == "--vsock-port", idx + 1 < arguments.count {
        guard let port = UInt32(arguments[idx + 1]), port != 0 else {
            fail("--vsock-port requires a numeric port value in 1...4294967294.")
        }
        vsockPort = port
        vsockPortSet = true
        idx += 2
    } else if arg == "--vsock-ctl" {
        vsockCtlEnabled = true
        idx += 1
    } else if arg == "--vsock-ctl-port", idx + 1 < arguments.count {
        guard let port = UInt32(arguments[idx + 1]), port != 0 else {
            fail("--vsock-ctl-port requires a numeric port value in 1...4294967294.")
        }
        vsockCtlPort = port
        vsockCtlPortSet = true
        idx += 2
    } else if arg == "--cpus", idx + 1 < arguments.count {
        guard let n = Int(arguments[idx + 1]), n >= 1, n <= 8 else {
            fail("--cpus requires a count in 1...8, got '\(arguments[idx + 1])'.")
        }
        cpuCount = n
        cpusExplicit = true
        idx += 2
    } else if arg == "--memory-mib", idx + 1 < arguments.count {
        // M129a (#2610): VZ anchors guest RAM at phys 0x7000_0000 growing
        // upward (observed 256/512 MiB boots). The kernel's user-stack
        // ASLR band opens at 4 GiB, so the guest's RAM top
        // (0x7000_0000 + size) must stay below it — 2304 MiB is the hard
        // geometry ceiling; 2048 is the bounded flag value under it.
        guard let n = Int(arguments[idx + 1]), n >= 64, n <= 2048 else {
            fail("--memory-mib requires a size in 64...2048, got '\(arguments[idx + 1])'.")
        }
        memoryMiB = n
        memoryMiBExplicit = true
        idx += 2
    } else if arg == "--timeout", idx + 1 < arguments.count {
        timeout = TimeInterval(arguments[idx + 1]) ?? 30
        timeoutExplicit = true
        idx += 2
    } else if arg == "--expect", idx + 1 < arguments.count {
        expectLine = arguments[idx + 1]
        idx += 2
    } else if arg == "--terminal-marker", idx + 1 < arguments.count {
        terminalMarker = arguments[idx + 1]
        idx += 2
    } else if arg == "--console" {
        consoleMode = true
        idx += 1
    } else if arg == "--console-tcp", idx + 1 < arguments.count {
        // #1066 Stage 0 / M46 RC1 (#1110, ADR 0022 D2): `[host:]port[:secret]`
        // — bind host (default 127.0.0.1) and serve the guest console over
        // TCP. The optional secret gates the client's first line. Implies
        // console mode (duplex serial attachment + guest-output tee).
        let spec = arguments[idx + 1]
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var parsed = false
        switch parts.count {
        case 1:
            if let p = UInt16(parts[0]) { consoleTCPPort = p; parsed = true }
        case 2:
            if let p = UInt16(parts[0]) { // port:secret
                consoleTCPPort = p; consoleTCPSecret = parts[1]; parsed = true
            } else if let p = UInt16(parts[1]) { // host:port
                consoleTCPBind = parts[0]; consoleTCPPort = p; parsed = true
            }
        case 3:
            if let p = UInt16(parts[1]) { // host:port:secret
                consoleTCPBind = parts[0]; consoleTCPPort = p; consoleTCPSecret = parts[2]; parsed = true
            }
        default:
            break
        }
        // M70g G2 (#1459): never echo the spec back — it may carry the secret.
        guard parsed else { fail("--console-tcp: invalid spec (want [host:]port[:secret])") }
        if consoleTCPBind.isEmpty { consoleTCPBind = "127.0.0.1" }
        if consoleTCPSecret?.isEmpty == true { consoleTCPSecret = nil }
        consoleMode = true
        idx += 2
    } else if arg == "--console-tcp-secret-file", idx + 1 < arguments.count {
        // M70g G2 (#1459): the bridge secret from a file (first line, CR/LF
        // trimmed) so it is visible neither in `ps` nor in any log line.
        let path = arguments[idx + 1]
        guard let raw = FileManager.default.contents(atPath: path) else {
            fail("--console-tcp-secret-file: cannot read '\(path)'")
        }
        let firstLine = raw.split(separator: 0x0a, maxSplits: 1, omittingEmptySubsequences: false).first ?? Data()
        let trimmed = firstLine.last == 0x0d ? firstLine.dropLast() : firstLine
        guard !trimmed.isEmpty else { fail("--console-tcp-secret-file: '\(path)' has an empty first line") }
        consoleTCPSecretFromFile = String(decoding: trimmed, as: UTF8.self)
        idx += 2
    } else if arg == "--debug-input" {
        debugInput = true
        idx += 1
    } else if arg == "--dump-marker", idx + 1 < arguments.count {
        markerDumpPath = arguments[idx + 1]
        idx += 2
    } else if arg == "--nvram-console", idx + 1 < arguments.count {
        nvramConsolePath = arguments[idx + 1]
        idx += 2
    } else if arg == "--script", idx + 1 < arguments.count {
        scriptPath = arguments[idx + 1]
        idx += 2
    } else if arg == "--script-after", idx + 1 < arguments.count {
        scriptAfter = arguments[idx + 1]
        idx += 2
    } else if arg == "--script-expect", idx + 1 < arguments.count {
        scriptExpect = arguments[idx + 1]
        idx += 2
    } else if arg == "--script-expect-tail", idx + 1 < arguments.count {
        // Claim 4912: seconds to hold the VM after --script-expect first
        // matches, so post-marker kernel output (the async reap/report
        // lines, drained on the guest's 1 Hz timer tick) reaches the serial
        // log before teardown. 0 = legacy stop-on-first-match.
        scriptExpectTail = Double(arguments[idx + 1]) ?? 1.5
        idx += 2
    } else if arg == "--script2", idx + 1 < arguments.count {
        script2Path = arguments[idx + 1]
        idx += 2
    } else if arg == "--script2-after", idx + 1 < arguments.count {
        script2After = arguments[idx + 1]
        idx += 2
    } else if arg == "--script3", idx + 1 < arguments.count {
        script3Path = arguments[idx + 1]
        idx += 2
    } else if arg == "--script3-after", idx + 1 < arguments.count {
        script3After = arguments[idx + 1]
        idx += 2
    } else if arg == "--custom-virtio" {
        customVirtioEnabled = true
        idx += 1
    } else if arg == "--cvc-echo" {
        // Claim 3141: the host-push echo spike — implies the device attach.
        customVirtioEnabled = true
        cvcEchoEnabled = true
        idx += 1
    } else if arg == "--via-virtio" {
        // Claim 9588: keyboard injection over the custom-virtio INPUT queue
        // (queue 3). Virtqueues are contiguous, so the four-queue shape
        // implies --custom-virtio AND the claim-3141 push echo.
        viaVirtioEnabled = true
        customVirtioEnabled = true
        cvcEchoEnabled = true
        idx += 1
    } else if arg == "--pointer-virtio", idx + 1 < arguments.count {
        // Claim 9367: pointer injection over the custom-virtio INPUT queue
        // (kind-2 absolute-pointer messages) — implies --via-virtio.
        pointerVirtioScript = arguments[idx + 1]
        viaVirtioEnabled = true
        customVirtioEnabled = true
        cvcEchoEnabled = true
        idx += 2
    } else if arg == "--pointer-virtio-after", idx + 1 < arguments.count {
        pointerVirtioAfter = arguments[idx + 1]
        idx += 2
    } else if arg == "--cvc-snap" {
        // Claim 0680: the five-queue shape — adds the framebuffer-snapshot
        // queue. Implies --via-virtio (contiguous queues).
        cvcSnapEnabled = true
        viaVirtioEnabled = true
        customVirtioEnabled = true
        cvcEchoEnabled = true
        idx += 1
    } else if arg == "--cvc-file", idx + 1 < arguments.count {
        // M34 HF1+HF2 (issues #735/#736): the SIX-queue shape — attaches
        // the host file channel (queue 5) serving the given macOS folder.
        // The deepest flag implies the full shape below it.
        cvcFileShareDir = arguments[idx + 1]
        cvcSnapEnabled = true
        viaVirtioEnabled = true
        customVirtioEnabled = true
        cvcEchoEnabled = true
        idx += 2
    } else if arg == "--host-clipboard" {
        // M108b (#2325, ADR 0051): the bidirectional clipboard lane —
        // signed lane files under the share's HOSTINT/. It does NOT touch
        // the queue shape: the share (queue 5) is already the transport.
        hostClipboardFlag = true
        idx += 1
    } else if arg == "--host-pasteboard", idx + 1 < arguments.count {
        hostPasteboardName = arguments[idx + 1]
        idx += 2
    } else if arg == "--host-clip-in", idx + 1 < arguments.count {
        hostClipInText = arguments[idx + 1]
        idx += 2
    } else if arg == "--host-clip-in-after", idx + 1 < arguments.count {
        hostClipInAfter = arguments[idx + 1]
        idx += 2
    } else if arg == "--host-clip-in-file", idx + 1 < arguments.count {
        hostClipInFile = arguments[idx + 1]
        idx += 2
    } else if arg == "--host-clip-in-mime", idx + 1 < arguments.count {
        hostClipInMime = arguments[idx + 1]
        idx += 2
    } else if arg == "--host-drop" {
        // M108c (#2326, ADR 0051 D4): the host→guest file-drop lane —
        // INBOX/ writes + signed DROP notices over the same share. Does
        // NOT touch the queue shape either.
        hostDropFlag = true
        idx += 1
    } else if arg == "--host-drop-file", idx + 1 < arguments.count {
        hostDropFiles.append(arguments[idx + 1])
        idx += 2
    } else if arg == "--host-drop-after", idx + 1 < arguments.count {
        hostDropAfter = arguments[idx + 1]
        idx += 2
    } else if arg == "--host-capture-keys" {
        hostCaptureKeys = true
        idx += 1
    } else if arg == "--host-cmd-after", idx + 1 < arguments.count {
        // M114a: <marker>:<verb> — the verb is the suffix after the LAST
        // colon (serial markers may carry their own). An unknown verb is
        // a parse-time error, not a trigger that silently never fires.
        guard let trigger = HostCommandTrigger(arguments[idx + 1]) else {
            fail("--host-cmd-after expects <marker>:<verb>; verbs are: \(HostCommand.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        hostCmdTriggers.append(trigger)
        idx += 2
    } else if arg == "--host-serial-send", idx + 1 < arguments.count {
        // M114d (#2457): arms the inspector's input line — a
        // `--host-cmd-after …:send-serial` trigger writes it into the
        // console pipe, the same path --script forwards through.
        hostSerialSend = arguments[idx + 1]
        inspector.inputLine = hostSerialSend!
        idx += 2
    } else if arg == "--host-notify" {
        // M108d (#2328, ADR 0051 D5): the notify-out lane — seat toasts
        // become signed NOTIFY_OUT records the runner maps to banners
        // (bundled) or no_bundle drops (bare). Modifier on --cvc-file;
        // never touches the queue shape.
        hostNotifyFlag = true
        idx += 1
    } else if arg == "--host-outbox" {
        // M127d (#2602, ADR 0051 V2-D5): the guest→host export lane —
        // REQ-marked payloads under OUTBOX/ become signed records the
        // runner verifies and moves out. Modifier on --cvc-file.
        hostOutboxFlag = true
        idx += 1
    } else if arg == "--host-outbox-dir", idx + 1 < arguments.count {
        hostOutboxDir = arguments[idx + 1]
        idx += 2
    } else if arg == "--cvc-console-file", idx + 1 < arguments.count {
        // Claim 0680: structured console — capture every queue-1 guest log
        // line to this file and arm the guest's console tee (kind-3) when
        // it signals readiness.
        cvcConsoleFilePath = arguments[idx + 1]
        customVirtioEnabled = true
        idx += 2
    } else if arg == "--snapshot-after", idx + 1 < arguments.count {
        // Claim 0680: fire one kind-4 snapshot request when this serial
        // marker appears (repeatable; outputs are numbered per instance).
        snapshotAfterMarkers.append(arguments[idx + 1])
        cvcSnapEnabled = true
        viaVirtioEnabled = true
        customVirtioEnabled = true
        cvcEchoEnabled = true
        idx += 2
    } else if arg == "--snapshot-out", idx + 1 < arguments.count {
        snapshotOutBase = arguments[idx + 1]
        idx += 2
    } else if arg == "--snapshot-drain-timeout", idx + 1 < arguments.count {
        // Issue #1788: seconds to hold the VM at teardown while an armed
        // kind-4 snapshot stream is still in flight. Clamp a negative value
        // to 0 here so `snapshotDrainTimeout > 0` in the drain is the
        // documented "do not wait" switch rather than a silent fallthrough:
        // a gate that fat-fingers `-5` gets the legacy stop, not a drain
        // that exits instantly on the first poll.
        snapshotDrainTimeout = Double(arguments[idx + 1]) ?? 20
        if snapshotDrainTimeout < 0 { snapshotDrainTimeout = 0 }
        idx += 2
    } else if arg == "--gpu3d-metal" {
        // M102d3 (#2168): opt-in private 3D render device (custom-virtio
        // 0x43 / PCI 1af4:1083, VIR1) beside native 2D — appended, never
        // replacing. Needs the SPIKE build; checked below with a named
        // failure on an ordinary binary.
        gpu3dOptions.metal = true
        idx += 1
    } else if arg == "--gpu3d-test-mode", idx + 1 < arguments.count {
        // M102d3 (#2168): completion-fault selection for c2's
        // deterministic knobs. SPIKE-only — the pre-attachment check
        // rejects it by name on an ordinary binary.
        guard let mode = GPU3DRunnerConfiguration.TestMode(rawValue: arguments[idx + 1]) else {
            fail("--gpu3d-test-mode: unknown mode '\(arguments[idx + 1])' (want \(GPU3DRunnerConfiguration.TestMode.allCases.map(\.rawValue).joined(separator: "|")))")
        }
        gpu3dOptions.testMode = mode
        idx += 2
    } else if arg == "--gpu3d-test-mode" {
        fail("--gpu3d-test-mode requires a mode (want \(GPU3DRunnerConfiguration.TestMode.allCases.map(\.rawValue).joined(separator: "|")))")
    } else if arg == "--net", idx + 1 < arguments.count {
        netCapturePath = arguments[idx + 1]
        idx += 2
    } else if arg == "--net-inject", idx + 1 < arguments.count {
        netInjectPath = arguments[idx + 1]
        idx += 2
    } else if arg == "--net-inject-after", idx + 1 < arguments.count {
        netInjectAfter = arguments[idx + 1]
        idx += 2
    } else if arg == "--net-arp-respond", idx + 1 < arguments.count {
        // Parse the dotted-quad host IP now (fail early, like --timeout).
        let parts = arguments[idx + 1].split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else {
            fail("--net-arp-respond requires a dotted-quad IPv4 address, got '\(arguments[idx + 1])'.")
        }
        netArpRespondHostIP = parts
        idx += 2
    } else if arg == "--net-icmp-respond", idx + 1 < arguments.count {
        // Parse the dotted-quad host IP now (fail early, like --timeout).
        let parts = arguments[idx + 1].split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else {
            fail("--net-icmp-respond requires a dotted-quad IPv4 address, got '\(arguments[idx + 1])'.")
        }
        netIcmpRespondHostIP = parts
        idx += 2
    } else if arg == "--net-ra-respond", idx + 1 < arguments.count {
        // M117b: <v6-prefix>/64 — e.g. 2001:db8:64::/64 (the advertised
        // PIO; the IID bits belong to the guest, the responder zeroes
        // them so the advertised prefix is honest).
        let halves = arguments[idx + 1].split(separator: "/")
        guard halves.count == 2, Int(halves[1]) == 64,
              var pfx = parseIPv6(String(halves[0])) else {
            fail("--net-ra-respond requires a v6 /64 prefix like 2001:db8:64::/64, got '\(arguments[idx + 1])'.")
        }
        for i in 8..<16 { pfx[i] = 0 }
        netRaRespondPrefix = pfx
        idx += 2
    } else if arg == "--net-ndp-respond", idx + 1 < arguments.count {
        // M117b: repeatable — each instance lists one answerable target.
        guard let addr = parseIPv6(arguments[idx + 1]) else {
            fail("--net-ndp-respond requires a v6 address, got '\(arguments[idx + 1])'.")
        }
        netNdpRespondAddrs.append(addr)
        idx += 2
    } else if arg == "--net-icmp6-respond", idx + 1 < arguments.count {
        guard let addr = parseIPv6(arguments[idx + 1]) else {
            fail("--net-icmp6-respond requires a v6 address, got '\(arguments[idx + 1])'.")
        }
        netIcmp6RespondAddr = addr
        idx += 2
    } else if arg == "--net-udp6-respond", idx + 1 < arguments.count {
        // M117c (#2475): '[v6-addr]:port' — the bracket keeps the
        // address's own colons out of the port split.
        let token = arguments[idx + 1]
        guard token.hasPrefix("["), let close = token.firstIndex(of: "]") else {
            fail("--net-udp6-respond requires '[<v6-addr>]:<host-port>', got '\(token)'.")
        }
        let addrText = String(token[token.index(after: token.startIndex)..<close])
        guard let addr = parseIPv6(addrText),
              token[token.index(after: close)..<token.endIndex].hasPrefix(":"),
              let port = UInt16(token[token.index(after: close)..<token.endIndex].dropFirst()) else {
            fail("--net-udp6-respond requires '[<v6-addr>]:<host-port>', got '\(token)'.")
        }
        netUdp6RespondAddr = addr
        netUdp6RespondPort = port
        idx += 2
    } else if arg == "--net-tcp6-respond", idx + 1 < arguments.count {
        // M117c (#2475): the same '[v6-addr]:port' bracketed shape.
        let token = arguments[idx + 1]
        guard token.hasPrefix("["), let close = token.firstIndex(of: "]") else {
            fail("--net-tcp6-respond requires '[<v6-addr>]:<host-port>', got '\(token)'.")
        }
        let addrText = String(token[token.index(after: token.startIndex)..<close])
        guard let addr = parseIPv6(addrText),
              token[token.index(after: close)..<token.endIndex].hasPrefix(":"),
              let port = UInt16(token[token.index(after: close)..<token.endIndex].dropFirst()) else {
            fail("--net-tcp6-respond requires '[<v6-addr>]:<host-port>', got '\(token)'.")
        }
        netTcp6RespondAddr = addr
        netTcp6RespondPort = port
        idx += 2
    } else if arg == "--net-udp-respond", idx + 1 < arguments.count {
        // Parse the host ip:port now (fail early, like --timeout).
        let halves = arguments[idx + 1].split(separator: ":")
        guard halves.count == 2, let port = UInt16(halves[1]) else {
            fail("--net-udp-respond requires '<host-ip>:<host-port>', got '\(arguments[idx + 1])'.")
        }
        let parts = halves[0].split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else {
            fail("--net-udp-respond requires a dotted-quad IPv4 address, got '\(arguments[idx + 1])'.")
        }
        netUdpRespondHostIP = parts
        netUdpRespondHostPort = port
        idx += 2
    } else if arg == "--net-dns-respond", idx + 1 < arguments.count {
        let token = arguments[idx + 1]
        let halves = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let ipPart = String(halves[0])
        let parts = ipPart.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else {
            fail("--net-dns-respond requires a dotted-quad IPv4 address, got '\(token)'.")
        }
        netDnsRespondHostIP = parts
        if halves.count == 2, let port = UInt16(halves[1]) {
            netDnsRespondHostPort = port
        } else if halves.count == 2 {
            fail("--net-dns-respond port must be 1..65535, got '\(halves[1])'.")
        }
        idx += 2
    } else if arg == "--net-dns-answer", idx + 1 < arguments.count {
        // M99i (issue #2187): pin an A record into every A reply.
        let parts = arguments[idx + 1].split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else {
            fail("--net-dns-answer requires a dotted-quad IPv4 address, got '\(arguments[idx + 1])'.")
        }
        netDnsAnswers.append(parts)
        idx += 2
    } else if arg == "--net-dns-answer6", idx + 1 < arguments.count {
        // M99i: pin an AAAA record into every AAAA reply — 32 hex
        // digits (colons tolerated, stripped).
        let hex = arguments[idx + 1].replacingOccurrences(of: ":", with: "")
        guard hex.count == 32, let rdata = parseHexBytes(hex), rdata.count == 16 else {
            fail("--net-dns-answer6 requires 32 hex digits (colons optional), got '\(arguments[idx + 1])'.")
        }
        netDnsAnswers6.append(rdata)
        idx += 2
    } else if arg == "--net-dns-ttl", idx + 1 < arguments.count {
        guard let ttl = UInt32(arguments[idx + 1]) else {
            fail("--net-dns-ttl requires a non-negative integer, got '\(arguments[idx + 1])'.")
        }
        netDnsTTL = ttl
        idx += 2
    } else if arg == "--net-dns-spoof" {
        netDnsSpoof = true
        idx += 1
    } else if arg == "--net-dns-wrong-question" {
        netDnsWrongQuestion = true
        idx += 1
    } else if arg == "--net-dns-truncate" {
        netDnsTruncate = true
        idx += 1
    } else if arg == "--net-sntp-respond", idx + 1 < arguments.count {
        let token = arguments[idx + 1]
        let halves = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let octets = String(halves[0]).split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard octets.count == 4, halves[0].split(separator: ".", omittingEmptySubsequences: false).count == 4 else {
            fail("--net-sntp-respond requires a dotted-quad IPv4 address, got '\(token)'.")
        }
        netSntpRespondHostIP = octets
        if halves.count == 2 {
            guard let port = UInt16(halves[1]), port >= 1 else {
                fail("--net-sntp-respond port must be 1..65535, got '\(halves[1])'.")
            }
            netSntpRespondHostPort = port
        }
        idx += 2
    } else if arg == "--net-sntp-skew", idx + 1 < arguments.count {
        guard let skew = Int64(arguments[idx + 1]) else {
            fail("--net-sntp-skew requires a signed integer number of seconds, got '\(arguments[idx + 1])'.")
        }
        netSntpSkew = skew
        idx += 2
    } else if arg == "--net-dhcp-respond", idx + 1 < arguments.count {
        // Card N9 (claim 9489): the optional ":<lease-seconds>" suffix
        // (default 3600 — backward compatible) makes the OFFER/ACK's
        // lease option 51 configurable, so a live gate can test the
        // lease lifecycle (renewal/rebind/expiry) in seconds. Parse now
        // (fail early, like --timeout).
        let token = arguments[idx + 1]
        let halves = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let ipPart = String(halves[0])
        let parts = ipPart.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else {
            fail("--net-dhcp-respond requires a dotted-quad IPv4 lease address, got '\(token)'.")
        }
        netDhcpRespondLeaseIP = parts
        if halves.count == 2, let lease = UInt32(halves[1]), lease >= 1, lease <= 86400 {
            netDhcpRespondLeaseSecs = lease
        } else if halves.count == 2 {
            fail("--net-dhcp-respond lease must be 1..86400 seconds, got '\(halves[1])'.")
        }
        idx += 2
    } else if arg == "--net-dhcp-respond-norenew" {
        // Audit follow-up 3 (issue #119): refuse the guest's unicast
        // RENEWING REQUESTs (the host keeps answering DISCOVERs + the
        // initial/rebinding broadcast REQUESTs).
        netDhcpRespondNoRenew = true
        idx += 1
    } else if arg == "--net-dhcp-respond-norebind" {
        // Audit follow-up 3 (issue #119): refuse the guest's broadcast
        // REBINDING REQUESTs (ciaddr != 0). The initial REQUEST
        // (ciaddr == 0) is still answered, so binds/recovery work.
        netDhcpRespondNoRebind = true
        idx += 1
    } else if arg == "--net-tcp-respond", idx + 1 < arguments.count {
        // Card N10 (claim 7026): the same shape as --net-udp-respond
        // (host-ip:host-port). Card N11 (claim 5357): an optional
        // `:handshake` suffix selects the handshake-only responder (SYN
        // -> SYN-ACK, then silent on data/FIN — the gate's deterministic
        // black hole). M51 SSH1 (#1168): a `:packet` suffix selects the
        // paced packet responder (see --net-tcp-respond-payload). Parse now
        // (fail early, like --timeout).
        let token = arguments[idx + 1]
        let halves = token.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard halves.count >= 2, let port = UInt16(halves[1]) else {
            fail("--net-tcp-respond requires <host-ip>:<host-port>[:handshake|packet|ssh|relay|options], got '\(token)'.")
        }
        if halves.count == 3 {
            if halves[2] == "handshake" {
                netTcpRespondHandshakeOnly = true
            } else if halves[2] == "packet" {
                netTcpRespondPacketMode = true
            } else if halves[2] == "ssh" {
                // M51 SSH5 (#1172): the minimal SSH-2 server.
                netTcpRespondSSHMode = true
            } else if halves[2] == "relay" {
                // M51 interop (#1209): byte-forward to a real upstream
                // (`--net-tcp-respond-relay`).
                netTcpRespondRelayMode = true
            } else if halves[2] == "options" {
                // M99h (#2186): the option-carrying peer (a real peer's
                // wire shape — the guest must parse-and-skip).
                netTcpRespondOptionsMode = true
            } else {
                fail("--net-tcp-respond mode must be 'handshake', 'packet', 'ssh', 'relay' or 'options', got '\(halves[2])'.")
            }
        }
        let parts = halves[0].split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else {
            fail("--net-tcp-respond requires a dotted-quad IPv4 address, got '\(token)'.")
        }
        netTcpRespondHostIP = parts
        netTcpRespondHostPort = port
        idx += 2
    } else if arg == "--net-tcp-respond-payload", idx + 1 < arguments.count {
        // M51 SSH1 (#1168): the byte payload the `:packet` mode paces out.
        do {
            netTcpRespondPacketPayload = [UInt8](try Data(contentsOf: URL(fileURLWithPath: arguments[idx + 1])))
        } catch {
            fail("--net-tcp-respond-payload could not read file '\(arguments[idx + 1])': \(error).")
        }
        idx += 2
    } else if arg == "--net-tcp-respond-chunk", idx + 1 < arguments.count {
        guard let n = Int(arguments[idx + 1]), n >= 1, n <= 192 else {
            fail("--net-tcp-respond-chunk requires 1..192 bytes, got '\(arguments[idx + 1])'.")
        }
        netTcpRespondPacketChunk = n
        idx += 2
    } else if arg == "--net-tcp-respond-ssh-hostkey", idx + 1 < arguments.count {
        // M51 SSH5 (#1172): the pinned ssh-ed25519 host key seed (64 hex
        // chars). Default: RFC 8032 §7.1 TEST 1.
        guard let seed = SSHFixtures.hex(arguments[idx + 1]), seed.count == 32 else {
            fail("--net-tcp-respond-ssh-hostkey requires 64 hex chars (a 32-byte Ed25519 seed), got '\(arguments[idx + 1])'.")
        }
        netTcpRespondSSHHostKey = seed
        idx += 2
    } else if arg == "--net-tcp-respond-ssh-userkey", idx + 1 < arguments.count {
        // M51 SSH5 (#1172): the pinned client ssh-ed25519 PUBLIC key (64 hex
        // chars) the server accepts. Default: RFC 8032 §7.1 TEST 2.
        guard let key = SSHFixtures.hex(arguments[idx + 1]), key.count == 32 else {
            fail("--net-tcp-respond-ssh-userkey requires 64 hex chars (a 32-byte Ed25519 public key), got '\(arguments[idx + 1])'.")
        }
        netTcpRespondSSHUserKey = key
        idx += 2
    } else if arg == "--net-tcp-respond-ssh-tamper-mac" {
        // NEGATIVE MODE: flip one bit of the first encrypted server tag so
        // the guest's AEAD open must fail closed.
        netTcpRespondSSHTamperMAC = true
        idx += 1
    } else if arg == "--net-tcp-respond-ssh-marker", idx + 1 < arguments.count {
        netTcpRespondSSHMarker = arguments[idx + 1]
        idx += 2
    } else if arg == "--net-tcp-respond-ssh-exit", idx + 1 < arguments.count {
        guard let n = UInt32(arguments[idx + 1]) else {
            fail("--net-tcp-respond-ssh-exit requires a uint32, got '\(arguments[idx + 1])'.")
        }
        netTcpRespondSSHExitStatus = n
        idx += 2
    } else if arg == "--net-tcp-respond-relay", idx + 1 < arguments.count {
        // M51 interop (#1209): the real upstream the `:relay` mode
        // byte-forwards to, `<host-ip>:<host-port>` (dotted quad, like the
        // other responders — the documented manual real-sshd check).
        let token = arguments[idx + 1]
        let halves = token.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard halves.count >= 2, let port = UInt16(halves[1]) else {
            fail("--net-tcp-respond-relay requires <host-ip>:<host-port>, got '\(token)'.")
        }
        let parts = halves[0].split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else {
            fail("--net-tcp-respond-relay requires a dotted-quad IPv4 address, got '\(token)'.")
        }
        netTcpRespondRelayHost = String(halves[0])
        netTcpRespondRelayPort = port
        idx += 2
    } else if arg == "--net-tcp-connect", idx + 1 < arguments.count {
        // SH7 (#1083, ADR 0020 Amendment B): the host-initiated inbound TCP
        // client, the reverse of --net-tcp-respond. The optional third
        // component is a payload file whose bytes are sent once the
        // handshake completes.
        let token = arguments[idx + 1]
        let halves = token.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard halves.count >= 2, let port = UInt16(halves[1]) else {
            fail("--net-tcp-connect requires <guest-ip>:<port>[:<payload-file>], got '\(token)'.")
        }
        let parts = halves[0].split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else {
            fail("--net-tcp-connect requires a dotted-quad guest IPv4 address, got '\(token)'.")
        }
        var payload: [UInt8] = []
        var sshMode = false
        if halves.count == 3, !halves[2].isEmpty {
            if halves[2] == "ssh" {
                // M70g G1 (#1491): host SSH-2 client against GOSSHD.ELF.
                sshMode = true
                netTcpConnectSSHMode = true
            } else {
                let payloadPath = String(halves[2])
                do {
                    payload = [UInt8](try Data(contentsOf: URL(fileURLWithPath: payloadPath)))
                } catch {
                    fail("--net-tcp-connect could not read payload file '\(payloadPath)': \(error).")
                }
            }
        }
        // M99f (#2184): one NetTcpClient per flag — several host-initiated
        // connections run concurrently, each on its own source port.
        netTcpClients.append(NetTcpClient(
            guestIP: parts,
            guestPort: port,
            cliPort: netTcpCliPort &+ UInt16(netTcpClients.count),
            payload: payload,
            sshMode: sshMode
        ))
        if netTcpClients.count == 1 {
            netTcpConnectGuestIP = parts
            netTcpConnectPort = port
            netTcpConnectPayload = payload
        }
        idx += 2
    } else if arg == "--net-tcp-connect-ssh-exec", idx + 1 < arguments.count {
        netTcpConnectSSHExec = arguments[idx + 1]
        idx += 2
    } else if arg == "--net-tcp-connect-stream", idx + 1 < arguments.count {
        netTcpConnectStreamExec = arguments[idx + 1]
        idx += 2
    } else if arg == "--net-tcp-connect-stream-arg", idx + 1 < arguments.count {
        netTcpConnectStreamArgs.append(arguments[idx + 1])
        idx += 2
    } else if arg == "--net-native-preview", idx + 1 < arguments.count {
        let mode = arguments[idx + 1]
        guard mode == "reset" || mode == "timeout" else { fail("--net-native-preview requires reset|timeout") }
        nativeSocketProbeMode = mode
        nativeSocketProbe = NativeSocketProbe(mode: mode)
        idx += 2
    } else if arg == "--net-tcp-connect-intruder" {
        netTcpConnectIntruder = true
        idx += 1
    } else if arg == "--net-tcp-connect-ssh-user", idx + 1 < arguments.count {
        netTcpConnectSSHUser = arguments[idx + 1]
        idx += 2
    } else if arg == "--net-tcp-connect-after", idx + 1 < arguments.count {
        netTcpConnectAfter = arguments[idx + 1]
        idx += 2
    } else if arg == "--net-tcp-connect-close-after", idx + 1 < arguments.count {
        netTcpConnectCloseAfter = arguments[idx + 1]
        idx += 2
    } else if arg == "--net-tcp-connect-secret", idx + 1 < arguments.count {
        // M50 TS4 (#1138, ADR 0024 D6/D7): answer the guest's
        // `VIRELAIOS-AUTH/1` challenge with HMAC-SHA256(secret, message).
        netTcpConnectSecret = arguments[idx + 1]
        idx += 2
    } else if arg == "--net-tcp-connect-mac", idx + 1 < arguments.count {
        // M50 TS4 replay path: send this pre-recorded MAC hex line verbatim
        // (a captured handshake replayed against the fresh challenge).
        netTcpConnectMac = arguments[idx + 1]
        idx += 2
    } else if arg == "--script2-delay", idx + 1 < arguments.count {
        // Card N9 (claim 9489): the claim-6684 settle before forwarding
        // script2 becomes configurable (flag-gated, default 0.5 — every
        // existing gate is unchanged), so a lease-lifecycle gate can wait
        // past T1/T2/expiry deterministically.
        guard let d = Double(arguments[idx + 1]), d >= 0 else {
            fail("--script2-delay requires a non-negative number of seconds, got '\(arguments[idx + 1])'.")
        }
        script2Delay = d
        idx += 2
    } else if arg == "--script3-delay", idx + 1 < arguments.count {
        guard let d = Double(arguments[idx + 1]), d >= 0 else {
            fail("--script3-delay requires a non-negative number of seconds, got '\(arguments[idx + 1])'.")
        }
        script3Delay = d
        idx += 2
    } else if arg == "--net-nat" {
        netNatEnabled = true
        idx += 1
    } else if arg == "--net-bridged", idx + 1 < arguments.count {
        netBridgedInterface = arguments[idx + 1]
        idx += 2
    } else if arg == "--net-vmnet" {
        netVmnetEnabled = true
        idx += 1
    } else if arg == "--net-vmnet-subnet", idx + 1 < arguments.count {
        // <a.b.c.d>/<len> — the subnet base for the vmnet logical
        // network (the daemon assigns a rotating /24 without it). Must be
        // the network address: the daemon interprets the value literally
        // and a non-base address is a silent different network.
        let halves = arguments[idx + 1].split(separator: "/")
        let parts = halves.count == 2 ? halves[0].split(separator: ".").compactMap { UInt8($0) } : []
        guard halves.count == 2, let len = Int(halves[1]), (1...31).contains(len), parts.count == 4 else {
            fail("--net-vmnet-subnet requires '<a.b.c.d>/<len>' like 192.168.77.0/24, got '\(arguments[idx + 1])'.")
        }
        let mv: UInt32 = ~UInt32(0) << (32 - len)
        let av = UInt32(parts[0]) << 24 | UInt32(parts[1]) << 16 | UInt32(parts[2]) << 8 | UInt32(parts[3])
        guard av & mv == av else {
            fail("--net-vmnet-subnet: '\(arguments[idx + 1])' is not the network base (host bits set).")
        }
        netVmnetSubnet = (parts, len)
        idx += 2
    } else {
        serialLogPath = arg
        idx += 1
    }
}

// M128c (#2607): the packaged session app is the `.virelaivm` document
// handler (Session-Info.plist's CFBundleDocumentTypes). A Finder
// double-click launches it BARE — argv is just the executable — and
// delivers the clicked bundle as the open-documents AppleEvent after
// finishLaunching. Harvest it here, before the boot shape is built, and
// route it through the normal `--profile` resolution below so the bundle
// is minted/refused by name exactly as a flag boot is. The posture is the
// session front door's: --display --input --host-session, no deadline,
// and the serial log inside the clicked bundle's run/ (cwd is not the
// repo under a Finder launch, so the artifacts/ default cannot apply).
// A bare UNBUNDLED run keeps its artifacts/disk.img default — the gate
// fleet's plain VMRunner invocations never enter this block.
var documentProfileURL: URL? = nil
if arguments.count == 1, Bundle.main.bundleURL.pathExtension == "app" {
    let opener = HostOpenDocuments()
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.delegate = opener
    app.finishLaunching()
    HostApplication.launchFinished = true
    // `odoc` arrives through the app's EVENT queue, not a runloop source —
    // RunLoop.run never dispatches it (observed: the harvest timed out,
    // and the queued event landed on the failure window's delegate and
    // was refused). Drive the same loop body NSApp.run() runs.
    let openDeadline = Date().addingTimeInterval(5)
    while opener.openedURL == nil, Date() < openDeadline {
        autoreleasepool {
            if let event = app.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
        }
    }
    guard let clicked = opener.openedURL else {
        HostApplication.presentLaunchFailure(
            "VirelaiOS was launched without a .virelaivm machine document. Double-click a profile bundle in Finder, or run `just session`.")
    }
    // A Finder launch has no terminal — a corrupt bundle refuses in the
    // session window, not on a stderr nobody can see.
    do {
        _ = try VMProfile.load(from: clicked)
    } catch {
        HostApplication.presentLaunchFailure("\(error)")
    }
    documentProfileURL = clicked
    profilePath = clicked.path
    hostSessionMode = true
    displayMode = true
    inputMode = true
    timeout = 0
    let runDir = clicked.appendingPathComponent("run", isDirectory: true)
    try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    serialLogPath = runDir.appendingPathComponent("serial.log").path
    print("host-open: document \(clicked.path)")
}

// M115c (#2462): `--profile` resolves the bundle BEFORE the member paths
// are consumed below. An absent path is minted; an existing directory must
// carry a readable virelaivm/1 manifest (missing/corrupt refuses by name).
// Every profile member is a default — an explicit --vars/--overlay-base/
// --data-disk/--cvc-file/--cpus flag wins regardless of argument order.
var activeProfile: VMProfile? = nil
if profileInitOnly, profilePath == nil {
    fail("--profile-init requires --profile <path>.")
}
// M115d (#2463): `--resume` IS a profile boot — it names the bundle and
// flags the saved-state restore below. A resume names an existing
// bundle by name; minting one to restore an empty saved-state would be
// a silent no-suspend, so the load fails closed instead.
if let resumeFromPath {
    if profileInitOnly {
        fail("--resume and --profile-init are mutually exclusive.")
    }
    if vzRestore {
        fail("--resume and --vz-restore are mutually exclusive.")
    }
    if let profilePath, profilePath != resumeFromPath {
        fail("--resume and --profile disagree (resume boots the named bundle; pass one path).")
    }
    profilePath = resumeFromPath
}
var resumeStateURL: URL? = nil
if let profilePath {
    do {
        activeProfile = resumeFromPath != nil
            ? try VMProfile.load(from: URL(fileURLWithPath: profilePath))
            : try VMProfile.openOrCreate(at: URL(fileURLWithPath: profilePath))
    } catch {
        fail("\(resumeFromPath != nil ? "--resume" : "--profile"): \(error)")
    }
}
if let _ = resumeFromPath {
    // The file the ctl `suspend` verb writes — its absence is the honest
    // "there is no suspended state" refusal, named up front.
    let url = activeProfile!.savedStateURL.appendingPathComponent(SuspendCtl.stateFileName)
    guard FileManager.default.fileExists(atPath: url.path) else {
        fail("--resume: no saved state at \(url.path) (nothing has suspended into this profile).")
    }
    resumeStateURL = url
    print("SUSPEND-RESUME: armed state=\(url.path)")
}
if let p = activeProfile {
    if varsOverridePath == nil { varsOverridePath = p.efiVarsURL.path }
    if overlayBasePath == nil { overlayBasePath = p.config.baseImage }
    if dataDiskPath == nil, p.config.devices.dataDisk { dataDiskPath = p.vlfsURL.path }
    if cvcFileShareDir == nil, virtioFSShareDir == nil, p.config.devices.share {
        // The bundle's share/ rides the same host file channel --cvc-file
        // attaches — including the implied six-queue device shape. An
        // explicit --virtio-fs wins the slot: the custom-virtio device is
        // the one VZ save/restore refuses, so a save-capable caller arms
        // the share on the standard transport instead (M120a #2558).
        cvcFileShareDir = p.shareURL.path
        cvcSnapEnabled = true
        viaVirtioEnabled = true
        customVirtioEnabled = true
        cvcEchoEnabled = true
    }
    if !cpusExplicit { cpuCount = p.config.cpus }
    if !memoryMiBExplicit { memoryMiB = p.config.memoryMiB }
    displayMode = displayMode || p.config.devices.display
    inputMode = inputMode || p.config.devices.input
    soundMode = soundMode || p.config.devices.sound
    netNatEnabled = netNatEnabled || p.config.devices.netNat
    vsockEnabled = vsockEnabled || p.config.devices.vsock
}
if profileInitOnly {
    // Mint/validate the bundle and exit without booting — session.sh runs
    // this before seeding the share, so a corrupt bundle refuses by name
    // up front instead of mid-boot. The force-unwrap is safe: the guard
    // above already proved a profile loaded.
    let p = activeProfile!
    print("profile: \(p.created ? "created" : "loaded") \(p.url.path)")
    print("profile: identity=\(p.identity) cpus=\(p.config.cpus) memoryMiB=\(p.config.memoryMiB) base=\(p.config.baseImage)")
    exit(0)
}

// M115f (#2465): the opt-in OS self-update legs. `--apply-update` runs
// BEFORE the base image is opened: verify the signed staged set on the
// armed share, then swap it in as the base (old base -> <base>.prev, a
// profile's persistent overlay.asif discarded). `--rollback-update`
// swaps .prev back. Both are pure file operations on host paths — the
// guest can stage but can never choose whether the apply happens.
if applyUpdate, rollbackUpdate {
    fail("--apply-update and --rollback-update are mutually exclusive.")
}
if applyUpdate || rollbackUpdate {
    guard let base = overlayBasePath else {
        fail("\(rollbackUpdate ? "--rollback-update" : "--apply-update"): no_base (no base image — needs --overlay-base or --profile).")
    }
    let baseURL = URL(fileURLWithPath: base)
    // A profile's persistent overlay belongs to the outgoing base — a
    // swapped base starts with a fresh layer (the overlay is re-minted at
    // the attach point below when absent).
    let overlayURL = activeProfile?.overlayURL
    if rollbackUpdate {
        let hadOverlay = overlayURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        do {
            let sha = try OSUpdate.rollback(baseImage: baseURL, overlay: overlayURL)
            print("apply-update: rollback restored sha256=\(sha)")
            if hadOverlay {
                print("apply-update: overlay reset (stale sectors belong to the old base)")
            }
        } catch {
            fail("apply-update: \(error)")
        }
    } else {
        // The staged set lives on the share the guest writes — the armed
        // --cvc-file / --virtio-fs dir or the bundle's share/.
        guard let share = cvcFileShareDir ?? virtioFSShareDir else {
            fail("apply-update: no_share (UPDATE/ is staged on the host share — arm --cvc-file/--virtio-fs or a profile share).")
        }
        if let updateDir = OSUpdate.stagedDir(shareDir: URL(fileURLWithPath: share)) {
            // The trust pin: the flag wins; else the bundle's own
            // config.json updatePubkey — a host-side value the guest
            // cannot reach.
            let keyHex = updateKeyHex ?? activeProfile?.config.updatePubkey
            guard let keyHex, let keyData = dataFromHex(keyHex), keyData.count == 32 else {
                fail("apply-update: no_key (--update-key <64-hex Ed25519 public key> or profile config updatePubkey).")
            }
            // The overlay marker is observable: the discard of a
            // persistent overlay.asif is the proof no stale sector shadows
            // the new base (the attach point re-mints it on THIS boot).
            let hadOverlay = overlayURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            do {
                let manifest = try OSUpdate.apply(updateDir: updateDir, baseImage: baseURL,
                                                  publicKey: keyData, overlay: overlayURL)
                print("apply-update: applied version=\(manifest.version) image=\(OSUpdate.imageName)")
                if hadOverlay {
                    print("apply-update: overlay reset (stale sectors belong to the old base)")
                }
            } catch {
                fail("apply-update: \(error)")
            }
        } else {
            print("apply-update: none staged")
        }
    }
}

// Console sessions run until the VM stops or the user ends the session,
// unless an explicit --timeout was requested. Script mode is a non-
// interactive variant of the duplex console plumbing (claim 6684).
let consoleTimeout: TimeInterval = (consoleMode && !timeoutExplicit) ? 0 : timeout
let scriptMode = scriptPath != nil

// M114a: --host-cmd-after's marker scan runs on the scripted/session
// polls; refuse silently-never-firing modes up front.
if !hostCmdTriggers.isEmpty, !scriptMode, !hostSessionMode {
    fail("--host-cmd-after requires --script or --host-session (the serial-marker scan runs on the scripted and session polls).")
}
// M114b: --host-capture-keys needs a VZVirtualMachineView to capture keys
// into (--host-session implies --display by its own validation).
if hostCaptureKeys, screenshotPath == nil, !displayMode {
    fail("--host-capture-keys requires --screen/--display or --host-session (there is no VZVirtualMachineView to capture keys into).")
}
// M114d: the injector is single-line — a newline would smuggle extra
// commands past the drawer's one-line contract.
if let line = hostSerialSend, line.contains("\n") {
    fail("--host-serial-send takes a single line (no newline).")
}

// ---------------------------------------------------------------------------
// Terminal state management (used in console mode; no-ops elsewhere).
// ---------------------------------------------------------------------------

var originalTermios: termios?
var terminalRaw = false

func setupTerminal() {
    guard consoleMode else { return }
    guard isatty(STDIN_FILENO) == 1 else {
        print("  terminal: stdin is not a TTY — character mode skipped (piped input is still forwarded to the guest)")
        return
    }
    var t = termios()
    guard tcgetattr(STDIN_FILENO, &t) == 0 else {
        print("  terminal: WARNING — could not read terminal settings (tcgetattr failed); terminal left untouched")
        return
    }
    originalTermios = t
    // Character-oriented input: disable canonical line buffering and echo.
    // ISIG stays on so ^C still raises SIGINT (documented: it ends the host
    // console session rather than reaching the guest). ICRNL off so Enter is
    // forwarded as \r (0x0d); IXON off so ^S/^Q pass through to the guest.
    // Backspace is forwarded as the raw byte the terminal sends (typically
    // 0x7f). No host-side line editing is performed.
    t.c_lflag &= ~tcflag_t(ICANON | ECHO)
    t.c_iflag &= ~tcflag_t(ICRNL | IXON)
    withUnsafeMutableBytes(of: &t.c_cc) { raw in
        raw[Int(VMIN)] = 1
        raw[Int(VTIME)] = 0
    }
    guard tcsetattr(STDIN_FILENO, TCSANOW, &t) == 0 else {
        print("  terminal: WARNING — could not apply character mode (tcsetattr failed); input stays canonical")
        originalTermios = nil
        return
    }
    terminalRaw = true
    print("  terminal: character mode enabled (no echo, no line editing; Ctrl-C ends the session)")
}

func restoreTerminal() {
    guard terminalRaw, var orig = originalTermios else { return }
    terminalRaw = false
    originalTermios = nil
    tcsetattr(STDIN_FILENO, TCSANOW, &orig)
}

atexit { restoreTerminal() }

// Issue #523 item 2 (claim 6637): when --overlay-base is used, the throwaway
// ASIF overlay layer lives in this directory; it is removed at exit so
// concurrent runs never share (or leave behind) writable state. Set
// VIRELAI_KEEP_OVERLAY=1 to keep it for post-mortem.
var overlayCleanupPath: String?
atexit {
    if let p = overlayCleanupPath, ProcessInfo.processInfo.environment["VIRELAI_KEEP_OVERLAY"] == nil {
        try? FileManager.default.removeItem(atPath: p)
    }
}

func fail(_ message: String) -> Never {
    restoreTerminal()
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    if hostSessionMode {
        HostApplication.presentLaunchFailure(message)
    }
    exit(1)
}

func hostArchitecture() -> String {
    var u = utsname()
    uname(&u)
    return withUnsafeBytes(of: &u.machine) { raw -> String in
        var s = ""
        for byte in raw {
            if byte == 0 { break }
            s.append(String(UnicodeScalar(byte)))
        }
        return s
    }
}

guard hostArchitecture() == "arm64" else {
    fail("Unsupported host architecture '\(hostArchitecture())' -- Apple silicon is required.")
}
let osVersion = ProcessInfo.processInfo.operatingSystemVersion
// Project requirement: macOS 27+ (Apple silicon + Virtualization.framework).
// macOS 27 is the floor — the host-side custom-virtio interrupt path
// (VZCustomVirtioDevice) and the project's SDK/toolchain target assume it.
guard osVersion.majorVersion >= 27 else {
    fail("macOS \(osVersion.majorVersion) is too old — this project requires macOS 27 or newer (Apple silicon + Virtualization.framework).")
}
if hostSessionMode {
    guard displayMode && inputMode && !consoleMode && !vzRestore else {
        fail("--host-session requires --display --input and cannot be used with --console or --vz-restore.")
    }
}

if vzRestore, !timeout.isFinite || timeout <= 0 || timeout > 600 {
    fail("--vz-restore requires --timeout in (0, 600] seconds; it never runs unbounded.")
}
if vsockPortSet, !vsockEnabled {
    fail("--vsock-port requires --vsock (the port names the host listener on the attached device).")
}
if vsockCtlEnabled, !vsockEnabled {
    fail("--vsock-ctl requires --vsock (the control channel rides the same socket device).")
}
if vsockCtlPortSet, !vsockCtlEnabled {
    fail("--vsock-ctl-port requires --vsock-ctl.")
}
if vzRestoreWitness != nil, !vzRestore {
    fail("--vz-restore-witness requires --vz-restore.")
}
if let witness = vzRestoreWitness, witness.isEmpty || witness.contains("\n") {
    fail("--vz-restore-witness requires one non-empty serial line.")
}
if vzRestoreVerifyCommand != nil || vzRestoreVerifyOutput != nil {
    guard vzRestore, vzRestoreWitness != nil, vzRestoreSaveDir == nil,
          let command = vzRestoreVerifyCommand, !command.isEmpty, !command.contains("\n"),
          let output = vzRestoreVerifyOutput, !output.isEmpty, !output.contains("\n") else {
        fail("--vz-restore-verify-command and --vz-restore-verify-output require a witness and a run that resumes the VM.")
    }
}
// M70g G3 (#1459): the cross-process pair is two processes with one role each.
if vzRestoreSaveDir != nil || vzRestoreLoadDir != nil {
    guard vzRestore else { fail("--vz-restore-save/--vz-restore-load require --vz-restore.") }
    guard vzRestoreSaveDir == nil || vzRestoreLoadDir == nil else {
        fail("--vz-restore-save and --vz-restore-load are mutually exclusive (one process saves, another loads).")
    }
}
// ADR 0059 (M131b #2639): the scripted warm-leg shape. --script under
// --vz-restore is only meaningful on the load side — a save or
// same-process run has no checkpoint to resume into a leg.
if vzRestore, scriptPath != nil, vzRestoreLoadDir == nil {
    fail("--script under --vz-restore requires --vz-restore-load — a scripted leg restores a checkpoint bundle; the save/same-process probes run no leg workload (ADR 0059 D2/D4).")
}
let vzWarmLeg = vzRestore && vzRestoreLoadDir != nil && scriptPath != nil
if vzWarmLeg, vzRestoreWitness != nil {
    fail("--vz-restore-witness + --script: a scripted warm leg's handshake replaces the probe's marker query (ADR 0059 D5) — pick one load path.")
}
if vzRestoreSettle != nil {
    guard vzRestore, vzRestoreSaveDir != nil else {
        fail("--vz-restore-settle requires --vz-restore-save — it names the base boot's quiescent marker (ADR 0059 D4).")
    }
    guard !vzRestoreSettle!.isEmpty, !vzRestoreSettle!.contains("\n") else {
        fail("--vz-restore-settle requires one non-empty serial marker.")
    }
}
// M113b (#2418): the verified-boot flag family is all-or-nothing —
// enrollment flags without the arming flag are a loud error, never a
// silently ignored flag (the hardware-contract convention).
if !secureBootEnabled, secureBootPKPath != nil || !secureBootDbEfiPaths.isEmpty || !secureBootDbHashes.isEmpty {
    fail("--secure-boot-pk/--secure-boot-db-efi/--secure-boot-db-hash require --secure-boot.")
}
if secureBootEnabled {
    guard secureBootPKPath != nil else {
        fail("--secure-boot requires --secure-boot-pk <DER X.509 certificate path>.")
    }
    guard !secureBootDbEfiPaths.isEmpty || !secureBootDbHashes.isEmpty else {
        fail("--secure-boot requires at least one of --secure-boot-db-efi <PE path> or --secure-boot-db-hash <64-hex>.")
    }
    // M115c (#2462): enrollment overwrites the vars file every run, which
    // would destroy the profile's persistent efi-vars.bin — refuse the
    // combination rather than silently mangling a bundle member.
    guard activeProfile == nil else {
        fail("--secure-boot builds a FRESH variable store each run; --profile's efi-vars.bin is persistent. The combination is refused.")
    }
}

let overlayMode = overlayBasePath != nil
let diskURL = URL(fileURLWithPath: diskImagePath)
if !overlayMode {
    guard FileManager.default.fileExists(atPath: diskURL.path) else {
        fail("Disk image not found at '\(diskImagePath)'. Run 'zig build image' first.")
    }
}
let artifactsDir = URL(fileURLWithPath: "artifacts")
try? FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
// M113b (#2418, ADR 0054 D5): the PE/COFF Authenticode digest — the image
// hashed in file order skipping the CheckSum field (4 bytes), the
// IMAGE_DIRECTORY_ENTRY_SECURITY entry (8 bytes), and the Attribute
// Certificate Table it points to (a file offset, not an RVA). This is the
// convention the M113a probe observed the firmware db enforcing (ADR 0054
// Grounding 3: the raw file hash is refused, this digest boots).
func peAuthenticodeSHA256(_ data: Data) -> Data? {
    let b = [UInt8](data)
    func u16le(_ off: Int) -> Int { Int(b[off]) | (Int(b[off + 1]) << 8) }
    func u32le(_ off: Int) -> Int {
        Int(b[off]) | (Int(b[off + 1]) << 8) | (Int(b[off + 2]) << 16) | (Int(b[off + 3]) << 24)
    }
    guard b.count >= 0x40 else { return nil }
    let peOff = u32le(0x3c)
    guard peOff + 24 <= b.count,
          b[peOff] == 0x50, b[peOff + 1] == 0x45, b[peOff + 2] == 0, b[peOff + 3] == 0 else { return nil }
    let optOff = peOff + 4 + 20 // PE signature + COFF header
    let magic = u16le(optOff)
    let dirBase: Int
    let numDirsOff: Int
    switch magic {
    case 0x10b: dirBase = optOff + 96; numDirsOff = optOff + 92 // PE32
    case 0x20b: dirBase = optOff + 112; numDirsOff = optOff + 108 // PE32+
    default: return nil
    }
    guard numDirsOff + 4 <= b.count else { return nil }
    let numDirs = u32le(numDirsOff)
    let checksumOff = optOff + 64
    let secDirOff = dirBase + 4 * 8 // IMAGE_DIRECTORY_ENTRY_SECURITY
    var hasher = SHA256()
    if numDirs <= 4 || secDirOff + 8 > b.count {
        guard checksumOff + 4 <= b.count else { return nil }
        hasher.update(data: data[0..<checksumOff])
        hasher.update(data: data[(checksumOff + 4)..<b.count])
    } else {
        let certOff = u32le(secDirOff)
        let certSize = u32le(secDirOff + 4)
        guard checksumOff + 4 <= secDirOff else { return nil }
        hasher.update(data: data[0..<checksumOff])
        hasher.update(data: data[(checksumOff + 4)..<secDirOff])
        let contentEnd = certOff == 0 ? b.count : min(certOff, b.count)
        guard secDirOff + 8 <= contentEnd else { return nil }
        hasher.update(data: data[(secDirOff + 8)..<contentEnd])
        if certOff != 0 {
            guard certOff + certSize <= b.count else { return nil }
            hasher.update(data: data[(certOff + certSize)..<b.count])
        }
    }
    return Data(hasher.finalize())
}

/// Parse a 64-hex-char digest string into bytes (nil on bad input).
func dataFromHex(_ hex: String) -> Data? {
    let chars = Array(hex.utf8)
    guard chars.count % 2 == 0 else { return nil }
    var out = Data()
    out.reserveCapacity(chars.count / 2)
    var i = 0
    func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
    while i + 1 < chars.count {
        guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
        out.append(hi << 4 | lo)
        i += 2
    }
    return out
}

let varsURL = URL(fileURLWithPath: varsOverridePath ?? "artifacts/efi-vars.bin")
try? FileManager.default.createDirectory(at: varsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let variableStore: VZEFIVariableStore
if secureBootEnabled {
    // M113b (#2418, ADR 0054 D5): a FRESH per-run store — enrollment is
    // one-shot setup, not accumulated state, so any existing file at this
    // path is deliberately overwritten.
    do {
        variableStore = try VZEFIVariableStore(creatingVariableStoreAt: varsURL, options: .allowOverwrite)
    } catch {
        fail("Could not create EFI variable store at \(varsURL.path): \(error)")
    }
#if SPIKE
    if #available(macOS 27.0, *) {
        guard let pkPath = secureBootPKPath,
              let der = FileManager.default.contents(atPath: pkPath),
              let platformKey = SecCertificateCreateWithData(nil, der as CFData) else {
            fail("--secure-boot-pk: cannot load a DER X.509 certificate from '\(secureBootPKPath ?? "")'.")
        }
        var signatures: [VZEFISignature] = []
        for pePath in secureBootDbEfiPaths {
            guard let pe = FileManager.default.contents(atPath: pePath) else {
                fail("--secure-boot-db-efi: cannot read '\(pePath)'.")
            }
            guard let digest = peAuthenticodeSHA256(pe) else {
                fail("--secure-boot-db-efi: '\(pePath)' is not a well-formed PE/COFF image.")
            }
            signatures.append(.sha256(digest))
            print("  secure-boot: db += authenticode(\(pePath)) = \(digest.map { String(format: "%02x", $0) }.joined())")
        }
        for hexDigest in secureBootDbHashes {
            guard let digest = dataFromHex(hexDigest), digest.count == 32 else {
                fail("--secure-boot-db-hash: '\(hexDigest)' is not 32 bytes of hex.")
            }
            signatures.append(.sha256(digest))
            print("  secure-boot: db += hash \(hexDigest)")
        }
        do {
            try variableStore.enableSecureBoot(platformKey: platformKey)
            let dbList = VZEFISignatureList(signatures: signatures)
            // ADR 0054 D1: custom PK + a db of the pinned digests only —
            // KEK and dbx stay empty, no Microsoft signatures are enrolled.
            let enrollment = VZEFISignatureDatabaseConfiguration(
                keyExchangeKeys: [],
                dbSignatures: [dbList],
                dbxSignatures: [])
            try variableStore.enrollSecureBootSignatures(enrollment)
            print("  secure-boot: enabled pk=\(pkPath) db_hashes=\(signatures.count) vars=\(varsURL.path) (fresh per-run store)")
        } catch {
            fail("--secure-boot: enrollment failed: \(error)")
        }
    } else {
        fail("--secure-boot requires macOS 27+ (VZEFIVariableStore Secure Boot APIs).")
    }
#else
    fail("--secure-boot requires a SPIKE build (macOS 27 SDK Secure Boot types); rebuild with `swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE` (`zig build spike-virtio` drives it). This binary cannot enroll Secure Boot signatures.")
#endif
} else if FileManager.default.fileExists(atPath: varsURL.path) {
    variableStore = VZEFIVariableStore(url: varsURL)
} else {
    do {
        variableStore = try VZEFIVariableStore(creatingVariableStoreAt: varsURL, options: .allowOverwrite)
    } catch {
        fail("Could not create EFI variable store at \(varsURL.path): \(error)")
    }
}

let bootLoader = VZEFIBootLoader()
bootLoader.variableStore = variableStore
let config = VZVirtualMachineConfiguration()
config.bootLoader = bootLoader
config.memorySize = UInt64(memoryMiB) * 1024 * 1024
config.cpuCount = cpuCount
// M70g G3 (#1459): a saved machine state is bound to the platform's
// machineIdentifier (VZGenericPlatformConfiguration.h: "When a virtual machine
// is saved to disk then loaded again, the machineIdentifier must match the
// machineIdentifier of the saved virtual machine"). VZ mints a random one per
// configuration, so the SAVE process persists its identifier and the LOAD
// process adopts it. Observed 2026-09-18 without this: restoreMachineStateFrom
// in a new process fails VZErrorRestore (12) "invalid argument". The default
// VM (and the same-process probe) keeps VZ's implicit platform, byte-identical.
if vzRestoreSaveDir != nil || vzRestoreLoadDir != nil {
    let platform = VZGenericPlatformConfiguration()
    if let load = vzRestoreLoadDir {
        let idURL = URL(fileURLWithPath: load, isDirectory: true).appendingPathComponent("machine-id.bin")
        guard let data = FileManager.default.contents(atPath: idURL.path),
              let id = VZGenericMachineIdentifier(dataRepresentation: data) else {
            fail("--vz-restore-load: no valid machine-id.bin in '\(load)' (run --vz-restore-save first).")
        }
        platform.machineIdentifier = id
        print("  platform: machineIdentifier adopted from \(idURL.path) (--vz-restore-load)")
    } else if let save = vzRestoreSaveDir {
        let dir = URL(fileURLWithPath: save, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try platform.machineIdentifier.dataRepresentation.write(to: dir.appendingPathComponent("machine-id.bin"))
        } catch {
            fail("--vz-restore-save: could not persist the machine identifier into '\(save)': \(error)")
        }
        print("  platform: machineIdentifier persisted to \(dir.appendingPathComponent("machine-id.bin").path) (--vz-restore-save)")
    }
    config.platform = platform
} else if let p = activeProfile {
    // M115c (#2462): a profiled machine keeps ONE machineIdentifier for its
    // whole life — adopt the bundle's machine-id.bin (minted at create,
    // reminted+persisted here if absent or unreadable by VZ) so a later
    // saved state binds and every boot presents the same machine.
    let platform = VZGenericPlatformConfiguration()
    if let data = p.machineIdentifierData(),
       let id = VZGenericMachineIdentifier(dataRepresentation: data) {
        platform.machineIdentifier = id
    } else {
        do {
            try p.setMachineIdentifier(platform.machineIdentifier.dataRepresentation)
        } catch {
            fail("--profile: could not persist \(p.machineIdentifierURL.path): \(error)")
        }
        print("  platform: machineIdentifier minted into \(p.machineIdentifierURL.path)")
    }
    config.platform = platform
}

do {
    if let base = overlayBasePath {
#if canImport(DiskImageKit)
        guard #available(macOS 27.0, *) else {
            fail("--overlay-base requires macOS 27+ DiskImageKit.")
        }
        // macOS 27 DiskImageKit stacked image (issue #523 item 2, claim
        // 6637): read-only base + a fresh ASIF overlay layer in a private
        // temp dir (removed at exit by the atexit handler). API verified
        // against the Xcode 27 SDK swiftinterfaces.
        let baseURL = URL(fileURLWithPath: base)
        guard FileManager.default.fileExists(atPath: baseURL.path) else {
            fail("Overlay base image not found at '\(base)'.")
        }
        let diskBase = try DiskImage(opening: .open(url: baseURL, mode: .readOnly))
        if let load = vzRestoreLoadDir {
            // M70g G3 (#1459): the LOAD process must see the disk exactly as
            // the SAVE process left it, so it re-opens the overlay that
            // process persisted instead of creating a fresh one.
            let overlayURL = URL(fileURLWithPath: load, isDirectory: true).appendingPathComponent("overlay.asif")
            guard FileManager.default.fileExists(atPath: overlayURL.path) else {
                fail("--vz-restore-load: no overlay.asif in '\(load)' (run --vz-restore-save first).")
            }
            let overlay = try DiskImage(opening: .open(url: overlayURL, mode: .readWrite))
            let stacked = try diskBase.appending(overlay)
            let attachment = try VZDiskImageStorageDeviceAttachment(diskImage: stacked)
            config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
            print("  disk: \(base) (base, read-only) + persisted ASIF overlay \(overlayURL.path) (--vz-restore-load)")
        } else {
            let stackDir: URL
            if let save = vzRestoreSaveDir {
                // M70g G3 (#1459): the overlay outlives this process — no
                // cleanup; the load process (or a failed run's post-mortem)
                // owns it.
                stackDir = URL(fileURLWithPath: save, isDirectory: true)
            } else if let p = activeProfile {
                // M115c (#2462): the overlay lives INSIDE the bundle — a
                // persisted member, never the throwaway tmp layer, and never
                // the atexit cleanup.
                stackDir = p.url
            } else {
                stackDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("virelai-overlay-\(UUID().uuidString)", isDirectory: true)
                overlayCleanupPath = stackDir.path
            }
            try FileManager.default.createDirectory(at: stackDir, withIntermediateDirectories: true)
            let overlayURL = stackDir.appendingPathComponent("overlay.asif")
            let stacked: any StackedImage
            if let p = activeProfile, FileManager.default.fileExists(atPath: overlayURL.path) {
                // M115c: a profiled machine REOPENS its persisted overlay —
                // guest writes to the boot disk survive across sessions.
                // (The vz-restore-save leg above is unreachable with a
                // profile: --profile is not in that probe's flag set.)
                _ = p
                let overlay = try DiskImage(opening: .open(url: overlayURL, mode: .readWrite))
                stacked = try diskBase.appending(overlay)
            } else {
                let layer = ASIFCreationConfiguration.layer(
                    url: overlayURL,
                    type: .overlay(blockCount: Int(diskBase.blockCount)))
                stacked = try diskBase.appending(layer)
            }
            let attachment = try VZDiskImageStorageDeviceAttachment(diskImage: stacked)
            config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
            if vzRestoreSaveDir != nil {
                print("  disk: \(base) (base, read-only) + persisted ASIF overlay in \(stackDir.path) (--vz-restore-save; kept for the load process)")
            } else if activeProfile != nil {
                print("  disk: \(base) (base, read-only) + persistent ASIF overlay \(overlayURL.path) (--profile)")
            } else {
                print("  disk: \(base) (base, read-only) + throwaway ASIF overlay in \(stackDir.path)")
            }
        }
#else
        fail("--overlay-base needs an SDK with DiskImageKit (macOS 27+); this binary was built without it.")
#endif
    } else {
        let attachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
    }
} catch {
    fail("Could not attach disk image '\(diskImagePath)': \(error)")
}

// M100b (issue #2307, ADR 0050 D1/D2): --data-disk appends a SECOND
// VZVirtioBlockDeviceConfiguration in every attach mode (plain and
// --overlay-base — the overlay covers the boot disk only; the data disk
// itself is never stacked). It is named "virelai-vlfs" so the guest's
// VIRTIO_BLK_T_GET_ID can tell it from the boot image, and its attachment
// runs synchronizationMode .full so a guest FLUSH is a host-side full
// sync. A missing file becomes a zero-filled raw image (default 64 MiB);
// the guest then refuses mount with not_vlfs until mkfs.vlfs (M100c)
// formats it — never the runner's or kernel's job.
if let dataDiskPath {
    do {
        let prepared = try DataDisk.prepare(path: dataDiskPath)
        try VZVirtioBlockDeviceConfiguration.validateBlockDeviceIdentifier(DataDisk.vlfsIdentifier)
        let attachment = try VZDiskImageStorageDeviceAttachment(
            url: prepared.url,
            readOnly: false,
            cachingMode: .automatic,
            synchronizationMode: .full)
        let dataDisk = VZVirtioBlockDeviceConfiguration(attachment: attachment)
        dataDisk.blockDeviceIdentifier = DataDisk.vlfsIdentifier
        config.storageDevices.append(dataDisk)
        if prepared.created {
            print("  data-disk: created zero-filled raw image \(dataDiskPath) (\(prepared.sectors) sectors)")
        } else {
            print("  data-disk: \(dataDiskPath) (\(prepared.sectors) sectors)")
        }
    } catch {
        fail("Could not attach --data-disk image '\(dataDiskPath)': \(error)")
    }
}

// ---------------------------------------------------------------------------
// Serial plumbing: evidence path (unchanged) vs console path (duplex + tee).
// ---------------------------------------------------------------------------

// Console-mode duplex pipes. The attachment reads host input from
// consoleInputPipe's read end (we forward stdin into its write end) and
// writes guest output to consoleOutputPipe's write end (we tee its read end
// to the terminal and the log). Non-console mode never touches these.
let consoleInputPipe = Pipe()
let consoleOutputPipe = Pipe()
var serialLogHandle: FileHandle?

let serialURL = URL(fileURLWithPath: serialLogPath)
FileManager.default.createFile(atPath: serialURL.path, contents: nil)
if consoleMode || scriptMode {
    do {
        serialLogHandle = try FileHandle(forWritingTo: serialURL)
    } catch {
        fail("Could not open serial log at \(serialURL.path): \(error)")
    }
}

// Claim 0680: the structured-console sink. Opened when --cvc-console-file
// was passed; the delegate writes every queue-1 guest log line into it
// verbatim (raw bytes, no injected newlines — the guest's own '\n'
// terminators are the only line breaks, so the file stays byte-faithful).
var cvcConsoleFileHandle: FileHandle?
if let path = cvcConsoleFilePath {
    let url = URL(fileURLWithPath: path)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    do {
        cvcConsoleFileHandle = try FileHandle(forWritingTo: url)
    } catch {
        fail("Could not open cvc console file at \(url.path): \(error)")
    }
}

let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
if consoleMode || scriptMode {
    // Duplex attachment: the host-to-guest input handle is non-nil.
    serialConfig.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: consoleInputPipe.fileHandleForReading,
        fileHandleForWriting: consoleOutputPipe.fileHandleForWriting
    )
} else {
    // Evidence path: output-only attachment, exactly as before.
    let serialHandle: FileHandle
    do {
        serialHandle = try FileHandle(forWritingTo: serialURL)
    } catch {
        fail("Could not open serial log at \(serialURL.path): \(error)")
    }
    serialConfig.attachment = VZFileHandleSerialPortAttachment(
        // M114d (#2457): --host-session gets the read end too — the
        // drawer's injector (send-serial) needs a guest RX path; vzRestore
        // already needed it for the probe's serial query.
        fileHandleForReading: (vzRestore || hostSessionMode) ? consoleInputPipe.fileHandleForReading : nil,
        fileHandleForWriting: serialHandle
    )
}
config.serialPorts = [serialConfig]
// M97g (#2084): --no-entropy leaves entropyDevices empty — the guest sees
// no DID 0x1044 device, the boot seed fails, and slot 72 must refuse.
config.entropyDevices = noEntropy ? [] : [VZVirtioEntropyDeviceConfiguration()]

var machineView: VZVirtualMachineView?
var machineWindow: NSWindow?
// Milestone six card G1 (claim 6053): the virtio-gpu device is attached
// under `--display` (the milestone's mode — the machine boots to a
// screen) as well as under `--screenshot` (the evidence capture). The
// default VM attaches NO graphics device — config.graphicsDevices stays
// [] and every existing gate stays byte-identical.
if screenshotPath != nil || displayMode {
    let graphics = VZVirtioGraphicsDeviceConfiguration()
    graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 720)]
    config.graphicsDevices = [graphics]
} else {
    config.graphicsDevices = []
}
// Milestone seven card I1 (claim 4272; premise corrected by claim 3868):
// the keyboard + pointing devices are attached only under `--input`. The
// default VM attaches none — config.keyboards/pointingDevices stay [] and
// every existing gate stays byte-identical. The guest observes an Apple
// XHCI USB controller (VID=0x106b DID=0x1a06), NOT virtio-input — the
// claim-3868 finding.
if inputMode {
    config.keyboards = [VZUSBKeyboardConfiguration()]
    config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
} else {
    config.keyboards = []
    config.pointingDevices = []
}
// M43 card U6: the USB mass storage device rides an explicit XHCI controller
// configuration (the macOS 15+ usbControllers surface). Purely additive —
// without --usb-msd the array stays empty and the boot is byte-identical.
if let usbMsdPath {
    let usbMsdURL = URL(fileURLWithPath: usbMsdPath)
    guard FileManager.default.fileExists(atPath: usbMsdURL.path) else {
        fail("--usb-msd: disk image not found: \(usbMsdPath)")
    }
    do {
        let msdAttachment = try VZDiskImageStorageDeviceAttachment(url: usbMsdURL, readOnly: false)
        let msd = VZUSBMassStorageDeviceConfiguration(attachment: msdAttachment)
        let xhciController = VZXHCIControllerConfiguration()
        xhciController.usbDevices = [msd]
        config.usbControllers = [xhciController]
    } catch {
        fail("--usb-msd: could not attach disk image \(usbMsdPath): \(error)")
    }
}
// Milestone five card N1 (claim 1373): the virtio-net device, attached only
// under `--net <capture-file>`. VZFileHandleNetworkDeviceAttachment transmits
// raw data-link frames over ONE connected datagram socket: VZ holds one end
// (every guest-transmitted frame arrives as a datagram; host->guest frames
// would be written into the same socket — that is card N2's RX direction),
// and the runner reads the other end and appends each datagram to the
// capture file byte-exactly. The guest MAC is FIXED on the host config
// (VZMACAddress "02:00:00:00:00:01", locally administered) so the guest's
// VIRTIO_NET_F_MAC read is deterministic and gate-assertable. Without the
// flag the config is exactly as before: networkDevices = [] — every existing
// gate stays byte-identical.
var netCaptureHandle: FileHandle? // capture file (append)
var netCaptureSocket: FileHandle? // the socket end VZ transmits to
var netCaptureReadSocket: FileHandle? // the runner's read end
var netCaptureStop = false
var netCaptureThread: Thread?
var netCaptureDone = DispatchSemaphore(value: 0)
if netInjectPath != nil, netCapturePath == nil {
    fail("--net-inject requires --net (the injection writes into the SAME attachment's socket).")
}
if netArpRespondHostIP != nil, netCapturePath == nil {
    fail("--net-arp-respond requires --net (the ARP reply is written into the SAME attachment's socket).")
}
if netRaRespondPrefix != nil, netCapturePath == nil {
    fail("--net-ra-respond requires --net (the RA is written into the SAME attachment's socket).")
}
if !netNdpRespondAddrs.isEmpty, netCapturePath == nil {
    fail("--net-ndp-respond requires --net (the NA is written into the SAME attachment's socket).")
}
if netIcmp6RespondAddr != nil, netCapturePath == nil {
    fail("--net-icmp6-respond requires --net (the echo reply is written into the SAME attachment's socket).")
}
if netUdp6RespondAddr != nil, netCapturePath == nil {
    fail("--net-udp6-respond requires --net (the UDP reply is written into the SAME attachment's socket).")
}
if netTcp6RespondAddr != nil, netCapturePath == nil {
    fail("--net-tcp6-respond requires --net (the TCP replies are written into the SAME attachment's socket).")
}
if netIcmpRespondHostIP != nil, netCapturePath == nil {
    fail("--net-icmp-respond requires --net (the ICMP reply is written into the SAME attachment's socket).")
}
if netUdpRespondHostIP != nil, netCapturePath == nil {
    fail("--net-udp-respond requires --net (the UDP reply is written into the SAME attachment's socket).")
}
if netDnsRespondHostIP != nil, netCapturePath == nil {
    fail("--net-dns-respond requires --net (the DNS reply is written into the SAME attachment's socket).")
}
// M99i (issue #2187): the depth knobs are meaningless without the
// responder they configure.
if netDnsRespondHostIP == nil,
   !netDnsAnswers.isEmpty || !netDnsAnswers6.isEmpty || netDnsTTL != 300 ||
   netDnsSpoof || netDnsWrongQuestion || netDnsTruncate {
    fail("--net-dns-answer/--net-dns-answer6/--net-dns-ttl/--net-dns-spoof/--net-dns-wrong-question/--net-dns-truncate require --net-dns-respond.")
}
if netSntpRespondHostIP != nil, netCapturePath == nil {
    fail("--net-sntp-respond requires --net (the SNTP reply is written into the SAME attachment's socket).")
}
if netSntpSkew != nil, netSntpRespondHostIP == nil {
    fail("--net-sntp-skew requires --net-sntp-respond.")
}
let netSntpResponder: SNTPResponder? = netSntpRespondHostIP.map {
    SNTPResponder(hostIP: $0, hostPort: netSntpRespondHostPort, skew: netSntpSkew ?? 0,
                  clock: { Date().timeIntervalSince1970 })
}
if netDhcpRespondLeaseIP != nil, netCapturePath == nil {
    fail("--net-dhcp-respond requires --net (the DHCP reply is written into the SAME attachment's socket).")
}
if netTcpRespondHostIP != nil, netCapturePath == nil {
    fail("--net-tcp-respond requires --net (the TCP reply is written into the SAME attachment's socket).")
}
// M51 SSH1 (#1168): the paced packet mode needs a payload to send.
if netTcpRespondPacketMode, netTcpRespondPacketPayload.isEmpty {
    fail("--net-tcp-respond :packet requires --net-tcp-respond-payload <file>.")
}
// M51 SSH5 (#1172): the SSH responder's hand-rolled cipher must reproduce
// the OpenSSH `PROTOCOL.chacha20poly1305` vector the guest's Zig
// implementation pins (ADR 0023 D2 drift guard) before the mode is armed.
if netTcpRespondSSHMode {
    guard SSHFixtures.cipherSelfCheck() else {
        fail("--net-tcp-respond :ssh cipher self-check FAILED (the OpenSSH PROTOCOL.chacha20poly1305 pinned vector did not reproduce). Refusing to serve the SSH responder.")
    }
    print("NET-TCP-SSH: cipher self-check ok (OpenSSH PROTOCOL.chacha20poly1305 pinned vector, seq 7, tag \(SSHFixtures.opensshVectorTagHex))")
}
// M51 interop (#1209): `:relay` needs the real upstream to forward to.
if netTcpRespondRelayMode, netTcpRespondRelayPort == nil {
    fail("--net-tcp-respond :relay requires --net-tcp-respond-relay <host-ip>:<host-port> (the real upstream TCP server).")
}
if netTcpConnectGuestIP != nil, netCapturePath == nil {
    fail("--net-tcp-connect requires --net (the client frames are written into the SAME attachment's socket).")
}
if nativeSocketProbeMode != nil && (netCapturePath == nil || netNatEnabled || netTcpConnectGuestIP != nil) {
    fail("--net-native-preview requires hermetic --net, no NAT or other connecting peer")
}
if netTcpConnectStreamExec != nil && (netTcpClients.isEmpty || netTcpClients.first!.sshMode || !netTcpClients.first!.payload.isEmpty || netNatEnabled) {
    fail("--net-tcp-connect-stream requires --net-tcp-connect <ip>:<port> with --net; no SSH, payload, or NAT")
}
if netTcpConnectStreamExec == nil && (!netTcpConnectStreamArgs.isEmpty || netTcpConnectIntruder) {
    fail("--net-tcp-connect-stream-arg and --net-tcp-connect-intruder require --net-tcp-connect-stream")
}
if netTcpConnectSSHMode {
    guard SSHFixtures.cipherSelfCheck() else {
        fail("--net-tcp-connect :ssh cipher self-check FAILED (the OpenSSH PROTOCOL.chacha20poly1305 pinned vector did not reproduce). Refusing to arm the SSH client.")
    }
    print("NET-TCP-CONNECT-SSH: cipher self-check ok (OpenSSH PROTOCOL.chacha20poly1305 pinned vector, seq 7, tag \(SSHFixtures.opensshVectorTagHex))")
}
// Milestone five card N7 (claim 4678): `--net-nat` is mutually exclusive
// with `--net` — one network device per guest for now (the flag
// validation shape: a clear fail, like the responder requirements above).
if netNatEnabled, netCapturePath != nil {
    fail("--net-nat is mutually exclusive with --net (one network device per guest for now).")
}
// M117d (issue #2476, ADR 0057 D11): the opt-in real-LAN attachments get
// the same one-network-device bound, then their own named refusals — the
// absent interface names itself, the absent com.apple.vm.networking
// entitlement names itself (checked in THIS signature: it is what VZ's
// config.validate() consults), and a non-success vmnet_return_t carries
// its status. Both keys are restricted entitlements an ad-hoc codesign
// cannot carry (observed 2026-10-17, macOS 27.2: amfid kills the process
// before main — "adhoc signed but contains restricted entitlements"), so
// they live in host/vm-runner/entitlements-net.plist for a
// development-signed build; entitlements.plist stays the ad-hoc-safe set.
func runnerHasEntitlement(_ name: String) -> Bool {
    guard let task = SecTaskCreateFromSelf(nil),
          let value = SecTaskCopyValueForEntitlement(task, name as CFString, nil) else {
        return false
    }
    return (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
}
#if canImport(vmnet)
func vmnetStatusName(_ status: vmnet_return_t) -> String {
    switch status.rawValue {
    case 1000: return "VMNET_SUCCESS"
    case 1001: return "VMNET_FAILURE"
    case 1002: return "VMNET_MEM_FAILURE"
    case 1003: return "VMNET_INVALID_ARGUMENT"
    case 1004: return "VMNET_SETUP_INCOMPLETE"
    case 1005: return "VMNET_INVALID_ACCESS"
    case 1006: return "VMNET_PACKET_TOO_BIG"
    case 1007: return "VMNET_BUFFER_EXHAUSTED"
    case 1008: return "VMNET_TOO_MANY_PACKETS"
    case 1009: return "VMNET_SHARING_SERVICE_BUSY"
    case 1010: return "VMNET_NOT_AUTHORIZED"
    default: return "vmnet_return_t(\(status.rawValue))"
    }
}
func ipv4Text(_ addr: in_addr) -> String {
    let b = UInt32(bigEndian: addr.s_addr)
    return "\(b >> 24 & 0xff).\(b >> 16 & 0xff).\(b >> 8 & 0xff).\(b & 0xff)"
}
func prefixLen(_ mask: in_addr) -> Int {
    Int((UInt32(bigEndian: mask.s_addr)).nonzeroBitCount)
}
#endif
if netBridgedInterface != nil {
    if netCapturePath != nil {
        fail("--net-bridged is mutually exclusive with --net (one network device per guest for now).")
    }
    if netNatEnabled {
        fail("--net-bridged is mutually exclusive with --net-nat (one network device per guest for now).")
    }
    if netVmnetEnabled {
        fail("--net-bridged is mutually exclusive with --net-vmnet (one network device per guest for now).")
    }
    let wanted = netBridgedInterface!
    guard let iface = VZBridgedNetworkInterface.networkInterfaces.first(where: { $0.identifier == wanted }) else {
        let available = VZBridgedNetworkInterface.networkInterfaces.map { $0.identifier }.joined(separator: ",")
        fail("--net-bridged: interface '\(wanted)' is not in VZBridgedNetworkInterface.networkInterfaces (bridgeable here: \(available.isEmpty ? "<none>" : available)).")
    }
    if !runnerHasEntitlement("com.apple.vm.networking") {
        fail("--net-bridged requires the com.apple.vm.networking entitlement, which this binary's signature does not carry. It is a RESTRICTED entitlement on macOS 27: an ad-hoc codesign (--sign -) carrying it is killed by amfid before main() (observed). Sign with a development identity using host/vm-runner/entitlements-net.plist, or use --net/--net-nat instead.")
    }
    netBridgedIface = iface
}
if netVmnetEnabled {
    if netCapturePath != nil {
        fail("--net-vmnet is mutually exclusive with --net (one network device per guest for now).")
    }
    if netNatEnabled {
        fail("--net-vmnet is mutually exclusive with --net-nat (one network device per guest for now).")
    }
    if netBridgedInterface != nil {
        fail("--net-vmnet is mutually exclusive with --net-bridged (one network device per guest for now).")
    }
#if canImport(vmnet)
    var netVmnetStatus = vmnet_return_t.VMNET_SUCCESS
    guard let vmnetConfig = vmnet_network_configuration_create(operating_modes_t.VMNET_SHARED_MODE, &netVmnetStatus) else {
        fail("--net-vmnet: vmnet_network_configuration_create failed (vmnet_return_t=\(netVmnetStatus.rawValue) \(vmnetStatusName(netVmnetStatus))).")
    }
    if let subnet = netVmnetSubnet {
        // The daemon's set_ipv4_subnet takes the GATEWAY address — the
        // second address of the range — not the base (observed in
        // apple/containerization's configureSubnetV4, and by the daemon's
        // own refusal: passing the base gives "can't have the gateway at
        // the subnet address" at interface start, err 49).
        let mv: UInt32 = ~UInt32(0) << (32 - subnet.prefixLen)
        let av = UInt32(subnet.ip[0]) << 24 | UInt32(subnet.ip[1]) << 16 | UInt32(subnet.ip[2]) << 8 | UInt32(subnet.ip[3])
        var saddr = in_addr(s_addr: (av + 1).byteSwapped)
        var smask = in_addr(s_addr: mv.byteSwapped)
        let setStatus = vmnet_network_configuration_set_ipv4_subnet(vmnetConfig, &saddr, &smask)
        guard setStatus == .VMNET_SUCCESS else {
            fail("--net-vmnet-subnet: vmnet_network_configuration_set_ipv4_subnet failed (vmnet_return_t=\(setStatus.rawValue) \(vmnetStatusName(setStatus))).")
        }
    }
    var netVmnetCreateStatus = vmnet_return_t.VMNET_SUCCESS
    guard let network = vmnet_network_create(vmnetConfig, &netVmnetCreateStatus) else {
        fail("--net-vmnet: vmnet_network_create failed (vmnet_return_t=\(netVmnetCreateStatus.rawValue) \(vmnetStatusName(netVmnetCreateStatus))) — the vmnet daemon requires the com.apple.developer.networking.vmnet entitlement or root (observed in the daemon's client_entitlement_check). The entitlement is restricted: an ad-hoc codesign cannot carry it — sign with a development identity using host/vm-runner/entitlements-net.plist.")
    }
    netVmnetNetwork = network
    var netSub = in_addr(), netMask = in_addr()
    vmnet_network_get_ipv4_subnet(network, &netSub, &netMask)
    netVmnetSubnetText = "\(ipv4Text(netSub))/\(prefixLen(netMask))"
#else
    fail("--net-vmnet requires a macOS 26+ SDK build (vmnet_network_create); this binary was compiled without vmnet.framework.")
#endif
}
if netVmnetSubnet != nil, !netVmnetEnabled {
    fail("--net-vmnet-subnet requires --net-vmnet.")
}
// M70g G2 (#1459): the bridge secret comes from the file OR the inline spec,
// never both; the file form is preferred because argv is world-readable.
if let fileSecret = consoleTCPSecretFromFile {
    guard consoleTCPPort != nil else {
        fail("--console-tcp-secret-file requires --console-tcp.")
    }
    guard consoleTCPSecret == nil else {
        fail("--console-tcp-secret-file: the --console-tcp spec already carries an inline secret; use one or the other.")
    }
    consoleTCPSecret = fileSecret
} else if consoleTCPSecret != nil {
    FileHandle.standardError.write(Data("WARNING: --console-tcp: an inline secret is visible in the process list; prefer --console-tcp-secret-file <path>\n".utf8))
}
// Card G6 set_visible follow-on (claim 0487): the marker-driven capture
// writes into the `--screen <base>` filename, so it requires the flag.
if screenshotAfter != nil, screenshotPath == nil {
    fail("--screenshot-after requires --screen (the marker capture writes into the --screen base filename).")
}
// M81f (#1766): a host-side share mutation only means anything when the
// guest is actually reading that share over the file channel, and the three
// flags form ONE trigger — a half-specified one is a parse error, not a
// silent no-op.
if hostWriteAfter != nil || hostWritePath != nil || hostWriteContent != nil {
    guard hostWriteAfter != nil, hostWritePath != nil else {
        fail("--host-write/--host-write-after/--host-write-content form one marker-anchored mutation: give --host-write <relpath> and --host-write-after <marker> (--host-write-content is the optional body).")
    }
    guard cvcFileEnabled else {
        fail("--host-write-after requires --cvc-file <share-dir> (the mutation must land in the share the guest reads).")
    }
}
// M108b (#2325, ADR 0051 D6): the lane flags are modifiers on --cvc-file —
// the share IS the transport, so a lane flag without it is a fatal argument
// error (loud, never a silent ignore — the --via-virtio rule).
if hostClipboardFlag || hostPasteboardName != nil || hostClipInText != nil || hostClipInAfter != nil || hostClipInFile != nil || hostClipInMime != nil {
    guard hostClipboardFlag else {
        fail("--host-pasteboard/--host-clip-in/--host-clip-in-after are modifiers on --host-clipboard (no lane to redirect or inject into).")
    }
    guard cvcFileEnabled else {
        fail("--host-clipboard requires --cvc-file <share-dir> (the lanes are signed files in that share — ADR 0051 D1).")
    }
    if hostClipInAfter != nil, hostClipInText == nil, hostClipInFile == nil {
        fail("--host-clip-in-after requires --host-clip-in <text> or --host-clip-in-file <path> (there is no pasteboard write to schedule).")
    }
    if hostClipInFile != nil, hostClipInMime == nil {
        fail("--host-clip-in-file requires --host-clip-in-mime <mime> (the type the inject negotiates on the pasteboard).")
    }
    if hostClipInMime != nil, hostClipInFile == nil {
        fail("--host-clip-in-mime requires --host-clip-in-file <path> (mime alone has no bytes to offer).")
    }
    if hostClipInText != nil || hostClipInFile != nil, hostClipInAfter == nil {
        // Default trigger: fire as soon as the seat announces the lane is
        // armed — the deterministic point where a CLIP_IN can be consumed.
        hostClipInAfter = "gotabwm: hostint armed"
    }
}
// M108c (#2326, ADR 0051 D6): the drop lane is the same shape — a modifier
// on --cvc-file, its hooks modifiers on the lane.
if hostDropFlag || !hostDropFiles.isEmpty || hostDropAfter != nil {
    guard hostDropFlag else {
        fail("--host-drop-file/--host-drop-after are modifiers on --host-drop (no lane to inject into).")
    }
    guard cvcFileEnabled else {
        fail("--host-drop requires --cvc-file <share-dir> (the lanes are signed files in that share — ADR 0051 D1).")
    }
    if hostDropAfter != nil, hostDropFiles.isEmpty {
        fail("--host-drop-after requires --host-drop-file <path> (there is no drop to schedule).")
    }
    if !hostDropFiles.isEmpty, hostDropAfter == nil {
        // Default trigger, same shape as --host-clip-in: fire once the
        // seat has adopted the lane's epoch.
        hostDropAfter = "gotabwm: hostint armed"
    }
}
// M108d (#2328, ADR 0051 D6): notify-out is the same modifier shape — no
// display prerequisite (banners do not need the VM window).
if hostNotifyFlag {
    guard cvcFileEnabled else {
        fail("--host-notify requires --cvc-file <share-dir> (the lanes are signed files in that share — ADR 0051 D1).")
    }
}
// M127d (#2602, ADR 0051 V2-D5): the outbox lane is the same modifier
// shape — no display prerequisite (exports are not a window gesture).
if hostOutboxFlag || hostOutboxDir != nil {
    guard hostOutboxFlag else {
        fail("--host-outbox-dir is a modifier on --host-outbox (no lane to redirect).")
    }
    guard cvcFileEnabled else {
        fail("--host-outbox requires --cvc-file <share-dir> (the lanes are signed files in that share — ADR 0051 D1).")
    }
}
// Claim 9367: --pointer-virtio rides the four-queue device; the after-marker
// only makes sense with a sequence to schedule.
if pointerVirtioScript == nil, pointerVirtioAfter != nil {
    fail("--pointer-virtio-after requires --pointer-virtio (there is no sequence to schedule).")
}
// Claim 0680: snapshot requests ride the five-queue device and stream the
// composed scanout, which only exists when the GPU is attached.
if !snapshotAfterMarkers.isEmpty, screenshotPath == nil {
    fail("--snapshot-after requires --screen (the guest composites into the virtio-gpu scanout; without it there is no framebuffer to stream).")
}
if cvcConsoleFilePath != nil, !customVirtioEnabled {
    fail("--cvc-console-file requires the custom virtio device (queue 1 carries the structured console).")
}
// M102d3 (#2168): the opt-in render device and its SPIKE-only fault knob
// are validated BEFORE any device is configured — every refusal is named,
// never a silent fallback (the leaf also covers the ordinary-build case:
// the flag parses, then attachment refuses by name).
if let rejection = GPU3DRunnerConfiguration.rejection(for: gpu3dOptions) {
    fail("\(rejection)")
}
if let sharePath = virtioFSShareDir {
    let shareURL = URL(fileURLWithPath: sharePath, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: shareURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        fail("--virtio-fs requires an existing host directory, got '\(sharePath)'.")
    }
    let fileSystem = VZVirtioFileSystemDeviceConfiguration(tag: "virelaios")
    fileSystem.share = VZSingleDirectoryShare(
        directory: VZSharedDirectory(url: shareURL, readOnly: false)
    )
    config.directorySharingDevices = [fileSystem]
    print("VIRTIO-FS: ENABLED tag=virelaios share=\(shareURL.path) read-write")
}
// M115a (#2460): Apple's standard virtio-socket device — the candidate
// restore-safe guest↔host channel (the custom-virtio device is refused by
// validateSaveRestoreSupport; this probe measures whether the SDK's own
// vsock device is). Attached only under --vsock; the host listener on
// --vsock-port is armed on the live device after the VM object exists.
if vsockEnabled {
    config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    print("VSOCK: ENABLED host-listen-port=\(vsockPort)")
}
// Claim 0680: build the trigger list — one numbered raw file per
// --snapshot-after instance, in registration order.
do {
    let snapBase = snapshotOutBase ?? (screenshotPath.map { $0 + "-snap" } ?? "snapshot")
    for (i, marker) in snapshotAfterMarkers.enumerated() {
        snapshotTriggers.append(SnapshotTrigger(marker: marker, outPath: "\(snapBase)-\(i).raw"))
    }
}

if let netCapturePath {
    let netURL = URL(fileURLWithPath: netCapturePath)
    FileManager.default.createFile(atPath: netURL.path, contents: nil)
    guard let netCaptureFile = try? FileHandle(forWritingTo: netURL) else {
        fail("Could not open net capture file at '\(netCapturePath)'.")
    }
    netCaptureHandle = netCaptureFile
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
        fail("Could not create the net attachment datagram socketpair (errno \(errno)).")
    }
    netCaptureSocket = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
    netCaptureReadSocket = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
    // Reader thread: drain the runner's socket end into the capture file.
    // One datagram per read (SOCK_DGRAM); a 4096-byte buffer covers the
    // largest N1 frame (1514 B) with headroom.
    netCaptureThread = Thread {
        // Card N3 (claim 7293): the host-side ARP responder's fixed MAC —
        // the same locally-administered address as the guest's
        // fallback_mac, so the reply the guest learns is deterministic and
        // gate-assertable.
        let arpHostMAC: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x02]
        var buf = [UInt8](repeating: 0, count: 4096)
        while !netCaptureStop {
            let n = read(netCaptureReadSocket!.fileDescriptor, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            try? netCaptureFile.write(contentsOf: Data(bytes: buf, count: n))
            // Card N3: if the guest asked an ARP request, answer it from
            // the host. The reply is written into the runner's socket end
            // (fds[1]) — the card-N2 host→guest direction (VZ reads
            // fds[0]), so the guest receives it; the capture file above
            // keeps only guest TX (byte-exact, unchanged).
            if let hostIP = netArpRespondHostIP, isArpRequest(buf, n) {
                var reply = [UInt8](repeating: 0, count: 42)
                buildArpReply(&reply, buf, n, arpHostMAC, hostIP)
                try? netCaptureReadSocket?.write(contentsOf: Data(reply))
                print("NET-ARP: answered the guest's ARP request for \(buf[28]).\(buf[29]).\(buf[30]).\(buf[31]) with host MAC 02:00:00:00:00:02")
            }
            // Card N4: if the guest pinged our address, echo it back from
            // the host (same socket direction; the capture file above
            // keeps only guest TX, byte-exact, unchanged).
            if let hostIP = netIcmpRespondHostIP, isIcmpEchoRequest(buf, n, hostIP) {
                var reply = [UInt8](repeating: 0, count: n)
                buildIcmpEchoReply(&reply, buf, n, arpHostMAC, hostIP)
                try? netCaptureReadSocket?.write(contentsOf: Data(reply))
                print("NET-ICMP: answered the guest's echo request for \(hostIP[0]).\(hostIP[1]).\(hostIP[2]).\(hostIP[3]) (id \(reply[38] << 8 | reply[39]), seq \(reply[40] << 8 | reply[41]))")
            }
            // M117b (#2474, ADR 0057 D10): the three v6 responders — the
            // same request-driven shape as the N3 ARP responder. A guest
            // Router Solicitation is answered with the hermetic RA (src
            // the router link-local, dst all-nodes — the guest's D2
            // filter admits it); an NS for a listed target (explicit
            // --net-ndp-respond entries + the router link-local when
            // --net-ra-respond is set) is answered with the NA; an
            // ICMPv6 echo request for the listed address is answered
            // byte-exact. Unlisted targets and unset flags go
            // unanswered — the refusal leg.
            if let pfx = netRaRespondPrefix, isRouterSolicitation(buf, n) {
                var reply = [UInt8](repeating: 0, count: 102)
                buildRouterAdvertisement(&reply, arpHostMAC, pfx)
                try? netCaptureReadSocket?.write(contentsOf: Data(reply))
                print("NET-RA: answered the guest's router solicitation with an RA advertising \(v6Text(pfx))/64 from fe80::ff:fe00:2")
            }
            if isNeighborSolicitation(buf, n), let target = ndpRespondTarget(buf, n) {
                var reply = [UInt8](repeating: 0, count: 86)
                buildNeighborAdvertisement(&reply, buf, n, arpHostMAC, target)
                try? netCaptureReadSocket?.write(contentsOf: Data(reply))
                print("NET-NDP: answered the guest's neighbor solicitation for \(v6Text(target)) (NA S=1 O=1, host MAC 02:00:00:00:00:02)")
            }
            if let addr = netIcmp6RespondAddr, isIcmp6EchoRequest(buf, n, addr) {
                var reply = [UInt8](repeating: 0, count: n)
                buildIcmp6EchoReply(&reply, buf, n, arpHostMAC)
                try? netCaptureReadSocket?.write(contentsOf: Data(reply))
                print("NET-ICMP6: answered the guest's echo request for \(v6Text(addr)) (id \(reply[58] << 8 | reply[59]), seq \(reply[60] << 8 | reply[61]))")
            }
            // M117c (#2475, ADR 0057): the v6 transport responders — the
            // same request-driven shapes as N5/N10 on the fixed 40-byte
            // header (UDP at frame 54, TCP at frame 54). A listed
            // [addr]:port answers; anything else goes unanswered.
            if let addr = netUdp6RespondAddr, let port = netUdp6RespondPort,
               isUdp6Datagram(buf, n, addr, port) {
                var reply = [UInt8](repeating: 0, count: n)
                buildUdp6Reply(&reply, buf, n, arpHostMAC, addr, port)
                try? netCaptureReadSocket?.write(contentsOf: Data(reply))
                let srcPort = (UInt16(buf[54]) << 8) | UInt16(buf[55])
                print("NET-UDP6: answered the guest's datagram for [\(v6Text(addr))]:\(port) (reply to guest src port \(srcPort), \(n - 62) payload bytes)")
            }
            if let addr = netTcp6RespondAddr, let port = netTcp6RespondPort,
               isTcp6Segment(buf, n, addr, port) {
                let flags = tcp6Flags(buf)
                let seq = tcp6Seq(buf)
                var reply = [UInt8](repeating: 0, count: 4096)
                var payload = [UInt8]()
                let dataOff = 54 + max(5, Int(buf[66] >> 4)) * 4
                if n > dataOff { payload = [UInt8](buf[dataOff..<n]) }
                let isSyn = (flags & 0x02) != 0 && (flags & 0x10) == 0
                let isFin = (flags & 0x01) != 0
                let isRst = (flags & 0x04) != 0
                let connKey = netTcp6ConnKey([UInt8](buf[22..<38]), (UInt16(buf[54]) << 8) | UInt16(buf[55]))
                if isRst {
                    netTcp6SrvConn(for: buf).closed = true
                    print("NET-TCP6: observed the guest's RST (seq 0x\(hex32(seq)))")
                } else if isSyn {
                    if !netTcpSrvAdmit(connKey) {
                        let replyLen = buildTcp6Reply(&reply, buf, n, arpHostMAC, port, 0, seq &+ 1, 0x14, [])
                        try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                        print("NET-TCP6: refused the guest's SYN (seq 0x\(hex32(seq))); \(netTcpSrvConnLimit) connections already live")
                    } else {
                        let conn = NetTcpSrvConn()
                        netTcpSrvConns[connKey] = conn
                        let replyLen = buildTcp6Reply(&reply, buf, n, arpHostMAC, port, netTcpSrvIsn, seq &+ 1, 0x12, [])
                        try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                        print("NET-TCP6: answered the guest's SYN (seq 0x\(hex32(seq))) with a SYN-ACK (seq 0x\(hex32(netTcpSrvIsn)), ack 0x\(hex32(seq &+ 1)))")
                    }
                } else if isFin {
                    let conn = netTcp6SrvConn(for: buf)
                    let replyLen = buildTcp6Reply(&reply, buf, n, arpHostMAC, port, conn.srvNxt, seq &+ 1, 0x11, payload)
                    try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                    conn.closed = true
                    print("NET-TCP6: answered the guest's FIN (seq 0x\(hex32(seq))) with a FIN-ACK (seq 0x\(hex32(conn.srvNxt)), ack 0x\(hex32(seq &+ 1)))")
                } else if !payload.isEmpty {
                    let conn = netTcp6SrvConn(for: buf)
                    var responsePayload = payload
                    let isGet = payload.count >= 4 && payload[0] == 0x47 && payload[1] == 0x45 && payload[2] == 0x54 && payload[3] == 0x20
                    if port == 80 || port == 8080 || isGet {
                        let body = "Hello from VirelaiOS Host!\n"
                        let httpBody = "HTTP/1.0 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                        responsePayload = Array(httpBody.utf8)
                    }
                    let replyLen = buildTcp6Reply(&reply, buf, n, arpHostMAC, port, conn.srvNxt, seq &+ UInt32(payload.count), 0x10, responsePayload)
                    try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                    if isGet || port == 80 {
                        print("NET-TCP6: answered the guest's HTTP request with 200 OK (\(responsePayload.count) bytes)")
                    } else {
                        print("NET-TCP6: echoed the guest's \(payload.count)-byte data (ack 0x\(hex32(seq &+ UInt32(payload.count))), \(payload.count) payload bytes)")
                    }
                    conn.srvNxt = conn.srvNxt &+ UInt32(responsePayload.count)
                } else {
                    _ = netTcp6SrvConn(for: buf)
                    print("NET-TCP6: observed the guest's ACK (ack 0x\(hex32(tcp6Ack(buf))))")
                }
            }
            // Card N5: if the guest sent a UDP datagram to our ip:port,
            // echo it back from the host (same socket direction; the
            // capture file above keeps only guest TX, byte-exact,
            // unchanged).
            if let hostIP = netUdpRespondHostIP, let hostPort = netUdpRespondHostPort,
               isUdpDatagram(buf, n, hostIP, hostPort) {
                var reply = [UInt8](repeating: 0, count: n)
                buildUdpReply(&reply, buf, n, arpHostMAC, hostIP, hostPort)
                try? netCaptureReadSocket?.write(contentsOf: Data(reply))
                let srcPort = (UInt16(buf[34]) << 8) | UInt16(buf[35])
                print("NET-UDP: answered the guest's datagram for \(hostIP[0]).\(hostIP[1]).\(hostIP[2]).\(hostIP[3]):\(hostPort) (reply to guest src port \(srcPort), \(n - 42) payload bytes)")
            }
            // Card N2 (claim 7566): DNS responder; M99i (#2187) added the
            // answer-set/depth knobs and the hostile injects. The noise
            // datagrams go out BEFORE the real reply so the guest's
            // rejection path is what lets the good answer through.
            if let hostIP = netDnsRespondHostIP, isDnsQuery(buf, n, hostIP, netDnsRespondHostPort) {
                let qname = extractDnsQName(buf, n)
                let qtype = dnsQueryType(buf, n)
                let answers = dnsAnswersFor(qtype, qname)
                let srcPort = (UInt16(buf[34]) << 8) | UInt16(buf[35])
                if netDnsSpoof {
                    var forged = [UInt8](repeating: 0, count: 1518)
                    let flen = buildDnsReply(&forged, buf, n, arpHostMAC, hostIP, netDnsRespondHostPort,
                                             answers: answers, ttl: netDnsTTL, truncate: false,
                                             forgeSrcIP: [10, 0, 0, 9])
                    if flen > 0 {
                        try? netCaptureReadSocket?.write(contentsOf: Data(forged[0..<flen]))
                        print("NET-DNS: injected a reply forged from 10.0.0.9 for '\(qname)' (the guest must drop it)")
                    }
                }
                if netDnsWrongQuestion {
                    var wq = [UInt8](repeating: 0, count: 1518)
                    let wlen = buildDnsReply(&wq, buf, n, arpHostMAC, hostIP, netDnsRespondHostPort,
                                             answers: answers, ttl: netDnsTTL, truncate: false,
                                             corruptQuestion: true)
                    if wlen > 0 {
                        try? netCaptureReadSocket?.write(contentsOf: Data(wq[0..<wlen]))
                        print("NET-DNS: injected a corrupted-question reply for '\(qname)' (the guest must drop it)")
                    }
                }
                var reply = [UInt8](repeating: 0, count: 1518)
                let replyLen = buildDnsReply(&reply, buf, n, arpHostMAC, hostIP, netDnsRespondHostPort,
                                             answers: answers, ttl: netDnsTTL, truncate: netDnsTruncate)
                if replyLen > 0 {
                    try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                    if netDnsTruncate {
                        print("NET-DNS: answered the guest's DNS query for '\(qname)' qtype=\(qtype) with TC=1 ANCOUNT=0 (reply to guest src port \(srcPort); the guest must refuse truncation)")
                    } else {
                        print("NET-DNS: answered the guest's DNS query for '\(qname)' qtype=\(qtype) ancount=\(answers.count) ttl=\(netDnsTTL) (reply to guest src port \(srcPort))")
                    }
                }
            }
            // M83b (#1775): SNTP responder
            if let sntp = netSntpResponder, let answer = sntp.answer(buf, n) {
                try? netCaptureReadSocket?.write(contentsOf: Data(answer.frame))
                let originate = answer.originate.map { String(format: "%02x", $0) }.joined()
                print("NET-SNTP: answered \(answer.guestIP.map(String.init).joined(separator: ".")):\(answer.guestPort) served_unix=\(answer.servedUnix) skew=\(sntp.skew) originate=\(originate)")
            }
            // Card N8 (claim 0351): if the guest ran the DHCP client,
            // answer the handshake from the host — a tiny deterministic
            // DHCP server: DISCOVER (type 1) -> OFFER, REQUEST (type 3)
            // -> ACK, both with the FIXED gate-assertable lease (the
            // guest's xid echoed byte-exact, yiaddr = the lease IP, mask
            // 255.255.255.0, gateway 10.0.0.1, server id = the lease IP,
            // lease 3600). The reply goes broadcast (the client's flag)
            // so the guest's N2 MAC filter admits it.
            if let leaseIP = netDhcpRespondLeaseIP, isDhcpDatagram(buf, n),
               let mtype = dhcpMessageType(buf, n), mtype == 1 || mtype == 3 {
                // Audit follow-up 3 (issue #119): the refusal knobs. The
                // frame's dst MAC tells the REQUEST shape: the RENEWING
                // REQUEST is UNICAST to the server (02:00:00:00:00:02),
                // the INITIAL + REBINDING REQUESTs are BROADCAST. The
                // ciaddr (frame byte 54 = DHCP message byte 12) tells
                // INITIAL (0.0.0.0) from REBINDING (the lease). Refused
                // REQUESTs go unanswered — the guest's renewal stalls,
                // and with the autonomous idle-loop poll it escalates to
                // REBINDING at T2 / releases at expiry (the issue's
                // evidence).
                let dstBroadcast = buf[0] == 0xff && buf[1] == 0xff && buf[2] == 0xff &&
                                   buf[3] == 0xff && buf[4] == 0xff && buf[5] == 0xff
                let ciaddrSet = n > 58 && (buf[54] != 0 || buf[55] != 0 || buf[56] != 0 || buf[57] != 0)
                let refused = mtype == 3 && ((netDhcpRespondNoRenew && !dstBroadcast) ||
                                             (netDhcpRespondNoRebind && dstBroadcast && ciaddrSet))
                if refused {
                    print("NET-DHCP: refused the guest's \(!dstBroadcast ? "unicast RENEWING" : "broadcast REBINDING") REQUEST (xid 0x\(String(format: "%08x", (UInt32(buf[46]) << 24) | (UInt32(buf[47]) << 16) | (UInt32(buf[48]) << 8) | UInt32(buf[49])))) — the client must advance on its own")
                } else {
                var reply = [UInt8](repeating: 0, count: 4096)
                let replyLen = buildDhcpReply(&reply, buf, n, arpHostMAC, leaseIP, netDhcpRespondLeaseSecs, mtype)
                try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                // The xid hex built manually (Swift's String(format:) vararg
                // bridge mismatches %x with UInt8/UInt32 — the same reason
                // the N5 responder prints ports as arithmetic).
                let hexT = Array("0123456789abcdef")
                let xidHex = [hexT[Int(buf[46] >> 4)], hexT[Int(buf[46] & 0xf)],
                              hexT[Int(buf[47] >> 4)], hexT[Int(buf[47] & 0xf)],
                              hexT[Int(buf[48] >> 4)], hexT[Int(buf[48] & 0xf)],
                              hexT[Int(buf[49] >> 4)], hexT[Int(buf[49] & 0xf)]]
                print("NET-DHCP: answered the guest's DHCP \(mtype == 1 ? "DISCOVER" : "REQUEST") (xid 0x\(String(xidHex))) with a \(mtype == 1 ? "OFFER" : "ACK") for \(leaseIP[0]).\(leaseIP[1]).\(leaseIP[2]).\(leaseIP[3]) (lease \(netDhcpRespondLeaseSecs)s)")
                }
            }
            // Card N10 (claim 7026): if the guest's bounded TCP client
            // connected to our ip:port, answer the handshake + echo from
            // the host — a tiny deterministic TCP server: SYN -> SYN-ACK
            // (the FIXED gate-assertable server ISN, ack = the guest's
            // ISN+1), the handshake ACK -> observed, a data segment ->
            // ACK + the payload ECHOED byte-exact, FIN -> FIN-ACK, the
            // final ACK -> observed. The reply is a fresh frame in the
            // same socket direction as the other responders.
            if let hostIP = netTcpRespondHostIP, let hostPort = netTcpRespondHostPort,
               isTcpSegment(buf, n, hostIP, hostPort) {
                let flags = tcpFlags(buf)
                let seq = tcpSeq(buf)
                let ack = tcpAck(buf)
                var reply = [UInt8](repeating: 0, count: 4096)
                var payload = [UInt8]()
                // M99h (#2186): the payload starts at the segment's data
                // offset, not byte 54 — a guest SYN carrying its MSS
                // option must not be echoed as "payload" in the SYN-ACK.
                let dataOff = 34 + max(5, Int(buf[46] >> 4)) * 4
                if n > dataOff { payload = [UInt8](buf[dataOff..<n]) }
                let isSyn = (flags & 0x02) != 0 && (flags & 0x10) == 0
                let isFin = (flags & 0x01) != 0
                let isRst = (flags & 0x04) != 0
                // M99f (#2184): the per-connection peer, keyed by the
                // guest's src IP:port — several guest connections are
                // answered concurrently; a SYN on a live key restarts
                // only that connection.
                let connKey = netTcpConnKey([UInt8](buf[26..<30]), (UInt16(buf[34]) << 8) | UInt16(buf[35]))
                if isRst {
                    // The guest aborted — the connection is dead; observe.
                    let conn = netTcpSrvConn(for: buf)
                    conn.closed = true
                    if netTcpRespondRelayMode {
                        conn.relay.shutdown(suppressFin: true)
                        print("NET-TCP-RELAY: observed the guest's RST (seq 0x\(hex32(seq))); upstream closed")
                    } else if netTcpRespondSSHMode {
                        print("NET-TCP-SSH: observed the guest's RST (seq 0x\(hex32(seq)))")
                    } else {
                        print("NET-TCP: observed the guest's RST (seq 0x\(hex32(seq)))")
                    }
                } else if isSyn {
                    if !netTcpSrvAdmit(connKey) {
                        // The bounded server table is full — the honest
                        // refusal, the same one the guest's table sends.
                        let replyLen = buildTcpReply(&reply, buf, n, arpHostMAC, hostPort, 0, seq &+ 1, 0x14, [])
                        try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                        print("NET-TCP: refused the guest's SYN (seq 0x\(hex32(seq))); \(netTcpSrvConnLimit) connections already live")
                    } else {
                    let conn = NetTcpSrvConn()
                    if let old = netTcpSrvConns[connKey] { old.relay.shutdown(suppressFin: true) }
                    netTcpSrvConns[connKey] = conn
                    if netTcpRespondRelayMode, netTcpRespondRelayPort != nil {
                        // M51 interop (#1209): a fresh connection dials the
                        // real upstream NOW — real sshd sends its banner
                        // before the guest's version line, so the first
                        // paced chunk is already buffered.
                        print("NET-TCP-RELAY: connection accepted (guest SYN seq 0x\(hex32(seq))); dialing upstream \(netTcpRespondRelayHost):\(netTcpRespondRelayPort!)")
                        conn.relay.hostMAC = arpHostMAC
                        conn.relay.hostPort = hostPort
                        conn.relay.serverIsn = netTcpSrvIsn
                        conn.relay.onFrame = { frame in
                            try? netCaptureReadSocket?.write(contentsOf: Data(frame))
                        }
                        conn.relay.begin(synFrame: buf, n)
                        conn.relay.start(netTcpRespondRelayHost, netTcpRespondRelayPort!)
                    } else if netTcpRespondSSHMode {
                        // M51 SSH5 (#1172): a fresh connection gets a fresh
                        // server state machine and an empty paced TX stream.
                        let cfg = SSHServer.Config(
                            hostKeySeed: netTcpRespondSSHHostKey,
                            acceptedUserKey: netTcpRespondSSHUserKey,
                            marker: netTcpRespondSSHMarker,
                            exitStatus: netTcpRespondSSHExitStatus,
                            tamperFirstServerTag: netTcpRespondSSHTamperMAC
                        )
                        let server = SSHServer(config: cfg)
                        server.logSink = { line in print("SSH-SRV: \(line)") }
                        conn.sshServer = server
                        print("NET-TCP-SSH: connection accepted (guest SYN seq 0x\(hex32(seq))); awaiting the version exchange")
                    }
                    let synAckOpts: [UInt8] = netTcpRespondOptionsMode ? netTcpOptionsSynAck : []
                    let replyLen = buildTcpReply(&reply, buf, n, arpHostMAC, hostPort, netTcpSrvIsn, seq &+ 1, 0x12, payload, options: synAckOpts)
                    try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                    print("NET-TCP: answered the guest's SYN (seq 0x\(hex32(seq))) with a SYN-ACK (seq 0x\(hex32(netTcpSrvIsn)), ack 0x\(hex32(seq &+ 1))\(netTcpRespondOptionsMode ? ", options mss/sackp/ws/ts" : ""))")
                    }
                } else if isFin {
                    let conn = netTcpSrvConn(for: buf)
                    if netTcpRespondHandshakeOnly {
                        // Card N11 (claim 5357): the handshake-only mode
                        // goes SILENT on data/FIN — the deterministic
                        // black hole that forces the guest's bounded
                        // retransmission machinery to fire.
                        print("NET-TCP: handshake-only — ignoring the guest's FIN (black hole)")
                    } else {
                        let finOpts: [UInt8] = netTcpRespondOptionsMode ? netTcpOptionsData : []
                        // #2349: in relay mode the connection's send-next
                        // lives on the relay (it advances as chunks pump);
                        // the conn's own srvNxt never moved.
                        let finSeq = netTcpRespondRelayMode ? conn.relay.currentSeqAck().seq : conn.srvNxt
                        let replyLen = buildTcpReply(&reply, buf, n, arpHostMAC, hostPort, finSeq, seq &+ 1, 0x11, payload, options: finOpts)
                        try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                        conn.closed = true
                        if netTcpRespondRelayMode {
                            conn.relay.shutdown(suppressFin: true)
                            print("NET-TCP-RELAY: the guest sent FIN; FIN-ACK and upstream close")
                        } else if netTcpRespondSSHMode {
                            print("NET-TCP-SSH: the guest sent FIN; FIN-ACK and close (SSH session done)")
                        } else {
                            print("NET-TCP: answered the guest's FIN (seq 0x\(hex32(seq))) with a FIN-ACK (seq 0x\(hex32(finSeq)), ack 0x\(hex32(seq &+ 1)))")
                        }
                    }
                } else if !payload.isEmpty {
                    let conn = netTcpSrvConn(for: buf)
                    // A data segment: the SSH responder's byte stream, the
                    // paced packet stream, or the HTTP/echo response.
                    if netTcpRespondRelayMode {
                        // M51 interop (#1209) + #2349: dedup the segment's
                        // payload against the in-order bound (retransmits
                        // write nothing upstream a second time), then pump
                        // as much real-server data as the guest's window
                        // holds — not one chunk per ACK. A dead relay is an
                        // RST, not a silent sink. No blocking wait: the
                        // guest waits on a bounded read and the upstream
                        // reader pumps asynchronously.
                        if conn.relay.guestDataSegment(buf, n) == .dead {
                            conn.closed = true
                        }
                        if !conn.closed && !conn.relay.pump() {
                            // Not established upstream bytes yet (or the
                            // guest's window is full): ACK the guest's
                            // data bare — at the in-order bound, so a
                            // dropped/ahead segment is NOT covered.
                            let sa = conn.relay.currentSeqAck()
                            let replyLen = buildTcpReply(&reply, buf, n, arpHostMAC, hostPort, sa.seq, sa.ack, 0x10, [])
                            try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                        }
                    } else if netTcpRespondSSHMode {
                        // M51 SSH5 (#1172): feed the SSH server with the
                        // guest's bytes and pace the next ≤192-byte chunk of
                        // its output with this ACK; when nothing is pending
                        // the ACK goes out bare.
                        if let server = conn.sshServer {
                            conn.sshTx.append(contentsOf: server.feed(payload))
                        }
                        if !netTcpRespondSSHSendChunk(conn, &reply, buf, n, arpHostMAC, hostPort, seq, payload.count) {
                            let replyLen = buildTcpReply(&reply, buf, n, arpHostMAC, hostPort, conn.srvNxt, seq &+ UInt32(payload.count), 0x10, [])
                            try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                        }
                    } else if netTcpRespondPacketMode {
                        // M51 SSH1 (#1168): a trigger/keepalive — ACK it bare
                        // and pace the next chunk; never echo (the payload is
                        // the SSH packet stream, not an echo surface).
                        if !netTcpSendPacketChunk(conn, &reply, buf, n, arpHostMAC, hostPort, seq, payload.count) {
                            let replyLen = buildTcpReply(&reply, buf, n, arpHostMAC, hostPort, conn.srvNxt, seq &+ UInt32(payload.count), 0x10, [])
                            try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                        }
                    } else if netTcpRespondHandshakeOnly {
                        print("NET-TCP: handshake-only — ignoring the guest's \(payload.count)-byte data (black hole)")
                    } else {
                        var responsePayload = payload
                        let isGet = payload.count >= 4 && payload[0] == 0x47 && payload[1] == 0x45 && payload[2] == 0x54 && payload[3] == 0x20
                        if hostPort == 80 || hostPort == 8080 || isGet {
                            let body = "Hello from VirelaiOS Host!\n"
                            let httpBody = "HTTP/1.0 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                            responsePayload = Array(httpBody.utf8)
                        }
                        let dataOpts: [UInt8] = netTcpRespondOptionsMode ? netTcpOptionsData : []
                        let replyLen = buildTcpReply(&reply, buf, n, arpHostMAC, hostPort, conn.srvNxt, seq &+ UInt32(payload.count), 0x10, responsePayload, options: dataOpts)
                        try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                        if isGet || hostPort == 80 {
                            print("NET-TCP: answered the guest's HTTP request with 200 OK (\(responsePayload.count) bytes)")
                        } else {
                            print("NET-TCP: echoed the guest's \(payload.count)-byte data (ack 0x\(hex32(seq &+ UInt32(payload.count))), \(payload.count) payload bytes)")
                        }
                        conn.srvNxt = conn.srvNxt &+ UInt32(responsePayload.count)
                    }
                } else {
                    let conn = netTcpSrvConn(for: buf)
                    // A pure ACK (the handshake / the echo / the final ACK).
                    // M51 SSH1 (#1168): in packet mode the handshake ACK (and
                    // every later ACK for a delivered chunk) paces out the
                    // next chunk; M51 SSH5 (#1172): the same pacing feeds the
                    // encrypted SSH byte stream. Otherwise it is observed.
                    if netTcpRespondRelayMode {
                        // #2349: the ack/window pair is adopted only when
                        // it does not retreat — a retransmitted segment's
                        // stale snapshot can no longer stall the pump.
                        if conn.relay.guestAckSegment(buf, n) {
                            conn.closed = true // stalled past the bound; RST sent
                        } else if !conn.relay.pump() {
                            print("NET-TCP-RELAY: observed the guest's ACK (ack 0x\(hex32(ack)))")
                        }
                    } else if netTcpRespondSSHMode {
                        if !netTcpRespondSSHSendChunk(conn, &reply, buf, n, arpHostMAC, hostPort, seq, 0) {
                            print("NET-TCP-SSH: observed the guest's ACK (ack 0x\(hex32(ack)))")
                        }
                    } else if !netTcpSendPacketChunk(conn, &reply, buf, n, arpHostMAC, hostPort, seq, 0) {
                        print("NET-TCP: observed the guest's ACK (ack 0x\(hex32(ack)))")
                    }
                }
            }
            nativeSocketProbe?.receive(buf, n)
            // M99f (#2184): every host-initiated client is an independent
            // state machine — the intruder receipt and the main dispatch
            // are keyed by each client's own 5-tuple.
            for client in netTcpClients {
                if client.intruderSent, !client.intruderAnswered,
                   isTcpSegmentFromGuest(buf, n, client.guestIP, client.guestPort, client.cliPort &+ 1) {
                    client.intruderAnswered = true
                    let flags = tcpFlags(buf)
                    let verdict = (flags & 0x04) != 0 ? "refused (RST)" : ((flags & 0x12) == 0x12 ? "ADMITTED (SYN-ACK)" : "answered")
                    print("NET-TCP-INTRUDER: the guest \(verdict) flags=0x\(String(flags, radix: 16))")
                }
                // SH7 (#1083, ADR 0020 Amendment B): the host-initiated
                // inbound TCP client. Match the guest server's segments
                // (src = the guest listener) and drive the handshake /
                // data / close for THIS client only.
                if isTcpSegmentFromGuest(buf, n, client.guestIP, client.guestPort, client.cliPort) {
                    client.drive(buf, n)
                }
            }
        }
        try? netCaptureFile.synchronize()
        netCaptureDone.signal()
    }
    netCaptureThread?.start()
    let netAttachment = VZFileHandleNetworkDeviceAttachment(fileHandle: netCaptureSocket!)
    let netConfig = VZVirtioNetworkDeviceConfiguration()
    netConfig.attachment = netAttachment
    guard let fixedMAC = VZMACAddress(string: "02:00:00:00:00:01") else {
        fail("Could not parse the fixed net MAC address.")
    }
    netConfig.macAddress = fixedMAC
    config.networkDevices = [netConfig]
} else if netNatEnabled {
    // Milestone five card N7 (claim 4678): the NAT attachment — the host
    // serves as the guest's router and performs NAT for accesses to
    // outside networks. The device config carries the SAME fixed
    // locally-administered MAC as the file-handle path; what the guest's
    // VIRTIO_NET_F_MAC read actually observes under NAT is a claim-time
    // observation (the NAT gateway may honor or override it — pinned in
    // the hardware contract, never assumed). No capture file: the host
    // translates the frames, so there are no guest TX bytes to capture.
    let natAttachment = VZNATNetworkDeviceAttachment()
    let natConfig = VZVirtioNetworkDeviceConfiguration()
    natConfig.attachment = natAttachment
    guard let fixedMAC = VZMACAddress(string: "02:00:00:00:00:01") else {
        fail("Could not parse the fixed net MAC address.")
    }
    natConfig.macAddress = fixedMAC
    config.networkDevices = [natConfig]
} else if let bridgedIface = netBridgedIface {
    // M117d (issue #2476, ADR 0057 D11): the bridged attachment — the
    // guest shares the host's physical interface and sits on the real
    // LAN with the SAME fixed locally-administered MAC the other
    // attachments pin (the iface and the com.apple.vm.networking
    // entitlement were both checked by name during flag validation).
    let bridgedAttachment = VZBridgedNetworkDeviceAttachment(interface: bridgedIface)
    let bridgedConfig = VZVirtioNetworkDeviceConfiguration()
    bridgedConfig.attachment = bridgedAttachment
    guard let fixedMAC = VZMACAddress(string: "02:00:00:00:00:01") else {
        fail("Could not parse the fixed net MAC address.")
    }
    bridgedConfig.macAddress = fixedMAC
    config.networkDevices = [bridgedConfig]
} else if netVmnetEnabled {
    // M117d (issue #2476, ADR 0057 D11): the vmnet attachment — the
    // shared-mode logical network was created up front (flag validation
    // fails carrying the vmnet_return_t on a non-success, so reaching
    // here means the network exists).
#if canImport(vmnet)
    let vmnetAttachment = VZVmnetNetworkDeviceAttachment(network: netVmnetNetwork!)
    let vmnetNetConfig = VZVirtioNetworkDeviceConfiguration()
    vmnetNetConfig.attachment = vmnetAttachment
    guard let fixedMAC = VZMACAddress(string: "02:00:00:00:00:01") else {
        fail("Could not parse the fixed net MAC address.")
    }
    vmnetNetConfig.macAddress = fixedMAC
    config.networkDevices = [vmnetNetConfig]
#endif
} else {
    config.networkDevices = []
}
// Milestone fifteen card A1 (claim 6140): the virtio-snd device, attached
// only under `--sound`. One output stream with a host audio sink — the
// device the guest discovers (DID observed, not assumed: the 0x1040+type
// scheme predicts 0x1059). Without the flag the config is exactly as
// before: soundDevices = [] — every existing gate stays byte-identical.
if soundMode {
    let sound = VZVirtioSoundDeviceConfiguration()
    let output = VZVirtioSoundDeviceOutputStreamConfiguration()
    output.sink = VZHostAudioOutputStreamSink()
    sound.streams = [output]
    config.audioDevices = [sound]
    print("SOUND: virtio-snd attached (1 output stream, host sink)")
} else {
    config.audioDevices = []
}
#if SPIKE
if customVirtioEnabled, #available(macOS 27.0, *) {
    // The runtime guard above already requires macOS 27+; the availability
    // check exists only because the manifest floor (.v26, for the CI
    // toolchain) is below the custom-virtio APIs' 27.0 introduction. The
    // whole spike is additionally gated behind the SPIKE define: the CI
    // toolchain's SDK (macOS 26) does not declare the custom-virtio types
    // at all, so the base `swift build` must not reference them.
    print(CustomVirtioSpike.attach(to: config))
}
#else
if customVirtioEnabled {
    // Loud, never silent (issue #523 acceptance): this binary was compiled
    // WITHOUT -DSPIKE, so it has no custom-virtio code at all. Ignoring
    // the flag would boot a different machine than the caller asked for.
    fail("--custom-virtio/--cvc-echo/--via-virtio/--cvc-snap/--cvc-console-file/--snapshot-after require a SPIKE build (macOS 27 SDK types); rebuild with `swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE` (`zig build spike-virtio` drives it). This binary cannot attach the requested device.")
}
#endif
// M102d3 (#2168): the opt-in private render device, attached AFTER the
// existing custom-virtio attach — the leaf's attach() APPENDS to
// config.customVirtioDevices, so the 0x42 channel, the native 2D GPU and
// every other device array stay untouched. Assemble builds c2's real
// Metal backend first: a Metal init failure is a named stop here, never
// a fallback. If VZ later refuses the configuration, config.validate()
// below reports its exact error — do not substitute another device.
// gpu3dCountersReport stays nil without the flag (and on every non-SPIKE
// binary), so teardown reporting is compiled in everywhere but fires
// only when the device was actually attached.
var gpu3dCountersReport: (() -> String)?
#if SPIKE
// Held for the VM's lifetime: VZ holds the provider's delegates weakly,
// so dropping the attachment would make the device go deaf (the same
// retention discipline as CustomVirtioSpike's static delegates).
@available(macOS 27.0, *)
enum GPU3DRunnerRetain {
    static var attachment: GPU3DRunnerAttachment?
}
if gpu3dOptions.metal, #available(macOS 27.0, *) {
    switch GPU3DRunnerAttachment.assemble(options: gpu3dOptions) {
    case .failure(let why):
        fail("\(why)")
    case .success(let attachment):
        GPU3DRunnerRetain.attachment = attachment
        attachment.attach(to: config)
        gpu3dCountersReport = { attachment.counters() }
        print("  \(attachment.banner())")
    }
}
#endif
do { try config.validate() } catch { fail("Invalid VM configuration: \(error)") }
if vzRestore {
#if arch(arm64)
    // M70g G3 (#1459): name the attached extras so a verdict line is
    // self-describing when it lands in docs/hardware-contract.md. #2261:
    // each entry carries whether it is a VZ custom-virtio device — those
    // are the observed-unsaveable ones, and the refusal names them.
    var vzRestoreExtras: [(name: String, customVirtio: Bool)] = []
    if displayMode { vzRestoreExtras.append(("virtio-gpu", customVirtio: false)) }
    if inputMode { vzRestoreExtras.append(("usb-hid(xhci)", customVirtio: false)) }
    if usbMsdPath != nil { vzRestoreExtras.append(("usb-msd(xhci)", customVirtio: false)) }
    if customVirtioEnabled { vzRestoreExtras.append(("custom-virtio", customVirtio: true)) }
    if gpu3dOptions.metal { vzRestoreExtras.append(("gpu3d-metal", customVirtio: true)) }
    if virtioFSShareDir != nil { vzRestoreExtras.append(("virtio-fs", customVirtio: false)) }
    if vsockEnabled { vzRestoreExtras.append(("vsock", customVirtio: false)) }
    let vzRestoreDevices = vzRestoreExtras.isEmpty ? "headless-base" : vzRestoreExtras.map(\.name).joined(separator: ",")
    print("VZ-RESTORE: devices=\(vzRestoreDevices) mode=\(vzRestoreLoadDir != nil ? "load" : vzRestoreSaveDir != nil ? "save" : "same-process")")
    if vzWarmLeg {
        print("VZ-RESTORE: warm leg — restore → D5 handshake → scripted run; a restore refusal exits \(vzRestoreRefusedStatus) with one stdout line (ADR 0059 D8)")
    }
    do {
        try config.validateSaveRestoreSupport()
        print("VZ-RESTORE: validateSaveRestoreSupport passed; \(ProcessInfo.processInfo.operatingSystemVersionString), arm64")
    } catch {
        print("VZ-RESTORE: validateSaveRestoreSupport REFUSED devices=\(vzRestoreDevices) error=\(error as NSError)")
        // VZ cannot serialize custom-virtio device state and offers no
        // detach/quiesce API, so a configuration carrying one is refused
        // wholesale: name the blocking attachment(s), not just the list.
        let blocking = vzRestoreExtras.filter(\.customVirtio).map(\.name)
        fail("--vz-restore validateSaveRestoreSupport failed: \(error as NSError). No snapshot or reboot fallback. Blocking device(s): \(blocking.isEmpty ? vzRestoreDevices : blocking.joined(separator: ",")).")
    }
#else
    fail("--vz-restore requires arm64 save/restore APIs.")
#endif
}

final class Runner: NSObject {
    let vm: VZVirtualMachine
    let queue = DispatchQueue(label: "virelaios.vm")
    init(configuration: VZVirtualMachineConfiguration) {
        vm = VZVirtualMachine(configuration: configuration, queue: queue)
        super.init()
    }
}

// ---------------------------------------------------------------------------
// VM stop reasons (claim #1278, the unblock for #1261).
//
// VZVirtualMachineDelegate exists precisely to carry the reason a VM stopped,
// and its own header says so (VZVirtualMachine.h: "For error cases, use the
// `state` property and information passed through the VZVirtualMachineDelegate
// to inspect the virtual machine's current state"). This binary set no
// delegate, so that information was discarded and a dying boot could only ever
// be reported as the bare state rawValue — which is why #1261 spent a whole
// investigation looking at `state=3` with no reason attached.
//
// Every member of the protocol is `@optional`, which makes a wrong signature
// compile silently and simply never be called. Both names below are therefore
// witnessed, not guessed: `#selector(VZVirtualMachineDelegate.guestDidStop(_:))`
// and `#selector(VZVirtualMachineDelegate.virtualMachine(_:didStopWithError:))`
// each resolve, which a wrong spelling could not.
//
// This class is only the VZ selector surface: the recording rules (what an
// error line looks like, and that an error outranks a racing clean stop) live in
// the VMPostmortem module, where `swift test` pins them without a VM.
final class VMRunnerDelegate: NSObject, VZVirtualMachineDelegate {
    let stopReasons = StopReasonRecorder()

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        stopReasons.recordGuestPoweredOff()
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        stopReasons.recordError(error)
    }

    /// The ` reason=…` suffix for a verdict line (never empty: a VM that stopped
    /// without VZ narrating it says so).
    func verdict() -> String { stopReasons.verdictSuffix() }
}

// M115a (#2460): the host-side accept half of the vsock probe. VZ calls the
// delegate on the VM's queue whenever the guest issues a connect to the
// listened port; each accepted connection is retained because the SDK
// documents that an accepted connection's fd dies with the object.
final class VsockListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    private var connections: [VZVirtioSocketConnection] = []

    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        connections.append(connection)
        print("VSOCK: listener accepted guest connect dport=\(connection.destinationPort) sport=\(connection.sourcePort) n=\(connections.count)")
        return true
    }
}

// Held strongly: `VZVirtioSocketListener.delegate` is weak, and the listener
// itself must outlive the VM's socket device for connects to keep landing.
let vsockListenerDelegate = VsockListenerDelegate()
let vsockListener = VZVirtioSocketListener()
// M115b (#2461): the ctl listener + its credential-bearing delegate are
// created at arm time (the key only exists once the share dir is known).
var vsockCtlDelegate: VSockCtlListenerDelegate?
let vsockCtlListener = VZVirtioSocketListener()

// Held strongly: `VZVirtualMachine.delegate` is a weak property, so a
// temporary would be deallocated immediately and never called.
let vmDelegate = VMRunnerDelegate()

let runner = Runner(configuration: config)
runner.vm.delegate = vmDelegate
if hostSessionMode {
    // M139a (#2779): the menu bar's verbs route through the session
    // router — one process-global bar acts on the key window's bus once
    // a second window exists.
    hostApplication = HostApplication(serialLog: serialLogPath, inspector: inspector,
                                      menuTarget: VMSessionRegistry.shared.router)
    hostApplication?.onStop = { reason, code in stopHostSession(reason, code: code) }
}
// M114a (#2454): the bus every UI action dispatches through — the session
// window's own instance when it exists, a windowless one otherwise, so
// --host-cmd-after dispatches verbs down the identical seam the menus use.
let commandBus = hostApplication?.commandBus ?? HostCommandBus()
// M139a (#2779): the straight-line boot IS session 1 — adopted here so
// the registry's dedup (`profile_in_use`), the `vm=1` receipts and the
// fleet drain at exit cover it exactly like a `new-window` session.
let primarySession = VMSessionRegistry.shared.adoptPrimary(
    commandBus: commandBus, runner: runner, delegate: vmDelegate,
    serialURL: serialURL, profile: activeProfile)
primarySession.hostApp = hostApplication
primarySession.window = hostApplication?.window
// M128c (#2607): a document-launched session carries no `--profile` in
// argv — the models' argv resolution would leave them unarmed. Arm them
// on the clicked bundle so ⌘, and the Machine-menu verbs act on the
// machine that is actually running.
if let documentProfileURL {
    commandBus.settings.profileURL = documentProfileURL
    commandBus.profiles.profileURL = documentProfileURL
    commandBus.machine.profileURL = documentProfileURL
    // M120e (#2562): captures route into the clicked bundle's share/ too.
    commandBus.captures.profileURL = documentProfileURL
}
// M120c (#2560): the Machine-menu persistence verbs. The model resolves
// the profile/share/base/key from argv itself; the pieces only the
// runner owns are the VZ drivers and the live posture reads — the same
// SuspendCtl/SnapshotCtl pair the vsock-ctl wire serves, armed here for
// EVERY run so a scripted --host-cmd-after dispatches the identical
// seam the session menu does. The suspend driver's accept tail stops
// the run exactly like the guest-initiated suspend; the snapshot
// driver's resume-after-reply is a no-op on a refused save.
var machineSaveUnsupported: String? = nil
do { try config.validateSaveRestoreSupport() } catch {
    machineSaveUnsupported = "\(error as NSError)"
}
let machineSuspendCtl = SuspendCtl(vm: runner.vm, queue: runner.queue,
                                 savedStateDir: activeProfile?.savedStateURL,
                                 unsupported: machineSaveUnsupported)
let machineSnapshotCtl = SnapshotCtl(
    vm: runner.vm, queue: runner.queue,
    shareDir: (cvcFileShareDir ?? virtioFSShareDir)
        .map { URL(fileURLWithPath: $0, isDirectory: true) },
    unsupported: machineSaveUnsupported)
commandBus.machine.saveCapable = { machineSaveUnsupported == nil }
commandBus.machine.vmRunning = { [vm = runner.vm] in vm.state == .running }
commandBus.machine.suspendDriver = {
    let verdict = machineSuspendCtl.begin()
    guard verdict.accepted else { return verdict.code }
    machineSuspendCtl.finish()
    return nil
}
commandBus.machine.snapshotDriver = { name in
    let verdict = machineSnapshotCtl.save(name: name)
    machineSnapshotCtl.resumeAfterReply()
    return verdict.accepted ? nil : verdict.code
}
// The verbs the runner performs itself: the framebuffer capture the
// --screen/--screenshot-after path already owns (enabled once the display
// view exists), and a headless stop/quit for runs with no session window
// (in --host-session those verbs come from HostApplication's own
// registration instead).
if screenshotPath != nil || displayMode {
    var hostUIShotCount = 0
    commandBus.register(.screenshot, HostCommandBus.Registration(
        isEnabled: { machineView != nil },
        receiptDetail: { commandBus.captures.receiptDetail }
    ) {
        hostUIShotCount += 1
        let path = screenshotPathForCapture("hostui-\(hostUIShotCount)")
        writeScreenshot(to: path)
        guard FileManager.default.fileExists(atPath: path) else { return .failed }
        // M120e (#2562): a landed capture arms the saved badge + counter —
        // the receipt's file= is the name the badge shows.
        commandBus.captures.noteSaved(URL(fileURLWithPath: path))
        return .performed
    })
}
// M114b (#2455): the headless viewport verbs — the same two the session
// window registers on its own bus instance in HostApplication, here bound
// to the scripted run's evidence window + machine view so --host-cmd-after
// exercises the identical seam. (In --host-session HostApplication's own
// registrations stand; the runner never overwrites them.)
if !hostSessionMode, screenshotPath != nil || displayMode {
    commandBus.register(.fullscreen, HostCommandBus.Registration(
        isEnabled: { machineWindow?.isVisible ?? false },
        itemState: { machineWindow?.styleMask.contains(.fullScreen) ?? false }
    ) {
        machineWindow?.toggleFullScreen(nil)
        return .performed
    })
    commandBus.register(.captureKeys, HostCommandBus.Registration(
        isEnabled: { machineView != nil },
        itemState: { machineView?.capturesSystemKeys ?? false },
        receiptDetail: {
            guard let view = machineView else { return nil }
            return "capture=\(view.capturesSystemKeys ? "on" : "off")"
        }
    ) {
        guard let view = machineView else { return .failed }
        view.capturesSystemKeys.toggle()
        return .performed
    })
}
if !hostSessionMode {
    let headlessStop = HostCommandBus.Registration(isEnabled: { runner.vm.state == .running }) {
        runner.queue.async { runner.vm.stop { _ in } }
        return .performed
    }
    commandBus.register(.stop, headlessStop)
    commandBus.register(.quit, headlessStop)
}
// M114d (#2457): the inspector drawer verbs. The model's serialSink is
// the console pipe's write end wherever a guest RX path exists (the
// --script/--console duplex attachment, --vz-restore's probe input, or
// --host-session's read end) — without one the verb receipts `disabled`
// instead of writing into a pipe nobody reads. `send-serial` is the
// same registration in every mode, like screenshot: the drawer's Send
// and --host-cmd-after dispatch it identically.
if consoleMode || scriptMode || hostSessionMode || vzRestore {
    inspector.serialSink = { line in
        do {
            try consoleInputPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
            return true
        } catch {
            return false
        }
    }
}
commandBus.register(.sendSerial, HostCommandBus.Registration(
    isEnabled: { inspector.serialSink != nil },
    receiptDetail: { "sent=\(inspector.sentCount)" }
) {
    inspector.inject() ? .performed : .failed
})
if !hostSessionMode {
    // Headless: no split pane exists, but the toggle is still honest —
    // isOpen is model state a receipt reports (the session window
    // registers its own pane-sliding variant in HostApplication).
    commandBus.register(.inspector, HostCommandBus.Registration(
        itemState: { inspector.isOpen },
        receiptDetail: { inspector.receiptDetail }
    ) {
        inspector.isOpen.toggle()
        return .performed
    })
}
// Set when vm.start completes successfully; consolePoll only treats a
// .stopped/.error state as "session over" after the VM has actually started
// (a fresh VZVirtualMachine is .stopped until boot begins).
var vmDidStart = false
let startTime = Date()
let deadline = startTime.addingTimeInterval(timeout)
let consoleStart = Date()
let consoleDeadline = consoleStart.addingTimeInterval(consoleTimeout)
var lastText = ""
var screenshotSaved = false
var serialMatched = false
var terminalMatched = terminalMarker == nil
var evidenceSince: Date?
let terminalDwell: TimeInterval = 2

print("VIRELAIOS VM runner")
print("  host: arm64 (Apple silicon), macOS \(osVersion.majorVersion).\(osVersion.minorVersion)")
print("  disk: \(overlayBasePath ?? diskImagePath)")
print("  memory: \(memoryMiB) MiB, cpus: \(cpuCount)")
if let p = activeProfile {
    print("  profile: \(p.url.path) identity=\(p.identity) (\(p.created ? "created" : "loaded"))")
}
if consoleMode {
    print("  mode: interactive console")
    print("  serial log: \(serialLogPath)  (guest output teed to terminal + log)")
    print("  interactive input: enabled — stdin → serial attachment (fileHandleForReading non-nil)")
    if let port = consoleTCPPort {
        let auth = consoleTCPSecret != nil
            ? ", HMAC-SHA256 challenge-response required (secret from \(consoleTCPSecretFromFile != nil ? "file" : "argv"))"
            : ""
        print("  console-tcp: \(consoleTCPBind):\(port) — remote console bridge (plaintext; #1066 Stage 0\(auth); one client at a time, extra clients told busy)")
    }
    print("  NOTE: guest RX is the polled virtio receive queue (claim 6684) — host bytes reach the kernel via the serial attachment")
    print("  controls: Ctrl-C ends the session and restores the terminal; Backspace/Enter are forwarded raw (no host line editing)")
} else if scriptMode {
    print("  mode: scripted input (non-interactive; claim 6684)")
    print("  serial log: \(serialLogPath)  (guest output teed to log)")
    print("  script: \(scriptPath!)  (forwarded once after the configured serial marker appears)")
    if let scriptAfter { print("  script-after: \"\(scriptAfter)\"  (forward once after this serial text appears)") }
    if let script2Path { print("  script2: \(script2Path)  (claim 4613: forwarded once after script2-after appears)") }
    if let script2After { print("  script2-after: \"\(script2After)\"  (forward script2 once after this serial text appears)") }
    if let script3Path { print("  script3: \(script3Path)  (claim 7786: forwarded once after script3-after appears)") }
    if let script3After { print("  script3-after: \"\(script3After)\"  (forward script3 once after this serial text appears)") }
    if let screenshotAfter { print("  screenshot-after: \"\(screenshotAfter)\"  (capture the framebuffer once after this serial text appears)") }
    if hostWriteAfter != nil {
        print("  host-write: \(hostWritePath ?? "<none>")  (M81f #1766: write \(hostWriteContent?.count ?? 0) bytes into the share once \"\(hostWriteAfter!)\" appears)")
    }
    if !snapshotTriggers.isEmpty {
        for t in snapshotTriggers { print("  snapshot-after: \"\(t.marker)\"  (claim 0680: kind-4 request over queue 3; guest streams the scanout → \(t.outPath))") }
        print("  snapshot-drain-timeout: \(snapshotDrainTimeout)s  (issue 1788: hold the VM at teardown until every armed kind-4 stream has landed; 0 = stop immediately)")
    }
    if let cvcConsoleFilePath { print("  cvc-console-file: \(cvcConsoleFilePath)  (claim 0680: structured console — every queue-1 log line captured; kind-3 arms the guest tee on \"cvconsole-ready\")") }
    if let scriptExpect { print("  script-expect: \"\(scriptExpect)\"  (exit 0 iff observed in the serial log)") }
    if scriptExpect != nil {
        print("  script-expect-tail: \(scriptExpectTail)s  (claim 4912: hold the VM after the match so post-marker kernel output reaches the serial log; 0 = stop immediately)")
    }
} else {
    print("  serial log: \(serialLogPath)  (timeout: \(Int(timeout))s)")
    print("  expecting: \"\(expectLine)\"")
    if let terminalMarker { print("  terminal marker: \"\(terminalMarker)\"") }
    if let markerDumpPath {
        print("  marker dump: \(markerDumpPath)  (ADR 0004 D4 fallback — NVRAM ladder; exit 0 iff an M2_* marker is found)")
    }
    if let nvramConsolePath {
        print("  nvram console: \(nvramConsolePath)  (claim 0015 — post-exit console stream from the NVRAM channel; exit 0 iff bytes were found)")
    }
}
for t in hostCmdTriggers {
    print("  host-cmd-after: \"\(t.marker)\" → \(t.command.rawValue)  (M114a #2454: HostCommand bus mirror — dispatch emits a host-ui: receipt)")
}
if let line = hostSerialSend {
    print("  host-serial-send: \(line.utf8.count) bytes armed  (M114d #2457: the send-serial verb / drawer injector writes the line into the console pipe)")
}
if hostCaptureKeys {
    print("  host-capture-keys: ENABLED (M114b #2455) — capture-keys dispatches on the HostCommand bus once the machine view exists; the host-ui: receipt is the same one ⌥⌘K / the toolbar pill emit")
}
if let netCapturePath {
    print("  net: ENABLED (milestone five card N1, claim 1373) — virtio-net device attached, guest TX frames captured byte-exactly to \(netCapturePath), fixed MAC 02:00:00:00:00:01")
}
if displayMode {
    print("  display: ENABLED (milestone six card G1, claim 6053) — virtio-gpu device attached, 1280x720 scanout window shown for the session")
}
if inputMode {
    print("  input: ENABLED (milestone seven card I1, claim 4272) — keyboard + pointing devices attached (VZUSBKeyboardConfiguration + VZUSBScreenCoordinatePointingDeviceConfiguration); the guest-side device is the Apple XHCI USB controller (DID 0x1a06) with the HID devices behind it")
}
if let usbMsdPath {
    print("  usb-msd: ENABLED (M43 card U6, issue #1037) — USB mass storage attached on an explicit VZXHCIControllerConfiguration (\(usbMsdPath)); the guest enumerates it as a bulk device behind the XHCI controller (the U1 bulk probe consumes it)")
}
if let dataDiskPath {
    print("  data-disk: ENABLED (M100b, issue #2307, ADR 0050) — second virtio-blk function id 'virelai-vlfs', raw read-write, sync .full (\(dataDiskPath)); the guest's GET_ID probe names it")
}
if let kc = inputKeyCode {
    if viaVirtioEnabled {
        print("  input-key: ENABLED (milestone seven card I2, claim 4116) — keyDown keyCode \(kc) rides the custom-virtio INPUT queue (claim 9588; HID-shaped messages, no view) after \"\(inputKeyAfter ?? "usb: enumerated")\"")
    } else {
        print("  input-key: ENABLED (milestone seven card I2, claim 4116) — synthesized keyDown keyCode \(kc) dispatched to the view after \"\(inputKeyAfter ?? "usb: enumerated")\" (the minimal I2 report seam; the full scripted surface is I3)")
    }
}
if let s = inputString {
    if viaVirtioEnabled {
        print("  input-string: ENABLED (milestone seven card I3, claim 6050) — typing \(s.debugDescription) over the custom-virtio INPUT queue (claim 9588; HID-shaped messages, no view) after \"\(inputStringAfter ?? "virelai> ")\"")
    } else {
        print("  input-string: ENABLED (milestone seven card I3, claim 6050) — typing \(s.debugDescription) into the view after \"\(inputStringAfter ?? "virelai> ")\" (keyDown + keyUp per char, shift for uppercase)")
    }
}
if let s = inputChords {
    if viaVirtioEnabled && !chordsViaView {
        print("  input-chords: ENABLED (milestone eight card U2, claim 1809) — typing \(s.debugDescription) over the custom-virtio INPUT queue (claim 9588; HID-shaped messages, no view, 0.25 s/stroke fixed pacing) after \"\(inputChordsAfter ?? "userspace: el0=1")\"")
    } else if chordsViaView {
        print("  input-chords: ENABLED (milestone eight card U2, claim 1809) — typing \(s.debugDescription) into the VZVirtualMachineView (--chords-view forces the view path despite the armed custom-virtio INPUT queue; \(inputChordsDelay) s per keystroke) after \"\(inputChordsAfter ?? "userspace: el0=1")\"")
    } else {
        print("  input-chords: ENABLED (milestone eight card U2, claim 1809) — typing \(s.debugDescription) into the view after \"\(inputChordsAfter ?? "userspace: el0=1")\" (keyDown + keyUp per chord: printable chars, return/up/down/left/right/home/end/delete/tab, alt-tab, ctrl-tab, ctrl-shift-tab, alt-shift-tab, ctrl-a..ctrl-z, ctrl-shift-a..ctrl-shift-z; \(inputChordsDelay) s per keystroke)")
    }
}
if viaVirtioEnabled {
    print("  via-virtio: ENABLED (claim 9588, issue #523 item 3) — keyboard injection rides the custom-virtio INPUT queue as HID-shaped 16-byte messages; NO NSEvent/CGEvent synthesis and no window/view required (attacks #179 synthesized-drop and #151 activation wall)")
}
if let seq = pointerVirtioScript {
    print("  pointer-virtio: ENABLED (claim 9367, issue #523 item 3 / #151) — \(seq.debugDescription) rides the custom-virtio INPUT queue as kind-2 absolute-pointer messages after \"\(pointerVirtioAfter ?? "winloop: present ok")\" (transport=cv-input; headless-safe, no view)")
}
if let script = pointerScript {
    print("  pointer: ENABLED (milestone eight card U4, claim 4993) — \(script.debugDescription) after \"\(pointerAfter ?? "tasks user-el0 reaped")\" via route \"\(pointerRoute)\"; trust=post:\(CGPreflightPostEventAccess()) ax:\(AXIsProcessTrusted()) (request-trust=\(pointerRequestTrust ? "on" : "off"))")
}
if let netInjectPath {
    print("  net-inject: ENABLED (milestone five card N2, claim 6076) — \(netInjectPath) written into the attachment's socket once after \"\(netInjectAfter ?? "net: rx-armed")\" appears in the serial log (host→guest RX)")
}
if let hostIP = netArpRespondHostIP {
    let ipText = hostIP.map(String.init).joined(separator: ".")
    print("  net-arp-respond: ENABLED (milestone five card N3, claim 7293) — the host answers the guest's ARP requests for \(ipText) (host MAC 02:00:00:00:00:02) via the capture thread (deterministic, request-driven)")
}
if let hostIP = netIcmpRespondHostIP {
    let ipText = hostIP.map(String.init).joined(separator: ".")
    print("  net-icmp-respond: ENABLED (milestone five card N4, claim 0148) — the host answers the guest's ICMP echo requests for \(ipText) (host MAC 02:00:00:00:00:02) via the capture thread (deterministic, request-driven)")
}
if let pfx = netRaRespondPrefix {
    print("  net-ra-respond: ENABLED (M117b #2474, ADR 0057 D10) — the host answers the guest's router solicitations with an RA from fe80::ff:fe00:2 advertising \(v6Text(pfx))/64 (A+L, host MAC 02:00:00:00:00:02) via the capture thread (deterministic, request-driven)")
}
if !netNdpRespondAddrs.isEmpty || netRaRespondPrefix != nil {
    let names = netNdpRespondAddrs.map { v6Text($0) }.joined(separator: ", ")
    print("  net-ndp-respond: ENABLED (M117b #2474, ADR 0057 D10) — the host answers the guest's neighbor solicitations for [\(names)]\(netRaRespondPrefix != nil ? " plus the router link-local fe80::ff:fe00:2" : "") (NA S=1 O=1, host MAC 02:00:00:00:00:02) via the capture thread; unlisted targets go unanswered")
}
if let addr = netIcmp6RespondAddr {
    print("  net-icmp6-respond: ENABLED (M117b #2474, ADR 0057 D10) — the host answers the guest's ICMPv6 echo requests for \(v6Text(addr)) (host MAC 02:00:00:00:00:02) via the capture thread (deterministic, request-driven)")
}
if let addr = netUdp6RespondAddr, let port = netUdp6RespondPort {
    print("  net-udp6-respond: ENABLED (M117c #2475, ADR 0057) — the host echoes the guest's UDP/IPv6 datagrams for [\(v6Text(addr))]:\(port) (host MAC 02:00:00:00:00:02) via the capture thread (deterministic, request-driven)")
}
if let addr = netTcp6RespondAddr, let port = netTcp6RespondPort {
    print("  net-tcp6-respond: ENABLED (M117c #2475, ADR 0057) — the host answers the guest's bounded TCP/IPv6 client on [\(v6Text(addr))]:\(port) (host MAC 02:00:00:00:00:02, server ISN 0x\(hex32(netTcpSrvIsn))) via the capture thread (deterministic, request-driven)")
}
if let hostIP = netUdpRespondHostIP, let hostPort = netUdpRespondHostPort {
    let ipText = hostIP.map(String.init).joined(separator: ".")
    print("  net-udp-respond: ENABLED (milestone five card N5, claim 8552) — the host answers the guest's UDP datagrams for \(ipText):\(hostPort) (host MAC 02:00:00:00:00:02) via the capture thread (deterministic, request-driven)")
}
if let hostIP = netDnsRespondHostIP {
    let ipText = hostIP.map(String.init).joined(separator: ".")
    var knobs = "a=\(netDnsAnswers.count) aaaa=\(netDnsAnswers6.count) ttl=\(netDnsTTL)"
    if netDnsSpoof { knobs += " spoof" }
    if netDnsWrongQuestion { knobs += " wrong-question" }
    if netDnsTruncate { knobs += " truncate" }
    print("  net-dns-respond: ENABLED (milestone twelve card N2, claim 7566; depth M99i #2187) — the host answers the guest's DNS queries for \(ipText):\(netDnsRespondHostPort) via the capture thread (deterministic, request-driven; \(knobs))")
}
if let hostIP = netSntpRespondHostIP {
    let ipText = hostIP.map(String.init).joined(separator: ".")
    let skew = netSntpSkew ?? 0
    let skewText = skew == 0 ? "" : (skew > 0 ? "+\(skew)s" : "\(skew)s")
    print("  net-sntp-respond: ENABLED (M83b #1775) — the host answers the guest's SNTP queries for \(ipText):\(netSntpRespondHostPort) with host time\(skewText) via the capture thread (deterministic, request-driven)")
}
if let leaseIP = netDhcpRespondLeaseIP {
    let ipText = leaseIP.map(String.init).joined(separator: ".")
    // The prefix stays byte-identical to card N8's gate assertion; card
    // N9's lease knob is noted after it.
    print("  net-dhcp-respond: ENABLED (milestone five card N8, claim 0351) + card N9 (claim 9489) — the host answers the guest's DHCP handshake with the fixed lease ip=\(ipText) mask=255.255.255.0 gw=10.0.0.1 server=\(ipText) lease=\(netDhcpRespondLeaseSecs) via the capture thread (deterministic, request-driven)")
    if netDhcpRespondNoRenew {
        print("  net-dhcp-respond-norenew: ENABLED (audit follow-up 3, issue #119) — the host REFUSES the guest's unicast RENEWING REQUESTs; the client must escalate to REBINDING at T2 on its own")
    }
    if netDhcpRespondNoRebind {
        print("  net-dhcp-respond-norebind: ENABLED (audit follow-up 3, issue #119) — the host REFUSES the guest's broadcast REBINDING REQUESTs (ciaddr != 0); the client's lease runs out")
    }
}
if let hostIP = netTcpRespondHostIP, let hostPort = netTcpRespondHostPort {
    let ipText = hostIP.map(String.init).joined(separator: ".")
    print("  net-tcp-respond: ENABLED (milestone five card N10, claim 7026) + card N11 (claim 5357) — the host answers the guest's bounded TCP client on \(ipText):\(hostPort) (host MAC 02:00:00:00:00:02, server ISN 0x\(hex32(netTcpSrvIsn))) via the capture thread (deterministic, request-driven)")
    if netTcpRespondHandshakeOnly {
        print("  net-tcp-respond mode: handshake-only (card N11) — the SYN is answered with a SYN-ACK, then data/FIN go unanswered (the deterministic black hole for the retransmission-bound run)")
    }
    if netTcpRespondPacketMode {
        let chunkCount = (netTcpRespondPacketPayload.count + netTcpRespondPacketChunk - 1) / netTcpRespondPacketChunk
        print("  net-tcp-respond mode: packet (M51 SSH1, #1168) — after the handshake, page \(netTcpRespondPacketPayload.count) bytes out as \(chunkCount) chunks of ≤\(netTcpRespondPacketChunk) bytes, one per guest ACK")
    }
    if netTcpRespondOptionsMode {
        print("  net-tcp-respond mode: options (M99h, #2186) — the SYN-ACK carries MSS 1460 + SACK-permitted + WS + TS (data offset 10) and every data/FIN segment carries NOP+NOP+TS (data offset 8) — a real peer's wire shape")
    }
    if netTcpRespondSSHMode {
        print("NET-TCP-SSH: ENABLED (M51 SSH5, #1172) hostkey=\(SSHFixtures.hexString(netTcpRespondSSHHostKey)) userkey=\(SSHFixtures.hexString(netTcpRespondSSHUserKey)) marker=\(netTcpRespondSSHMarker.debugDescription) exit=\(netTcpRespondSSHExitStatus) tamper-mac=\(netTcpRespondSSHTamperMAC)")
    }
}
if let guestIP = netTcpConnectGuestIP, let guestPort = netTcpConnectPort {
    let ipText = guestIP.map(String.init).joined(separator: ".")
    print("  net-tcp-connect: ENABLED (M45 SH7, issue #1083, ADR 0020 Amendment B) — the host initiates an INBOUND TCP connection to the guest listener \(ipText):\(guestPort) (client port \(netTcpCliPort), ISN 0x\(hex32(netTcpCliIsn)), guest server ISN 0x\(hex32(netTcpGuestSrvIsn))) after \"\(netTcpConnectAfter ?? "sh: remote")\"\(netTcpConnectPayload.isEmpty ? "" : ", \(netTcpConnectPayload.count)-byte payload")")
    // M99f (#2184): each further --net-tcp-connect flag is its own client.
    for client in netTcpClients.dropFirst() {
        let extraIP = client.guestIP.map(String.init).joined(separator: ".")
        print("  net-tcp-connect: ENABLED additional client to \(extraIP):\(client.guestPort) (client port \(client.cliPort))")
    }
    if netTcpConnectSSHMode {
        print("NET-TCP-CONNECT-SSH: ENABLED (M70g G1, #1491) user=\(netTcpConnectSSHUser) exec=\(netTcpConnectSSHExec.debugDescription) hostpin=\(SSHFixtures.hexString(netTcpConnectSSHHostPin))")
    }
    if let path = netTcpConnectStreamExec {
        print("NET-TCP-STREAM: ENABLED (hermetic --net only) executable=\(path)")
    }
}
if netNatEnabled {
    print("  net-nat: ENABLED (milestone five card N7, claim 4678) — VZNATNetworkDeviceAttachment attached (host router + NAT; no capture file — guest-observed counters are the gate's evidence)")
}
if let iface = netBridgedInterface {
    print("  net-bridged: ENABLED (M117d, issue #2476, ADR 0057 D11) — VZBridgedNetworkDeviceAttachment on \(iface) (com.apple.vm.networking carried in signature; the guest sits on the real LAN — guest-observed counters are the gate's evidence)")
}
if netVmnetEnabled {
    print("  net-vmnet: ENABLED (M117d, issue #2476, ADR 0057 D11) — VZVmnetNetworkDeviceAttachment on a shared-mode vmnet network\(netVmnetSubnetText.map { " (gateway \($0))" } ?? "") (the daemon serves DHCP + NAT; guest-observed counters are the gate's evidence)")
}

// M108 (#2325/#2326, ADR 0051): arm the live lanes BEFORE the VM starts —
// the ARMED record lands in the share now, so the seat's first poll after
// boot already verifies it. The session is SHARED: one credential, one
// epoch, one ARMED record naming every live lane in its mask. No flag →
// no HOSTINT/, no INBOX/, no records, no pasteboard read (D7's
// byte-silence: a flags-off boot is identical to today). A refused arm
// (no credential, broken share) is dead lanes, not a failed boot.
// The drop lane's display precondition (D4): the drop target is the
// display view, so a headless runner refuses lane_disabled at arm and the
// drop bit never enters the mask.
if hostClipboardFlag || hostDropFlag || hostNotifyFlag || hostOutboxFlag {
    let shareURL = URL(fileURLWithPath: cvcFileShareDir!, isDirectory: true)
    var mask: UInt8 = 0
    var requested: [String] = []
    if hostClipboardFlag {
        mask |= HostInt.laneClip
        requested.append("clip")
    }
    var dropWanted = false
    if hostDropFlag {
        requested.append("drop")
        if screenshotPath != nil || displayMode || hostSessionMode {
            mask |= HostInt.laneDrop
            dropWanted = true
        } else {
            hostIntRefuse("drop", .laneDisabled)
        }
    }
    if hostNotifyFlag {
        mask |= HostInt.laneNotify
        requested.append("notify")
    }
    if hostOutboxFlag {
        mask |= HostInt.laneOutbox
        requested.append("outbox")
    }
    if mask != 0 {
        hostIntSession = HostIntSession.arm(shareDir: shareURL, mask: mask, requested: requested)
    }
    if let session = hostIntSession {
        if hostClipboardFlag {
            hostClipboard = HostClipboard(session: session, pasteboardName: hostPasteboardName)
            hostClipboard?.start()
        }
        if dropWanted {
            hostDrop = HostDrop(session: session)
            hostDrop?.start()
        }
        if hostNotifyFlag {
            hostNotify = HostNotify(session: session)
            hostNotify?.start()
        }
        if hostOutboxFlag {
            // --host-outbox-dir redirects the landing; absent it the
            // lane default is ~/Downloads (the flag is what keeps a
            // class-B run out of the real one).
            let dest = hostOutboxDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            hostOutbox = HostOutbox(session: session, destDir: dest)
            hostOutbox?.start()
        }
        // One shared 250 ms drain for every consuming lane — the notify
        // and outbox lanes ride the same poll as the clipboard drain
        // (ADR 0051 D5, V2-D5).
        if hostClipboard != nil || hostNotify != nil || hostOutbox != nil {
            DispatchQueue.main.async { hostIntTick() }
        }
    }
}

runner.queue.async {
    // M115a (#2460): arm the host vsock listener on the VM's queue BEFORE
    // any boot or restore — a post-restore guest connect must find the
    // listener already in place in the loading process too.
    if vsockEnabled {
        if let socketDevice = runner.vm.socketDevices.first as? VZVirtioSocketDevice {
            vsockListener.delegate = vsockListenerDelegate
            socketDevice.setSocketListener(vsockListener, forPort: vsockPort)
            print("VSOCK: host listener armed port=\(vsockPort)")
            // M115b (#2461, ADR 0056): the ctl endpoint is fail-closed —
            // no `vsock-ctl` share credential, no listener, and a guest
            // connect then gets the honest RST of an unlistened port.
            if vsockCtlEnabled {
                // M115d (#2463): the credential may ride EITHER host file
                // channel — the profile share can attach through cvc-file
                // or (for a save/restore-safe device set) virtio-fs.
                let ctlShareDirs = [cvcFileShareDir, virtioFSShareDir].compactMap { $0 }
                if let key = ctlShareDirs.lazy.compactMap({
                    VSCtl.loadKey(shareDir: URL(fileURLWithPath: $0, isDirectory: true))
                }).first {
                    // M115d (#2463): the suspend verb's driver — the
                    // profile's saved-state/ as destination, the
                    // device set's save/restore verdict as the support
                    // check. Both computed once here: the verb then
                    // answers `no_state`/`unsupported` honestly or runs
                    // the pause→save→reply→stop chain.
                    var suspendUnsupported: String? = nil
                    do { try config.validateSaveRestoreSupport() } catch {
                        suspendUnsupported = "\(error as NSError)"
                    }
                    let suspendCtl = SuspendCtl(vm: runner.vm, queue: runner.queue,
                                              savedStateDir: activeProfile?.savedStateURL,
                                              unsupported: suspendUnsupported)
                    let delegate = VSockCtlListenerDelegate(
                        key: key,
                        suspendHandler: { suspendCtl.begin() },
                        onSuspendAccepted: { suspendCtl.finish() })
                    vsockCtlDelegate = delegate
                    vsockCtlListener.delegate = delegate
                    socketDevice.setSocketListener(vsockCtlListener, forPort: vsockCtlPort)
                    print("VSOCK-CTL: host listener armed port=\(vsockCtlPort) suspend=\(suspendUnsupported != nil ? "unsupported" : (activeProfile == nil ? "no_state" : "armed"))")
                } else {
                    print("VSOCK-CTL: refuse no_credential (no vsock-ctl row in the armed share's SECRETS.TXT)")
                }
            }
        } else {
            FileHandle.standardError.write(Data("ERROR: --vsock was attached but no VZVirtioSocketDevice is present on the VM.\n".utf8))
            exit(1)
        }
    }
    if vzRestore, let load = vzRestoreLoadDir {
        // M70g G3 (#1459): the load process never boots — it restores the
        // other process's saved state into this fresh VZVirtualMachine.
        if vzWarmLeg {
            // ADR 0059 (M131b #2639): a scripted warm leg. Restore the leg's
            // checkpoint clone, then the D5 handshake (serial-epoch mark →
            // "\n" → fresh 'virelai> ' inside the epoch) seats the guest;
            // only then does the ordinary script/expect/timeout machinery
            // arm. The leg's first --script-after is re-based onto that
            // handshake — a boot-settle marker cannot re-fire post-restore.
            startGuestOutputTee()
            let probe = VZRestoreProbe(vm: runner.vm, queue: runner.queue, serialURL: serialURL,
                                       input: consoleInputPipe.fileHandleForWriting, timeout: timeout,
                                       mode: .load(URL(fileURLWithPath: load, isDirectory: true)),
                                       warm: true,
                                       onSeated: {
                vmDidStart = true
                print("VZ-RESTORE: warm leg seated — arming the leg's script over the post-restore epoch (ADR 0059 D6)")
                if let orig = scriptAfter {
                    print("  warm: --script-after \"\(orig)\" re-based onto the post-restore handshake (ADR 0059 D5)")
                }
                forwardScriptOnce(path: scriptPath!, after: "virelai> ", label: "script", settle: 0.5)
                startScript2Input()
                startScript3Input()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { scriptPoll() }
            })
            probe.startFromSavedState()
            return
        }
        let probe = VZRestoreProbe(vm: runner.vm, queue: runner.queue, serialURL: serialURL,
                                   input: consoleInputPipe.fileHandleForWriting, timeout: timeout,
                                   witnessLine: vzRestoreWitness,
                                   verifyCommand: vzRestoreVerifyCommand,
                                   verifyOutput: vzRestoreVerifyOutput,
                                   mode: .load(URL(fileURLWithPath: load, isDirectory: true)))
        probe.startFromSavedState()
        return
    }
    if let resumeURL = resumeStateURL {
        // M115d (#2463): `--resume` — restore the machine state a ctl
        // `suspend` saved into the profile and continue the guest. The
        // ctl listener is already armed above, so the resumed machine
        // can suspend again.
        runner.vm.restoreMachineStateFrom(url: resumeURL) { error in
            if let error {
                print("SUSPEND-RESUME: restore refused code=\((error as NSError).code) error=\(error as NSError)")
                FileHandle.standardError.write(Data("ERROR: --resume restore failed: \(error as NSError)\n".utf8))
                exit(1)
            }
            runner.vm.resume { result in
                if case .failure(let error) = result {
                    print("SUSPEND-RESUME: resume refused error=\(error as NSError)")
                    FileHandle.standardError.write(Data("ERROR: --resume resume failed: \(error as NSError)\n".utf8))
                    exit(1)
                }
                vmDidStart = true
                print("SUSPEND-RESUME: restored \(SuspendCtl.stateFileName)")
            }
        }
        return
    }
    runner.vm.start { result in
        if case .failure(let error) = result {
            if hostSessionMode {
                FileHandle.standardError.write(Data("ERROR: VM failed to start: \(error)\n".utf8))
                DispatchQueue.main.async {
                    // M114d (#2457): a start refusal gets the crash card
                    // too — the drawer opens on it.
                    inspector.noteStop(PostmortemCard(
                        ending: .crashed, state: "start",
                        reason: StopReasonRecorder.describe(error),
                        serialLines: inspector.ingestedCount))
                    hostApplication?.showFailure("VM failed to start: \(error)")
                }
                return
            }
            restoreTerminal()
            FileHandle.standardError.write(Data("ERROR: VM failed to start: \(error)\n".utf8))
            exit(1)
        }
        vmDidStart = true
        if hostSessionMode {
            DispatchQueue.main.async { hostApplication?.didStart() }
        }
        if vzRestore {
            let mode: VZRestoreProbe.Mode = vzRestoreSaveDir.map { .save(URL(fileURLWithPath: $0, isDirectory: true)) } ?? .sameProcess
            let probe = VZRestoreProbe(vm: runner.vm, queue: runner.queue, serialURL: serialURL,
                                       input: consoleInputPipe.fileHandleForWriting, timeout: timeout,
                                       witnessLine: vzRestoreWitness,
                                       verifyCommand: vzRestoreVerifyCommand,
                                       verifyOutput: vzRestoreVerifyOutput,
                                       mode: mode, settleAfter: vzRestoreSettle)
            probe.start()
        }
    }
}

var captureTimes: [TimeInterval] = [5, 10, 15]

// Milestone six card G1 (claim 6053): create the AppKit window + the
// VZVirtualMachineView the virtio-gpu scanout renders into, whenever the
// gpu device is attached (`--display` and/or `--screenshot`). Shared by
// the evidence path and script mode so a gated run can screenshot the
// guest framebuffer mid-script.
func setupDisplayWindow() {
    guard screenshotPath != nil || displayMode else { return }
    let app = NSApplication.shared
    // Screenshot/headless gates keep the historical accessory policy.
    // Human display+input sessions must finish launching as an AppKit app
    // and dispatch native events, not just run Foundation's VM timers.
    let wantPointer = pointerScript != nil
    let nativeInput = NativeInput.enabled(display: displayMode, input: inputMode)
    if hostSessionMode {
        // The bundled front door already finished launching.
    } else if wantPointer || nativeInput {
        app.setActivationPolicy(.regular)
        // A CLI process must finishLaunching before the window server
        // will grant it activation/key status (unbundled executables skip
        // the normal launch sequence). Policy before finishLaunching.
        app.finishLaunching()
    } else {
        app.setActivationPolicy(.accessory)
    }
    // M114b: the evidence window gets the same resizable + 16:9-locked
    // chrome as the session window, so the fullscreen/capture-keys verbs
    // performed on it are real, not just receipted.
    let window = hostApplication?.window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentAspectRatio = NSSize(width: 16, height: 9)
    let view = TraceView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    view.trace = ["direct", "diag", "pid", "drag", "warp", "cg"].contains(pointerRoute)
    view.nativeInput = nativeInput
    view.virtualMachine = runner.vm
    window.setContentSize(NSSize(width: 1280, height: 720))
    if let hostApplication {
        hostApplication.attach(view)
    } else {
        window.contentView = view
    }
    if nativeInput && !hostSessionMode {
        window.title = "VirelaiOS"
        window.makeFirstResponder(view)
    }
    window.center()
    window.acceptsMouseMovedEvents = true
    // AppKit only dispatches mouseMoved to views inside a tracking area;
    // without one, moves posted to the window are dropped at the
    // dispatch layer (a real mouse gets moves via the implicit tracking
    // area of the window's first responder path, but synthesized posts
    // need the explicit area).
    let tracking = NSTrackingArea(
        rect: view.bounds,
        options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .activeAlways],
        owner: view, userInfo: nil)
    view.addTrackingArea(tracking)
    // M108c (#2326, ADR 0051 D4): the drop target lives here, on the display
    // view itself — registered only while the lane is armed, so a flags-off
    // boot shows no affordance.
    if hostDrop != nil {
        view.registerForDraggedTypes([.fileURL])
        view.dropHandler = { urls in hostDrop?.drop(urls: urls) }
    }
    window.orderFrontRegardless()
    window.makeKeyAndOrderFront(nil)
    if hostSessionMode {
        // HostApplication owns activation, focus and close/quit.
    } else if wantPointer {
        window.level = .normal
        // macOS 14+: the deprecated ignoringOtherApps form is a no-op for
        // unbundled CLI processes; the modern no-arg activate() is the
        // one that can steal focus. Try both.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.activate()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        // Re-assert after the run loop has a chance to complete the
        // activation (async on macOS), so the first synthesized event
        // lands on an already-key window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.activate()
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            pmo("diag key-after-activate=\(window.isKeyWindow) main=\(window.isMainWindow) active=\(NSApp.isActive) visible=\(window.isVisible) onscreen=\(window.isOnActiveSpace)")
        }
    } else if nativeInput {
        app.activate()
    } else {
        app.activate(ignoringOtherApps: true)
    }
    machineView = view
    machineWindow = window
    // M139a: the router's window lookup covers the evidence window too —
    // a menu action lands on the session whose window is key.
    primarySession.view = view
    primarySession.window = window
    // M114b (#2455): --host-capture-keys rides the bus — one dispatch once
    // the view exists, so startup capture lands in the same host-ui:
    // receipt as ⌥⌘K / the toolbar pill / a --host-cmd-after trigger.
    if hostCaptureKeys, machineView?.capturesSystemKeys == false {
        commandBus.dispatch(.captureKeys)
    }
}

// Milestone six card G1 (claim 6053): the 5/10/15 s screenshot capture,
// shared by the evidence poll and scriptPoll so a gated scripted run can
// capture the guest framebuffer. The evidence now comes from
// ScreenCaptureKit — the runner's own window captured by ID and cropped
// to the content area, i.e. the composited pixels exactly as the operator
// sees them in `--display` (title bar excluded via the window's own frame
// geometry). The offscreen `cacheDisplay` render remains as the honest
// fallback when Screen Recording permission is unavailable (TCC not
// granted, headless CI, ...); the printed capture path says which one
// produced the PNG.
func captureScreenshot(at t: TimeInterval) {
    let path: String
    if let base = screenshotPath {
        let dot = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        path = ext.isEmpty ? "\(dot)-\(Int(t))s" : "\(dot)-\(Int(t))s.\(ext)"
    } else {
        path = "artifacts/vm-screen-\(Int(t))s.png"
    }
    writeScreenshot(to: path)
}

// Card G6 set_visible follow-on (claim 0487): a MARKER-driven capture.
// When `--screenshot-after <marker>` is set, the framebuffer is captured
// ONCE the moment the marker appears in the serial log, under a stable
// `-<label>` name (deterministic — the fixed 5/10/15 s captures cannot
// guarantee a capture lands inside an EL0 hide/show window).
// The `-<label>` path naming shared by --screenshot-after and the bus's
// screenshot verb (M114a): <base>-<label>[.<ext>], or artifacts/ when no
// --screen base was given.
func screenshotPathForLabel(_ label: String) -> String {
    if let base = screenshotPath {
        let dot = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        return ext.isEmpty ? "\(dot)-\(label)" : "\(dot)-\(label).\(ext)"
    }
    return "artifacts/vm-screen-\(label).png"
}

// M120e (#2562): the ⌘⇧5 verb's destination — `<share>/CAPTURES/` of the
// armed share or the active profile (the recorder's own destination), with
// the --screen basename + ext kept so a run's naming survives the reroute.
// A shareless run keeps the historical <base>-<label>[.<ext>] / artifacts/
// path — the card promises CAPTURES only where a share exists.
func screenshotPathForCapture(_ label: String) -> String {
    guard let dir = commandBus.captures.resolvedDir() else {
        return screenshotPathForLabel(label)
    }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let screen = (screenshotPath ?? "") as NSString
    let stem = (screen.deletingPathExtension as NSString).lastPathComponent
    let ext = screen.pathExtension
    let name = "\(stem.isEmpty ? "vm-screen" : stem)-\(label).\(ext.isEmpty ? "png" : ext)"
    return dir.appendingPathComponent(name).path
}

func captureScreenshotMarker(_ label: String) {
    writeScreenshot(to: screenshotPathForLabel(label))
}

// Shared capture body (ScreenCaptureKit first, cacheDisplay fallback):
// render the composited content area to a PNG and write it to `path`.
func writeScreenshot(to path: String) {
    var png: Data?
    if let img = screenCaptureKitScreenshot() {
        let rep = NSBitmapImageRep(cgImage: img)
        if let data = rep.representation(using: .png, properties: [:]) {
            png = data
            print("  capture path: ScreenCaptureKit (composited window, \(img.width)x\(img.height) px)")
        }
    }
    if png == nil, let view = machineView,
       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        png = rep.representation(using: .png, properties: [:]) ?? png
        print("  capture path: cacheDisplay fallback (Screen Recording permission unavailable)")
    }
    guard let data = png else { return }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("SUCCESS: framebuffer screenshot saved to \(path) (\(data.count) bytes).")
        screenshotSaved = true
    } catch { print("WARNING: could not write screenshot: \(error)") }
}

// ScreenCaptureKit path: capture OUR window by ID via a window content
// filter (SCShareableContent -> SCContentFilter(display:includingWindows:))
// and crop the title bar off, so the evidence is the composited content
// area exactly as the operator sees it in `--display`. No display-space
// coordinate math is involved — the filter captures the window and the
// title bar height comes from the window's own frame geometry. Screen
// Recording permission is required; the caller falls back to cacheDisplay
// when the capture fails.
func screenCaptureKitScreenshot() -> CGImage? {
    guard let window = machineWindow else { return nil }
    let windowID = CGWindowID(window.windowNumber)
    guard windowID > 0 else { return nil }

    let sem = DispatchSemaphore(value: 0)
    var scWindow: SCWindow?
    var display: SCDisplay?
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
        if let error {
            print("WARNING: SCShareableContent failed: \(error)")
        } else if let content {
            scWindow = content.windows.first { $0.windowID == windowID }
            display = content.displays.first
            if scWindow == nil {
                print("WARNING: window \(windowID) not in SCK shareable content (off-screen?)")
            }
        }
        sem.signal()
    }
    if sem.wait(timeout: .now() + 5) == .timedOut {
        print("WARNING: SCShareableContent timed out")
        return nil
    }
    guard let scWindow, let display else { return nil }

    let filter = SCContentFilter(display: display, including: [scWindow])
    let config = SCScreenshotConfiguration()
    config.showsCursor = false
    config.ignoreShadows = true

    var image: CGImage?
    let sem2 = DispatchSemaphore(value: 0)
    SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config) { output, error in
        if let error {
            print("WARNING: ScreenCaptureKit capture failed: \(error)")
        } else {
            image = output?.sdrImage
        }
        sem2.signal()
    }
    if sem2.wait(timeout: .now() + 5) == .timedOut {
        print("WARNING: ScreenCaptureKit capture timed out")
        return nil
    }
    guard let full = image else { return nil }

    // The window capture includes the title bar (the frame above the
    // content view). Crop it off using the window's own geometry so the
    // evidence is exactly the view's content area (what cacheDisplay
    // produced before, so the gate pixel math is unchanged).
    let titleBar = window.frame.height - window.contentLayoutRect.height
    let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : (window.screen?.backingScaleFactor ?? 2.0)
    let crop = CGRect(x: 0,
                      y: titleBar * scale,
                      width: window.contentLayoutRect.width * scale,
                      height: window.contentLayoutRect.height * scale)
    print("  sck debug: window=\(windowID) raw=\(full.width)x\(full.height) scale=\(scale) titleBar=\(titleBar) crop=\(NSStringFromRect(crop))")
    guard crop.width > 0, crop.height > 0,
          crop.minX >= 0, crop.minY >= 0,
          crop.maxX <= Double(full.width), crop.maxY <= Double(full.height),
          let cropped = full.cropping(to: crop) else {
        return full
    }
    return cropped
}

// Issue #1788: stop the device, then run the post-stop evidence reads and
// exit. Split out of finish() so the teardown drain can gate the stop
// itself without duplicating this body.
func stopDeviceAndExit(success: Bool, wantDump: Bool, wantNvram: Bool) {
    runner.queue.async {
        runner.vm.stop { _ in
            // Claim 2188: the VM is stopped, so every guest byte VZ will
            // deliver is already in the pipe — let the tee flush it into the
            // log before the NVRAM reads and exit() below (which would
            // otherwise race the tee thread and cut the tail mid-write).
            drainTeeBeforeExit("finish(success:\(success))")
            // Exit code: the serial evidence `success` is the default; each
            // NVRAM-gated channel (marker ladder, nvram console) flips it to
            // true when its bytes are found. With no such flag the original
            // serial-gate semantics are unchanged.
            var finalSuccess = success
            if wantDump, let dumpPath = markerDumpPath {
                // ADR 0004 D4 fixed-memory-marker fallback (working form, claim
                // 0009): the kernel persists its takeover stage as the EFI
                // non-volatile variable `VirelaiM2` (runtime SetVariable survives
                // ExitBootServices on VZ — observed), and the host reads the
                // store after the VM stops. The memory-scan variant is impossible
                // on VZ: guest RAM is not mapped into the runner process
                // (observed — a full submap-aware walk finds no 256 MiB region
                // and every M2_* hit is the runner's own constant array). The
                // NVRAM ladder is the gate here; the exit code becomes 0 iff at
                // least one marker instance is present in the store.
                print("marker ladder: reading EFI variable store")
                let ladder = readMarkerLadder(from: varsURL)
                writeMarkerDump(to: dumpPath, ladder: ladder)
                if ladder.isEmpty {
                    print("MARKER-GATE: no M2_* marker in the EFI variable store (kernel died before its first marker write, or SetVariable failed)")
                } else {
                    finalSuccess = true
                    for (name, _) in ladder {
                        print("MARKER-GATE: \(name)")
                    }
                }
            }
            if wantNvram, let path = nvramConsolePath {
                print("nvram console: reconstructing console stream from EFI variable store")
                let result = readNvramConsole(from: varsURL)
                writeNvramConsole(to: path, result: result)
                if result.text.isEmpty {
                    print("NVRAM-CONSOLE: no console chunks in the EFI variable store (kernel wrote nothing, or SetVariable failed post-exit)")
                } else {
                    finalSuccess = true
                    print("NVRAM-CONSOLE: \(result.chunks) chunk(s) reconstructed\(result.complete ? "" : " (INCOMPLETE — missing chunk index \(result.missing!))"), \(result.text.count) bytes")
                }
            }
            // Milestone five card N1 (claim 1373): the VM is stopped, so the
            // net attachment is quiescent — stop the reader (closing the
            // runner's socket end unblocks its read), join it, and close the
            // capture file so the gate can assert the guest's frames
            // byte-exactly.
            if netCaptureSocket != nil {
                netCaptureStop = true
                try? netCaptureReadSocket?.close()
                _ = netCaptureDone.wait(timeout: .now() + 2)
                try? netCaptureHandle?.close()
            }
            for client in netTcpClients {
                if let probe = client.streamProcess, probe.isRunning {
                    probe.terminate() // VM stopped; do not leave a blocked test peer behind
                }
            }
            // M102d3 (#2168): the opt-in render device's lifecycle
            // counters (resets, refusals, draws, completions) — numbers
            // only, never token contents or guest bytes.
            if let gpu3dCountersReport {
                print("  \(gpu3dCountersReport())")
            }
            // Claim #1278: report the stop verdict on EVERY run, not only the
            // failing ones. The live gate asserts this line, so dropping the
            // `runner.vm.delegate = vmDelegate` wiring — the exact omission that
            // left #1261 with a bare `state=3` and no reason — now fails a gate
            // instead of silently discarding the reason again.
            print("vm-stop: state=\(runner.vm.state.rawValue)\(vmDelegate.verdict())")
            exit(finalSuccess ? 0 : 1)
        }
    }
}

// Issue #1788: hold the VM before the teardown while an armed kind-4
// snapshot stream is still in flight, then run `done`.
//
// A kind-4 snapshot is a 3.5 MiB round trip (claim 0680: 113 chunks back
// over queue 4 after one request over queue 3), and a `--snapshot-after`
// marker can be printed microseconds before the `--script-expect` match
// that ends the run — live-web boot 13 prints `web-ink-20s` and then
// `web-ink-done` back to back, so ONE poll tick fires the second request
// and records the match. The old path then stopped the device one
// `--script-expect-tail` (default 1.5 s) later, mid-transfer, and the gate
// failed on a .raw the guest was still streaming. Other specs arm a
// snapshot on the very marker they expect (live-wm4-paint A/B,
// live-win-hig), so the honest fix belongs here, not in one spec.
//
// Bounded by --snapshot-drain-timeout; a stream that never lands (dead
// guest) costs that many seconds once and says so loudly.
func drainSnapshotsBeforeStop(_ context: String, then done: @escaping () -> Void) {
    guard snapshotDrainTimeout > 0, !snapshotTriggers.isEmpty else { done(); return }
    let started = Date()
    let deadline = started.addingTimeInterval(snapshotDrainTimeout)
    var announced = false
    func step() {
        // Nothing can land once the device is gone or faulted.
        if runner.vm.state == .stopped || runner.vm.state == .error { done(); return }
        if !snapshotStreamInFlight() {
            if announced {
                FileHandle.standardOutput.write(Data("CVC-SNAP-DRAIN: in-flight stream landed in \(String(format: "%.1f", Date().timeIntervalSince(started)))s — stopping the device (\(context))\n".utf8))
            }
            done()
            return
        }
        if !announced {
            announced = true
            FileHandle.standardOutput.write(Data("CVC-SNAP-DRAIN: kind-4 stream still in flight at \(context) — holding the VM up to \(snapshotDrainTimeout)s so the frame lands\n".utf8))
        }
        guard Date() < deadline else {
            FileHandle.standardError.write(Data("CVC-SNAP-DRAIN: TIMEOUT after \(snapshotDrainTimeout)s with a kind-4 stream still in flight — its .raw will be missing or short (\(context))\n".utf8))
            done()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { step() }
    }
    step()
}

// Issue #1788: is a kind-4 scanout stream in flight right now? The read
// hops onto the device's serial queue — the same discipline every callback
// uses — so the (pendingSnapPath, snap) pair is read consistently, and a
// fire already dispatched onto that queue has necessarily run (FIFO), so a
// request enqueued microseconds earlier is never missed.
func snapshotStreamInFlight() -> Bool {
    #if SPIKE
    guard #available(macOS 27.0, *) else { return false }
    return CustomVirtioSpike.snapshotStreamInFlight()
    #else
    return false
    #endif
}

// Issue #1788: every exit path goes through here. Stopping the device is
// what truncates an in-flight kind-4 stream, so the drain runs first.
func finish(success: Bool) {
    drainSnapshotsBeforeStop("finish(success:\(success))") {
        stopDeviceAndExit(success: success, wantDump: markerDumpPath != nil, wantNvram: nvramConsolePath != nil)
    }
}

// ---------------------------------------------------------------------------
// ADR 0004 D4 fixed-memory-marker fallback (working form, claim 0009): the
// kernel writes each takeover stage as the EFI non-volatile variable
// `VirelaiM2` (VendorGuid M2M2_VIRELAIOS-M). EFI runtime services survive
// ExitBootServices on VZ, so after the run the host reads the variable store
// (artifacts/efi-vars.bin) and sees the ordered ladder of stages the kernel
// reached. A missing later stage names the crash window: a ladder ending at
// M2_MAPD! (identity map built, pre-install) with no M2_MMUP! means the MMU
// switch itself faulted — observed on every VZ run (claim 0009).
// ---------------------------------------------------------------------------

// The kernel's stage words, little-endian as stored by SetVariable. The LE
// byte strings are distinctive ASCII (e.g. "YRTNE_2M" for M2_ENTRY), so a
// plain byte scan of the store finds every instance in file order; the store
// is append-per-write, so file order == write order and the LAST instance is
// the kernel's final stage.
let markerNeedles: [(name: String, leBytes: [UInt8])] = [
    ("M2_TABLE", [0x45, 0x4c, 0x42, 0x41, 0x54, 0x5f, 0x32, 0x4d]), // ELBAT_2M
    ("M2_SERIA", [0x41, 0x49, 0x52, 0x45, 0x53, 0x5f, 0x32, 0x4d]), // AIRES_2M
    ("M2_ENTRY", [0x59, 0x52, 0x54, 0x4e, 0x45, 0x5f, 0x32, 0x4d]), // YRTNE_2M
    ("M2_CMAP!", [0x21, 0x50, 0x41, 0x4d, 0x43, 0x5f, 0x32, 0x4d]), // !PAMC_2M
    ("M2_MAPD!", [0x21, 0x44, 0x50, 0x41, 0x4d, 0x5f, 0x32, 0x4d]), // !DPAM_2M
    ("M2_PREX!", [0x21, 0x58, 0x45, 0x52, 0x50, 0x5f, 0x32, 0x4d]), // !XERP_2M
    ("M2_EXIT!", [0x21, 0x54, 0x49, 0x58, 0x45, 0x5f, 0x32, 0x4d]), // !TIXE_2M
    ("M2_MMUP!", [0x21, 0x50, 0x55, 0x4d, 0x4d, 0x5f, 0x32, 0x4d]), // !PUMM_2M
    ("M2_READY", [0x59, 0x44, 0x41, 0x45, 0x52, 0x5f, 0x32, 0x4d]), // YDAER_2M
    ("M2_RAW!", [0x21, 0x57, 0x41, 0x52, 0x5f, 0x32, 0x4d, 0x00]), // !WAR_2M\0 (claim 0013 probe stage; 7-char word, u64-padded with 0x00)
    ("M2_TXOK!", [0x21, 0x4b, 0x4f, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !KOXT_2M (claim 0013: first TX returned)
    ("M2_TXST!", [0x21, 0x54, 0x53, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !TSXT_2M (virtio flush entered, desc/avail posted)
    ("M2_TXNT!", [0x21, 0x54, 0x4e, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !TNXT_2M (notify write issued)
    ("M2_TXPL!", [0x21, 0x4c, 0x50, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !LPXT_2M (used-ring poll finished)
    ("M2_PEXT!", [0x21, 0x54, 0x58, 0x45, 0x50, 0x5f, 0x32, 0x4d]), // !TXEP_2M (claim 0017: pre-exit TX experiment entered)
    ("M2_PEXD!", [0x21, 0x44, 0x58, 0x45, 0x50, 0x5f, 0x32, 0x4d]), // !DXEP_2M (claim 0017: pre-exit TX experiment flush returned)
    ("M2_TXFL!", [0x21, 0x4c, 0x46, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !LFXT_2M (claim 0018: entered virtio flush)
    ("M2_TXDA!", [0x21, 0x41, 0x44, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !ADXT_2M (desc/avail prepared)
    ("M2_TXCC!", [0x21, 0x43, 0x43, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !CCXT_2M (DMA cache clean completed)
    ("M2_TXBR!", [0x21, 0x52, 0x42, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !RBXT_2M (before first post-exit BAR/common-cfg read)
    ("M2_TXAR!", [0x21, 0x52, 0x41, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !RAXT_2M (after that read)
    ("M2_TXBN!", [0x21, 0x4e, 0x42, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !NBXT_2M (before queue notify MMIO write)
    ("M2_TXAN!", [0x21, 0x4e, 0x41, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !NAXT_2M (after notify)
    ("M2_TXUP!", [0x21, 0x50, 0x55, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !PUXT_2M (entered used-ring poll)
    ("M2_TXUC!", [0x21, 0x43, 0x55, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !CUXT_2M (device changed used.idx)
    ("M2_TXFR!", [0x21, 0x52, 0x46, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !RFXT_2M (flush returned)
    ("M2_TRA1!", [0x21, 0x31, 0x41, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !1ART_2M (claim 0020 phase A: pre-EBS TX experiment entered)
    ("M2_TRA2!", [0x21, 0x32, 0x41, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !2ART_2M (phase A: flush returned)
    ("M2_TRAU!", [0x21, 0x55, 0x41, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !UART_2M (phase A: used.idx advanced)
    ("M2_TRB1!", [0x21, 0x31, 0x42, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !1BRT_2M (phase B: post-EBS/pre-MMU experiment entered)
    ("M2_TRB2!", [0x21, 0x32, 0x42, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !2BRT_2M (phase B: flush returned)
    ("M2_TRBU!", [0x21, 0x55, 0x42, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !UBRT_2M (phase B: used.idx advanced)
    ("M2_TRC1!", [0x21, 0x31, 0x43, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !1CRT_2M (phase C: post-MMU experiment entered)
    ("M2_TRC2!", [0x21, 0x32, 0x43, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !2CRT_2M (phase C: flush returned)
    ("M2_TRCU!", [0x21, 0x55, 0x43, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !UCRT_2M (phase C: used.idx advanced)
    ("M2_TRD1!", [0x21, 0x31, 0x44, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !1DRT_2M (phase D: final-location experiment entered)
    ("M2_TRD2!", [0x21, 0x32, 0x44, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !2DRT_2M (phase D: flush returned)
    ("M2_TRDU!", [0x21, 0x55, 0x44, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !UDRT_2M (phase D: used.idx advanced)
    ("M2_TRNX!", [0x21, 0x58, 0x4e, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !XNR T_2M (claim 0020: experiment skipped — transport not armed)
    ("M2_WP_00", [0x30, 0x30, 0x5f, 0x50, 0x57, 0x5f, 0x32, 0x4d]), // 00_PW_2M (claim 7896 walk-probe battery start)
    ("M2_WP_01", [0x31, 0x30, 0x5f, 0x50, 0x57, 0x5f, 0x32, 0x4d]), // 10_PW_2M (claim 7896: P1 kernel-BSS read returned)
    ("M2_WP_02", [0x32, 0x30, 0x5f, 0x50, 0x57, 0x5f, 0x32, 0x4d]), // 20_PW_2M (claim 7896: P2 ram-hi read returned)
    ("M2_WP_03", [0x33, 0x30, 0x5f, 0x50, 0x57, 0x5f, 0x32, 0x4d]), // 30_PW_2M (claim 7896: P3 ram-mid read returned)
    ("M2_WP_04", [0x34, 0x30, 0x5f, 0x50, 0x57, 0x5f, 0x32, 0x4d]), // 40_PW_2M (claim 7896: P4 ram-lo read returned)
    ("M2_WP_05", [0x35, 0x30, 0x5f, 0x50, 0x57, 0x5f, 0x32, 0x4d]), // 50_PW_2M (claim 7896: P5 virtio-BAR read returned — battery complete)
]

/// Read the EFI variable store and return the marker ladder (name, store
/// offset), in file order. Byte-scan only — no struct-layout assumption
/// beyond the value being present: the marker strings are distinctive 8-byte
/// ASCII sequences, and every hit is checked against the needle table.
func readMarkerLadder(from storeURL: URL) -> [(name: String, offset: Int)] {
    guard let data = try? Data(contentsOf: storeURL) else { return [] }
    let bytes = [UInt8](data)
    var hits: [(name: String, offset: Int)] = []
    var i = 0
    while i + 8 <= bytes.count {
        for (name, needle) in markerNeedles {
            var match = true
            var j = 0
            while j < 8 {
                if bytes[i + j] != needle[j] { match = false; break }
                j += 1
            }
            if match { hits.append((name, i)) }
        }
        i += 1
    }
    hits.sort { $0.offset < $1.offset }
    return hits
}

// ---------------------------------------------------------------------------
// Claim 0015: NVRAM console reconstruction. The kernel persists console
// bytes as chunked EFI variables VirelaiC0..N (runtime SetVariable — the
// proven post-exit-safe channel on VZ), each value prefixed with the
// in-band marker "VIRELAIC <4-digit-index>:" inside the value bytes. A
// plain byte scan of the store finds every chunk in file order (the store
// is append-per-write), exactly like the marker ladder — no struct-layout
// parsing. Payloads are concatenated after validating the indices are
// sequential from 0 (a gap means a SetVariable call was dropped; reported
// honestly).
// ---------------------------------------------------------------------------

struct NvramConsoleResult {
    var text: String = ""
    var chunks: Int = 0
    var complete: Bool = true
    var missing: Int? = nil
}

func readNvramConsole(from storeURL: URL) -> NvramConsoleResult {
    var result = NvramConsoleResult()
    guard let data = try? Data(contentsOf: storeURL) else { return result }
    let bytes = [UInt8](data)
    let prefix = Array("VIRELAIC ".utf8) // 9 bytes; +4 digits + ":" = marker at i+13
    let endMarker = Array("VIRELAIC-END".utf8) // 12 bytes; closes every chunk value
    guard prefix.count == 9, endMarker.count == 12 else { return result }

    // Find every chunk start marker, in file order.
    var starts: [(index: Int, pos: Int)] = []
    var i = 0
    while i + 14 <= bytes.count {
        if bytes[i..<(i + 9)].elementsEqual(prefix) {
            var ok = true
            var index = 0
            for k in 9..<13 {
                let c = bytes[i + k]
                guard c >= 0x30, c <= 0x39 else { ok = false; break }
                index = index * 10 + Int(c - 0x30)
            }
            if ok, bytes[i + 13] == 0x3a { // ":"
                starts.append((index, i))
                i += 14
                continue
            }
        }
        i += 1
    }

    // Payload of each chunk = bytes between its start marker and the first
    // VIRELAIC-END after it. The end marker is written atomically with the
    // value by the kernel, so this delimits payloads exactly without parsing
    // the store's structure (variable headers / GUIDs / other variables sit
    // between chunks). Validate the index sequence 0..n-1: a dropped
    // SetVariable shows as a gap and is reported honestly.
    var expected = 0
    var out = Data()
    var sawUnterminated = false
    for (n, (index, pos)) in starts.enumerated() {
        if index != expected {
            result.complete = false
            result.missing = expected
        }
        expected = index + 1
        let payloadStart = pos + 14
        let searchStart = (n + 1 < starts.count) ? min(payloadStart, starts[n + 1].pos) : payloadStart
        var end = -1
        var j = searchStart
        while j + 12 <= bytes.count {
            if bytes[j..<(j + 12)].elementsEqual(endMarker) {
                end = j
                break
            }
            j += 1
        }
        if end < 0 {
            sawUnterminated = true
            continue // no end marker: skip the chunk rather than swallow the store tail
        }
        out.append(contentsOf: bytes[payloadStart..<end])
    }
    result.chunks = starts.count
    if sawUnterminated {
        result.complete = false
        if result.missing == nil { result.missing = expected }
    }
    if result.chunks == 0 { return result }

    result.text = String(decoding: out, as: UTF8.self)
    return result
}

func writeNvramConsole(to path: String, result: NvramConsoleResult) {
    var lines: [String] = []
    lines.append("VIRELAIOS nvram console — claim 0015 (post-exit console bytes via the NVRAM variable channel)")
    lines.append("date=\(ISO8601DateFormatter().string(from: Date()))")
    lines.append("store=\(varsURL.path)")
    lines.append("chunks=\(result.chunks) complete=\(result.complete)\(result.missing.map { " missing=\($0)" } ?? "") bytes=\(result.text.count)")
    lines.append("NOTE: these bytes rode the NVRAM variable channel (runtime SetVariable), not the virtio serial pipe.")
    lines.append("")
    lines.append("----- reconstructed console stream -----")
    lines.append(result.text)
    lines.append("----------------------------------------")
    let text = lines.joined(separator: "\n") + "\n"
    do {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        print("nvram console output saved to \(path) (\(result.chunks) chunk(s), \(result.text.count) bytes)")
    } catch {
        FileHandle.standardError.write(Data("ERROR: could not write nvram console output to \(path): \(error)\n".utf8))
    }
}

func writeMarkerDump(to path: String, ladder: [(name: String, offset: Int)]) {
    var lines: [String] = []
    lines.append("VIRELAIOS marker dump — ADR 0004 D4 fixed-memory-marker fallback (NVRAM ladder)")
    lines.append("date=\(ISO8601DateFormatter().string(from: Date()))")
    lines.append("store=\(varsURL.path)")
    lines.append("")
    lines.append("marker ladder (file order == write order):")
    if ladder.isEmpty {
        lines.append("  (none — no M2_* marker instance in the store)")
    } else {
        for (name, offset) in ladder {
            lines.append("  \(name) @0x\(String(format: "%x", offset))")
        }
    }
    let text = lines.joined(separator: "\n") + "\n"
    do {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        print("marker dump saved to \(path) (\(ladder.count) marker instance(s))")
    } catch {
        FileHandle.standardError.write(Data("ERROR: could not write marker dump to \(path): \(error)\n".utf8))
    }
}

func poll() {
    if let data = try? Data(contentsOf: serialURL), let text = String(data: data, encoding: .utf8) {
        if !text.isEmpty { lastText = text; feedInspector(text) }
        serialMatched = text.contains(expectLine)
        if let terminalMarker { terminalMatched = text.contains(terminalMarker) }
        if serialMatched && terminalMatched {
            if evidenceSince == nil { evidenceSince = Date() }
            if Date().timeIntervalSince(evidenceSince!) >= terminalDwell {
                if runner.vm.state != .running {
                    print("FAILURE: VM left the running state during terminal dwell (state=\(runner.vm.state.rawValue)).")
                    finish(success: false)
                    return
                }
                print("SUCCESS: requested serial evidence remained present during terminal dwell.")
                print("----- captured serial console -----")
                print(text)
                print("-----------------------------------")
                finish(success: true)
                return
            }
        } else {
            evidenceSince = nil
        }
    }

    captureScreenshotIfDue()

    // `--timeout 0` = no deadline (an interactive session runs until the
    // operator interrupts it); every existing invocation passes a positive
    // timeout, so this guard is behavior-preserving for the gate fleet.
    if timeout > 0 && Date() > deadline {
        if screenshotSaved && terminalMarker == nil {
            print("Timed out waiting for serial output, but a framebuffer screenshot was captured.")
            finish(success: true)
        } else {
            print("FAILURE: requested evidence not observed within \(Int(timeout))s (serial=\(serialMatched), terminal=\(terminalMatched)).")
            if !lastText.isEmpty { print("----- captured serial console (partial) -----\n\(lastText)\n---------------------------------------------") }
            finish(success: false)
        }
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
}

// Milestone six card G1 (claim 6053): the 5/10/15 s screenshot capture,
// shared by the evidence poll and scriptPoll so a gated scripted run can
// capture the guest framebuffer.
func captureScreenshotIfDue() {
    if screenshotPath != nil {
        let elapsed = Date().timeIntervalSince(startTime)
        if let next = captureTimes.first(where: { $0 <= elapsed }) {
            captureTimes.removeAll { $0 == next }
            captureScreenshot(at: next)
        }
    }
}

// Card G6 set_visible follow-on (claim 0487): marker-driven capture. Once
// the `--screenshot-after` marker appears in the serial log, capture the
// framebuffer under the stable `-after` name (once only). Deterministic
// where the fixed 5/10/15 s captures are not: the marker appears exactly
// when an EL0 hide/show transition has landed.
func captureScreenshotIfMarker(_ text: String) {
    if let marker = screenshotAfter, !screenshotAfterCaptured, text.contains(marker) {
        screenshotAfterCaptured = true
        captureScreenshotMarker("after")
    }
}

// M108b (#2325, ADR 0051): the lane session's 250 ms poll — drains
// CLIP_OUT records to the pasteboard, NOTIFY_OUT records to banners
// (M108d), and carries changeCount bumps out as CLIP_IN records. Runs on
// the main queue like every other runner poll, for the life of the
// process.
func hostIntTick() {
    hostClipboard?.tick()
    hostNotify?.tick()
    hostOutbox?.tick()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { hostIntTick() }
}

// Marker-driven pasteboard write (`--host-clip-in` + `--host-clip-in-after`):
// when the marker appears in the serial stream the text is written to the
// lane's pasteboard — a REAL host change the ordinary changeCount poll then
// carries in, not a seam that skips it. Fires once; the marker line carries
// the byte count, never the text (never-logged contract).
func fireHostClipInIfMarker(_ text: String) {
    guard let marker = hostClipInAfter, !hostClipInFired,
          text.contains(marker) else { return }
    if let body = hostClipInText {
        hostClipInFired = true
        guard let lane = hostClipboard else { return }
        let cc = lane.inject(body)
        FileHandle.standardOutput.write(Data("host-clip: inject len=\(body.utf8.count) changeCount=\(cc) after \"\(marker)\"\n".utf8))
    } else if let path = hostClipInFile, let mime = hostClipInMime {
        hostClipInFired = true
        guard let lane = hostClipboard else { return }
        let cc = lane.injectTyped(path: path, mime: mime)
        FileHandle.standardOutput.write(Data("host-clip: inject mime=\(mime) changeCount=\(cc) after \"\(marker)\"\n".utf8))
    }
}

// M108c (#2326, ADR 0051 D6): marker-driven file drop (`--host-drop-file` +
// `--host-drop-after`). When the marker appears in the serial stream the
// listed paths go through HostDrop.drop — the SAME function the NSView's
// performDragOperation calls — so a class-B run exercises the real handler:
// sanitize, caps, temp+rename into INBOX/, then the signed DROP notices.
// Fires once; the marker names a file COUNT, never contents (never-logged).
func fireHostDropIfMarker(_ text: String) {
    guard let marker = hostDropAfter, !hostDropFired, !hostDropFiles.isEmpty,
          text.contains(marker) else { return }
    hostDropFired = true
    guard let lane = hostDrop else {
        hostIntRefuse("drop", .laneDisabled)
        return
    }
    FileHandle.standardOutput.write(Data("host-drop: inject files=\(hostDropFiles.count) after \"\(marker)\"\n".utf8))
    lane.drop(urls: hostDropFiles.map { URL(fileURLWithPath: $0) })
}

// M81f (#1766): marker-driven host-side share mutation. When the
// --host-write-after marker appears in the serial stream, the runner writes
// the --host-write-content body into --host-write under the share dir
// (macOS-side, FileManager). The serial marker is CHOREOGRAPHY (when to
// mutate); how the guest comes to observe the change through the file
// channel is the behavior under test. Fires once; a failed write is named
// on stdout, never silent.
func fireHostWriteIfMarker(_ text: String) {
    guard let marker = hostWriteAfter, !hostWriteFired, let relPath = hostWritePath,
          text.contains(marker) else { return }
    hostWriteFired = true
    guard let root = cvcFileShareDir else { return }
    let url = URL(fileURLWithPath: root).appendingPathComponent(relPath)
    let body = hostWriteContent ?? ""
    let payload = body.hasSuffix("\n") ? body : body + "\n"
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: url, atomically: true, encoding: .utf8)
        FileHandle.standardOutput.write(Data("HOST-WRITE: wrote \(relPath) (\(payload.utf8.count) bytes) after \"\(marker)\"\n".utf8))
    } catch {
        FileHandle.standardOutput.write(Data("HOST-WRITE: FAILED for \(relPath): \(error)\n".utf8))
    }
}

// M114d (#2457): the inspector's feed — every poll hands it the same
// serial-log snapshot it just read (the model's offset ingest keeps only
// the new lines), plus a lane-directory seq scan when HostInt is armed:
// a record filename's seq counts whether or not the file survives to the
// next tick. Runs before fireHostCmdsIfMarker so a verb firing on a
// marker this tick already saw the line ingested — `saw=` in a receipt
// is then the model's truth, not a race.
func feedInspector(_ text: String) {
    inspector.ingest(serialText: text)
    if let laneDir = hostIntSession?.laneDir {
        for tag in [HostInt.Tag.clipIn, .clipOut, .notifyOut, .drop, .outbox, .notifyFocus] {
            for (_, seq) in HostInt.records(laneDir: laneDir, tag: tag) ?? [] {
                inspector.noteHostIntSeq(seq)
            }
        }
    }
}

// The runner's own `host-int: refuse` sites report to the model too —
// lane-internal refusals reach stdout only (the model doc names that
// limit); these are the refusals main.swift itself emits.
func hostIntRefuse(_ lane: String, _ reason: HostInt.Refusal) {
    HostInt.logRefuse(lane: lane, reason: reason)
    inspector.noteHostMarker("host-int: refuse lane=\(lane) reason=\(reason.rawValue)")
}

// M120e (#2562): one postmortem for every poll's "VM ended" observation —
// the inspector's card + auto-open and the `host-inspector: postmortem`
// receipt are the same model state the session window's drawer shows
// (the index's identical-seam rule: headless modes get the model truth,
// the session gets the real pane). Idempotent — a still-dead VM's repeat
// observation re-notes nothing.
func noteVMEnd(_ state: VZVirtualMachine.State) {
    inspector.noteStop(PostmortemCard(
        ending: state == .error ? .crashed : .stopped,
        state: "\(state.rawValue)",
        reason: vmDelegate.stopReasons.reason ?? StopReasonRecorder.noReason,
        serialLines: inspector.ingestedCount))
}

// M114a (#2454, index #2447): `--host-cmd-after <marker>:<verb>` — the
// headless mirror of the HostCommand bus. When a trigger's marker appears
// in the serial stream the verb dispatches through the SAME bus the
// AppKit menu items use, so a class-B run exercises the real seam instead
// of a synthesized click (index thesis 1). Each trigger fires once; the
// dispatch itself writes the `host-ui:` receipt.
func fireHostCmdsIfMarker(_ text: String) {
    // M139a: the shared per-session fire — the primary's list and bus.
    // A `vm<k>:`-bound trigger fires only on session k's own scan; the
    // `new-window@<path>` operand is staged by the shared body.
    fireHostCmdTriggers(&hostCmdTriggers, on: commandBus, session: 1, text: text)
}

// Claim 0680 (issue #523 item 3 capstone): marker-driven snapshot requests.
// When a registered --snapshot-after marker appears in the serial stream,
// enqueue one kind-4 control message; the guest composites and streams the
// scanout back over queue 4, and the delegate writes the raw BGRX file.
// The serial marker is CHOREOGRAPHY (when to ask), not evidence — the
// pixels themselves travel the custom-virtio channel.
func fireSnapshotsIfMarker(_ text: String) {
    #if SPIKE
    for i in snapshotTriggers.indices {
        if snapshotTriggers[i].fired { continue }
        let trigger = snapshotTriggers[i]
        guard text.contains(trigger.marker) else { continue }
        snapshotTriggers[i].fired = true
        guard #available(macOS 27.0, *) else { continue }
        FileHandle.standardOutput.write(Data("CVC-SNAP-REQ: kind-4 request scheduled after \"\(trigger.marker)\" transport=cv-input → \(trigger.outPath)\n".utf8))
        CustomVirtioSpike.deviceQueue.async {
            // Issue #1788: claim pendingSnapPath on the device queue, where
            // the stream's header message consumes it — so the teardown drain
            // (which reads the pair with a sync hop onto this same serial
            // queue) cannot observe a fired trigger whose request has not
            // been sent yet, and cannot miss one that has.
            CustomVirtioSpike.pendingSnapPath = trigger.outPath
            if !CustomVirtioSpike.enqueueMessageNow(
                CustomVirtioSpike.controlMessage(CustomVirtioSpike.inputKindSnapshotReq, payload: []),
                label: "snap-req → \(trigger.outPath)"
            ) {
                // The request never left the host: clear the pending path so
                // the drain does not wait out its whole window for a stream
                // that was never armed.
                CustomVirtioSpike.pendingSnapPath = nil
                FileHandle.standardError.write(Data("ERROR: CVC-SNAP-REQ: queue 3 pool empty at request time (\(trigger.outPath))\n".utf8))
            }
        }
    }
    #endif
}

// ---------------------------------------------------------------------------
// Console mode: streaming tee, stdin forwarding, signal-safe exit.
// ---------------------------------------------------------------------------

// Claim 2188: teardown serial drain. Exit paths used to sleep a fixed
// 0.4–0.5 s and hope the guest-output tee finished writing the pipe before
// exit() cut it off; the sleeps could not wait for pipe EOF because VZ
// keeps its copy of the write end open until process exit (observed).
// Instead the tee now runs a poll loop and stops on REQUEST: after the VM
// stops (every guest byte VZ will deliver is already in the pipe), the
// drain sets the stop flag and waits on `teeGroup` until the tee has
// flushed the pipe to empty and synchronized the log — so the LAST guest
// bytes always land before exit(). `teeRunning` is false in evidence mode
// (no duplex pipe there — VZ writes the serial log directly), so the drain
// is a structural no-op for evidence runs.
let teeGroup = DispatchGroup()
var teeRunning = false

// Claim 2188: the tee's poll loop checks this flag instead of waiting for
// pipe EOF — VZ keeps its copy of the pipe's write end open until process
// exit, so EOF never arrives at stop time. The flag is set only AFTER the
// VM has stopped, when every guest byte VZ will deliver is already in the
// pipe; the tee then drains the pipe to empty and signals `teeGroup`.
let teeStopLock = NSLock()
var teeStopRequested = false

func requestTeeStop() {
    teeStopLock.lock()
    teeStopRequested = true
    teeStopLock.unlock()
}

func teeStopIsRequested() -> Bool {
    teeStopLock.lock()
    defer { teeStopLock.unlock() }
    return teeStopRequested
}

/// Bounded wait for the guest-output tee to drain the pipe and flush the
/// serial log. Call AFTER the VM has stopped (or its serial attachment
/// closed): the tee then flushes the pipe to empty and signals the group.
/// No-op when no tee is running (evidence mode — VZ writes the log
/// directly).
func drainTeeBeforeExit(_ context: String, timeout: TimeInterval = 3.0) {
    // M139a: a run never exits with a sibling VM still flying — every
    // exit path drains the session fleet first (bounded).
    VMSessionRegistry.shared.shutdownAllAndWait()
    guard teeRunning else { return }
    requestTeeStop()
    if teeGroup.wait(timeout: .now() + timeout) == .timedOut {
        FileHandle.standardError.write(Data("WARNING: \(context): guest-output tee did not drain within \(Int(timeout))s — some tail bytes may be missing from the serial log\n".utf8))
    }
}

func startGuestOutputTee() {
    // Guest output → terminal + serial log. Streaming tee: each chunk is
    // written as it arrives; the log is never reloaded to show new bytes.
    let teeQueue = DispatchQueue(label: "virelaios.tee")
    var logWriteWarned = false
    teeRunning = true
    teeGroup.enter()
    teeQueue.async {
        defer { teeGroup.leave() } // the stopping drain finished — the exit path can proceed
        let fh = consoleOutputPipe.fileHandleForReading
        let fd = fh.fileDescriptor
        // Non-blocking reads: the stopping drain empties the pipe without
        // ever blocking on a writer (VZ) that stays open until exit.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var buf = [UInt8](repeating: 0, count: 4096)
        func emit(_ n: Int) {
            let data = Data(bytes: buf, count: n)
            try? FileHandle.standardOutput.write(contentsOf: data)
            consoleTCPEmit(data)
            do {
                try serialLogHandle?.write(contentsOf: data)
            } catch {
                if !logWriteWarned {
                    logWriteWarned = true
                    FileHandle.standardError.write(Data("WARNING: could not write guest output to \(serialLogPath): \(error)\n".utf8))
                }
            }
        }
        // Read everything currently in the pipe (non-blocking) and emit it.
        // Returns when the pipe is empty (EAGAIN), EOF, or on error.
        func drainPipe() {
            while true {
                var n: Int
                repeat { n = read(fd, &buf, buf.count) } while n < 0 && errno == EINTR
                if n > 0 {
                    emit(n)
                    continue
                }
                break // 0 = EOF, < 0 = EAGAIN or error — pipe drained
            }
        }
        while true {
            if teeStopIsRequested() {
                // Claim 2188: the VM has stopped — every guest byte VZ will
                // deliver is already in the pipe. Flush it to empty, then
                // end so drainTeeBeforeExit returns with the true tail.
                drainPipe()
                break
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 200)
            if pr < 0, errno == EINTR { continue }
            if pr > 0 {
                if (pfd.revents & Int16(POLLIN)) != 0 {
                    drainPipe()
                }
                if (pfd.revents & Int16(POLLHUP | POLLERR)) != 0 {
                    drainPipe() // write end closed — flush and finish
                    break
                }
            }
        }
        try? serialLogHandle?.synchronize()
    }
}

func startStdinForwarding() {
    // Host stdin → guest serial input (raw bytes, character-oriented).
    let inputQueue = DispatchQueue(label: "virelaios.stdin")
    inputQueue.async {
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            var n: Int
            repeat { n = read(STDIN_FILENO, &buf, buf.count) } while n < 0 && errno == EINTR
            if n <= 0 { break } // EOF: stop forwarding and close the guest input side
            let data = Data(bytes: buf, count: n)
            if debugInput {
                let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
                FileHandle.standardError.write(Data("input → serial attachment: \(data.count) bytes: \(hex)\n".utf8))
            }
            do { try consoleInputPipe.fileHandleForWriting.write(contentsOf: data) }
            catch { break }
        }
        try? consoleInputPipe.fileHandleForWriting.close()
    }
}

func startConsoleStreams() {
    startGuestOutputTee()
    // The stdin forwarder CLOSES the shared serial-input pipe's write end on
    // EOF, which would break a TCP client that connects later. When the TCP
    // console bridge owns input, stdin forwarding stays off.
    if consoleTCPPort == nil {
        startStdinForwarding()
    } else {
        startTCPConsoleBridge(port: consoleTCPPort!, bindHost: consoleTCPBind)
    }
}

// M50 TS4 (#1138, ADR 0024 D6): the host-initiated client's challenge
// answer. Lower-case hex of a byte array; the inverse decode; and the
// `VIRELAIOS-AUTH/1 <scheme> <hex-challenge>` line parser/answer.
func hexString(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef")
    var out = ""
    out.reserveCapacity(bytes.count * 2)
    for b in bytes {
        out.append(digits[Int(b >> 4)])
        out.append(digits[Int(b & 0xf)])
    }
    return out
}

func hexDecode(_ s: String) -> [UInt8]? {
    let chars = Array(s.utf8)
    guard chars.count % 2 == 0 else { return nil }
    func nib(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }
    var out = [UInt8]()
    out.reserveCapacity(chars.count / 2)
    var i = 0
    while i < chars.count {
        guard let hi = nib(chars[i]), let lo = nib(chars[i + 1]) else { return nil }
        out.append((hi << 4) | lo)
        i += 2
    }
    return out
}

/// Answer one `VIRELAIOS-AUTH/1 <scheme> <hex-challenge>` line with
/// `hex(HMAC-SHA256(secret, "<domain>" || 0x00 || challenge)) + "\n"` (the
/// TS4 acceptance primitive). `netTcpConnectMac` sends the pre-recorded hex
/// line instead (the captured-handshake replay path). Returns nil on a
/// malformed line or an unsupported scheme (Ed25519 host signing is the
/// recorded TS4 stretch) — the caller then closes honestly.
func netTcpAuthAnswer(challenge payload: [UInt8]) -> [UInt8]? {
    guard let newline = payload.firstIndex(of: 0x0a) else { return nil }
    var line = payload[0..<newline]
    if line.last == 0x0d { line = line.dropLast() }
    let parts = String(decoding: line, as: UTF8.self).split(separator: " ")
    guard parts.count == 3, parts[0] == "VIRELAIOS-AUTH/1" else { return nil }
    guard let challengeBytes = hexDecode(String(parts[2])) else { return nil }
    if let mac = netTcpConnectMac {
        return Array((mac + "\n").utf8)
    }
    guard parts[1] == "hmac-sha256", let secret = netTcpConnectSecret else { return nil }
    var message = Data("VIRELAIOS-AUTH/1 hmac-sha256".utf8)
    message.append(0)
    message.append(contentsOf: challengeBytes)
    let key = SymmetricKey(data: Data(secret.utf8))
    let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
    return Array((hexString(Array(mac)) + "\n").utf8)
}

// #1066 Stage 0 (issue #1066) + M70g G2 (#1459, ADR 0022 D2 amendment): the
// TCP console bridge. Still ONE client at a time, but the policy is now
// explicit and every open end is bounded:
//   * the accept loop keeps accepting while a client is served and answers
//     every extra connection `console-tcp: busy` + close (it no longer hangs
//     in the listen backlog); serving runs on its own serial queue;
//   * pre-auth reads carry a deadline (a connected-but-silent client — the
//     half-open shape — is dropped with `console-tcp: auth timeout`);
//   * the MAC compare is CryptoKit's constant-time check, never String ==;
//   * post-auth input is bounded per line (`console-tcp: line too long`);
//   * guest output reaches the client through `consoleTCPEmit` (the output
//     tee) under SO_SNDTIMEO — a client that stops reading is dropped, never
//     allowed to stall the tee; SO_KEEPALIVE probes a vanished peer;
//   * a client that dies mid-line has its partial line cancelled in the
//     guest (Ctrl-C — lineedit echoes `^C` and clears) so the next client
//     starts at a clean prompt — M52's no-zombie-seat lesson.
// Only `tcpClientFD`/`tcpClientServing` are shared; both live under the lock.
var tcpClientFD: Int32 = -1
var tcpClientServing = false
let tcpClientLock = NSLock()
let consoleTCPServeQueue = DispatchQueue(label: "virelaios.console-tcp.client")
/// Pre-auth deadline (ms): a client that never answers the challenge is dropped.
let consoleTCPAuthTimeoutMs = 10_000
/// Post-auth input bound: bytes without CR/LF before the client is dropped.
/// 4x the guest line editor's buffer (kernel/src/lineedit.zig `max_line` =
/// 256) — the guest refuses the excess anyway; this bounds the pump itself.
let consoleTCPLineMax = 1024
/// Output stall bound (s): a client whose socket send blocks this long is dropped.
let consoleTCPSendTimeoutSec = 2

func consoleTCPSay(_ msg: String) {
    print("  console-tcp: \(msg)")
    FileHandle.standardOutput.synchronizeFile()
}

/// Write every byte (EINTR-safe). False on error or SO_SNDTIMEO expiry.
func consoleTCPWriteAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    while off < bytes.count {
        let w = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress! + off, bytes.count - off) }
        if w < 0 && errno == EINTR { continue }
        if w <= 0 { return false }
        off += w
    }
    return true
}

func consoleTCPEmit(_ data: Data) {
    // The whole write happens UNDER the lock: the serving loop clears
    // tcpClientFD under the same lock before it closes, so guest output can
    // never land on a recycled fd number that now belongs to a fresh (and
    // possibly still unauthenticated) client. The hold is bounded by
    // SO_SNDTIMEO (2 s), which is also the stall bound below.
    tcpClientLock.lock()
    defer { tcpClientLock.unlock() }
    let fd = tcpClientFD
    guard fd >= 0 else { return }
    if !consoleTCPWriteAll(fd, [UInt8](data)) {
        // The send timed out or the peer is gone: drop the client rather
        // than let it stall the guest-output tee. shutdown() wakes the
        // serving loop's read, which then closes the fd.
        tcpClientFD = -1
        shutdown(fd, SHUT_RDWR)
        consoleTCPSay("client stalled (output not drained within \(consoleTCPSendTimeoutSec) s; client dropped)")
    }
}

/// Read one byte before `deadline`: 1 = byte, 0 = EOF, -1 = error, -2 = timeout.
func consoleTCPReadByteTimed(_ fd: Int32, _ byte: inout UInt8, deadline: DispatchTime) -> Int {
    while true {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline.uptimeNanoseconds > now else { return -2 }
        let remainMs = min((deadline.uptimeNanoseconds - now) / 1_000_000, UInt64(Int32.max))
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pr = poll(&pfd, 1, Int32(remainMs))
        if pr < 0 { if errno == EINTR { continue }; return -1 }
        if pr == 0 { return -2 }
        let r = read(fd, &byte, 1)
        if r < 0 && errno == EINTR { continue }
        return r
    }
}

func consoleTCPEndServing() {
    tcpClientLock.lock(); tcpClientServing = false; tcpClientLock.unlock()
}

/// Serve one accepted client to completion (auth, pump, teardown).
func consoleTCPServe(_ c: Int32) {
    var tv = timeval(tv_sec: consoleTCPSendTimeoutSec, tv_usec: 0)
    _ = setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    // Keepalive so a peer that vanished without a FIN (network drop, host
    // sleep) is detected: first probe after 15 s idle, then 3 x 5 s.
    var on: Int32 = 1
    _ = setsockopt(c, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))
    var kaIdle: Int32 = 15
    _ = setsockopt(c, IPPROTO_TCP, TCP_KEEPALIVE, &kaIdle, socklen_t(MemoryLayout<Int32>.size))
    var kaIntvl: Int32 = 5
    _ = setsockopt(c, IPPROTO_TCP, TCP_KEEPINTVL, &kaIntvl, socklen_t(MemoryLayout<Int32>.size))
    var kaCnt: Int32 = 3
    _ = setsockopt(c, IPPROTO_TCP, TCP_KEEPCNT, &kaCnt, socklen_t(MemoryLayout<Int32>.size))

    if let secret = consoleTCPSecret {
        // M50 TS4 (#1138, ADR 0024 D7): HMAC-SHA256 challenge-response. Send
        // a fresh 32-byte challenge line, read the client's one-line hex MAC
        // under the pre-auth deadline, and verify it in constant time. No
        // secret configured => byte-identical to the pre-TS4 bridge.
        var challenge = [UInt8](repeating: 0, count: 32)
        for i in 0..<challenge.count { challenge[i] = UInt8.random(in: 0...255) }
        let challengeLine = "VIRELAIOS-AUTH/1 hmac-sha256 " + hexString(challenge) + "\n"
        _ = consoleTCPWriteAll(c, Array(challengeLine.utf8))
        let deadline = DispatchTime.now() + .milliseconds(consoleTCPAuthTimeoutMs)
        var line = [UInt8]()
        var newline = false
        var timedOut = false
        var one: UInt8 = 0
        while line.count <= 160 {
            let r = consoleTCPReadByteTimed(c, &one, deadline: deadline)
            if r == -2 { timedOut = true; break }
            if r <= 0 { break }
            if one == 0x0a { newline = true; break }
            if one == 0x0d { continue }
            line.append(one)
        }
        if timedOut {
            _ = consoleTCPWriteAll(c, Array("console-tcp: auth timeout\n".utf8))
            close(c)
            consoleTCPEndServing()
            consoleTCPSay("auth timeout (no answer within \(consoleTCPAuthTimeoutMs / 1000) s; still listening)")
            return
        }
        var message = Data("VIRELAIOS-AUTH/1 hmac-sha256".utf8)
        message.append(0)
        message.append(contentsOf: challenge)
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = newline ? hexDecode(String(decoding: line, as: UTF8.self)) : nil
        let ok = mac.map { HMAC<SHA256>.isValidAuthenticationCode($0, authenticating: message, using: key) } ?? false
        guard ok else {
            _ = consoleTCPWriteAll(c, Array("console-tcp: auth failed\n".utf8))
            close(c)
            consoleTCPEndServing()
            consoleTCPSay("auth failed (MAC mismatch; still listening)")
            return
        }
        consoleTCPSay("client authenticated")
    }
    tcpClientLock.lock(); tcpClientFD = c; tcpClientLock.unlock()
    consoleTCPSay("client connected")
    var buf = [UInt8](repeating: 0, count: 4096)
    var lineLen = 0 // bytes of the guest's current line (since the last CR/LF)
    var dropReason: String?
    while true {
        var n: Int
        repeat { n = read(c, &buf, buf.count) } while n < 0 && errno == EINTR
        if n <= 0 { break }
        var overflow = false
        for i in 0..<n {
            if buf[i] == 0x0a || buf[i] == 0x0d {
                lineLen = 0
            } else {
                lineLen += 1
                if lineLen > consoleTCPLineMax { overflow = true; break }
            }
        }
        if overflow {
            // Nothing from the offending chunk reaches the guest.
            _ = consoleTCPWriteAll(c, Array("console-tcp: line too long\n".utf8))
            dropReason = "line too long (> \(consoleTCPLineMax) bytes without a newline; client dropped)"
            break
        }
        let data = Data(bytes: buf, count: n)
        do { try consoleInputPipe.fileHandleForWriting.write(contentsOf: data) } catch { break }
    }
    tcpClientLock.lock()
    if tcpClientFD == c { tcpClientFD = -1 }
    tcpClientLock.unlock()
    close(c)
    // Free the seat BEFORE the cancel below so the next client is admitted
    // as soon as the socket is gone; its bytes queue behind the cancel on
    // this serial queue, so ordering into the guest is preserved.
    consoleTCPEndServing()
    let midLine = lineLen > 0
    if midLine {
        // Leave no zombie seat state: cancel the partial line sitting in the
        // guest's editor so the next client starts at a clean prompt.
        try? consoleInputPipe.fileHandleForWriting.write(contentsOf: Data([0x03]))
    }
    if let dropReason { consoleTCPSay(dropReason) }
    consoleTCPSay("client disconnected" + (midLine ? " mid-line (partial line cancelled with ^C)" : "") + " (still listening)")
}

func startTCPConsoleBridge(port: UInt16, bindHost: String) {
    let listenQueue = DispatchQueue(label: "virelaios.console-tcp")
    listenQueue.async {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else {
            FileHandle.standardError.write(Data("WARNING: --console-tcp: socket() failed (errno=\(errno))\n".utf8))
            return
        }
        var reuse: Int32 = 1
        _ = setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if inet_pton(AF_INET, bindHost, &addr.sin_addr) != 1 {
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        }
        let bindRC = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindRC == 0 else {
            FileHandle.standardError.write(Data("WARNING: --console-tcp: bind \(bindHost):\(port) failed (errno=\(errno))\n".utf8))
            close(s)
            return
        }
        // Backlog > 1 so concurrent connectors are ACCEPTED and refused
        // explicitly (`busy`) instead of silently SYN-dropped.
        guard listen(s, 4) == 0 else {
            FileHandle.standardError.write(Data("WARNING: --console-tcp: listen failed (errno=\(errno))\n".utf8))
            close(s)
            return
        }
        consoleTCPSay("listening on \(bindHost):\(port) — connect with `nc \(bindHost) \(port)`")
        while true {
            var caddr = sockaddr()
            var clen = socklen_t(MemoryLayout<sockaddr>.size)
            let c = accept(s, &caddr, &clen)
            if c < 0 { if errno == EINTR { continue }; break }
            // A peer that closes while guest output is streaming makes the
            // tee's next write() raise SIGPIPE, which kills the whole runner
            // (exit 141) before the serving loop reads the EOF. Fail the write
            // with EPIPE instead, so the existing drop path handles it.
            var noSigPipe: Int32 = 1
            _ = setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            tcpClientLock.lock()
            let busy = tcpClientServing
            if !busy { tcpClientServing = true }
            tcpClientLock.unlock()
            if busy {
                // ADR 0022 D2 (M70g amendment): one client at a time, and
                // the second one is TOLD so — no backlog limbo.
                _ = consoleTCPWriteAll(c, Array("console-tcp: busy\n".utf8))
                close(c)
                consoleTCPSay("second client refused (busy; one client at a time)")
                continue
            }
            consoleTCPServeQueue.async { consoleTCPServe(c) }
        }
        close(s)
    }
}

// Claim 6684: scripted-input mode. Waits until the guest has reached the
// configured serial marker (the takeover terminal state by default), then
// forwards the script file's bytes exactly once into the serial attachment.
// The guest supplied its
// virtio RX buffer pre-exit, so nothing is lost while we wait; the settle
// delay only avoids racing the shell's very first poll.
func startScriptInput() {
    guard let scriptPath else { return }
    forwardScriptOnce(path: scriptPath, after: scriptAfter, label: "script", settle: 0.5)
}

// Claim 4613: the SECOND scripted phase. The primary --script is forwarded
// in ONE burst, so a command that must land AFTER a background program
// exits and is reaped (the long-lived gate re-execs USER.BIN into the
// freed pool slot) cannot be in the same burst. --script2 is forwarded
// once, after its own serial marker (the first USER.BIN's reap line),
// using the identical settle-then-forward machinery.
func startScript2Input() {
    guard let path = script2Path, let after = script2After else { return }
    forwardScriptOnce(path: path, after: after, label: "script2", settle: script2Delay)
}

// Card 3c (claim 7786): the THIRD scripted phase. The kill gate needs a
// post-reap snapshot — the `procs | pages | exec USER.BIN | procs` read
// that proves the killed process's pages returned and its slot was
// re-used — which must land AFTER the kill's reap line, so it cannot be
// in the one-burst primary script (claim 6684) or the claim-4613 second
// phase. --script3 is forwarded once after its own serial marker using
// the same settle-then-forward machinery.
func startScript3Input() {
    guard let path = script3Path, let after = script3After else { return }
    forwardScriptOnce(path: path, after: after, label: "script3", settle: script3Delay)
}

// Issue #179 follow-up (claim 8844): the activation wall (claim 4769) —
// VZ's synthesized-input translation is session-dependent (macOS 14+
// refuses programmatic focus-stealing while another app holds focus), so
// a dispatch into the view reports ok=true whether or not a single
// keystroke reaches the guest; a silent drop used to surface only as
// guest `events=0`. Report the delivery-relevant window state on every
// synthesized-keyboard path so a failing run is diagnosed at the host
// instead of guessed at. Observed 2026-08-18: a not-key window at the
// FIRST keystroke is consistent with BOTH events=0 (walled run) and a
// full events=6 delivery (the wall lifted mid-sequence) — so this report
// is evidence, not a prediction. Must be called on the main thread.
func reportKeyboardKeyState(_ view: VZVirtualMachineView, label: String) {
    let w = view.window
    let key = w?.isKeyWindow ?? false
    let main = w?.isMainWindow ?? false
    let active = NSApp.isActive
    if key {
        FileHandle.standardOutput.write(Data("\(label): window key=\(key) main=\(main) active=\(active) — key window, input should translate\n".utf8))
    } else {
        FileHandle.standardOutput.write(Data("\(label): window key=\(key) main=\(main) active=\(active) — the claim-4769 activation wall may be holding (VZ synthesized-keyboard delivery is session-dependent: the guest can report events=0 OR translate normally; observed both on 2026-08-18). If this run shows guest events=0, re-run when the machine is idle or after a fresh login; no code fix exists (VZ has no programmatic keyboard API).\n".utf8))
    }
}

// Marker-watch deadline policy for the scripted-input injectors
// (--input-key, --input-string): M73z (#1638) + #2703 — a gate may anchor
// input on a marker deep into a long run (boot 04's `gotabwm: alt-tab
// id=4` lands ~200 s in; its `gotabwm: tab close id=` lands ~160 s in),
// and a marker can never arrive after --timeout, so the session timeout
// is the honest ceiling. The 40 s floor keeps short-timeout sessions on
// the original window.
func inputMarkerWaitSeconds(sessionTimeout: TimeInterval) -> TimeInterval {
    max(40, sessionTimeout)
}

// Milestone seven card I2 (claim 4116): synthesize ONE host key event into
// the VZVirtualMachineView after the marker appears. VZ has no programmatic
// keyboard-injection API — VZUSBKeyboardConfiguration is driven only by a
// VZVirtualMachineView forwarding host key events — so the runner builds an
// NSEvent keyDown and dispatches it straight into the view (the host keycode
// maps to the guest HID usage inside VZ). This is the MINIMAL seam the I2
// gate needs to produce one deterministic HID report; the full scripted
// key-sequence surface that types into Road Pops is I3.
func startKeyInject() {
    guard let keyCode = inputKeyCode else { return }
    let q = DispatchQueue(label: "virelaios.keyinject")
    q.async {
        let marker = inputKeyAfter ?? "usb: enumerated"
        // M73z (#1638): timeout-aware deadline, mirroring claim 0142's
        // script-wait fix — a gate may anchor this key on a marker deep
        // into a long run (boot 04's `gotabwm: alt-tab id=4` lands ~200 s
        // in), and a marker can never arrive after --timeout.
        let waitSeconds = inputMarkerWaitSeconds(sessionTimeout: timeout)
        let waitDeadline = Date().addingTimeInterval(waitSeconds)
        var sent = false
        while Date() < waitDeadline {
            if let text = try? String(contentsOf: serialURL, encoding: .utf8),
               text.contains(marker) {
                Thread.sleep(forTimeInterval: 0.5) // let the armed ring settle
                #if SPIKE
                if viaVirtioEnabled {
                    // Claim 9588: ride the custom-virtio INPUT queue — no
                    // view, no NSEvent, no window (headless-safe). KeyDown
                    // only, the same single-report shape as the synthesized
                    // seam.
                    guard #available(macOS 27.0, *) else {
                        fail("--via-virtio requires macOS 27 (VZCustomVirtioDevice).")
                    }
                    guard let ch = CustomVirtioSpike.charFromMacCode(keyCode),
                          let (usage, shift) = CustomVirtioSpike.hidUsage(for: ch) else {
                        FileHandle.standardError.write(Data("ERROR: --via-virtio --input-key: no HID mapping for macOS keycode \(keyCode)\n".utf8))
                        return
                    }
                    let mods: UInt8 = shift ? CustomVirtioSpike.hidModShift : 0
                    FileHandle.standardOutput.write(Data("KEY-INJECT: keyCode \(keyCode) keyDown rides the custom-virtio INPUT queue after \"\(marker)\"\n".utf8))
                    CustomVirtioSpike.injectStrokes(
                        [CustomVirtioSpike.HidStroke(mods: mods, usage: usage, isDown: true)],
                        sequenceTag: "key-inject"
                    )
                    sent = true
                    break
                }
                #endif
                DispatchQueue.main.async {
                    guard let view = machineView else {
                        FileHandle.standardError.write(Data("ERROR: --input-key needs --display/--screenshot (no VZVirtualMachineView)\n".utf8))
                        return
                    }
                    let windowNumber = view.window?.windowNumber ?? 0
                    let now = ProcessInfo.processInfo.systemUptime
                    // KeyDown only (no keyUp): a single deterministic
                    // "key pressed" HID report, no up/down timing race.
                    if let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: now, windowNumber: windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: keyCode) {
                        view.keyDown(with: down)
                    }
                    FileHandle.standardOutput.write(Data("KEY-INJECT: keyCode \(keyCode) keyDown dispatched to the VZVirtualMachineView after \"\(marker)\"\n".utf8))
                    // Claim 8844: report the delivery-relevant window state so
                    // a silent VZ drop (not-key window) is diagnosed here.
                    reportKeyboardKeyState(view, label: "KEY-INJECT")
                }
                sent = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !sent {
            FileHandle.standardError.write(Data("ERROR: guest did not emit key-inject marker '\(marker)' within \(Int(waitSeconds))s; key not injected\n".utf8))
        }
    }
}

// Milestone seven card I3 (claim 6050): map an ASCII character to its macOS
// virtual keycode + whether shift is required. Only the usable subset the
// guest keymap accepts is covered; anything else returns nil (the caller
// fails honestly rather than inventing a keystroke). Enter is `\n`.
func macKey(for ch: Character) -> (UInt16, Bool)? {
    switch ch {
    case "a": return (0x00, false); case "b": return (0x0B, false)
    case "c": return (0x08, false); case "d": return (0x02, false)
    case "e": return (0x0E, false); case "f": return (0x03, false)
    case "g": return (0x05, false); case "h": return (0x04, false)
    case "i": return (0x22, false); case "j": return (0x26, false)
    case "k": return (0x28, false); case "l": return (0x25, false)
    case "m": return (0x2E, false); case "n": return (0x2D, false)
    case "o": return (0x1F, false); case "p": return (0x23, false)
    case "q": return (0x0C, false); case "r": return (0x0F, false)
    case "s": return (0x01, false); case "t": return (0x11, false)
    case "u": return (0x20, false); case "v": return (0x09, false)
    case "w": return (0x0D, false); case "x": return (0x07, false)
    case "y": return (0x10, false); case "z": return (0x06, false)
    case "A": return (0x00, true);  case "B": return (0x0B, true)
    case "C": return (0x08, true);  case "D": return (0x02, true)
    case "E": return (0x0E, true);  case "F": return (0x03, true)
    case "G": return (0x05, true);  case "H": return (0x04, true)
    case "I": return (0x22, true);  case "J": return (0x26, true)
    case "K": return (0x28, true);  case "L": return (0x25, true)
    case "M": return (0x2E, true);  case "N": return (0x2D, true)
    case "O": return (0x1F, true);  case "P": return (0x23, true)
    case "Q": return (0x0C, true);  case "R": return (0x0F, true)
    case "S": return (0x01, true);  case "T": return (0x11, true)
    case "U": return (0x20, true);  case "V": return (0x09, true)
    case "W": return (0x0D, true);  case "X": return (0x07, true)
    case "Y": return (0x10, true);  case "Z": return (0x06, true)
    case "0": return (0x1D, false); case "1": return (0x12, false)
    case "2": return (0x13, false); case "3": return (0x14, false)
    case "4": return (0x15, false); case "5": return (0x17, false)
    case "6": return (0x16, false); case "7": return (0x1A, false)
    case "8": return (0x1C, false); case "9": return (0x19, false)
    case " ": return (0x31, false)
    case "_": return (0x1B, true)
    case ".": return (0x2F, false); case ",": return (0x2B, false)
    case "/": return (0x2C, false); case "?": return (0x2C, true)
    case "-": return (0x1B, false)
    case "=": return (0x18, false); case "[": return (0x21, false)
    case "]": return (0x1E, false); case "\\": return (0x2A, false)
    case ";": return (0x29, false); case "'": return (0x27, false)
    case "`": return (0x32, false)
    case "\n": return (0x24, false) // Enter / Return
    default: return nil
    }
}

// Milestone eight card U2 (claim 1809): map one `--input-chords` token to a
// (keyCode, modifiers, characters) triple. A single printable char uses
// macKey (shift for uppercase); the named chords map to the macOS virtual
// keycodes for the nav cluster (function-key characters so VZ translates the
// keyCode to the guest HID usage), and ctrl-x maps to the letter's keycode
// with the .control modifier. nil = unknown chord (the caller fails honestly).
func macChord(_ token: String) -> (UInt16, NSEvent.ModifierFlags, String)? {
    switch token {
    case "return": return (0x24, [], "\r")
    case "space": return (0x31, [], " ")
    case "comma": return (0x2B, [], ",") // K12/K16: the CSV token separator cannot carry a literal comma
    case "ctrl-comma": return (0x2B, [.control], ",")
    case "ctrl-space": return (0x31, [.control], " ") // M37 DQ1: the God Menu summon chord
    case "tab": return (0x30, [], "\t")
    case "alt-tab": return (0x30, [.option], "\t") // WMS6 Gate A: Option+Tab
    case "alt-shift-tab": return (0x30, [.option, .shift], "\t")
    case "ctrl-tab": return (0x30, [.control], "\t") // M63r #1424
    case "ctrl-shift-tab": return (0x30, [.control, .shift], "\t")
    // M80k (#1727): the terminal's full-RIS chord (macOS path; 'r' = 0x0F).
    case "ctrl-shift-alt-r": return (0x0F, [.control, .shift, .option], "r")
    case "up": return (0x7E, [], "\u{F700}")
    case "down": return (0x7D, [], "\u{F701}")
    case "left": return (0x7B, [], "\u{F702}")
    case "right": return (0x7C, [], "\u{F703}")
    case "home": return (0x73, [], "\u{F729}")
    case "end": return (0x77, [], "\u{F72B}")
    case "delete": return (0x75, [], "\u{F728}")
    case "backspace": return (0x33, [], "\u{7F}") // M68a (#1449): macOS keycode 0x33 = Delete/Backspace; 0x7F is the byte a terminal expects
    case "pageup": return (0x74, [], "\u{F72C}")
    case "pagedown": return (0x79, [], "\u{F72D}")
    case "escape": return (0x35, [], "\u{1B}")
    case "insert": return (0x72, [], "\u{F729}")
    case "f1": return (0x7A, [], "\u{F704}")
    case "f2": return (0x78, [], "\u{F705}")
    case "f3": return (0x63, [], "\u{F706}")
    case "f4": return (0x76, [], "\u{F707}")
    case "f5": return (0x60, [], "\u{F708}")
    case "f6": return (0x61, [], "\u{F709}")
    case "f7": return (0x62, [], "\u{F70A}")
    case "f8": return (0x64, [], "\u{F70B}")
    case "f9": return (0x6D, [], "\u{F70C}")
    case "f10": return (0x67, [], "\u{F70D}")
    case "f11": return (0x6F, [], "\u{F70E}")
    case "f12": return (0x6A, [], "\u{F70F}")
    default:
        if token.hasPrefix("ctrl-shift-"), token.count == 12 {
            let letter = token[token.index(token.startIndex, offsetBy: 11)]
            if let (code, _) = macKey(for: letter) {
                return (code, [.control, .shift], String(letter))
            }
        }
        if token.hasPrefix("ctrl-"), token.count == 6 {
            let letter = token[token.index(token.startIndex, offsetBy: 5)]
            if let (code, _) = macKey(for: letter) {
                return (code, .control, String(letter))
            }
        }
        if token.count == 1, let (code, shift) = macKey(for: token[token.startIndex]) {
            return (code, shift ? .shift : [], token)
        }
        return nil
    }
}

// Milestone eight card U2 (claim 1809): type the `--input-chords` sequence
// into the VZVirtualMachineView once the marker appears — keyDown + keyUp
// per chord, mirroring the --input-string timing (one report per Road Pops
// present cadence). This is how arrows/Ctrl chords reach the I3 keymap on
// real hardware.
func startChordInject() {
    guard let csv = inputChords else { return }
    let q = DispatchQueue(label: "virelaios.chords")
    q.async {
        let marker = inputChordsAfter ?? "userspace: el0=1"
        // #990 (claim #997): the marker deadline was a hardcoded 60 s — the
        // WM2 gate's choreography (loop-ok + 20 s settle) lands chord-go at
        // ~88 s, so the chords were NEVER typed ("guest did not emit
        // chord-seq marker ... within 60s") and every WM boot failed its
        // checks with key_fan=0. Key the watcher to the run deadline like
        // every other marker watcher.
        let waitDeadline = deadline
        var sent = false
        while Date() < waitDeadline {
            if let log = try? String(contentsOf: serialURL, encoding: .utf8), log.contains(marker) {
                Thread.sleep(forTimeInterval: 1.0) // let the armed ring settle
                #if SPIKE
                if viaVirtioEnabled && !chordsViaView {
                    // Claim 9588: chords ride the custom-virtio INPUT queue —
                    // keyDown + keyUp per token as HID reports, no view, no
                    // window, headless-safe. (--chords-view forces the view
                    // path below even when this queue is attached.)
                    guard #available(macOS 27.0, *) else {
                        fail("--via-virtio requires macOS 27 (VZCustomVirtioDevice).")
                    }
                    var strokes: [CustomVirtioSpike.HidStroke] = []
                    for token in csv.split(separator: ",").map(String.init) {
                        guard let (mods, usage) = CustomVirtioSpike.hidChord(token) else {
                            FileHandle.standardError.write(Data("ERROR: --via-virtio --input-chords: no HID mapping for chord '\(token)'\n".utf8))
                            FileHandle.standardOutput.write(Data("CHORD-SEQ: aborted (unknown chord) ok=false\n".utf8))
                            return
                        }
                        strokes.append(CustomVirtioSpike.HidStroke(mods: mods, usage: usage, isDown: true))
                        strokes.append(CustomVirtioSpike.HidStroke(mods: 0, usage: 0, isDown: false))
                    }
                    FileHandle.standardOutput.write(Data("CHORD-SEQ: typed \(csv.debugDescription) over the custom-virtio INPUT queue after \"\(marker)\" transport=cv-input\n".utf8))
                    CustomVirtioSpike.injectStrokes(strokes, sequenceTag: "chord-seq")
                    sent = true
                    break
                }
                #endif
                guard let view = machineView else {
                    FileHandle.standardError.write(Data("ERROR: --input-chords needs --display/--screenshot (no VZVirtualMachineView)\n".utf8))
                    return
                }
                let windowNumber = view.window?.windowNumber ?? 0
                var events: [(type: NSEvent.EventType, code: UInt16, mods: NSEvent.ModifierFlags, chars: String)] = []
                var allOk = true
                for token in csv.split(separator: ",").map(String.init) {
                    guard let (code, mods, chars) = macChord(token) else {
                        FileHandle.standardError.write(Data("ERROR: --input-chords: no mapping for chord '\(token)'\n".utf8))
                        allOk = false
                        break
                    }
                    events.append((.keyDown, code, mods, chars))
                    events.append((.keyUp, code, mods, chars))
                }
                if allOk {
                    // Chain the events: each keyDown/keyUp is scheduled only
                    // AFTER the previous one fires, so the 3 s gaps are real
                    // wall-clock gaps. Scheduling every event up front with
                    // increasing asyncAfter deadlines lets a busy main queue
                    // (VM display updates) fire several in a burst, which
                    // drops/reorders reports at the guest's single-pending-
                    // report interrupt-IN endpoint (observed claim-time).
                    var remaining = events
                    func fireNext(after delay: Double, first: Bool) {
                        if remaining.isEmpty {
                            FileHandle.standardOutput.write(Data("CHORD-SEQ: typed \(csv.debugDescription) into the VZVirtualMachineView after \"\(marker)\" ok=true\n".utf8))
                            return
                        }
                        if first, let view = machineView {
                            // Claim 8844: same delivery-state report as
                            // KEY-SEQ, before the first chord lands.
                            reportKeyboardKeyState(view, label: "CHORD-SEQ")
                        }
                        let evt = remaining.removeFirst()
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            let t = ProcessInfo.processInfo.systemUptime
                            if let e = NSEvent.keyEvent(with: evt.type, location: .zero, modifierFlags: evt.mods, timestamp: t, windowNumber: windowNumber, context: nil, characters: evt.chars, charactersIgnoringModifiers: evt.chars, isARepeat: false, keyCode: evt.code) {
                                if evt.type == .keyDown {
                                    view.keyDown(with: e)
                                } else {
                                    view.keyUp(with: e)
                                }
                            }
                            fireNext(after: inputChordsDelay, first: false)
                        }
                    }
                    fireNext(after: 0.0, first: true)
                } else {
                    FileHandle.standardOutput.write(Data("CHORD-SEQ: aborted (unknown chord) ok=false\n".utf8))
                }
                sent = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !sent {
            FileHandle.standardError.write(Data("ERROR: guest did not emit chord-seq marker '\(marker)' before the run deadline; chords not typed\n".utf8))
        }
    }
}

// Milestone eight cards U4/U5 (claims 4993/0935): the pointer-synthesis
// seam. Once the marker appears, each "<x>,<y>[,c]" step synthesizes one
// mouseMoved NSEvent (plus a left mouseDown/mouseUp pair when the click
// flag 'c' is set) and dispatches it to the VZVirtualMachineView — VZ has
// no programmatic pointer API, exactly like the I3 keyboard seam. 3 s per
// step; the guest's pointer reports ride the same single-TRB interrupt-IN
// arming as the keyboard.
// Pointer-route probe (claim 4769): a VZVirtualMachineView subclass that
// logs which NSResponder mouse methods actually fire, so a probe run can
// tell "the event never reached the view" from "VZ dropped it internally".
final class TraceView: VZVirtualMachineView {
    var trace = false
    var nativeInput = false
    /// M108c (#2326, ADR 0051 D4): the file-drop surface. Set only when
    /// --host-drop armed the lane AND this view registered .fileURL — a
    /// flags-off view never advertises a drop affordance.
    var dropHandler: (([URL]) -> Void)?
    private var nativeKeyLogged = false
    private var nativeClickLogged = false

    private func reportNativeInput(_ kind: String) {
        // Bounded receipts, never key characters or document contents.
        print("input: host-view \(kind) key=\(window?.isKeyWindow ?? false) responder=\(window?.firstResponder === self) active=\(NSApp.isActive)")
        fflush(stdout)
    }

    override func keyDown(with event: NSEvent) {
        if nativeInput && !nativeKeyLogged {
            nativeKeyLogged = true
            reportNativeInput("keyDown")
        }
        super.keyDown(with: event)
    }

    // macOS click-through: the first click on an INACTIVE app's window is
    // swallowed to activate the app and never reaches the view. Synthesized
    // posts hit exactly this wall (the app can never become active from a
    // CLI process). Accepting the first mouse makes the click deliver
    // anyway, so the posted event reaches the VZ view's responder methods
    // regardless of activation state.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseMoved(with event: NSEvent) {
        if trace { pmo("TRACE mouseMoved inW=(\(event.locationInWindow))") }
        super.mouseMoved(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        if trace { pmo("TRACE mouseDragged inW=(\(event.locationInWindow))") }
        super.mouseDragged(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        if nativeInput && !nativeClickLogged {
            nativeClickLogged = true
            reportNativeInput("mouseDown")
        }
        if trace { pmo("TRACE mouseDown inW=(\(event.locationInWindow)) key=\(event.window?.isKeyWindow ?? false)") }
        super.mouseDown(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        if trace { pmo("TRACE mouseUp inW=(\(event.locationInWindow)) key=\(event.window?.isKeyWindow ?? false)") }
        super.mouseUp(with: event)
    }
    override func mouseEntered(with event: NSEvent) {
        if trace { pmo("TRACE mouseEntered") }
        super.mouseEntered(with: event)
    }

    // NSDraggingDestination: the drop lands ONLY while the lane armed this
    // surface — the copy cursor is the affordance, and the URLs go through
    // the one handler --host-drop-file also calls (ADR 0051 D4's "same
    // function" rule).
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dropHandler != nil else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let handler = dropHandler else { return false }
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        handler(urls)
        return true
    }
}

// M114b (#2455): the session window's capture-keys verb toggles the view
// through the HostKeyCapturing seam — VMAppKit stays Virtualization-free,
// so the retroactive conformance lives here where Virtualization is
// already imported. `capturesSystemKeys` is inherited from
// VZVirtualMachineView and satisfies the protocol as-is.
extension TraceView: HostKeyCapturing {}

func pmo(_ s: String) {
    FileHandle.standardOutput.write(Data("PTR-TRACE: \(s)\n".utf8))
}

/// Deliver one synthesized pointer NSEvent to the VZ view over the
/// configured route (see --pointer-route). The "cg" route re-posts a real
/// CGEvent at the HID tap in GLOBAL screen coordinates — the OS delivers
/// it to the key window exactly like a physical mouse. The "pid" route
/// posts the SAME CGEvent straight into OUR OWN application queue
/// (CGEventPostToPid needs no frontmost window — it is hit-tested against
/// our key window, i.e. the VZ window). The "direct" route calls the
/// NSResponder mouse methods VZ implements directly on the view — the
/// exact pattern the keyboard seam uses. The claim-4769 probe also added
/// "warp" (warp the real cursor over the view, then trusted HID-tap
/// post), "diag" (force key + first responder, then sendEvent), and
/// "drag" (moves as leftMouseDragged). All of them hit the same
/// activation wall: VZ only translates for its KEY window, and macOS 14+
/// refuses programmatic focus-stealing from a background process — see
/// claim 4769 (historical — in git history).
func deliverPointerEvent(_ view: VZVirtualMachineView, _ e: NSEvent) {
    switch pointerRoute {
    case "direct":
        switch e.type {
        case .leftMouseDown: view.mouseDown(with: e)
        case .leftMouseUp: view.mouseUp(with: e)
        default: view.mouseMoved(with: e)
        }
    case "pid":
        if let w = view.window {
            let glob = w.convertToScreen(NSRect(x: e.locationInWindow.x, y: e.locationInWindow.y, width: 1, height: 1)).origin
            guard let screen = NSScreen.main else { return }
            let cgPt = CGPoint(x: glob.x, y: screen.frame.maxY - glob.y)
            let src = CGEventSource(stateID: .hidSystemState)
            let type: CGEventType = e.type == .leftMouseDown ? .leftMouseDown : (e.type == .leftMouseUp ? .leftMouseUp : .mouseMoved)
            if let cg = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: cgPt, mouseButton: .left) {
                pmo("pid-post \(type) at (\(Int(cgPt.x)),\(Int(cgPt.y)))")
                cg.postToPid(pid_t(getpid()))
            }
        }
    case "warp":
        // Physical-mouse precondition: the REAL cursor must be over the
        // view for hit-tested delivery. Warp it into the window's center
        // (no Accessibility needed for the warp), then post the event via
        // the HID tap (trust needed; checked per post). If VZ tracks the
        // global cursor location rather than the event field, this is the
        // missing piece.
        if let w = view.window {
            let center = w.convertToScreen(NSRect(x: w.contentView!.bounds.midX, y: w.contentView!.bounds.midY, width: 1, height: 1)).origin
            guard let screen = NSScreen.main else { return }
            CGWarpMouseCursorPosition(CGPoint(x: center.x, y: screen.frame.maxY - center.y))
            pmo("warped cursor to (\(Int(center.x)),\(Int(screen.frame.maxY - center.y)))")
            if CGPreflightPostEventAccess() {
                let local = e.locationInWindow
                let glob = w.convertToScreen(NSRect(x: local.x, y: local.y, width: 1, height: 1)).origin
                let cgPt = CGPoint(x: glob.x, y: screen.frame.maxY - glob.y)
                let src = CGEventSource(stateID: .hidSystemState)
                let type: CGEventType = e.type == .leftMouseDown ? .leftMouseDown : (e.type == .leftMouseUp ? .leftMouseUp : .mouseMoved)
                if let cg = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: cgPt, mouseButton: .left) {
                    cg.post(tap: .cghidEventTap)
                }
            } else {
                pmo("warp skipped post (untrusted)")
            }
        }
    case "app":
        NSApp.postEvent(e, atStart: true)
    case "diag":
        // Route-minus-buried-context probe: force the VZ window to be key,
        // frontmost, and first responder (the one thing physical-mouse
        // users have and synthesized routes may lack), then sendEvent.
        if let w = view.window {
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(view)
            w.acceptsMouseMovedEvents = true
            NSApp.activate(ignoringOtherApps: true)
            pmo("diag key=\(w.isKeyWindow) main=\(w.isMainWindow) fr=\(w.firstResponder === view)")
            w.sendEvent(e)
        }
    case "drag":
        // VZ's pointer tracking may bind on mouseDragged (the path a real
        // drag takes) rather than mouseMoved. Convert moves into
        // leftMouseDragged events (button state down), delivered to the
        // window like a real drag sequence.
        if e.type == .mouseMoved {
            let loc = e.locationInWindow
            let t = ProcessInfo.processInfo.systemUptime
            if let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: loc, modifierFlags: [], timestamp: t, windowNumber: e.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1.0) {
                if let w = view.window {
                    w.sendEvent(drag)
                } else {
                    view.mouseDragged(with: drag)
                }
            }
        } else if let w = view.window {
            w.sendEvent(e)
        } else {
            view.mouseMoved(with: e)
        }
    case "cg":
        if let w = view.window {
            // Accessibility trust is the gating permission: without it the
            // HID-tap post is silently dropped (the claim-4993 observation).
            // Report the truth once so a gate can distinguish "untrusted"
            // from "trusted but no report".
            let trusted = CGPreflightPostEventAccess()
            if !trusted {
                FileHandle.standardOutput.write(Data("PTR-TRUST: untrusted (cg route needs Accessibility for the terminal) skipped-post\n".utf8))
                return
            }
            // Window-local (bottom-left) -> global AppKit -> CG (top-left).
            let local = e.locationInWindow
            let glob = w.convertToScreen(NSRect(x: local.x, y: local.y, width: 1, height: 1)).origin
            guard let screen = NSScreen.main else { return }
            let cgPt = CGPoint(x: glob.x, y: screen.frame.maxY - glob.y)
            let src = CGEventSource(stateID: .hidSystemState)
            let type: CGEventType = e.type == .leftMouseDown ? .leftMouseDown : (e.type == .leftMouseUp ? .leftMouseUp : .mouseMoved)
            let cg = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: cgPt, mouseButton: .left)
            cg?.post(tap: .cghidEventTap)
            pmo("cg-post \(type) at (\(Int(cgPt.x)),\(Int(cgPt.y))) key=\(w.isKeyWindow) active=\(NSApp.isActive) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil") cursor=\(Int(NSEvent.mouseLocation.x)),\(Int(NSEvent.mouseLocation.y))")
        }
    default: // "window"
        if let w = view.window {
            w.sendEvent(e)
        } else {
            view.mouseMoved(with: e)
        }
    }
}

func startPointerInject() {
    guard let script = pointerScript else { return }
    if pointerRequestTrust && !AXIsProcessTrusted() {
        // Prompt the system to grant Accessibility to the responsible
        // process (the terminal). Returns immediately; the user grants in
        // System Settings and re-runs. The cg route checks trust per post
        // and reports PTR-TRUST honestly either way.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let nowTrusted = AXIsProcessTrustedWithOptions(opts)
        FileHandle.standardOutput.write(Data("PTR-TRUST: requested accessibility prompt, now-trusted=\(nowTrusted ? 1 : 0)\n".utf8))
    }
    let q = DispatchQueue(label: "virelaios.ptrseq")
    q.async {
        let marker = pointerAfter ?? "tasks user-el0 reaped"
        let waitDeadline = deadline // #990: was a hardcoded 120 s (same late-marker class)
        var sent = false
        while Date() < waitDeadline {
            if let log = try? String(contentsOf: serialURL, encoding: .utf8), log.contains(marker) {
                Thread.sleep(forTimeInterval: 0.5)
                guard let view = machineView else {
                    FileHandle.standardError.write(Data("ERROR: --pointer needs --display/--screenshot (no VZVirtualMachineView)\n".utf8))
                    return
                }
                let windowNumber = view.window?.windowNumber ?? 0
                // Resolve every step up front; a malformed step aborts
                // before any event fires (fail honestly, invent nothing).
                var steps: [(x: CGFloat, y: CGFloat, click: Bool)] = []
                for part in script.split(separator: ";") {
                    let fields = part.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
                    guard fields.count >= 2, let gx = Double(fields[0]), let gy = Double(fields[1]), gx >= 0, gy >= 0, gx <= 1280, gy <= 720 else {
                        FileHandle.standardError.write(Data("ERROR: --pointer step '\(part)' is not <x>,<y>[,c] with 0<=x<=1280, 0<=y<=720\n".utf8))
                        steps = []
                        break
                    }
                    let click = fields.count >= 3 && (fields[2] == "c" || fields[2] == "1")
                    steps.append((CGFloat(gx), CGFloat(gy), click))
                }
                if !steps.isEmpty {
                    let vh = view.bounds.height
                    // A real mouse always ENTERS the window before moving —
                    // synthesized moves alone were observed not to wake VZ's
                    // pointer tracking. Lead with a mouseEntered over the
                    // view (claim-time experiment, card U4).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let t = ProcessInfo.processInfo.systemUptime
                        let loc = NSPoint(x: vh * 0 + 8, y: vh - 8)
                        if let e = NSEvent.enterExitEvent(with: .mouseEntered, location: loc, modifierFlags: [], timestamp: t, windowNumber: windowNumber, context: nil, eventNumber: 1, trackingNumber: 1, userData: nil) {
                            if let w = view.window {
                                w.sendEvent(e)
                            } else {
                                view.mouseEntered(with: e)
                            }
                            FileHandle.standardOutput.write(Data("PTR-EVT entered\n".utf8))
                        }
                    }
                    var delay: Double = 3.0
                    for st in steps {
                        let s = st
                        // Guest pixels are top-left origin; AppKit view
                        // coordinates are bottom-left — flip Y.
                        let loc = NSPoint(x: s.x, y: vh - s.y)
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            let t = ProcessInfo.processInfo.systemUptime
                            if let e = NSEvent.mouseEvent(with: .mouseMoved, location: loc, modifierFlags: [], timestamp: t, windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                                deliverPointerEvent(view, e)
                                FileHandle.standardOutput.write(Data("PTR-EVT move \(Int(s.x)),\(Int(s.y))\n".utf8))
                            }
                        }
                        delay += 3.0
                        if s.click {
                            for (type, name) in [(NSEvent.EventType.leftMouseDown, "down"), (NSEvent.EventType.leftMouseUp, "up")] {
                                let ty = type
                                let nm = name
                                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                    let t = ProcessInfo.processInfo.systemUptime
                                    if let e = NSEvent.mouseEvent(with: ty, location: loc, modifierFlags: [], timestamp: t, windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: ty == .leftMouseDown ? 1.0 : 0.0) {
                                        deliverPointerEvent(view, e)
                                        FileHandle.standardOutput.write(Data("PTR-EVT click \(nm) \(Int(s.x)),\(Int(s.y))\n".utf8))
                                    }
                                }
                                delay += 3.0
                            }
                        }
                    }
                    FileHandle.standardOutput.write(Data("PTR-SEQ: \(steps.count) pointer steps scheduled after \"\(marker)\" ok=true\n".utf8))
                } else {
                    FileHandle.standardOutput.write(Data("PTR-SEQ: aborted (malformed step) ok=false\n".utf8))
                }
                sent = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !sent {
            FileHandle.standardError.write(Data("ERROR: guest did not emit pointer marker '\(marker)' within 120s; pointer steps not sent\n".utf8))
        }
    }
}

// Claim 9367: the --pointer-virtio sequence — pointer injection over the
// custom-virtio INPUT queue (kind-2 absolute-pointer messages), HEADLESS:
// no view, no window, no NSEvent/CGEvent anywhere. Same step grammar and
// guest-pixel coordinate space as --pointer ("x,y[,c]" steps, 0<=x<=1280,
// 0<=y<=720); each pixel coord is converted to the HID absolute 0..32767
// logical space the guest's map_pointer_axis expects. The sequence is
// scheduled once `--pointer-virtio-after <marker>` appears in the serial
// log (deterministic choreography, not a sleep).
func startPointerVirtioInject() {
    guard let script = pointerVirtioScript else { return }
    let q = DispatchQueue(label: "virelaios.ptrcv")
    q.async {
        let marker = pointerVirtioAfter ?? "winloop: present ok"
        let waitDeadline = deadline // #990: was a hardcoded 120 s (same late-marker class)
        var sent = false
        while Date() < waitDeadline {
            if let log = try? String(contentsOf: serialURL, encoding: .utf8), log.contains(marker) {
                Thread.sleep(forTimeInterval: 0.5)
                #if SPIKE
                guard #available(macOS 27.0, *) else {
                    fail("--pointer-virtio requires macOS 27 (VZCustomVirtioDevice).")
                }
                // Resolve every step up front; a malformed step aborts
                // before any message fires (fail honestly, invent nothing).
                var steps: [CustomVirtioSpike.PtrStep] = []
                for part in script.split(separator: ";") {
                    let fields = part.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
                    guard fields.count >= 2, let gx = Double(fields[0]), let gy = Double(fields[1]), gx >= 0, gy >= 0, gx <= 1280, gy <= 720 else {
                        FileHandle.standardError.write(Data("ERROR: --pointer-virtio step '\(part)' is not <x>,<y>[,c|d|u|rc] with 0<=x<=1280, 0<=y<=720\n".utf8))
                        steps = []
                        break
                    }
                    // Grammar: bare = move (buttons 0); `c`/`1` = click
                    // (down+up at one point, the claim 9367 shape); `d`/`2`
                    // = press-and-hold (down); `u`/`3` = release (up);
                    // `rc` = right-click (buttons bit1 down+up, M124d's
                    // context-menu leg). The WMS5 drag choreography is
                    // `<title>,d ; x1,y1 ; x2,y2 ; ...,u` — held moves
                    // between down and up.
                    let mode: CustomVirtioSpike.PtrStep.Mode
                    if fields.count >= 3 && (fields[2] == "d" || fields[2] == "2") {
                        mode = .down
                    } else if fields.count >= 3 && (fields[2] == "u" || fields[2] == "3") {
                        mode = .up
                    } else if fields.count >= 3 && (fields[2] == "c" || fields[2] == "1") {
                        mode = .click
                    } else if fields.count >= 3 && fields[2] == "rc" {
                        mode = .rightClick
                    } else if fields.count >= 3 && fields[2] == "mc" {
                        mode = .middleClick
                    } else {
                        mode = .move
                    }
                    // Guest pixels -> HID absolute logical (the inverse of
                    // driving_award.map_pointer_axis on the 1280x720 fb).
                    let lx = UInt16(min(32767, Int((gx * 32768.0 / 1280.0).rounded())))
                    let ly = UInt16(min(32767, Int((gy * 32768.0 / 720.0).rounded())))
                    steps.append(CustomVirtioSpike.PtrStep(x: lx, y: ly, mode: mode))
                }
                if !steps.isEmpty {
                    FileHandle.standardOutput.write(Data("PTR-CV-SEQ: \(steps.count) pointer steps scheduled after \"\(marker)\" transport=cv-input\n".utf8))
                    CustomVirtioSpike.injectPointerSteps(steps, sequenceTag: "ptr-seq")
                } else {
                    FileHandle.standardOutput.write(Data("PTR-CV-SEQ: aborted (malformed step) ok=false\n".utf8))
                }
                sent = true
                break
                #else
                fail("--pointer-virtio requires the SPIKE build (zig build spike-virtio).")
                #endif
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if !sent {
            FileHandle.standardError.write(Data("ERROR: guest did not emit pointer-virtio marker '\(marker)' within 120s; pointer steps not sent\n".utf8))
        }
    }
}

// Milestone seven card I3 (claim 6050): type the `--input-string` text into
// the VZVirtualMachineView once the marker appears — keyDown + keyUp per
// char (shift for uppercase, `\n` = Enter). VZ has no programmatic keyboard
// API, so each keystroke is a synthesized NSEvent dispatched to the view.
func startKeyStringInject() {
    guard let text = inputString else { return }
    let q = DispatchQueue(label: "virelaios.keyseq")
    q.async {
        let marker = inputStringAfter ?? "virelai> "
        // #2703: timeout-aware deadline, the same M73z (#1638) fix
        // startKeyInject already carries — a gate may anchor the string on a
        // marker deep into a long run (go-dogfood boot 04's
        // `gotabwm: tab close id=` lands ~160 s in, after the demo's
        // auto-close and the state-ask drain on silent apps), and a marker
        // can never arrive after --timeout. The 40 s floor keeps every
        // short-timeout session's window unchanged.
        let waitSeconds = inputMarkerWaitSeconds(sessionTimeout: timeout)
        let waitDeadline = Date().addingTimeInterval(waitSeconds)
        var sent = false
        while Date() < waitDeadline {
            if let log = try? String(contentsOf: serialURL, encoding: .utf8), log.contains(marker) {
                Thread.sleep(forTimeInterval: 0.5) // let the armed ring settle
                #if SPIKE
                if viaVirtioEnabled {
                    // Claim 9588: type through the custom-virtio INPUT queue
                    // — keyDown + keyUp per char as HID reports, no view, no
                    // window, headless-safe.
                    guard #available(macOS 27.0, *) else {
                        fail("--via-virtio requires macOS 27 (VZCustomVirtioDevice).")
                    }
                    var strokes: [CustomVirtioSpike.HidStroke] = []
                    for ch in text {
                        guard let (usage, shift) = CustomVirtioSpike.hidUsage(for: ch) else {
                            FileHandle.standardError.write(Data("ERROR: --via-virtio --input-string: no HID usage for '\(ch)'\n".utf8))
                            FileHandle.standardOutput.write(Data("KEY-SEQ: aborted (no HID usage) ok=false\n".utf8))
                            return
                        }
                        let mods: UInt8 = shift ? CustomVirtioSpike.hidModShift : 0
                        strokes.append(CustomVirtioSpike.HidStroke(mods: mods, usage: usage, isDown: true))
                        strokes.append(CustomVirtioSpike.HidStroke(mods: 0, usage: 0, isDown: false))
                    }
                    FileHandle.standardOutput.write(Data("KEY-SEQ: typed \(text.debugDescription) over the custom-virtio INPUT queue after \"\(marker)\" transport=cv-input\n".utf8))
                    CustomVirtioSpike.injectStrokes(strokes, sequenceTag: "key-seq")
                    sent = true
                    break
                }
                #endif
                guard let view = machineView else {
                    FileHandle.standardError.write(Data("ERROR: --input-string needs --display/--screenshot (no VZVirtualMachineView)\n".utf8))
                    return
                }
                let windowNumber = view.window?.windowNumber ?? 0
                var allOk = true
                // Resolve every char up front (so a missing keycode aborts
                // before any event fires), then schedule the keyDown/keyUp
                // pairs on the MAIN queue with strictly increasing delays.
                // Each event is delivered via the view on the main thread;
                // the timing lives in asyncAfter, not in a background
                // Thread.sleep, so the run loop pumps normally between
                // events and no event is coalesced or dropped. The 2 s
                // spacing is deliberate: VZ's keyboard delivers reports at
                // roughly one per full-frame Road Pops present, so typing
                // faster drops reports (observed claim-time).
                var events: [(type: NSEvent.EventType, code: UInt16, mods: NSEvent.ModifierFlags, chars: String)] = []
                for ch in text {
                    guard let (code, shift) = macKey(for: ch) else {
                        FileHandle.standardError.write(Data("ERROR: --input-string: no macOS keycode for '\(ch)'\n".utf8))
                        allOk = false
                        break
                    }
                    let mods: NSEvent.ModifierFlags = shift ? .shift : []
                    let chars = String(ch)
                    events.append((.keyDown, code, mods, chars))
                    events.append((.keyUp, code, mods, chars))
                }
                if allOk {
                    var delay: Double = 0.0
                    for (i, ev) in events.enumerated() {
                        let evt = ev
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            if i == 0, let view = machineView {
                                // Claim 8844: report the delivery-relevant
                                // window state BEFORE the first keystroke
                                // lands (main thread) — a passing run shows
                                // key=true; a walled run shows key=false
                                // immediately, instead of a silent events=0.
                                reportKeyboardKeyState(view, label: "KEY-SEQ")
                            }
                            let t = ProcessInfo.processInfo.systemUptime
                            // VZ maps keyDown/keyUp by keyCode; keep the
                            // characters on both so the pair is symmetric.
                            let chars = evt.chars
                            if let e = NSEvent.keyEvent(with: evt.type, location: .zero, modifierFlags: evt.mods, timestamp: t, windowNumber: windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: evt.code) {
                                if evt.type == .keyDown {
                                    view.keyDown(with: e)
                                } else {
                                    view.keyUp(with: e)
                                }
                            }
                        }
                        delay += 2.0
                    }
                    FileHandle.standardOutput.write(Data("KEY-SEQ: typed \(text.debugDescription) into the VZVirtualMachineView after \"\(marker)\" ok=true\n".utf8))
                } else {
                    FileHandle.standardOutput.write(Data("KEY-SEQ: aborted (missing keycode) ok=false\n".utf8))
                }
                sent = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !sent {
            FileHandle.standardError.write(Data("ERROR: guest did not emit key-seq marker '\(marker)' within \(Int(waitSeconds))s; string not typed\n".utf8))
        }
    }
}

/// Forward `path` into the serial attachment exactly once, after `after`
/// appears in the serial log (default: the kernel terminal state). Shared
/// by the primary script (claim 6684) and the second phase (claim 4613).
///
/// Issue #843 (Shape A): every forward step is logged distinctly so a
/// script-phase delivery stall self-diagnoses at the host — "marker seen"
/// is logged SEPARATELY from "bytes written", and a post-write pipe
/// residual check distinguishes "VZ never consumed the bytes" (residual
/// bytes still queued in the serial input pipe) from "bytes left the pipe"
/// (delivered to VZ/guest — a guest RX or shell-processing stall).
func forwardScriptOnce(path: String, after: String?, label: String, settle: Double) {
    let q = DispatchQueue(label: "virelaios.\(label)")
    q.async {
        let scriptData: Data
        do {
            scriptData = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("ERROR: could not read script file '\(path)': \(error)\n".utf8))
            exit(1)
        }
        let marker = after ?? "kernel terminal state"
        // Card N9 (claim 9489): a configured settle (--script2-delay /
        // --script3-delay) is a wall-clock wait the gate WANTS, so the
        // marker-wait extends with it — the marker of a later phase
        // legitimately appears only after the earlier phases' delays have
        // elapsed. The default 40 s is unchanged for every existing gate.
        //
        // Card U2 (claim 0142): the bound also extends to the session
        // timeout. A phase-2 marker can legitimately appear a long way in
        // when phase 1 is slow — the U2 gate's `u2done` lands only after ~24
        // synthesized keystrokes at 3 s each — and a marker can never arrive
        // after the VM is gone, so `--timeout` is the honest ceiling. This
        // only ever widens the wait, and only for a session that asked for a
        // longer timeout than the old fixed floor.
        let waitSeconds = max(max(40, settle + 60), timeout)
        let waitDeadline = Date().addingTimeInterval(waitSeconds)
        let started = Date()
        FileHandle.standardOutput.write(Data("\(label): waiting for marker \"\(marker)\" (script \(scriptData.count) bytes, settle \(settle)s, deadline \(Int(waitSeconds))s)\n".utf8))
        var sent = false
        var readFailures = 0
        while Date() < waitDeadline {
            if let text = try? String(contentsOf: serialURL, encoding: .utf8) {
                if text.contains(marker) {
                    FileHandle.standardOutput.write(Data("\(label): marker \"\(marker)\" seen at t=\(String(format: "%.1f", Date().timeIntervalSince(started)))s (serial log \(text.count) bytes) — settle \(settle)s, then forward\n".utf8))
                    Thread.sleep(forTimeInterval: settle)
                    let writeStart = Date()
                    do { try consoleInputPipe.fileHandleForWriting.write(contentsOf: scriptData) }
                    catch {
                        FileHandle.standardError.write(Data("ERROR: could not forward script to the guest serial attachment: \(error)\n".utf8))
                    }
                    let writeSecs = Date().timeIntervalSince(writeStart)
                    FileHandle.standardOutput.write(Data("\(label): forwarded \(scriptData.count) bytes to the serial attachment (write took \(String(format: "%.3f", writeSecs))s)\n".utf8))
                    if writeSecs > 1.0 {
                        FileHandle.standardError.write(Data("WARNING: \(label): serial-input write blocked \(String(format: "%.3f", writeSecs))s — the pipe was backed up (VZ not draining the serial attachment fast enough)\n".utf8))
                    }
                    // Issue #843 Shape A: after a grace period, check whether
                    // the forwarded bytes are STILL queued in the serial input
                    // pipe (unread by VZ's serial attachment). poll() on the
                    // READ end: POLLIN set = data pending = VZ never consumed
                    // it — the host→guest delivery itself stalled. POLLIN
                    // clear = the bytes left the pipe and any stall is in VZ's
                    // delivery or the guest's RX/shell path, not this write.
                    Thread.sleep(forTimeInterval: 2.0)
                    var pfd = pollfd(fd: consoleInputPipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                    let pr = poll(&pfd, 1, 0)
                    if pr > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                        FileHandle.standardError.write(Data("WARNING: \(label): \(scriptData.count) forwarded bytes STILL queued in the serial input pipe 2s after the write — the VZ serial attachment did not consume them (host→guest RX stall)\n".utf8))
                    } else {
                        FileHandle.standardOutput.write(Data("\(label): serial input pipe drained (bytes left the host pipe — any stall is VZ delivery or guest RX)\n".utf8))
                    }
                    sent = true
                    break
                }
            } else {
                readFailures += 1
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if readFailures > 0 {
            FileHandle.standardError.write(Data("WARNING: \(label): \(readFailures) serial-log read(s) failed while polling for the marker\n".utf8))
        }
        if !sent {
            FileHandle.standardError.write(Data("ERROR: guest did not emit \(label)-after marker '\(marker)' within \(Int(waitSeconds))s; script input not sent\n".utf8))
        }
    }
}

// Claim 6076 (milestone five card N2): the host→guest RX injection. Waits
// until the trigger marker appears in the serial log (default: the guest's
// `net: rx-armed` line — the queue-0 RX buffer is guaranteed supplied and
// kicked, so the datagram cannot race an unarmed ring), then writes the
// --net-inject file's bytes into the runner's OTHER end of the attachment
// socketpair EXACTLY ONCE. Direction (observed in the claim-6076 probe):
// the attachment socket is fds[0], the reader's end is fds[1] — VZ READS
// fds[0] for host→guest packets and WRITES fds[0] for guest→host packets,
// so on a socketpair a datagram written to fds[1] is exactly what VZ's
// read on fds[0] consumes (a write to fds[0] instead would be captured by
// the runner's own reader and never reach the guest — the probe's capture
// held the injected bytes). The reader thread reads fds[1] for datagrams
// written to fds[0] (guest TX), so the two directions never race. The
// injected bytes are the raw Ethernet frame the guest's net recv must
// print byte-exact. Deterministic — a serial trigger, not a sleep.
// Requires --net (validated at parse time); a no-op without it.
func startNetInject() {
    guard let path = netInjectPath, let socket = netCaptureReadSocket else { return }
    let q = DispatchQueue(label: "virelaios.netinject")
    q.async {
        let injectData: Data
        do {
            injectData = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("ERROR: could not read net-inject file '\(path)': \(error)\n".utf8))
            exit(1)
        }
        let marker = netInjectAfter ?? "net: rx-armed"
        let waitDeadline = Date().addingTimeInterval(40)
        var sent = false
        // Poll every 20 ms (claim 7293): a scripted gate that injects at a
        // MID-SCRIPT marker (the guest's `net ip: ip=...` echo, not a
        // boot-time marker) must not race the commands that follow the
        // marker — the guest executes the script burst in tens of ms, so a
        // 0.5 s poll would land the datagram AFTER the observation
        // commands already ran.
        while Date() < waitDeadline {
            if let text = try? String(contentsOf: serialURL, encoding: .utf8),
               text.contains(marker) {
                // One datagram per write (SOCK_DGRAM); the injected bytes
                // are the raw Ethernet frame the guest must receive.
                do {
                    try socket.write(contentsOf: injectData)
                    FileHandle.standardOutput.write(Data("NET-INJECT: sent \(injectData.count) byte(s) into the attachment socketpair (VZ reads fds[0]) after \"\(marker)\"\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("ERROR: net-inject write failed: \(error)\n".utf8))
                }
                sent = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if !sent {
            FileHandle.standardError.write(Data("ERROR: guest did not emit net-inject marker '\(marker)' within 40s; injection not sent\n".utf8))
        }
    }
}

// SH7 (#1083, ADR 0020 Amendment B): the host-initiated inbound TCP client
// kicker — wait for the guest shell's listening marker, then write the SYN
// into the attachment socketpair. The capture thread drives the rest
// (SYN-ACK -> ACK+payload -> data -> FIN). Deterministic — a serial
// trigger, not a sleep. Requires --net (validated at parse time).
// M99f (#2184): one SYN-watcher per declared client — several
// `--net-tcp-connect` flags each wait for the marker and fire their own
// SYN on their own source port.
func startNetTcpConnect() {
    guard let socket = netCaptureReadSocket else { return }
    for client in netTcpClients {
        let q = DispatchQueue(label: "virelaios.nettcpconnect.\(client.cliPort)")
        q.async {
            let marker = netTcpConnectAfter ?? "sh: remote"
            let waitDeadline = Date().addingTimeInterval(60)
            var sent = false
            while Date() < waitDeadline {
                if let text = try? String(contentsOf: serialURL, encoding: .utf8), text.contains(marker) {
                    client.seq = netTcpCliIsn
                    client.ack = 0
                    client.sshGuestDataSeen = false
                    client.state = 1
                    var syn = [UInt8](repeating: 0, count: 4096)
                    let len = buildTcpFrameExplicit(&syn, netTcpGuestMAC, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02], netTcpCliSrcIP, client.guestIP, client.cliPort, client.guestPort, netTcpCliIsn, 0, 0x02, [])
                    do {
                        try socket.write(contentsOf: Data(syn[0..<len]))
                        let ipText = client.guestIP.map(String.init).joined(separator: ".")
                        FileHandle.standardOutput.write(Data("NET-TCP-CONNECT: sent SYN to \(ipText):\(client.guestPort) (seq 0x\(hex32(netTcpCliIsn))) after \"\(marker)\"\n".utf8))
                    } catch {
                        FileHandle.standardError.write(Data("ERROR: net-tcp-connect SYN write failed: \(error)\n".utf8))
                    }
                    sent = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            if !sent {
                FileHandle.standardError.write(Data("ERROR: guest did not emit net-tcp-connect marker '\(marker)' within 60s; connection not attempted\n".utf8))
            }
        }
    }
}

func startNativeSocketProbe() {
    guard let probe = nativeSocketProbe, let socket = netCaptureReadSocket else { return }
    DispatchQueue(label: "virelaios.native-preview").async {
        while Date() < deadline {
            if let text = try? String(contentsOf: serialURL, encoding: .utf8),
               text.contains("native-socket: listening two-client limit") {
                probe.start(socket: socket)
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        print("NATIVE-PROBE: FAIL listener marker missing")
    }
}

// Card N3 (claim 7293): is the datagram an ARP request (Ethernet II
// ethertype 0x0806, ARP htype 1 / ptype 0x0800 / hlen 6 / plen 4, op 1)?
// The guest's request frames are raw Ethernet — dst ff*6 (broadcast),
// src own MAC, ethertype at bytes 12-13, the ARP payload at 14..42.
func isArpRequest(_ buf: [UInt8], _ n: Int) -> Bool {
    guard n >= 42 else { return false }
    guard buf[12] == 0x08 && buf[13] == 0x06 else { return false }
    guard buf[14] == 0x00 && buf[15] == 0x01 else { return false } // htype ethernet
    guard buf[16] == 0x08 && buf[17] == 0x00 else { return false } // ptype IPv4
    guard buf[18] == 0x06 && buf[19] == 0x04 else { return false } // hlen/plen
    guard buf[20] == 0x00 && buf[21] == 0x01 else { return false } // op request
    return true
}

// Card N3 (claim 7293): synthesize the 42-byte ARP REPLY to the request in
// `req` (the guest's bytes): dst = the requester's MAC, src = host MAC,
// ethertype 0x0806, op 2, sha/spa = host MAC/IP, tha/tpa = the requester's
// MAC/IP (copied from the request's sha/spa — the standard answer shape).
func buildArpReply(_ reply: inout [UInt8], _ req: [UInt8], _ n: Int, _ hostMAC: [UInt8], _ hostIP: [UInt8]) {
    _ = n
    reply[0...5] = req[22...27] // dst = the requester's MAC (its sha)
    reply[6...11] = hostMAC[0...5] // src
    reply[12] = 0x08
    reply[13] = 0x06
    reply[14] = 0x00
    reply[15] = 0x01
    reply[16] = 0x08
    reply[17] = 0x00
    reply[18] = 0x06
    reply[19] = 0x04
    reply[20] = 0x00
    reply[21] = 0x02 // op reply
    reply[22...27] = hostMAC[0...5] // sha
    reply[28...31] = hostIP[0...3] // spa
    reply[32...37] = req[22...27] // tha = the requester's MAC
    reply[38...41] = req[28...31] // tpa = the requester's IP
}

// Card N4 (claim 0148): is the datagram an ICMP ECHO REQUEST for our
// address? Ethernet II ethertype 0x0800, version 4 / IHL 5 (0x45),
// protocol ICMP (1), dst IP == `hostIP`, ICMP type 8. The guest's
// `net ping` frames are raw Ethernet — header at 14..34, ICMP at 34.
func isIcmpEchoRequest(_ buf: [UInt8], _ n: Int, _ hostIP: [UInt8]) -> Bool {
    guard n >= 46 else { return false }
    guard buf[12] == 0x08 && buf[13] == 0x00 else { return false } // ethertype IPv4
    guard buf[14] == 0x45 else { return false } // version 4, IHL 5
    guard (buf[20] & 0x1f) == 0 && buf[21] == 0 else { return false } // NOT a fragment (the ICMP header would not be at 34)
    guard buf[23] == 0x01 else { return false } // protocol ICMP
    guard buf[30] == hostIP[0] && buf[31] == hostIP[1] && buf[32] == hostIP[2] && buf[33] == hostIP[3] else { return false }
    guard buf[34] == 0x08 else { return false } // ICMP echo request
    return true
}

// Card N5 (claim 8552): the UDP checksum over the IPv4 pseudo-header
// (src IP, dst IP, zero, protocol 17, UDP length) + the datagram (RFC
// 768 §2 / RFC 1071; the checksum field must be zero during the build).
@Sendable func udpChecksum(_ srcIP: [UInt8], _ dstIP: [UInt8], _ datagram: [UInt8], _ udpLen: UInt16) -> UInt16 {
    var words: [UInt16] = []
    func push(_ hi: UInt8, _ lo: UInt8) {
        words.append((UInt16(hi) << 8) | UInt16(lo))
    }
    push(srcIP[0], srcIP[1])
    push(srcIP[2], srcIP[3])
    push(dstIP[0], dstIP[1])
    push(dstIP[2], dstIP[3])
    words.append(UInt16(17)) // zero + protocol UDP
    words.append(udpLen)
    var i = 0
    while i + 1 < datagram.count {
        push(datagram[i], datagram[i + 1])
        i += 2
    }
    if i < datagram.count { push(datagram[i], 0) }
    var sum: UInt32 = 0
    for w in words { sum += UInt32(w) }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return UInt16(~sum & 0xffff)
}

// M117b (#2474, ADR 0057 D10): parse a text IPv6 address — any
// inet_pton-legal form ("::" compression, mixed case). The runner is a
// host process; Darwin's inet_pton is the honest parser (no hand-rolled
// hex walk).
@Sendable func parseIPv6(_ text: String) -> [UInt8]? {
    var addr = in6_addr()
    return text.withCString { cstr in
        guard inet_pton(AF_INET6, cstr, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }
}

// M117b: the canonical text form of a v6 address (inet_ntop — the same
// compressed shape the guest's formatter emits for these values).
@Sendable func v6Text(_ a: [UInt8]) -> String {
    var addr = in6_addr()
    withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: a) }
    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN))
    return String(cString: buf)
}

// M117b: the ICMPv6 pseudo-header checksum — 16-byte src + dst, the
// 32-bit upper-layer length, 3 zero bytes + next-header — over `msg`
// (RFC 8200 §8.1; the checksum field must be zero during the build).
@Sendable func icmp6Checksum(_ srcIP: [UInt8], _ dstIP: [UInt8], _ msg: [UInt8], _ nextHeader: UInt8) -> UInt16 {
    var sum: UInt32 = 0
    var i = 0
    while i < 16 {
        sum += (UInt32(srcIP[i]) << 8) | UInt32(srcIP[i + 1])
        sum += (UInt32(dstIP[i]) << 8) | UInt32(dstIP[i + 1])
        i += 2
    }
    sum += UInt32(msg.count >> 16) + UInt32(msg.count & 0xffff)
    sum += UInt32(nextHeader)
    i = 0
    while i + 1 < msg.count {
        sum += (UInt32(msg[i]) << 8) | UInt32(msg[i + 1])
        i += 2
    }
    if i < msg.count { sum += UInt32(msg[i]) << 8 }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return UInt16(~sum & 0xffff)
}

// M117b: is the datagram an IPv6 frame carrying ICMPv6 of the given
// type? Ethernet II ethertype 0x86dd, version 6, next-header 58 (the
// guest sends terminal next-headers only), the ICMPv6 type byte at 54.
@Sendable func isIcmp6Type(_ buf: [UInt8], _ n: Int, _ type: UInt8) -> Bool {
    guard n >= 56 else { return false }
    guard buf[12] == 0x86 && buf[13] == 0xdd else { return false }
    guard buf[14] >> 4 == 0x6 else { return false }
    guard buf[20] == 58 else { return false }
    return buf[54] == type
}

@Sendable func isRouterSolicitation(_ buf: [UInt8], _ n: Int) -> Bool {
    return isIcmp6Type(buf, n, 133)
}

@Sendable func isNeighborSolicitation(_ buf: [UInt8], _ n: Int) -> Bool {
    return isIcmp6Type(buf, n, 135)
}

// M117b: the NS's target when it names an answerable address — an
// explicit --net-ndp-respond entry, or the router link-local implicitly
// listed by --net-ra-respond (the guest's router-resolution NS is
// answered without a second flag). nil = unanswered (the refusal leg).
@Sendable func ndpRespondTarget(_ buf: [UInt8], _ n: Int) -> [UInt8]? {
    guard n >= 78 else { return nil }
    let target = [UInt8](buf[62..<78])
    for a in netNdpRespondAddrs where a == target { return target }
    if netRaRespondPrefix != nil, target == netRouterLinkLocal { return target }
    return nil
}

// M117b: is the datagram an ICMPv6 echo request for `addr`?
@Sendable func isIcmp6EchoRequest(_ buf: [UInt8], _ n: Int, _ addr: [UInt8]) -> Bool {
    guard isIcmp6Type(buf, n, 128) else { return false }
    return [UInt8](buf[38..<54]) == addr
}

// M117b: synthesize the ROUTER ADVERTISEMENT to a guest RS: dst
// all-nodes (33:33:00:00:00:01 / ff02::1 — the guest's D2 filter admits
// it), src the router link-local, hop 255, cur-hop 64, M|O 0, router
// lifetime 1800, reachable/retrans 0, ONE Prefix Information option
// carrying the argument /64 with A+L and finite recorded lifetimes
// (valid 86400, preferred 14400). 102 bytes total.
@Sendable func buildRouterAdvertisement(_ reply: inout [UInt8], _ hostMAC: [UInt8], _ prefix: [UInt8]) {
    reply = [UInt8](repeating: 0, count: 102)
    reply[0...5] = [0x33, 0x33, 0x00, 0x00, 0x00, 0x01] // all-nodes dst
    reply[6...11] = hostMAC[0...5] // src
    reply[12] = 0x86
    reply[13] = 0xdd
    reply[14] = 0x60 // version 6
    reply[18] = 0
    reply[19] = 48 // payload_len: 16-byte RA fixed part + 32-byte PIO
    reply[20] = 58 // ICMPv6
    reply[21] = 255 // hop limit — the NDP standing check
    reply[22...37] = netRouterLinkLocal[0...15] // src = the router link-local
    reply[38] = 0xff
    reply[39] = 0x02
    reply[53] = 0x01 // dst = ff02::1 (all-nodes)
    let src = netRouterLinkLocal
    var dst = [UInt8](repeating: 0, count: 16)
    dst[0] = 0xff
    dst[1] = 0x02
    dst[15] = 0x01
    // ICMPv6 RA: type 134, code 0, checksum, cur-hop 64, flags 0,
    // lifetime 1800, reachable 0, retrans 0.
    reply[54] = 134
    reply[58] = 64
    reply[60] = 0x07
    reply[61] = 0x08 // router lifetime 1800
    // PIO at 70: type 3, len 4, prefix_len 64, flags A|L (0xc0),
    // valid 86400, preferred 14400, reserved 0, prefix.
    reply[70] = 3
    reply[71] = 4
    reply[72] = 64
    reply[73] = 0xc0
    reply[74] = 0
    reply[75] = 1
    reply[76] = 0x51
    reply[77] = 0x80 // valid lifetime 86400
    reply[78] = 0
    reply[79] = 0
    reply[80] = 0x46
    reply[81] = 0x50 // preferred lifetime 14400
    reply[86...101] = prefix[0...15]
    let chk = icmp6Checksum(src, dst, [UInt8](reply[54..<102]), 58)
    reply[56] = UInt8(chk >> 8)
    reply[57] = UInt8(chk & 0xff)
}

// M117b: synthesize the NEIGHBOR ADVERTISEMENT to the guest's NS in
// `req`: dst = the request's observed Ethernet source (all-nodes when
// its v6 src was :: — the DAD answer), src = the solicited `target`,
// flags S|O, target echoed, TLLA = the host MAC, hop 255. 86 bytes.
@Sendable func buildNeighborAdvertisement(_ reply: inout [UInt8], _ req: [UInt8], _ n: Int, _ hostMAC: [UInt8], _ target: [UInt8]) {
    reply = [UInt8](repeating: 0, count: 86)
    let reqSrc = [UInt8](req[22..<38])
    let unspecified = reqSrc == [UInt8](repeating: 0, count: 16)
    if unspecified {
        reply[0...5] = [0x33, 0x33, 0x00, 0x00, 0x00, 0x01] // all-nodes
    } else {
        reply[0...5] = req[6...11] // dst = the observed src MAC
    }
    reply[6...11] = hostMAC[0...5] // src
    reply[12] = 0x86
    reply[13] = 0xdd
    reply[14] = 0x60
    reply[18] = 0
    reply[19] = 32 // payload_len: flags(4) + target(16) + TLLA(8) + hdr(4)
    reply[20] = 58
    reply[21] = 255
    reply[22...37] = target[0...15] // src = the solicited target
    if unspecified {
        reply[38] = 0xff
        reply[39] = 0x02
        reply[53] = 0x01 // dst = ff02::1
    } else {
        reply[38...53] = reqSrc[0...15] // dst = the requester's address
    }
    reply[54] = 136 // NA
    reply[58] = 0x60 // flags S|O
    reply[62...77] = target[0...15] // target echoed
    reply[78] = 2 // TLLA option type
    reply[79] = 1 // length 1
    reply[80...85] = hostMAC[0...5]
    let dst = [UInt8](reply[38..<54])
    let chk = icmp6Checksum(target, dst, [UInt8](reply[54..<86]), 58)
    reply[56] = UInt8(chk >> 8)
    reply[57] = UInt8(chk & 0xff)
}

// M117b: synthesize the ICMPv6 ECHO REPLY to the echo request in `req`
// — Ethernet dst/src swapped, v6 src/dst swapped (the reply's src is
// the address it was sent to), hop 64, type 129, id/seq/payload echoed
// byte-exact, the pseudo-header checksum recomputed.
@Sendable func buildIcmp6EchoReply(_ reply: inout [UInt8], _ req: [UInt8], _ n: Int, _ hostMAC: [UInt8]) {
    reply = [UInt8](repeating: 0, count: n)
    reply[0...5] = req[6...11] // dst = the requester's MAC
    reply[6...11] = hostMAC[0...5] // src
    reply[12] = 0x86
    reply[13] = 0xdd
    reply[14] = 0x60
    reply[18...19] = req[18...19] // payload_len (unchanged; TC/flow stays 0)
    reply[20] = 58
    reply[21] = 64 // hop limit — echo traffic, not NDP
    reply[22...37] = req[38...53] // src = the addressed address
    reply[38...53] = req[22...37] // dst = the requester's address
    reply[54] = 129 // echo reply
    if n > 58 {
        reply[58...n - 1] = req[58...n - 1] // id + seq + payload echoed
    }
    let src = [UInt8](reply[22..<38])
    let dst = [UInt8](reply[38..<54])
    let chk = icmp6Checksum(src, dst, [UInt8](reply[54..<n]), 58)
    reply[56] = UInt8(chk >> 8)
    reply[57] = UInt8(chk & 0xff)
}

// Card N5 (claim 8552): is the datagram a UDP datagram addressed to
// `hostIP:hostPort`? Ethernet II ethertype 0x0800, version 4 / IHL 5,
// NOT a fragment, protocol UDP (17), dst IP match, dst port match.
func isUdpDatagram(_ buf: [UInt8], _ n: Int, _ hostIP: [UInt8], _ hostPort: UInt16) -> Bool {
    guard n >= 46 else { return false }
    guard buf[12] == 0x08 && buf[13] == 0x00 else { return false } // ethertype IPv4
    guard buf[14] == 0x45 else { return false } // version 4, IHL 5
    guard (buf[20] & 0x1f) == 0 && buf[21] == 0 else { return false } // NOT a fragment
    guard buf[23] == 17 else { return false } // protocol UDP
    guard buf[30] == hostIP[0] && buf[31] == hostIP[1] && buf[32] == hostIP[2] && buf[33] == hostIP[3] else { return false }
    let dstPort = (UInt16(buf[36]) << 8) | UInt16(buf[37])
    return dstPort == hostPort
}

// Card N5 (claim 8552): synthesize the UDP REPLY to the datagram in `req`
// (the guest's bytes) into `reply` (same length): Ethernet dst/src
// swapped, ethertype 0x0800, IPv4 src/dst swapped (identification
// ECHOED — deterministic), TTL 64, protocol 17, UDP src port = the host
// port, dst port = the sender's src port, the payload ECHOED byte-exact;
// the IPv4 header checksum + the UDP pseudo-header checksum recomputed.
func buildUdpReply(_ reply: inout [UInt8], _ req: [UInt8], _ n: Int, _ hostMAC: [UInt8], _ hostIP: [UInt8], _ hostPort: UInt16) {
    reply = [UInt8](repeating: 0, count: n)
    reply[0...5] = req[6...11] // dst = the sender's MAC
    reply[6...11] = hostMAC[0...5] // src
    reply[12] = 0x08
    reply[13] = 0x00 // ethertype IPv4
    reply[14] = 0x45 // version 4, IHL 5
    reply[16...17] = req[16...17] // total length (unchanged)
    reply[18...19] = req[18...19] // identification ECHOED
    reply[22] = 64 // TTL
    reply[23] = 17 // protocol UDP
    reply[26...29] = hostIP[0...3] // src = our address
    reply[30...33] = req[26...29] // dst = the sender's address
    let hdrChk = ipChecksum(reply, 14, 34)
    reply[24] = UInt8(hdrChk >> 8)
    reply[25] = UInt8(hdrChk & 0xff)
    // UDP: src = the host port, dst = the sender's src port, length
    // echoed, the payload echoed byte-exact; checksum recomputed.
    reply[34] = UInt8(hostPort >> 8)
    reply[35] = UInt8(hostPort & 0xff)
    reply[36] = req[34] // the sender's src port
    reply[37] = req[35]
    reply[38...39] = req[38...39] // UDP length (unchanged)
    let udpLen = (UInt16(req[38]) << 8) | UInt16(req[39])
    let payloadStart = 42
    if n > payloadStart {
        reply[payloadStart...n - 1] = req[payloadStart...n - 1] // payload echoed
    }
    let senderIP = [UInt8](req[26...29])
    var datagram = [UInt8](reply[34..<n])
    datagram[6] = 0
    datagram[7] = 0 // zero the checksum field during the computation
    let udpChk = udpChecksum(hostIP, senderIP, datagram, udpLen)
    reply[40] = UInt8(udpChk >> 8)
    reply[41] = UInt8(udpChk & 0xff)
}

// M117c (#2475): is the datagram a UDP/IPv6 datagram addressed to
// `addr:port`? Ethernet II ethertype 0x86dd, version 6, next-header 17,
// the 16-byte dst address match, the dst port match. UDP over v6 is
// at frame 54 (14-byte Ethernet + the 40-byte fixed header).
@Sendable func isUdp6Datagram(_ buf: [UInt8], _ n: Int, _ addr: [UInt8], _ port: UInt16) -> Bool {
    guard n >= 62 else { return false }
    guard buf[12] == 0x86 && buf[13] == 0xdd else { return false } // ethertype IPv6
    guard buf[14] >> 4 == 0x6 else { return false } // version 6
    guard buf[20] == 17 else { return false } // next header UDP
    guard [UInt8](buf[38..<54]) == addr else { return false } // dst address
    let dstPort = (UInt16(buf[56]) << 8) | UInt16(buf[57])
    return dstPort == port
}

// M117c (#2475): synthesize the UDP/IPv6 REPLY to the datagram in `req`
// (the guest's bytes) into `reply` (same length): Ethernet dst/src
// swapped, ethertype 0x86dd, v6 src/dst swapped, payload_len echoed,
// hop 64, UDP src port = the host port, dst port = the sender's src
// port, the payload ECHOED byte-exact; the UDP pseudo-header checksum
// recomputed over the v6 addresses (icmp6Checksum is the generic
// 16-byte pseudo-header — nh 17 here).
@Sendable func buildUdp6Reply(_ reply: inout [UInt8], _ req: [UInt8], _ n: Int, _ hostMAC: [UInt8], _ addr: [UInt8], _ port: UInt16) {
    reply = [UInt8](repeating: 0, count: n)
    reply[0...5] = req[6...11] // dst = the sender's MAC
    reply[6...11] = hostMAC[0...5] // src
    reply[12] = 0x86
    reply[13] = 0xdd // ethertype IPv6
    reply[14] = 0x60 // version 6
    reply[18...19] = req[18...19] // payload_len (unchanged)
    reply[20] = 17 // next header UDP
    reply[21] = 64 // hop limit
    reply[22...37] = addr[0...15] // src = the addressed address
    reply[38...53] = req[22...37] // dst = the sender's address
    reply[54] = UInt8(port >> 8)
    reply[55] = UInt8(port & 0xff)
    reply[56] = req[54] // the sender's src port
    reply[57] = req[55]
    reply[58...59] = req[58...59] // UDP length (unchanged)
    if n > 62 {
        reply[62...n - 1] = req[62...n - 1] // payload echoed
    }
    let dst = [UInt8](reply[38..<54])
    var datagram = [UInt8](reply[54..<n])
    datagram[6] = 0
    datagram[7] = 0 // zero the checksum field during the computation
    let udpChk = icmp6Checksum(addr, dst, datagram, 17)
    reply[60] = UInt8(udpChk >> 8)
    reply[61] = UInt8(udpChk & 0xff)
}

// M99i (issue #2187): hex helper for --net-dns-answer6.
func parseHexBytes(_ hex: String) -> [UInt8]? {
    guard hex.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(hex.count / 2)
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
        out.append(b)
        i = j
    }
    return out
}

// Milestone twelve card N2 (claim 7566): DNS packet matching & response synthesis
func isDnsQuery(_ buf: [UInt8], _ n: Int, _ hostIP: [UInt8], _ hostPort: UInt16) -> Bool {
    guard n >= 42 + 12 + 5 else { return false }
    guard buf[12] == 0x08 && buf[13] == 0x00 else { return false } // IPv4
    guard buf[14] == 0x45 else { return false } // IHL 5
    guard (buf[20] & 0x1f) == 0 && buf[21] == 0 else { return false } // not a fragment
    guard buf[23] == 17 else { return false } // UDP
    guard buf[30] == hostIP[0] && buf[31] == hostIP[1] && buf[32] == hostIP[2] && buf[33] == hostIP[3] else { return false }
    let dstPort = (UInt16(buf[36]) << 8) | UInt16(buf[37])
    guard dstPort == hostPort else { return false }
    let flags = (UInt16(buf[44]) << 8) | UInt16(buf[45])
    return (flags & 0x8000) == 0 // QR = 0 (query)
}

func extractDnsQName(_ buf: [UInt8], _ n: Int) -> String {
    var off = 42 + 12
    var labels: [String] = []
    while off < n {
        let len = Int(buf[off])
        if len == 0 { break }
        if (len & 0xC0) != 0 { break }
        off += 1
        if off + len > n { break }
        let s = String(decoding: buf[off..<off+len], as: UTF8.self)
        labels.append(s)
        off += len
    }
    return labels.joined(separator: ".")
}

// M99i (issue #2187): the QTYPE the request's question section asks for
// (offset 42+12 qname, then QTYPE/QCLASS).
func dnsQueryType(_ req: [UInt8], _ n: Int) -> UInt16 {
    var off = 42 + 12
    while off < n {
        let len = Int(req[off])
        if len == 0 { off += 1; break }
        if (len & 0xC0) != 0 { off += 2; break }
        off += 1 + len
    }
    guard off + 2 <= n else { return 1 }
    return (UInt16(req[off]) << 8) | UInt16(req[off + 1])
}

// M99i: the answer set for one query. A queries take the configured A
// records (or the legacy qname table, one answer — the pre-M99i
// behavior); AAAA queries take the configured AAAA records (or one fixed
// 2001:db8::53).
func dnsAnswersFor(_ qtype: UInt16, _ qname: String) -> [(rtype: UInt16, rdata: [UInt8])] {
    if qtype == 28 {
        if !netDnsAnswers6.isEmpty {
            return netDnsAnswers6.map { (28, $0) }
        }
        return [(28, [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x53])]
    }
    if !netDnsAnswers.isEmpty {
        return netDnsAnswers.map { (1, $0) }
    }
    var resolvedIP: [UInt8] = [93, 184, 216, 34]
    if qname == "myhost.local" || qname == "gateway.local" {
        resolvedIP = [10, 0, 0, 2]
    } else if qname == "virelai.local" {
        resolvedIP = [10, 0, 0, 1]
    }
    return [(1, resolvedIP)]
}

// M99i: builds the full Ethernet reply. `answers` is the record set,
// `ttl` is written into each, `truncate` answers TC=1/ANCOUNT=0,
// `forgeSrcIP` replaces the packet's source IPv4 (the spoof knob), and
// `corruptQuestion` flips the echoed question's first label byte so the
// guest's byte-exact question check rejects it.
func buildDnsReply(_ reply: inout [UInt8], _ req: [UInt8], _ n: Int, _ hostMAC: [UInt8], _ hostIP: [UInt8], _ hostPort: UInt16, answers: [(rtype: UInt16, rdata: [UInt8])], ttl: UInt32, truncate: Bool, forgeSrcIP: [UInt8]? = nil, corruptQuestion: Bool = false) -> Int {
    var off = 42 + 12
    while off < n {
        let len = Int(req[off])
        if len == 0 { off += 1; break }
        if (len & 0xC0) != 0 { off += 2; break }
        off += 1 + len
    }
    off += 4
    if off > n { return 0 }
    let questionLen = off - (42 + 12)

    let ancount = truncate ? 0 : answers.count
    var answersLen = 0
    for a in answers { answersLen += 12 + a.rdata.count }

    var dnsPayload = [UInt8](repeating: 0, count: 12 + questionLen + answersLen)
    dnsPayload[0] = req[42]
    dnsPayload[1] = req[43]
    dnsPayload[2] = truncate ? 0x83 : 0x81
    dnsPayload[3] = 0x80
    dnsPayload[4] = 0x00
    dnsPayload[5] = 0x01
    dnsPayload[6] = UInt8(ancount >> 8)
    dnsPayload[7] = UInt8(ancount & 0xff)
    dnsPayload[8] = 0x00
    dnsPayload[9] = 0x00
    dnsPayload[10] = 0x00
    dnsPayload[11] = 0x00

    dnsPayload[12..<(12 + questionLen)] = req[(42 + 12)..<off]
    if corruptQuestion, questionLen > 2 {
        // Flip the case of the first label's first byte — DNS name
        // comparison is case-insensitive on paper, but the guest's
        // byte-exact echo check must refuse it.
        dnsPayload[13] ^= 0x20
    }

    var aoff = 12 + questionLen
    for a in answers {
        dnsPayload[aoff + 0] = 0xC0
        dnsPayload[aoff + 1] = 0x0C
        dnsPayload[aoff + 2] = UInt8(a.rtype >> 8)
        dnsPayload[aoff + 3] = UInt8(a.rtype & 0xff)
        dnsPayload[aoff + 4] = 0x00
        dnsPayload[aoff + 5] = 0x01
        dnsPayload[aoff + 6] = UInt8(ttl >> 24)
        dnsPayload[aoff + 7] = UInt8((ttl >> 16) & 0xff)
        dnsPayload[aoff + 8] = UInt8((ttl >> 8) & 0xff)
        dnsPayload[aoff + 9] = UInt8(ttl & 0xff)
        dnsPayload[aoff + 10] = UInt8(a.rdata.count >> 8)
        dnsPayload[aoff + 11] = UInt8(a.rdata.count & 0xff)
        for (i, b) in a.rdata.enumerated() {
            dnsPayload[aoff + 12 + i] = b
        }
        aoff += 12 + a.rdata.count
    }

    let srcIP = forgeSrcIP ?? hostIP
    let totalLen = 42 + dnsPayload.count
    reply = [UInt8](repeating: 0, count: totalLen)
    reply[0...5] = req[6...11]
    reply[6...11] = hostMAC[0...5]
    reply[12] = 0x08
    reply[13] = 0x00
    reply[14] = 0x45
    let ipTotalLen = UInt16(20 + 8 + dnsPayload.count)
    reply[16] = UInt8(ipTotalLen >> 8)
    reply[17] = UInt8(ipTotalLen & 0xff)
    reply[18...19] = req[18...19]
    reply[22] = 64
    reply[23] = 17
    reply[26...29] = srcIP[0...3]
    reply[30...33] = req[26...29]
    let hdrChk = ipChecksum(reply, 14, 34)
    reply[24] = UInt8(hdrChk >> 8)
    reply[25] = UInt8(hdrChk & 0xff)

    reply[34] = UInt8(hostPort >> 8)
    reply[35] = UInt8(hostPort & 0xff)
    reply[36] = req[34]
    reply[37] = req[35]
    let udpLen = UInt16(8 + dnsPayload.count)
    reply[38] = UInt8(udpLen >> 8)
    reply[39] = UInt8(udpLen & 0xff)
    reply[42..<totalLen] = dnsPayload[0..<dnsPayload.count]

    let senderIP = [UInt8](req[26...29])
    var datagram = [UInt8](reply[34..<totalLen])
    datagram[6] = 0
    datagram[7] = 0
    let udpChk = udpChecksum(srcIP, senderIP, datagram, udpLen)
    reply[40] = UInt8(udpChk >> 8)
    reply[41] = UInt8(udpChk & 0xff)

    return totalLen
}


// Card N8 (claim 0351): is the datagram a DHCP client message (Ethernet
// II ethertype 0x0800, version 4 / IHL 5, NOT a fragment, protocol UDP,
// src port 68 -> dst port 67)? The guest's DISCOVER/REQUEST frames are
// raw Ethernet — header at 14..34, UDP at 34..42, the DHCP message at 42.
func isDhcpDatagram(_ buf: [UInt8], _ n: Int) -> Bool {
    guard n >= 46 else { return false }
    guard buf[12] == 0x08 && buf[13] == 0x00 else { return false } // ethertype IPv4
    guard buf[14] == 0x45 else { return false } // version 4, IHL 5
    guard (buf[20] & 0x1f) == 0 && buf[21] == 0 else { return false } // NOT a fragment
    guard buf[23] == 17 else { return false } // protocol UDP
    let srcPort = (UInt16(buf[34]) << 8) | UInt16(buf[35])
    let dstPort = (UInt16(buf[36]) << 8) | UInt16(buf[37])
    return srcPort == 68 && dstPort == 67
}

// Card N8 (claim 0351): the DHCP message type (option 53) of a client
// message, or nil when absent/malformed. Options start at frame 282 (42 +
// the 236-byte BOOTP header + the 4-byte magic cookie).
func dhcpMessageType(_ buf: [UInt8], _ n: Int) -> UInt8? {
    guard n >= 284 else { return nil }
    var i = 282
    while i + 2 <= n {
        let code = buf[i]
        if code == 255 { break }
        if code == 0 { i += 1; continue }
        let len = Int(buf[i + 1])
        if i + 2 + len > n { break }
        if code == 53 && len == 1 { return buf[i + 2] }
        i += 2 + len
    }
    return nil
}

// Card N8 (claim 0351): synthesize the DHCP OFFER (mtype 1 -> 2) or ACK
// (mtype 3 -> 5) to the client message in `req` into `reply` (a fresh
// broadcast frame): Ethernet dst ff*6 / src host MAC, ethertype 0x0800,
// IPv4 src = the lease IP / dst 255.255.255.255 (the client's broadcast
// flag), protocol 17, then the BOOTREPLY (op 2, the guest's xid ECHOED,
// yiaddr = the lease IP, the client's chaddr echoed) with the FIXED
// gate-assertable lease options: 53 (type), 1 (mask 255.255.255.0), 3
// (gateway 10.0.0.1), 54 (server id = the lease IP), 51 (lease 3600),
// 255. Both checksums recomputed (RFC 1071). Returns the frame length
// (310 bytes — the reply message is 268 bytes).
func buildDhcpReply(_ reply: inout [UInt8], _ req: [UInt8], _ n: Int, _ hostMAC: [UInt8], _ leaseIP: [UInt8], _ leaseSecs: UInt32, _ mtype: UInt8) -> Int {
    _ = n
    // The reply message: 236 header + 4 cookie + 53,1,type(3) +
    // 1,4,mask(6) + 3,4,gw(6) + 54,4,server(6) + 51,4,lease(6) + 255(1)
    // = 268 bytes; the frame = 42 + 268 = 310.
    let msgLen = 268
    let frameLen = 42 + msgLen // 310
    reply = [UInt8](repeating: 0, count: frameLen)
    // Ethernet: dst broadcast, src host MAC.
    reply[0...5] = [UInt8](repeating: 0xff, count: 6)[0...5]
    reply[6...11] = hostMAC[0...5]
    reply[12] = 0x08
    reply[13] = 0x00 // ethertype IPv4
    // IPv4: src = the lease IP, dst = 255.255.255.255, proto 17.
    reply[14] = 0x45 // version 4, IHL 5
    reply[16] = UInt8((20 + 8 + msgLen) >> 8)
    reply[17] = UInt8((20 + 8 + msgLen) & 0xff) // total length 296
    reply[22] = 64 // TTL
    reply[23] = 17 // protocol UDP
    reply[26...29] = leaseIP[0...3] // src
    reply[30...33] = [UInt8](repeating: 0xff, count: 4)[0...3] // dst broadcast
    let hdrChk = ipChecksum(reply, 14, 34)
    reply[24] = UInt8(hdrChk >> 8)
    reply[25] = UInt8(hdrChk & 0xff)
    // UDP: src 67, dst 68, length 8 + msgLen.
    reply[34] = 0x00
    reply[35] = 67 // src port 67
    reply[36] = 0x00
    reply[37] = 68 // dst port 68
    reply[38] = UInt8((8 + msgLen) >> 8)
    reply[39] = UInt8((8 + msgLen) & 0xff) // UDP length 276
    // The DHCP message at 42: op BOOTREPLY, htype/hlen, the guest's xid
    // echoed, yiaddr = the lease IP, the client's chaddr echoed.
    reply[42] = 2 // BOOTREPLY
    reply[43] = 1 // htype ethernet
    reply[44] = 6 // hlen
    reply[46...49] = req[46...49] // xid echoed byte-exact
    reply[58...61] = leaseIP[0...3] // yiaddr
    reply[70...85] = req[70...85] // chaddr echoed (the client's MAC)
    // The magic cookie + the fixed lease options.
    reply[278] = 0x63
    reply[279] = 0x82
    reply[280] = 0x53
    reply[281] = 0x63
    var o = 282
    // The reply's message type is the SERVER's answer to the client's
    // message (option 53 must be 2 OFFER for a DISCOVER, 5 ACK for a
    // REQUEST — never the echoed client type).
    let replyType: UInt8 = mtype == 1 ? 2 : 5
    reply[o] = 53; reply[o + 1] = 1; reply[o + 2] = replyType; o += 3 // message type
    reply[o] = 1; reply[o + 1] = 4; reply[o + 2] = 255; reply[o + 3] = 255; reply[o + 4] = 255; reply[o + 5] = 0; o += 6 // subnet mask
    reply[o] = 3; reply[o + 1] = 4; reply[o + 2] = 10; reply[o + 3] = 0; reply[o + 4] = 0; reply[o + 5] = 1; o += 6 // gateway
    reply[o] = 54; reply[o + 1] = 4; reply[o + 2...o + 5] = leaseIP[0...3]; o += 6 // server id
    reply[o] = 51; reply[o + 1] = 4; reply[o + 2] = UInt8(leaseSecs >> 24); reply[o + 3] = UInt8((leaseSecs >> 16) & 0xff); reply[o + 4] = UInt8((leaseSecs >> 8) & 0xff); reply[o + 5] = UInt8(leaseSecs & 0xff); o += 6 // lease option 51
    reply[o] = 255; o += 1 // end
    // o must be exactly frameLen (282 + 28 = 310).
    assert(o == frameLen)
    // The UDP checksum over the pseudo-header (lease IP -> broadcast).
    var datagram = [UInt8](reply[34..<frameLen])
    datagram[6] = 0
    datagram[7] = 0 // zero the checksum field during the computation
    let udpChk = udpChecksum(leaseIP, [UInt8](repeating: 0xff, count: 4), datagram, UInt16(8 + msgLen))
    reply[40] = UInt8(udpChk >> 8)
    reply[41] = UInt8(udpChk & 0xff)
    return frameLen
}

// M51 SSH1 (#1168): pace one payload chunk out in `--net-tcp-respond :packet`
// mode. Called once per accepted guest segment; `guestSeq`/`guestPayload` are
// the incoming segment's seq and payload length (so our ACK covers it). Sends
// at most one ≤chunk segment per call — the guest's one-slot RX cannot take
// two back-to-back, and the host has no retransmission. Returns true when a
// chunk was sent.
func netTcpSendPacketChunk(_ conn: NetTcpSrvConn, _ reply: inout [UInt8], _ buf: [UInt8], _ n: Int, _ hostMAC: [UInt8], _ hostPort: UInt16, _ guestSeq: UInt32, _ guestPayload: Int) -> Bool {
    guard netTcpRespondPacketMode else { return false }
    let total = netTcpRespondPacketPayload.count
    let off = conn.packetIndex * netTcpRespondPacketChunk
    guard off < total else { return false }
    let end = min(off + netTcpRespondPacketChunk, total)
    let chunk = Array(netTcpRespondPacketPayload[off..<end])
    let chunkCount = (total + netTcpRespondPacketChunk - 1) / netTcpRespondPacketChunk
    let replyLen = buildTcpReply(&reply, buf, n, hostMAC, hostPort, conn.srvNxt, guestSeq &+ UInt32(guestPayload), 0x10, chunk)
    try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
    conn.srvNxt = conn.srvNxt &+ UInt32(chunk.count)
    conn.packetIndex += 1
    print("NET-TCP: packet mode sent chunk \(conn.packetIndex)/\(chunkCount) (\(chunk.count) bytes, seq 0x\(hex32(conn.srvNxt &- UInt32(chunk.count))))")
    return true
}

// M51 SSH5 (#1172): pace one ≤192-byte segment of the SSH server's output
// stream out in `--net-tcp-respond :ssh` mode. Called once per accepted
// guest segment; `guestSeq`/`guestPayload` are the incoming segment's seq
// and payload length (so our ACK covers it). Same contract as
// `netTcpSendPacketChunk`: the guest kernel RX is a single bounded slot
// with no reassembly and the host has no retransmission, so at most one
// segment goes out per guest ACK. Returns true when a chunk was sent.
func netTcpRespondSSHSendChunk(_ conn: NetTcpSrvConn, _ reply: inout [UInt8], _ buf: [UInt8], _ n: Int, _ hostMAC: [UInt8], _ hostPort: UInt16, _ guestSeq: UInt32, _ guestPayload: Int) -> Bool {
    guard netTcpRespondSSHMode else { return false }
    let total = conn.sshTx.count
    let off = conn.sshTxOffset
    guard off < total else { return false }
    let end = min(off + netTcpRespondPacketChunk, total)
    let chunk = Array(conn.sshTx[off..<end])
    let replyLen = buildTcpReply(&reply, buf, n, hostMAC, hostPort, conn.srvNxt, guestSeq &+ UInt32(guestPayload), 0x10, chunk)
    try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
    conn.srvNxt = conn.srvNxt &+ UInt32(chunk.count)
    conn.sshTxOffset = end
    print("NET-TCP-SSH: sent \(chunk.count) bytes (\(end)/\(total), seq 0x\(hex32(conn.srvNxt &- UInt32(chunk.count))))")
    if end >= total {
        conn.sshTx.removeAll(keepingCapacity: true)
        conn.sshTxOffset = 0
    }
    return true
}

// M99f (#2184): the host-initiated client state machine, one instance per
// `--net-tcp-connect` flag. Everything that was a scalar global is a field
// on the client, so two live clients never share sequence/ACK/stream
// state — a segment's 5-tuple picks its client before `drive` runs.
extension NetTcpClient {
    /// One guest segment for THIS client: the handshake / payload / SSH /
    /// stream / close transitions that used to live in the capture loop's
    /// scalar switch.
    func drive(_ buf: [UInt8], _ n: Int) {
        let flags = tcpFlags(buf)
        let seq = tcpSeq(buf)
        if n > 49 { peerWindow = UInt32(tcpWindow(buf)) }
        var payload = [UInt8]()
        if n > 54 { payload = [UInt8](buf[54..<n]) }
        let isSynAck = (flags & 0x02) != 0 && (flags & 0x10) != 0
        let isFin = (flags & 0x01) != 0
        let isRst = (flags & 0x04) != 0
        var reply = [UInt8](repeating: 0, count: 4096)
        let guestIP = self.guestIP
        let guestPort = self.guestPort
        let cliPort = self.cliPort
        switch state {
        case 1:
            // SYN sent — expect the guest's SYN-ACK.
            if isSynAck {
                ack = seq &+ 1
                self.seq = netTcpCliIsn &+ 1
                if isStreamClient {
                    let replyLen = buildTcpFrameExplicit(&reply, netTcpGuestMAC, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02], netTcpCliSrcIP, guestIP, cliPort, guestPort, self.seq, ack, 0x10, [])
                    try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                    state = 2
                    startStream()
                    print("NET-TCP-STREAM: handshake complete; probe launched")
                } else if sshMode {
                    let cfg = SSHClient.Config(
                        userKeySeed: netTcpConnectSSHUserSeed,
                        hostPublicKey: netTcpConnectSSHHostPin,
                        user: netTcpConnectSSHUser,
                        execCommand: netTcpConnectSSHExec
                    )
                    let client = SSHClient(config: cfg)
                    client.logSink = { line in print("SSH-CLI: \(line)") }
                    sshClient = client
                    sshTx = client.start()
                    sshTxOffset = 0
                    sshGuestDataSeen = false
                    state = 2
                    if !sshSendChunk() {
                        let replyLen = buildTcpFrameExplicit(&reply, netTcpGuestMAC, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02], netTcpCliSrcIP, guestIP, cliPort, guestPort, self.seq, ack, 0x10, [])
                        try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                    }
                    print("NET-TCP-CONNECT: handshake complete (server ISN 0x\(hex32(seq)), ack 0x\(hex32(ack))); SSH client started")
                } else {
                // M50 TS4 (#1138, ADR 0024 D6): in auth mode the
                // guest mints + sends its challenge once the
                // connection is ESTABLISHED, so the handshake ACK
                // must be bare; the payload follows the MAC.
                let authPending = netTcpConnectSecret != nil || netTcpConnectMac != nil
                let firstPayload = authPending ? [UInt8]() : self.payload
                let replyLen = buildTcpFrameExplicit(&reply, netTcpGuestMAC, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02], netTcpCliSrcIP, guestIP, cliPort, guestPort, self.seq, ack, 0x10, firstPayload)
                try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                self.seq = self.seq &+ UInt32(firstPayload.count)
                state = authPending ? 5 : 2
                if authPending {
                    print("NET-TCP-CONNECT: handshake complete (server ISN 0x\(hex32(seq)), ack 0x\(hex32(ack))); awaiting the VIRELAIOS-AUTH/1 challenge")
                } else {
                    print("NET-TCP-CONNECT: handshake complete (server ISN 0x\(hex32(seq)), ack 0x\(hex32(ack))); sent \(self.payload.count)-byte payload")
                }
                }
            } else if isRst {
                state = 3
                print("NET-TCP-CONNECT: the guest refused the connection (RST)")
            }
        case 5:
            // M50 TS4: awaiting the guest's `VIRELAIOS-AUTH/1` line.
            if isRst {
                state = 3
                print("NET-TCP-CONNECT: the guest reset the connection (RST)")
            } else if isFin {
                ack = seq &+ 1
                let replyLen = buildTcpFrameExplicit(&reply, netTcpGuestMAC, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02], netTcpCliSrcIP, guestIP, cliPort, guestPort, self.seq, ack, 0x10, [])
                try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                state = 3
                print("NET-TCP-CONNECT: the guest sent FIN; ACKed and closed")
            } else if !payload.isEmpty {
                var text = ""
                for b in payload { text.append((b >= 0x20 && b < 0x7f) ? Character(UnicodeScalar(b)) : ".") }
                recvText.append(text)
                print("NET-TCP-CONNECT: received \(payload.count) byte(s): \(text)")
                ack = seq &+ UInt32(payload.count)
                if let answer = netTcpAuthAnswer(challenge: payload) {
                    let combined = answer + self.payload
                    let replyLen = buildTcpFrameExplicit(&reply, netTcpGuestMAC, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02], netTcpCliSrcIP, guestIP, cliPort, guestPort, self.seq, ack, 0x10, combined)
                    try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                    self.seq = self.seq &+ UInt32(combined.count)
                    state = 2
                    print("NET-TCP-CONNECT: answered the challenge (\(answer.count) bytes) with the \(netTcpConnectMac != nil ? "recorded replay MAC" : "computed HMAC"); sent \(self.payload.count)-byte payload")
                } else {
                    let replyLen = buildTcpFrameExplicit(&reply, netTcpGuestMAC, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02], netTcpCliSrcIP, guestIP, cliPort, guestPort, self.seq, ack, 0x10, [])
                    try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                    state = 3
                    print("NET-TCP-CONNECT: could not answer the challenge (malformed / no HMAC support); closing")
                }
            }
        case 2:
            // ESTABLISHED — the guest shell's data / a FIN.
            if isRst {
                if isStreamClient { try? streamInput?.close() }
                state = 3
                print("NET-TCP-CONNECT: the guest reset the connection (RST)")
            } else if isFin {
                if isStreamClient { try? streamInput?.close() }
                ack = seq &+ 1
                let replyLen = buildTcpFrameExplicit(&reply, netTcpGuestMAC, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02], netTcpCliSrcIP, guestIP, cliPort, guestPort, self.seq, ack, 0x10, [])
                try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                state = 3
                print("NET-TCP-CONNECT: the guest sent FIN; ACKed and closed")
            } else if isStreamClient {
                netTcpStreamLock.lock()
                if !payload.isEmpty {
                    if netTcpConnectIntruder && !intruderSent {
                        // The guest is ESTABLISHED and serving: now a
                        // second viewer knocks from the next port.
                        intruderSent = true
                        let synLen = buildTcpFrameExplicit(&reply, netTcpGuestMAC, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02], netTcpCliSrcIP, guestIP, cliPort &+ 1, guestPort, netTcpIntruderIsn, 0, 0x02, [])
                        try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<synLen]))
                        print("NET-TCP-INTRUDER: sent a second SYN from port \(cliPort &+ 1) while the first viewer is connected")
                    }
                    let fresh = streamAccept(seq, payload)
                    if !fresh.isEmpty {
                        streamRxBytes += fresh.count
                        if streamRxBytes <= netTcpStreamMaxRx {
                            // nil once the probe exited: a dead viewer reads nothing.
                            try? streamInput?.write(contentsOf: Data(fresh))
                        } else {
                            streamDone = true
                            print("NET-TCP-STREAM: inbound byte bound exceeded")
                        }
                    }
                }
                if (flags & 0x10) != 0 && tcpAck(buf) == self.seq {
                    streamInFlight = false
                }
                if !payload.isEmpty || isSynAck {
                    let replyLen = buildTcpFrameExplicit(&reply, netTcpGuestMAC, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02], netTcpCliSrcIP, guestIP, cliPort, guestPort, self.seq, ack, 0x10, [])
                    try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                }
                streamPump()
                netTcpStreamLock.unlock()
            } else if sshMode {
                if (flags & 0x02) != 0 {
                    // SYN-ACK retransmit after ESTABLISHED. Re-ACK
                    // only — another SSH chunk would overflow RX.
                    let replyLen = buildTcpFrameExplicit(&reply, netTcpGuestMAC, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02], netTcpCliSrcIP, guestIP, cliPort, guestPort, self.seq, ack, 0x10, [])
                    try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                    print("NET-TCP-CONNECT-SSH: re-ACK SYN-ACK retransmit")
                } else {
                    var fresh: [UInt8] = []
                    if !payload.isEmpty {
                        fresh = sshAccept(seq, payload)
                        if !fresh.isEmpty {
                            sshGuestDataSeen = true
                            if let client = sshClient {
                                sshTx.append(contentsOf: client.feed(fresh))
                            }
                        }
                    }
                    // Pace further chunks only after the guest has
                    // Recv'd (it then emits SSH bytes). Bare ACKs
                    // of the handshake chunk land while RX is full.
                    if sshGuestDataSeen {
                        if !sshSendChunk() {
                            if !payload.isEmpty {
                                let replyLen = buildTcpFrameExplicit(&reply, netTcpGuestMAC, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02], netTcpCliSrcIP, guestIP, cliPort, guestPort, self.seq, ack, 0x10, [])
                                try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                            }
                        }
                    } else if !payload.isEmpty {
                        let replyLen = buildTcpFrameExplicit(&reply, netTcpGuestMAC, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02], netTcpCliSrcIP, guestIP, cliPort, guestPort, self.seq, ack, 0x10, [])
                        try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                    }
                    if let client = sshClient, client.isClosed, sshTx.isEmpty {
                        let finLen = buildTcpFrameExplicit(&reply, netTcpGuestMAC, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02], netTcpCliSrcIP, guestIP, cliPort, guestPort, self.seq, ack, 0x11, [])
                        try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<finLen]))
                        self.seq = self.seq &+ 1
                        state = 4
                        print("NET-TCP-CONNECT-SSH: session done; sent FIN")
                    }
                }
            } else if !payload.isEmpty {
                ack = seq &+ UInt32(payload.count)
                var text = ""
                for b in payload { text.append((b >= 0x20 && b < 0x7f) ? Character(UnicodeScalar(b)) : ".") }
                recvText.append(text)
                print("NET-TCP-CONNECT: received \(payload.count) byte(s): \(text)")
                let replyLen = buildTcpFrameExplicit(&reply, netTcpGuestMAC, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02], netTcpCliSrcIP, guestIP, cliPort, guestPort, self.seq, ack, 0x10, [])
                try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
                // Close once the reply shows the command ran (the
                // configure marker) or, absent one, after the first
                // data segment.
                let shouldClose = netTcpConnectCloseAfter.map { recvText.contains($0) } ?? true
                if shouldClose {
                    let finLen = buildTcpFrameExplicit(&reply, netTcpGuestMAC, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02], netTcpCliSrcIP, guestIP, cliPort, guestPort, self.seq, ack, 0x11, [])
                    try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<finLen]))
                    self.seq = self.seq &+ 1
                    state = 4
                    print("NET-TCP-CONNECT: sent FIN (closing the session)")
                }
            }
        case 4:
            // FIN sent — expect the guest's ACK.
            if (flags & 0x10) != 0 {
                state = 3
                print("NET-TCP-CONNECT: close acknowledged (session done)")
            }
        default:
            break
        }
    }

    // Advance ack over in-order guest payload and return the new bytes.
    // Retransmits and out-of-order segments are dropped: feeding them
    // into SSHClient concatenates a second copy of the identification
    // line onto a partial KEXINIT and the client fails closed (observed
    // on the first live-ssh-server run as "malformed KEXINIT").
    func sshAccept(_ seq: UInt32, _ payload: [UInt8]) -> [UInt8] {
        if payload.isEmpty { return [] }
        let delta = Int32(bitPattern: seq &- ack)
        if delta > 0 {
            print("NET-TCP-CONNECT-SSH: dropped out-of-order seq 0x\(hex32(seq)) want 0x\(hex32(ack))")
            return []
        }
        let skip = Int(ack &- seq)
        if skip >= payload.count {
            print("NET-TCP-CONNECT-SSH: ignored retransmit seq 0x\(hex32(seq)) (acked through 0x\(hex32(ack)))")
            return []
        }
        let fresh = skip == 0 ? payload : Array(payload[skip...])
        ack = ack &+ UInt32(fresh.count)
        print("NET-TCP-CONNECT-SSH: received \(fresh.count) byte(s)")
        return fresh
    }

    // M70g G1 (#1491): pace one ≤192-byte segment of the SSH client's
    // output toward the guest. Same contract as
    // netTcpRespondSSHSendChunk: the guest kernel RX is a single bounded
    // slot with no reassembly.
    func sshSendChunk() -> Bool {
        guard sshMode, peerWindow != 0 else { return false }
        let total = sshTx.count
        let off = sshTxOffset
        guard off < total else { return false }
        let end = min(off + netTcpRespondPacketChunk, total)
        let chunk = Array(sshTx[off..<end])
        var reply = [UInt8](repeating: 0, count: 4096)
        let replyLen = buildTcpFrameExplicit(&reply, netTcpGuestMAC, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02], netTcpCliSrcIP, guestIP, cliPort, guestPort, seq, ack, 0x10, chunk)
        try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<replyLen]))
        seq = seq &+ UInt32(chunk.count)
        sshTxOffset = end
        print("NET-TCP-CONNECT-SSH: sent \(chunk.count) bytes (\(end)/\(total), seq 0x\(hex32(seq &- UInt32(chunk.count))))")
        if end >= total {
            sshTx.removeAll(keepingCapacity: true)
            sshTxOffset = 0
        }
        return true
    }

    // Runs only after a guest SYN-ACK, on the hermetic test path. Child
    // stdout is binary RFB, never printed as text; stderr is diagnostic
    // only. One reader drains stdout, and the network capture thread
    // writes stdin.
    func startStream() {
        guard let path = netTcpConnectStreamExec else { return }
        let proc = Process()
        let stdin = Pipe(), stdout = Pipe()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = netTcpConnectStreamArgs
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.standardError
        // A viewer that dies mid-update leaves guest bytes in flight;
        // writing them to its closed pipe must be an error, not a SIGPIPE
        // to the runner.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try proc.run()
        } catch {
            streamDone = true
            print("NET-TCP-STREAM: probe launch failed: \(error)")
            return
        }
        streamProcess = proc
        streamInput = stdin.fileHandleForWriting
        DispatchQueue.global().async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 192)
            while true {
                // FileHandle.readData(ofLength:) waits for the FULL
                // requested length on a pipe. RFB's 12-byte banner reply
                // would not reach the guest until EOF. POSIX read returns
                // each available chunk.
                let n = Darwin.read(stdout.fileHandleForReading.fileDescriptor, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                guard let self else { break }
                let bytes = Array(buf[..<n])
                netTcpStreamLock.lock()
                if self.streamTx.count + bytes.count > netTcpStreamMaxTx {
                    self.streamDone = true
                    netTcpStreamLock.unlock()
                    print("NET-TCP-STREAM: outbound byte bound exceeded")
                    break
                }
                self.streamTx.append(contentsOf: bytes)
                self.streamPump()
                netTcpStreamLock.unlock()
            }
            proc.waitUntilExit()
            let status = proc.terminationStatus
            print("NET-TCP-STREAM: probe exited status=\(status)")
            if let self {
                if self.intruderSent && !self.intruderAnswered {
                    print("NET-TCP-INTRUDER: no answer to the second SYN (dropped without RST)")
                }
                // The viewer's exit is its close: a clean exit is a FIN
                // after its last byte is ACKed, any other exit is a peer
                // that vanished (RST).
                netTcpStreamLock.lock()
                try? self.streamInput?.close()
                self.streamInput = nil
                if status == 0 && !self.streamDone {
                    self.streamEOF = true
                    self.streamPump()
                } else {
                    self.streamDone = true
                    self.streamReset()
                }
                netTcpStreamLock.unlock()
            }
        }
    }

    // Called under streamLock. Only an ESTABLISHED stream is reset: once
    // the guest has closed first there is nothing left to tear down.
    func streamReset() {
        guard state == 2 else { return }
        var rst: [UInt8] = []
        let len = buildTcpFrameExplicit(&rst, netTcpGuestMAC, [0x02, 0, 0, 0, 0, 0x02],
            netTcpCliSrcIP, guestIP, cliPort, guestPort, seq, ack, 0x14, [])
        try? netCaptureReadSocket?.write(contentsOf: Data(rst[0..<len]))
        state = 3
        print("NET-TCP-STREAM: the viewer died; sent RST")
    }

    // In-order, retransmit-safe byte delivery to the probe. The kernel
    // only has one RX segment slot, so the reverse path likewise sends
    // one <=192-byte chunk and waits for its ACK before advancing.
    // Called under streamLock.
    func streamAccept(_ seq: UInt32, _ payload: [UInt8]) -> [UInt8] {
        let delta = Int32(bitPattern: seq &- ack)
        if delta > 0 { return [] }
        let skip = Int(ack &- seq)
        if skip >= payload.count { return [] }
        let fresh = Array(payload[skip...])
        ack = ack &+ UInt32(fresh.count)
        return fresh
    }

    func streamPump() {
        if streamEOF && streamTx.isEmpty && !streamInFlight && !streamDone {
            streamDone = true
            guard state == 2 else { return }
            var fin: [UInt8] = []
            let len = buildTcpFrameExplicit(&fin, netTcpGuestMAC, [0x02, 0, 0, 0, 0, 0x02],
                netTcpCliSrcIP, guestIP, cliPort, guestPort, seq, ack, 0x11, [])
            try? netCaptureReadSocket?.write(contentsOf: Data(fin[0..<len]))
            seq = seq &+ 1
            state = 4
            print("NET-TCP-STREAM: the viewer closed; sent FIN")
            return
        }
        guard !streamInFlight && !streamTx.isEmpty && !streamDone && peerWindow != 0 else { return }
        let count = min(192, streamTx.count)
        let chunk = Array(streamTx.prefix(count))
        streamTx.removeFirst(count)
        var reply: [UInt8] = []
        let len = buildTcpFrameExplicit(&reply, netTcpGuestMAC, [0x02, 0, 0, 0, 0, 0x02],
            netTcpCliSrcIP, guestIP, cliPort, guestPort, seq, ack, 0x10, chunk)
        do {
            try? netCaptureReadSocket?.write(contentsOf: Data(reply[0..<len]))
            seq = seq &+ UInt32(count)
            streamInFlight = true
        } catch {
            streamDone = true
            print("NET-TCP-STREAM: transmit failed: \(error)")
        }
    }
}

// Card N4 (claim 0148): synthesize the ICMP ECHO REPLY to the echo
// request in `req` (the guest's bytes) into `reply` (same length):
// Ethernet dst/src swapped, ethertype 0x0800, IPv4 src/dst swapped, the
// identification ECHOED (deterministic — the gate asserts it), TTL 64,
// protocol 1, ICMP type 0 with the id/seq/payload echoed byte-exact;
// both checksums recomputed (RFC 1071).
func buildIcmpEchoReply(_ reply: inout [UInt8], _ req: [UInt8], _ n: Int, _ hostMAC: [UInt8], _ hostIP: [UInt8]) {
    reply = [UInt8](repeating: 0, count: n)
    reply[0...5] = req[6...11] // dst = the requester's MAC
    reply[6...11] = hostMAC[0...5] // src
    reply[12] = 0x08
    reply[13] = 0x00 // ethertype IPv4
    reply[14] = 0x45 // version 4, IHL 5
    reply[16...17] = req[16...17] // total length (unchanged)
    reply[18...19] = req[18...19] // identification ECHOED
    reply[22] = 64 // TTL
    reply[23] = 0x01 // protocol ICMP
    reply[26...29] = hostIP[0...3] // src = our address
    reply[30...33] = req[26...29] // dst = the requester's address
    let hdrChk = ipChecksum(reply, 14, 34)
    reply[24] = UInt8(hdrChk >> 8)
    reply[25] = UInt8(hdrChk & 0xff)
    reply[34] = 0x00 // ICMP echo reply
    reply[35] = 0x00 // code
    reply[38...n - 1] = req[38...n - 1] // id + seq + payload echoed
    let icmpChk = ipChecksum(reply, 34, n)
    reply[36] = UInt8(icmpChk >> 8)
    reply[37] = UInt8(icmpChk & 0xff)
}

// Claim 6684: script-mode lifecycle. Polls the serial log for the expected
// transcript; success (exit 0) once it appears and the claim-4912 tail
// window has elapsed, failure on timeout or an early VM stop.
// Issue #990 (claim #997): three robustness fixes for the silent-death
// flake (the run ended rc=1 with NO verdict while the guest had completed
// the whole flow byte-clean):
//   1. LOSSY decode — `String(decoding:as:)` never returns nil, so a
//      transient/partial multi-byte sequence at a poll instant can no
//      longer stall matching (the old `String(data:encoding:.utf8)`+
//      `try?` pair silently skipped EVERY match check for that poll and,
//      if the tail byte was permanently dangling, forever).
//   2. UNBUFFERED verdicts — the SUCCESS/FAILURE lines go through
//      FileHandle.standardOutput (direct write), so a killed/exited
//      process can no longer lose the verdict to stdio buffering.
//   3. Poll heartbeat — an unbuffered stderr line every 30 s proves the
//      poll recursion is alive; its absence in evidence localizes the
//      death to a specific window instead of "no verdict at all".
var scriptPollLastBeat: Date = Date()

// M115d (#2463): set by SuspendCtl's accepted-suspend tail — the stop a
// suspended VM lands is the teardown the guest asked for, so the poll's
// early-stop failure branch must not outrace it.
var suspendStopInFlight = false

func scriptPoll(matchedAt: Date? = nil) {
    var matchedAt = matchedAt
    // An early VM stop ends the run: pass when the expected transcript was
    // already observed (the tail window simply cannot capture more output),
    // otherwise fail. A ctl `suspend` teardown is its own success path.
    if !suspendStopInFlight && vmDidStart && (runner.vm.state == .stopped || runner.vm.state == .error) {
        // M120e (#2562): the drawer notes the end in script mode too —
        // the postmortem card + auto-open is the same model state the
        // session window would show, and the receipt is the live leg's
        // "drawer opened" evidence.
        noteVMEnd(runner.vm.state)
        // Issue #1024: the state was sampled BEFORE this tick's log read —
        // a VM that stops in the gap after the previous read makes this
        // branch see "stopped" while the transcript already sits in the
        // file from that same gap. Re-observe the log before judging: the
        // old order failed fully-green runs (rc=1, all asserts green) when
        // the stop landed in the inter-poll window.
        let textAtStop = String(decoding: (try? Data(contentsOf: serialURL)) ?? Data(), as: UTF8.self)
        if matchedAt == nil, let expect = scriptExpect, textAtStop.contains(expect) {
            FileHandle.standardOutput.write(Data("SUCCESS: expected transcript '\(expect)' observed in the serial log (VM ended; log re-read at verdict time, issue #1024).\n".utf8))
            finish(success: true)
            return
        }
        if matchedAt != nil {
            finish(success: true)
        } else {
            // Claim #1278: name the reason, not just the state. `state=3` on
            // its own is what made #1261 unfalsifiable from the outside.
            FileHandle.standardError.write(Data("FAILURE: VM ended before the expected transcript appeared (state=\(runner.vm.state.rawValue)).\(vmDelegate.verdict())\n".utf8))
            finish(success: false)
        }
        return
    }
    // Lossy decode (fix 1): invalid bytes become U+FFFD, never nil.
    let text = String(decoding: (try? Data(contentsOf: serialURL)) ?? Data(), as: UTF8.self)
    if !text.isEmpty { lastText = text; feedInspector(text) }
    if matchedAt == nil, let expect = scriptExpect, text.contains(expect) {
        // Claim 4912: the kernel prints the exec reap/report lines
        // (`tasks` / `procs <name> exited status=N`) from the shell idle
        // loop, which only wakes on the 1 Hz EL1 timer tick — up to ~1 s
        // AFTER the program's own last marker lands in this log. Tearing
        // down on the first match (the pre-4912 behavior) stopped the VM
        // inside that window and dropped the tail, flaking the live
        // gates. Hold the VM through `scriptExpectTail` so the tail
        // reaches the log, then finish. 0 = legacy immediate stop.
        if scriptExpectTail > 0 {
            FileHandle.standardOutput.write(Data("script-expect: transcript '\(expect)' observed — holding the VM for the \(scriptExpectTail)s tail window so post-marker kernel output (reap lines) reaches the serial log\n".utf8))
            matchedAt = Date()
        } else {
            FileHandle.standardOutput.write(Data("SUCCESS: expected transcript '\(expect)' observed in the serial log.\n".utf8))
            finish(success: true)
            return
        }
    }
    if let m = matchedAt, Date().timeIntervalSince(m) >= scriptExpectTail {
        let expect = scriptExpect ?? "<none>"
        FileHandle.standardOutput.write(Data("SUCCESS: expected transcript '\(expect)' observed in the serial log (claim-4912 tail window \(scriptExpectTail)s elapsed; post-marker output captured).\n".utf8))
        finish(success: true)
        return
    }
    captureScreenshotIfDue()
    captureScreenshotIfMarker(lastText)
    fireSnapshotsIfMarker(lastText)
    fireHostWriteIfMarker(lastText)
    fireHostClipInIfMarker(lastText)
    fireHostDropIfMarker(lastText)
    fireHostCmdsIfMarker(lastText)
    // Fix 3: the liveness heartbeat — unbuffered stderr every 30 s.
    if Date().timeIntervalSince(scriptPollLastBeat) >= 30 {
        scriptPollLastBeat = Date()
        FileHandle.standardError.write(Data("scriptPoll: alive (log=\(text.count) bytes, expect=\(scriptExpect ?? "<none>"), matched=\(matchedAt != nil))\n".utf8))
    }
    // `--timeout 0` = no deadline (shared with the evidence path above).
    if timeout > 0 && Date() > deadline {
        if matchedAt != nil {
            // The transcript appeared but --timeout cut the tail window
            // short — the gate's evidence is already in the log; pass.
            FileHandle.standardOutput.write(Data("SUCCESS: expected transcript '\(scriptExpect ?? "<none>")' observed before the deadline (claim-4912 tail window cut short by --timeout).\n".utf8))
            finish(success: true)
            return
        }
        FileHandle.standardOutput.write(Data("FAILURE: expected transcript '\(scriptExpect ?? "<none>")' not observed within \(Int(timeout))s (log=\(text.count) bytes).\n".utf8))
        // Issue #1024: re-read the serial log NOW — the log we just measured
        // against was read at the TOP of this poll tick, and the VM has run
        // for another 0.5 s since. Under host load VZ virtual time dilates
        // (the 1 Hz kernel heartbeat can land arbitrarily late on the wall
        // clock), and a marker that appeared in that gap made this path
        // exit 1 on a run whose gate evidence was fully intact (observed:
        // live-win-move rc=1 with all 25 asserts + both snapshots green).
        // A stale-read failure verdict is an observation bug, not gate
        // evidence; the log is the record either way.
        let finalText = String(decoding: (try? Data(contentsOf: serialURL)) ?? Data(), as: UTF8.self)
        if scriptExpect != nil, finalText.contains(scriptExpect!) {
            FileHandle.standardOutput.write(Data("SUCCESS: expected transcript '\(scriptExpect!)' observed in the serial log (raced the deadline — log re-read at verdict time, issue #1024).\n".utf8))
            finish(success: true)
            return
        }
        finish(success: scriptExpect == nil)
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { scriptPoll(matchedAt: matchedAt) }
}

var signalSources: [DispatchSourceSignal] = []

// All host exit sources funnel through HostLifecycle on the main queue.
// VZ state/stop remain on the VM queue; a close during start waits for its
// completion instead of racing a second VZ operation.
func stopHostSession(_ reason: String, code: Int32) {
    print("host-session: stopping reason=\(reason) pid=\(getpid())")
    fflush(stdout)
    let stopDeadline = Date().addingTimeInterval(15)
    runner.queue.async {
        @Sendable func complete(_ exitCode: Int32) {
            drainTeeBeforeExit("host-session \(reason)")
            restoreTerminal()
            print("host-session: stopped pid=\(getpid()) state=\(runner.vm.state.rawValue) code=\(exitCode)\(vmDelegate.verdict())")
            fflush(stdout)
            exit(exitCode)
        }
        // Also bounds a stop() whose completion never arrives. This is a
        // failure exit, not evidence that VZ stopped successfully.
        runner.queue.asyncAfter(deadline: .now() + 15) {
            FileHandle.standardError.write(Data("host-session: VM stop timed out, terminating owning process\n".utf8))
            complete(1)
        }
        @Sendable func step() {
            if runner.vm.state == .stopped || runner.vm.state == .error {
                complete(code)
            } else if runner.vm.canStop {
                runner.vm.stop { error in
                    if let error {
                        FileHandle.standardError.write(Data("host-session: VM stop failed: \(error)\n".utf8))
                        complete(1)
                    } else {
                        complete(code)
                    }
                }
            } else if Date() < stopDeadline {
                runner.queue.asyncAfter(deadline: .now() + 0.05) { step() }
            } else {
                FileHandle.standardError.write(Data("host-session: VM stop timed out, terminating owning process\n".utf8))
                complete(1)
            }
        }
        step()
    }
}

func hostSessionPoll() {
    guard let hostApplication,
          hostApplication.lifecycle.state != .stopping else { return }
    // M114a: --host-cmd-after fires in session mode on the same serial-log
    // scan the scripted poll uses — the mirror of choosing the menu item.
    let sessionText = String(decoding: (try? Data(contentsOf: serialURL)) ?? Data(), as: UTF8.self)
    if !sessionText.isEmpty { lastText = sessionText; feedInspector(sessionText) }
    fireHostCmdsIfMarker(lastText)
    runner.queue.async {
        let state = runner.vm.state
        DispatchQueue.main.async {
            if vmDidStart && (state == .stopped || state == .error) {
                // M114d (#2457) + M120e (#2562): the in-window postmortem
                // — the drawer opens itself on the stop/crash card
                // (state + the VZ delegate's reason + how deep the
                // serial tail is), and the host-inspector: receipt is
                // the same line the headless end paths print.
                noteVMEnd(state)
                hostApplication.showFailure("VM ended (state=\(state.rawValue)).\(vmDelegate.verdict())")
            } else if timeout > 0 && Date() > deadline {
                hostApplication.stop("session-timeout")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { hostSessionPoll() }
        }
    }
}

// Claim 2188: single-teardown guard for the console exit paths. All of
// them run on the main queue (the poll recursion and the signal sources
// both dispatch there), so a plain flag serializes them: the first path
// wins, later ones (a second signal, or a signal racing the timeout)
// return without double-stopping the VM or double-exiting.
var consoleExitStarted = false

/// Claim 2188: stop the VM if it is still running (every guest byte VZ
/// will deliver then lands in the pipe), then let the tee flush the
/// remaining bytes into the serial log before the process exits.
func stopAndDrainForExit(_ context: String) {
    runner.queue.async {
        runner.vm.stop { _ in
            drainTeeBeforeExit(context)
            exitWithTerminalRestore(consoleExitCode)
        }
    }
}

var consoleExitCode: Int32 = 0

func beginConsoleExit(_ context: String, code: Int32, restore: Bool = false) {
    guard !consoleExitStarted else { return }
    consoleExitStarted = true
    consoleExitCode = code
    if restore {
        restoreTerminal()
        FileHandle.standardError.write(Data("console: \(context) — terminal restored, draining guest output, exiting\n".utf8))
    } else {
        print("console: \(context) — ending session")
    }
    stopAndDrainForExit(context)
}

func installSignalHandlers() {
    guard consoleMode || hostSessionMode else { return }
    for sig: Int32 in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN) // suppress default termination; the source below handles it
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            if hostSessionMode {
                hostApplication?.stop("signal-\(sig)", code: 128 + sig)
                return
            }
            // Claim 2188: stop the VM (closes the serial pipe) and wait for
            // the tee to flush, instead of the old fixed 0.4 s sleep that
            // could still race the tee thread's final write. `restore:` is
            // true — the terminal is raw while the console session runs.
            beginConsoleExit("caught signal \(sig)", code: 128 + sig, restore: true)
        }
        src.resume()
        signalSources.append(src)
    }
}

func consolePoll() {
    // M114d (#2457): the drawer's tail feeds off the same serial log the
    // tee is writing — the model's offset ingest keeps only new lines.
    if let text = try? String(contentsOf: serialURL, encoding: .utf8), !text.isEmpty {
        feedInspector(text)
    }
    let state = runner.vm.state
    if vmDidStart && (state == .stopped || state == .error) {
        // M120e (#2562): the console-mode end notes the postmortem too —
        // same model, same receipt.
        noteVMEnd(state)
        // The VM already ended, so VZ closed the serial pipe — the tee is
        // draining on its own; wait for it instead of the fixed 0.5 s sleep.
        // Claim #1278: report the delegate's reason alongside the state on the
        // console-exit path too — this is the branch a passing-but-dead boot
        // takes, so it is the one that most often hid an error.
        beginConsoleExit("VM ended (state=\(state.rawValue)).\(vmDelegate.verdict())", code: 0)
        return
    }
    if consoleTimeout > 0, Date() > consoleDeadline {
        beginConsoleExit("session timed out after \(Int(consoleTimeout))s (VM state=\(state.rawValue))", code: 0)
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { consolePoll() }
}

func exitWithTerminalRestore(_ code: Int32) -> Never {
    restoreTerminal()
    exit(code)
}

if hostSessionMode {
    installSignalHandlers()
    setupDisplayWindow()
    startGuestOutputTee()
    if scriptMode { startScriptInput() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { hostSessionPoll() }
} else if vzRestore {
    // A warm leg's timeout is owned by scriptPoll (same deadline), which
    // exits through the ordinary script verdict — the probe's hard fail
    // is only for the marker-query modes that otherwise never leave.
    if !vzWarmLeg {
        runner.queue.asyncAfter(deadline: .now() + timeout) {
            fail("--vz-restore timed out; no successful restore verdict.")
        }
    }
} else if consoleMode {
    // Install signal handlers BEFORE engaging raw/character mode so there is
    // never a window where the terminal is raw with no restore path.
    installSignalHandlers()
    setupTerminal()
    startConsoleStreams()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { consolePoll() }
} else if scriptMode {
    // Claim 6684: non-interactive scripted input — tee guest output to the
    // log, forward the script after the terminal state, poll for the
    // expected transcript. Milestone six card G1 (claim 6053): when the
    // gpu device is attached (`--display`/`--screenshot`), the window is
    // created here too so the scripted run can capture the framebuffer.
    setupDisplayWindow()
    startGuestOutputTee()
    startScriptInput()
    startScript2Input()
    startScript3Input()
    startNetInject()
    startNetTcpConnect()
    startNativeSocketProbe()
    startKeyInject()
    startKeyStringInject()
    startChordInject()
    startPointerInject()
    startPointerVirtioInject()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { scriptPoll() }
} else {
    setupDisplayWindow()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
}
NativeInput.run(
    display: displayMode,
    input: inputMode,
    applicationLoop: {
        print("input: native AppKit event loop")
        NSApplication.shared.run()
    },
    headlessLoop: { RunLoop.main.run() }
)

// ---------------------------------------------------------------------------
// macOS 27 spike (capability-audit step 3): one default-off custom virtio
// device, so the guest's PCI discovery can observe it on a real VZ boot.
//
// Compiled only with -DSPIKE (the `zig build spike-virtio` step): the CI
// toolchain's macOS 26 SDK does not declare VZCustomVirtioDevice at all, so
// this whole section must be absent from the base class-A build.
//
// Device identity (guest-facing): virtio-pci VID 0x1af4, DID = 0x1040 | 0x42
// = 0x1082 — distinct from the console's DID 0x1043 (claim 0013) and blk's
// 0x1042 (claim 6420). PCI class 0x00 / subclass 0x00, one virtqueue.
//
// SDK reality (Xcode 27 beta 4, macOS 27.0): the framework exposes NO
// host-triggered guest-interrupt API — the WWDC26 "trigger an interrupt on
// the device" claim has no public symbol; the word "interrupt" appears in
// exactly one framework header (a POSIX EINTR param). The only host->guest
// signaling is the framework-internal used-buffer notification when queue
// elements are returned via VZVirtioQueueElement.returnToQueue. This spike
// is discovery + transport evidence only; the DRIVER_OK / queue-notification
// logs below give the audit its step-4 hooks for free.
// ---------------------------------------------------------------------------

#if SPIKE

@available(macOS 27.0, *)
enum CustomVirtioSpike {
    /// Virtio device ID; PCI DID presented to the guest = 0x1040 | deviceID.
    static let deviceID: UInt16 = 0x42
    static let pciClass: UInt8 = 0x00
    static let pciSubclass: UInt8 = 0x00
    // Two queues (claims 4374/4837): queue 0 = the exchange/transport
    // queue, queue 1 = the guest log transport. The claim-3141 push echo
    // (--cvc-echo) adds queue 2 — the queue COUNT is the capability signal;
    // the guest driver probes its size through the common config. The
    // claim-9588 input channel (--via-virtio) adds queue 3, and the
    // claim-0680 snapshot channel (--cvc-snap) adds queue 4 (virtqueues are
    // contiguous, so each deeper flag implies the full shape below it).
    static let queueCount: UInt16 = cvcFileEnabled ? 6 : (cvcSnapEnabled ? 5 : (viaVirtioEnabled ? 4 : (cvcEchoEnabled ? 3 : 2)))

    // ---- Claim 9588 INPUT channel (queue 3): HID-shaped input messages.
    // Wire format is normative in docs/hardware-contract.md:
    //   [kind u8][flags u8][len u16le][12-byte payload], fixed 16 bytes;
    //   kind 1 = raw 8-byte HID keyboard boot report [mods, 0, k0..k5];
    //   kind 2 = raw 5-byte absolute-pointer report [buttons, x_lo, x_hi,
    //   y_lo, y_hi] (claim 9367), HID absolute 0..32767 coords.
    static let inputMsgLen = 16
    static let inputKindKeyboard: UInt8 = 1
    static let inputKindPointer: UInt8 = 2
    static let inputKindConsoleCtrl: UInt8 = 3
    static let inputKindSnapshotReq: UInt8 = 4
    static let inputKeyboardReportLen = 8
    static let inputPointerReportLen = 5
    // HID boot-protocol modifier bits (the guest's hid_modifiers_to_flags
    // reads exactly these: bit0 LCtrl, bit1 LShift, bit2 LAlt, bit3 LCmd).
    static let hidModCtrl: UInt8 = 0x01
    static let hidModShift: UInt8 = 0x02
    static let hidModAlt: UInt8 = 0x04 // USB HID keyboard modifier bit 2 = LAlt

    /// One injected key report: (modifier byte, usage ID, down or up).
    struct HidStroke {
        let mods: UInt8
        let usage: UInt8
        let isDown: Bool
        var label: String { "\(isDown ? "down" : "up") usage=0x\(String(usage, radix: 16)) mods=0x\(String(mods, radix: 16))" }
    }

    /// Claim 9367: one injected pointer report — absolute logical coords
    /// (HID 0..32767 convention; the guest maps them onto the framebuffer)
    /// plus the button byte (bit0 = button 1, bit1 = button 2/right).
    /// M32 WMS5 (issue #625): the step grammar gains `d` (down, held) and
    /// `u` (up) so a DRAG can be expressed: move to the title bar, down,
    /// move while held, up — the established `c` click still expands to
    /// down+up at one point (zero regression for the claim 9367 gates).
    /// M124d (#2583): `rc` adds the right-button click for GOFILES'
    /// context-menu leg (the guest already maps buttons bit1 to SGR
    /// button 2 — only the injection grammar lacked a way to ask for it).
    /// M124e (#2584): `mc` adds the middle-button click (buttons bit2,
    /// 0x04) — the primary-selection paste gesture's injection.
    struct PtrStep {
        enum Mode {
            case move, click, down, up, rightClick, middleClick
        }

        let x: UInt16
        let y: UInt16
        let mode: Mode
        var label: String { "mode=\(mode) x=\(x) y=\(y)" }
    }

    /// Map one character of the `macKey` vocabulary to its HID usage ID +
    /// shift requirement (the guest keymap's inverse — a–z, 0–9, punctuation,
    /// space, `\n` = Enter). nil = outside the vocabulary (fail honestly).
    static func hidUsage(for ch: Character) -> (usage: UInt8, shift: Bool)? {
        switch ch {
        case "a": return (0x04, false); case "b": return (0x05, false)
        case "c": return (0x06, false); case "d": return (0x07, false)
        case "e": return (0x08, false); case "f": return (0x09, false)
        case "g": return (0x0A, false); case "h": return (0x0B, false)
        case "i": return (0x0C, false); case "j": return (0x0D, false)
        case "k": return (0x0E, false); case "l": return (0x0F, false)
        case "m": return (0x10, false); case "n": return (0x11, false)
        case "o": return (0x12, false); case "p": return (0x13, false)
        case "q": return (0x14, false); case "r": return (0x15, false)
        case "s": return (0x16, false); case "t": return (0x17, false)
        case "u": return (0x18, false); case "v": return (0x19, false)
        case "w": return (0x1A, false); case "x": return (0x1B, false)
        case "y": return (0x1C, false); case "z": return (0x1D, false)
        case "A": return (0x04, true);  case "B": return (0x05, true)
        case "C": return (0x06, true);  case "D": return (0x07, true)
        case "E": return (0x08, true);  case "F": return (0x09, true)
        case "G": return (0x0A, true);  case "H": return (0x0B, true)
        case "I": return (0x0C, true);  case "J": return (0x0D, true)
        case "K": return (0x0E, true);  case "L": return (0x0F, true)
        case "M": return (0x10, true);  case "N": return (0x11, true)
        case "O": return (0x12, true);  case "P": return (0x13, true)
        case "Q": return (0x14, true);  case "R": return (0x15, true)
        case "S": return (0x16, true);  case "T": return (0x17, true)
        case "U": return (0x18, true);  case "V": return (0x19, true)
        case "W": return (0x1A, true);  case "X": return (0x1B, true)
        case "Y": return (0x1C, true);  case "Z": return (0x1D, true)
        case "1": return (0x1E, false); case "2": return (0x1F, false)
        case "3": return (0x20, false); case "4": return (0x21, false)
        case "5": return (0x22, false); case "6": return (0x23, false)
        case "7": return (0x24, false); case "8": return (0x25, false)
        case "9": return (0x26, false); case "0": return (0x27, false)
        case "\n", "\r": return (0x28, false) // Enter / Return
        case " ": return (0x2C, false)		case "_": return (0x2D, true)
		case "+": return (0x2E, true)
		case ":": return (0x33, true)
		case "-": return (0x2D, false); case "=": return (0x2E, false)
        case "[": return (0x2F, false); case "]": return (0x30, false)
        case "\\": return (0x31, false)
        case ";": return (0x33, false); case "'": return (0x34, false)
        case "`": return (0x35, false)
        case ",": return (0x36, false); case ".": return (0x37, false)
        case "/": return (0x38, false); case "?": return (0x38, true)
        default: return nil
        }
    }

    /// Map one `macChord` token to (mods, usage). Same accepted vocabulary:
    /// named nav tokens + ctrl-a..ctrl-z + single printable chars. The nav
    /// usages are the guest keymap's editing cluster (arrows CSI x, Home/
    /// End/PgUp/PgDn; `delete` = forward-delete 0x4C → the guest's CSI 3~,
    /// matching the macOS-0x75 semantics macChord carries).
    static func hidChord(_ token: String) -> (mods: UInt8, usage: UInt8)? {        switch token {
        case "return": return (0, 0x28)
        case "space": return (0, 0x2C)
        case "comma": return (0, 0x36) // K12/K16: the CSV token separator cannot carry a literal comma
        case "ctrl-comma": return (hidModCtrl, 0x36)
        case "ctrl-space": return (hidModCtrl, 0x2C) // M37 DQ1: the God Menu summon chord
        case "tab": return (0, 0x2B)
        // WMS6 Gate A (issue #626): a real Alt+Tab chord over the HID channel
        // (LAlt modifier + Tab usage) — the WM's alt-tab policy hook.
        case "alt-tab": return (hidModAlt, 0x2B)
        case "alt-shift-tab": return (hidModAlt | hidModShift, 0x2B)
        // M63r (#1424): Ctrl+Tab / Ctrl+Shift+Tab were missing — the
        // ctrl-<letter> / ctrl-shift-<letter> patterns are letters only.
        case "ctrl-tab": return (hidModCtrl, 0x2B)
        case "ctrl-shift-tab": return (hidModCtrl | hidModShift, 0x2B)
        case "escape": return (0, 0x29)
        case "insert": return (0, 0x70)
        // M124e (#2584): the seat's primary-paste chord — the canonical
        // X11 spelling, free at every scope (ctrl+shift+v is split-cycle
        // at seat scope and tty clipboard paste at kernel-terminal scope).
        case "shift-insert": return (hidModShift, 0x70)
        case "f1": return (0, 0x3A)
        case "f2": return (0, 0x3B)
        case "f3": return (0, 0x3C)
        case "f4": return (0, 0x3D)
        case "f5": return (0, 0x3F)
        case "f6": return (0, 0x40)
        case "f7": return (0, 0x41)
        case "f8": return (0, 0x42)
        case "f9": return (0, 0x43)
        case "f10": return (0, 0x44)
        case "f11": return (0, 0x46)
        case "f12": return (0, 0x45)
        case "up": return (0, 0x52)
        case "down": return (0, 0x51)
        case "left": return (0, 0x50)
        case "right": return (0, 0x4F)
        case "home": return (0, 0x4A)
        case "end": return (0, 0x4D)
        case "delete": return (0, 0x4C)
        // M68a (#1449): `backspace` was missing from BOTH chord tables, so
        // any spec that edits a typed line (type, delete a char, type over
        // it) failed the whole sequence with "no HID mapping for chord
        // 'backspace'" and injected NOTHING — the go-sh gate then sat at its
        // prompt for its full 240 s deadline. Usage 0x2A is the guest
        // keymap's Backspace (kernel/src/input.zig maps it to byte 0x08),
        // so this behaves exactly like the physical key.
        case "backspace": return (0, 0x2A)
        case "pageup": return (0, 0x4B)
        case "pagedown": return (0, 0x4E)
        // M121b (#2565): the seat's tab-move chords — the ctrl-shift-<x>
        // pattern is letters only, so the editing-cluster pair is named.
        case "ctrl-shift-pageup": return (hidModCtrl | hidModShift, 0x4B)
        case "ctrl-shift-pagedown": return (hidModCtrl | hidModShift, 0x4E)
        // WM2 mission-control overview (Self-hosting Lane 1, issue #707
        // card 2, port of the #971 exploration): the overview hotkey —
        // LCtrl modifier + USB HID F12 usage (0x45). The guest kind-21
        // stream carries raw HID usages, so WND.BIN matches 0x45 for the
        // overview chord.
        case "ctrl-f12": return (hidModCtrl, 0x45)
        // M80k (#1727): the terminal's full-RIS chord. A THIRD modifier
        // is not expressible in the ctrl-/ctrl-shift- letter patterns
        // (they are letters only), so the triple-modifier chord is named
        // outright — usage 0x15 = 'r', the same key as ctrl-shift-r's
        // soft reset, so the guest can tell them apart by the alt bit.
        case "ctrl-shift-alt-r": return (hidModCtrl | hidModShift | hidModAlt, 0x15)
        default: break
        }
        if token.hasPrefix("ctrl-shift-"), token.count == 12 {
            let letter = token[token.index(token.startIndex, offsetBy: 11)]
            if let (usage, shift) = hidUsage(for: letter), !shift {
                return (hidModCtrl | hidModShift, usage)
            }
            return nil
        }
        if token.hasPrefix("ctrl-"), token.count == 6 {
            let letter = token[token.index(token.startIndex, offsetBy: 5)]
            if let (usage, shift) = hidUsage(for: letter), !shift {
                return (hidModCtrl, usage)
            }
            return nil
        }
        if token.count == 1, let (usage, shift) = hidUsage(for: token[token.startIndex]) {
            return (shift ? hidModShift : 0, usage)
        }
        return nil
    }

    /// Reverse of the free function macKey(for:): macOS virtual keycode →
    /// character, so `--input-key`'s numeric keycode can ride the HID
    /// channel (mirrors macKey's pairs exactly; nil = unmapped, loud fail).
    static func charFromMacCode(_ code: UInt16) -> Character? {
        switch code {
        case 0x00: return "a"; case 0x0B: return "b"; case 0x08: return "c"
        case 0x02: return "d"; case 0x0E: return "e"; case 0x03: return "f"
        case 0x05: return "g"; case 0x04: return "h"; case 0x22: return "i"
        case 0x26: return "j"; case 0x28: return "k"; case 0x25: return "l"
        case 0x2E: return "m"; case 0x2D: return "n"; case 0x1F: return "o"
        case 0x23: return "p"; case 0x0C: return "q"; case 0x0F: return "r"
        case 0x01: return "s"; case 0x11: return "t"; case 0x20: return "u"
        case 0x09: return "v"; case 0x0D: return "w"; case 0x07: return "x"
        case 0x10: return "y"; case 0x06: return "z"
        case 0x12: return "1"; case 0x13: return "2"; case 0x14: return "3"
        case 0x15: return "4"; case 0x17: return "5"; case 0x16: return "6"
        case 0x1A: return "7"; case 0x1C: return "8"; case 0x19: return "9"
        case 0x1D: return "0"
        case 0x31: return " "; case 0x24: return "\n"
        case 0x2F: return "."; case 0x2B: return ","; case 0x2C: return "/"
        case 0x1B: return "-"; case 0x18: return "="; case 0x21: return "["
        case 0x1E: return "]"; case 0x2A: return "\\"; case 0x29: return ";"
        case 0x27: return "'"; case 0x32: return "`"
        default: return nil
        }
    }

    /// Build the fixed 16-byte input message for one stroke (contract shape:
    /// [kind][flags=0][len LE][payload]; kind 1 payload = the raw report).
    static func inputMessage(mods: UInt8, usage: UInt8, isDown: Bool) -> Data {
        var msg = Data(repeating: 0, count: inputMsgLen)
        msg[0] = inputKindKeyboard
        msg[2] = UInt8(inputKeyboardReportLen & 0xff)
        if isDown {
            msg[4] = mods       // byte 0 of the HID boot report: modifiers
            msg[6] = usage      // byte 2: first keycode slot (byte 1 reserved)
        }
        // keyUp = the all-zero report — the guest's held-set transition
        // logic emits KEY_UP exactly like a physical release.
        return msg
    }

    /// Claim 9367: build the fixed 16-byte kind-2 pointer message — payload
    /// [buttons, x_lo, x_hi, y_lo, y_hi], the exact shape the guest's
    /// decode_pointer_report reads from an XHCI pointer report.
    static func inputPointerMessage(x: UInt16, y: UInt16, buttons: UInt8) -> Data {
        var msg = Data(repeating: 0, count: inputMsgLen)
        msg[0] = inputKindPointer
        msg[2] = UInt8(inputPointerReportLen & 0xff)
        msg[4] = buttons
        msg[5] = UInt8(x & 0xff)
        msg[6] = UInt8((x >> 8) & 0xff)
        msg[7] = UInt8(y & 0xff)
        msg[8] = UInt8((y >> 8) & 0xff)
        return msg
    }

    /// Enqueue one pre-built input message into a pre-armed receive buffer
    /// on queue 3 and return it (used ring advance + SPI — the only
    /// host→guest data path). Runs ON the device delegate queue so element
    /// access stays single-threaded with the callbacks. Returns false when
    /// the pool is momentarily empty (the caller retries — ordering
    /// preserved); shape or write failures report loudly on stderr.
    @discardableResult
    static func enqueueMessageNow(_ msg: Data, label: String) -> Bool {
        guard let device, let queue = device.queue(at: 3) else {
            FileHandle.standardError.write(Data("ERROR: CUSTOM-VIRTIO-INPUT: queue 3 unavailable (device \(device == nil ? "nil" : "present"))\n".utf8))
            return true // unrecoverable: do not retry-spin the sequence
        }
        guard let element = queue.nextElement() else {
            return false // pool empty: retry THIS message, later ones wait
        }
        do {
            try element.write(msg)
        } catch {
            FileHandle.standardError.write(Data("ERROR: CUSTOM-VIRTIO-INPUT: write FAILED (\(label)): \(error)\n".utf8))
            element.returnToQueue()
            return true
        }
        element.returnToQueue()
        print("CUSTOM-VIRTIO-INPUT: enqueued \(label) (\(msg.count)-byte message)")
        return true
    }

    /// Keyboard convenience: build + enqueue one stroke's message.
    static func enqueueInputNow(_ stroke: HidStroke, sequenceTag: String) -> Bool {
        let msg = inputMessage(mods: stroke.mods, usage: stroke.usage, isDown: stroke.isDown)
        return enqueueMessageNow(msg, label: "\(sequenceTag) \(stroke.label)")
    }

    /// Deliver a stroke sequence in STRICT order on the device queue: the
    /// next stroke is scheduled only after the previous one was accepted,
    /// so a pool-empty retry delays the rest of the sequence instead of
    /// reordering it (observed live, claim 9588: a fixed-schedule burst hit
    /// a momentarily empty pool and typed 'inpu⏎t' — the guest executed two
    /// garbled commands). 0.25 s pacing; exhaustion fails LOUDLY, never
    /// drops silently.
    static func injectStrokes(_ strokes: [HidStroke], sequenceTag: String) {
        deviceQueue.async {
            deliverStrokes(strokes, sequenceTag: sequenceTag, index: 0, attempts: 0)
        }
    }

    private static func deliverStrokes(_ strokes: [HidStroke], sequenceTag: String, index: Int, attempts: Int) {
        if index >= strokes.count {
            print("CUSTOM-VIRTIO-INPUT: sequence complete tag=\(sequenceTag) n=\(strokes.count) ok=true")
            return
        }
        let stroke = strokes[index]
        if enqueueInputNow(stroke, sequenceTag: sequenceTag) {
            deviceQueue.asyncAfter(deadline: .now() + 0.25) {
                deliverStrokes(strokes, sequenceTag: sequenceTag, index: index + 1, attempts: 0)
            }
        } else if attempts < 40 {
            deviceQueue.asyncAfter(deadline: .now() + 0.25) {
                deliverStrokes(strokes, sequenceTag: sequenceTag, index: index, attempts: attempts + 1)
            }
        } else {
            FileHandle.standardError.write(Data("ERROR: CUSTOM-VIRTIO-INPUT: rx pool empty after 40 retries (\(sequenceTag) \(stroke.label)) — sequence ABORTED at \(index)/\(strokes.count)\n".utf8))
        }
    }

    /// Claim 9367: deliver a POINTER step sequence in STRICT order on the
    /// device queue — same shape as the stroke ladder (0.25 s pacing, pool-
    /// empty retry delays the rest instead of reordering, exhaustion fails
    /// LOUDLY). Each move is one kind-2 message; a click step emits
    /// down then up at the same coords so the guest's button edge logic
    /// sees exactly what a physical click produces.
    /// Claim 9367: deliver a POINTER step sequence in STRICT order on the
    /// device queue — same shape as the stroke ladder (pool-empty retry
    /// delays the rest instead of reordering, exhaustion fails LOUDLY).
    /// Each move is one kind-2 message; a click step emits down then up at
    /// the same coords so the guest's button edge logic sees exactly what a
    /// physical click produces. PACING: pointer presses are edge-detected
    /// by driving_award.pointer_tick, which runs once per shell-idle pass —
    /// at the Road Pops present cadence (~1.5–2 s, observed claim-time),
    /// NOT per message. Spacing below one idle pass collapses press+release
    /// into a single tick and the click never fires (observed live, this
    /// claim), so pointer sequences pace at `pacingSeconds` (default 2.5 s,
    /// the same order as the synthesized chord paths' 2–3 s).
    static func injectPointerSteps(_ steps: [PtrStep], sequenceTag: String, pacingSeconds: Double = 2.5) {
        deviceQueue.async {
            var msgs: [(Data, String)] = []
            var held = false
            for s in steps {
                switch s.mode {
                case .move:
                    // A move between down and up carries the held button
                    // (the WMS5 drag choreography); a leading move is a bare
                    // hover (buttons 0) exactly like the claim 9367 gates.
                    let buttons: UInt8 = held ? 0x01 : 0
                    msgs.append((inputPointerMessage(x: s.x, y: s.y, buttons: buttons), "\(sequenceTag) move buttons=0x\(String(buttons, radix: 16)) x=\(s.x) y=\(s.y)"))
                case .click:
                    msgs.append((inputPointerMessage(x: s.x, y: s.y, buttons: 0), "\(sequenceTag) move buttons=0x0 x=\(s.x) y=\(s.y)"))
                    msgs.append((inputPointerMessage(x: s.x, y: s.y, buttons: 0x01), "\(sequenceTag) down buttons=0x1 x=\(s.x) y=\(s.y)"))
                    msgs.append((inputPointerMessage(x: s.x, y: s.y, buttons: 0), "\(sequenceTag) up buttons=0x0 x=\(s.x) y=\(s.y)"))
                case .rightClick:
                    // Same click choreography, button byte bit1: the
                    // guest's right-button edge logic sees a physical
                    // right-click (driving_award maps it to SGR button 2).
                    msgs.append((inputPointerMessage(x: s.x, y: s.y, buttons: 0), "\(sequenceTag) move buttons=0x0 x=\(s.x) y=\(s.y)"))
                    msgs.append((inputPointerMessage(x: s.x, y: s.y, buttons: 0x02), "\(sequenceTag) down buttons=0x2 x=\(s.x) y=\(s.y)"))
                    msgs.append((inputPointerMessage(x: s.x, y: s.y, buttons: 0), "\(sequenceTag) up buttons=0x0 x=\(s.x) y=\(s.y)"))
                case .middleClick:
                    // M124e: same click choreography, button byte bit2 —
                    // the guest sees a physical middle-click (the seat's
                    // hidBtnMiddle edge), which is the primary-paste
                    // gesture when the target's manifest row opts in.
                    msgs.append((inputPointerMessage(x: s.x, y: s.y, buttons: 0), "\(sequenceTag) move buttons=0x0 x=\(s.x) y=\(s.y)"))
                    msgs.append((inputPointerMessage(x: s.x, y: s.y, buttons: 0x04), "\(sequenceTag) down buttons=0x4 x=\(s.x) y=\(s.y)"))
                    msgs.append((inputPointerMessage(x: s.x, y: s.y, buttons: 0), "\(sequenceTag) up buttons=0x0 x=\(s.x) y=\(s.y)"))
                case .down:
                    msgs.append((inputPointerMessage(x: s.x, y: s.y, buttons: 0), "\(sequenceTag) move buttons=0x0 x=\(s.x) y=\(s.y)"))
                    msgs.append((inputPointerMessage(x: s.x, y: s.y, buttons: 0x01), "\(sequenceTag) down buttons=0x1 x=\(s.x) y=\(s.y)"))
                    held = true
                case .up:
                    // Land at the target WHILE held (the guest issues its
                    // final SET_WINDOW there), then release — a physical
                    // mouse's up lands at the drag's final position.
                    msgs.append((inputPointerMessage(x: s.x, y: s.y, buttons: 0x01), "\(sequenceTag) move buttons=0x1 x=\(s.x) y=\(s.y)"))
                    msgs.append((inputPointerMessage(x: s.x, y: s.y, buttons: 0), "\(sequenceTag) up buttons=0x0 x=\(s.x) y=\(s.y)"))
                    held = false
                }
            }
            deliverMessages(msgs, sequenceTag: sequenceTag, index: 0, attempts: 0, pacingSeconds: pacingSeconds)
        }
    }

    private static func deliverMessages(_ msgs: [(Data, String)], sequenceTag: String, index: Int, attempts: Int, pacingSeconds: Double = 0.25) {
        if index >= msgs.count {
            print("CUSTOM-VIRTIO-INPUT: sequence complete tag=\(sequenceTag) n=\(msgs.count) ok=true")
            return
        }
        let (msg, label) = msgs[index]
        if enqueueMessageNow(msg, label: label) {
            deviceQueue.asyncAfter(deadline: .now() + pacingSeconds) {
                deliverMessages(msgs, sequenceTag: sequenceTag, index: index + 1, attempts: 0, pacingSeconds: pacingSeconds)
            }
        } else if attempts < 40 {
            deviceQueue.asyncAfter(deadline: .now() + pacingSeconds) {
                deliverMessages(msgs, sequenceTag: sequenceTag, index: index, attempts: attempts + 1, pacingSeconds: pacingSeconds)
            }
        } else {
            FileHandle.standardError.write(Data("ERROR: CUSTOM-VIRTIO-INPUT: rx pool empty after 40 retries (\(label)) — sequence ABORTED at \(index)/\(msgs.count)\n".utf8))
        }
    }

    // ---- Claim 0680 control plane (queue 3 carries kinds 3/4 alongside
    // the input kinds; queue 4 streams the framebuffer back) ----

    /// Build a fixed 16-byte control message ([kind][flags=0][len LE][payload]).
    static func controlMessage(_ kind: UInt8, payload: [UInt8]) -> Data {
        var msg = Data(repeating: 0, count: inputMsgLen)
        msg[0] = kind
        msg[2] = UInt8(payload.count & 0xff)
        for (i, b) in payload.enumerated() { msg[4 + i] = b }
        return msg
    }

    /// Snapshot wire tags + sizes (normative in docs/hardware-contract.md).
    static let snapTagHeader: UInt8 = 0x01
    static let snapTagChunk: UInt8 = 0x02
    static let snapTagDone: UInt8 = 0x03

    /// One in-flight snapshot assembly (touched only on the deviceQueue —
    /// the same serial discipline as every other element access).
    struct SnapAssembly {
        var width = 0
        var height = 0
        var bpp = 0
        var total = 0
        var chunkLen = 0
        var expectedChunks = 0
        var receivedChunks = 0
        var data = Data()
        var outPath = ""
    }
    static var snap: SnapAssembly?
    /// The output path of the snapshot request most recently sent — set by
    /// fireSnapshotsIfMarker, consumed by the stream's header message.
    static var pendingSnapPath: String?

    /// Issue #1788: is a kind-4 scanout stream in flight right now? Read
    /// with a sync hop onto deviceQueue, so the pair is observed the same
    /// serial way the callbacks mutate it.
    static func snapshotStreamInFlight() -> Bool {
        deviceQueue.sync { snap != nil || pendingSnapPath != nil }
    }

    // ---- Claim 3141 host-push echo state (all touched only on the
    // device's serial deviceQueue) ----
    // The byte-exact request the host app writes into the guest's pre-armed
    // receive buffer, and the phase machine:
    //   0 idle            — the rx buffer is armed, waiting for the guest's
    //                       "cvc-push-armed" log line to trigger the push
    //   1 awaiting reply  — the request was enqueued + returned
    //   2 done            — the reply was observed and verified (or failed)
    static let pushRequest = Data("CVC-PING-0x42".utf8)
    /// Byte-exact success line constants (the gate greps these verbatim).
    static let pushRequestText = "CVC-PING-0x42"
    static var pushPhase = 0

    // The provider holds the configuration delegate *weakly* and the created
    // VZCustomVirtioDevice holds the device delegate *weakly* too, so both
    // delegates must be kept alive for the VM's whole lifetime or the device
    // silently goes deaf. Static stored properties live forever.
    static let configDelegate = CustomVirtioSpikeConfigDelegate()
    static let deviceDelegate = CustomVirtioSpikeDeviceDelegate()

    /// THE device delegate queue, created here so the injection paths can
    /// schedule their element access onto the SAME serial queue the
    /// callbacks run on (all queue-element access single-threaded).
    static let deviceQueue = DispatchQueue(label: "virelaios.customvirtio")

    /// The live device (captured at didCreateDevice; strong — lives as long
    /// as the VM). The input-injection paths dereference it on deviceQueue.
    static var device: VZCustomVirtioDevice?

    static func attach(to config: VZVirtualMachineConfiguration) -> String {
        let provider = VZCustomVirtioDeviceDelegateProvider(
            deviceQueue: deviceQueue,
            delegate: configDelegate
        )

        let deviceConfig = VZCustomVirtioDeviceConfiguration()
        deviceConfig.deviceID = deviceID
        deviceConfig.pciClassID = pciClass
        deviceConfig.pciSubclassID = pciSubclass
        deviceConfig.virtioQueueCount = queueCount
        deviceConfig.provider = provider

        config.customVirtioDevices = [deviceConfig]

        let did = 0x1040 + Int(deviceID)  // virtio transitional PCI DID = 0x1040 + device_id (add, not OR)
        if cvcFileEnabled {
            return String(
                format: "  custom virtio: ENABLED — VID 0x1af4 DID 0x%04x (virtio deviceID 0x%02x), class 0x%02x/0x%02x, %d queue(s) incl. push-echo, INPUT, SNAPSHOT, and the M34 FILE channel (queue 5) serving \"%@\" (--cvc-file)",
                did, Int(deviceID), Int(pciClass), Int(pciSubclass), Int(queueCount), cvcFileShareDir ?? "<none>"
            )
        }
        if cvcSnapEnabled {
            return String(
                format: "  custom virtio: ENABLED — VID 0x1af4 DID 0x%04x (virtio deviceID 0x%02x), class 0x%02x/0x%02x, %d queue(s) incl. the claim-3141 push-echo queue, the claim-9588 INPUT queue, and the claim-0680 SNAPSHOT queue (--cvc-snap)",
                did, Int(deviceID), Int(pciClass), Int(pciSubclass), Int(queueCount)
            )
        }
        if viaVirtioEnabled {
            return String(
                format: "  custom virtio: ENABLED — VID 0x1af4 DID 0x%04x (virtio deviceID 0x%02x), class 0x%02x/0x%02x, %d queue(s) incl. the claim-3141 push-echo queue and the claim-9588 INPUT queue (--via-virtio)",
                did, Int(deviceID), Int(pciClass), Int(pciSubclass), Int(queueCount)
            )
        }
        if cvcEchoEnabled {
            return String(
                format: "  custom virtio: ENABLED — VID 0x1af4 DID 0x%04x (virtio deviceID 0x%02x), class 0x%02x/0x%02x, %d queue(s) incl. the claim-3141 push-echo queue (--cvc-echo)",
                did, Int(deviceID), Int(pciClass), Int(pciSubclass), Int(queueCount)
            )
        }
        return String(
            format: "  custom virtio: ENABLED — VID 0x1af4 DID 0x%04x (virtio deviceID 0x%02x), class 0x%02x/0x%02x, %d queue(s); guest PCI discovery evidence (spike)",
            did, Int(deviceID), Int(pciClass), Int(pciSubclass), Int(queueCount)
        )
    }
}

/// Receives the created device and wires the device delegate. Called on the
/// VM's serial queue when VZVirtualMachine is created.
@available(macOS 27.0, *)
final class CustomVirtioSpikeConfigDelegate: NSObject, VZCustomVirtioDeviceConfigurationDelegate {
    func customVirtioConfiguration(_ deviceConfiguration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice) {
        print("CUSTOM-VIRTIO: device created (didCreateDevice)")
        device.delegate = CustomVirtioSpike.deviceDelegate
        // Claim 9588: capture the live device so the input-injection paths
        // can reach its queues (they touch it on CustomVirtioSpike.deviceQueue
        // only — the same serial queue every callback runs on).
        CustomVirtioSpike.device = device
    }
}

/// Device lifecycle + guest-driver evidence. Every method here is optional in
/// the protocol; only the ones the spike needs are implemented.
///
/// Audit step 4/5 (claim 0828): on a queue notification the delegate
/// dequeues every available element (the guest's known-payload descriptor),
/// logs the exact bytes, and returns the element via `returnToQueue` — the
/// framework then advances the used ring AND asserts the device's
/// interrupt (the framework-internal used-buffer notification, the only
/// host→guest signaling the macOS 27 SDK exposes). The callback runs on the
/// provider's deviceQueue (serial), so element access is single-threaded.
@available(macOS 27.0, *)
final class CustomVirtioSpikeDeviceDelegate: NSObject, VZCustomVirtioDeviceDelegate {
    func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        print("CUSTOM-VIRTIO: guest set DRIVER_OK — negotiation complete, queues ready")
    }

    func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        print("CUSTOM-VIRTIO: guest notified queue \(queue.queueIndex) (size \(queue.queueSize))")
        if queue.queueIndex == 2 && cvcEchoEnabled {
            // Claim 3141 push-echo queue: phase-dependent handling — never
            // drain it blindly (the armed rx buffer must survive until the
            // host chooses to enqueue into it).
            handlePushNotification(device: device, queue: queue)
            return
        }
        if queue.queueIndex == 3 && viaVirtioEnabled {
            // Claim 9588 input queue: notifications here are the guest's
            // arm-time kick and per-batch replenish kicks. The rx buffers
            // are the GUEST's — never dequeue them; each log line is the
            // host-side evidence that the pool is cycling.
            print("CUSTOM-VIRTIO-INPUT: queue 3 notified (guest rx pool cycling)")
            return
        }
        if queue.queueIndex == 4 && cvcSnapEnabled {
            // Claim 0680 snapshot queue: the guest streams header/chunk/
            // done messages as device-read payloads; each element is
            // acknowledged ("OK:<n>") and returned so the guest's next
            // submit can proceed.
            handleSnapshotNotification(queue: queue)
            return
        }
        if queue.queueIndex == 5 && cvcFileEnabled {
            // M34 HF1+HF2 (issues #735/#736): the host file channel — the
            // guest sends one framed request per element; the host serves
            // it with FileManager calls rooted at the share dir (stateless:
            // no handles, nothing held between requests). VF_PROBE is the
            // transport-only 32 KiB device-write spike.
            handleFileNotification(queue: queue)
            return
        }
        // Drain every available element (many may be in flight — claim
        // 4374's concurrency): queue 0 exchanges get the payload echoed
        // back verbatim; queue 1 log lines are printed to stdout and
        // answered with ACK:<len> (claim 4837). Then return each element
        // so the used ring advances (its length reflects writtenByteCount)
        // and the device IRQ asserts.
        while let element = queue.nextElement() {
            process(element: element, device: device, queueIndex: Int(queue.queueIndex))
        }
    }

    /// Claim 3141: queue-2 notifications. Phase 0 = the arm-time kick (the
    /// guest pre-armed its receive buffer) — log and leave the buffer in
    /// place. Phase 1 = the guest's reply arrived after our push — verify
    /// byte-exactly, write the ack, return.
    private func handlePushNotification(device: VZCustomVirtioDevice, queue: VZVirtioQueue) {
        switch CustomVirtioSpike.pushPhase {
        case 0:
            print("CUSTOM-VIRTIO-PUSH: queue 2 notified with the rx buffer armed (idle — waiting for the guest's armed signal)")
        case 1:
            while let element = queue.nextElement() {
                var bytes: [UInt8] = []
                for buffer in element.readBuffers() {
                    bytes.append(contentsOf: [UInt8](buffer))
                }
                let expected = [UInt8](CustomVirtioSpike.pushRequest)
                if bytes == expected {
                    // Byte-exact reply observed: acknowledge with OK:<len>
                    // so the guest can verify the full loop closed.
                    let ackText = "OK:\(bytes.count)"
                    do {
                        try element.write(Data(ackText.utf8))
                        print("CUSTOM-VIRTIO-PUSH: reply verified rsp=\"\(CustomVirtioSpike.pushRequestText)\" (byte-exact), wrote ack=\"\(ackText)\"")
                    } catch {
                        print("CUSTOM-VIRTIO-PUSH: ack write FAILED: \(error)")
                    }
                } else {
                    print("CUSTOM-VIRTIO-PUSH: reply MISMATCH (\(bytes.count) byte(s), expected \(expected.count)): hex=[\(hexSummary(bytes))]")
                }
                element.returnToQueue()
                CustomVirtioSpike.pushPhase = 2
            }
        default:
            print("CUSTOM-VIRTIO-PUSH: unexpected queue 2 notification in phase \(CustomVirtioSpike.pushPhase)")
        }
    }

    /// Claim 3141: the host app ENQUEUES the request. Called on observing
    /// the guest's "cvc-push-armed" log line (event-driven — no timing
    /// dance): dequeue the pre-armed receive buffer, write the request into
    /// it, return it. The framework then advances the used ring and asserts
    /// the device interrupt — the only host→guest data path the SDK exposes.
    private func enqueuePushRequest(device: VZCustomVirtioDevice) {
        guard CustomVirtioSpike.pushPhase == 0 else {
            print("CUSTOM-VIRTIO-PUSH: push requested in phase \(CustomVirtioSpike.pushPhase) (skipped)")
            return
        }
        guard let queue = device.queue(at: 2) else {
            print("CUSTOM-VIRTIO-PUSH: queueAtIndex(2) unavailable")
            return
        }
        guard let element = queue.nextElement() else {
            print("CUSTOM-VIRTIO-PUSH: no pre-armed rx buffer available (nextElement nil)")
            return
        }
        guard element.readBuffersByteCount == 0, element.writeBuffersByteCount >= CustomVirtioSpike.pushRequest.count else {
            print("CUSTOM-VIRTIO-PUSH: unexpected rx shape (read \(element.readBuffersByteCount), write \(element.writeBuffersByteCount))")
            element.returnToQueue()
            return
        }
        do {
            try element.write(CustomVirtioSpike.pushRequest)
        } catch {
            print("CUSTOM-VIRTIO-PUSH: request write FAILED: \(error)")
            element.returnToQueue()
            return
        }
        element.returnToQueue()
        CustomVirtioSpike.pushPhase = 1
        print("CUSTOM-VIRTIO-PUSH: host enqueued req=\"\(CustomVirtioSpike.pushRequestText)\" (\(CustomVirtioSpike.pushRequest.count) byte(s)) into the pre-armed rx buffer")
    }

    /// Claim 0680: queue-4 notifications — reassemble the guest's tagged
    /// snapshot stream (header → chunks → done) into a raw BGRX file.
    /// Strict-order assembly: the guest submits sequentially and waits for
    /// each OK, so chunk seq must equal the received count. Any mismatch
    /// reports loudly, drops the assembly, and still acknowledges the
    /// element (the guest counts its own failure; neither side wedges).
    private func handleSnapshotNotification(queue: VZVirtioQueue) {
        while let element = queue.nextElement() {
            var bytes: [UInt8] = []
            for buffer in element.readBuffers() {
                bytes.append(contentsOf: [UInt8](buffer))
            }
            if let err = consumeSnapshotMessage(bytes) {
                print("CVC-SNAPSHOT: ERROR \(err) (\(bytes.count)-byte message dropped, assembly aborted)")
                CustomVirtioSpike.snap = nil
            }
            do {
                try element.write(Data("OK:\(bytes.count)".utf8))
            } catch {
                print("CVC-SNAPSHOT: ack write FAILED: \(error)")
            }
            element.returnToQueue()
        }
    }

    /// Consume one tagged snapshot message; nil = accepted, String = loud
    /// error. Mirrors the guest's little-endian framing exactly.
    private func consumeSnapshotMessage(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 1 else { return "empty message" }
        switch bytes[0] {
        case CustomVirtioSpike.snapTagHeader:
            guard bytes.count >= 24 else { return "short header" }
            guard bytes[1...4].elementsEqual("SNAP".utf8) else { return "bad header magic" }
            guard bytes[5] == 1 else { return "unsupported header version \(bytes[5])" }
            var a = CustomVirtioSpike.SnapAssembly()
            func le32(_ off: Int) -> Int {
                Int(bytes[off]) | (Int(bytes[off + 1]) << 8) | (Int(bytes[off + 2]) << 16) | (Int(bytes[off + 3]) << 24)
            }
            a.bpp = Int(bytes[6])
            a.width = le32(8)
            a.height = le32(12)
            a.total = le32(16)
            a.chunkLen = le32(20)
            guard a.width > 0, a.height > 0, a.bpp == 4 else { return "nonsensical geometry w=\(a.width) h=\(a.height) bpp=\(a.bpp)" }
            guard a.total > 0, a.chunkLen > 0 else { return "nonsensical sizes total=\(a.total) chunk=\(a.chunkLen)" }
            a.expectedChunks = (a.total + a.chunkLen - 1) / a.chunkLen
            a.data.reserveCapacity(a.total)
            // The out path rides the trigger that requested THIS stream;
            // keep it across the header reset by re-reading the pending
            // trigger assignment made in fireSnapshotsIfMarker.
            if let pending = CustomVirtioSpike.pendingSnapPath { a.outPath = pending }
            CustomVirtioSpike.pendingSnapPath = nil
            CustomVirtioSpike.snap = a
            print("CVC-SNAPSHOT: header w=\(a.width) h=\(a.height) bpp=\(a.bpp) total=\(a.total) chunk=\(a.chunkLen) chunks=\(a.expectedChunks) → \(a.outPath)")
            return nil
        case CustomVirtioSpike.snapTagChunk:
            guard var a = CustomVirtioSpike.snap else { return "chunk before header" }
            guard bytes.count >= 12 else { return "short chunk envelope" }
            let seq = Int(bytes[2]) | (Int(bytes[3]) << 8)
            let len = Int(bytes[4]) | (Int(bytes[5]) << 8)
            let cksum = UInt16(Int(bytes[6]) | (Int(bytes[7]) << 8))
            guard seq == a.receivedChunks else { return "chunk seq \(seq) out of order (expected \(a.receivedChunks))" }
            guard len == bytes.count - 12, len > 0 else { return "chunk len field \(len) != payload \(bytes.count - 12)" }
            guard rfc1071(Array(bytes[12...])) == cksum else { return "chunk seq \(seq) cksum mismatch" }
            a.data.append(contentsOf: bytes[12...])
            a.receivedChunks += 1
            CustomVirtioSpike.snap = a
            if a.receivedChunks % 32 == 0 {
                print("CVC-SNAPSHOT: chunk \(a.receivedChunks)/\(a.expectedChunks)")
            }
            return nil
        case CustomVirtioSpike.snapTagDone:
            guard let a = CustomVirtioSpike.snap else { return "done before header" }
            guard bytes.count >= 10 else { return "short done message" }
            let chunks = Int(bytes[2]) | (Int(bytes[3]) << 8)
            let total = Int(bytes[4]) | (Int(bytes[5]) << 8) | (Int(bytes[6]) << 16) | (Int(bytes[7]) << 24)
            let cksum = UInt16(Int(bytes[8]) | (Int(bytes[9]) << 8))
            guard chunks == a.expectedChunks, chunks == a.receivedChunks else {
                return "done claims \(chunks) chunks (expected \(a.expectedChunks), received \(a.receivedChunks))"
            }
            guard total == a.data.count else { return "done claims \(total) bytes (received \(a.data.count))" }
            let frameCksum = rfc1071([UInt8](a.data))
            guard frameCksum == cksum else {
                return String(format: "frame cksum mismatch got=0x%04x want=0x%04x", frameCksum, cksum)
            }
            let out = Data(a.data)
            let url = URL(fileURLWithPath: a.outPath)
            do {
                try out.write(to: url)
            } catch {
                return "raw write to \(a.outPath) FAILED: \(error)"
            }
            print(String(format: "CVC-SNAPSHOT: done chunks=%d bytes=%d cksum=0x%04x path=%@", chunks, total, cksum, a.outPath))
            CustomVirtioSpike.snap = nil
            return nil
        default:
            return "unknown tag 0x\(String(bytes[0], radix: 16))"
        }
    }

    /// RFC 1071 one's-complement Internet checksum over big-endian words —
    /// byte-for-byte the same function as the guest's ipv4.checksum /
    /// virtio_custom.checksum1071, so the host verifies what the guest sent.
    /// The accumulator is UInt64: a whole-frame checksum over the 3.5 MiB
    /// scanout overflows UInt32 before the fold (observed live as a Swift
    /// "arithmetic overflow" trap, claim 0680).
    private func rfc1071(_ b: [UInt8]) -> UInt16 {
        var sum: UInt64 = 0
        var i = 0
        while i + 1 < b.count {
            sum += (UInt64(b[i]) << 8) | UInt64(b[i + 1])
            i += 2
        }
        if i < b.count { sum += UInt64(b[i]) << 8 }
        while (sum >> 16) != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum & 0xffff)
    }

    private func process(element: VZVirtioQueueElement, device: VZCustomVirtioDevice, queueIndex: Int) {
        // Reassemble the guest's device-read spans (claim 9492: a
        // >4 KiB payload arrives as several readBuffers()).
        var bytes: [UInt8] = []
        for buffer in element.readBuffers() {
            bytes.append(contentsOf: [UInt8](buffer))
        }
        if queueIndex == 1 {
            // Guest log transport (claim 4837): print the line verbatim to
            // the runner stdout and write ACK:<len> back into the element's
            // write buffers — the guest verifies the ack.
            let line = String(bytes: bytes, encoding: .utf8) ?? "<non-utf8>"
            print("CUSTOM-VIRTIO-LOG: \(line)")
            // Claim 0680: structured console — raw bytes into the file, no
            // injected newlines, so the capture stays byte-faithful.
            if let h = cvcConsoleFileHandle {
                do { try h.write(Data(bytes)) } catch {
                    print("CUSTOM-VIRTIO-CONSOLE: file write FAILED: \(error)")
                }
            }
            if line == "cvconsole-ready" && cvcConsoleFileHandle != nil {
                // Claim 0680: the guest's queue-3 pool is live — arm the
                // console tee (kind-3, bit0=1) NOW on this serial
                // deviceQueue, event-driven like the claim-3141 push.
                _ = CustomVirtioSpike.enqueueMessageNow(
                    CustomVirtioSpike.controlMessage(CustomVirtioSpike.inputKindConsoleCtrl, payload: [0x01]),
                    label: "console-arm enable=1"
                )
            }
            if line == "cvc-push-armed" && cvcEchoEnabled {
                // Claim 3141: the guest pre-armed its push rx buffer — the
                // HOST now chooses the moment and enqueues the request.
                // Inline on this serial deviceQueue, so ordering with the
                // queue-2 reply notification is deterministic.
                enqueuePushRequest(device: device)
            }
            let ack = Data("ACK:\(bytes.count)".utf8)
            do {
                try element.write(ack)
                print("CUSTOM-VIRTIO: log ack written (\(element.writtenByteCount) byte(s) into \(element.writeBuffersByteCount) byte(s) of write buffers)")
            } catch {
                print("CUSTOM-VIRTIO: log ack write FAILED: \(error)")
            }
        } else {
            // Queue-0 exchange: echo the exact reassembled payload back
            // (claim 0828's bidirectional flow, now length-agnostic). The
            // hex summary is bounded so a 12,340-byte payload does not
            // flood the runner log; the byte count + the guest's
            // byte-for-byte echo comparison carry the assertion.
            print("CUSTOM-VIRTIO: dequeued \(bytes.count) byte(s) (read \(element.readBuffersByteCount)): hex=[\(hexSummary(bytes))] ascii=\"\(printableAscii(bytes))\"")
            if element.writeBuffersByteCount >= bytes.count {
                do {
                    try element.write(Data(bytes))
                    print("CUSTOM-VIRTIO: echoed \(element.writtenByteCount) byte(s) into \(element.writeBuffersByteCount) byte(s) of write buffers")
                } catch {
                    print("CUSTOM-VIRTIO: reply write FAILED: \(error)")
                }
            } else {
                print("CUSTOM-VIRTIO: reply write skipped (write buffers \(element.writeBuffersByteCount) < \(bytes.count))")
            }
        }
        element.returnToQueue()
        print("CUSTOM-VIRTIO: returned element to queue \(queueIndex) — used ring advanced, device interrupt asserted")
    }

    /// Bounded hex rendering: full hex up to 64 bytes, otherwise the first
    /// and last 16 bytes + a 32-bit running sum (the claim-9492 big
    /// payload is 12,340 bytes of non-printable pattern).
    private func hexSummary(_ bytes: [UInt8]) -> String {
        let hex = { (slice: ArraySlice<UInt8>) in
            slice.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
        if bytes.count <= 64 {
            return hex(bytes[0...])
        }
        var sum: UInt32 = 0
        for b in bytes { sum = sum &+ UInt32(b) }
        return "\(hex(bytes[0..<16]))..\(hex(bytes[(bytes.count - 16)...])) sum=0x\(String(format: "%08x", sum))"
    }

    /// The payload's ASCII form, or <binary> when any byte is non-printable
    /// (the big-payload pattern is binary by design).
    private func printableAscii(_ bytes: [UInt8]) -> String {
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else { return "<binary>" }
        return String(bytes: bytes, encoding: .utf8) ?? "<non-utf8>"
    }

    func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        print("CUSTOM-VIRTIO: device reset")
    }

    func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) {
        print("CUSTOM-VIRTIO: device stopped")
    }
}

#endif
