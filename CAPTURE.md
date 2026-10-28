# Captures owed — TermiNote 0.2.0

Real screenshots from a run on a real Windows machine, for the README.
No placeholders: the README links here until these exist. Please capture
at 100% scaling unless a capture says otherwise, with a few real notes in
the list (one pinned, at least two tags in use).

1. **Main window, normal size** — the note list with several notes: header,
   toolbar, tag chips, and cards all visible; list showing titles only.
2. **Editor open** — a note with a title, tags, and a few lines of body
   text; the ruled lines, character count, and bottom toolbar visible.
3. **Settings screen** — sort order and text size controls visible.
4. **Settings → Trash** — the trash list with at least one deleted note
   showing its restore and delete-forever buttons.
5. **Narrow window** — the window resized to near its minimum width, to
   show the single column still lays out cleanly.
6. **Wide window** — the window maximised on a widescreen monitor, to show
   the centered column with dark margins on both sides.
7. **150% display scaling** — the main window again with Windows display
   scaling at 150%, to check text and cards scale without clipping.

Field checks to go with the captures (the on-machine verdict for
QUALITY.md):

- Installs from `TermiNote-Setup-x64.exe` and starts from the Start Menu.
- Notes written by 0.1.0 are still there after the upgrade.
- Add, edit, delete, restore, pin, drag-reorder, and search all work.
- The portable zip runs from an unzipped folder and keeps its notes next
  to itself.
- `TermiNote.exe list` and `TermiNote.exe stats` in a terminal print
  titles and counts, with no body text in the list output.
- Uninstall removes the program and leaves the notes file alone.
