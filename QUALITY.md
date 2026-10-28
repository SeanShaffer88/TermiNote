# Quality — TermiNote 0.3.0

Scorecard for this version. Scores are given only where there is evidence;
anything that can only be proven on a real Windows machine is marked
**Unverified** rather than guessed at.

## What changed in 0.3.0

- Notes are stored as individual Markdown files: one `.md` file per note
  in a `notes` folder (trash in `notes/trash`), named `<id>-<slug>.md`,
  with the note's details in a front-matter block and the body as plain
  Markdown text. Saving writes only the notes that changed; a title
  change renames the note's file; delete/restore move the file between
  the folders. Covered by unit tests: save/load round-trip, title
  rename with no orphan left, a per-note save test proving an edit to
  one note does not rewrite another note's file, a front-matter
  round-trip test, and a trash move test.
- Automatic one-time migration: an old `notes.json` is converted to
  Markdown files on first run and kept as `notes.json.migrated.bak`
  (never deleted; `.bak2` and so on when the name is taken). A corrupt
  `notes.json` keeps the old quarantine behaviour. Covered by unit
  tests using the 0.1.0-format fixture, including the backup-name and
  quarantine cases. The migration of a real machine's existing notes is
  **Unverified** until the new version has run there.
- Fluid and responsive: all store loads and saves in the app are
  asynchronous (the GUI never does synchronous file IO), saves are
  queued so they cannot overlap, a failed write keeps its note on the
  dirty list for the next save instead of dropping it, and the
  scanline background now sits behind a RepaintBoundary so resizes and
  hover animations never repaint it. Loading happens once at startup
  (and after import), never as part of saving.

## What changed in 0.2.1 (shipped as part of 0.3.0)

