# TermiNote

A dark, terminal-styled notepad for Windows that looks like a simple mobile notepad app. Notes have a title and a body, the list shows titles only, and notes are organised with tags.

## TL;DR

TermiNote is a notebook that works like the notepad on your phone, but on your Windows PC. You write notes, each one has a title and the note itself. The list of notes only ever shows the titles — like sticky notes labelled on the front, where you open one to read what's inside. You sort notes into groups with tags (small labels like "home" or "work") instead of folders. Everything is black with white writing and red buttons, like an old computer terminal. Your notes are saved on your own computer the moment you type them. Nobody else can see them, and it works with no internet at all.

## Key features

- **Title and body for every note.** Each note is a title plus the note text. The title is what the list shows.
- **Titles-only list.** The main list never shows any body text — no previews, no snippets. You only see what a note is called until you open it.
- **Tags, not folders.** Give a note any number of tags, then tap a tag chip to see just those notes. There are no folders anywhere.
- **Looks like a phone app.** One simple layout that fills the whole window: a header, a big red "Add note" button, and your notes as rounded cards with the date and time on each one.
- **Terminal theme.** Near-black background with a faint scanline texture, white text, red highlights, and a monospace (typewriter-style) font everywhere.
- **Drag to reorder.** Grab the handle on a note card and drag it up or down to put your notes in your own order.
- **Search.** The search button looks through titles, bodies, and tags — but the results still only show titles.
- **Autosave.** Notes save as you type. Close the program whenever you like; nothing is lost.
- **No lost work.** If you close a note, or quit, with changes that have not saved yet, TermiNote asks first: save them, throw them away, or keep working.
- **Turn notes into lists.** In the editor, the "1." and "•" buttons turn the selected lines — or the whole note — into a numbered or bullet list. Press the same button again to turn it back into plain text.
- **Minimize to the tray.** The minimize button can tuck TermiNote into the tray by the clock instead of the taskbar. The tray icon's menu opens it, starts a new note, or quits; turn the behaviour off in Settings if you prefer a normal minimize.
- **Find inside a note.** Press Ctrl+F while editing to search the note you are in, with a match count and next/previous stepping.
- **Keyboard-friendly list.** The up and down arrow keys move a highlight between note cards, Enter opens the highlighted note, and Delete moves it to the trash (with the usual undo).
- **Crash recovery.** While you edit, a recovery copy of your latest text is kept. If the program closes suddenly, the next start offers the unsaved text back instead of losing it.
- **One window at a time.** Starting TermiNote again while it is running brings the window you already have to the front.
- **Pin important notes.** Pinned notes stay at the top of the list.
- **Trash with second chances.** Deleted notes go to a trash list first, where you can bring them back or delete them for good. Deleting for good, and emptying the trash, ask first.
- **Text size controls.** Make the writing in the editor bigger or smaller with the A− and A+ buttons, and see the character count as you write.
- **Full command line.** Everything you can do in the window can also be done from a terminal window, with the same results.
- **Portable mode.** Put the program on a USB stick and it can keep its notes right next to itself.
- **Notes stored as Markdown files.** Every note is its own `.md` file in a notes folder — readable in any text editor, easy to copy, back up, or put under version control. Only the notes you changed are written, in the background, so the window stays smooth.

## Requirements

- Windows 10 or Windows 11, 64-bit (x64).
- Admin rights: not needed. It installs for your user account only.
- Internet: not needed, for installing or for using it.

## Install

