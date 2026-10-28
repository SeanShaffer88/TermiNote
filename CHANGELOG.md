# Changelog

All notable changes to TermiNote are recorded here.

## 0.3.1 — not yet released

- Clicking the window's X button now asks what to do: minimize to the
  system tray, or quit. A "Don't ask again" checkbox in the dialog
  remembers the choice, and Settings gains the same choice as radio
  buttons ("When I click the X button": Ask every time / Quit /
  Minimize to the system tray), so a remembered choice can be changed.
  Quitting from the tray menu still always quits, and a remembered
  "minimize to tray" choice quits instead when the system tray setting
  is switched off.

## 0.3.0 — 2026-10-28

- Fixed: the backup safety check that refuses to copy notes into the
  notes folder itself could compare two different written forms of the
  same Windows folder path and let the backup through. Folder paths
  are now put into one canonical form before they are compared.
- Each note is now stored as its own Markdown (.md) file in a notes
  folder, with the note's details in a small header block at the top of
  the file. Existing notes are converted automatically the first time
  the new version runs, and the old notes file is kept as a backup
  copy. Trashed notes live in a trash subfolder, and a note's file is
  renamed when its title changes.
- Saving is quicker and the window stays smooth: only the notes that
  changed are written, and saving happens in the background instead of
  making the window wait on the disk.
- Confirmation dialogs before unsaved work is lost: closing a note with
  changes that have not saved yet (back button or Esc) asks "Save before
  closing?", and quitting the program with unsaved changes asks "Save
  before quitting?". Both offer save, discard, or stay. The editor's
  check button still saves and closes without asking.
- The layout now uses the full window width; the wide empty margins on
  either side of the old centered column are gone.
- Notes can be turned into lists: the editor toolbar gains "1." and "•"
  buttons that convert the selected lines (or the whole body) into a
  numbered or bullet list; pressing the same button again converts back
  to plain text. The command line gains `listify ID numbered|bullets|plain`.
- Minimize to the system tray: with the new Settings toggle on (the
  default), the minimize button tucks TermiNote into the tray by the
  clock. The tray icon's menu can open the program, start a new note,
  or quit (quit still asks about unsaved work first).
- Polish: cards now have a dark-red edge with a red side tick, the
  Add note button glows softly, and the background has a faint scanline
  texture.
- Deleting a note for good and emptying the trash in Settings now ask
  first, in a dialog that says plainly it cannot be undone.
- Settings can back up the whole notes folder — live notes and the
  trash — to a folder you choose ("Back up notes"), and restore a
  backup later ("Restore backup"): restored notes are added alongside
  your current ones with fresh ids, nothing is overwritten, files that
  cannot be read are skipped and reported, and backing up into the
  notes folder itself is refused.
- Note titles now keep their leading and trailing spaces when a note is
  saved and reopened (a title with edge spaces is stored quoted in the
  file header). Files written by earlier versions read exactly as before.
- The command line has a `version` command that prints the program
  version (the same text Settings shows under About).
- Importing an export no longer duplicates notes you already have (same
  title and same body): they are skipped, and the import message says
  how many notes were imported and how many were skipped.
- The command line now has automated tests covering every command —
  adding, listing, showing, editing, pinning, searching, list
  conversion, the trash round trip, delete-all, export and import,
  help, stats, and the error cases — run as part of the test suite.
- One TermiNote window at a time: starting the program again while it
  is already running brings the running window to the front instead of
  opening a second window over the same notes (two windows editing the
  same note could overwrite each other). Command-line calls are not
  affected and work as before, including while the window is open.
- The "Save before quitting?" prompt is now asked by the window itself
  whenever it is told to close — the close button, Alt+F4, and the
  tray menu's Quit all go through it — so the question cannot be
  skipped by a close route the program did not foresee. If the answer
  never comes back, the window closes anyway rather than trapping you
  in a program that cannot be quit.
