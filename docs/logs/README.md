# Coordination logs (append-only, per branch)

**Why this exists:** the project changelog used to live entirely inside
`docs/status.md`. Every agent appended to that one file, so parallel work
collided on every merge — PR #8/#10 collided once, and PR #12/#13 collided
again on the same section. Coordination state is now **sharded by branch**:
each branch owns its own log file, and cross-branch merges never touch the
same lines.

**The rule is unchanged and still binding** (AGENTS.md): log files are
**append-only**. Never rewrite or delete an entry — including entries in
other branches' logs. Corrections are *new* entries that reference the old
one.

## How to log

1. Your branch's log file is `docs/logs/<branch-slug>.md` (e.g.
   `agent/buffy/m15-commands` → `docs/logs/agent-buffy-m15-commands.md`).
   Create it on your first entry.
2. **Append** an entry in this format:

   `- **YYYY-MM-DD** — *owner (branch)*: claim → what changed → evidence → status.`

   Status legend: ⬜ claimed · 🔄 in progress · ✅ done · ⛔ blocked.
3. Cite `artifacts/` evidence files. No observed claim without a saved log.
4. Do **not** edit `docs/status.md` for logging — only for milestone-level
   facts (position, gates). Per-step progress goes in the per-milestone
   tracker (`docs/march-m15.md`); per-work detail goes here and in your
   claim file. If you must touch `README.md`/`roadmap.md`/`testing.md`,
   prefer pointer-level changes.
