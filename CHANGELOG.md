# Changelog

All notable changes to TermiNote are recorded here.

## 0.3.0 — 2026-10-28

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

- Fixed: a note converted from the old single-file format could keep
  an unusable id of 0 until the next run; ids are now repaired during
  the conversion itself.
- Fixed: converting a note to a numbered or bullet list now tidies
  Windows-style line endings instead of leaving stray carriage
  returns in the converted text.

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
