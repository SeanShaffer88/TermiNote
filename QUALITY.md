# Quality status

## Verified by CI for v0.8.3

- [Post-merge CI](https://github.com/SeanShaffer88/TermiNote/actions/runs/44463988727) passed Linux core tests and the Dioxus WebAssembly UI check, plus the Windows x64 app and installer build.
- [Release workflow](https://github.com/SeanShaffer88/TermiNote/actions/runs/44464018580) passed the version/tag check, Rust core tests, Windows Tauri build, updater safeguards, Inno Setup installer, portable ZIP, and publication of both assets.
- The [v0.8.3 release](https://github.com/SeanShaffer88/TermiNote/releases/tag/v0.8.3) contains `TermiNote-Setup-x64.exe` and `TermiNote-Portable-x64.zip`.

## Safety properties

- Notes use per-note Markdown files and atomic replacement.
- Legacy JSON is retained as a migration backup; restore creates a safety copy before replacing data.
- Deletes move notes to Trash first; permanent deletion is explicit.
- The GUI and CLI acquire the same data lock, preventing concurrent writes.
- Autosaves are serialized. Failed saves keep a recoverable draft; startup offers newer drafts for recovery.
- Tray Quit and update installation wait for pending note saves.
- Update downloads are restricted to the official GitHub release asset, size-limited, and SHA-256 checked.

## Not yet field-verified

- CI builds and packages the app but does not launch it. A fresh installer launch, in-app update, tray interaction, remembered window placement, and real user-data migration still need a Windows 11 x64 runtime pass.
- Performance has not been profiled. No performance refactor is included before profiling.
- Full accessibility and screen-reader behavior have not been tested on Windows.

## Scope

TermiNote is a Rust/Tauri desktop app with a Rust/Dioxus WebAssembly UI. The v0.8.3 release is built for Windows 11 x64. CI status proves compilation and packaging, not interactive runtime behavior.