5. Run `bash tools/status/refresh-indexes.sh` to regenerate the
   [Log index](#log-index) below — it is **generated from the log files**,
   so never hand-edit it (hand-appending rows to a shared table is how
   parallel branches collide on merge).

## Log index

**This table is generated** from the log files by
`bash tools/status/refresh-indexes.sh` — do not hand-edit it. The
coordination gate (`bash tools/verify-coordination.sh`, `just
verify-coordination`, and CI) fails if it drifts from the files.

<!-- LOGS_INDEX:START -->
| Branch | Log file |
|--------|----------|
| agent/buffy/doc-sync-m3 | [`agent-buffy-doc-sync-m3.md`](agent-buffy-doc-sync-m3.md) |
| `agent/buffy/m15-commands` (PR #12) | [`agent-buffy-m15-commands.md`](agent-buffy-m15-commands.md) |
| `agent/buffy/m15-host-plumbing` (PR #13) | [`agent-buffy-m15-host-plumbing.md`](agent-buffy-m15-host-plumbing.md) |
| `agent/buffy/m15-machine-controls` | [`agent-buffy-m15-machine-controls.md`](agent-buffy-m15-machine-controls.md) |
| `agent/buffy/m15-milestone-docs` | [`agent-buffy-m15-milestone-docs.md`](agent-buffy-m15-milestone-docs.md) |
| `agent/buffy/m15-nvram-console` | [`agent-buffy-m15-nvram-console.md`](agent-buffy-m15-nvram-console.md) |
| M1.5 console & shell core (agent B) | [`agent-buffy-m15-shell-core.md`](agent-buffy-m15-shell-core.md) |
| `agent/buffy/m15-vz-serial-gate` | [`agent-buffy-m15-vz-serial-gate.md`](agent-buffy-m15-vz-serial-gate.md) |
| `agent/buffy/m2-badhandoff-fix` (PR #11) | [`agent-buffy-m2-badhandoff-fix.md`](agent-buffy-m2-badhandoff-fix.md) |
| `agent/buffy/m2-kernel-proper` (PR #10) | [`agent-buffy-m2-kernel-proper.md`](agent-buffy-m2-kernel-proper.md) |
| M2 fixed-memory-marker fallback (ADR 0004 D4, gate work item 3) | [`agent-buffy-m2-marker-fallback.md`](agent-buffy-m2-marker-fallback.md) |
| per-task user address spaces (claim 5804) | [`agent-buffy-m3-addrspaces.md`](agent-buffy-m3-addrspaces.md) |
| milestone-three close-out (lane E, `agent/buffy/m3-closeout`) | [`agent-buffy-m3-closeout.md`](agent-buffy-m3-closeout.md) |
| `agent/buffy/m3-docs-reconcile-syscall-abi` | [`agent-buffy-m3-docs-reconcile-syscall-abi.md`](agent-buffy-m3-docs-reconcile-syscall-abi.md) |
| user task lifecycle (claim 6729) | [`agent-buffy-m3-lifecycle.md`](agent-buffy-m3-lifecycle.md) |
| `agent/buffy/m3-uaccess` | [`agent-buffy-m3-uaccess.md`](agent-buffy-m3-uaccess.md) |
| milestone-four close-out (claim 2839) | [`agent-buffy-m4-closeout.md`](agent-buffy-m4-closeout.md) |
| milestone-four follow-on: concurrent processes (two live user address spaces) | [`agent-buffy-m4-concurrent-processes.md`](agent-buffy-m4-concurrent-processes.md) |
| milestone four card 1: virtio entropy driver + CSPRNG (claim 2665) | [`agent-buffy-m4-entropy-csprng.md`](agent-buffy-m4-entropy-csprng.md) |
| milestone-four follow-on 3, card 3e: exec context block (args to EL0) | [`agent-buffy-m4-exec-args.md`](agent-buffy-m4-exec-args.md) |
| milestone-four follow-on 3, card 3d: per-process exit reports (exact) | [`agent-buffy-m4-exit-report-fifo.md`](agent-buffy-m4-exit-report-fifo.md) |
| milestone four card 2: general (non-ESP) filesystem (claim 3678) | [`agent-buffy-m4-general-fs.md`](agent-buffy-m4-general-fs.md) |
| milestone-four follow-on 4, card 4b: IPC depth — more messages per process ring | [`agent-buffy-m4-ipc-depth.md`](agent-buffy-m4-ipc-depth.md) |
| milestone-four follow-on 3, card 3f: IPC — distinct processes exchange data | [`agent-buffy-m4-ipc.md`](agent-buffy-m4-ipc.md) |
| milestone-four follow-on 3, card 3c: kill (the kernel owns process lifetime) | [`agent-buffy-m4-kill.md`](agent-buffy-m4-kill.md) |
| milestone-four follow-on 2: a long-lived process among live peers | [`agent-buffy-m4-long-lived-process.md`](agent-buffy-m4-long-lived-process.md) |
| milestone-four follow-on 3, card 3g: pool scale — a third live user process | [`agent-buffy-m4-pool-scale.md`](agent-buffy-m4-pool-scale.md) |
| milestone four card 3: process abstraction (claim 3848) | [`agent-buffy-m4-process-abstraction.md`](agent-buffy-m4-process-abstraction.md) |
| milestone-four follow-on 4, card 4a: process observability — sys_procs introspection syscall | [`agent-buffy-m4-procs-syscall.md`](agent-buffy-m4-procs-syscall.md) |
| milestone-four follow-on 4, card 4c: exit-status propagation — a bounded `sys_wait` block | [`agent-buffy-m4-wait-exit.md`](agent-buffy-m4-wait-exit.md) |
| agent/buffy/m5-arp | [`agent-buffy-m5-arp.md`](agent-buffy-m5-arp.md) |
| agent/buffy/m5-ipv4 | [`agent-buffy-m5-ipv4.md`](agent-buffy-m5-ipv4.md) |
| agent/buffy/m5-net-dhcp-renew | [`agent-buffy-m5-net-dhcp-renew.md`](agent-buffy-m5-net-dhcp-renew.md) |
| agent/buffy/m5-net-dhcp | [`agent-buffy-m5-net-dhcp.md`](agent-buffy-m5-net-dhcp.md) |
| agent/buffy/m5-net-nat | [`agent-buffy-m5-net-nat.md`](agent-buffy-m5-net-nat.md) |
| agent/buffy/m5-net-rx | [`agent-buffy-m5-net-rx.md`](agent-buffy-m5-net-rx.md) |
| agent/buffy/m5-net-tcp-rto | [`agent-buffy-m5-net-tcp-rto.md`](agent-buffy-m5-net-tcp-rto.md) |
| agent/buffy/m5-net-tcp | [`agent-buffy-m5-net-tcp.md`](agent-buffy-m5-net-tcp.md) |
| agent/buffy/m5-net-tx | [`agent-buffy-m5-net-tx.md`](agent-buffy-m5-net-tx.md) |
| agent/buffy/m5-udp-syscall | [`agent-buffy-m5-udp-syscall.md`](agent-buffy-m5-udp-syscall.md) |
| agent/buffy/m5-udp | [`agent-buffy-m5-udp.md`](agent-buffy-m5-udp.md) |
| agent/buffy/m6-gpu | [`agent-buffy-m6-gpu.md`](agent-buffy-m6-gpu.md) |
| agent/buffy/m6-roadpops | [`agent-buffy-m6-roadpops.md`](agent-buffy-m6-roadpops.md) |
| agent/buffy/m6-text | [`agent-buffy-m6-text.md`](agent-buffy-m6-text.md) |
| `agent/buffy/macos27-custom-virtio-spike` | [`agent-buffy-macos27-custom-virtio-spike.md`](agent-buffy-macos27-custom-virtio-spike.md) |
| `agent/codex/m3-march-tracker` | [`agent-codex-m3-march-tracker.md`](agent-codex-m3-march-tracker.md) |
| `agent/codex/m3-ragshit-dogfood` | [`agent-codex-m3-ragshit-dogfood.md`](agent-codex-m3-ragshit-dogfood.md) |
| `agent/codex/m3-syscall-abi` | [`agent-codex-m3-syscall-abi.md`](agent-codex-m3-syscall-abi.md) |
| audit-2026 maintenance: timer-gate evidence restore + doc drift fixes (claim 6204) | [`agent-maintenance-audit-2026-issues.md`](agent-maintenance-audit-2026-issues.md) |
| milestone eight card U2: shell editing & history (zcode) | [`agent-zcode-m8-u2-lineedit.md`](agent-zcode-m8-u2-lineedit.md) |
| milestone eight card U3: error/usage contract (zcode) | [`agent-zcode-m8-u3-errors.md`](agent-zcode-m8-u3-errors.md) |
| `codex/el0-svc-task` | [`codex-el0-svc-task.md`](codex-el0-svc-task.md) |
| `codex/vz-real-irq-delivery` | [`codex-vz-real-irq-delivery.md`](codex-vz-real-irq-delivery.md) |
| freebuff/can-you-check-out-our-status-and-work-on-the-next (milestone six, G4) | [`freebuff-can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-8acc-47ac-bb44-68841236e5fc.md`](freebuff-can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-8acc-47ac-bb44-68841236e5fc.md) |
| freebuff/docs-reconciliation-m15-status-20260808 | [`freebuff-docs-reconciliation-m15-status-20260808.md`](freebuff-docs-reconciliation-m15-status-20260808.md) |
| freebuff/get-newest-github-files-and-let-s-get-some-shit-do-1e1cbf84-86fb-4605-a843-32fc0593fea0 | [`freebuff-get-newest-github-files-and-let-s-get-some-shit-do-1e1cbf84-86fb-4605-a843-32fc0593fea0.md`](freebuff-get-newest-github-files-and-let-s-get-some-shit-do-1e1cbf84-86fb-4605-a843-32fc0593fea0.md) |
| `freebuff/grab-latest-git-and-check-out-status-and-let-s-get-15800f9b-d72c-4035-ac26-ae778c52b296` | [`freebuff-grab-latest-git-and-check-out-status-and-let-s-get-15800f9b-d72c-4035-ac26-ae778c52b296.md`](freebuff-grab-latest-git-and-check-out-status-and-let-s-get-15800f9b-d72c-4035-ac26-ae778c52b296.md) |
| freebuff/grab-most-current-git-and-let-s-continue-on-with-o-5886224b-69b6-4597-adc4-63698bac127e | [`freebuff-grab-most-current-git-and-let-s-continue-on-with-o-5886224b-69b6-4597-adc4-63698bac127e.md`](freebuff-grab-most-current-git-and-let-s-continue-on-with-o-5886224b-69b6-4597-adc4-63698bac127e.md) |
| freebuff/grab-most-current-git-and-let-s-continue-on-with-o-6068d391-a734-4e7b-859d-b1e95f01f3f6 | [`freebuff-grab-most-current-git-and-let-s-continue-on-with-o-6068d391-a734-4e7b-859d-b1e95f01f3f6.md`](freebuff-grab-most-current-git-and-let-s-continue-on-with-o-6068d391-a734-4e7b-859d-b1e95f01f3f6.md) |
| freebuff/grab-most-current-git-and-let-s-continue-on-with-o-bd839138-534f-40b1-97b3-220d1b1c9a61 | [`freebuff-grab-most-current-git-and-let-s-continue-on-with-o-bd839138-534f-40b1-97b3-220d1b1c9a61.md`](freebuff-grab-most-current-git-and-let-s-continue-on-with-o-bd839138-534f-40b1-97b3-220d1b1c9a61.md) |
| M2 MMU-takeover root cause & fix (claim 0010) | [`freebuff-grab-newest-files-from-github-and-pick-something-t-a3eb337e-4b37-4bae-8548-242c49be7456.md`](freebuff-grab-newest-files-from-github-and-pick-something-t-a3eb337e-4b37-4bae-8548-242c49be7456.md) |
| `freebuff/grab-newest-git-and-check-status-if-there-s-any-im-b9d5c028-9379-48e0-8ddb-ebfbf45ef2df` | [`freebuff-grab-newest-git-and-check-status-if-there-s-any-im-b9d5c028-9379-48e0-8ddb-ebfbf45ef2df.md`](freebuff-grab-newest-git-and-check-status-if-there-s-any-im-b9d5c028-9379-48e0-8ddb-ebfbf45ef2df.md) |
| Status re-verification on merged main (claim 0014) | [`freebuff-let-s-get-the-latest-github-and-do-something-benef-e128807b-0418-4d4e-aebe-ba30b18c18c5.md`](freebuff-let-s-get-the-latest-github-and-do-something-benef-e128807b-0418-4d4e-aebe-ba30b18c18c5.md) |
| M1.5 transcript test automation (`freebuff/m15-transcript-test`) | [`freebuff-m15-transcript-test.md`](freebuff-m15-transcript-test.md) |
| freebuff/mainzig-modules | [`freebuff-mainzig-modules.md`](freebuff-mainzig-modules.md) |
| Coordination-tooling hardening (claim 1801) | [`freebuff-make-sure-git-is-current-first-18548850-6288-40ff-bca2-007971e567ac.md`](freebuff-make-sure-git-is-current-first-18548850-6288-40ff-bca2-007971e567ac.md) |
| make-sure-git-main-is-current (claim 4922) | [`freebuff-make-sure-git-main-is-current-7f307de5-d3c0-4d90-966c-3a4221ad4d24.md`](freebuff-make-sure-git-main-is-current-7f307de5-d3c0-4d90-966c-3a4221ad4d24.md) |
| `freebuff/mmu-debt-contract` | [`freebuff-mmu-debt-contract.md`](freebuff-mmu-debt-contract.md) |
| freebuff/okay-we-ve-been-kind-of-freestyling-off-away-from--0584ad0f-9850-473f-8884-7c28b20acab7 | [`freebuff-okay-we-ve-been-kind-of-freestyling-off-away-from--0584ad0f-9850-473f-8884-7c28b20acab7.md`](freebuff-okay-we-ve-been-kind-of-freestyling-off-away-from--0584ad0f-9850-473f-8884-7c28b20acab7.md) |
| `freebuff/pull-git-and-check-status-to-make-sure-everything--9934c25c-63ea-4cf3-b3fb-4b98fb81b9f4` | [`freebuff-pull-git-and-check-status-to-make-sure-everything--9934c25c-63ea-4cf3-b3fb-4b98fb81b9f4.md`](freebuff-pull-git-and-check-status-to-make-sure-everything--9934c25c-63ea-4cf3-b3fb-4b98fb81b9f4.md) |
| `freebuff/pull-git-and-check-status-to-make-sure-everything--d4bf6a7f-c051-49b8-a1c4-bc479835e531` | [`freebuff-pull-git-and-check-status-to-make-sure-everything--d4bf6a7f-c051-49b8-a1c4-bc479835e531.md`](freebuff-pull-git-and-check-status-to-make-sure-everything--d4bf6a7f-c051-49b8-a1c4-bc479835e531.md) |
| status-preflight review (claim 8592) | [`freebuff-pull-latest-dipshitos-main-after-all-preceding-rel-1fe779b0-133e-4303-81f1-397087634352.md`](freebuff-pull-latest-dipshitos-main-after-all-preceding-rel-1fe779b0-133e-4303-81f1-397087634352.md) |
| verification gate classification (claim 0594) | [`freebuff-pull-latest-dipshitos-main-ebe15999-a14a-4066-9551-00deb3d2323a.md`](freebuff-pull-latest-dipshitos-main-ebe15999-a14a-4066-9551-00deb3d2323a.md) |
| `freebuff/pull-the-latest-dipshitos-main-after-the-virtio-pc-fc4c7c03-1dba-4af3-857d-af8cfa2c1e91` | [`freebuff-pull-the-latest-dipshitos-main-after-the-virtio-pc-fc4c7c03-1dba-4af3-857d-af8cfa2c1e91.md`](freebuff-pull-the-latest-dipshitos-main-after-the-virtio-pc-fc4c7c03-1dba-4af3-857d-af8cfa2c1e91.md) |
| freebuff/pull-the-latest-from-github-and-find-something-in--a639920e (serial device discovery) | [`freebuff-pull-the-latest-from-github-and-find-something-in--a639920e-ebe1-47a0-a380-54cece9b4c40.md`](freebuff-pull-the-latest-from-github-and-find-something-in--a639920e-ebe1-47a0-a380-54cece9b4c40.md) |
| `freebuff/ragshit-impact` | [`freebuff-ragshit-impact.md`](freebuff-ragshit-impact.md) |
| `freebuff/ragshit-review` | [`freebuff-ragshit-review.md`](freebuff-ragshit-review.md) |
| stale-doc cleanup (claim 3109) | [`freebuff-stale-doc-cleanup.md`](freebuff-stale-doc-cleanup.md) |
| ragshit review coverage truncation (claim 0176) | [`freebuff-start-from-current-dipshitos-main-record-the-exact-af2bed0e-1f29-49ea-b233-bf528e5ce88e.md`](freebuff-start-from-current-dipshitos-main-record-the-exact-af2bed0e-1f29-49ea-b233-bf528e5ce88e.md) |
| freebuff/start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2 | [`freebuff-start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2.md`](freebuff-start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2.md) |
| `freebuff/t0sz16-startlevel-diag` | [`freebuff-t0sz16-startlevel-diag.md`](freebuff-t0sz16-startlevel-diag.md) |
| freebuff/you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d | [`freebuff-you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d.md`](freebuff-you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d.md) |
| M1.5 tracker origin (pre-branch era) | [`m1.5-tracker.md`](m1.5-tracker.md) |
<!-- LOGS_INDEX:END -->