- Find inside a note: Ctrl+F in the editor opens a find bar with a
  match count in plain words ("match 2 of 5", or "no matches") and
  previous/next buttons. Enter steps to the next match, Shift+Enter
  to the previous one, and Esc closes the bar. The search is a plain
  text search of the note's body, ignoring case.
- The note list can be driven from the keyboard: the up and down
  arrow keys move a highlight between cards (the highlighted card
  wears the same red edge as a hovered one), Enter opens the
  highlighted note, and Delete moves it to the trash with the usual
  undo. Moving the mouse over a card moves the highlight to it, so
  mouse and keyboard always agree on the current card. While you are
  typing in the search box, the arrow, Enter, and Delete keys belong
  to the search and do not touch the list.
- Crash recovery: while a note is being edited, a recovery copy of
  its latest text is kept alongside the autosave. If the program
  closes suddenly, the next start offers to recover each note whose
  kept text is newer than its saved text — "Recover unsaved work?" —
  and you can put the text back or throw it away. A normal close
  removes the recovery copy, so the offer only appears after a
  sudden close.

- Fixed: a note converted from the old single-file format could keep
  an unusable id of 0 until the next run; ids are now repaired during
  the conversion itself.
- Fixed: converting a note to a numbered or bullet list now tidies
  Windows-style line endings instead of leaving stray carriage
  returns in the converted text.
- Fixed: the text-size note in Settings could overflow its row at
  narrow window widths; it now wraps.

## 0.2.0 — 2026-10-28

Complete rewrite in Flutter. The program now looks like a mobile notepad
app inside a desktop window: a centered column, a header with a settings
gear, a toolbar with search, a red "Add note" button, "All Delete" and a
sort button, and rounded note cards with a timestamp row and edit/trash
buttons. Cards can be dragged to reorder them.

- The data file format is unchanged from 0.1.0, so notes written by 0.1.0
  are picked up automatically — nothing to convert, nothing to export
  first.
- Everything else from 0.1.0 is carried across: title and body per note,
  titles-only list, tags-only organisation (no folders), dark terminal
  theme (near-black, white text, red accent, Consolas monospace),
  autosave, pinning, search, trash with restore, text-size controls,
  character and word count, portable mode, corrupt-file quarantine, and
  the full command line.
- The command line is now part of the Flutter program itself: running
  `TermiNote.exe` with a command (for example `list` or `add`) prints to
  the terminal instead of opening the window.
- Zero external packages: the program depends only on the Flutter SDK.

## 0.1.0 — 2026-10-28

First release.

- Notes with a title and a body; the main list shows titles only, never body text.
- Organisation by tags only (sidebar filter with counts, "All notes" and "Untagged" views). No folders.
- Dark terminal theme: near-black background, white text, red accent, Consolas monospace throughout.
- Search across titles, bodies and tags.
- Autosave as you type (about 600 ms after the last change), with a "Saved" time indicator; Ctrl+S saves immediately; saving is atomic (temp file then rename).
- Pin notes to the top of the list; sort by modified (newest first), title or created.
- Trash with restore: delete, undo delete (Ctrl+Shift+Z), restore, delete-forever, empty-trash, delete-all.
- Text size controls (A− / A+), character and word count, per-control tooltips, F1 built-in help, About box.
- Drag and drop import of `.txt` / `.md` files as notes and `.json` exports as merged notes.
- Full command line with parity for every operation, `--json` output on list/show/search/tags/stats, plain-word errors and exit codes 0/1/2.
- Settings (window position and size, text size, last note, last tag filter, sort) restored on start.
- Portable mode via `portable.txt` beside the program; otherwise data in `%LOCALAPPDATA%\TermiNote`.
- Damaged data files are quarantined (renamed with `.corrupt-` plus a timestamp) instead of being lost.
- Windows 10/11 x64 only; release assets are exactly `TermiNote-Setup-x64.exe` and `TermiNote-Portable-x64.zip`.
- No update checker in this version; the program works fully offline.
