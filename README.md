# TermiNote

A dark, terminal-styled notepad for Windows: notes with a title and a body, organised with tags, stored on your own computer as plain JSON.

## TL;DR

TermiNote is a notepad that looks like an old computer terminal — black screen, white writing, one red button. You write notes in it. Each note has a short title (like a label on a folder) and the note itself underneath. To keep notes tidy you stick tags on them, like sticky notes that say "work" or "ideas", and you can look at just the notes with one tag. The list only ever shows the titles, never the note text, so nobody walking past sees what you wrote. Everything stays on your own computer in a file you can read yourself. No account, no internet, no cost.

## Features

- **Notes with a title and a body** — the title is the short label; the body is the note itself.
- **Title-only list** — the main list shows titles only, never any body text. Click a title to read or edit that note.
- **Tags, not folders** — organise notes with as many tags as you like. The sidebar lists every tag with a count; click one to filter. There is also "All notes" and "Untagged".
- **Dark terminal theme** — near-black background (`#0C0C0C`), all text white, red accent (`#E81123`) for the Add note button and the selected note, and a monospace font (Consolas) throughout.
- **Search** — type in the search box to find notes by title, body or tag.
- **Autosave** — notes save themselves about half a second after you stop typing; the window shows when the last save happened. Ctrl+S saves immediately. Work is never lost to a sudden close: saving writes a complete new file and swaps it in.
- **Pinning** — pin a note and it stays at the top of the list.
- **Trash, not instant deletion** — deleting moves a note to the trash. "Undo delete" (Ctrl+Shift+Z) brings back the last one; the command line can restore any trashed note, empty the trash, or delete one note for good.
- **Text size controls** — A− / A+ change the text size for the whole window.
- **Character and word count** — shown in the editor's bottom bar and updated as you type.
- **Drag and drop** — drop `.txt` or `.md` files on the window to turn them into notes (the file name becomes the title), or drop a TermiNote `.json` export to import it.
- **Full command line** — everything the window can do can also be done from a terminal (see the CLI reference below), including machine-readable `--json` output for scripts.
- **Remembers where you left off** — window size and position, text size, last tag filter, sort order and last open note are restored on the next start.
- **Tooltips everywhere** — every button, list and field explains itself when you hover over it.
- **Built-in help** — press F1 (or the Help button) for a plain-words guide inside the program; it works offline.
- **Portable mode** — put a file called `portable.txt` next to `TermiNote.exe` and the program keeps its data in that same folder. The portable zip already includes it.

## Screenshots

Screenshots are taken on a real Windows machine; the exact captures still owed are listed in [CAPTURE.md](CAPTURE.md). No placeholder images are used in this README.

## Requirements

- Windows 10 or Windows 11, 64-bit (x64).
- No other software needs to be installed. The installer does not need administrator rights.

## Install

Download from the GitHub Releases page:

- **`TermiNote-Setup-x64.exe`** — the installer. Run it; it installs for your user account only, adds a Start Menu shortcut, and can be removed from Windows Settings like any other program.
- **`TermiNote-Portable-x64.zip`** — the portable version. Unzip it anywhere and run `TermiNote.exe`. See `PORTABLE.txt` inside the zip.

The program is unsigned (there is no code-signing certificate), so Windows may show a "Windows protected your PC" message the first time; choose "More info" then "Run anyway" if you trust the source — the source code is all in this repository.

## How to use it

1. **Open TermiNote.** You see the tags sidebar on the left, a search box and a red **Add note** button at the top, the list of note titles in the middle, and the editor on the right.
2. **Add a note:** click **Add note** (or press Ctrl+N). A new note appears in the list and opens in the editor, ready for its title.
3. **Write:** type the title in the top field, any tags in the field under it (separated by commas, for example `work, ideas`), and the note in the big field. It saves itself as you type — watch the "Saved" time in the editor.
4. **Find a note:** click its title in the list, click a tag in the sidebar to filter, or type in the search box.
5. **Make the text bigger or smaller:** use the **A+** and **A−** buttons under the editor.
6. **Pin an important note:** open it and click **Pin**; it stays at the top of the list.
7. **Delete a note:** open it and click **Delete**, or select it in the list and press the Delete key. It goes to the trash, not oblivion — **Undo delete** brings back the last one.
8. **Get help:** press F1 at any time.

## Command line reference

Running `TermiNote` with no arguments opens the window. With arguments it runs as a command-line tool instead. Exit codes: `0` success, `1` the command could not be done (for example no such note), `2` the command was not understood. `list` and `search` print titles only — never body text. `show` is the one command that prints a note in full.

