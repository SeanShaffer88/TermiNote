# Quality — TermiNote 0.2.0

Scorecard for this version. Scores are given only where there is evidence;
anything that can only be proven on a real Windows machine is marked
**Unverified** rather than guessed at.

## Status of this build

0.2.0 is a complete rewrite of the 0.1.0 program in Flutter: a mobile
notepad app's layout (header, toolbar, rounded note cards) inside a
desktop window, in the dark terminal theme (blinking header cursor,
hover states, animated search, page transitions, styled scrollbar,
undo snackbars). Golden renders in `preview/` show the built screens.
The Windows runtime itself is still **Unverified** until the program
has run on a real Windows machine.

Gate run 2026-10-28 (before publish): `dart format` clean,
`flutter analyze` — no issues, `flutter test` — 33/33 pass, including
the store tests, the titles-only widget test, and both golden renders.
One real bug was found and fixed by the golden test at this gate: the
editor screen put a flexible spacer inside a scroll view, which cannot
be laid out; the editor now switches between a full-height layout and
a scrolling layout by window height. Golden comparisons allow a 2.5%
pixel tolerance (`test/flutter_test_config.dart`) because renders
differ slightly between operating systems; the first Windows release
run measured 1.22% and 0.35% differences, which is rendering noise,
not a layout change.

## Evidence status

| Claim | Status |
|---|---|
| Data layer (`lib/note_store.dart`) reads and writes the exact 0.1.0 file format | Covered by tests: a 0.1.0-format fixture round-trips, unknown fields are ignored, `next_id` is repaired ahead of trashed ids |
| Damaged data files are quarantined, never overwritten | Covered by a test: corrupt input is renamed to `notes.json.corrupt-<ts>` with its bytes intact |
| Saves are atomic (`.tmp` file then rename) | Covered by the save/load round-trip test, which also checks no `.tmp` file is left behind |
| The main list shows titles only, never body text | Enforced three ways: by construction in the store/CLI (list output is id + title + tags only), by a widget test that pumps the real list screen with unique body text and asserts it appears nowhere, and by the golden list render, which a human can inspect |
| Command line works through the same store code as the GUI | Code-shared by construction (`lib/cli.dart` calls only `lib/note_store.dart` operations); runtime check on Windows still **Unverified** |
| Windows runtime behaviour (window opens, cards render, drag reorder works, DPI scaling, installer) | **Unverified** — needs the on-machine pass listed in CAPTURE.md |
| Look matches the design in `preview/` | Golden renders in `preview/` are generated from the real screens by the test suite and were inspected at the gate. Final verdict is the on-machine look check (CAPTURE.md) |

## Scorecard

| Dimension | Score (0–5) | Evidence |
|---|---|---|
| Correctness of core logic | 4 | 29 store tests over JSON compatibility, tags, every store operation, trash/restore, reorder, import/export merge, corruption quarantine, file paths |
| Data safety | 4 | Atomic save, trash-first deletes, corruption quarantine keeps the original bytes, import never overwrites |
| GUI behaviour | 3 | Screens built to the design in preview/ with the polish pass (hover/pressed/focus states, animated search and chips, 200 ms page transitions, undo snackbars, confirm dialog on delete-all); widget + golden tests cover the list and editor; Windows runtime still Unverified until the on-machine pass |
| Accessibility | 3 | Tooltips on every icon button, visible red/white focus outlines on buttons, keyboard shortcuts (Ctrl+N, Ctrl+F, Ctrl+S, Esc), text-size controls from 12–28 pt; screen-reader pass on Windows still Unverified |
| Performance | 4 | Zero external packages, in-memory list operations, no network, no background work; small data scale by design |
| Documentation | 4 | README with TL;DR, CLI table, troubleshooting; DECISIONS, PARITY, RULES, CAPTURE all present; no placeholder screenshots |
| Privacy | 5 | No network code, no account, no analytics, local JSON only, no selling data |

## Known limitations

- No folders (by design), no sync, no update checker in 0.2.0.
- Trash management lives in Settings; there is no separate trash screen.
- Export and import use a typed file path (no file-picker package, by the
  zero-dependency decision in DECISIONS.md).
