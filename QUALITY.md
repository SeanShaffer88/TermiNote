# Quality status

## Verified in this workspace

- `cargo test --locked -p terminote-core`: 17 tests pass, covering Markdown-file compatibility, legacy JSON/settings migration, CRUD and Trash safety, tags, backup/restore, recovery drafts, locking, Markdown formatting/rendering, and CLI behavior.
- `cargo check --locked -p terminote-ui`: passes.
- Windows-only native build and runtime behavior are delegated to the Windows x64 CI job because this Linux workspace lacks the GTK development libraries needed to compile Tauri here.

## Safety properties

- Notes use per-note Markdown files and atomic replacement.
- Legacy JSON is retained as a migration backup; restore creates a safety copy before replacing data.
- Deletes move notes to Trash first; permanent deletion is explicit.
- The GUI and CLI acquire the same data lock, preventing concurrent writes.
- Autosaves are serialized. Failed saves keep a recoverable draft; startup offers newer drafts for recovery.
- Update downloads are restricted to the official GitHub release asset, size-limited, and SHA-256 checked. Installing waits for pending note saves.

## Not yet field-verified

- Windows 11 x64 installer launch, tray click/minimize/close behavior, remembered window placement, and real user-data migration require a Windows run.
- Performance has not been profiled. No performance refactor is included before profiling.
- Full accessibility and screen-reader behavior have not been tested on Windows.

## Scope

This is the in-progress Rust/Tauri rewrite. Do not treat the historical Flutter screenshots or prior release verification as proof of the new build's runtime behavior. CI and a Windows 11 x64 field pass are the evidence for the rewrite.