- Save-confirmation dialogs: closing a note with unsaved changes and
  quitting the program with unsaved changes both ask first. The editor
  dialog is covered by a widget test (change the text, close, the
  dialog appears, "Keep editing" stays in the editor, "Save and close"
  writes the change to the note's file). The program-close interception
  goes through the app lifecycle listener and is **Unverified** on a
  real Windows machine.
- Full-width layout: the centered column is gone; every screen uses the
  whole window with the normal inner padding.
- List conversion: `toNumberedList`, `toBulletList`, and
  `stripListMarkers` are pure functions in the store file, covered by
  unit tests; the editor toolbar buttons and the `listify` command
  share them.
- Minimize to the system tray: implemented natively in the Windows
  runner plus a Settings toggle (on by default, persisted in the
  settings file; the persistence is covered by a test). The tray
  behaviour itself is **Unverified** on a real Windows machine until it
  has been clicked through there.
- Polish (the confirmed direction for this release): note cards carry a
  thin dark-red border with a bright red tick on the left edge that
  brightens on hover, the "Add note" button has a soft red glow, and
  the background has a faint scanline texture. The golden renders are
  regenerated for the new look; the final look verdict is the
  on-machine check in CAPTURE.md.
- Permanent deletions from Settings ask first: deleting a note for
  good and emptying the trash both go through a confirmation dialog
  (covered by widget tests — Cancel keeps the notes and their files,
  confirming removes them).
- Notes-folder backup and restore in Settings: "Back up notes" copies
  every note file (trash included) into a chosen folder in the same
  layout, refusing the notes folder itself and anything inside it;
  "Restore backup" adds the backed-up notes with fresh ids after a
  confirmation. Covered by store tests: a round trip through backup
  and restore keeps titles, bodies, tags, pin, times, and trash
  membership, unreadable files are counted as skipped, and the
  self-backup refusal is tested.
- Title edge spaces: a title with leading or trailing spaces is stored
  quoted in the file header and now round-trips exactly (unit tests);
  files written by earlier versions read exactly as before.
- Import skips notes already present: an incoming note whose title and
  body match a live note is skipped and counted, instead of duplicated
  on every import; a copy that only exists in the trash does not count.
  Covered by unit tests (repeat import, changed body, trash-only copy).

## Status of the current build (0.3.0, not yet released)

0.2.0 was a complete rewrite of the 0.1.0 program in Flutter (dark
terminal theme, blinking header cursor, hover states, animated
search, page transitions, styled scrollbar, undo snackbars); 0.3.0
builds on it as described above. Golden renders in `preview/` show
the built screens. The Windows runtime of the 0.3.0 changes is still
**Unverified** until the program has run on a real Windows machine.

Gate run 2026-10-28 (all improvements, before publish): `dart format`
clean, `flutter analyze` — no issues, `flutter test` — 88/88 pass,
including the store, edge-case, widget, editor, and golden tests.
Real bugs were found and fixed at these gates: the editor screen put
a flexible spacer inside a scroll view (0.2.0); manual drag order was
re-stamped at load (0.3.0); a migrated note could keep an unusable id
(audit); list conversion left stray carriage returns (audit); and the
Settings text-size row overflowed instead of wrapping at narrow
widths (improvements gate). Golden comparisons allow a 2.5% pixel
tolerance (`test/flutter_test_config.dart`) because renders differ
slightly between operating systems; the first Windows release run
measured 1.22% and 0.35% differences, which is rendering noise, not a
layout change.

## Evidence status

| Claim | Status |
|---|---|
| Data layer (`lib/note_store.dart`) reads and writes the per-note Markdown format, and still reads the 0.1.0 JSON format for migration and import | Covered by tests: a 0.1.0-format fixture round-trips through JSON and migrates to `.md` files, unknown fields are ignored, `next_id` is repaired ahead of trashed ids, front matter round-trips field for field, title edge spaces round-trip via header quoting, import skips duplicates and reports both counts, and the notes folder backs up and restores with fresh ids |
| Damaged data files are quarantined, never overwritten | Covered by a test: a corrupt `notes.json` is renamed to `notes.json.corrupt-<ts>` with its bytes intact during migration; damaged `.md` files are parsed tolerantly and keep their text as the body |
| Saves are atomic (`.tmp` file then rename) and per-note | Covered by the save/load round-trip test (also checks no `.tmp` file is left behind) and the per-note save test (another note's file content and timestamp untouched by an edit) |
| Migration keeps the old file as a backup | Covered by tests: `notes.json.migrated.bak` holds the original bytes, `.bak2` is used when the first name is taken, and note ids are repaired during the conversion itself; real-machine migration **Unverified** |
| The main list shows titles only, never body text | Enforced three ways: by construction in the store/CLI (list output is id + title + tags only), by a widget test that pumps the real list screen with unique body text and asserts it appears nowhere, and by the golden list render, which a human can inspect |
| Command line works through the same store code as the GUI | Code-shared by construction (`lib/cli.dart` calls only `lib/note_store.dart` operations); runtime check on Windows still **Unverified** |
| Windows runtime behaviour (window opens, cards render, drag reorder works, DPI scaling, installer) | **Unverified** — needs the on-machine pass listed in CAPTURE.md |
| Look matches the design in `preview/` | Golden renders in `preview/` are generated from the real screens by the test suite and were inspected at the gate. Final verdict is the on-machine look check (CAPTURE.md) |

## Scorecard

| Dimension | Score (0–5) | Evidence |
|---|---|---|
| Correctness of core logic | 4 | 67 store and edge-case tests over JSON compatibility, tags, every store operation, trash/restore, reorder, import/export merge, the Markdown file layout (migration, title rename, per-note saves, front-matter round-trip, trash file moves), corruption quarantine, file paths |
| Data safety | 4 | Atomic save, trash-first deletes, permanent deletions from Settings ask first, corruption quarantine keeps the original bytes, import never overwrites and skips notes already present, notes folder can be backed up and restored |
| GUI behaviour | 3 | Screens built to the design in preview/ with the polish pass (hover/pressed/focus states, animated search and chips, 200 ms page transitions, undo snackbars, confirm dialog on delete-all); widget + golden tests cover the list and editor; Windows runtime still Unverified until the on-machine pass |
| Accessibility | 3 | Tooltips on every icon button, visible red/white focus outlines on buttons, keyboard shortcuts (Ctrl+N, Ctrl+F, Ctrl+S, Esc), text-size controls from 12–28 pt; screen-reader pass on Windows still Unverified |
| Performance | 4 | Zero external packages, in-memory list operations, no network, no background work; small data scale by design |
| Documentation | 4 | README with TL;DR, CLI table, troubleshooting; DECISIONS, PARITY, RULES, CAPTURE all present; no placeholder screenshots |
| Privacy | 5 | No network code, no account, no analytics, local Markdown files only, no selling data |

## Known limitations

- No folders (by design), no sync, no update checker.
- Trash management lives in Settings; there is no separate trash screen.
- Export and import use a typed file path (no file-picker package, by the
  zero-dependency decision in DECISIONS.md).
