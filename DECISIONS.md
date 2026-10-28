# Decisions

## Stack: Rust + native Win32, zero external crates

TermiNote is written in Rust (edition 2021) with no dependencies at all. The window is built with direct Win32 FFI calls from `src/gui.rs`, and the JSON store uses a small hand-written parser in `src/json.rs`.

Reasons:

- A notepad needs almost nothing from a framework; the whole feature set fits comfortably in direct Win32 controls (list boxes, edits, buttons).
- Zero crates means zero supply-chain risk, no version drift, fast builds, and a binary that works offline forever.
- Rust gives memory safety for the parts that parse untrusted text (the JSON store and imports) without a runtime or garbage collector.
- Direct Win32 gives exact control over the theme: black brushes via `WM_CTLCOLOR*`, an owner-drawn notes list (black background, white text, red selection), and an owner-drawn red Add note button.
- Every capability is implemented once as an operation in `src/ops.rs`; the GUI and CLI are both thin dispatchers over it, so they cannot drift apart (see `docs/PARITY.md`).

## Data format

One JSON file (`notes.json`) holds `next_id`, the live `notes` array and the `trash` array. Each note is `{id, title, body, tags, pinned, created, modified}` with unix-second timestamps.

- Plain JSON the user can read, back up, and repair by hand.
- Saving is atomic: write `notes.json.tmp`, then rename over `notes.json`, so a crash mid-save cannot leave a half-written file.
- Loading is tolerant per note (a damaged note entry is skipped), and a wholly unparseable file is quarantined to `notes.json.corrupt-<timestamp>` with an empty store returned plus a flag, instead of crashing or discarding the bytes.
- Import merges with fresh ids, so importing can never overwrite an existing note.

## Title-only list

The main list shows note titles only — never body text, not even a first-line preview. This is a core product decision, not a missing feature: the list is for finding notes, and keeping bodies out of it means the list is safe to show on a shared screen and stays scannable. Reading a body is always one explicit click (`show` on the CLI) away.

## Tags, not folders

Organisation is by tags only. A note can carry many tags; a folder would force each note into exactly one place. The sidebar offers "All notes", "Untagged" and one row per tag with counts. Tags are normalised (trimmed, lowercased, deduplicated, capped at 40 characters) so `Work` and `work` are the same tag.

## Other decisions

- **Deletes go to a trash list first.** Nothing is permanently removed by a single action in the GUI; permanent deletion exists only as explicit CLI commands and the trash operations.
- **Time is a parameter.** Operations take `now` (unix seconds) instead of reading the clock, which keeps them deterministic and testable.
- **DPI awareness is set by API call at startup** (`SetProcessDpiAwarenessContext`, Per-Monitor V2) rather than by an embedded manifest, so there is no `build.rs` and no resource toolchain in the build.
- **No update checker in v0.1.0.** The program contains no network code at all.
- **x64 only.** Releases ship exactly two assets: `TermiNote-Setup-x64.exe` and `TermiNote-Portable-x64.zip`.