1. Open the [latest release](https://github.com/SeanShaffer88/TermiNote/releases/latest) page.
2. Download one of the two files:
   - `TermiNote-Setup-x64.exe` — the installer. Run it and it puts TermiNote in your Start Menu.
   - `TermiNote-Portable-x64.zip` — the portable version. Unzip it anywhere and run `TermiNote.exe` inside.
3. The builds are unsigned (there is no paid code-signing certificate), so Windows may show a blue SmartScreen box the first time. Choose "More info", then "Run anyway".
4. If you used an older TermiNote, your notes are converted automatically the first time this version runs (see "Your data" below).

## How to use it

1. **Add a note.** Press the red "Add note" button. Type a title, any tags (separated by commas), and the note itself. Press the tick at the top right, or just go back — it saves as you type either way.
2. **Open a note.** Tap its card in the list, or tap the pencil button on the card.
3. **Find a note.** Press the search button and type. Matching notes appear as cards showing their titles.
4. **Filter by tag.** Tap a tag chip under the toolbar: "All notes" shows everything, "Untagged" shows notes with no tags, and each tag shows its own notes.
5. **Reorder notes.** Drag a card by its handle (the lines icon on the card) to move it. Your order is remembered.
6. **Delete a note.** Tap the trash button on its card. Deleted the wrong one? Open Settings (the gear) and use the Trash list to restore it.
7. **Delete everything.** The "All Delete" button moves every note to the trash. They are not gone for good until you empty the trash in Settings.
8. **Change text size.** In the editor, the A− and A+ buttons in the bottom bar change the writing size.
9. **Back up your notes.** In Settings, "Back up notes" copies the whole notes folder (trash included) to a folder you choose, and "Restore backup" brings such a backup back — restored notes are added alongside yours, nothing is overwritten. Export and Import also live there: they move notes through a single JSON file, and importing skips any note you already have (same title and same text) instead of duplicating it.
10. **Make a list.** In the editor, select the lines you want (or select nothing, for the whole note) and press "1." for a numbered list or "•" for bullets in the bottom bar. Press the same button again to go back to plain text.
11. **Tuck it into the tray.** Press the minimize button and TermiNote sits in the tray by the clock. Double-click the tray icon to bring it back, or right-click it for Open, New note, and Quit. Turn this off in Settings ("Minimize to the system tray") if you would rather it minimized to the taskbar.

## Command line

Run `TermiNote.exe` with a command instead of double-clicking it, and it works in the terminal without opening the window. List commands print the note id, its title, and its tags — never body text. Only `show` prints a note in full.

| Command | What it does |
|---|---|
| `add "title" [--body TEXT] [--tags a,b]` | Add a note |
| `list [--tag TAG] [--untagged] [--search TEXT] [--sort NAME] [--json]` | List notes, titles only |
| `show ID [--json]` | Print one note in full |
| `edit ID [--title T] [--body B] [--tags a,b]` | Change a note |
| `search WORDS [--json]` | Find notes, titles only |
| `delete ID` | Move a note to the trash |
| `duplicate ID` | Copy a note |
| `listify ID numbered / bullets / plain` | Make the note body a numbered list, a bullet list, or plain text again |
| `pin ID` / `unpin ID` | Pin or unpin a note |
| `tag ID TAG` / `untag ID TAG` | Add or remove a tag on a note |
| `rename-tag OLD NEW` | Rename a tag on every note |
| `tags [--json]` | List tags with their note counts |
| `trash [--json]` | List the trash, titles only |
| `restore ID` | Bring a note back from the trash |
| `delete-forever ID` | Delete a trashed note for good |
| `empty-trash` | Empty the trash |
| `delete-all --yes` | Move every note to the trash |
| `export FILE` | Write all notes to a JSON file |
| `import FILE` | Merge notes from a JSON file |
| `stats [--json]` | Counts for the whole notebook |
| `help` | Print the built-in help |

Sort names for `--sort`: `modifiedDesc` (newest changed first), `titleAsc`, `createdDesc`, `manual` (your drag order). Exit codes: 0 means fine, 1 means not found or failed, 2 means the command line itself was wrong.

## Your data

- Every note is its own Markdown (`.md`) file, in a notes folder you can open, read, copy, and back up yourself:
  - Normal install: `%LOCALAPPDATA%\TermiNote\notes\`
  - Portable version: a `notes` folder next to `TermiNote.exe` (this is what the `portable.txt` file in the zip switches on).
- Each file is named after its note (for example `3-non-negotiable.md`) and starts with a small header block holding the note's title, tags, pin state, and dates; the rest of the file is the note text exactly as you typed it, in plain Markdown. Trashed notes sit in a `trash` subfolder until you restore them or delete them for good. Settings shows the exact folder location.
- You can point the program at a different data folder by setting the `TERMINOTE_DATA` environment variable. (Older versions expected it to name the old `notes.json` file; that still works — the file's folder is used.)
- **Upgrading from 0.2.x or 0.1.0:** the first time this version runs, it converts your old `notes.json` into the new per-note files automatically. The old file is not deleted: it is renamed to `notes.json.migrated.bak` (or `.bak2`, and so on, if that name is taken) and kept in the same folder as a backup.
- Saving is done carefully and per note: only the notes that changed are written, each new file is written next to the old one first and then swapped in, so a crash or power cut cannot leave you with half a file. Saving happens in the background, so typing never waits on the disk.
- If the old `notes.json` is ever found damaged during the conversion, the program does not throw it away. It renames it with `.corrupt-` and the time added to the name, keeps it in the same folder, and starts with an empty notebook so you can rescue the text by hand. Individual damaged note files are read as tolerantly as possible — their text is kept as the note's body.
- Export and import (in Settings, and on the command line) still use a single JSON file. That JSON file is the interchange format for moving notes between copies of TermiNote; it is no longer how notes are stored day to day.
- Uninstalling the program does not delete your notes.

## Screenshots

Screenshots are listed in [CAPTURE.md](CAPTURE.md); they will be added from real runs on a Windows machine.

## Build it yourself

You need the Flutter SDK (stable channel) and Visual Studio with the "Desktop development with C++" workload, which is what Flutter needs for Windows apps.

```text
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

The built program lands in `build\windows\x64\runner\Release`. The installer script is `installer\TermiNote.nsi` (built with NSIS); it expects the Release folder's contents staged in an `installer\payload` folder next to it, plus `LICENSE` — the release workflow in `.github\workflows\release.yml` shows the exact steps.

## Project structure

- `lib/note_store.dart` — the note model, the store, every note operation, and reading/writing the per-note Markdown files (plus the one-time conversion of the old single-file store). No screen code in here.
- `lib/theme.dart` — the terminal theme in one place: colours, button styles, the styled scrollbar, and the phone-style page transition.
- `lib/main.dart` — the window: header, toolbar, tag chips, and the note card list.
- `lib/editor_screen.dart` — the note editor page.
- `lib/settings_screen.dart` — settings, trash, export/import, and about.
- `lib/cli.dart` — the command line, using the same store code as the window.
- `lib/window_channel.dart` — the small bridge to the Windows runner for the system tray behaviour.
- `test/` — tests for the store, the screens, and the golden (picture) tests.
- `windows/` — the standard Flutter Windows runner, with small changes so the command line can print to the terminal and the window can minimize to the system tray.
- `installer/` — the NSIS installer script.

## Tests

```text
flutter test
```

This runs the store tests (including a round-trip of a 0.1.0 data file and a damaged-file test). Screen tests — including the widget test that proves the list shows titles and no body text, and the golden picture tests that render the screens to `preview/` — live alongside the screen code in `test/`.

## Troubleshooting

- **Windows says the program is unsigned / shows SmartScreen.** That is expected: the builds are not code-signed. Choose "More info", then "Run anyway".
- **My notes are gone and the list is empty.** Check the data folder for a file with `.corrupt-` in its name. That is your old notes file from before the Markdown conversion, kept safe; the program started a fresh notebook because the file was damaged. Your text is still inside the renamed file. Also check the notes folder itself (Settings shows where it is) — your notes are one `.md` file each in there.
- **The command line prints nothing.** Run it from a terminal window (so there is a console to print to), and make sure the first word after the program name is one of the commands in the table above.
- **Two copies of the program disagree about my notes.** One of them is probably the portable version keeping its notes next to itself, or `TERMINOTE_DATA` is set. Check which notes folder each copy is using (Settings shows the location).

## Privacy and network behaviour

TermiNote works fully offline. It makes no network connections, has no accounts, shows no ads, sells no data, and collects nothing. Your notes never leave your computer unless you export them yourself. The program is free; optional donations never unlock anything.

## Limitations and known issues

- No folders — that is deliberate. Organisation is tags only.
- No sync between computers. Notes are plain Markdown files in one folder, so you can copy that folder yourself.
- No update checker in this version. Check the releases page when you want a newer version.
- Windows x64 only.

## Licence

MIT — see [LICENSE](LICENSE). Free software: use it, copy it, change it.
