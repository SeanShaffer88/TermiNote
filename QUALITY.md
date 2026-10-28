# Quality — TermiNote v0.1.0

Scorecard for this version. Scores are given only where there is evidence; anything that can only be proven on a real Windows machine is marked **Unverified** rather than guessed at.

## Evidence status

| Claim | Status |
|---|---|
| Library (JSON, notes, store, operations, CLI parsing helpers) builds and its unit tests pass | Verified by the project gate (`cargo test`) on the build machine |
| Full gate (run 2026-10-28 before publish) | **Verified:** `cargo fmt` clean; clippy `-D warnings` clean on host AND `x86_64-pc-windows-gnu` (all targets); `cargo test --locked` 36/36 pass; Windows release build produced a PE32+ x86-64 `TermiNote.exe` (1,501,999 bytes); NSIS installer compiled from `installer/TermiNote.nsi` (558,610 bytes); CLI smoke test passed end to end (add/list/search/tags/show/stats against a temp data file, list output contained titles only, no body text) |
| Windows runtime behaviour (window opens, theme paints, autosave fires, drag and drop, DPI scaling) | **Unverified** — only a build/VM check exists; the on-machine pass in CAPTURE.md is the verdict |
| Installer installs and uninstalls cleanly on Windows 10/11 | **Unverified** — pending the on-machine pass in CAPTURE.md |

## Scorecard

| Dimension | Score (0–5) | Evidence |
|---|---|---|
| Correctness of core logic | 4 | 30+ unit tests over JSON, tags, every store operation, trash/restore, import/export merge, corruption quarantine |
| Data safety | 4 | Atomic save (temp file + rename), trash-first deletes, corruption quarantine keeps the original bytes, import never overwrites |
| GUI behaviour | 2 | Code complete against the brief; runtime **Unverified** until the on-machine pass |
| Accessibility | 3 | Native controls (screen-reader friendly), tooltips on every control, keyboard paths for new/save/search/delete/help, text size controls; high-DPI behaviour Unverified |
| Performance | 4 | Zero dependencies, in-memory list operations, no network, no background work; tiny data scale by design |
| Documentation | 4 | README with TL;DR, CLI table, troubleshooting; DECISIONS, PARITY, RULES, CAPTURE all present; no placeholder screenshots |
| Privacy | 5 | No network code, no account, no analytics, local JSON only, no selling data |

**Overall: release is gated on the full automated gate passing. The GUI score stays at 2 until the Windows on-machine pass in CAPTURE.md is done — that is an honest open item, not a waiver.**

## Known limitations

- No folders (by design), no sync, no update checker in v0.1.0.
- The GUI's "Saved HH:MM:SS" indicator shows UTC time.
- GUI trash management is limited to undo-delete of the most recent deletion; full trash browsing is a CLI capability in this version (see docs/PARITY.md).
