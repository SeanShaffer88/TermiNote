# Changelog

All notable changes to TermiNote are recorded here.

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
