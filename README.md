# TermiNote

TermiNote is a Windows 11 x64 desktop notes app with a dark terminal-style theme. The app and shared note logic are written in Rust, with a Rust-authored Dioxus interface hosted by Tauri.

## What it does

- Shows compact notes with title, preview, tags, and changed date.
- Expands notes inline: edit title, tags, Markdown text, or checklist items without switching screens. Changes save automatically.
- Suggests existing tags while typing; search and tag filters include note contents.
- Hides scrollbar chrome but keeps lists and editors scrollable; the text-size setting scales all app text.
- Keeps the three-dot menu at the top with only Recycle Bin and Delete All Notes.
- Offers Markdown edit, split, and preview modes, formatting tools, find/replace, and list conversion.
- Supports pinning, manual reorder, Trash, recovery drafts, JSON import/export, and full data-folder backup/restore.
- Restores the previous window size, position, and maximized state. A single tray click restores a hidden or minimized window; tray Quit exits reliably after pending edits get time to flush.
- Includes a CLI using the same Rust note core.
- Keeps notes and settings local. Automatic update checks can be disabled in Settings.

The app uses the existing near-black, scanline, white-text, red-accent theme. Rust handles the UI logic, storage, Markdown, CLI, and Windows lifecycle; no Flutter or Dart source remains.

## Install

Use Windows 11 x64. Download either asset from the [latest release](https://github.com/SeanShaffer88/TermiNote/releases/latest):

- `TermiNote-Setup-x64.exe` — per-user installer.
- `TermiNote-Portable-x64.zip` — unzip and run `TermiNote.exe`; `portable.txt` keeps data beside the program.

The installer is currently unsigned, so Windows SmartScreen may ask for confirmation.

## Data and compatibility

- Normal data folder: `%LOCALAPPDATA%\TermiNote`.
- Set `TERMINOTE_DATA` to use another data folder.
- Portable mode stores data next to the executable.
- Notes are individual `.md` files; Trash and recovery drafts remain in the same data folder.
- Existing `notes.json` data and the previous `settings.json` shape are read and migrated. JSON remains available for import/export.
- Uninstalling the app does not remove notes.

## Build and test

Install Rust for the MSVC target, the Dioxus CLI (`dx`), the Tauri CLI (`cargo-tauri`), and Inno Setup 6. Build on Windows 11 x64:

```powershell
cargo test --locked -p terminote-core
cargo check --locked -p terminote-ui
Push-Location src-tauri
cargo tauri build --target x86_64-pc-windows-msvc --no-bundle
cargo test --locked -p terminote --lib
Pop-Location
ISCC.exe /DAppVersion=0.8.4 installer\TermiNote.iss
```

The v0.8.4 release publishes an Inno Setup installer and a separate portable ZIP. CI checks the core, WebAssembly UI, Windows build, updater safeguards, and packaging; the hosted Windows job installs the build and tests tray restore and Quit. See [QUALITY.md](QUALITY.md) for the verification boundary.

## CLI

Run commands from a terminal with `TermiNote.exe <command>`. Use `TermiNote.exe help` for the complete syntax. The core commands are:

```text
add, list, show, edit, search, delete, duplicate
listify, format, render, toc, export-html
pin, unpin, tag, untag, rename-tag, tags
trash, restore, delete-forever, empty-trash, delete-all
export, import, add-file, backup, restore-backup, stats
```

Destructive commands require explicit confirmation flags where appropriate.

## Source layout

- `crates/core` — note model, Markdown files, migration, backups, recovery, and CLI operations.
- `ui` — Rust/Dioxus interface and theme styles.
- `src-tauri` — Tauri commands, Windows tray/window lifecycle, single-instance behavior, and updater.
- `.github/workflows` — Linux/core and Windows x64 CI plus tagged releases.

TermiNote is licensed under MIT. See [LICENSE](LICENSE).
