# Captures — TermiNote 0.3.0

Real screenshots from a run on a real Windows machine, for the README.
No placeholders. Please capture at 100% scaling unless a capture says
otherwise, with a few real notes in the list (one pinned, at least two
tags in use).

Captured 2026-10-28 (in the README, in the `screenshots` folder):

1. **Main window, normal size** — `screenshots/list.png`.
2. **Editor open** — `screenshots/editor.png`.
3. **Settings screen** — `screenshots/settings.png`.

Still owed:

4. **Settings → Trash** — the trash list with at least one deleted note
   showing its restore and delete-forever buttons.
5. **Narrow window** — the window resized to near its minimum width, to
   show the layout still lays out cleanly.
6. **Wide window** — the window maximised on a widescreen monitor, to show
   the content using the full window width, edge to edge.
7. **150% display scaling** — the main window again with Windows display
   scaling at 150%, to check text and cards scale without clipping.

Field checks to go with the captures (the on-machine verdict for
QUALITY.md):

- Installs from `TermiNote-Setup-x64.exe` and starts from the Start Menu.
- Notes written by 0.1.0 are still there after the upgrade.
- First run of 0.3.0 converts existing notes to .md files: the notes
  folder appears next to the old data, every note (and trash entry) is
  present, and the old file remains as notes.json.migrated.bak.
- Add, edit, delete, restore, pin, drag-reorder, and search all work.
- The portable zip runs from an unzipped folder and keeps its notes next
  to itself.
- `TermiNote.exe list` and `TermiNote.exe stats` in a terminal print
  titles and counts, with no body text in the list output.
- Uninstall removes the program and leaves the notes file alone.
- Type in a note and close it straight away (inside the autosave
  moment): the "Save before closing?" dialog appears, and each of its
  three buttons does what it says.
- Quit the program with unsaved changes in an open note: the "Save
  before quitting?" dialog appears.
- In the editor, the "1." and "•" toolbar buttons convert the body (and
  a selection) into a list and back again.
- Minimize with the system tray setting on: the window tucks into the
  tray; the tray icon's Open, New note, and Quit items work, and Quit
  still asks about unsaved work. With the setting off, minimize is a
  normal taskbar minimize.
