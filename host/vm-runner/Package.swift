// swift-tools-version:6.2
//
// VirelaiOS milestone-zero host launcher.
// A minimal macOS CLI built on Apple's Virtualization framework that boots a
// raw GPT+FAT disk image under UEFI (VZEFIBootLoader) and captures the
// guest's serial console into a log file.
//
// M34 HF1 (issue #735): the pure-Swift VFWire module (wire-format
// encode/decode for the host file channel — zero Virtualization imports,
// so `swift test` runs without a VM) + the VMRunnerTests target locking
// byte-parity with the guest side via the checked-in fixtures.
//
// Tools version 6.2 is the floor that parses on the CI toolchain (Swift
// 6.3.3 on GitHub's macos-latest) while still exposing the macOS 26
// platform case; the target language mode stays Swift 5 to keep the
// concurrency surface small.
import PackageDescription

let package = Package(
    name: "vm-runner",
    platforms: [
        // Project requirement: macOS 27+ (Apple silicon + Virtualization.framework).
        // The manifest floor tracks the highest version the CI toolchain's
        // PackageDescription exposes (.v26; .v27 needs PackageDescription
        // 6.4 / Swift 6.4). The runtime requirement (macOS 27+) is enforced
        // in Sources/VMRunner/main.swift.
        .macOS(.v26)
    ],
    targets: [
        .target(
            name: "VFWire",
            path: "Sources/VFWire"
        ),
        // M51 SSH5 (#1172) / M70g G1 (#1491): the minimal SSH-2 server the
        // runner hosts behind `--net-tcp-respond …:ssh`, plus the matching
        // client behind `--net-tcp-connect …:ssh`. Hand-rolled OpenSSH
        // cipher, curve25519-sha256 KEX, pinned ssh-ed25519 keys, one
        // session exec. Pure Swift/CryptoKit, zero Virtualization imports.
        .target(
            name: "VSSH",
            path: "Sources/VSSH"
        ),
        // M83b (#1775): the host SNTP responder behind `--net-sntp-respond`.
        // Pure Swift/Foundation, zero Virtualization imports.
        .target(
            name: "VSNTP",
            path: "Sources/VSNTP"
        ),
        // #1278: the VM stop-reason recorder — the host half of the fault/state
        // recorder that unblocks #1261. Pure Swift/Foundation, ZERO
        // Virtualization imports, so its formatting and ordering rules are
        // pinned by `swift test` on a machine that never boots a VM.
        .target(
            name: "VMPostmortem",
            path: "Sources/VMPostmortem"
        ),
        // M100b (#2307, ADR 0050): the `--data-disk` raw-image preparation
        // (create/validate) + the `virelai-vlfs` identifier. Pure
        // Swift/Foundation so `swift test` covers it without a VM.
        .target(
            name: "VMDiskImage",
            path: "Sources/VMDiskImage"
        ),
        // M115c (#2462): the `.virelaivm` profile bundle — manifest-gated
        // create/load + atomic save behind the runner's `--profile`. Pure
        // Swift/Foundation so `swift test` pins the format without a VM.
        .target(
            name: "VMProfile",
            path: "Sources/VMProfile"
        ),
        .target(
            name: "VMAppKit",
            // M114d (#2457): the inspector model renders VMPostmortem's
            // PostmortemCard — a pure-Foundation edge, so the
            // Virtualization-free boundary NativeInputTests depends on
            // is untouched.
            dependencies: ["VMPostmortem"],
            path: "Sources/VMAppKit"
        ),
        // M102b2 (#2163): the host envelope for the experimental
        // custom-Virtio 3D render device (ID 0x43 / PCI 1af4:1083) — the
        // frozen VIR1 wire codec, the two-context generation-safe device
        // core, and the injected GPU3DBackend seam c2's Metal renderer
        // will fill. The Virtualization glue is behind -DSPIKE (macOS 27
        // SDK); the core is pure Swift, so `swift test` exercises it on
        // any host. Nothing attaches it to the runner until d3.
        .target(
            name: "VMGPU3D",
            path: "Sources/VMGPU3D"
        ),
        // #2349: the runner's TCP wire helpers + the :relay upstream
        // state machine (NetTcpRelay) — pure Swift/Foundation, zero
        // Virtualization imports, so `swift test` proves the >1460-byte
        // inbound payload and retransmit-dedup behavior without a VM.
        .target(
            name: "VMTcp",
            path: "Sources/VMTcp"
        ),
        // M115b (#2461, ADR 0056): the virelai-ctl/1 session codec — the
        // HMAC-challenged guest→host control channel behind --vsock-ctl.
        // Pure Swift/CryptoKit, zero Virtualization imports, so
        // `swift test` drives the whole refusal matrix without a VM.
        .target(
            name: "VSCtl",
            path: "Sources/VSCtl"
        ),
        .executableTarget(
            name: "VMRunner",
            dependencies: ["VFWire", "VSSH", "VSNTP", "VMPostmortem", "VMAppKit", "VMGPU3D", "VMDiskImage", "VMTcp", "VSCtl", "VMProfile"],
            path: "Sources/VMRunner"
        ),
        // M118a (#2479): the `--sound-in` observation vehicle — a standalone
        // minimal boot carrying VZVirtioSoundDeviceInputStreamConfiguration +
        // VZHostAudioInputStreamSource, kept OUT of VMRunner because
        // main.swift's flag loop has no extension point and the file is held
        // by other active claims (#2475/#2476). Ad-hoc codesigned with the
        // same entitlements.plist by the gate before use.
        .executableTarget(
            name: "SoundInProbe",
            path: "Sources/SoundInProbe"
        ),
        .testTarget(
            name: "VMRunnerTests",
            dependencies: ["VFWire", "VSSH", "VSNTP", "VMPostmortem", "VMAppKit", "VMGPU3D", "VMDiskImage", "VMTcp", "VSCtl", "VMProfile"]
        )
    ],
    swiftLanguageModes: [.v5]
)
