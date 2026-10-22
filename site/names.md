---
title: Project names & lore
status: published
tags: [lore, names]
---

# Project names & lore

The project has a naming scheme. It is legible once you know the one rule:
the names are jokes, and the engineering is not.

## VirelaiOS

The project itself. A from-scratch AArch64 operating system that boots under
real UEFI firmware on Apple silicon. The name is the conservation law acting
on the project's own past (ADR 0017): **VIRELAIOS is an exact anagram of
LAVOISIER** — the chemist who proved that nothing is lost, nothing is
created, and everything is transformed — and a virelai is a medieval French
*forme fixe* (ballade, rondeau, virelai) built on a returning refrain. The
refrain that returns on schedule here is a gate: every merge runs the same
evidence discipline that built the machine.

The name is unique to this project by construction: a sweep of Webster's
Second International (1934) for 7-letter words over `{a,e,i,i,l,r,v}` returns
zero hits — the dictionary does not even contain `virelai` itself. The
retired name and its history are memorialized at
`docs/archive/dipshitos-name.md`.

## Road Pops

The **graphical terminal**. The boot terminal you interact with — the one
painted on the framebuffer — is Road Pops. It is a tee: every byte reaches the
serial console first (that is the shared evidence seam every transcript gate
reads), and the same banner, prompt, and replies are rendered on screen.

## Driving Award

The **window manager**. Road Pops is window 0; a 1 Hz clock overlay is window
1; user programs can open windows 2 and 3 through the syscall seam. Driving
Award owns the registry, z-order, focus, hit-testing, and the dirty-rect
compositor.

## Why this matters

The lore is not wallpaper — it names real subsystems with real gates:

- `roadpops` is a monitor command (armed/dirty/presents).
- `win` was the Driving Award command (registry, focus, raise, hit) — now
  renamed to `dui` (the `win` command no longer exists).
- The gates that prove them are `live-roadpops` and the `live-win*` family.

<Aside kind="tip">

**LIVE-GATED.** The pixel gates decode the actual captures against the
kernel's own font table — the Road Pops text and the Driving Award clock
overlay both must read forward, or the mirror-tripwire gate fails.

</Aside>

## Not documented (yet)

Names appear only when they are current repo truth. If a name is not on this
page, it is not an established part of the project yet — the documentation
does not invent lore ahead of the code.