| Command | What it does |
|---|---|
| `add "title" [--body TEXT] [--tags a,b]` | Add a note |
| `list [--tag T] [--search Q] [--sort S]` | List note titles (id, title, tags) |
| `show ID` | Print one note in full |
| `edit ID [--title T] [--body B] [--tags a,b]` | Change a note |
| `delete ID` | Move a note to the trash |
| `restore ID` | Bring a note back from the trash |
| `delete-forever ID` | Permanently delete a trashed note |
| `trash` | List trashed note titles |
| `empty-trash` | Permanently delete everything in the trash |
| `delete-all --yes` | Move every note to the trash (`--yes` is required) |
| `tag ID TAG` / `untag ID TAG` | Add or remove a tag on a note |
| `rename-tag OLD NEW` | Rename a tag on every note |
| `tags` | List tags with counts |
| `pin ID` / `unpin ID` | Pin or unpin a note |
| `duplicate ID` | Copy a note |
| `search Q` | Search titles, bodies and tags; lists titles |
| `export FILE` | Write all notes to a file as JSON |
| `import FILE` | Merge a JSON export into this store (new ids; nothing overwritten) |
| `stats` | Counts, word and character totals |
| `help` | The built-in help |

`--sort` accepts `modified` (newest first, the default), `title` or `created`. `--json` can be added to `list`, `show`, `search`, `tags` and `stats` for machine-readable output. The `TERMINOTE_DATA` environment variable can point at a different data file, which is handy for scripts and tests.

Examples:

```
TermiNote add "Shopping list" --body "Milk, eggs, bread" --tags home
TermiNote list --tag home
TermiNote show 3
TermiNote rename-tag home house
TermiNote export backup.json
```

## Settings and data locations

- **Installed mode:** notes live in `%LOCALAPPDATA%\TermiNote\notes.json`; window and view settings in `settings.json` in the same folder.
- **Portable mode:** with `portable.txt` next to the program, both files live next to `TermiNote.exe`.
- The data file is plain JSON. If it is ever damaged, TermiNote does not throw it away: it renames it with `.corrupt-` and a timestamp in its name, starts with an empty store, and tells you what happened.

## Building from source

You need a Rust toolchain (stable) with the `x86_64-pc-windows-msvc` target.

```
cargo build --release
cargo test
cargo clippy --all-targets -- -D warnings
cargo fmt --check
```

The installer is built with NSIS: copy the release `TermiNote.exe` next to `installer/TermiNote.nsi` and run `makensis installer\TermiNote.nsi`; it produces `TermiNote-Setup-x64.exe`. Releases attach exactly two assets, both x64: the setup program and the portable zip.

## Project structure

```
src/lib.rs     Module list, re-exports, the small time helper
src/main.rs    Entry point: GUI with no arguments, CLI with arguments
src/json.rs    Small tolerant JSON parser/serializer (no dependencies)
src/note.rs    The Note type and tag normalisation
src/store.rs   Load/save the JSON store, corruption quarantine, data paths
src/ops.rs     Every operation on the store - the single registry the GUI and CLI share
src/cli.rs     The command line
src/gui.rs     The native Win32 window (direct FFI, no GUI crates)
installer/     The NSIS installer script
docs/          Parity matrix and the project rule sheet
```

## Tests

`cargo test` runs the unit tests: JSON round-trips, tag normalisation, every store operation (add, filtering, search, sorting, pinning, trash and restore, tag rename, import/export), the store save/load round-trip, and the corruption quarantine. The GUI itself is exercised on a real Windows machine (see CAPTURE.md).

## Troubleshooting

- **"The data file was damaged" message:** TermiNote moved the damaged file aside (look for a file with `.corrupt-` in its name in the data folder) and started empty. Your original file is still there; a JSON-savvy person can often repair it by hand and rename it back to `notes.json` while TermiNote is closed.
- **Windows says the program is unsigned / "Windows protected your PC":** the program ships without a code-signing certificate. Choose "More info" then "Run anyway" if you trust the source.
- **Notes seem missing after using portable mode:** portable mode reads and writes the `notes.json` beside the program, not the one in `%LOCALAPPDATA%`. Delete `portable.txt` (while TermiNote is closed) to go back to the normal folder.
- **The window opens off-screen:** delete `settings.json` in the data folder while TermiNote is closed; it will start with default size and position.

## Privacy

TermiNote works fully offline. Notes are stored in one local JSON file on your computer. There is no account, no sign-in, no analytics, no network code at all, and no selling of data. TermiNote is completely free; optional donations are allowed but never required and never unlock anything.

## Limitations

- No folders — by design. Organisation is by tags only.
- No sync between computers in this version; copy `notes.json` (or use export/import) to move notes yourself.
- No built-in update checker in v0.1.0; new versions are announced on the GitHub Releases page.
- One data file per location: the installed folder or the portable folder.

## Licence

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Sean Shaffer.
