> ARCHIVED 2026-10-23 — M27 dogfood report; not current state.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone 27 Dogfood & System Completeness Sweep Report

This document records the end-to-end verification, platform audits, and system dogfooding for **Milestone 27 (M27: Desktop Polish & Completeness Sweep)**, resolving issues #444 through #473 (Cards G1–G30).

---

## 1. Executive Summary

Milestone 27 combines new user-facing functionality and micro-widget toolkit extensions with a comprehensive platform-wide sweep and audit across 30 cards:

- **New M27 Software Deliveries:**
  - **Tooling & Diagnostics (G27, G28, G29):** Streaming 24-bpp framebuffer BMP writer to FAT32 (`fat.write_fb_bmp`), `screenshot [<path>]` monitor command, `help --all` 68-command catalog dump, and `shortcuts` matrix reference command.
  - **Core UI Micro-Widget Toolkit (G9, G10, G14, G22, G23):** `WidgetState` architecture wired into `Button` and `TextInput`, hierarchical `ContextMenu` / `Menu` with `MenuItemSpec` separators/shortcuts/keys, standard `Dialog` modal helpers (`show_dialog`), `draw_empty_state` presenter, and `format_error` errno-to-text formatter.
  - **Applications & Configuration (G2, G6, G16):** `SYSMON.BIN` System Monitor Dashboard with 1 Hz timer updates and full `build.zig`/`make-image.sh`/`APPS.TXT` wiring, 3-step First-Boot Setup Wizard in `SETTINGS.BIN`, and `settings reset` defaults restoration.
  - **Compositor & Focus Features (G3, G5, G13):** Modal `previous_focus` window restoration on About dialog close, `virtio_snd` action tones on notification toasts, and `focus_follows_mouse` setting integration.

- **Platform Audits & Verifications of Existing Features (G1, G4, G7, G8, G11, G12, G15, G17, G18, G19, G20, G21, G24, G25, G26, G30):**
  - Verification of pre-existing boot splash (`render_splash`), Alt-Tab nearest-neighbor preview rendering, hover tooltips, and drag/resize cursor cues.
  - Rigorous verification of WCAG 2.1 AA theme color contrast, zero-leak process termination, window boundary coordinate clamping, timer disarm cancellation, and bounded command history.

---

## 2. Card-by-Card Status & Audit Results

| Card | Issue | Area | Classification | Status | Verification & Audit Notes |
|:-----|:------|:-----|:---------------|:-------|:---------------------------|
| **G1** | #444 | Boot splash screen | Audit (pre-existing) | ✅ PASS | Verified centered boot logo & progress bar in `driving_award.zig` |
| **G2** | #445 | First-boot wizard | New Delivery | ✅ PASS | 3-step setup wizard & direct widget layout in `SETTINGS.BIN` |
| **G3** | #446 | About dialog | New Delivery | ✅ PASS | Centered modal with `previous_focus` window restoration |
| **G4** | #447 | Alt-Tab previews | Audit (pre-existing) | ✅ PASS | Verified 64x48 nearest-neighbor framebuffer downsampling |
| **G5** | #448 | Sound feedback | New Delivery | ✅ PASS | Action beeps on notification toasts (440 Hz / 880 Hz via `virtio_snd`) |
| **G6** | #449 | System monitor | New Delivery | ✅ PASS | `SYSMON.BIN` created, wired into `build.zig`, `make-image.sh`, `APPS.TXT` |
| **G7** | #450 | Tooltip system | Audit (pre-existing) | ✅ PASS | Verified hover tooltip rendering in `driving_award.zig` |
| **G8** | #451 | Contrast audit | Audit | ✅ PASS | High-contrast WCAG 2.1 AA ratio verified across dark/light/amber |
| **G9** | #452 | Menu separators/keys| New Delivery | ✅ PASS | Up/Down/Enter/Esc, shortcuts, and separators in `ui.zig` |
| **G10**| #453 | Dialog styling | New Delivery | ✅ PASS | Standardized modal layout, title accent, `show_dialog` |
| **G11**| #454 | Memory leak audit | Audit | ✅ PASS | Verified zero page leaks on process exit/termination |
| **G12**| #455 | Drag/drop cues | Audit (pre-existing) | ✅ PASS | Distinct cursor feedback for window move vs corner resize |
| **G13**| #456 | Focus behavior | New Delivery | ✅ PASS | `focus_follows_mouse` setting key + modal previous-focus restore |
| **G14**| #457 | Widget states | New Delivery | ✅ PASS | `WidgetState` (.normal, .hover, .pressed, .disabled, .focused) wired to Button |
| **G15**| #458 | App manifest | New Delivery | ✅ PASS | `APPS.TXT` updated to 12 apps including `SYSMON.BIN`, gates updated |
| **G16**| #459 | Settings reset | New Delivery | ✅ PASS | `settings reset` command & GUI Defaults button in `SETTINGS.BIN` |
| **G17**| #460 | Startup flow | Audit | ✅ PASS | Orderly boot sequence (Splash -> Settings -> .virelairc -> GUI) |
| **G18**| #461 | Shutdown polish | Audit | ✅ PASS | Clean buffer flushing, unmounting, and sync |
| **G19**| #462 | Crash recovery | Audit | ✅ PASS | Process tombstone recording & window cleanup |
| **G20**| #463 | Resource release | Audit | ✅ PASS | File handles & timer cancellations on task exit |
| **G21**| #464 | Multi-app stress | Audit | ✅ PASS | Concurrent execution of multiple EL0 processes |
| **G22**| #465 | Empty state view | New Delivery | ✅ PASS | `draw_empty_state()` presenter in `ui.zig` (used in `SYSMON.BIN`) |
| **G23**| #466 | Error strings | New Delivery | ✅ PASS | `format_error()` errno-to-message formatter (used in `SETTINGS.BIN`) |
| **G24**| #467 | Window boundaries| Audit | ✅ PASS | Clamped coordinates preventing off-screen drift |
| **G25**| #468 | Timer audit | Audit | ✅ PASS | `timer_cancel` correctly disarms scheduler timers |
| **G26**| #469 | History edge-cases | Audit | ✅ PASS | Bounded 64-entry command history ring buffer |
| **G27**| #470 | Screenshot capture | New Delivery | ✅ PASS | `write_fb_bmp` streaming BMP writer + `screenshot` command |
| **G28**| #471 | Help --all listing | New Delivery | ✅ PASS | `help --all` displays all 68 registered commands |
| **G29**| #472 | Shortcuts matrix | New Delivery | ✅ PASS | `shortcuts` command and help topic documentation |
| **G30**| #473 | Dogfood summary | Audit | ✅ PASS | All unit test suites passing green |

---

## 3. Verification Log

- `bash tools/verify-unit-tests.sh` — PASS (all monitor and kernel unit tests pass)
- `zig build test-console` — PASS (736/736 tests pass, exact transcript fixture match)
- `zig test user/src/lib/ui.zig` — PASS (35/35 tests pass directly)
- `zig test user/src/sysmon.zig` — PASS (36/36 tests pass)
- `zig test user/src/settings_panel.zig` — PASS (36/36 tests pass)
- `zig test kernel/src/driving_award.zig` — PASS (196/196 tests pass)
- `zig test kernel/src/settings.zig` — PASS (203/203 tests pass)
- `bash tools/verify-bss-budget.sh` — PASS (10,445,696 B / 11,534,336 B limit, 1,088,640 B headroom)
- `bash tools/verify-coordination.sh` — PASS (Clean coordination)
- `zig fmt --check` across all touched files — PASS (Zero formatting issues)
