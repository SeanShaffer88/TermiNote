# TermiNote — Project Rules

Prompt in force: The Elite Software Master Prompt v1.1 · Annexes: Annex A (Windows desktop), Annex C1 (shareable defaults)
Purpose in one line: A dark terminal-themed Windows notepad — notes with titles and bodies, organised by tags only, stored locally as JSON.
Frozen foundation: `src/ops.rs` is the single operation registry; GUI (`src/gui.rs`) and CLI (`src/cli.rs`) dispatch to it and hold no business logic. Data types live in `src/note.rs` / `src/store.rs`; JSON in `src/json.rs`. Zero external crates — this is a hard rule for this project, not a preference.
Build: `cargo build --release` · Full gate: `cargo fmt --check` + `cargo clippy --locked --all-targets -- -D warnings` + `cargo test --locked --all-targets` (all on `x86_64-pc-windows-msvc`) · Test corpus: unit tests inside the modules (JSON, tags, ops, store).
Budgets: startup effectively instant for a local notepad; list operations in memory; autosave debounce 600 ms; no network use at all; binary stays dependency-free.
Coverage floors: Elite defaults — 85% core logic / 70% overall / 100% of safety paths (atomic save, corruption quarantine, trash-first delete, import-never-overwrites are safety paths and each has a test).
Special rules for this project:
- The notes list shows TITLES ONLY — body text must never be added to the listbox or printed by `list`/`search`.
- Organisation is by tags only. No folders, ever, in UI, CLI or data model.
- Theme is fixed: background #0C0C0C, all text white #FFFFFF, red accent #E81123, Consolas monospace.
- Every control has a tooltip; every GUI capability is also a CLI capability or is listed as an asymmetry in `docs/PARITY.md`.
- Releases are x64 only with exactly two assets: `TermiNote-Setup-x64.exe` and `TermiNote-Portable-x64.zip`. Never submit to winget. The program is unsigned and the docs say so.
- Windows runtime behaviour is only ever claimed from an on-machine test, never from a build or VM check (see CAPTURE.md).
Known limitations live at: README.md ("Limitations") · Decision log: DECISIONS.md · QUALITY.md: QUALITY.md
